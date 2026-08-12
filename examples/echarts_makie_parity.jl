try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# ⚖️ ECharts ↔ Makie parity

The same data through **both** chart libraries, on the **same Slate theme**, stacked so you can compare
them directly (ECharts on top, Makie below each). The goal is *parity*: an interactive ECharts figure
and a rendered Makie figure should read as one system — same palette order, transparent background,
palette-toned grid/axes, and matching scale.

Pick a theme below. It's a plain `@bind` — so the choice **flows through the dependency graph**: the
`use_slate_theme!(theme = ui_theme)` cell re-runs and every figure that reads the theme re-renders. So
the **ECharts** *and* the server-rendered **Makie** charts re-theme together, automatically, with no
manual re-run (and it propagates to region workers via the same edges).
"""

#%% code id=theme_pick hidecode
@bind ui_theme Radio(["midnight" => "Midnight", "graphite" => "Graphite", "nord" => "Nord",
                      "dracula" => "Dracula", "solarized-dark" => "Solarized Dark",
                      "daylight" => "Daylight", "solarized-light" => "Solarized Light"], "midnight")

#%% md id=h_setup
@md"""
## Setup — shared theme + shared data

`use_slate_theme!(theme = ui_theme)` puts Makie on the Slate look for the selected theme; because this
cell reads `ui_theme`, switching the Radio re-runs it — and the graph re-renders every figure below to
match. Every pair draws from the same seeded arrays, so any visual difference is a real library
difference, not different numbers.
"""

#%% code id=setup hidecode
using CairoMakie, Random, Statistics
use_slate_theme!(theme = string(ui_theme))   # reads the theme Radio → re-runs + re-renders every figure on a switch
Random.seed!(1234)

lx      = 1:24
lines3  = [cumsum(randn(24)) for _ in 1:3]          # multi-series line
bcats   = ["A", "B", "C", "D", "E"]                 # categorical bar
bvals   = [5.0, 20, 36, 10, 12]
scx     = randn(400); scy = 0.5 .* scx .+ randn(400) # scatter cloud
arx     = 1:40; ary = cumsum(randn(40))             # area
hz      = [sin(i / 3) * cos(j / 4) for i in 1:12, j in 1:12]  # heatmap field
bgroups = ["A", "B", "C", "D"]                       # boxplot groups
bsamples = [randn(60) .+ g for g in 1:4]
"parity data ready"

#%% md id=h_line
@md"""
### Line — multi-series
"""

#%% code id=ec_line
echart([series(:line, collect(lx), lines3[i]; name = "s$i", smooth = true) for i in 1:3]...;
       title = "Line · ECharts", legend = true)

#%% code id=mk_line column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Line · Makie", xlabel = "t", ylabel = "value")
    for i in 1:3
        lines!(ax, lx, lines3[i]; label = "s$i")
    end
    axislegend(ax; position = :lt)
    fig
end

#%% md id=h_bar
@md"""
### Bar — categorical
"""

#%% code id=ec_bar
echart(:bar, bcats, bvals; title = "Bar · ECharts")

#%% code id=mk_bar column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Bar · Makie", xticks = (1:length(bcats), bcats))
    barplot!(ax, 1:length(bcats), bvals)
    fig
end

#%% md id=h_scatter
@md"""
### Scatter
"""

#%% code id=ec_scatter
echart(:scatter, scx, scy; symbolSize = 6, title = "Scatter · ECharts")

#%% code id=mk_scatter column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Scatter · Makie")
    scatter!(ax, scx, scy; markersize = 7)
    fig
end

#%% md id=h_area
@md"""
### Area — filled line
"""

#%% code id=ec_area
echart(series(:line, collect(arx), ary; smooth = true, areaStyle = Dict());
       title = "Area · ECharts")

#%% code id=mk_area column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Area · Makie")
    band!(ax, arx, zeros(length(arx)), ary)
    lines!(ax, arx, ary)
    fig
end

#%% md id=h_heatmap
@md"""
### Heatmap

Watch this pair: ECharts colours from its `visualMap`, Makie from its `colormap` — a sequential-palette
parity gap the Slate theme doesn't yet close on both sides.
"""

#%% code id=ec_heatmap
echart(:heatmap, string.(1:12), string.(1:12), hz; title = "Heatmap · ECharts")

#%% code id=mk_heatmap column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Heatmap · Makie")
    hm = heatmap!(ax, hz)
    Colorbar(fig[1, 2], hm)
    fig
end

#%% md id=h_box
@md"""
### Boxplot
"""

#%% code id=ec_box
echart(:boxplot, bgroups, bsamples; title = "Boxplot · ECharts")

#%% code id=mk_box column=2
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Boxplot · Makie", xticks = (1:4, bgroups))
    cats = reduce(vcat, [fill(i, length(bsamples[i])) for i in 1:4])
    vals = reduce(vcat, bsamples)
    boxplot!(ax, cats, vals)
    fig
end
