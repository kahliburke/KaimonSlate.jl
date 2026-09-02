# ── Working inside an allocation ─────────────────────────────────────────────────────────────
#
# A batch sweep submits work and walks away. The other half of cluster work is the opposite: hold a
# piece of the machine and poke at it — run a few time steps, look at the output, edit the code, run
# it again. That needs a worker ON a compute node, and a compute node is not something you can just
# ssh to:
#
#   * you do not get one until the scheduler gives you one, and
#   * WHICH one you get is decided then, not now. The hostname is an output of the allocation.
#
# So a region on a compute node cannot be a fixed address. It is: ask the scheduler for an
# allocation, find out where it landed, and put the worker there — then let it go when the work is
# done, because an allocation you forgot to release is an allocation you are paying for.
#
# ATTACH BEFORE REQUEST. A distinctive job name makes an existing allocation findable, which is what
# lets a notebook reopen onto the one it was already using instead of asking for a second. That is
# the trick a user of a real cluster already does by hand.

"""
    Allocation

What the scheduler is holding for us, if anything. `node` is empty until it is `:running` — that is
the whole point: the host is not knowable in advance.
"""
struct Allocation
    name::String        # the job name we look it up by
    id::String          # scheduler job id ("" when there is none)
    state::Symbol       # :running | :pending | :none
    node::String        # the compute host, once it exists
    timeleft::String    # what the scheduler says is left, for display
end

Base.show(io::IO, a::Allocation) =
    a.state === :none ? print(io, "Allocation(", a.name, ": none)") :
    print(io, "Allocation(", a.name, " #", a.id, " ", a.state,
          isempty(a.node) ? "" : " on " * a.node,
          isempty(a.timeleft) ? "" : ", " * a.timeleft * " left", ")")

"Is this allocation usable right now — a node exists and the scheduler says it is ours?"
alive(a::Allocation) = a.state === :running && !isempty(a.node)

"""
    find_allocation(host, name) -> Allocation

What the scheduler is holding under this job name. `host` is where the scheduler's client tools are
— a login node, or `""` for this machine. One `squeue` call, so it is cheap enough to ask before
every use, which is the point: an allocation can expire between two cells.
"""
function find_allocation(host::AbstractString, name::AbstractString)
    ok, out = run_there(host, "squeue -h -n " * shq(name) * " -o '%i|%T|%N|%L' 2>/dev/null")
    ok || return Allocation(String(name), "", :none, "", "")
    for line in split(strip(out), '\n')
        f = split(strip(line), '|')
        length(f) >= 3 && !isempty(strip(f[1])) || continue
        st = uppercase(strip(f[2]))
        state = st == "RUNNING" ? :running : (st in ("PENDING", "CONFIGURING") ? :pending : :none)
        state === :none && continue
        # `%N` is a node LIST in SLURM's compressed form ("c[1-4]"); the first name is the one a
        # single-node interactive allocation runs on, and expanding the rest is not this layer's job.
        node = state === :running ? first_node(strip(f[3])) : ""
        left = length(f) >= 4 ? String(strip(f[4])) : ""
        return Allocation(String(name), String(strip(f[1])), state, node, left)
    end
    return Allocation(String(name), "", :none, "", "")
end

"""
    first_node(nodelist) -> String

The first hostname out of a scheduler's compressed node list: `c[1-4]` → `c1`, `n[03,07]` → `n03`,
a bare `c1` → `c1`. Pure, so the range syntax is testable without a scheduler.
"""
function first_node(s::AbstractString)
    s = strip(String(s))
    isempty(s) && return ""
    m = match(r"^([^\[,]+)\[([^\]]+)\]", s)
    m === nothing && return String(first(split(s, ','), 1)[1])
    prefix, spec = m.captures[1], m.captures[2]
    firstspec = String(first(split(spec, ',')))
    return prefix * String(first(split(firstspec, '-')))
end

"""
    request_allocation!(host, name; resources...) -> Allocation

Ask for an allocation and return once the scheduler has decided, or `:pending` if it has not yet.
`--no-shell` because Slate wants the RESERVATION, not a login session on it: the worker gets there
over ssh, and a shell nobody is attached to would just be something else to clean up.

Idempotent by name: an allocation that already exists is returned rather than duplicated.
"""
function request_allocation!(host::AbstractString, name::AbstractString;
                             walltime::AbstractString = "01:00:00",
                             partition::AbstractString = "",
                             cpus::Integer = 1, mem::AbstractString = "",
                             gpus::AbstractString = "", account::AbstractString = "",
                             extra::AbstractString = "")
    cur = find_allocation(host, name)
    cur.state === :none || return cur
    args = String["--no-shell", "-J", shq(name), "-t", shq(walltime)]
    cpus > 0 && append!(args, ["-n", string(cpus)])
    isempty(partition) || append!(args, ["-p", shq(partition)])
    isempty(mem)       || append!(args, ["--mem", shq(mem)])
    isempty(gpus)      || append!(args, ["--gpus", shq(gpus)])
    isempty(account)   || append!(args, ["-A", shq(account)])
    isempty(extra)     || push!(args, extra)
    ok, out = run_there(host, "salloc " * join(args, " ") * " 2>&1")
    ok || @debug "salloc failed" out
    return find_allocation(host, name)
end

"""
    release_allocation!(host, name) -> Bool

Give it back. Worth doing the moment the interactive work is done: an allocation bills for the time
it is held, not the time it is used, and the commonest way to waste a cluster is to forget one.
"""
function release_allocation!(host::AbstractString, name::AbstractString)
    a = find_allocation(host, name)
    a.state === :none && return false
    ok, _ = run_there(host, "scancel -n " * shq(name) * " 2>&1")
    return ok
end

"""
    allocation_node!(host, name; wait_s = 120, resources...) -> Allocation

The whole flow: attach to an allocation under this name, or ask for one, then wait for it to be
running so its node is known. This is what a region on a compute node has to call before it can
say where the worker goes.

Returns a `:pending` allocation if the queue has not granted it within `wait_s` — which is not a
failure, just a cluster that is busy; the caller polls again later rather than giving up.
"""
function allocation_node!(host::AbstractString, name::AbstractString; wait_s::Real = 120, kw...)
    a = request_allocation!(host, name; kw...)
    alive(a) && return a
    deadline = time() + wait_s
    while time() < deadline
        sleep(2)
        a = find_allocation(host, name)
        alive(a) && return a
        a.state === :none && return a          # it went away — do not spin on nothing
    end
    return a
end

# PBS holds a node the same way in principle and with entirely different commands (`qsub`/`qstat`/
# `qdel`, and no `--no-shell` equivalent — the usual trick is a job that just sleeps out its
# walltime). Detection already reports PBS, so a region can be CONFIGURED for it; erroring here is
# how it stays honest about the half that does not exist rather than issuing SLURM commands to a
# scheduler that has never heard of them.
_unsupported_scheduler(kind) =
    error("this build allocates on SLURM only; `$kind` is detected and configurable, but its " *
          "allocation commands are not implemented")
