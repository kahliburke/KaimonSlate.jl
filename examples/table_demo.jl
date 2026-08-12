try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 📊 `slate_table` — formatting, in-cell visuals, paging

`slate_table` renders tabular data as a real table widget rather than a printed grid. It takes either
a header vector plus rows, or anything table-shaped like a `DataFrame`.

Two keyword arguments carry most of the value. `format` states what a column *means* — `:currency`,
`:percent`, `:integer`, optionally with `digits` — so numbers are formatted at the point of display
while the underlying values stay untouched. `viz` draws a per-cell `:bar` or `:heat` inside the
column, which reads a distribution far faster than scanning digits.
"""

#%% md id=h_rows
@md"""
## Header and rows

The simplest form: a vector of column names and a vector of row vectors. Columns are typed from the
data, so the numeric columns sort numerically rather than lexically.
"""

#%% code id=sales
slate_table(
    ["Product", "Units", "Revenue", "Margin", "In stock"],
    [["Widget Alpha", 1200, 45999.50, 0.324, true],
     ["Widget Beta", 340, 12050.0, 0.281, false],
     ["Gadget Prime", 8750, 210000.0, 0.4153, true],
     ["Doohickey", 42, 899.99, 0.15, true],
     ["Contraption XL", 15300, 1250000.0, 0.512, false]])

#%% md id=h_fmt
@md"""
## The same table, formatted

`Revenue` becomes currency, `Margin` a percentage to one decimal, `Units` a grouped integer. Same
data, same call — only the presentation spec is added.
"""

#%% code id=fmt_sales
slate_table(
    ["Product", "Units", "Revenue", "Margin", "In stock"],
    [["Widget Alpha", 1200, 45999.50, 0.324, true],
     ["Widget Beta", 340, 12050.0, 0.281, false],
     ["Gadget Prime", 8750, 210000.0, 0.4153, true],
     ["Contraption XL", 15300, 1250000.0, 0.512, false]];
    format = (Revenue = :currency, Margin = (kind = :percent, digits = 1), Units = :integer))

#%% md id=h_df
@md"""
## A DataFrame, with in-cell visuals and paging

At this size, reading the numbers one by one stops working. `viz` puts a bar in `revenue` and a heat
shade in `score`, so the shape of each column is visible at a glance. Large tables page in the
browser; `export_rows` caps how many rows a static HTML or PDF export carries, since an exported page
has no server to page against.
"""

#%% code id=setup
using DataFrames, Random
Random.seed!(11)

n = 120
df = DataFrame(
    product = ["SKU-" * lpad(i, 4, '0') for i in 1:n],
    region  = rand(["north", "south", "east", "west"], n),
    units   = rand(20:20_000, n),
    revenue = round.(rand(n) .* 250_000; digits = 2),
    margin  = round.(0.05 .+ rand(n) .* 0.45; digits = 4),
    score   = round.(rand(n) .* 100; digits = 1),
)

#%% code id=bigtbl
slate_table(df;
    format = (revenue = :currency, margin = (kind=:percent, digits=1), units = :integer),
    viz    = (revenue = :bar, score = :heat),
    export_rows = 12)

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 95373a68-f877-463a-9449-9ef83e322bb8
# ╚═╡
