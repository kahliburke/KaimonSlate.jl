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

## Tables

Interactive tables are a feature in their own right — sorting, filtering, paging, currency /
percent / bytes formatting, in-cell bar & heat viz, clickable rows, and server-paging for large
data. They have their own page: **[Tables](tables.md)**.
