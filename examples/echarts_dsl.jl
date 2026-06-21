#%% md id=intro
# 📊 ECharts DSL

`echart` is a thin, Julian surface over [Apache ECharts](https://echarts.apache.org) —
return one from a cell and it renders live, animating **in place** on reactive updates.
Three forms, all sugar over the raw option dict (so nothing in ECharts is out of reach):

- **Express** — `echart(:line, x, y; title=…, smooth=…)` for a single series.
- **Composable** — `echart(series(:line, …), series(:bar, …); legend=true)` for several.
- **Raw** — `echart(; xAxis=(…), series=[…])` (Symbol/NamedTuple-friendly) for anything else.

Dark theme + tooltip are on by default; a legend appears when several series are named, and
extra kwargs / top-level components (`grid`, `dataZoom`, `visualMap`, …) pass straight through.

#%% md id=h_express
## Express — one series, one line

The x-axis is inferred from the data: string x → category axis, numeric x → value axis.

#%% code id=line
echart(:line, ["Mon", "Tue", "Wed", "Thu", "Fri"], [120, 200, 150, 80, 70];
       title = "Weekly visits", smooth = false)

#%% code id=bar
echart(:bar, ["A", "B", "C", "D", "E"], [5, 20, 36, 10, 12]; title = "Counts")

#%% code id=scatter controls=col
@bind col ColorPicker("#56d364")
echart(:scatter, randn(800), randn(800); symbolSize = 2, color=col, title = "Gaussian cloud")

#%% code id=pie
echart(:pie, ["Search", "Direct", "Email", "Ads"], [1048, 735, 580, 300]; title = "Traffic")

#%% md id=h_reactive
## Reactive — drive a chart with `@bind`

Drag the slider and switch the wave; the chart `setOption`s in place — no image swap.
`wave` is a `Radio` of `value => label` pairs, so it compares as its value (`wave == "sin"`)
while `wave.label` gives the pretty name.

#%% code id=ctrl
@bind freq Slider(1:0.5:12; label = "frequency")
@bind wave Radio(["sin" => "sine", "cos" => "cosine"]; label = "wave")
@bind smooth Toggle(true; on = "smooth", off = "sharp")

#%% code id=reactive controls=[freq,wave],smooth
x = range(0, 2π; length = 220)
f = wave == "sin" ? sin : cos
echart(:line, collect(x), f.(freq .* x);
       title = "$(wave.label)(freq·x)   ·   freq = $freq", smooth = smooth)

#%% md id=h_multi
## Composable — several series

Each `series(:kind, …)` is one trace; `echart(series…; layout…)` assembles the shared axes,
legend and theme. Mixed types (line + bar here) just work.

#%% code id=multi
t = range(0, 2π; length = 140)
echart(
    series(:line, collect(t), sin.(t);       name = "sin",       smooth = true),
    series(:line, collect(t), cos.(t);       name = "cos",       smooth = true),
    series(:bar,  collect(t), 0.3 .* sin.(2 .* t); name = "0.3·sin 2t");
    title = "Trig mix", legend = true,
)

#%% md id=h_raw
## Raw passthrough — the whole ECharts surface

`series(:kind, …)` works for *any* ECharts series type, and any top-level component passes
through verbatim with Symbol/NamedTuple keys. Here: a heatmap with a `visualMap` colour scale.

#%% code id=heatmap
hours = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
days  = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
heat  = [[i, j, (i * 3 + j * 2) % 11] for i in 0:7 for j in 0:6]
echart(
    series(:heatmap, heat; label = (show = true,));
    title     = "Activity",
    xAxis     = (type = :category, data = hours),
    yAxis     = (type = :category, data = days),
    visualMap = (min = 0, max = 10, calculable = true,
                 orient = :horizontal, left = :center, bottom = 0),
    tooltip   = (position = :top,),
)

#%% md id=h_fullraw
And the fully-raw escape hatch — a plain ECharts option, no helpers, Symbol/NamedTuple-friendly,
with a `dataZoom` slider added for free:

#%% code id=fullraw
echart(
    xAxis    = (type = :category, data = ["A", "B", "C", "D", "E", "F", "G"]),
    yAxis    = (type = :value,),
    series   = [(type = :bar, data = [12, 9, 15, 7, 18, 11, 6])],
    dataZoom = [(type = :slider,)],
    backgroundColor = "transparent",
)
