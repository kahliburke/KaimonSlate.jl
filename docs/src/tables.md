# Tables

`slate_table` renders any table — a `DataFrame`, any [Tables.jl](https://github.com/JuliaData/Tables.jl)
source, or a `Vector` of `NamedTuple`s — as an interactive, **sortable, filterable, paginated**
table. Return it from a cell (a bare `DataFrame` auto-renders through the same path):

```julia
slate_table(df)
```

![An interactive slate_table with sortable, filterable columns](./assets/table.png)

## Sort, filter, page

- **Sort** — click a column header; click again to flip ascending/descending. Numeric columns
  sort numerically, not lexically.
- **Filter** — the box above the table filters rows as you type (a *search* box for server-paged
  tables — see [below](#Big-data-—-server-paging)).
- **Page** — large results paginate. The footer shows the visible range and the total, and a page
  number can be clicked to jump. Page size is 25 for an ordinary table and is set by `page_size` only
  when `paged = true`; the reader cannot change it.

Each column can opt out of sorting or filtering; numeric columns right-align by default.

An ordinary table ships at most **5000 rows**, and says so in the footer (`capped at 5000 of N`) when
it truncates. Use `paged = true`, or `slate_query`, to browse past that.

## Column formatting

Numbers render cleanly out of the box. For richer display, pass **`format`** — a
column-name-keyed `NamedTuple` (or `Dict`) — with a preset per column:

| Preset | Renders | Example |
| --- | --- | --- |
| `:currency` | `$1,234.50` | `Revenue = :currency` |
| `:percent` | `41.8%` | `Margin = :percent` |
| `:integer` | `1,204` (grouped) | `Units = :integer` |
| `:fixed` | `3.14` | `Ratio = :fixed` |
| `:scientific` | `6.02e23` | `N = :scientific` |
| `:bytes` | `1.0 MB` | `Size = :bytes` |

Tune any preset with a spec — `(kind = :percent, digits = 1)`, `(kind = :currency, prefix = "€")`,
`(kind = :fixed, digits = 3, sep = true)`. Alongside `format`, **`align`** (`:left`/`:right`/`:center`)
and **`coltype`** override the inferred defaults:

```julia
slate_table(df;
    format = (Revenue = :currency, Margin = (kind = :percent, digits = 1), Size = :bytes),
    align  = (Product = :left,))
```

Each of these takes a `NamedTuple`, so a one-entry one needs its trailing comma. `(Product = :left)`
without it is a parenthesized assignment, and `slate_table` rejects it.

`default_format` applies one spec to **every** numeric column, for when you would otherwise list them
all. An explicit `format` entry for a column still wins:

```julia
slate_table(df; default_format = :integer, format = (Margin = :percent,))
```

The same formatting is applied server-side, so it carries into exported HTML and PDF (see
[Publishing](#Publishing-and-export)). `export_rows = n` caps a fixed export (PDF, markdown, static
HTML) to the first `n` rows with a "showing n of N" note, leaving the live table fully paginated.

## In-cell visualization

Turn a numeric column into an in-cell **bar** or **heat** strip with **`viz`** — a compact way to
read magnitude down a column at a glance:

```julia
slate_table(df; format = (Revenue = :currency,), viz = (Revenue = :bar, Margin = :heat))
```

![A slate_table with currency / percent / bytes formatting and in-cell bar and heat columns](./assets/table-formatted.png)

## Clickable rows — `TableSelect`

Bind the row a reader clicks with the [`TableSelect`](widgets.md) widget — the bound value is that
row as a `NamedTuple`, so downstream cells can read its fields:

```julia
@bind sel TableSelect(df)      # sel.product, sel.revenue, … ; `nothing` until a row is clicked
```

Only the first `maxrows` rows (default 200) are rendered and selectable, so a large frame stays
responsive; the footer flags the truncation. Raise it with `TableSelect(df; maxrows = 1000)`, and
give `default` a 1-based row index to start with one selected.

## Big data — server paging

For large or lazy data, keep it **server-side** so only the visible page crosses the wire:

```julia
slate_table(df; paged = true, page_size = 100)   # eager table, paged over the wire
slate_query(conn, "SELECT …")                    # a SQL source, paged in the database
```

Sorting, filtering, and paging then run **where the cells evaluate** (the gate worker), so a
million-row frame stays snappy in the browser. `slate_query` goes further and pushes them into SQL,
against a DBInterface connection such as a `DuckDB.DB` or `SQLite.DB`.

For a source that is neither a frame nor SQL, subtype `PagedProvider` and give it `page_columns` and
`fetch_page`.

## Matrices

Returning a bare `AbstractMatrix` renders it without you asking. A small one becomes KaTeX, or dotted
notation when it is a little larger; a large or sparse one becomes a downsampled heatmap.

`slate_matrix(M; kind, max_cells, …)` overrides that choice, or its defaults.

## In markdown, and when published

Tables interpolate into markdown cells with double-brace interpolation, so a table can sit inline
in your prose (see [Notebook Basics](notebook-basics.md#Markdown-interpolation)):

```markdown
Latest figures: {{ slate_table(df) }}
```

### Publishing and export

Tables travel well into [exports](export.md) and [published pages](publishing.md):

- **HTML** — rendered as clean static HTML with the same per-column formatting, alignment, and
  in-cell bar/heat viz as the live table.
- **PDF (Typst)** — typeset as a themed grid with per-column alignment and the numeric formatting
  preserved, so a formatted financial table looks right in a publication-quality document.

So a table you style once reads the same in the notebook, in a shared HTML page, and in a printed
PDF — no re-authoring.
