# ── Cross-machine clock tracking ─────────────────────────────────────────────────────────────────
# A worker is on another machine, so an instant it reports means nothing here until it is mapped into
# the hub's timeline. Nobody's clock is adjusted: we MEASURE the delta between the two and track it,
# with the hub as the reference standard.
#
# Between MONOTONIC clocks, deliberately. `time_ns()` has an arbitrary origin on each machine — which
# the offset absorbs — and, unlike wall time, it cannot be stepped by the node's own time daemon
# correcting itself. A wall-to-wall delta makes such a step indistinguishable from a sudden enormous
# drift; a monotonic one does not move at all.
#
# The measurement rides `__slate_running`, which the liveness sweep already round-trips every few
# seconds, so it costs nothing extra: the hub notes when it sent and received, the worker reports when
# it received and replied, and those four give the offset and the round-trip time (Cristian).
#
# WHAT THIS IS NOT FOR: elapsed time. A duration is measured within one machine and must never
# consult an offset — so a bad estimate here can misplace an event on a timeline, but can never
# shorten someone's allocation.
module ClockTrack

export note_exchange!, to_hub_ns, clock_quality, forget_clock!, tracked_conns

# One exchange: when it happened (hub monotonic, ns), the offset it implies, and what it cost.
const _WINDOW = 32          # samples kept per connection
const _MIN_FIT = 4          # below this, report the plain offset rather than a fitted line
# A RATE needs a lever arm. The startup burst is eight exchanges inside half a second, which pins the
# offset well and says nothing about drift: a few ms of RTT noise over that baseline fits slopes in
# the thousands of ppm. Until the samples span this much time, hold drift at zero and use the offset
# alone — which is exactly right, since drift over a minute is microseconds.
const _DRIFT_MIN_SPAN_NS = 60.0e9
# Crystals are tens of ppm. Anything past this is noise or a step, not a clock running fast.
const _DRIFT_MAX_PPM = 200.0
# A residual beyond this is not drift — it is a step, and the window is rebuilt around it rather than
# smeared across it. Monotonic clocks do not step, so in practice this fires on a worker restart
# reusing a connection name.
const _STEP_NS = 5.0e8      # 0.5 s

mutable struct Track
    t::Vector{Float64}      # hub monotonic (ns) at the midpoint of each exchange
    off::Vector{Float64}    # worker_mono − hub_mono (ns)
    rtt::Vector{Float64}    # round-trip (ns)
    offset::Float64         # fitted offset at `anchor`
    drift::Float64          # ns of offset per ns of hub time
    drift_ok::Bool          # whether that rate was actually FITTED, as opposed to held at zero
    anchor::Float64         # hub monotonic the fit is expressed at
    ok::Bool
end
Track() = Track(Float64[], Float64[], Float64[], 0.0, 0.0, false, 0.0, false)

const _TRACKS = Dict{String,Track}()
const _LOCK = ReentrantLock()

"""
    note_exchange!(conn, t1, t2, t3, t4)

Record one round trip. `t1`/`t4` are hub monotonic (ns) at send and receive; `t2`/`t3` are the
worker's monotonic (ns) at receive and reply. Ignored when the four are not ordered sensibly.
"""
function note_exchange!(conn::AbstractString, t1::Real, t2::Real, t3::Real, t4::Real)
    rtt = (Float64(t4) - Float64(t1)) - (Float64(t3) - Float64(t2))
    (isfinite(rtt) && rtt >= 0) || return nothing
    # The classic estimator: the two crossings' errors cancel when the path is symmetric.
    off = ((Float64(t2) - Float64(t1)) + (Float64(t3) - Float64(t4))) / 2
    mid = (Float64(t1) + Float64(t4)) / 2
    lock(_LOCK) do
        tr = get!(Track, _TRACKS, String(conn))
        # A step (or a different process behind the same name) invalidates the history rather than
        # being averaged into it.
        if tr.ok && abs(_predict(tr, mid) - off) > _STEP_NS
            empty!(tr.t); empty!(tr.off); empty!(tr.rtt)
        end
        push!(tr.t, mid); push!(tr.off, off); push!(tr.rtt, rtt)
        if length(tr.t) > _WINDOW
            popfirst!(tr.t); popfirst!(tr.off); popfirst!(tr.rtt)
        end
        _refit!(tr)
    end
    return nothing
end

_predict(tr::Track, t::Real) = tr.offset + tr.drift * (Float64(t) - tr.anchor)

# Fit offset + drift over the CLEANEST samples. Queuing delay is additive and asymmetric, so a slow
# exchange is biased while a fast one is nearly not — keep those within twice the window's best RTT
# and fit a line through them, which is what keeps the estimate good between measurements instead of
# decaying until it needs rescuing.
function _refit!(tr::Track)
    n = length(tr.t)
    n == 0 && (tr.ok = false; return nothing)
    best = minimum(tr.rtt)
    keep = [i for i in 1:n if tr.rtt[i] <= max(2 * best, best + 1.0e6)]
    length(keep) < _MIN_FIT && (tr.anchor = tr.t[end]; tr.offset = tr.off[end];
                                tr.drift = 0.0; tr.drift_ok = false; tr.ok = true; return nothing)
    t0 = tr.t[keep[end]]
    span = tr.t[keep[end]] - tr.t[keep[1]]
    if span < _DRIFT_MIN_SPAN_NS
        # Offset only, taken from the CLEANEST exchange rather than the newest: least queuing delay,
        # least contaminated estimate.
        bi = keep[argmin([tr.rtt[i] for i in keep])]
        tr.anchor = tr.t[bi]; tr.offset = tr.off[bi]
        tr.drift = 0.0; tr.drift_ok = false; tr.ok = true      # withheld, NOT measured as flat
        return nothing
    end
    xs = [tr.t[i] - t0 for i in keep]
    ys = [tr.off[i] for i in keep]
    mx = sum(xs) / length(xs); my = sum(ys) / length(ys)
    sxx = sum((x - mx)^2 for x in xs)
    slope = sxx > 0 ? sum((xs[i] - mx) * (ys[i] - my) for i in eachindex(xs)) / sxx : 0.0
    # Past this it is not a crystal: keep the offset, and report the rate as unknown rather than as
    # zero — a rejected fit is not a measurement of flatness.
    fitted = abs(slope) * 1e6 <= _DRIFT_MAX_PPM
    fitted || (slope = 0.0)
    tr.anchor = t0; tr.offset = my + slope * (0.0 - mx)
    tr.drift = slope; tr.drift_ok = fitted; tr.ok = true
    return nothing
end

"""
    to_hub_ns(conn, worker_mono_ns) -> Union{Float64,Nothing}

A worker monotonic instant, expressed on the hub's monotonic timeline. `nothing` when this
connection has never been measured — the caller must then fall back to what it knows itself, never
to a guess.
"""
function to_hub_ns(conn::AbstractString, worker_ns::Real)
    lock(_LOCK) do
        tr = get(_TRACKS, String(conn), nothing)
        (tr === nothing || !tr.ok) && return nothing
        # offset(t) is expressed against HUB time, and we are inverting: solve for the hub instant
        # whose predicted offset maps to this worker instant. One Newton step is exact for a line.
        h = Float64(worker_ns) - tr.offset
        return h - tr.drift * (h - tr.anchor)
    end
end

"""
How good the mapping is for this connection: `(; ok, rtt_ns, drift_ppm, samples)`.

`drift_ppm` is `nothing` until a rate has actually been fitted — which needs samples spanning
`_DRIFT_MIN_SPAN_NS`. Reporting an unmeasured rate as `0` would read as "these clocks do not drift",
which is a claim, not an observation.
"""
function clock_quality(conn::AbstractString)
    lock(_LOCK) do
        tr = get(_TRACKS, String(conn), nothing)
        tr === nothing && return (; ok = false, rtt_ns = 0.0, drift_ppm = nothing, samples = 0)
        return (; ok = tr.ok, rtt_ns = isempty(tr.rtt) ? 0.0 : minimum(tr.rtt),
                drift_ppm = tr.drift_ok ? tr.drift * 1e6 : nothing, samples = length(tr.t))
    end
end

forget_clock!(conn::AbstractString) = (lock(_LOCK) do; delete!(_TRACKS, String(conn)); end; nothing)

"Every connection with a mapping, for the sweep that drops the ones no worker holds any more."
tracked_conns() = lock(_LOCK) do; collect(keys(_TRACKS)); end

end # module ClockTrack
