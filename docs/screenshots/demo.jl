#%% md id=intro
# KaimonSlate

A **reactive** Julia notebook in the browser. Edit a cell or drag a widget and only the
*downstream* cells recompute. The source round-trips to this plain `.jl` file.

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

#%% code id=slider
@bind n Slider(4:2:60; default = 24, label = "samples")

#%% code id=chart
# Reads `n` — re-renders live as you drag the slider.
xs = range(0, 2π; length = n)
echart(:line, round.(collect(xs); digits = 2), round.(sin.(xs); digits = 3);
       smooth = true, title = "sin(x), $(n) samples")

#%% md id=mdinterp
## Markdown + interpolation

Markdown cells render GFM tables, LaTeX math, and **double-brace interpolation** of live
Julia values. With **{{ n }}** samples, the mean of sine over one period is
{{ round(sum(sin.(range(0, 2π; length = n))) / n; digits = 3) }} — and the math
typesets: $\int_0^\pi \sin x \, dx = 2$.

#%% code id=table
slate_table([(x = round(x; digits = 2), sinx = round(sin(x); digits = 3))
             for x in range(0, π; length = 7)])

#%% code id=boom
# An error names the offending line and is clickable — even across cells.
total = 0
total = total + missing_value
total
