try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# A reactive Julia notebook

Move a control and only the cells that depend on it recompute — the chart below redraws live
as you drag the slider or flip the toggle.
"""

#%% code id=controls
@bind freq Slider(1:0.5:8; default = 3, label = "frequency")
@bind showcos Toggle(false; label = "cosine", on = "shown", off = "hidden")

#%% code id=wave
x = range(0, 2π; length = 160)
waves = [series(:line, collect(x), sin.(freq .* x); name = "sin", color = "#56d364")]
showcos && push!(waves, series(:line, collect(x), cos.(freq .* x); name = "cos"))
echart(waves...; title = "freq = $freq", legend = true)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 01c72759-346b-4f70-92be-e08ec0380098
# ╚═╡
