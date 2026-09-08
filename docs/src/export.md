# Export

KaimonSlate exports a notebook as a self-contained **HTML** page, a publication-quality **PDF**
(rendered server-side with Typst), **Markdown**, a fully reproducible **self-contained `.jl`**, and
an [**app**](app-mode.md) folder someone else can run.

One **Export** entry in the ☰ menu opens a dialog where you pick the format and its options. Your
choices are remembered between exports.

## Export HTML

A single file that opens with no server behind it. What lands in it:

- Markdown cells rendered (GFM tables, KaTeX math).
- Code cells with their source and output (values, stdout, errors).
- Makie figures embedded as base64 images.
- ECharts figures embedded as their specifications and re-drawn in the browser, so hover, zoom,
  legend toggles and tooltips keep working.
- Tables with their sort, filter, paging and CSV download intact.
- `@bind` controls rendered as real controls, but disabled. Marking what they drive with
  [`@replay`](replay.md) ships results for every position of the control and makes them work.

Options for this format:

| Option | What it does |
| --- | --- |
| **Outputs** | All, figures only, or prose and code only. |
| **Theme** | As-is, Light, or Dark. Overriding re-renders every figure for the export. |
| **Chart renderer** | Auto (each chart's own setting), Canvas, or SVG. SVG is vector, so it stays crisp in print. A reader can override it with `?renderer=svg` on the URL. |
| **Code size** | Normal down to tiny. |
| **Page width** | The content column, from 620px to full width. |
| **Source** | Include cell sources, or export outputs only. |
| **Offline** | Inline KaTeX, ECharts and the widget stack instead of linking a CDN, so the page renders with no network at all. Adds roughly a megabyte. |
| **Data** | Gzip the inlined libraries and data. Typically halves the file, and needs Chrome 80, Safari 16.4 or Firefox 113 to inflate. Numeric arrays are narrowed to 32-bit either way. |
| **Runnable** | Embed the reproducible bundle and a "Run live" button, so a reader can run the notebook on their own machine. |
| **Git history** | With Runnable on, ship the project's full history so a reader can branch and open a pull request with matching commits. Off ships the current source only, which is the safer default for a public page. |
| **Precomputed results** | Embed cached cell results so a reader who runs it live skips the expensive cells. Entries are chosen by compute saved per byte. |
| **Interim preview** | Embed the last rendered figures so they show immediately while the live environment rebuilds behind them. |

**🔗 Share via Gist** uploads the export as a secret GitHub gist and copies a download command to
your clipboard. It needs the `gh` CLI, authenticated.

If the notebook has any `@replay` marks, confirming opens a second step for choosing how finely to
sweep each control. See [Offline interactivity](replay.md).

The route is `GET /api/<id>/export.html` (`?dl=1` to download, `?source=0` for an output-only
document).

## Publication PDF (Typst)

The **PDF** format renders a typeset document **server-side via Typst** — not a browser print. It
offers:

- **Theme** — *As-is*, *Light* (publication), or *Dark*. **As-is** reuses each figure exactly as
  it's already rendered in the live UI (fastest — nothing re-renders). **Light** and **Dark**
  force a canonical palette and **re-render every figure for the export** so the whole document is
  internally consistent regardless of the live theme: native **Makie** figures are re-rendered on
  the worker under the chosen palette, and **ECharts** are re-drawn in the matching chart theme.
  (The dialog flags an override, since re-rendering takes a moment.)
- **Layout** — *Article* / *Report* × *single* / *two-column* (the title and abstract span the
  full width above the columns), or *Slides* for a 16:9 presentation deck.
- **Speaker notes** — on a slides layout, append one notes page per slide that has `notes` cells.
- **Body text** — *Auto* (compact for two-column), *Large*, *Normal*, *Compact*, *Small*.
- **Code listings** — *Normal* / *Small* / *Smaller* / *Tiny* font, or *Hidden* (outputs only).
- **Parameters** — show `@bind` controls as a strip at their current values. Off by default, so a
  PDF carries no controls unless you ask for them.
- **Typst source** — also download the editable Typst project as a `.tar.gz`: `doc.typ` plus its
  assets, which recompiles with `typst compile doc.typ` if you want to hand-finish the typesetting.
  Its route is `GET /api/<id>/export.typ`, taking the same options as `export.pdf`.

![The PDF export dialog: theme, layout, body-text and code-listing options](./assets/export-dialog.png)

Highlights:

- **Vector figures** — CairoMakie figures embed as **PDF** (fonts embedded, crisp at any
  scale); ECharts charts embed as **SVG** in the export's theme. Rasters are the fallback.
- **Math** through LaTeX (`mitex`), with a shim preamble for commands `mitex` lacks. All four
  delimiter spellings work — `$…$`, `$$…$$`, `\(…\)`, `\[…\]` — the bracket forms are normalized
  to the dollar forms on the way in, so a notebook reads the same on screen and in print.
- **Frozen controls** — with **Parameters** ticked, `@bind` widgets render as a compact strip at
  their current values (a PDF is a snapshot).
- **Academic front matter** — if the first markdown cell opens with a `---`-fenced block, its
  `title` / `subtitle` / `author` / `date` / `abstract` render as a title block (the title
  overrides the filename) and the rest of that cell becomes body text.

The route is `GET /api/<id>/export.pdf` with `?theme=`, `?style=`, `?columns=`, `?body=`,
`?code=`. The bundled `Typst_jll` is used unless a system `typst` is on `PATH`.

### Writing for print only

You author in Markdown and LaTeX, not Typst — the `.typ` document is generated. For the cases
where print needs something the screen doesn't, a markdown cell can address each surface on its
own. Both markers are HTML comments, so neither disturbs the other view:

````markdown
<!--raw-typst #pagebreak() -->

<!--typst-begin-exclude-->
This paragraph is for readers of the live notebook, and never reaches the PDF.
<!--typst-end-exclude-->
````

`raw-typst` passes its body through as **Typst code** — a page break, a `#place`, a `#set text(…)`
— and the browser sees only an HTML comment, so it shows nothing. `typst-begin-exclude` is the
mirror: the enclosed markdown renders normally on screen and is dropped from the PDF.

Only these two markers are honoured. Typst syntax written loose in a markdown cell is escaped and
printed as ordinary text, since the cell is CommonMark first.

## Self-contained single-source `.jl`

The **Standalone .jl** format produces one `.jl` that carries the notebook **and** its
full environment, for sharing or archiving. The runnable cells are followed by a `Slate.bundle`
footer embedding (gzip + base64):

- `Project.toml` + `Manifest.toml` of the active environment (fully pinned),
- the **local / path-dependency source** (the parent module code) under `local/<pkg>/`,
- when the project is a git repo, a **shallow git bundle** (`repo.gitbundle`) + the `origin`
  URL — so an expanded copy can attach to the original remote with **matching SHAs**.

Two options decide how it behaves when someone opens it:

- **Precomputed results** — a size budget for embedded cached cell results, so an expensive notebook
  restores instead of recomputing. Entries are chosen by compute saved per byte, so even a small
  budget banks the most expensive work.
- **Interim preview** — embed the last rendered figures and tables so they appear the instant it
  opens, while the live environment rebuilds behind them. This is distinct from precomputed results,
  which restore the underlying values.

Both are also offered for the HTML export's **Runnable** bundle.

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

## Markdown

The **Markdown** format writes GitHub-flavored Markdown for pasting into Discourse, Slack or a
GitHub issue, or saving as a `.md`. It offers whether to include cell sources as ```` ```julia ````
blocks, an image scale (full, max 800px, or max 480px, for hosts with paste size limits), and
whether to name the file `README.md` so GitHub renders it.

Figures embed as data-URI images. GitHub does not render those, so upload a PNG alongside if the
destination is a repository.

The route is `GET /api/<id>/export.md`.

## App

The **App** format writes a folder that runs as an application, with launchers for macOS, Linux and
Windows. See [App Mode](app-mode.md).

## Notes

- ECharts snapshots are captured from the live canvas as you view the notebook, so open a
  cell's chart at least once before exporting (HTML, PDF, or standalone) to ensure its snapshot
  is current.
- A notebook's own front-end code is self-contained: [web cells](frontend-extensions.md), `WebPage`
  output, and `@use` imports carry their HTML/CSS/JS (and import map) into the exported page, so
  custom widgets and scripts keep working offline.
- Markdown chart / table interpolations (double-brace `echart(…)` / `slate_table(…)`) are
  client-hydrated and appear as static placeholders in HTML; scalar and image interpolations embed directly.
