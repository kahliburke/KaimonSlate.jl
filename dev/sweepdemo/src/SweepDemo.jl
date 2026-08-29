"""
    SweepDemo

The science half of the batch-fabric demo: a real package, provisioned to the cluster, that a
notebook's sweep calls into. Keeping the work here rather than in the notebook is the realistic
shape — a compute node cannot revive a closure, but it can load a package.

The workload is synthetic with tunable cost, on purpose. A demo that only ever succeeds cannot show
what the sweep machinery is actually for: the interesting cases are walltime kills, memory kills,
deterministic errors, and shards that vanish without a trace. Every one of those is a knob here, so
they can be provoked deliberately instead of waited for.
"""
module SweepDemo

using Random
using SHA

export work, damped, plan_cost

"""
    damped(x; ω = 3.0, ζ = 0.15) -> Float64

The value the sweep is actually "measuring": a damped oscillation. Deterministic, cheap, and
smooth enough that a partially filled chart reads as a curve rather than noise.
"""
damped(x; ω = 3.0, ζ = 0.15) = exp(-ζ * x) * cos(ω * x)

"""
    work(p) -> NamedTuple

Run one shard. `p` is a row of the sweep grid and may carry these knobs, all optional:

| knob      | effect |
|-----------|--------------------------------------------------------------|
| `x`       | the point being evaluated (required in practice)             |
| `ms`      | busy-wait this many milliseconds (CPU, not sleep)            |
| `sleep_s` | sleep this many seconds (idle, for queue/walltime shaping)   |
| `mb`      | allocate this many megabytes and touch them                  |
| `fail`    | throw deterministically                                      |
| `hang_s`  | sleep this long, to be killed by a short walltime            |
| `seed`    | vary the result reproducibly                                 |

Returns `(; x, y, host, ms)`.
"""
function work(p)
    x       = _get(p, :x, 0.0)
    ms      = _get(p, :ms, 0)
    sleep_s = _get(p, :sleep_s, 0.0)
    mb      = _get(p, :mb, 0)
    seed    = _get(p, :seed, 0)
    t0 = time()

    if _get(p, :fail, false)
        error("SweepDemo: deliberate failure at x=$(x), seed=$(seed)")
    end

    # A walltime kill has to be a real overrun: the process must still be alive when the scheduler
    # takes it, so the shard writes no manifest and the reconciler sees it as missing rather than
    # errored. That distinction is the whole point of the :stalled state.
    hang = _get(p, :hang_s, 0.0)
    hang > 0 && sleep(hang)

    # Busy-wait rather than sleep when asked for CPU: a sleeping shard does not occupy a core, so it
    # would not exercise the scheduler's allocation the way real work does.
    if ms > 0
        deadline = time() + ms / 1000
        acc = 0.0
        while time() < deadline
            acc += sum(sin, 1:2000)
        end
        acc == Inf && println(acc)   # keep the loop from being optimised away
    end

    sleep_s > 0 && sleep(sleep_s)

    # Touched, not just allocated: an untouched allocation may never be faulted in, so a memory
    # limit would not trigger.
    if mb > 0
        buf = Vector{UInt8}(undef, mb * 1024 * 1024)
        fill!(buf, 0x01)
        buf[1] == 0x00 && println("unreachable")
    end

    rng = Random.MersenneTwister(hash((x, seed)))
    y = damped(x) + 0.02 * randn(rng)

    return (; x, y, host = gethostname(), ms = round((time() - t0) * 1000; digits = 1))
end

_get(p, k::Symbol, default) = hasproperty(p, k) ? getproperty(p, k) : default

"""
    plan_cost(grid) -> NamedTuple

What a sweep is about to cost, before submitting it. Firing thousands of jobs should be a decision
taken with a number in front of you.
"""
function plan_cost(grid)
    per = [(_get(p, :ms, 0) / 1000) + _get(p, :sleep_s, 0.0) + _get(p, :hang_s, 0.0) for p in grid]
    total = sum(per; init = 0.0)
    return (; shards = length(grid),
            seconds_each = isempty(per) ? 0.0 : round(sum(per) / length(per); digits = 2),
            core_seconds = round(total; digits = 1),
            core_hours = round(total / 3600; digits = 3))
end

end # module SweepDemo
