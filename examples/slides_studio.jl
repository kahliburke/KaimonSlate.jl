try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=cover bg=aurora layout=title
@md"""
# Slides Studio
### Every deck feature, one notebook
"""

#%% md id=n_cover notes
@md"""
Testbed for the presentation work: layouts, builds, reactive steps, transitions, media, timing,
recording. Each slide exercises one feature.
"""

#%% code id=makie hidecode
using CairoMakie
use_slate_theme!()

#%% md id=builds
@md"""
## Builds, without copies

::: incremental
- Each item arrives on its own click
- The slide keeps its layout as they appear
- Nothing on the slide is duplicated to make the build
:::

. . .

A pause marker reveals everything after it in one step.
"""

#%% md id=effects transition=zoom
@md"""
## Step effects

::::: columns
:::: column
::: {.step .fade-left}
**fade-left** slides in from the left
:::
::: {.step .fade-right}
**fade-right** slides in from the right
:::
::: {.step .zoom}
**zoom** grows into place
:::
::: {.step .blur}
**blur** comes into focus
:::
::::
:::: column
::: {.step .highlight}
**highlight** lights up on its step
:::
::: {.step .strike}
**strike** is crossed out on its step
:::
::: {.step .fade-out}
**fade-out** leaves on its step
:::
::: {.incremental .dim}
- **dim** keeps the current item bright
- and quiets the ones before it
:::
::::
:::::
"""

#%% md id=columns
@md"""
## Columns

:::: columns
::: {.column width="40%"}
### Left
- a narrower column
- set by `width="40%"`
:::
::: column
### Right
The right column takes the rest. Columns sit side by side on the slide and stack in the notebook
only if the page is narrow.
:::
::::
"""

#%% md id=reactive
@md"""
## A figure that builds itself

Each click adds the next odd harmonic; the chart is recomputed, not swapped.
"""

#%% code id=k_bind hidecode
@bind k SlideSteps(5)

#%% code id=fourier
let x = range(0, 4π; length = 600)
    y = sum(sin.((2j - 1) .* x) ./ (2j - 1) for j in 1:(k + 1))
    echart(:line, collect(x), 4 / π .* y; showSymbol = false, lineStyle = (width = 3,))
end

#%% md id=forces
@md raw"""
## Three forces

$$\term{inertia}{m\ddot x} \stepat{1}{{}+ \term{damping}{c\,\dot x}} \stepat{2}{{}+ \term{spring}{k\,x}} = 0$$

$\term{inertia}{m\ddot x}$ is the inertia: mass times acceleration

::: {.step step=1}
$\term{damping}{c\,\dot x}$ resists motion, in proportion to speed
:::

::: {.step step=2}
$\term{spring}{k\,x}$ pulls back, in proportion to displacement
:::
"""

#%% md id=reading layout=center
@md raw"""
## Reading the equation

$$\braceat{1}{\term{inertia}{m\ddot x}}{inertia} + \braceat{2}{\term{damping}{c\,\dot x}}{friction} + \braceat{3}{\term{spring}{k\,x}}{restoring} = \focusat{4}{0}$$

::: {.step .fade step=4}
Nothing pushes from outside: the three forces balance
:::
"""

#%% md id=derivation layout=center
@md raw"""
## Naming the rates

::: derive
$$\term{inertia}{m\ddot x} + \term{damping}{c\,\dot x} + \term{spring}{k\,x} = 0$$

$$\term{inertia}{\ddot x} + \term{damping}{\tfrac{c}{m}\,\dot x} + \term{spring}{\tfrac{k}{m}\,x} = 0 \qquad \note{divide by m}$$

$$\term{inertia}{\ddot x} + \term{damping}{2\gamma\,\dot x} + \term{spring}{\omega_0^2\,x} = 0 \qquad \note{name the rates}\;\; \term{damping}{2\gamma = \tfrac{c}{m}},\; \term{spring}{\omega_0^2 = \tfrac{k}{m}}$$
:::
"""

#%% md id=derive_guess layout=center
@md raw"""
## Guessing an exponential

::: derive
$$\term{inertia}{\ddot x} + \term{damping}{2\gamma\,\dot x} + \term{spring}{\omega_0^2\,x} = 0$$

$$\term{inertia}{r^2}\,\term{ert}{e^{rt}} + \term{damping}{2\gamma\, r}\,\term{ert}{e^{rt}} + \term{spring}{\omega_0^2}\,\term{ert}{e^{rt}} = 0 \qquad \note{try}\;\; x = e^{rt}$$

$$\term{ert}{e^{rt}}\left(\term{inertia}{r^2} + \term{damping}{2\gamma\, r} + \term{spring}{\omega_0^2}\right) = 0 \qquad \note{factor it out}$$

$$\term{ert}{\cancel{e^{rt}}}\left(\term{inertia}{r^2} + \term{damping}{2\gamma\, r} + \term{spring}{\omega_0^2}\right) = 0 \qquad \note{never zero}$$

$$\term{inertia}{r^2} + \term{damping}{2\gamma\, r} + \term{spring}{\omega_0^2} = 0$$
:::
"""

#%% md id=derive_roots layout=center
@md raw"""
## The roots

::: derive
$$\term{inertia}{r^2} + \term{damping}{2\gamma\, r} + \term{spring}{\omega_0^2} = 0$$

$$r = -\term{damping}{\gamma} \pm \sqrt{\term{damping}{\gamma}^2 - \term{spring}{\omega_0^2}}$$

$$r = -\term{damping}{\gamma} \pm i\,\term{freq}{\sqrt{\term{spring}{\omega_0^2} - \term{damping}{\gamma}^2}} \qquad \note{when}\;\; \term{damping}{\gamma} < \term{spring}{\omega_0}$$

$$r = -\term{damping}{\gamma} \pm i\,\term{freq}{\omega_d}$$

$$\term{x}{x(t)} = \term{envelope}{e^{-\gamma t}}\,\cos(\term{freq}{\omega_d}\, t)$$
:::
"""

#%% md id=motion
@md raw"""
## The motion

$$\term{x}{x(t)} = \term{envelope}{e^{-\gamma t}}\,\cos(\term{freq}{\omega_d}\, t)$$
"""

#%% code id=env_bind hidecode
@bind show_env SlideSteps(1)

#%% code id=motion_plot
let t = collect(range(0, 12; length = 600)), γ = 0.25, ωd = 2.0
    env = exp.(-γ .* t)
    s = Any[series(:line, t, env .* cos.(ωd .* t); name = "x", showSymbol = false)]
    if show_env >= 1
        for sgn in (1, -1)
            push!(s, series(:line, t, sgn .* env; name = "envelope", showSymbol = false,
                            lineStyle = (width = 2, type = :dashed)))
        end
    end
    echart(s...; legend = false, height = 420,
           steps = [(x = (0, 12),), (x = (7.5, 12), y = (-0.16, 0.16)), (x = (0, 3), band = true)])
end

#%% md id=live
@md"""
## Change the damping
"""

#%% code id=damping_bind
@bind γd Slider(0.05:0.05:1.0; default = 0.25, label = "damping γ")

#%% code id=live_plot ghost
let t = collect(range(0, 12; length = 600)), ωd = 2.0
    echart(series(:line, t, exp.(-γd .* t) .* cos.(ωd .* t); name = "x", showSymbol = false);
           legend = false, height = 380, yAxis = (min = -1, max = 1))
end

#%% md id=phase
@md"""
## The orbit in phase space

Position against velocity: each swing loses a little, so the orbit spirals in.

::: {.step step=2}
Every orbit ends at rest.
:::

::: {.step step=3}
Close in, the spiral keeps its shape.
:::
"""

#%% code id=phase_fig hidecode column=2
let γ = 0.25, ωd = 2.0
    t = range(0, 16; length = 1200)
    x = @. exp(-γ * t) * cos(ωd * t)
    v = @. -γ * x - exp(-γ * t) * ωd * sin(ωd * t)
    fig = Figure(size = (760, 700), fontsize = 26)
    ax = Axis(fig[1, 1]; xlabel = L"x", ylabel = L"\dot{x}", limits = (-1.1, 1.1, -2.2, 2.2))
    tr = trace!(ax, x, v; color = slate_color(:orange))
    rest = callout!(ax, (0.0, 0.0), "rest"; offset = (70, 60))
    slide_figure(fig; steps = [
        (trace = tr, frames = 90),
        (show = rest,),
        (limits = (ax, (-0.25, 0.25, -0.5, 0.5)), frames = 45),
    ])
end

#%% md id=helix
@md"""
## Time as a third axis

From the side, the orbit is the decaying cosine.

::: {.step step=2}
Down the time axis, it is the spiral.
:::
"""

#%% code id=helix_fig hidecode column=2
let γ = 0.25, ωd = 2.0
    t = range(0, 12; length = 900)
    x = @. exp(-γ * t) * cos(ωd * t)
    v = @. -γ * x - exp(-γ * t) * ωd * sin(ωd * t)
    fig = Figure(size = (800, 700), fontsize = 26)
    ax = Axis3(fig[1, 1]; xlabel = L"t", ylabel = L"\dot{x}", zlabel = L"x",
               azimuth = -π / 2 + 0.02, elevation = 0.05, perspectiveness = 0.2, protrusions = (40, 90, 40, 40))
    tr = trace!(ax, t, v, x; color = slate_color(:orange))
    start = callout!(ax, (0.0, -0.25, 1.0), L"x_0"; offset = (40, 40))
    slide_figure(fig; steps = [
        (trace = tr, show = start, frames = 90),
        (view = (ax, (-0.02, 0.05)), frames = 75),
    ])
end

#%% md id=draws
@md"""
## Two hundred and forty draws
"""

#%% code id=draws_data hidecode
using Random
draws = randn(MersenneTwister(7), 240)
jitter = rand(MersenneTwister(11), 240)
edges = collect(range(-3, 3; length = 13))
binof(v) = clamp(searchsortedlast(edges, v), 1, length(edges) - 1)
nothing

#%% code id=draws_strip morph=dist
echart(; xAxis = (type = :value, min = -3, max = 3), yAxis = (type = :value, min = 0, max = 1, show = false),
       series = [(type = :scatter, symbolSize = 10, itemStyle = (opacity = 0.85,),
                  data = [(value = [v, j], groupId = "b$(binof(v))") for (v, j) in zip(draws, jitter)])],
       height = 420)

#%% md id=histo
@md"""
## Gathered into a histogram
"""

#%% code id=histo_chart morph=dist
let nb = length(edges) - 1
    counts = [count(v -> binof(v) == b, draws) for b in 1:nb]
    centers = [(edges[b] + edges[b+1]) / 2 for b in 1:nb]
    echart(; xAxis = (type = :value, min = -3, max = 3), yAxis = (type = :value,),
           series = [(type = :bar, barWidth = "80%",
                      data = [(value = [centers[b], counts[b]], groupId = "b$b") for b in 1:nb])],
           height = 420)
end

#%% md id=section bg=nebula layout=section transition=slide
@md"""
## Part two
### Media and timing
"""

#%% md id=video
@md"""
## Video on a slide

:::: columns
::: {.column width="58%"}
![autoplay loop muted](data/ripple.mp4)
:::
::: column
::: incremental
- Image syntax, a clip path
- `autoplay` starts it when the slide comes up
- `loop`, `muted`, `nocontrols` as needed
:::
:::
::::
"""

#%% code id=ripple hidecode
# The clip the next two slides play, rendered once into the data dir.
ripple = let path = joinpath(datadir(), "ripple.mp4")
    isfile(path) || let fig = Figure(size = (640, 360), figure_padding = 0)
        ax = Axis(fig[1, 1]); hidedecorations!(ax); hidespines!(ax)
        xs = range(-8, 8; length = 320); ys = range(-4.5, 4.5; length = 180)
        t = Observable(0.0)
        z = lift(t -> [sin(2hypot(x - 3, y) - 6t) + sin(2hypot(x + 3, y) - 6t) for x in xs, y in ys], t)
        heatmap!(ax, xs, ys, z; colormap = :magma)
        record(fig, path, range(0, 4π / 3; length = 121)[1:end-1]; framerate = 30) do τ
            t[] = τ
        end
    end
    path
end;

#%% md id=bgvideo bg=data/ripple.mp4 bgdim=0.45 layout=center transition=zoom
@md"""
## Full-bleed background

### `bg=clip.mp4 bgdim=0.45` on the cell
"""

#%% md id=morph_a
@md"""
## Morph

The heading on the next slide has the same text, so it glides into its new place.
"""

#%% md id=morph_b layout=center transition=fade
@md"""
## Morph
"""

#%% md id=timed auto=3
@md"""
## Timed

This slide advances by itself after three seconds.
"""

#%% md id=close bg=aurora layout=title
@md"""
# Thanks
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 52415fcf-743c-4d4a-98a8-b334482df07b
#   format = 2
# ╚═╡
