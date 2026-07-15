# Charts

Return a chart from a cell and it renders inline — interactive, and **animating in place** on
reactive updates (no image swap). `echart` is a Slate helper injected into every cell. For
interactive tables, see [Tables](tables.md); for frame-by-frame playback, see
[Animation](animation.md).

## `echart` — the ECharts DSL

`echart` is a thin Julian surface over [Apache ECharts](https://echarts.apache.org). Three forms,
all sugar over the raw option dict, so nothing in ECharts is out of reach:

- **Express** — `echart(:line, x, y; title=…, smooth=…)` for a single series.
- **Composable** — `echart(series(:line, …), series(:bar, …); legend=true)` for several.
- **Raw** — `echart(; xAxis=(…), series=[…])` (Symbol/NamedTuple-friendly) for anything else.

Dark theme + tooltip are on by default; a legend appears when several series are named.

### Express — one series

```julia
echart(:line, ["Mon", "Tue", "Wed", "Thu", "Fri"], [120, 200, 150, 80, 70]; title = "Weekly visits", smooth = true)
```

![A smoothed ECharts line chart](./assets/chart-line.png)

```julia
echart(:bar, ["A", "B", "C", "D", "E"], [5, 20, 36, 10, 12]; title = "Counts")
```

![An ECharts bar chart](./assets/chart-bar.png)

The x-axis is inferred from the data — string x → category axis, numeric x → value axis. `:area`,
`:scatter`, and `:pie` work the same way:

![An ECharts area chart](./assets/chart-area.png)
![An ECharts scatter plot of a Gaussian cloud](./assets/chart-scatter.png)
![An ECharts pie chart](./assets/chart-pie.png)

### Ergonomic kinds

`:heatmap`, `:radar`, `:boxplot`, and `:candlestick` know their data shape and bring the components
they imply (a `visualMap` for the heatmap, the radar indicators, a five-number summary for boxplots
computed from raw samples):

![An ECharts heatmap](./assets/chart-heatmap.png)
![An ECharts radar chart](./assets/chart-radar.png)
![An ECharts boxplot](./assets/chart-boxplot.png)
![An ECharts candlestick (OHLC) chart](./assets/chart-candlestick.png)

### Relational, hierarchical, geo & calendar

Flows, networks, hierarchies, map trajectories, and calendar heatmaps get the same one-liner
treatment — nodes, links, and hierarchies are inferred from friendly Julia data:

```julia
echart(:sankey, [("coal", "grid", 40), ("solar", "grid", 25), ("grid", "homes", 65)])  # flows
echart(:graph,  ["a", "b", "c"], [("a", "b"), "b" => "c"]; title = "Network")           # force-directed network
echart(:treemap, ["Eng" => ["api" => 12, "ui" => 8], "Ops" => 5])                       # hierarchy (also :sunburst)
echart(:calendar, dates, counts; title = "Activity")                                    # calendar heatmap
```

- **`:sankey`** — links are `(source, target, value)` (or `src => tgt => val`); nodes are derived from
  the endpoints, or pass an explicit `(nodes, links)`.
- **`:graph`** — a network; edges are `(source, target)` (or `src => tgt`), force-laid-out and roamable by
  default. Pairs naturally with the pipeline [DAG](dag.md).
- **`:treemap` / `:sunburst`** — a hierarchy: `name => value` is a leaf, `name => [children…]` a branch;
  NamedTuple/Dict nodes pass through. One root or a vector of roots.
- **`:lines`** — geo trajectories/flows. Coordinates are `(lon, lat)`; the series binds to the geo
  coordinate system, so add a map (same recipe as geo scatter):

```julia
echart(:lines, from, to;
       registerMap = (name = "world", url = "/assets/maps/world.json"),
       geo = (map = "world", roam = true), effect = (show = true, symbol = "arrow"))
```

- **`:calendar`** — a calendar heatmap from `(dates, values)`; brings the calendar component (its range
  auto-spans the dates) and a `visualMap`. Dates can be `Date`s or `"YYYY-MM-DD"` strings.

### Composable — several series

Each `series(:kind, …)` is one trace; `echart(series…; layout…)` assembles the shared axes, legend,
and theme. Mixed types just work:

```julia
echart(series(:line, x, sin.(x); name = "sin", smooth = true),
       series(:bar,  x, 0.3 .* sin.(2x); name = "0.3·sin 2t"); title = "Composable", legend = true)
```

![A composable ECharts chart mixing a line and bar series](./assets/chart-composable.png)

Charts also work inside markdown cells via double-brace interpolation — see
[Notebook Basics](notebook-basics.md#markdown-interpolation).

## One look — ECharts & Makie

Interactive ECharts figures are themed to match the notebook automatically: they use the **Slate
palette** (drawn from the active UI theme's colours), a transparent background, and the document
font — so a chart reads as part of the page, and it **restyles when you switch the Slate theme**.

Makie figures are yours to theme, but a matching theme ships so your rendered plots line up with the
interactive ones — same series colours, palette-toned grid/axes, and a figure height aligned to the
ECharts cell. Apply it once (needs Makie loaded):

```julia
using CairoMakie
use_slate_theme!()          # every Makie figure now matches the Slate look
# or grab the Theme to compose: set_theme!(merge(slate_theme(), Theme(fontsize = 16)))
```

`slate_theme()` returns a Makie `Theme`; `use_slate_theme!()` applies it globally for the notebook.

## Tables

Interactive tables are a feature in their own right — sorting, filtering, paging, currency /
percent / bytes formatting, in-cell bar & heat viz, clickable rows, and server-paging for large
data. They have their own page: **[Tables](tables.md)**.
