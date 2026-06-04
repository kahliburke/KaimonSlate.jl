#%% md id=intro
# Display upgrades — LaTeX & tables

This notebook exercises the **display** layer: LaTeX math in markdown and in
output, plus tabular rendering. Math is typeset client-side by KaTeX.

#%% md id=mathmd
## Math in markdown

Inline math like $e^{i\pi} + 1 = 0$ flows in a sentence, and display math sits on
its own line:

$$\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$$

Backslash-escapes (`\,`, `\;`), subscripts $a_i$, and emphasis like _this_ all
coexist — the math is kept byte-for-byte, only _this_ becomes italic.

#%% code id=imports
# Imports live in their own cell (standard practice) — value cells below never
# introduce methods, so rich-MIME capture is never racing a freshly-loaded `show`.
using LaTeXStrings

#%% code id=latexval
# A `LaTeXString` (text/latex) value is captured and typeset by KaTeX. Any type
# with a text/latex `show` works the same way (Symbolics, Latexify, …).
L"\frac{\partial \mathcal{L}}{\partial q} - \frac{d}{dt}\frac{\partial \mathcal{L}}{\partial \dot q} = 0"

#%% code id=quadratic
# Computed LaTeX: substitute coefficients into the quadratic formula via %$ interpolation.
a, b, c = 1, -3, 2
disc = b^2 - 4a*c
L"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a} = \frac{%$(-b) \pm \sqrt{%$disc}}{%$(2a)}"

#%% md id=tablesmd
## Interactive tables

A returned **DataFrame** (or any Tables.jl source) auto-renders as a sortable,
filterable, paged table — click a header to sort, type in the filter box, page
through with the controls. `slate_table(data)` does the same for a `Vector` of
`NamedTuple`s, a `Dict`/`NamedTuple` of column vectors, or explicit `columns, rows`.

#%% code id=tableimports
# Imports in their own cell (as above) — keep value cells method-introduction-free.
using Random, DataFrames

#%% code id=tabledata
# `slate_table` on a vector of NamedTuple rows. Numbers sort numerically; the
# `metal` booleans and strings sort lexically.
Random.seed!(42)
elements = ["H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne"]
slate_table([(symbol = e, Z = i, mass = round(2.0i + randn(), digits = 3), metal = i in (3, 4))
             for (i, e) in enumerate(elements)])

#%% code id=3837ae
elements

#%% code id=tabledf
# A bare DataFrame auto-renders (no slate_table call). 30 rows ⇒ pagination kicks in.
DataFrame(x = 1:30, square = (1:30) .^ 2, parity = ifelse.(iseven.(1:30), "even", "odd"))

#%% md id=pagedmd
## Large tables — server-paged

These tables keep their data in the **worker**; the browser fetches one page at a
time, so size doesn't matter. `slate_table(df; paged=true)` pages an in-memory
frame; `slate_query` runs the sort / search / paging as **SQL** (here, DuckDB).

#%% code id=pagedmem
# 100k rows, paged in-memory — only the visible page ever crosses the wire.
slate_table(DataFrame(i = 1:100_000,
                      v = round.(sin.((1:100_000) ./ 1000), digits = 4),
                      bucket = mod.(1:100_000, 7)); paged = true)

#%% code id=sqlimports
using DuckDB, DBInterface
const con = DBInterface.connect(DuckDB.DB)
nothing

#%% code id=pagedsql
# 1,000,000 rows in DuckDB, browsed with SQL pushdown (sort/search/page in the DB).
slate_query(con, "SELECT i, i*i AS sq, (i % 3) AS m FROM range(1, 1000001) t(i)")
