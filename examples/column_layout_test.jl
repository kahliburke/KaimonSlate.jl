try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🧱 Column layout test

Exercises the `column=N` side-by-side layout across **content types** (markdown, code, ECharts plots,
a Makie image, an inline SVG, a table) and **column counts** (2, 3, 4). A cell tagged `column=N` (N≥2)
sits in the Nth slot of the row anchored by the preceding **untagged** cell — so you only tag the extra
columns. Plain (untagged) cells are full-width row anchors. This doubles as the HTML/Typst export fixture.
"""

#%% code id=setup hidecode
using CairoMakie, Random, Statistics, DataFrames
Random.seed!(7)
use_slate_theme!()

#%% md id=h_md
@md"""
## 2 columns — markdown │ markdown
"""

#%% md id=md_l
@md"""
**Left column.** Prose flows and wraps inside its half-width column. Lorem-ish text so we can see the
line breaks land at the column edge, not the page edge — with a `code span` and a [link](https://example.com).
"""

#%% md id=md_r column=2
@md"""
**Right column.** A second markdown block beside the first. A short list:
- one
- two
- three

Both halves should be equal width and top-aligned.
"""

#%% md id=h_code
@md"""
## 2 columns — code │ code
"""

#%% code id=code_l
# left: squares
sq = [i^2 for i in 1:8]

#%% code id=code_r column=2
# right: cumulative sum
cs = cumsum(1:8)

#%% md id=h_ec
@md"""
## 2 columns — ECharts plot │ ECharts plot
"""

#%% code id=ec_l
echart(:line, 1:24, cumsum(randn(24)); smooth = true, title = "Left · random walk")

#%% code id=ec_r column=2
echart(:bar, ["A", "B", "C", "D", "E"], [5, 12, 8, 15, 6]; title = "Right · bars")

#%% md id=h_mix
@md"""
## 2 columns — markdown │ plot (narrative beside a figure)
"""

#%% md id=mix_l
@md"""
The classic layout: **explanatory text** on the left, its **figure** on the right, at matching width.

The pie shows a three-way split; the prose can be as long as it needs and simply wraps within its
column while the chart holds its half.
"""

#%% code id=mix_r column=2
echart(:pie, ["Search", "Direct", "Social"], [48, 32, 20]; title = "Traffic", radius = ["40%", "70%"])

#%% md id=h_img
@md"""
## 2 columns — Makie image │ code
"""

#%% code id=img_l hidecode
let
    fig = Figure(size = (440, 280))
    ax = Axis(fig[1, 1]; title = "Makie (rendered PNG)")
    for i in 1:3
        lines!(ax, 1:24, cumsum(randn(24)); label = "s$i")
    end
    axislegend(ax; position = :lt)
    fig
end

#%% code id=img_r column=2
# code beside the rendered raster image — exercises an <img> in a flex column
kind    = "3-series random walk"
nseries = 3
backend = "CairoMakie"

#%% md id=h_svg
@md"""
## 2 columns — inline SVG image │ markdown
"""

#%% code id=svg_l hidecode
HTML(raw"""
<svg width="100%" viewBox="0 0 260 150" xmlns="http://www.w3.org/2000/svg">
  <rect width="260" height="150" rx="12" fill="#141828"/>
  <circle cx="90" cy="75" r="45" fill="#569cd6" opacity="0.85"/>
  <circle cx="165" cy="75" r="45" fill="#56d364" opacity="0.7"/>
  <text x="130" y="138" fill="#d4d8e8" font-size="13" text-anchor="middle">inline SVG</text>
</svg>""")

#%% md id=svg_r column=2
@md"""
An inline **SVG** on the left (a vector image via `HTML`), notes on the right. Verifies a non-chart,
non-raster image scales to its column.
"""

#%% md id=h_tbl
@md"""
## 2 columns — table │ plot
"""

#%% code id=tbl_l
DataFrame(metric = ["cpu %", "rss MB", "gc ms", "tasks"], value = [42, 1240, 8, 3])

#%% code id=tbl_r column=2
echart(:bar, ["cpu", "rss", "gc", "tasks"], [42, 1240, 8, 3]; title = "same data, charted")

#%% md id=h_three
@md"""
## 3 columns — plot │ plot │ plot
"""

#%% code id=t3a
echart(:line, 1:16, sin.((1:16) ./ 2); smooth = true, title = "sin")

#%% code id=t3b column=2
echart(:line, 1:16, cos.((1:16) ./ 2); smooth = true, title = "cos")

#%% code id=t3c column=3
echart(:bar, ["a", "b", "c", "d"], rand(1:9, 4); title = "rand")

#%% md id=h_three_mix
@md"""
## 3 columns — markdown │ code │ plot
"""

#%% md id=tm_a
@md"""
Left: a short **note** in column one.
"""

#%% code id=tm_b column=2
phi = (1 + sqrt(5)) / 2

#%% code id=tm_c column=3
echart(:scatter, randn(80), randn(80); symbolSize = 5, title = "cloud")

#%% md id=h_four
@md"""
## 4 columns — compact stat cells
"""

#%% code id=f4a
"⚡ CPU · 42%"

#%% code id=f4b column=2
"🧠 RSS · 1.2 GB"

#%% code id=f4c column=3
"♻ GC · 8 ms"

#%% code id=f4d column=4
"🧵 Tasks · 3"

#%% md id=h_full
@md"""
## Full-width interspersed (row boundaries)
"""

#%% md id=full1
@md"""
A **full-width** cell (no column tag) — it must break the previous row and not bleed into the next.
"""

#%% code id=fw_l
echart(:line, 1:40, cumsum(randn(40)); smooth = true, title = "wide-left")

#%% code id=fw_r column=2
echart(:bar, ["p", "q", "r", "s", "t", "u"], [2, 5, 3, 8, 4, 6]; title = "wide-right")

#%% md id=full2
@md"""
Another **full-width** cell after the 2-column row above — confirms the row closed cleanly.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 0c5f1f54-adec-418a-ab49-8c1950370bd1
# ╚═╡
