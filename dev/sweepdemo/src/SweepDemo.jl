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

export work, damped, plan_cost, orbital_slice, lyapunov

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

# ── A two-dimensional parameter space ────────────────────────────────────────────────────────────
# One number per point over a grid of two axes — the shape a sweep has whenever the question is
# "where in this parameter space does the behaviour change?", and the shape a heatmap answers.

"""
    lyapunov(; a, b, seq = "AB", warmup = 256, iters = 1024, ms = 0) -> NamedTuple

The Lyapunov exponent of a logistic map whose growth rate alternates between `a` and `b` following
`seq`. Negative means nearby orbits converge and the system settles; positive means they separate
and it is chaotic. Sweeping `(a, b)` maps the boundary between the two.

Returns `(; a, b, λ, host)`.
"""
function lyapunov(; a::Real, b::Real, seq::AbstractString = "AB",
                  warmup::Integer = 256, iters::Integer = 1024, ms::Integer = 0)
    rate(i) = seq[mod1(i, length(seq))] == 'A' ? Float64(a) : Float64(b)
    x = 0.5
    for i in 1:warmup
        x = rate(i) * x * (1 - x)
    end
    acc = 0.0
    for i in 1:iters
        r = rate(warmup + i)
        x = r * x * (1 - x)
        d = abs(r * (1 - 2x))
        # An orbit landing exactly on the turning point has derivative zero; charge it a large
        # negative rather than -Inf, which would poison the mean for the whole point.
        acc += d > 1e-12 ? log(d) : -30.0
    end
    ms > 0 && _burn(ms)
    return (; a = Float64(a), b = Float64(b), λ = acc / iters, host = gethostname())
end

# ── A field, not a number ────────────────────────────────────────────────────────────────────────
# The other half of what a sweep unit can be. `work` returns a scalar per point, which is the easy
# case; here each unit computes one PLANE of a 3-D field and the sweep assembles a volume. That is
# the shape most real sweeps actually have — a unit produces an array, an image, a spectrum — and it
# exercises the parts a scalar never touches: a result too big to eyeball, a live view that has to
# summarise rather than plot the value, and a final artifact assembled from every unit at once.
#
# Hydrogen wavefunctions, in Bohr units and unnormalised: closed form, exactly reproducible, and
# cheap enough that the cost knob (`npix`) is the only thing that makes a unit slow. ψ is kept
# SIGNED rather than squared — the sign is where the physics is legible, since the nodal surfaces
# that separate the lobes are exactly where it crosses zero.

# Radial parts R_nl(r) for n ≤ 3, written out rather than assembled from generalised Laguerre
# polynomials: six lines against a recurrence, and these are the orbitals anyone recognises.
function _radial(n::Int, l::Int, r::Float64)
    (n, l) == (1, 0) && return exp(-r)
    (n, l) == (2, 0) && return (2 - r) * exp(-r / 2)
    (n, l) == (2, 1) && return r * exp(-r / 2)
    (n, l) == (3, 0) && return (27 - 18r + 2r^2) * exp(-r / 3)
    (n, l) == (3, 1) && return r * (6 - r) * exp(-r / 3)
    (n, l) == (3, 2) && return r^2 * exp(-r / 3)
    (n, l) == (4, 1) && return r * (80 - 20r + r^2) * exp(-r / 4)
    (n, l) == (4, 2) && return r^2 * (12 - r) * exp(-r / 4)
    (n, l) == (4, 3) && return r^3 * exp(-r / 4)
    error("SweepDemo: no radial part for n=$n, l=$l (supported: 1s 2s 2p 3s 3p 3d 4p 4d 4f)")
end

# Real spherical harmonics as Cartesian polynomials over rⁱ — the form in which they are simply
# true, with no Condon–Shortley bookkeeping to get wrong.
function _angular(l::Int, m::Int, x::Float64, y::Float64, z::Float64, r::Float64)
    r < 1e-12 && return l == 0 ? 1.0 : 0.0
    l == 0 && return 1.0
    l == 1 && return (m == -1 ? y : m == 0 ? z : x) / r
    if l == 2
        r2 = r^2
        m == -2 && return x * y / r2
        m == -1 && return y * z / r2
        m ==  0 && return (3z^2 - r2) / r2
        m ==  1 && return x * z / r2
        m ==  2 && return (x^2 - y^2) / r2
    end
    if l == 3
        r2, r3 = r^2, r^3
        m == -3 && return y * (3x^2 - y^2) / r3          # 4f_y(3x²−y²) — six lobes
        m == -2 && return x * y * z / r3                 # 4f_xyz       — eight lobes
        m == -1 && return y * (5z^2 - r2) / r3
        m ==  0 && return z * (5z^2 - 3r2) / r3
        m ==  1 && return x * (5z^2 - r2) / r3
        m ==  2 && return z * (x^2 - y^2) / r3
        m ==  3 && return x * (x^2 - 3y^2) / r3          # 4f_x(x²−3y²) — six lobes
    end
    error("SweepDemo: no angular part for l=$l, m=$m (supported: l ≤ 3)")
end

"""
    orbital_slice(; n, l, m, z, npix = 96, extent = 20.0, ms = 0) -> NamedTuple

One z-plane of the hydrogen orbital ψ_nlm, as an `npix × npix` grid over `[-extent, extent]²`.

Returns `(; z, psi, density, host, ms)`. `density` is `∑|ψ|²` over the plane — the z-marginal, so a
live view can plot ONE number per unit while the unit itself carries a whole field. A sweep over `z`
assembles the volume; playing the slices back in order flies through it.
"""
function orbital_slice(; n::Integer = 3, l::Integer = 2, m::Integer = 0, z::Real = 0.0,
                       npix::Integer = 96, extent::Real = 20.0, ms::Integer = 0)
    t0 = time()
    ax = range(-Float64(extent), Float64(extent); length = Int(npix))
    psi = Matrix{Float32}(undef, Int(npix), Int(npix))
    zz = Float64(z)
    @inbounds for (j, yy) in enumerate(ax), (i, xx) in enumerate(ax)
        r = sqrt(xx^2 + yy^2 + zz^2)
        psi[i, j] = Float32(_radial(Int(n), Int(l), r) * _angular(Int(l), Int(m), xx, yy, zz, r))
    end
    ms > 0 && _burn(ms)
    return (; z = zz, psi, density = Float64(sum(abs2, psi)),
              host = gethostname(), ms = round((time() - t0) * 1000; digits = 1))
end

# Shared with `work`: occupy a core for `ms`, rather than sleeping, so a shard exercises the
# scheduler's allocation the way real work does.
function _burn(ms::Integer)
    deadline = time() + ms / 1000
    acc = 0.0
    while time() < deadline
        acc += sum(sin, 1:2000)
    end
    acc == Inf && println(acc)   # keep the loop from being optimised away
    return nothing
end

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
