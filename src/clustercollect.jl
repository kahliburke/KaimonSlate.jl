# ── What a cluster is doing, asked once ──────────────────────────────────────────────────────
# Everything watching a cluster wants the same two or three answers, and each asker used to go and
# get them itself. A sweep card polls every few seconds; a page with four cards asked a login node
# for the same scheduler state four times a tick, pulled the same metadata four times, and the
# cluster panel and the log viewer added their own on top.
#
# So the answers are cached per cluster and the first caller inside the window pays for them. Not a
# change of mechanism: the same commands over the same session the hub already holds. Deliberately
# NOT authoritative — the event log is still the truth and this sits in front of the transport, so
# a stale entry costs a reader a few seconds of lag and can never cost correctness.
#
# No background task and nothing to subscribe to. Every consumer here already polls on its own
# timer, so a read is what drives a refresh: when nobody is watching, nothing runs and there is no
# lifetime to manage, no lease to expire and nothing to leak. A poller that PUSHES belongs with the
# streaming design, and it would speak this same shape.
#
# Each question is refreshed on its own clock, because they cost very different things and move at
# very different rates:
#
#   the metadata pull   a `find -newer` and a tar of what changed. Every reader needs it current,
#                       and it is how results arrive, so the window is short.
#   the scheduler       one `squeue`/`qstat`. Cheap, but it only changes when the scheduler acts —
#                       and while nothing is queued or running, only a submission can change it,
#                       which is something this process does and therefore knows about.
#   the store's size    a walk of every blob. The most expensive of the three by far and the
#                       slowest-moving, so it is refreshed on a clock of its own however often the
#                       panel asking for it repaints.
const COLLECT_PULL_S = 2.0
const COLLECT_POLL_LIVE_S = 3.0
const COLLECT_POLL_IDLE_S = 30.0
const COLLECT_SIZE_S = 120.0

mutable struct ClusterCollect
    target::ClusterTarget
    jobs::Dict{String,Symbol}
    size::NamedTuple{(:bytes, :blobs),Tuple{Int,Int}}
    pulled::Float64
    polled::Float64
    sized::Float64
    err::String
    # One lock per question, held ACROSS the remote call on purpose: a second caller arriving while
    # a pull is in flight blocks and then finds it no longer due, which is the whole point. Separate
    # locks so a slow `du` does not hold up a poll.
    pull_lk::ReentrantLock
    poll_lk::ReentrantLock
    size_lk::ReentrantLock
end

ClusterCollect(t::ClusterTarget) =
    ClusterCollect(t, Dict{String,Symbol}(), (; bytes = 0, blobs = 0), 0.0, 0.0, 0.0, "",
                   ReentrantLock(), ReentrantLock(), ReentrantLock())

# Keyed like the ssh session is: by the host and the store on it. Two cards pointed at the same
# cluster share an entry even when their targets differ in walltime or chunk size, because none of
# the three questions depends on those.
const _COLLECTORS = Dict{Tuple{String,String},ClusterCollect}()
const _COLLECTORS_LK = ReentrantLock()

function collector(t::ClusterTarget)
    key = (String(t.host), String(store_root(t)))
    return lock(_COLLECTORS_LK) do
        get!(() -> ClusterCollect(t), _COLLECTORS, key)
    end
end

_short_err(e) = first(sprint(showerror, e), 200)

"""
    collect_pull!(t; force = false) -> Bool

Bring the mirror up to date, at most once per window however many readers ask. `force` is for a
caller about to WRITE: a submission is decided from what the mirror says, so it reads the store
rather than a copy of it from a moment ago.
"""
function collect_pull!(t::ClusterTarget; force::Bool = false)
    isempty(t.host) && return true
    c = collector(t)
    return lock(c.pull_lk) do
        (force || time() - c.pulled > COLLECT_PULL_S) || return true
        ok = try
            pull_meta!(remote_store(t))
        catch e
            c.err = _short_err(e); false
        end
        # A failed pull leaves the mirror as it was rather than emptying it, and says so. A card
        # that blanks every time a login node hiccups is less use than one showing its last answer.
        ok && (c.pulled = time(); c.err = "")
        return ok
    end
end

"""
    collect_jobs(t; force = false) -> Dict{String,Symbol}

What the scheduler says about every submission in this store — one query for the whole store rather
than one per sweep. Falls back to the last answer when the query fails.
"""
function collect_jobs(t::ClusterTarget; force::Bool = false)
    isempty(t.host) && return Dict{String,Symbol}()
    c = collector(t)
    lock(c.poll_lk) do
        live = any(s -> s === :running || s === :pending, values(c.jobs))
        due = time() - c.polled > (live ? COLLECT_POLL_LIVE_S : COLLECT_POLL_IDLE_S)
        (force || due) || return
        try
            subs = BatchSweep.known_submissions(store_root(t))
            c.jobs = isempty(subs) ? Dict{String,Symbol}() :
                     BatchLauncher.poll(launcher_for(t), store_root(t), collect(keys(subs)))
            c.polled = time()
        catch e
            c.err = _short_err(e)
        end
    end
    return lock(c.poll_lk) do; copy(c.jobs); end
end

"""
    collect_size(t) -> (; bytes, blobs)

How much the store weighs. On its own slow clock: this walks every blob on the far side, and it is
read by a panel that repaints far more often than the number changes.
"""
function collect_size(t::ClusterTarget)
    c = collector(t)
    lock(c.size_lk) do
        if time() - c.sized > COLLECT_SIZE_S
            try
                c.size = store_size(source_of(t))
                c.sized = time()
            catch e
                c.err = _short_err(e)
            end
        end
        return c.size
    end
end

"What the last read of this cluster reported, without asking for another."
function collect_state(t::ClusterTarget)
    c = collector(t)
    return (; err = c.err, pulled = c.pulled, polled = c.polled, sized = c.sized,
              age = c.pulled == 0.0 ? -1.0 : time() - c.pulled)
end

"Forget what is cached for a cluster, so the next read goes out to it. For a caller that has just
changed something over there and must not then read its own stale copy."
function collect_invalidate!(t::SweepTarget)
    t isa ClusterTarget || return nothing
    c = collector(t)
    lock(c.pull_lk) do; c.pulled = 0.0; end
    lock(c.poll_lk) do; c.polled = 0.0; end
    return nothing
end
