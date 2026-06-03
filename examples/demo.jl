#%% md id=title
# 📊 Kaimon Reactive Notebook — Feature Tour

A warm-session, **reactive** notebook. Edit a cell or drag a widget and only the
*downstream* cells recompute (pruned dependency graph). The source is a plain
`.jl` file, so the agent and the browser share one source of truth.

| Feature | Where to look |
|---|---|
| Reactive deps | drag a slider → plot + chart + stats update; `setup` & this cell don't |
| Widgets (`@bind`) | the controls below |
| Makie figures | the dark-themed signal plot |
| Interactive charts | the ECharts histogram (hover / zoom / drag-select) |
| Markdown editing | **double-click this text** to edit its source, ⇧⏎ to commit |

> Every code cell shows its eval time (ms) in the header.

#%% code id=setup
using CairoMakie, Statistics
CairoMakie.activate!(type = "png")
set_theme!(theme_dark())              # dark plots to match the UI
"environment ready"

#%% md id=controls-h
## Controls — drag / toggle these

#%% code id=freq
@bind freq Slider(1:0.5:12)

#%% code id=amp
@bind amp Slider(0.2:0.2:3.0)

#%% code id=phase
@bind phase Slider(0:0.1:6.2)

#%% code id=shape
@bind shape Select(["sine", "square-ish", "sawtooth"])

#%% code id=npts
@bind npts NumberField(240)

#%% code id=grid
@bind grid Checkbox(true)

#%% code id=label
@bind label TextField("amp · f(freq·x + phase)")

#%% md id=signal-h
## Reactive signal — depends on every widget above

#%% code id=signal
x = range(0, 2π; length = Int(round(npts)))
b = sin.(freq .* x .+ phase)
y = amp .* (shape == "square-ish" ? sign.(b) .* abs.(b) .^ 0.3 :
            shape == "sawtooth"   ? (2 / π) .* asin.(clamp.(b, -1, 1)) : b)
(; points = length(x), peak = round(maximum(y); digits = 3))

#%% md id=plot-h
## Makie figure (dark theme) — recomputes in place on any change

#%% code id=plot
fig = Figure(size = (760, 320))
ax = Axis(fig[1, 1]; title = label, xlabel = "x", ylabel = "y")
ax.xgridvisible = grid
ax.ygridvisible = grid
band!(ax, x, zeros(length(x)), y; color = (:cyan, 0.12))
lines!(ax, x, y; color = :cyan, linewidth = 2)
fig

#%% md id=chart-h
## Interactive ECharts — value distribution (hover a bar, drag to zoom)

#%% code id=chart
edges = range(-amp, amp; length = 13)
counts = [count(v -> edges[i] <= v < edges[i+1], y) for i in 1:length(edges)-1]
mids = round.((edges[1:end-1] .+ edges[2:end]) ./ 2; digits = 2)
echart(Dict(
    "tooltip" => Dict("trigger" => "axis"),
    "dataZoom" => [Dict("type" => "inside"), Dict("type" => "slider")],
    "xAxis" => Dict("type" => "category", "data" => string.(mids), "name" => "value"),
    "yAxis" => Dict("type" => "value", "name" => "count"),
    "series" => [Dict("type" => "bar", "data" => counts,
                      "itemStyle" => Dict("color" => "#22d3ee"))],
))

#%% md id=stats-h
## A plain value cell — return-value repr + cross-cell state

#%% code id=stats
(; mean = round(mean(y); digits = 4),
   std = round(std(y); digits = 4),
   rms = round(sqrt(mean(y .^ 2)); digits = 4),
   n = length(y))

#%% md id=outro
## Try it

- **Drag** `freq` / `amp` / `phase` → the plot, histogram, and stats recompute;
  the markdown and `setup` cells stay untouched (pruned recompute).
- **Switch** `shape` or toggle `grid`; type a new `label`.
- **Edit** any code cell and press ⇧⏎. **Double-click** markdown to edit its source.
- **Drag** the ⠿ handle to reorder; **⌘Z / ⌘⇧Z** to undo / redo; **Tab** completes.
