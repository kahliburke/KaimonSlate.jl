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
#
# The FLOW is the same on either scheduler and the commands are not, so the flow is written once and
# each scheduler contributes three scripts: find, request, release.

"""
    Allocation

What the scheduler is holding for us, if anything. `node` is empty until it is `:running` — that is
the whole point: the host is not knowable in advance.

`:unreachable` is a separate state from `:none` and the distinction matters more than it looks: one
means the scheduler answered and is holding nothing, the other means nobody answered. Collapsing
them reports a cluster that is switched off as a queue that is merely busy, which sends you reading
`squeue` documentation about a problem that is really `ssh`.
"""
struct Allocation
    name::String        # the job name we look it up by
    id::String          # scheduler job id ("" when there is none)
    state::Symbol       # :running | :pending | :none | :unreachable
    node::String        # the compute host, once it exists
    timeleft::String    # what the scheduler says is left, for display
end

Base.show(io::IO, a::Allocation) =
    a.state === :unreachable ? print(io, "Allocation(", a.name, ": host unreachable)") :
    a.state === :none ? print(io, "Allocation(", a.name, ": none)") :
    print(io, "Allocation(", a.name, " #", a.id, " ", a.state,
          isempty(a.node) ? "" : " on " * a.node,
          isempty(a.timeleft) ? "" : ", " * a.timeleft * " left", ")")

"Is this allocation usable right now — a node exists and the scheduler says it is ours?"
alive(a::Allocation) = a.state === :running && !isempty(a.node)

"Is there nothing more to wait for — the scheduler holds nothing, or could not be asked?"
settled(a::Allocation) = a.state === :none || a.state === :unreachable

"""
    sched_seconds(s) -> Float64

A scheduler time — `HH:MM:SS`, `D-HH:MM:SS`, `MM:SS`, a bare `MM`, or UNLIMITED — in seconds.
Anything unrecognised reads as an hour, which at worst costs one extra round trip.
"""
function sched_seconds(s::AbstractString)
    t = strip(String(s))
    isempty(t) && return 3600.0
    uppercase(t) in ("UNLIMITED", "INFINITE", "NOT_SET") && return Inf
    days = 0.0
    i = findfirst('-', t)
    if i !== nothing
        days = something(tryparse(Float64, t[1:prevind(t, i)]), 0.0)
        t = t[nextind(t, i):end]
    end
    f = [tryparse(Float64, p) for p in split(t, ':')]
    any(isnothing, f) && return 3600.0
    secs = length(f) == 3 ? f[1] * 3600 + f[2] * 60 + f[3] :
           length(f) == 2 ? f[1] * 60 + f[2] :
           length(f) == 1 ? f[1] * 60 : 0.0
    return days * 86400 + secs
end

"Seconds as `HH:MM:SS`, the form both schedulers display."
function hms(secs::Real)
    isfinite(secs) || return ""
    s = max(0, round(Int, secs))
    return string(lpad(s ÷ 3600, 2, '0'), ":", lpad((s % 3600) ÷ 60, 2, '0'), ":",
                  lpad(s % 60, 2, '0'))
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
    pbs_first_node(exec_host) -> String

The first hostname out of a PBS `exec_host` — `c1/0*4+c2/0` → `c1`. A different syntax from SLURM's
compressed list rather than a variant of it, so it is a different function and not a flag.
"""
function pbs_first_node(s::AbstractString)
    s = strip(String(s))
    isempty(s) && return ""
    return String(first(split(first(split(s, '+')), '/')))
end

# ── Asking a scheduler what it holds ─────────────────────────────────────────────────────────

# SLURM answers in one line per job, which is what `-o` is for.
_slurm_find_script(name) =
    "squeue -h -n " * shq(name) * " -o '%i|%T|%N|%L' 2>/dev/null"

# PBS has no per-name query and no output format of its own, so one `qstat -f` is filtered by name
# into the same five fields. `%L` has no equivalent either: what is LEFT is the walltime asked for
# minus the walltime used, and both are attributes on the job.
#
# `qselect` first for the reason `BatchLauncher._PBS_POLL` gives: `-u` silently overrides `-f`.
_pbs_find_script(name) = """
set -f
ids=\$(qselect -u "\$USER" 2>/dev/null)
[ -n "\$ids" ] || exit 0
qstat -f \$ids 2>/dev/null | awk -v want=$(shq(name)) '
  function out() {
    if (n == want && n != "") print id "|" s "|" eh "|" wt "|" used
    id = ""; n = ""; s = ""; eh = ""; wt = ""; used = ""
  }
  function val()  { v = substr(\$0, index(\$0, "= ") + 2); sub(/[ \\t\\r]+\$/, "", v); return v }
  /^Job Id:/                            { out(); id = substr(\$0, index(\$0, ":") + 2); sub(/[ \\t\\r]+\$/, "", id) }
  /^[ \\t]*Job_Name = /                  { n = val() }
  /^[ \\t]*job_state = /                 { s = val() }
  /^[ \\t]*exec_host = /                 { eh = val() }
  /^[ \\t]*Resource_List.walltime = /    { wt = val() }
  /^[ \\t]*resources_used.walltime = /   { used = val() }
  END                                   { out() }'
"""

# SLURM's job states, and PBS's single letters. Both collapse to the three an allocation can be in:
# ours, queued, or gone. Anything ending (SLURM's COMPLETING, PBS's `E`) is treated as gone, because
# a node that is being torn down is not one to place a worker on.
_slurm_alloc_state(st) =
    st == "RUNNING" ? :running : (st in ("PENDING", "CONFIGURING") ? :pending : :none)
_pbs_alloc_state(st) =
    st == "R" ? :running : (st in ("Q", "H", "W", "T", "S", "B") ? :pending : :none)

"""
    find_allocation(kind, host, name) -> Allocation

What the scheduler is holding under this job name. `host` is where the scheduler's client tools are
— a login node, or `""` for this machine. One round trip, so it is cheap enough to ask before every
use, which is the point: an allocation can expire between two cells.
"""
function find_allocation(kind::Symbol, host::AbstractString, name::AbstractString)
    script = kind === :slurm ? _slurm_find_script(name) :
             kind === :pbs   ? _pbs_find_script(name) : _unsupported_scheduler(kind)
    ok, out = run_there(host, script)
    # Nobody answered. NOT the same as "the scheduler holds nothing for you" — see `Allocation`.
    ok || return Allocation(String(name), "", :unreachable, "", "")
    for line in split(strip(out), '\n')
        f = split(strip(line), '|')
        length(f) >= 3 && !isempty(strip(f[1])) || continue
        st = uppercase(strip(f[2]))
        state = kind === :slurm ? _slurm_alloc_state(st) : _pbs_alloc_state(st)
        state === :none && continue
        # SLURM's `%N` is a node LIST in its compressed form ("c[1-4]") and PBS's `exec_host` names
        # a cpu on each node ("c1/0*4"); either way the first name is the one a single-node
        # interactive allocation runs on, and expanding the rest is not this layer's job.
        node = state !== :running ? "" :
               kind === :slurm ? first_node(strip(f[3])) : pbs_first_node(strip(f[3]))
        left = length(f) >= 4 ? String(strip(f[4])) : ""
        kind === :pbs && (left = _pbs_timeleft(left, length(f) >= 5 ? strip(f[5]) : ""))
        return Allocation(String(name), String(strip(f[1])), state, node, left)
    end
    return Allocation(String(name), "", :none, "", "")
end

# What is left of a PBS allocation, which the scheduler does not report directly.
function _pbs_timeleft(total::AbstractString, used::AbstractString)
    isempty(strip(String(total))) && return ""
    t = sched_seconds(total)
    isfinite(t) || return ""
    u = isempty(strip(String(used))) ? 0.0 : sched_seconds(used)
    return hms(max(0.0, t - u))
end

# ── Asking for one ───────────────────────────────────────────────────────────────────────────

# `--no-shell` because Slate wants the RESERVATION, not a login session on it: the worker gets there
# over ssh, and a shell nobody is attached to would just be something else to clean up.
function _slurm_request_script(name; walltime, partition, cpus, mem, gpus, account, extra)
    args = String["--no-shell", "-J", shq(name), "-t", shq(walltime)]
    cpus > 0 && append!(args, ["-n", string(cpus)])
    isempty(partition) || append!(args, ["-p", shq(partition)])
    isempty(mem)       || append!(args, ["--mem", shq(mem)])
    isempty(gpus)      || append!(args, ["--gpus", shq(gpus)])
    isempty(account)   || append!(args, ["-A", shq(account)])
    isempty(extra)     || push!(args, extra)
    return "salloc " * join(args, " ") * " 2>&1"
end

# PBS has NO `--no-shell`, and that is the one real difference between the two: there is no way to
# ask it to hold a node without running something on it. So the reservation is a job that sleeps —
# the node is held for as long as the job lives, and PBS ends the job at its walltime, which is
# exactly the lease `salloc` would have given. The sleep only has to outlast that.
function _pbs_request_script(name; walltime, partition, cpus, mem, gpus, account, extra)
    res = Dict{Symbol,Any}()
    cpus > 0 && (res[:cpus] = cpus)
    isempty(mem)  || (res[:mem] = String(mem))
    isempty(gpus) || (res[:gpus] = String(gpus))
    # `defaults = false`: an allocation states only what was asked for, so an unset memory is the
    # queue's own default rather than a number Slate invented — the same as `salloc` above.
    sel = BatchLauncher.pbs_select(NamedTuple(res); defaults = false)
    args = String["-N", shq(name), "-l", shq("select=" * sel), "-l", shq("walltime=" * walltime)]
    isempty(partition) || append!(args, ["-q", shq(partition)])
    isempty(account)   || append!(args, ["-A", shq(account)])
    isempty(extra)     || push!(args, extra)
    return """
    qsub $(join(args, " ")) 2>&1 <<'SLATE_HOLD_EOF'
    #!/bin/sh
    # Slate holds this node for a notebook. PBS ends the job at its walltime.
    sleep 2147483647
    SLATE_HOLD_EOF
    """
end

"""
    request_allocation!(kind, host, name; resources...) -> Allocation

Ask for an allocation and return once the scheduler has decided, or `:pending` if it has not yet.

Idempotent by name: an allocation that already exists is returned rather than duplicated.
"""
function request_allocation!(kind::Symbol, host::AbstractString, name::AbstractString;
                             walltime::AbstractString = "01:00:00",
                             partition::AbstractString = "",
                             cpus::Integer = 1, mem::AbstractString = "",
                             gpus::AbstractString = "", account::AbstractString = "",
                             extra::AbstractString = "")
    cur = find_allocation(kind, host, name)
    cur.state === :none || return cur   # already held, or unreachable — either way, do not submit
    mk = kind === :slurm ? _slurm_request_script :
         kind === :pbs   ? _pbs_request_script : _unsupported_scheduler(kind)
    ok, out = run_there(host, mk(name; walltime, partition, cpus, mem, gpus, account, extra))
    ok || @debug "allocation request failed" kind out
    return find_allocation(kind, host, name)
end

_slurm_release_script(name) = "scancel -n " * shq(name) * " 2>&1"
# `qdel` takes ids, not names, so the name is resolved first — one round trip either way.
_pbs_release_script(name) =
    "ids=\$(qselect -N " * shq(name) * " -u \"\$USER\" 2>/dev/null); " *
    "[ -n \"\$ids\" ] && qdel \$ids 2>&1"

"""
    release_allocation!(kind, host, name) -> Bool

Give it back. Worth doing the moment the interactive work is done: an allocation bills for the time
it is held, not the time it is used, and the commonest way to waste a cluster is to forget one.
"""
function release_allocation!(kind::Symbol, host::AbstractString, name::AbstractString)
    a = find_allocation(kind, host, name)
    settled(a) && return false          # nothing held, or nobody to tell
    script = kind === :slurm ? _slurm_release_script(name) :
             kind === :pbs   ? _pbs_release_script(name) : _unsupported_scheduler(kind)
    ok, _ = run_there(host, script)
    return ok
end

"""
How long to leave between asking the scheduler whether it has granted our node yet.

Every one of these is a command on a shared login node, and a queue wait is minutes to hours — so a
fixed short interval spends thousands of them to learn nothing, and is the kind of thing sites
notice. But the COMMON case is a cluster with room, which answers in the first few seconds, and
making that case wait would be felt on every run.

So: fast while the answer is plausibly imminent, then back off toward a cadence that costs nothing
to keep up for an hour. A wait long enough to reach the ceiling is one where fifteen seconds of
pickup latency is not the thing you are waiting for.
"""
const _POLL_BACKOFF = (first = 2.0, ceiling = 15.0, growth = 1.6, fast_for = 20.0)

# The gap before the next ask, given how long this allocation has been waited on ALTOGETHER.
function _poll_gap(waited::Real)
    waited <= _POLL_BACKOFF.fast_for && return _POLL_BACKOFF.first
    grown = _POLL_BACKOFF.first *
            _POLL_BACKOFF.growth^((waited - _POLL_BACKOFF.fast_for) / _POLL_BACKOFF.fast_for)
    return min(grown, _POLL_BACKOFF.ceiling)
end

# Altogether, and not just for this attempt. `allocation_node!` returns after `wait_s` and its caller
# starts it again, so a backoff measured from the top of the function would restart on every attempt
# — an hour-long queue wait would keep re-paying the fast phase and never reach the ceiling, which is
# the opposite of what a backoff is for. Keyed by the allocation, cleared when it stops pending.
const _WAIT_SINCE = Dict{Tuple{Symbol,String,String},Float64}()
const _WAIT_LOCK = ReentrantLock()
_waiting_since(key) = lock(_WAIT_LOCK) do; get!(_WAIT_SINCE, key, time()); end
_waited_enough!(key) = (lock(_WAIT_LOCK) do; delete!(_WAIT_SINCE, key); end; nothing)

"""
    allocation_node!(kind, host, name; wait_s = 120, resources...) -> Allocation

The whole flow: attach to an allocation under this name, or ask for one, then wait for it to be
running so its node is known. This is what a region on a compute node has to call before it can
say where the worker goes.

Polls on a backoff (`_POLL_BACKOFF`) rather than a fixed interval — see there for why.

Returns a `:pending` allocation if the queue has not granted it within `wait_s` — which is not a
failure, just a cluster that is busy; the caller polls again later rather than giving up.
"""
function allocation_node!(kind::Symbol, host::AbstractString, name::AbstractString;
                          wait_s::Real = 120, kw...)
    key = (kind, String(host), String(name))
    a = request_allocation!(kind, host, name; kw...)
    (alive(a) || settled(a)) && (_waited_enough!(key); return a)   # granted, gone, or unreachable
    since = _waiting_since(key)                # stamped on the first attempt, inherited by the rest
    deadline = time() + wait_s
    while true
        left = deadline - time()
        left > 0 || break
        # Never sleep past the deadline: the caller gave a budget, and overrunning it by most of a
        # backed-off gap would make a short `wait_s` mean something other than what it says.
        sleep(min(_poll_gap(time() - since), left))
        a = find_allocation(kind, host, name)
        (alive(a) || settled(a)) && (_waited_enough!(key); return a)
    end
    return a                                   # still pending — the caller asks again later
end

# Kubernetes and the rest answer all three of these differently again, and detection only ever
# reports a scheduler it found the client tools for. Erroring here is how a kind that reached this
# far stays honest rather than being issued commands some other scheduler has never heard of.
_unsupported_scheduler(kind) =
    error("this build allocates on SLURM and PBS; `$kind` is not one of them")
