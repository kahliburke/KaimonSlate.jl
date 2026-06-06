#%% md id=title
# 📈 ECharts gallery

A slew of [Apache ECharts](https://echarts.apache.org) examples. Return an
`echart(Dict(...))` from a cell and it renders live (and animates in place on
reactive updates). The **line / bar / scatter / gauge** charts are driven by the
`controls` group below — the rest are static showcases. Open 🎛 **Controls** to
rearrange the controls that feed the reactive charts.

#%% code id=controls
@bind n Slider(20:5:200)
@bind freq Slider(1:0.5:10)
@bind amp Slider(0.5:0.5:5)
@bind chartColor ColorPicker("#5470cf")
@bind smooth Toggle(true)

#%% code id=base
xs = collect(range(0, 2π; length = Int(n)))
ys = round.(amp .* sin.(freq .* xs); digits = 3)
zs = round.(amp .* cos.(freq .* xs); digits = 3)
cats = string.(round.(xs; digits = 2))
(; points = length(xs))

#%% code id=line controls=[n,freq],[amp,chartColor,smooth]
echart(Dict(
    "title" => Dict("text" => "Line — reactive"),
    "tooltip" => Dict("trigger" => "axis"),
    "legend" => Dict("data" => ["sin", "cos"], "top" => 24),
    "xAxis" => Dict("type" => "category", "data" => cats),
    "yAxis" => Dict("type" => "value"),
    "series" => [
        Dict("name" => "sin", "type" => "line", "data" => ys, "smooth" => smooth,
             "areaStyle" => (smooth ? Dict("opacity" => 0.15) : nothing),
             "lineStyle" => Dict("color" => chartColor), "itemStyle" => Dict("color" => chartColor)),
        Dict("name" => "cos", "type" => "line", "data" => zs, "smooth" => smooth),
    ],
))

#%% code id=bar
bar_chart = echart(Dict(
    "title" => Dict("text" => "Bar — stacked"),
    "tooltip" => Dict("trigger" => "axis"),
    "legend" => Dict("top" => 24),
    "xAxis" => Dict("type" => "category", "data" => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
    "yAxis" => Dict("type" => "value"),
    "series" => [
        Dict("name" => "Direct", "type" => "bar", "stack" => "t", "data" => [320, 302, 301, 334, 390, 330, 320]),
        Dict("name" => "Email", "type" => "bar", "stack" => "t", "data" => [120, 132, 101, 134, 90, 230, 210]),
        Dict("name" => "Ads", "type" => "bar", "stack" => "t", "data" => [220, 182, 191, 234, 290, 330, 310]),
    ],
))

#%% md id=af6747
# Chart embeds?

Here we goooo!

{{ bar_chart }}

#%% code id=scatter controls=chartColor
echart(Dict(
    "title" => Dict("text" => "Scatter — reactive"),
    "tooltip" => Dict("trigger" => "item"),
    "xAxis" => Dict("type" => "value"),
    "yAxis" => Dict("type" => "value"),
    "series" => [Dict("type" => "scatter", "symbolSize" => 8,
                      "itemStyle" => Dict("color" => chartColor),
                      "data" => [[round(x; digits = 3), y] for (x, y) in zip(xs, ys)])],
))

#%% code id=pie
echart(Dict(
    "title" => Dict("text" => "Pie", "left" => "center"),
    "tooltip" => Dict("trigger" => "item"),
    "series" => [Dict("type" => "pie", "radius" => "60%",
        "data" => [Dict("value" => 1048, "name" => "Search"), Dict("value" => 735, "name" => "Direct"),
                   Dict("value" => 580, "name" => "Email"), Dict("value" => 484, "name" => "Union Ads"),
                   Dict("value" => 300, "name" => "Video Ads")],
        "emphasis" => Dict("itemStyle" => Dict("shadowBlur" => 10, "shadowColor" => "rgba(0,0,0,0.5)")))],
))

#%% code id=rose
echart(Dict(
    "title" => Dict("text" => "Doughnut / rose", "left" => "center"),
    "tooltip" => Dict("trigger" => "item"),
    "series" => [Dict("type" => "pie", "radius" => ["30%", "65%"], "roseType" => "area",
        "itemStyle" => Dict("borderRadius" => 6),
        "data" => [Dict("value" => 40, "name" => "A"), Dict("value" => 38, "name" => "B"),
                   Dict("value" => 32, "name" => "C"), Dict("value" => 30, "name" => "D"),
                   Dict("value" => 28, "name" => "E"), Dict("value" => 22, "name" => "F")])],
))

#%% code id=radar
echart(Dict(
    "title" => Dict("text" => "Radar"),
    "legend" => Dict("data" => ["Allocated", "Actual"], "top" => 24),
    "radar" => Dict("indicator" => [
        Dict("name" => "Sales", "max" => 6500), Dict("name" => "Admin", "max" => 16000),
        Dict("name" => "Tech", "max" => 30000), Dict("name" => "Support", "max" => 38000),
        Dict("name" => "Dev", "max" => 52000), Dict("name" => "Market", "max" => 25000)]),
    "series" => [Dict("type" => "radar", "data" => [
        Dict("value" => [4200, 3000, 20000, 35000, 50000, 18000], "name" => "Allocated"),
        Dict("value" => [5000, 14000, 28000, 26000, 42000, 21000], "name" => "Actual")])],
))

#%% code id=gauge controls=amp
echart(Dict(
    "title" => Dict("text" => "Gauge — reactive (amp)"),
    "series" => [Dict("type" => "gauge", "min" => 0, "max" => 5, "progress" => Dict("show" => true),
        "axisLine" => Dict("lineStyle" => Dict("width" => 18)),
        "data" => [Dict("value" => amp, "name" => "amp")])],
))

#%% code id=heatmap
echart(Dict(
    "title" => Dict("text" => "Heatmap"),
    "tooltip" => Dict("position" => "top"),
    "xAxis" => Dict("type" => "category", "data" => ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]),
    "yAxis" => Dict("type" => "category", "data" => ["Sat", "Fri", "Thu", "Wed", "Tue", "Mon", "Sun"]),
    "visualMap" => Dict("min" => 0, "max" => 10, "calculable" => true, "orient" => "horizontal",
                        "left" => "center", "bottom" => 0),
    "series" => [Dict("type" => "heatmap", "label" => Dict("show" => true),
        "data" => [[i, j, (i * 3 + j * 2) % 11] for i in 0:7 for j in 0:6])],
))

#%% code id=candlestick
echart(Dict(
    "title" => Dict("text" => "Candlestick"),
    "tooltip" => Dict("trigger" => "axis"),
    "xAxis" => Dict("type" => "category", "data" => ["10/1", "10/2", "10/3", "10/4", "10/5", "10/6"]),
    "yAxis" => Dict("type" => "value", "scale" => true),
    "series" => [Dict("type" => "candlestick", "data" => [
        [20, 34, 10, 38], [40, 35, 30, 50], [31, 38, 33, 44],
        [38, 15, 5, 42], [15, 25, 8, 28], [25, 30, 20, 36]])],
))

#%% code id=funnel
echart(Dict(
    "title" => Dict("text" => "Funnel"),
    "tooltip" => Dict("trigger" => "item"),
    "series" => [Dict("type" => "funnel", "left" => "10%", "width" => "80%",
        "label" => Dict("show" => true, "position" => "inside"),
        "data" => [Dict("value" => 100, "name" => "Show"), Dict("value" => 80, "name" => "Click"),
                   Dict("value" => 60, "name" => "Visit"), Dict("value" => 40, "name" => "Inquiry"),
                   Dict("value" => 20, "name" => "Order")])],
))

#%% code id=graph
echart(Dict(
    "title" => Dict("text" => "Graph — force"),
    "tooltip" => Dict(),
    "series" => [Dict("type" => "graph", "layout" => "force", "roam" => true,
        "force" => Dict("repulsion" => 120, "edgeLength" => 60),
        "label" => Dict("show" => true),
        "data" => [Dict("name" => "α", "symbolSize" => 40), Dict("name" => "β", "symbolSize" => 28),
                   Dict("name" => "γ", "symbolSize" => 28), Dict("name" => "δ", "symbolSize" => 20),
                   Dict("name" => "ε", "symbolSize" => 20), Dict("name" => "ζ", "symbolSize" => 20)],
        "links" => [Dict("source" => "α", "target" => "β"), Dict("source" => "α", "target" => "γ"),
                    Dict("source" => "β", "target" => "δ"), Dict("source" => "γ", "target" => "ε"),
                    Dict("source" => "γ", "target" => "ζ"), Dict("source" => "δ", "target" => "ε")])],
))

#%% code id=sankey
echart(Dict(
    "title" => Dict("text" => "Sankey"),
    "series" => [Dict("type" => "sankey",
        "data" => [Dict("name" => "a"), Dict("name" => "b"), Dict("name" => "c"),
                   Dict("name" => "d"), Dict("name" => "e")],
        "links" => [Dict("source" => "a", "target" => "b", "value" => 5),
                    Dict("source" => "a", "target" => "c", "value" => 3),
                    Dict("source" => "b", "target" => "d", "value" => 4),
                    Dict("source" => "c", "target" => "d", "value" => 2),
                    Dict("source" => "d", "target" => "e", "value" => 6)])],
))

#%% code id=sunburst
echart(Dict(
    "title" => Dict("text" => "Sunburst"),
    "series" => [Dict("type" => "sunburst", "radius" => ["15%", "90%"],
        "data" => [
            Dict("name" => "A", "value" => 10, "children" => [
                Dict("name" => "A1", "value" => 4), Dict("name" => "A2", "value" => 6,
                    "children" => [Dict("name" => "A2a", "value" => 3), Dict("name" => "A2b", "value" => 3)])]),
            Dict("name" => "B", "value" => 8, "children" => [
                Dict("name" => "B1", "value" => 5), Dict("name" => "B2", "value" => 3)])])],
))

#%% code id=polar
echart(Dict(
    "title" => Dict("text" => "Polar bar"),
    "polar" => Dict("radius" => [20, "80%"]),
    "angleAxis" => Dict("max" => 4, "startAngle" => 75),
    "radiusAxis" => Dict("type" => "category", "data" => ["a", "b", "c", "d"]),
    "tooltip" => Dict(),
    "series" => [Dict("type" => "bar", "coordinateSystem" => "polar",
        "data" => [2, 1.2, 2.4, 3.6], "itemStyle" => Dict("color" => chartColor))],
))

#%% code id=4ae287
my_var = 69

#%% md id=89cd5e
Here is some embedded variable in markdown! {{ my_var }}

But can I embed it into LaTeX too?

$$x = e^{ {{my_var}} }$$

#%% md id=c18381
## Math in markdown

Inline math like $e^{i\pi} + 1 = 0$ flows in a sentence, and display math sits on
its own line:

$$\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$$

Backslash-escapes (`\,`, `\;`), subscripts $a_i$, and emphasis like _this_ all
coexist — the math is kept byte-for-byte, only _this_ becomes italic.
