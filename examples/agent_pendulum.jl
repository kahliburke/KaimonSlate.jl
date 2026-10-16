try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title_slide title bg=midnight layout=title
@md"""
# Why a pendulum keeps time

## Where T ≈ 2π√(L/g) comes from

A string, a weight, and one small approximation.
"""

#%% md id=forces
@md raw"""
## Newton along the arc

A bob of mass $m$ hangs on a string of length $\term{length}{L}$, swung out by an angle $\term{theta}{\theta}$.

$$\braceat{3}{\term{inertia}{m L\,\ddot\theta}}{mass $\times$ accel.} \stepat{1}{= \hlat{2}{-}\,\term{gravity}{m g \sin\theta}}$$

::: {.step step=1}
Only $\term{gravity}{m g \sin\theta}$, the part of gravity along the arc, moves the bob. The string pulls straight in, across the motion.
:::

::: {.step step=2}
The minus sign: the pull always points back toward the bottom.
:::

::: {.step step=3}
Arc length is $L\theta$, so its acceleration is $L\ddot\theta$.
:::
"""

#%% md id=derive_small_angle
@md raw"""
## Strip it down

::: derive
$$\term{inertia}{m L\,\ddot\theta} = -\term{gravity}{m g \sin\theta} \qquad \note{Newton along the arc}$$

$$\term{inertia}{L\,\ddot\theta} = -\term{gravity}{g \sin\theta} \qquad \note{divide by m: the mass drops out}$$

$$\term{inertia}{\ddot\theta} = -\term{gravity}{\tfrac{g}{L}\sin\theta} \qquad \note{divide by L}$$

$$\term{inertia}{\ddot\theta} = -\term{gravity}{\tfrac{g}{L}\,\theta} \qquad \note{small swing: sin θ ≈ θ}$$

$$\term{inertia}{\ddot\theta} = -\term{omega}{\omega^2}\,\theta \qquad \note{name g/L = ω²}$$
:::

::: {.step step=3}
For small angles (in radians) $\sin\theta \approx \theta$: at 10° the two differ by 0.5%.
:::
"""

#%% md id=solution_period
@md raw"""
## The motion, and its period

::: derive
$$\term{inertia}{\ddot\theta} = -\term{omega}{\omega^2}\,\theta \qquad \note{what we found}$$

$$\term{theta}{\theta(t)} = \theta_0 \cos(\term{omega}{\omega}\, t) \qquad \note{guess a cosine}$$

$$\term{omega}{\omega}\,\term{period}{T} = 2\pi \qquad \note{one full swing}$$

$$\term{period}{T} = 2\pi\sqrt{\frac{\term{length}{L}}{g}} \qquad \note{use} \; \term{omega}{\omega^2} = g/L$$
:::

::: {.step step=3}
No mass, no amplitude $\theta_0$: only $\term{length}{L}$ and $g$.
:::
"""

#%% code id=motion_steps
@bind k_motion SlideSteps(3)

#%% code id=motion_plot hidecode
let L = 1.0, g = 9.81
    ω = sqrt(g / L)
    T = 2π / ω
    t = range(0, 2.5T; length = 400)
    θ0 = 0.2
    s = Any[]
    k_motion >= 1 && push!(s, series(:line, t, θ0 .* cos.(ω .* t); name = "theta", symbol = "none"))
    k_motion >= 2 && push!(s, series(:line, [T, T], [-θ0, θ0]; name = "period", symbol = "none",
                                     lineStyle = (type = "dashed",)))
    k_motion >= 3 && push!(s, series(:line, t, 0.5θ0 .* cos.(ω .* t); name = "smaller swing",
                                     symbol = "none", lineStyle = (type = "dotted",)))
    echart(s...; xAxis = (name = "t (s), L = 1 m", min = 0, max = 2.5T),
           yAxis = (name = "θ (rad)", min = -0.25, max = 0.25), height = 320)
end

#%% md id=how_small
@md"""
## How small is small?

The small-angle $\term{period}{T}$ ignores the swing. The true period $\term{exact}{T_{\text{exact}}}$ grows as the swing $\theta_0$ widens.

::: {.step step=2}
Below about 20°, they agree to better than 1%.
:::
"""

#%% code id=amplitude_steps
@bind k_amp SlideSteps(2)

#%% code id=period_vs_amplitude hidecode
let L = 1.0, g = 9.81
    # complete elliptic integral K(k) through the arithmetic-geometric mean
    function K(k)
        a, b = 1.0, sqrt(1 - k^2)
        for _ in 1:30
            a, b = (a + b) / 2, sqrt(a * b)
        end
        π / (2a)
    end
    T0 = 2π * sqrt(L / g)
    deg = range(0, 120; length = 241)
    Texact = [4sqrt(L / g) * K(sind(d / 2)) for d in deg]
    s = Any[series(:line, deg, fill(T0, length(deg)); name = "period", symbol = "none")]
    exact_kw = k_amp >= 2 ?
        (markArea = (itemStyle = (opacity = 0.15,),
                     data = [[(xAxis = 0, name = "< 1%"), (xAxis = 20,)]]),) : (;)
    k_amp >= 1 && push!(s, series(:line, deg, Texact; name = "exact", symbol = "none", exact_kw...))
    echart(s...; xAxis = (name = "swing θ₀ (degrees)", min = 0, max = 120),
           yAxis = (name = "period (s), L = 1 m", min = 1.8, max = 2.6), height = 320)
end

#%% md id=closing bg=midnight layout=center
@md raw"""
## Keeping time

$$\term{period}{T} \approx 2\pi\sqrt{\frac{\term{length}{L}}{g}}$$

::: incremental
- The mass cancels: heavy and light bobs swing together.
- Small swings make the pull proportional to $\term{theta}{\theta}$, and that gives a cosine.
- Every small swing takes the same time, which is why a pendulum can keep time.
:::
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = adad5da0-dbb0-4d7c-abec-47e10b719ee0
#   format = 2
# ╚═╡
