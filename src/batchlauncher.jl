# How batch work gets scheduled. One interface, several backends, and deliberately nothing else:
# provisioning (how code reaches the node) and the store (how blobs move) are separate concerns
# with separate interfaces, because Kubernetes answers all three differently and folding them
# together is what would make it a rewrite later.
#
# The interface is keyed on NAMES, not job ids. A name is content-derived, so the hub can always
# recompute it from the notebook; a job id is exactly the kind of state that goes stale while the
# hub is closed. `poll` therefore asks "is anything running under these names", which is a question
# that can be answered after a restart, a reboot, or from a different machine.
#
# `poll` is also batched by construction. A sweep can have hundreds of submissions and the answer
# has to cost one call, not one call each.

module BatchLauncher

import Dates

export Launcher, ExecLauncher, SlurmLauncher, JobSpec, submit!, poll, cancel!, logs

"""
    JobSpec

One submission: run `chunks[i]` as array element `i`. `name` is the dedup token the backend
registers the work under, and is what `poll`/`cancel!` later match on.
"""
struct JobSpec
    name::String
    chunks::Vector{String}
    root::String                 # CAS root, as the COMPUTE node sees it
    project::String              # Julia project the task runs under
    payload::String              # path to slatetask.jl on the compute node
    julia::String                # julia binary (or a module-load prologue can supply it)
    resources::NamedTuple        # (; cpus, mem, walltime, partition, ...)
    logdir::String
    prologue::String             # shell run before julia: `module load`, depot exports, ...
    directives::String           # scheduler flags verbatim, one per line — see `directive_lines`
end

JobSpec(name, chunks; root, project, payload, julia = "julia",
        resources = (; cpus = 1, mem = "1G", walltime = "00:30:00", partition = ""),
        logdir = joinpath(root, "logs"), prologue = "", directives = "") =
    JobSpec(String(name), String.(collect(chunks)), String(root), String(project),
            String(payload), String(julia), resources, String(logdir), String(prologue),
            String(directives))

"""
    directive_lines(text) -> Vector{String}

Free-form scheduler directives → `#SBATCH` lines. One per line; blank lines and `#` comments are
dropped, and a line may be written either way (`--exclusive` or `#SBATCH --exclusive`) because both
are what people have in front of them when they are copying from a working batch script.

This is the escape hatch for a flag whose value contains characters a cell header cannot carry, and
for the site-specific ones there is no point naming (`--licenses`, `--switches`, `--wckey`). It is
emitted verbatim: Slate does not know what a site's flags mean and should not pretend to.
"""
function directive_lines(text::AbstractString)
    out = String[]
    for raw in eachsplit(String(text), '\n')
        s = strip(raw)
        (isempty(s) || startswith(s, "# ") || s == "#") && continue
        s = startswith(s, "#SBATCH") ? strip(s[8:end]) : s
        isempty(s) && continue
        # A directive is one flag. Anything else would be a shell line in a place that only accepts
        # scheduler options, where it is silently ignored rather than run — so say so instead.
        startswith(s, "-") ||
            error("scheduler directive `$s` does not start with `-`. These are sbatch flags " *
                  "(`--constraint=avx512`), one per line; shell setup belongs in the cluster's prologue.")
        push!(out, "#SBATCH " * s)
    end
    return out
end

abstract type Launcher end

"""
    submit!(launcher, spec) -> String

Start the work and return a backend handle (a job id, a pid). The handle is a convenience for logs
and diagnostics; correctness never depends on the hub remembering it.
"""
function submit! end

"""
    poll(launcher, names) -> Dict{String,Symbol}

State of every name in ONE call: `:pending`, `:running`, or `:unknown`. `:unknown` means the
backend has nothing live under that name, which is deliberately not the same as "finished" — only
the store can answer that, because a job can die without producing anything.
"""
function poll end

"""
    cancel!(launcher, names) -> Int

Cancel anything live under these names. Returns how many names were acted on.
"""
function cancel! end

"Recent output for a name, best effort. Empty string when there is nothing to show."
function logs end

# The command a task process runs. Written once here so every backend launches identically and a
# bug in the invocation cannot differ between local and cluster runs.
#
# JULIA_PKG_PRECOMPILE_AUTO=0 is not optional: hundreds of tasks starting against an incomplete
# depot would each try to precompile into it, which is how a shared filesystem gets taken down. A
# task must load from a ready depot or fail fast.
function task_command(spec::JobSpec, chunks)
    pre = isempty(spec.prologue) ? "" : spec.prologue * "\n"
    cs = chunks isa AbstractString ? String(chunks) : join(String.(collect(chunks)), " ")
    return string(pre,
        "export JULIA_PKG_PRECOMPILE_AUTO=0\n",
        spec.julia, " --project=", spec.project, " --startup-file=no ",
        "-e 'include(\"", spec.payload, "\"); exit(SlateTask.main(ARGS))' ",
        spec.root, " ", cs)
end

# ── Local execution ──────────────────────────────────────────────────────────────────────────
# No scheduler at all: run the chunks as local subprocesses. This is what makes the whole fabric
# testable without a cluster, and it is also the honest answer for `slate_map` on a laptop.
#
# There is no squeue to ask here, so the launcher keeps its own pid files. That is not a violation
# of "derive, don't store": a pid file is observable state that can be checked against the process
# table, which is precisely what squeue does on a cluster.
struct ExecLauncher <: Launcher
    maxproc::Int
end
# The binding constraint is MEMORY, not cores: every task process is a separate Julia that loads
# the project, so this is deliberately far below the core count. Raise it only with an eye on RSS.
ExecLauncher(; maxproc::Int = clamp(Sys.CPU_THREADS ÷ 3, 1, 4)) = ExecLauncher(maxproc)

_jobdir(root) = joinpath(root, "jobs")
_jobfile(root, name) = joinpath(_jobdir(root), name)

_alive(pid::Integer) = pid > 0 && try
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
catch
    false
end

# Chunks are dealt round-robin into at most `maxproc` slices, and each slice becomes ONE process
# that runs its chunks in sequence.
#
# The earlier version started a process per chunk with nothing bounding it, which on a sweep of a
# few hundred units meant dozens of concurrent Julia processes each loading a full project. That is
# gigabytes, and it can take a machine down. On a cluster the scheduler enforces this; running
# locally there is nothing but this function.
function _deal(chunks, n)
    n = max(1, min(n, length(chunks)))
    slices = [String[] for _ in 1:n]
    for (i, c) in enumerate(chunks); push!(slices[mod1(i, n)], String(c)); end
    return filter(!isempty, slices)
end

function submit!(l::ExecLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    mkpath(_jobdir(spec.root)); mkpath(spec.logdir)
    pids = Int[]
    for (i, slice) in enumerate(_deal(spec.chunks, l.maxproc))
        logf = joinpath(spec.logdir, "$(spec.name).$(i).log")
        cmd = pipeline(Cmd(`sh -c $(task_command(spec, slice))`); stdout = logf, stderr = logf)
        p = run(cmd; wait = false)
        push!(pids, getpid(p))
    end
    write(_jobfile(spec.root, spec.name), join(pids, "\n"))
    return join(pids, ",")
end

function poll(l::ExecLauncher, root::AbstractString, names)
    out = Dict{String,Symbol}()
    for name in names
        f = _jobfile(root, name)
        if !isfile(f)
            out[String(name)] = :unknown
            continue
        end
        pids = [something(tryparse(Int, s), 0) for s in split(read(f, String); keepempty = false)]
        out[String(name)] = any(_alive, pids) ? :running : :unknown
    end
    return out
end

function cancel!(l::ExecLauncher, root::AbstractString, names)
    n = 0
    for name in names
        f = _jobfile(root, name); isfile(f) || continue
        for s in split(read(f, String); keepempty = false)
            pid = tryparse(Int, s); pid === nothing && continue
            _alive(pid) && (try; ccall(:kill, Cint, (Cint, Cint), pid, 15); catch; end)
        end
        rm(f; force = true); n += 1
    end
    return n
end

function logs(l::ExecLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    dir = joinpath(root, "logs")
    isdir(dir) || return ""
    fs = filter(f -> startswith(basename(f), String(name) * "."), readdir(dir; join = true))
    isempty(fs) && return ""
    buf = IOBuffer()
    for f in fs
        ls = try; readlines(f); catch; String[]; end
        println(buf, "== ", basename(f), " ==")
        for l in last(ls, max(1, lines ÷ length(fs))); println(buf, l); end
    end
    return String(take!(buf))
end

# ── SLURM ────────────────────────────────────────────────────────────────────────────────────
# One array job per submission: the scheduler sees a single entry with N elements, which is what
# array jobs exist for, instead of N separate jobs competing in the queue.
#
# Array element i runs chunks[i], resolved through an index file written next to the job. The hub
# never needs that mapping back: per-chunk progress comes from the status directory, and per-shard
# completion comes from the store.
struct SlurmLauncher <: Launcher
    host::String                 # the login node; "" runs the client tools locally
    account::String
    qos::String
    runner::Any                  # (host, script) -> (ok, output); the caller's authenticated session
end
# The default runner is a plain local shell, which is what the tests use and what running ON a login
# node needs. Anything reaching a remote cluster passes its own.
SlurmLauncher(host = ""; account = "", qos = "",
              runner = (h, sc) -> _local_run(sc)) =
    SlurmLauncher(String(host), String(account), String(qos), runner)

function _local_run(script::AbstractString)
    buf = IOBuffer()
    ok = try; run(pipeline(`sh -c $script`; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

# An empty host means the SLURM client tools are on THIS machine, which is the case when Slate runs
# on a login node (a common enough deployment that it should not need a loopback ssh) and when the
# reconciler itself runs inside the cluster. Everything else about the backend is identical, so the
# two cases differ only in how a command is wrapped.
# Returns `(ok, output)` — the runner is the caller's authenticated session, not a Cmd.
_ssh(l::SlurmLauncher, script::AbstractString) = l.runner(l.host, String(script))

function _run_capture(cmd::Cmd)
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

# The batch script. `$SLURM_ARRAY_TASK_ID` picks this element's chunk out of the index file, so one
# script serves every element and the mapping lives on the shared filesystem rather than in the
# submission.
# The three settings whose Slate name differs from sbatch's, because they predate the rest. Every
# other key becomes its own flag with `_` → `-` — which is what lets an option Slate has never heard
# of work anyway (`--licenses`, `--switches`, a scheduler patch a site added last week).
const _SBATCH_RENAME = Dict(:cpus => "cpus-per-task", :walltime => "time", :gpus => "gpus")

sbatch_flag(k::Symbol) = get(_SBATCH_RENAME, k, replace(String(k), '_' => '-'))

# `--exclusive` is the one flag whose VALUE is optional (`--exclusive`, or `=user`/`=mcs`/`=topo`),
# so it cannot be emitted as a plain `--key=value`.
function _exclusive_line(v)
    s = strip(String(v))
    (isempty(s) || lowercase(s) in ("no", "false", "0")) && return nothing
    return lowercase(s) in ("yes", "true", "1") ? "#SBATCH --exclusive" : "#SBATCH --exclusive=$s"
end

# The three Slate always emits, because a job with no cores, memory or time limit is at the mercy of
# whatever the site's defaults happen to be — and those are the numbers a sweep most needs to state.
const _SBATCH_ALWAYS = (cpus = 1, mem = "1G", walltime = "00:30:00")

function _sbatch_script(l::SlurmLauncher, spec::JobSpec, indexfile::AbstractString)
    r = spec.resources
    lines = ["#!/bin/bash",
             "#SBATCH --job-name=$(spec.name)",
             "#SBATCH --array=1-$(length(spec.chunks))",
             "#SBATCH --output=$(spec.logdir)/$(spec.name).%A_%a.out",
             "#SBATCH --cpus-per-task=$(get(r, :cpus, _SBATCH_ALWAYS.cpus))",
             "#SBATCH --mem=$(get(r, :mem, _SBATCH_ALWAYS.mem))",
             "#SBATCH --time=$(get(r, :walltime, _SBATCH_ALWAYS.walltime))",
             # Duplicate submission across a hub restart is prevented by the cluster itself: only
             # one job of this name per user can run, and the name is content-derived.
             "#SBATCH --dependency=singleton"]
    # Everything else the spec carries, sorted so two identical sweeps produce identical scripts.
    # A key absent from the spec emits no line at all: writing `--nodes=1` where the author asked
    # for nothing would override the partition's own configuration with a guess.
    #
    # Deduplicated by the FLAG, not the key: three options have a Slate name that differs from
    # sbatch's, so `cpus` and `cpus_per_task` are the same setting reached two ways. A spec holding
    # both (an older notebook, a hand-edited footer) would emit `--cpus-per-task` twice — which
    # sbatch tolerates by taking the last, and a reader does not. The explicit key wins over the one
    # already emitted above.
    seen = Set{String}(["job-name", "array", "output", "cpus-per-task", "mem", "time",
                        "dependency", "account", "qos"])
    for k in sort!(collect(keys(r)))
        k in (:cpus, :mem, :walltime, :account, :qos, :exclusive) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        f = sbatch_flag(k)
        if f in seen
            # An alias of something already written: replace that line rather than adding a second.
            i = findfirst(l -> startswith(l, "#SBATCH --$f="), lines)
            i === nothing || (lines[i] = "#SBATCH --$f=$(v)")
            continue
        end
        push!(seen, f)
        push!(lines, "#SBATCH --$f=$(v)")
    end
    # Account and QoS default to the SITE's (they are a property of the launcher), but a cell may
    # override them — someone with two allocations bills one sweep to each.
    for (k, site) in ((:account, l.account), (:qos, l.qos))
        v = string(get(r, k, site))
        isempty(v) || push!(lines, "#SBATCH --$(sbatch_flag(k))=$(v)")
    end
    exc = _exclusive_line(get(r, :exclusive, ""))
    exc === nothing || push!(lines, exc)
    # Site directives, verbatim and LAST so they win over everything above (sbatch takes the last
    # occurrence of a repeated option). This is what a flag whose value a cell header cannot carry
    # uses, and what makes a definition able to say everything a hand-written `#SBATCH` block said.
    append!(lines, directive_lines(spec.directives))
    append!(lines, ["set -euo pipefail",
                    "CHUNK=\$(sed -n \"\${SLURM_ARRAY_TASK_ID}p\" $(indexfile))",
                    "test -n \"\$CHUNK\"",
                    replace(task_command(spec, "\$CHUNK"), "\n" => "\n")])
    return join(lines, "\n") * "\n"
end

function submit!(l::SlurmLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    indexfile = joinpath(spec.root, "jobs", spec.name * ".index")
    script = _sbatch_script(l, spec, indexfile)
    # Write the index and the script on the far side, then submit. Heredocs keep it to one ssh
    # round trip and avoid quoting the script through two shells.
    payload = """
    set -e
    mkdir -p $(joinpath(spec.root, "jobs")) $(spec.logdir)
    cat > $(indexfile) <<'SLATE_INDEX_EOF'
    $(join(spec.chunks, "\n"))
    SLATE_INDEX_EOF
    cat > $(indexfile).sbatch <<'SLATE_SBATCH_EOF'
    $(script)SLATE_SBATCH_EOF
    sbatch --parsable $(indexfile).sbatch
    """
    ok, out = (_ssh(l, payload))
    ok || error("sbatch failed on $(l.host): $(strip(out))")
    return strip(split(strip(out), '\n')[end])
end

function poll(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return Dict{String,Symbol}()
    out = Dict{String,Symbol}(n => :unknown for n in ns)
    # One call for every name. squeue lists only live jobs, so anything absent stays :unknown and
    # the store decides whether that means finished or lost.
    ok, txt = (_ssh(l, "squeue -h -o '%j %T' --name=$(join(ns, ','))"))
    ok || return out
    for line in split(txt, '\n'; keepempty = false)
        parts = split(strip(line))
        length(parts) >= 2 || continue
        name, state = String(parts[1]), uppercase(String(parts[2]))
        haskey(out, name) || continue
        # A name with several elements in flight reports RUNNING as soon as any element runs.
        if state == "RUNNING" || out[name] === :running
            out[name] = :running
        elseif state in ("PENDING", "CONFIGURING", "REQUEUED", "RESIZING", "SUSPENDED")
            out[name] === :running || (out[name] = :pending)
        else
            out[name] === :running || (out[name] = :pending)
        end
    end
    return out
end

# ONE scancel per name. `--name` takes a single job name: `scancel --name=a,b` matches nothing and
# still EXITS 0, so batching them reported every job cancelled while the work carried on running —
# a cancel that silently keeps burning the allocation. Verified against SLURM 24.11.
#
# Sent as one ssh round trip regardless, and the count comes from what actually left the queue
# rather than from scancel's exit status, which says nothing about whether a name matched.
function cancel!(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return 0
    before = poll(l, root, ns)
    live = [n for n in ns if get(before, n, :unknown) in (:pending, :running)]
    isempty(live) && return 0
    (_ssh(l, join(("scancel --name=$(n)" for n in live), "; ")))
    after = poll(l, root, live)
    return count(n -> !(get(after, n, :unknown) in (:pending, :running)), live)
end

function logs(l::SlurmLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    ok, txt = (_ssh(l,
        "tail -n $(lines) $(joinpath(root, "logs"))/$(name).*.out 2>/dev/null"))
    return ok ? txt : ""
end

"""
    explain_failure(l::SlurmLauncher, name) -> String

Why a submission's elements ended, from accounting. Only ever consulted to explain a failure:
whether a shard is done is a question for the store, since `sacct` needs site-configured accounting
and may return nothing at all.
"""
function explain_failure(l::SlurmLauncher, name::AbstractString)
    ok, txt = (_ssh(l,
        "sacct -n -X --name=$(name) -o JobID,State,ExitCode,Elapsed,MaxRSS 2>/dev/null"))
    return ok ? txt : ""
end

end # module BatchLauncher
