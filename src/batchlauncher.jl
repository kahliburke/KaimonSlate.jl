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
    resources::NamedTuple        # (; cpus, mem, walltime, partition)
    logdir::String
    prologue::String             # shell run before julia: `module load`, depot exports, ...
end

JobSpec(name, chunks; root, project, payload, julia = "julia",
        resources = (; cpus = 1, mem = "1G", walltime = "00:30:00", partition = ""),
        logdir = joinpath(root, "logs"), prologue = "") =
    JobSpec(String(name), String.(collect(chunks)), String(root), String(project),
            String(payload), String(julia), resources, String(logdir), String(prologue))

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
function task_command(spec::JobSpec, chunk::AbstractString)
    pre = isempty(spec.prologue) ? "" : spec.prologue * "\n"
    return string(pre,
        "export JULIA_PKG_PRECOMPILE_AUTO=0\n",
        spec.julia, " --project=", spec.project, " --startup-file=no ",
        "-e 'include(\"", spec.payload, "\"); exit(SlateTask.main(ARGS))' ",
        spec.root, " ", chunk)
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
ExecLauncher(; maxproc::Int = max(1, Sys.CPU_THREADS - 1)) = ExecLauncher(maxproc)

_jobdir(root) = joinpath(root, "jobs")
_jobfile(root, name) = joinpath(_jobdir(root), name)

_alive(pid::Integer) = pid > 0 && try
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
catch
    false
end

function submit!(l::ExecLauncher, spec::JobSpec)
    mkpath(_jobdir(spec.root)); mkpath(spec.logdir)
    pids = Int[]
    for (i, chunk) in enumerate(spec.chunks)
        logf = joinpath(spec.logdir, "$(spec.name).$(i).log")
        cmd = pipeline(Cmd(`sh -c $(task_command(spec, chunk))`); stdout = logf, stderr = logf)
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
    host::String                 # ssh target for the login node; "" runs the client tools locally
    account::String
    qos::String
    ssh_opts::Vector{String}
end
SlurmLauncher(host = ""; account = "", qos = "",
              ssh_opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]) =
    SlurmLauncher(String(host), String(account), String(qos), String.(ssh_opts))

# An empty host means the SLURM client tools are on THIS machine, which is the case when Slate runs
# on a login node (a common enough deployment that it should not need a loopback ssh) and when the
# reconciler itself runs inside the cluster. Everything else about the backend is identical, so the
# two cases differ only in how a command is wrapped.
_ssh(l::SlurmLauncher, script::AbstractString) =
    isempty(l.host) ? `sh -c $script` : `ssh $(l.ssh_opts) $(l.host) $script`

function _run_capture(cmd::Cmd)
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

# The batch script. `$SLURM_ARRAY_TASK_ID` picks this element's chunk out of the index file, so one
# script serves every element and the mapping lives on the shared filesystem rather than in the
# submission.
function _sbatch_script(l::SlurmLauncher, spec::JobSpec, indexfile::AbstractString)
    r = spec.resources
    part = get(r, :partition, "")
    lines = ["#!/bin/bash",
             "#SBATCH --job-name=$(spec.name)",
             "#SBATCH --array=1-$(length(spec.chunks))",
             "#SBATCH --output=$(spec.logdir)/$(spec.name).%A_%a.out",
             "#SBATCH --cpus-per-task=$(get(r, :cpus, 1))",
             "#SBATCH --mem=$(get(r, :mem, "1G"))",
             "#SBATCH --time=$(get(r, :walltime, "00:30:00"))",
             # Duplicate submission across a hub restart is prevented by the cluster itself: only
             # one job of this name per user can run, and the name is content-derived.
             "#SBATCH --dependency=singleton"]
    # Account and QoS are properties of the SITE, not of one sweep, so they live on the launcher.
    isempty(part)      || push!(lines, "#SBATCH --partition=$(part)")
    isempty(l.account) || push!(lines, "#SBATCH --account=$(l.account)")
    isempty(l.qos)     || push!(lines, "#SBATCH --qos=$(l.qos)")
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
    ok, out = _run_capture(_ssh(l, payload))
    ok || error("sbatch failed on $(l.host): $(strip(out))")
    return strip(split(strip(out), '\n')[end])
end

function poll(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return Dict{String,Symbol}()
    out = Dict{String,Symbol}(n => :unknown for n in ns)
    # One call for every name. squeue lists only live jobs, so anything absent stays :unknown and
    # the store decides whether that means finished or lost.
    ok, txt = _run_capture(_ssh(l, "squeue -h -o '%j %T' --name=$(join(ns, ','))"))
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

function cancel!(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return 0
    ok, _ = _run_capture(_ssh(l, "scancel --name=$(join(ns, ','))"))
    return ok ? length(ns) : 0
end

function logs(l::SlurmLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    ok, txt = _run_capture(_ssh(l,
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
    ok, txt = _run_capture(_ssh(l,
        "sacct -n -X --name=$(name) -o JobID,State,ExitCode,Elapsed,MaxRSS 2>/dev/null"))
    return ok ? txt : ""
end

end # module BatchLauncher
