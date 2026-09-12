try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=title role=title
@md"""
# `@bind` → Observable

### A Slate control driving a WGLMakie figure in place
"""

#%% md id=intro
@md"""
A Slate control can be consumed two ways, and only one of them is good.

Reading `decay` makes a cell a **reader**: every change restales it, so the whole cell runs again
and its figure is rebuilt — for a WGLMakie figure that means re-inlining the scene and taking a
fresh Bonito session, which is the visible flash.

Reading `bind_observable(:decay)` names the control as quoted **data**, so the cell is not a reader
and never restales. The control pushes the new value in and Makie updates the scene in place,
exactly as a native `SliderGrid` would.

Each figure's title carries its own run count. Drag anything: the counts stay at **1**, because
nothing below is ever recomputed by a control.
"""

#%% code id=setup hidecode
using WGLMakie, BonitoSlate, Observables
WGLMakie.activate!()
BonitoSlate.enable!()
use_slate_theme!()


nothing

#%% code id=controls
@bind decay Slider(0.0:0.05:1.5; default=0.35, label="decay")
@bind freq  Slider(1:1:12;       default=4,    label="frequency")

nothing

#%% code id=fig_observe hidecode nocache
# OBSERVE — built ONCE. No bind variable is named, so nothing here can restale the cell; the
# control pushes into the Observable and Makie updates the scene in place.
#
# `bind_observable` hands back a CELL-LOCAL Observable, fresh per run, so an ordinary `lift` on
# top of it dies with the cell. Nothing to detach, nothing to leak.
let
    d = bind_observable(:decay)
    f = bind_observable(:freq)
    t = range(0, 4π; length = 600)

    y   = lift((dv, fv) -> @.(exp(-dv * t) * sin(fv * t)), d, f)
    env = lift(dv -> @.(exp(-dv * t)), d)
    neg = lift(e -> -e, env)
    ttl = lift((dv, fv) -> "OBSERVE — decay $dv, freq $fv", d, f)

    fig = Figure(size = (760, 320))
    ax = Axis(fig[1, 1]; title = ttl, xlabel = "t", ylabel = "x(t)")
    lines!(ax, t, y; linewidth = 3)
    lines!(ax, t, env; linestyle = :dash, linewidth = 2)
    lines!(ax, t, neg; linestyle = :dash, linewidth = 2)
    ylims!(ax, -1.15, 1.15)
    fig
end

#%% md id=md_hidden
@md"""
## A control drawn somewhere else

`hidden(…)` marks a control as rendered outside the notebook — no row in its `@bind` cell, no
entry in a surfaced strip, and it is not offered by the 🎛 picker. It is otherwise completely
normal: it holds a value, coerces it, fires `@onchange`, feeds `bind_observable`, and remains a
parameter in a static export. Only the notebook's own widget is suppressed.

This is what lets a control be drawn natively *inside* a figure without a second, drifting copy
appearing in the notebook beside it.

The cell below declares `phase` as hidden — you should see **no widget** for it, while the figure
under it still tracks its value.
"""

#%% code id=hidden_ctl
@bind phase hidden(Slider(0.0:0.1:6.3; default=0.0, label="phase"))

nothing

#%% code id=fig_hidden nocache
let
    p = bind_observable(:phase)
    t = range(0, 4π; length = 400)
    y = lift(pv -> @.(sin(t + pv)), p)
    ttl = lift(pv -> "HIDDEN CONTROL — phase $(round(pv, digits = 2))   ·   no widget in the notebook", p)

    fig = Figure(size = (760, 240))
    ax = Axis(fig[1, 1]; title = ttl, xlabel = "t")
    lines!(ax, t, y; linewidth = 3)
    ylims!(ax, -1.2, 1.2)
    fig
end

#%% md id=md_native
@md"""
## The control drawn inside the figure

`bonito_controls(session, :amp, :phase2)` builds a **native Bonito widget** per named Slate control
and returns a DOM node to compose into an `App` — so the knobs sit in the figure card next to what
they drive.

The Slate control stays authoritative: these are a second *view* of it, not a second copy. A change
goes back through `window.slateSetBind`, the same path a native Slate widget uses, so the registry,
the global, `@onchange`, the persisted value and any static export all move together.

Both controls are declared `hidden(…)`, so the notebook renders no chrome for them — one control,
drawn where it's useful.

The interesting case is the **echo**: Slate reflects changes back into the widget so it never shows
a stale position, and that reflection fires the widget's own change handler. The guard is to write
back only when the value genuinely differs from what Slate already holds, so a reflected value stops
at the first hop while a real drag always gets through. No timers, no suppression flag to get stuck.
"""

#%% code id=native_ctls
@bind amp    hidden(Slider(0.1:0.1:2.0; default=1.0, label="amplitude"))
@bind phase2 hidden(Slider(0.0:0.1:6.3; default=0.0, label="phase"))

nothing

#%% code id=fig_native nocache
App() do session
    a = bind_observable(:amp)
    p = bind_observable(:phase2)
    t = range(0, 4π; length = 400)
    y = lift((av, pv) -> @.(av * sin(t + pv)), a, p)
    ttl = lift((av, pv) -> "NATIVE CONTROLS — amp $(round(av, digits=2)), phase $(round(pv, digits=2))", a, p)

    fig = Figure(size = (720, 280))
    ax = Axis(fig[1, 1]; title = ttl, xlabel = "t")
    lines!(ax, t, y; linewidth = 3)
    ylims!(ax, -2.2, 2.2)

    DOM.div(bonito_controls(session, :amp, :phase2; layout = :row), fig;
                   style = "display:flex;flex-direction:column;gap:6px")
end

#%% md id=md_3d
@md"""
## 3D, with all three kinds of control at once

`Axis3` is the harder case: WGLMakie has no client-side 3D camera, so drag-to-rotate updates the
azimuth and elevation **in Julia** and pushes the result back. That makes it a real test of the live
channel rather than just the first paint.

Three ways to put a knob on one figure, deliberately mixed:

| control | what it is | where it is actually drawn |
|---|---|---|
| `ripples` | Slate `@bind` | HTML, in the notebook's own chrome above |
| `falloff`, `z scale` | Slate `@bind` + `hidden(…)`, rendered by Bonito | **HTML**, in the figure *card* — a DOM sibling of the canvas, not inside it |
| `twist` | Makie `SliderGrid`, no `@bind` at all | **inside the WebGL canvas**, part of the scene graph Makie draws |

The distinction between the last two is easy to miss and worth being clear about. A Bonito widget
is still an HTML element; it just happens to sit in the same card as the canvas, so it *looks*
like part of the figure. The `SliderGrid` is drawn by Makie into the scene itself — it is in the
canvas, and it would look and behave identically in a GLMakie window with no browser involved.

The first two are the same Slate control reached through `bind_observable`; only where they are
*drawn* differs, which is what `hidden(…)` decides. The third never touches Slate at all.

None of them recomputes the cell — `cell runs` stays at 1 whichever you touch. Drag the surface to
rotate, then move any slider: the camera stays put, because nothing re-created the scene.
"""

#%% code id=fig_3d nocache
# The controls are declared HERE, in the same cell as the figure that observes them.
#
# That is not cosmetic. `bind_observable(:ripple)` names the control as quoted data, which is what
# stops this cell being a reader — but it also means no dependency edge, and cells evaluate as a
# parallel batch, so a control declared in ANOTHER cell may not exist yet when this one runs.
# Declaring them here removes the race without reintroducing the restale: `set_bind!` re-runs the
# declaring cell only when the changed name is in its `reads`, and a quoted name is not a read.
@bind ripple  Slider(1:1:10;             default=3,   label="ripples")   # drawn by Slate
@bind falloff hidden(Slider(0.5:0.1:4.0; default=2.0, label="falloff"))  # drawn by Bonito
@bind zscale  hidden(Slider(0.2:0.1:2.5; default=1.0, label="z scale"))  # drawn by Bonito

App() do session
    r = bind_observable(:ripple)     # Slate control, Slate-drawn
    f = bind_observable(:falloff)    # Slate control, Bonito-drawn (hidden in the notebook)
    z = bind_observable(:zscale)     # Slate control, Bonito-drawn (hidden in the notebook)

    xs = range(-3, 3; length = 80)
    ys = range(-3, 3; length = 80)

    fig = Figure(size = (720, 600))
    ax = Axis3(fig[1, 1]; xlabel = "x", ylabel = "y", zlabel = "z")

    # A Makie-native control: no @bind, no Slate. Its value IS a Makie Observable, and it is drawn
    # INSIDE the GL canvas as part of the scene — the baseline the Slate paths aim to feel like.
    sg = SliderGrid(fig[2, 1], (label = "twist", range = 0:0.05:2.0, startvalue = 0.0))
    tw = sg.sliders[1].value

    zs = lift(r, f, z, tw) do rv, fv, zv, tv
        [zv * exp(-(x^2 + y^2) / fv) * sin(rv * sqrt(x^2 + y^2) + tv * atan(y, x))
         for x in xs, y in ys]
    end

    # `ax.title` IS an Observable, so set its VALUE — assigning a new Observable over it with dot
    # notation is refused by Makie (it would replace the one the block already wired up).
    title_of(rv, fv, zv, tv) =
        "ripples $rv (slate) · falloff $(round(fv, digits=1)) / z $(round(zv, digits=1)) (bonito) " *
        "· twist $(round(tv, digits=2)) (makie)"
    ax.title[] = title_of(r[], f[], z[], tw[])
    onany((rv, fv, zv, tv) -> (ax.title[] = title_of(rv, fv, zv, tv)), r, f, z, tw)

    surface!(ax, xs, ys, zs; colormap = :viridis)
    zlims!(ax, -2.5, 2.5)

    DOM.div(bonito_controls(session, :falloff, :zscale; layout = :row), fig;
            style = "display:flex;flex-direction:column;gap:6px")
end

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 6b2a41d8-3c17-4f9e-9a55-1e0c7f2b84aa
# ╚═╡
