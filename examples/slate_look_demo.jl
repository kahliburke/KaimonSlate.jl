#%% md id=intro
# 🎨 Slate look — ECharts & Makie, one theme

Interactive **ECharts** figures are auto-themed to the active UI palette (and re-color when you
switch the Slate theme in **Settings → Theme**). **Makie** figures match via `use_slate_theme!()`,
so a rendered plot and an interactive one read as one system.

_Test: run the cells, then switch the Slate theme — the ECharts charts should recolor **without a
reload**. The Makie cells need `CairoMakie` in this notebook's env (add it from the 📦 package pane)._

#%% md id=h_echarts
## ECharts — themed from the UI palette

#%% code id=ec_multi
echart(series(:line, 1:12, cumsum(randn(12)); name = "alpha", smooth = true),
       series(:line, 1:12, cumsum(randn(12)); name = "beta", smooth = true),
       series(:bar,  1:12, 2 .+ 2 .* rand(12); name = "gamma");
       title = "Slate palette · switch the theme to recolor", legend = true)

#%% code id=ec_pie
echart(:pie, ["Search", "Direct", "Email", "Ads", "Social"], [1048, 735, 580, 300, 210];
       title = "Categorical hues", radius = ["40%", "70%"])

#%% md id=h_makie
## Makie — the matching theme

`use_slate_theme!()` applies the shared look globally; `slate_theme()` returns the `Theme` if you
want to compose it. Transparent background, the same series colours, palette-toned grid/axes, and a
figure height aligned to the ECharts cell.

#%% code id=mk_setup hidecode
using CairoMakie
use_slate_theme!()
"Makie is now on the Slate look — the figures below should match the charts above."

#%% code id=mk_lines
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Makie — matching theme", xlabel = "t", ylabel = "value")
    for i in 1:4
        lines!(ax, 1:24, cumsum(randn(24)); label = "series $i")
    end
    axislegend(ax; position = :lt)
    fig
end

#%% code id=mk_scatter
let
    fig = Figure()
    ax = Axis(fig[1, 1]; title = "Palette check")
    for i in 1:5
        scatter!(ax, randn(60) .+ i, randn(60); label = "g$i", markersize = 7)
    end
    fig
end
