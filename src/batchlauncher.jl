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

export Launcher, ExecLauncher, SlurmLauncher, PbsLauncher, JobSpec, submit!, poll, cancel!, logs

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
    directive_lines(text; prefix = "#SBATCH", example = "--constraint=avx512") -> Vector{String}

Free-form scheduler directives → directive lines. One per line; blank lines and `#` comments are
dropped, and a line may be written with or without the prefix (`--exclusive` or
`#SBATCH --exclusive`) because both are what people have in front of them when they are copying from
a working batch script. Either scheduler's prefix is accepted on input, so moving a definition
between clusters does not mean re-typing the block.

This is the escape hatch for a flag whose value contains characters a cell header cannot carry, and
for the site-specific ones there is no point naming (`--licenses`, `--switches`, `--wckey`). It is
emitted verbatim: Slate does not know what a site's flags mean and should not pretend to.
"""
function directive_lines(text::AbstractString; prefix::AbstractString = "#SBATCH",
                         example::AbstractString = "--constraint=avx512")
    out = String[]
    for raw in eachsplit(String(text), '\n')
        s = strip(raw)
        (isempty(s) || startswith(s, "# ") || s == "#") && continue
        for p in ("#SBATCH", "#PBS")
            startswith(s, p) && (s = strip(s[(length(p) + 1):end]); break)
        end
        isempty(s) && continue
        # A directive is one flag. Anything else would be a shell line in a place that only accepts
        # scheduler options, where it is silently ignored rather than run — so say so instead.
        startswith(s, "-") ||
            error("scheduler directive `$s` does not start with `-`. These are scheduler flags " *
                  "(`$example`), one per line; shell setup belongs in the cluster's prologue.")
        push!(out, prefix * " " * s)
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
    for k in sort!(collect(keys(r)))
        haskey(_SBATCH_HINT, k) && _hint_once(:SLURM, k, _SBATCH_HINT[k], "--$(sbatch_flag(k))=…")
    end
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

# ── PBS ──────────────────────────────────────────────────────────────────────────────────────
# The other scheduler a site is likely to have, and NOT a renaming of the one above. Three things
# differ in kind rather than in spelling, and each of them is a decision made below:
#
#   * PBS asks for per-node resources INSIDE a chunk statement (`-l select=2:ncpus=8:mem=16gb`) and
#     for job-wide ones beside it (`-l walltime=…`). SLURM's one-flag-per-setting form has no chunk,
#     so the pass-through rule needs a shape here, not just a different flag name.
#   * There is no `--dependency=singleton`, which is what stopped a SLURM sweep double-submitting
#     across a hub restart. PBS will happily queue two jobs of the same name, so the check the
#     scheduler used to do is done in the submission itself.
#   * Names are the interface (see the top of this file), and PBS cannot cancel by name. `qselect`
#     turns a name into ids and `qdel` takes those, which is two commands and still one round trip.
struct PbsLauncher <: Launcher
    host::String                 # the login node; "" runs the client tools locally
    account::String
    qos::String
    runner::Any                  # (host, script) -> (ok, output); the caller's authenticated session
end
PbsLauncher(host = ""; account = "", qos = "",
            runner = (h, sc) -> _local_run(sc)) =
    PbsLauncher(String(host), String(account), String(qos), runner)

_ssh(l::PbsLauncher, script::AbstractString) = l.runner(l.host, String(script))

# The settings that go INSIDE the chunk statement — what one node of the job must have.
const _PBS_CHUNK = Dict(:cpus => "ncpus", :gpus => "ngpus", :mem => "mem",
                        :ntasks_per_node => "mpiprocs", :nodelist => "host")

# Settings whose usual SLURM meaning has no PBS form. ADVISORY, not a block: the editor shows the
# note, and the option is still forwarded as `-l key=value` like any other.
#
# Refusing them outright was tried and is wrong. PBS lets a site define ARBITRARY resources
# (`qmgr -c "create resource ntasks type=long"`), so a name that means one thing on SLURM may be a
# real resource here — and blocking it because SLURM uses the word contradicts the rule at the top
# of this file. A site that has no such resource gets `Unknown resource: constraint` from `qsub`,
# which is the loud rejection that rule is asking for.
const _PBS_HINT = Dict(
    :constraint  => "usually a chunk resource on PBS — see `select=`",
    :gres        => "usually `gpus=` (a count), or `select=…:ngpus=2:gpu_model=v100`",
    :exclude     => "PBS has no exclude list — pick a queue, or name hosts with `select=`",
    :reservation => "a PBS reservation IS a queue — usually `partition=`",
    :ntasks      => "PBS counts per chunk — usually `nodes=` and `ntasks_per_node=`",
)

# `select=` is PBS's chunk statement and sbatch has no such option. Same treatment in reverse.
const _SBATCH_HINT = Dict(
    :select => "PBS's chunk statement — on SLURM say `nodes=`, `cpus=`, `mem=`, `gpus=`",
)

# Warned once per setting per process: a sweep emits a script per submission, and the same advice a
# few hundred times would bury the run's own output.
const _HINTED = Set{Tuple{Symbol,Symbol}}()
const _HINT_LOCK = ReentrantLock()

function _hint_once(kind::Symbol, k::Symbol, note::AbstractString, flag::AbstractString)
    fresh = lock(_HINT_LOCK) do; (kind, k) in _HINTED ? false : (push!(_HINTED, (kind, k)); true); end
    fresh || return nothing
    @warn "`$k` has no standard $(kind) equivalent — $(note). Sending it as `$(flag)` anyway; " *
          "$(kind) will reject it unless this site defines it."
    return nothing
end

# The settings that become something other than a job-wide `-l key=value`.
const _PBS_NAMED = (:cpus, :mem, :mem_per_cpu, :walltime, :partition, :account, :qos, :exclusive,
                    :nodes, :select)

"""
    pbs_size(v) -> String

A memory size as PBS writes it. SLURM's `16G` is not a size PBS accepts: its units are two letters
(`kb`, `mb`, `gb`, `tb`), and a bare number is bytes. Anything already in that form, or in a syntax
this does not recognise, is passed through — a site's own spelling is not ours to correct.
"""
function pbs_size(v)
    s = strip(string(v))
    m = match(r"^(\d+)\s*([kmgtKMGT]?)[bB]?$", s)
    m === nothing && return String(s)
    return string(m.captures[1], lowercase(m.captures[2]), "b")
end

const _PBS_ALWAYS = (cpus = 1, mem = "1gb", walltime = "00:30:00")

"""
    pbs_select(resources; defaults = true) -> String

The chunk statement: how many nodes, and what each must have. `select=` in the resources wins
outright — a PBS user thinks in chunk statements, and one escape hatch answers every site resource
Slate has no name for, which is why the unmappable settings above point at it.

`defaults = false` asks for only what was named. A batch job states its limits (a job at the mercy
of a site's defaults is the one whose limits kill it); an interactive allocation does not, so that
an unset memory is the queue's own default rather than a number Slate invented.
"""
function pbs_select(r; defaults::Bool = true)
    explicit = strip(string(get(r, :select, "")))
    isempty(explicit) || return String(explicit)
    ncpus = get(r, :cpus, defaults ? _PBS_ALWAYS.cpus : nothing)
    chunk = String[]
    ncpus === nothing || push!(chunk, "ncpus=$(ncpus)")
    mem = _pbs_chunk_mem(r, ncpus, defaults)
    mem === nothing || push!(chunk, "mem=$(mem)")
    for k in sort!(collect(keys(r)))
        (k === :cpus || k === :mem || !haskey(_PBS_CHUNK, k)) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        push!(chunk, string(_PBS_CHUNK[k], "=", k === :nodelist ? _pbs_host(v) : v))
    end
    n = get(r, :nodes, 1)
    return isempty(chunk) ? string(n) : string(n, ":", join(chunk, ":"))
end

# How much memory one chunk gets. `mem_per_cpu` is SLURM's spelling and PBS has no per-CPU memory,
# but a chunk holds exactly `ncpus` cpus — so the multiplication is arithmetic, not a guess, and it
# is right for a multi-chunk job too. Naming BOTH is ambiguous and SLURM rejects it as well.
function _pbs_chunk_mem(r, ncpus, defaults::Bool)
    per = strip(string(get(r, :mem_per_cpu, "")))
    flat = strip(string(get(r, :mem, "")))
    isempty(per) && return isempty(flat) ? (defaults ? _PBS_ALWAYS.mem : nothing) : pbs_size(flat)
    isempty(flat) ||
        error("`mem` and `mem_per_cpu` are both set; PBS asks for memory per chunk, so it can " *
              "honour one of them. Say `mem=` for the whole chunk, or `mem_per_cpu=` alone.")
    ncpus === nothing &&
        error("`mem_per_cpu` needs a cpu count to multiply out on PBS — set `cpus=` too.")
    m = match(r"^(\d+)([kmgt])b$", pbs_size(per))
    m === nothing &&
        error("`mem_per_cpu=$per` is not a size that can be multiplied out — say `mem=` instead.")
    return string(parse(Int, m.captures[1]) * Int(ncpus), m.captures[2], "b")
end

# `nodelist` maps only when it names ONE host: a PBS chunk is placed on a single host, so several
# would need one chunk each and there is no honest way to guess how the work should be split.
function _pbs_host(v)
    s = strip(string(v))
    (occursin(',', s) || occursin('[', s)) &&
        error("`nodelist=$s` names more than one host; a PBS chunk sits on one. Write the " *
              "placement out with `select=` (`2:ncpus=4:host=c1+1:ncpus=4:host=c2`).")
    return s
end

# `-l place=`, PBS's answer to `--exclusive`. Its vocabulary is its own (`excl`, `exclhost`,
# `shared`), so anything but a yes/no is forwarded for PBS to accept or reject.
function _pbs_place(v)
    s = strip(String(v))
    (isempty(s) || lowercase(s) in ("no", "false", "0")) && return nothing
    return lowercase(s) in ("yes", "true", "1") ? "excl" : s
end

"""
    pbs_flag(k) -> String

How a catalogued setting is spelled for PBS, for the cell editor's benefit. Empty when PBS has no
way to say it — which the editor shows rather than pretending the setting will be honoured.
"""
pbs_flag(k::Symbol) =
    haskey(_PBS_HINT, k)     ? "" :
    haskey(_PBS_CHUNK, k)    ? "select=…:" * _PBS_CHUNK[k] :
    k === :walltime          ? "-l walltime" :
    k === :partition         ? "-q" :
    k === :account           ? "-A" :
    k === :nodes             ? "-l select=N:…" :
    k === :exclusive         ? "-l place" :
    # No per-CPU memory on PBS: it becomes the chunk's `mem`, multiplied by its cpu count.
    k === :mem_per_cpu       ? "select=…:mem (×ncpus)" :
    "-l " * String(k)

# `$PBS_ARRAY_INDEX` picks this element's chunk out of the index file, the same trick the sbatch
# script plays with `$SLURM_ARRAY_TASK_ID`.
function _pbs_script(l::PbsLauncher, spec::JobSpec, indexfile::AbstractString)
    r = spec.resources
    for k in sort!(collect(keys(r)))
        haskey(_PBS_HINT, k) && _hint_once(:PBS, k, _PBS_HINT[k], "-l $(k)=$(get(r, k, ""))")
    end
    lines = ["#!/bin/bash",
             "#PBS -N $(spec.name)",
             # One file, not two: PBS spools stdout and stderr separately otherwise.
             "#PBS -j oe"]
    # Naming the output is three-way, and only one of them is right. Measured on OpenPBS 23.06:
    #
    #   -o <dir>/                          PBS names the file after the JOB ID, which is the one
    #                                      thing the fabric never keeps — `logs` is asked for a
    #                                      NAME, so it would find nothing, ever.
    #   -o <dir>/<name>.out                every element of the array writes to that ONE file.
    #                                      Silently, which makes it the worst of the three.
    #   -o <dir>/<name>.^array_index^.out  one file per element, where we asked for it.
    #
    # `^array_index^` is PBS Pro / OpenPBS (Altair's token for array output paths), not TORQUE. A
    # TORQUE site would have to fall back on the default naming — no `-o` at all gives
    # `$HOME/<name>.o<seq>.<index>`, which is findable by name but ignores `logdir`.
    #
    # A one-element array is not an array (PBS rejects the degenerate range), so the index is read
    # with a default and its log is named as though it were element 1 — one glob finds either.
    if length(spec.chunks) > 1
        push!(lines, "#PBS -J 1-$(length(spec.chunks))",
                     "#PBS -o $(spec.logdir)/$(spec.name).^array_index^.out")
    else
        push!(lines, "#PBS -o $(spec.logdir)/$(spec.name).1.out")
    end
    push!(lines, "#PBS -l select=$(pbs_select(r))")
    push!(lines, "#PBS -l walltime=$(get(r, :walltime, _PBS_ALWAYS.walltime))")
    q = strip(string(get(r, :partition, "")))
    isempty(q) || push!(lines, "#PBS -q $(q)")
    acct = strip(string(get(r, :account, l.account)))
    isempty(acct) || push!(lines, "#PBS -A $(acct)")
    # Job-wide resources: QoS if the site has one, exclusivity, and then everything the spec carries
    # that is not a chunk resource and not named above. Sorted, so two identical sweeps produce
    # identical scripts and the content-derived name keeps matching what was submitted.
    wide = Pair{String,String}[]
    qos = strip(string(get(r, :qos, l.qos)))
    isempty(qos) || push!(wide, "qos" => qos)
    pl = _pbs_place(get(r, :exclusive, ""))
    pl === nothing || push!(wide, "place" => pl)
    for k in sort!(collect(keys(r)))
        (k in _PBS_NAMED || haskey(_PBS_CHUNK, k)) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        # PBS resource names carry underscores (`min_walltime`, `scratch_local`), so unlike sbatch's
        # long options they pass through exactly as written.
        push!(wide, String(k) => string(v))
    end
    for (k, v) in wide; push!(lines, "#PBS -l $(k)=$(v)"); end
    # Site directives, verbatim and LAST, for the same reason as the sbatch script.
    append!(lines, directive_lines(spec.directives; prefix = "#PBS",
                                   example = "-l scratch_local=10gb"))
    append!(lines, ["set -euo pipefail",
                    "CHUNK=\$(sed -n \"\${PBS_ARRAY_INDEX:-1}p\" $(indexfile))",
                    "test -n \"\$CHUNK\"",
                    task_command(spec, "\$CHUNK")])
    return join(lines, "\n") * "\n"
end

function submit!(l::PbsLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    indexfile = joinpath(spec.root, "jobs", spec.name * ".index")
    script = _pbs_script(l, spec, indexfile)
    # The `qselect` guard is what `--dependency=singleton` does on SLURM: the hub can restart, or two
    # notebooks can reconcile the same sweep, and the name is content-derived either way. Without it
    # the second reconcile queues the work twice and both copies write the same shards.
    payload = """
    set -e
    mkdir -p $(joinpath(spec.root, "jobs")) $(spec.logdir)
    cat > $(indexfile) <<'SLATE_INDEX_EOF'
    $(join(spec.chunks, "\n"))
    SLATE_INDEX_EOF
    cat > $(indexfile).pbs <<'SLATE_PBS_EOF'
    $(script)SLATE_PBS_EOF
    if [ -n "\$(qselect -N $(spec.name) -u \"\$USER\" 2>/dev/null)" ]; then
      echo SLATE_ALREADY
      exit 0
    fi
    qsub $(indexfile).pbs
    """
    ok, out = (_ssh(l, payload))
    ok || error("qsub failed on $(l.host): $(strip(out))")
    id = strip(split(strip(out), '\n')[end])
    return id == "SLATE_ALREADY" ? "" : String(id)
end

# One `qstat -f` for the user's jobs, parsed by name. PBS has no `--name` filter, and asking per name
# would be one command per sweep unit — which is exactly the cost `poll` is documented not to have.
# An array job appears ONCE, under its own name, which is the entry we want; its elements are only
# visible with `-t` and the store answers for them anyway.
#
# `qselect` FIRST, and not `qstat -f -u "$USER"`: `-u` silently overrides `-f` and prints the short
# table instead, which has no Job_Name column — so every name parses as absent and a running sweep
# reads as one that never started. Verified against OpenPBS 23.06. `set -f` because an array job's
# id contains `[]`, which the shell would otherwise try to glob.
#
# Attributes are accumulated per JOB BLOCK rather than read in order: `qstat -f` emits them in
# whatever order the server holds them, and `resources_used` lands before `job_state`.
const _PBS_POLL = raw"""
set -f
ids=$(qselect -u "$USER" 2>/dev/null)
[ -n "$ids" ] || exit 0
qstat -f $ids 2>/dev/null | awk '
  function out() { if (n != "") print n " " s; n = ""; s = "" }
  /^Job Id:/                    { out() }
  /^[ \t]*Job_Name = /          { n = substr($0, index($0, "= ") + 2); sub(/[ \t\r]+$/, "", n) }
  /^[ \t]*job_state = /         { s = substr($0, index($0, "= ") + 2); sub(/[ \t\r]+$/, "", s) }
  END                           { out() }'
"""

# PBS's single-letter states. `B` is an array job with elements running, `E` a job on its way out —
# both are still live, and only a job the scheduler no longer holds leaves a name `:unknown`.
_pbs_state(s::AbstractString) =
    s in ("R", "B", "E") ? :running :
    s in ("Q", "H", "W", "T", "S", "M") ? :pending : :unknown

function poll(l::PbsLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return Dict{String,Symbol}()
    out = Dict{String,Symbol}(n => :unknown for n in ns)
    ok, txt = (_ssh(l, _PBS_POLL))
    ok || return out
    for line in split(txt, '\n'; keepempty = false)
        parts = split(strip(line))
        length(parts) >= 2 || continue
        name = String(parts[1])
        haskey(out, name) || continue
        st = _pbs_state(uppercase(String(parts[2])))
        st === :unknown && continue
        out[name] === :running || (out[name] = st)
    end
    return out
end

# `qdel` takes ids, so each name is resolved first — and that is also what makes the count honest
# here without a second poll: `qselect` lists only live jobs, so a name it answers for was live, and
# `qdel`'s exit status says whether it was acted on.
#
# Deliberately NOT the SLURM shape of re-polling to see what left. A cancelled PBS job goes to `E`
# (exiting) before it disappears, so a poll taken straight after a successful `qdel` still reports it
# live and every cancel would report zero. SLURM re-polls because `scancel` exits 0 whether or not a
# name matched anything; PBS hands us ids instead, which is a better answer to the same question.
function cancel!(l::PbsLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return 0
    ok, out = (_ssh(l, join(("ids=\$(qselect -N $(n) -u \"\$USER\" 2>/dev/null); " *
                             "[ -n \"\$ids\" ] && qdel \$ids >/dev/null 2>&1 && echo CANCELLED"
                             for n in ns), "\n")))
    return count(==("CANCELLED"), strip.(split(out, '\n'; keepempty = false)))
end

# Only after the job ENDS: PBS spools output on the execution node and copies it back at exit, where
# SLURM writes it live. Per-unit progress comes from the status directory either way, so this is for
# reading what a finished job said — which is when it is asked for.
function logs(l::PbsLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    ok, txt = (_ssh(l,
        "tail -n $(lines) $(joinpath(root, "logs"))/$(name).*.out 2>/dev/null"))
    return ok ? txt : ""
end

"""
    explain_failure(l::PbsLauncher, name) -> String

Why a submission's elements ended, from job history — PBS's answer to `sacct`, and with the same
caveat: `qstat -x` needs the server's `job_history_enable` set, so it may return nothing at all.
Only ever consulted to explain a failure; whether a shard is done is a question for the store.
"""
function explain_failure(l::PbsLauncher, name::AbstractString)
    ok, txt = (_ssh(l,
        "for j in \$(qselect -x -N $(name) -u \"\$USER\" 2>/dev/null); do " *
        "qstat -x -f \"\$j\" 2>/dev/null | " *
        "grep -E 'Job Id|job_state|Exit_status|resources_used'; done"))
    return ok ? txt : ""
end

end # module BatchLauncher
