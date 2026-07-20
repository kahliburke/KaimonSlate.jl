try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# KaimonSlate

A **reactive** Julia notebook in the browser. Edit a cell or drag a widget and only the
*downstream* cells recompute. The source round-trips to this plain `.jl` file.
"""

#%% code id=highlight
# Tree-based Julia syntax highlighting (CodeMirror 6 + the Lezer Julia grammar).
function gram_schmidt(V::Matrix{Float64}; tol = 1e-10)   # types, kwargs, comment
    n = size(V, 2)
    Q = zeros(Float64, size(V, 1), n)
    for j in 1:n
        q = V[:, j]
        for k in 1:(j - 1)
            q -= (Q[:, k]' * V[:, j]) .* Q[:, k]
        end
        nrm = sqrt(sum(abs2, q))
        Q[:, j] = nrm < tol ? q : q ./ nrm
    end
    return Q
end

#%% code id=controls
@bind freq Slider(1:0.5:8; default = 2, label = "frequency")
@bind showcos Toggle(false; label = "cosine", on = "shown", off = "hidden")
@bind hue ColorPicker("#56d364"; label = "color")

#%% code id=chart
# Reads freq, showcos, hue — recomputes live as you drag the slider or toggle the controls.
x = range(0, 2π; length = 240)
waves = [series(:line, collect(x), round.(sin.(freq .* x); digits = 3); name = "sin", smooth = true, color = hue)]
showcos && push!(waves, series(:line, collect(x), round.(cos.(freq .* x); digits = 3); name = "cos", smooth = true))
echart(waves...; title = "frequency = $freq", legend = true)

#%% md id=mdinterp
@md"""
## Markdown + interpolation

Markdown cells render GFM tables, LaTeX math, and **double-brace interpolation** of live
Julia values. At frequency **{{ freq }}** the wave's period is
{{ round(2π / freq; digits = 2) }} — and the math typesets: $\int_0^\pi \sin x \, dx = 2$.
"""

#%% code id=table
slate_table([(x = round(x; digits = 2), sinx = round(sin(x); digits = 3))
             for x in range(0, π; length = 7)])

#%% code id=boom
# An error names the offending line and is clickable — even across cells.
total = 0
total = total + missing_value
total

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = da21e6d1-3528-457f-951f-9b768a16a585
# ╚═╡
