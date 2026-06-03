#%% md id=title
# 🎛️ Controls-with-output demo

The headline UX: a cell surfaces the bound controls that drive it, in a **control
strip** in its own output area — turning the notebook into a mini-app.

- **`controls`** is a *control-group* cell: several `@bind`s declared together.
- The **`plot`** cell declares `controls=[freq,amp],phase` — `freq` and `amp`
  stack in one column, `phase` sits in a column beside them, rendered **with the
  figure**. Open the 🎛 Controls palette and drag chips between cells/columns.

#%% code id=setup
using CairoMakie, Statistics
CairoMakie.activate!(type = "png")
set_theme!(theme_dark())
"environment ready"

#%% code id=controls
@bind freq Slider(1:0.5:12)
@bind amp Slider(0.2:0.2:3.0)
@bind phase Slider(0:0.1:6.2)

#%% code id=signal controls=[amp,phase],freq
x = range(0, 2π; length = 2400)
y = amp .* sin.(freq .* x .+ phase)
(; peak = round(maximum(y); digits = 3))

#%% code id=plot controls=phase,freq
fig = Figure(size = (760, 320))
ax = Axis(fig[1, 1]; title = "amp · sin(freq·x + phase)", xlabel = "x", ylabel = "y")
band!(ax, x, zeros(length(x)), y; color = (:cyan, 0.12))
lines!(ax, x, y; color = :cyan, linewidth = 2)
fig
