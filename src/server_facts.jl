# ── System facts ─────────────────────────────────────────────────────────────────────────────────
#
# The ONE description of the hub's state that pages show: which hosts are signed in, and every open
# notebook's workers, with what each is doing. Pages hold a copy of it (model.js) and render from that
# copy alone, so two parts of a page cannot disagree about the same thing, and nothing on a page keeps
# a fact of its own that can go stale.
#
# FACTS, not display text, and nothing that changes merely because time passed: a duration is sent as
# the instant it counts from (an allocation's end, the last use, when a worker stopped answering), and
# the page measures it. So a fact changes only when the system does, and an unchanged fact is never
# resent.
#
# Computed from the sources themselves (the ssh transport, the region registry and its placements, the
# kernels) by `_facts_compute`, and published as a DIFF by `facts_refresh!`. A refresh runs on every
# event that changes what is shown (`facts_changed!`, called where those events happen) and on a slow
# tick, which bounds how long a change no event announces can go unseen. Recomputing everything rather
# than patching what an event says it touched is what keeps the copy right: an event cannot forget a
# consequence, because no event says what its consequences are.
#
# Keys are `worker/<notebook>/<side>` (side "" is the notebook's main worker) and `session/<host>`.

const _FACTS = Dict{String,Any}()
const _FACTS_REV = Ref(0)
const _FACTS_LOCK = ReentrantLock()                 # the published set and its revision
const _FACTS_COMPUTE_LOCK = ReentrantLock()         # one refresh at a time
const _FACT_LISTENERS = Channel{String}[]
const _FACT_LISTENERS_LOCK = ReentrantLock()
const _FACTS_HUB = Ref{Any}(nothing)
const _FACTS_PENDING = Threads.Atomic{Bool}(false)
const _FACTS_TICK_S = 3.0
const _FACTS_COALESCE_S = 0.03                      # events in a burst share one refresh

"""
    facts_changed!()

Something the facts describe has changed: a worker connected or went, a host signed in or out, a
region started placing or preparing. Schedules a refresh shortly, so a burst of events costs one.
"""
function facts_changed!()
    _FACTS_HUB[] === nothing && return nothing
    Threads.atomic_xchg!(_FACTS_PENDING, true) && return nothing     # one already scheduled
    Threads.@spawn begin
        sleep(_FACTS_COALESCE_S)
        _FACTS_PENDING[] = false
        try; facts_refresh!(); catch e
            @debug "facts refresh failed" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

# The hub the facts are about, and its tick. Installed at hub start; the tick ends with the hub.
function _install_facts!(h)
    _FACTS_HUB[] = h
    lock(_FACTS_LOCK) do; empty!(_FACTS); end
    errormonitor(@async while _FACTS_HUB[] === h
        try; facts_refresh!(); catch; end
        sleep(_FACTS_TICK_S)
    end)
    return nothing
end

"""
    facts_refresh!() -> Int

Recompute the facts from their sources and publish what changed. Returns the revision.
"""
function facts_refresh!()
    h = _FACTS_HUB[]
    h === nothing && return _FACTS_REV[]
    lock(_FACTS_COMPUTE_LOCK) do
        now_ = _facts_compute(h)
        set = Dict{String,Any}(); del = String[]
        rev = lock(_FACTS_LOCK) do
            for (k, v) in now_
                get(_FACTS, k, nothing) == v || (set[k] = v; _FACTS[k] = v)
            end
            for k in collect(keys(_FACTS))
                haskey(now_, k) || (push!(del, k); delete!(_FACTS, k))
            end
            (isempty(set) && isempty(del)) || (_FACTS_REV[] += 1)
            _FACTS_REV[]
        end
        (isempty(set) && isempty(del)) && return rev
        _facts_send(JSON.json(_json_finite(Dict("t" => "facts", "rev" => rev, "now" => time(),
                                                "set" => set, "del" => del))))
        return rev
    end
end

"The whole published set, as a page loads it before the stream's deltas."
facts_snapshot() = lock(_FACTS_LOCK) do
    Dict{String,Any}("t" => "facts", "rev" => _FACTS_REV[], "now" => time(), "full" => true,
                     "set" => copy(_FACTS), "del" => String[])
end

function _facts_send(frame::String)
    lock(_FACT_LISTENERS_LOCK) do
        for ch in _FACT_LISTENERS
            # A listener that has stopped reading is dropped from the delta stream: its page notices
            # the gap in revisions and reloads the whole set.
            (isopen(ch) && Base.n_avail(ch) < 256) && (try; put!(ch, frame); catch; end)
        end
    end
    return nothing
end

# The facts stream: the whole set first, then each change, as server-sent events. One stream serves
# every page on the hub, the home page and each notebook alike.
function _sse_facts(stream::HTTP.Stream)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    ch = Channel{String}(512)
    lock(() -> push!(_FACT_LISTENERS, ch), _FACT_LISTENERS_LOCK)
    beat = Timer(_ -> (try; put!(ch, "hb"); catch; end), 15; interval = 15)
    try
        write(stream, "data: " * JSON.json(_json_finite(facts_snapshot())) * "\n\n")
        while true
            msg = take!(ch)
            write(stream, msg == "hb" ? ": hb\n\n" : "data: $msg\n\n")
        end
    catch
    finally
        close(beat)
        lock(() -> filter!(c -> c !== ch, _FACT_LISTENERS), _FACT_LISTENERS_LOCK)
        close(ch)
    end
    return nothing
end

# ── computing them ───────────────────────────────────────────────────────────────────────────────

function _facts_compute(h)
    out = Dict{String,Any}()
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    for nb in nbs
        nb.closed && continue
        # A dormant notebook runs nothing: its page shows the launch pill instead of workers.
        get(nb.report.meta, "inactive", false) === true && continue
        for w in (try; _workers_json(nb); catch; Any[]; end)
            f = _worker_fact(w)
            f["nb"] = nb.id
            f["notebookName"] = basename(nb.path)
            f["path"] = abspath(nb.path)
            # The name a roster files a routed node's worker under: its login host, which shares its
            # home and where its manifest is read.
            h_ = String(get(f, "host", ""))
            v = isempty(h_) ? nothing : (try; ReportEngine.via(h_); catch; nothing; end)
            (v === nothing || isempty(v.host)) || (f["viaHost"] = String(v.host))
            out["worker/" * nb.id * "/" * String(get(w, "side", ""))] = f
        end
    end
    for (host, uses) in (try; _session_hosts(nothing); catch; Dict{String,Vector{String}}(); end)
        out["session/" * host] = _session_fact(host, uses, nbs)
    end
    return out
end

# A worker entry as a fact: the measurements that ride the telemetry stream are left out, and what was
# a duration becomes the instant it counts from, so the fact holds still between real changes.
function _worker_fact(w::AbstractDict)
    f = Dict{String,Any}(String(k) => v for (k, v) in w)
    delete!(f, "stats")                       # telemetry: its own stream
    delete!(f, "clockSamples")                # grows with every heartbeat
    haskey(f, "clockRttMs") && (f["clockRttMs"] = round(Float64(f["clockRttMs"]); digits = 1))
    haskey(f, "clockDriftPpm") && (f["clockDriftPpm"] = round(Float64(f["clockDriftPpm"])))
    t = time()
    haskey(f, "walltimeLeft") && (f["until"] = round(t + pop!(f, "walltimeLeft")))
    haskey(f, "idleFor") && (f["lastUsed"] = round(t - pop!(f, "idleFor")))
    return f
end

# What a host said it takes when last asked without signing in (`/api/sessions/probe`): "key",
# "interactive", "unreachable". Kept here so every page shows the answer, not just the one that asked.
const _SESSION_PROBED = Dict{String,Tuple{String,String}}()    # host → (auth, error)
const _SESSION_PROBED_LOCK = ReentrantLock()
session_probed!(host::AbstractString, auth::AbstractString, err::AbstractString = "") =
    lock(() -> (_SESSION_PROBED[String(host)] = (String(auth), String(err)); facts_changed!()), _SESSION_PROBED_LOCK)

# A host's session: whether it is signed in, whether a sign-in is under way, what it asked for last
# time, what it is used for, and which open notebooks use it.
function _session_fact(host::AbstractString, uses, nbs)
    T = ReportEngine.Sweep.SshTransport
    asked = try; T.remembered_prompts(host); catch; []; end
    users = String[]
    for nb in nbs
        nb.closed && continue
        (try; haskey(_session_hosts(nb), String(host)); catch; false; end) && push!(users, nb.id)
    end
    probed = lock(() -> get(_SESSION_PROBED, String(host), ("", "")), _SESSION_PROBED_LOCK)
    return Dict{String,Any}("host" => String(host), "usedBy" => sort(String.(uses)), "nbs" => sort(users),
                            "connected" => ReportEngine.Sweep.connected(host),
                            "opening" => (try; T.opening(String(host)); catch; false; end),
                            "auth" => !isempty(probed[1]) ? probed[1] : isempty(asked) ? "unknown" : "interactive",
                            "error" => probed[2],
                            "asks" => [String(first(p)) for p in asked])
end

"""
    _session_hosts(nb = nothing) -> Dict{String,Vector{String}}

The hosts there is something to sign in to, each with what it is used for. Machine-wide for `nothing`
(the home page); given a notebook, only the hosts it names — a notebook that sweeps on one cluster has
no business showing a control for another.
"""
function _session_hosts(nb::Union{LiveNotebook,Nothing} = nothing)
    wanted = nb === nothing ? nothing : begin
        cl, rg = Set{String}(), Set{String}()
        lock(nb.lock) do
            for c in nb.report.cells
                n = get(ReportEngine.cell_attrs(c), "cluster", ""); isempty(n) || push!(cl, n)
                r = _cell_region(c); isempty(r) || push!(rg, r)
            end
        end
        (cl, rg)
    end
    seen = Dict{String,Vector{String}}()
    add!(h, use) = isempty(strip(String(h))) || push!(get!(seen, strip(String(h)), String[]), use)
    for c in ReportEngine.clusters_all()
        String(get(c, "kind", "")) == "local" && continue   # nothing to sign in to
        name = String(get(c, "name", "?"))
        (wanted === nothing || name in wanted[1]) || continue
        add!(get(c, "host", ""), "cluster " * name)
    end
    for r in ReportEngine.regions()
        (wanted === nothing || r.name in wanted[2]) || continue
        add!(r.host, "region " * r.name)
    end
    return seen
end
