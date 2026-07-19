# Export

KaimonSlate exports a notebook four ways: a self-contained **HTML** document, a
publication-quality **PDF** (rendered server-side with Typst), browser **Print HTML**, and a
fully reproducible **self-contained `.jl`**.

## Export HTML

**☰ → Export HTML** downloads a single `.html` file with everything inlined:

- Markdown cells rendered (GFM tables, KaTeX math).
- Code cells with their source and output (values, stdout, errors).
- Figures embedded as base64 — CairoMakie rasters directly, and client-rendered **ECharts
  frozen to their latest snapshot PNG**.
- Interactive tables flattened to static HTML.

No scripts to boot and no server required — the file opens offline, with KaTeX pulled from a
CDN to typeset math. The route is `GET /api/<id>/export.html` (`?dl=1` to download,
`?source=0` for an output-only document).

## Publication PDF (Typst)

**☰ → Export PDF (publication)** renders a typeset PDF **server-side via Typst** — not a
browser print. A small dialog (remembered between exports) offers:

- **Theme** — *As-is*, *Light* (publication), or *Dark*. **As-is** reuses each figure exactly as
  it's already rendered in the live UI (fastest — nothing re-renders). **Light** and **Dark**
  force a canonical palette and **re-render every figure for the export** so the whole document is
  internally consistent regardless of the live theme: native **Makie** figures are re-rendered on
  the worker under the chosen palette, and **ECharts** are re-drawn in the matching chart theme.
  (The dialog flags an override, since re-rendering takes a moment.)
- **Layout** — *Article* / *Report* × *single* / *two-column* (the title and abstract span the
  full width above the columns).
- **Body text** — *Auto* (compact for two-column), *Large*, *Normal*, *Compact*, *Small*.
- **Code listings** — *Normal* / *Small* / *Smaller* / *Tiny* font, or *Hidden* (outputs only).

![The PDF export dialog: theme, layout, body-text and code-listing options](./assets/export-dialog.png)

Highlights:

- **Vector figures** — CairoMakie figures embed as **PDF** (fonts embedded, crisp at any
  scale); ECharts charts embed as **SVG** in the export's theme. Rasters are the fallback.
- **Math** through LaTeX (`mitex`), with a shim preamble for commands `mitex` lacks.
- **Frozen controls** — `@bind` widgets render as a compact *parameters* strip at their
  current values (a PDF is a snapshot).
- **Academic front matter** — if the first markdown cell opens with a `---`-fenced block, its
  `title` / `subtitle` / `author` / `date` / `abstract` render as a title block (the title
  overrides the filename) and the rest of that cell becomes body text.

The route is `GET /api/<id>/export.pdf` with `?theme=`, `?style=`, `?columns=`, `?body=`,
`?code=`. The bundled `Typst_jll` is used unless a system `typst` is on `PATH`.

## Print HTML

**☰ → Print HTML** opens the static HTML document in a new tab and triggers your browser's
print dialog — a quick path to PDF when you don't need the Typst typesetting.

## Self-contained single-source `.jl`

**☰ → Export self-contained `.jl`** produces one `.jl` that carries the notebook **and** its
full environment, for sharing or archiving. The runnable cells are followed by a `Slate.bundle`
footer embedding (gzip + base64):

- `Project.toml` + `Manifest.toml` of the active environment (fully pinned),
- the **local / path-dependency source** (the parent module code) under `local/<pkg>/`,
- when the project is a git repo, a **shallow git bundle** (`repo.gitbundle`) + the `origin`
  URL — so an expanded copy can attach to the original remote with **matching SHAs**.

A standalone `.jl` still opens as an ordinary notebook (the bundle footer is ignored on
parse). To reinflate it into a project tree:

```julia
using KaimonSlate
expand("notebook.standalone.jl")          # → notebook.standalone.expanded/
```

`expand` writes `Project.toml` + `Manifest.toml`, the local source under `local/`, the
runnable notebook, and — when a git bundle is present — **auto-clones it into `repo/` with
`origin` rewired**, handing back a git repo whose tip SHA matches the original (branch & PR
straight away). It prints how to `Pkg.instantiate` the environment.

The route is `GET /api/<id>/export.standalone.jl`.

## Notes

- ECharts snapshots are captured from the live canvas as you view the notebook, so open a
  cell's chart at least once before exporting (HTML, PDF, or standalone) to ensure its snapshot
  is current.
- A notebook's own front-end code is self-contained: [web cells](frontend-extensions.md), `WebPage`
  output, and `@use` imports carry their HTML/CSS/JS (and import map) into the exported page, so
  custom widgets and scripts keep working offline.
- Markdown chart / table interpolations (double-brace `echart(…)` / `slate_table(…)`) are
  client-hydrated and appear as static placeholders in HTML; scalar and image interpolations embed directly.
