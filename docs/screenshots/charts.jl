try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Charts — `echart`

Slate's ECharts DSL. Express (`echart(:kind, x, y)`), composable (`series(…)`), or raw.
"""

#%% code id=line
echart(:line, ["Mon", "Tue", "Wed", "Thu", "Fri"], [120, 200, 150, 80, 70];
       title = "Weekly visits", smooth = true)

#%% code id=bar
echart(:bar, ["A", "B", "C", "D", "E"], [5, 20, 36, 10, 12]; title = "Counts")

#%% code id=area
echart(:area, collect(0:11), [3, 5, 4, 7, 9, 8, 11, 10, 13, 12, 15, 14];
       title = "Cumulative", smooth = true)

#%% code id=scatter
echart(:scatter, randn(600), randn(600); symbolSize = 4, title = "Gaussian cloud")

#%% code id=pie
echart(:pie, ["Search", "Direct", "Email", "Ads"], [1048, 735, 580, 300]; title = "Traffic")

#%% code id=heatmap
hours = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
days  = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
z = [(i * 3 + j * 2) % 11 for j in 1:7, i in 1:8]
echart(:heatmap, hours, days, z; title = "Activity")

#%% code id=candlestick
echart(:candlestick, ["10/1", "10/2", "10/3", "10/4", "10/5", "10/6"],
       [[20, 34, 10, 38], [40, 35, 30, 50], [31, 38, 33, 44],
        [38, 15, 5, 42], [15, 25, 8, 28], [25, 30, 20, 36]]; title = "OHLC")

#%% code id=radar
echart(:radar,
       ["Sales" => 6500, "Admin" => 16000, "Tech" => 30000, "Support" => 38000, "Dev" => 52000],
       ["Allocated" => [4200, 3000, 20000, 35000, 50000],
        "Actual"    => [5000, 14000, 28000, 26000, 42000]]; title = "Budget", legend = true)

#%% code id=boxplot
groups  = ["A", "B", "C", "D"]
samples = [randn(60) .+ g for g in 1:4]
echart(:boxplot, groups, samples; title = "Distributions")

#%% code id=composable
t = range(0, 2π; length = 140)
echart(series(:line, collect(t), sin.(t); name = "sin", smooth = true),
       series(:bar,  collect(t), 0.3 .* sin.(2 .* t); name = "0.3·sin 2t");
       title = "Composable", legend = true)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = eb195579-b887-490d-ae2a-36fe058470fb
# ╚═╡
