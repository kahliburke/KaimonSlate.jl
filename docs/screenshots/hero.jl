#%% md id=intro
# A reactive Julia notebook

Move a control and only the cells that depend on it recompute — the chart below redraws live
as you drag the slider or flip the toggle.

#%% code id=controls
@bind freq Slider(1:0.5:8; default = 3, label = "frequency")
@bind showcos Toggle(false; label = "cosine", on = "shown", off = "hidden")

#%% code id=wave
x = range(0, 2π; length = 160)
waves = [series(:line, collect(x), sin.(freq .* x); name = "sin", color = "#56d364")]
showcos && push!(waves, series(:line, collect(x), cos.(freq .* x); name = "cos"))
echart(waves...; title = "freq = $freq", legend = true)
