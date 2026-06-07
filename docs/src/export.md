# Export

KaimonSlate produces a **self-contained HTML document** of a notebook — and, through the
browser's print dialog, a PDF.

## Export HTML

**☰ → Export HTML** downloads a single `.html` file with everything inlined:

- Markdown cells rendered (GFM tables, KaTeX math).
- Code cells with their source and output (values, stdout, errors).
- Figures embedded as base64 — CairoMakie rasters directly, and client-rendered **ECharts
  frozen to their latest snapshot PNG**.
- Interactive tables flattened to static HTML.

There are no scripts to boot and no server required — the file opens offline, with KaTeX
pulled from a CDN to typeset math.

The route is `GET /api/<id>/export.html`. Query options:

- `?dl=1` — download as an attachment (the menu uses this).
- `?source=0` — hide code cells (output-only document).

## Print / Save PDF

**☰ → Print / Save PDF** opens the same static document in a new tab and triggers your
browser's print dialog — choose "Save as PDF". The export stylesheet keeps backgrounds and
figure colors in print (`print-color-adjust: exact`) and avoids breaking code blocks across
pages.

## Notes

- ECharts snapshots are captured from the live canvas as you view the notebook, so open a
  cell's chart at least once before exporting to ensure its snapshot is current.
- Markdown `{{ echart(…) }}` / `{{ slate_table(…) }}` interpolations are client-hydrated and
  appear as static placeholders in the exported document; scalar and image interpolations
  embed directly.
