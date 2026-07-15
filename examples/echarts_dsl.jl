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

#%% md id=h_ergonomic
## Ergonomic kinds — heatmap · candlestick · radar · boxplot

These know their data shape and bring the components they imply — category axes + a
`visualMap` for the heatmap, the `radar` component, a scaled value axis for OHLC — with no
hand-assembly. `boxplot` even computes the five-number summary from raw samples.

#%% code id=heatmap
hours = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
days  = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
z = [(i * 3 + j * 2) % 11 for j in 1:7, i in 1:8]      # rows = days, cols = hours
echart(:heatmap, hours, days, z; title = "Activity")

#%% code id=candlestick
echart(:candlestick, ["10/1", "10/2", "10/3", "10/4", "10/5", "10/6"],
       [[20, 34, 10, 38], [40, 35, 30, 50], [31, 38, 33, 44],
        [38, 15, 5, 42], [15, 25, 8, 28], [25, 30, 20, 36]];   # [open, close, low, high]
       title = "OHLC")

#%% code id=radar
echart(:radar,
       ["Sales" => 6500, "Admin" => 16000, "Tech" => 30000, "Support" => 38000, "Dev" => 52000],
       ["Allocated" => [4200, 3000, 20000, 35000, 50000],
        "Actual"    => [5000, 14000, 28000, 26000, 42000]];
       title = "Budget", legend = true)

#%% code id=boxplot
groups  = ["A", "B", "C", "D"]
samples = [randn(60) .+ g for g in 1:4]                # raw samples → 5-number summary computed
echart(:boxplot, groups, samples; title = "Distributions")

#%% md id=h_relational
## Relational, hierarchical, geo & calendar

Flows, networks, hierarchies, map trajectories, and calendar heatmaps get the same one-liner
treatment — nodes, links, and hierarchies inferred from friendly Julia data.

#%% code id=sankey
echart(:sankey, [("coal", "grid", 40), ("gas", "grid", 30), ("solar", "grid", 25),
                 ("grid", "homes", 55), ("grid", "industry", 40)]; title = "Energy flow")

#%% code id=graph
echart(:graph, ["ingest", "clean", "model", "score", "report"],
       [("ingest", "clean"), ("clean", "model"), ("model", "score"), ("score", "report"), "clean" => "report"];
       title = "Pipeline")

#%% code id=treemap
echart(:treemap, ["Engineering" => ["api" => 12, "ui" => 8, "infra" => 6],
                  "Product" => ["design" => 5, "research" => 4], "Ops" => 7]; title = "Headcount")

#%% code id=sunburst
echart(:sunburst, [(name = "root", children = [
        (name = "A", value = 10, children = [(name = "A1", value = 4), (name = "A2", value = 6)]),
        (name = "B", value = 8, children = [(name = "B1", value = 5), (name = "B2", value = 3)])])];
       title = "Sunburst")

#%% code id=calendar
using Dates
days = collect(Date(2024, 1, 1):Day(1):Date(2024, 3, 31))
echart(:calendar, days, [(dayofyear(d) * 7) % 30 for d in days]; title = "Daily activity 2024")

#%% code id=geolines
echart(:lines, [(-74.0, 40.7), (2.35, 48.85), (139.7, 35.7)],        # from: NYC, Paris, Tokyo
                [(-0.13, 51.5), (-0.13, 51.5), (-122.4, 37.8)];       # to:   London, London, SF
       title = "Routes", registerMap = (name = "world", url = "/assets/maps/world.json"),
       geo = (map = "world", roam = true, itemStyle = (areaColor = "#161a2b", borderColor = "#2a2e40")),
       effect = (show = true, symbol = "arrow", symbolSize = 5), lineStyle = (curveness = 0.2, width = 1.5))

#%% md id=h_raw
## Async + a button — a live gauge

The clean way to stream into a chart: a **`reactive`** value plus an **`@onclick`** handler — no
globals, no generation counters, no manual `slate_refresh`. Click **Fill ▸** and the handler
spawns a cancellable ramp to a random target; `level[] = v` pushes each step to the gauge (a
reader of `level`), which `setOption`s in place. Click again and the prior ramp is cancelled.

#%% code id=gauge_ctrl
@bind fill Button("Fill ▸")

#%% code id=stop_ctrl
@bind stop Button("Stop ■")   # separate @bind cell: clicking Stop must not recompute the fill handler

#%% code id=level
level = reactive(:level, 0)        # a live value: `level[]` reads, `level[] = v` pushes to readers

#%% code id=stopper
@onclick stop cancel(:fill)        # Stop button → cancel the running ramp (it stops at the next pause)

#%% code id=filler
@onclick fill begin   
  	level[] = 0# runs on each click; a new click cancels the running ramp
    for v in 0:2:rand(45:100)
        level[] = v
        pause(0.1)                # cancellable sleep
    end
end

#%% code id=b037ad

#%% code id=gauge controls=[fill,stop]
echart(series(:gauge; min = 0, max = 100,
              progress = (show = true, width = 14),
              axisLine = (lineStyle = (width = 14,
                          color = [[0.3, "#56d364"], [0.7, "#e3b341"], [1.0, "#e57575"]]),),
              detail = (formatter = "{value}%", color = "inherit", fontSize = 28),
              data = [(value = level[], name = "load")]);
       title = "System load", tooltip = false)

#%% code id=20d576
level[]

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
