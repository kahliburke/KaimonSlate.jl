# Slides & Present

Any notebook is also a **slide deck**. The same cells you edit group into slides by their
headings — no separate authoring mode, no second copy of the content. Present them live in the
browser, or export a typeset PDF deck.

## Present mode — ▶ Present

Click **▶ Present** in the top bar (or press **⌘⇧P**) to enter full-screen presentation. The
notebook's cells are segmented into slides and shown one at a time; arrow keys advance. Press
`Esc` to exit back to the editor.

Because the deck *is* the notebook, your figures, tables, and `@bind` controls are all live on
the slide — a slider still drives its chart mid-presentation.

![A notebook presented full-screen as a slide, with its heading, prose, and a live chart](./assets/present-slide.png)

## How cells become slides

Segmentation follows a small set of boundary rules (shared by Present mode and the PDF export,
so both agree):

1. A **markdown heading** at or above the slide level (default `##` / H2) starts a new slide.
2. A cell tagged **`slide`** forces a new slide, regardless of headings.
3. A **thematic break** (`---` on its own line) *inside* a markdown cell splits it mid-cell into
   separate slides.
4. A cell tagged **`notes`** attaches to the current slide as **speaker notes** (never shown in
   the slide body).
5. Cells before the first boundary form the leading **title slide**.
6. `collapsed` cells are omitted (matching the article/report export).

```julia
#%% md id=title
# Reactive Notebooks
### a five-minute tour

#%% md id=idea
## The core idea            ← starts slide 2 (H2 heading)
Change a value; only the downstream cells recompute.

#%% code id=demo slide      ← `slide` tag forces slide 3, even without a heading
@bind f Slider(1:10)
echart(:line, 1:100, sin.(f .* (1:100) ./ 10))

#%% md id=sp notes          ← speaker notes for slide 3, not shown on it
Remember to drag the slider here.
```

Set the **slide level** (how deep a heading has to be to start a slide — H1 only, through H3),
the **transition**, the **theme**, and the **aspect ratio** (16:9 or 4:3) per notebook in
**☰ → 🎚 Notebook config** (see [Configuration](configuration.md#notebook-config)). These pin
to the notebook and travel in its `.jl`.

## Export a PDF deck

**☰ → ⬆ Export…**, format **PDF**, layout **🎞 Slides — presentation deck**. This renders a
typeset landscape deck **server-side via Typst** — one slide per page, 16:9 (or 4:3), auto-fit:

- **Code listings are hidden by default** on slides (a deck shows results, not source); the
  *Code listings* option turns them back on.
- **Vector figures** — CairoMakie embeds as PDF, ECharts as SVG (light+dark captured), so a
  slide stays crisp on a projector.
- **Speaker notes** — tick **Append speaker-notes pages to the deck** to follow the deck with a
  notes appendix (one page per slide that has `notes` cells).

The route is `GET /api/<id>/export.pdf?layout=slides` (`?theme=`, `?columns=` ignored for decks;
`?code=` sizes/hides listings). See [Export](export.md) for the shared PDF options and the
editable Typst project (`export.typ`).

!!! tip "One source, three artifacts"
    The same notebook is a live document, a full-screen presentation, and a typeset PDF deck. Add a
    few `##` headings and it's already a deck — refine with `slide` / `notes` tags and the
    Notebook-config knobs.
