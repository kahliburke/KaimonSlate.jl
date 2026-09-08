# Slides & Present

Any notebook is also a **slide deck**. The same cells you edit group into slides by their
headings — no separate authoring mode, no second copy of the content. Present them live in the
browser, or export a typeset PDF deck.

## Present mode — 📽 Present

**☰ → 📽 Present** (or **⌘⇧P**) enters full-screen presentation. The notebook's cells are segmented
into slides and shown one at a time.

Because the deck *is* the notebook, your figures, tables, and `@bind` controls are all live on
the slide — a slider still drives its chart mid-presentation.

In the deck: `←` / `→` move, `Home` / `End` jump to the ends, `c` toggles code, `f` toggles
fullscreen, and `Esc` exits back to the editor.

### The presenter window

Press `s` (or the 🪞 button, or *Open presenter window* in the palette) for a second window showing
the current and next slide, a timer, and the **speaker notes** from your `notes` cells. That window
is the only place notes are visible. The two stay in step as you advance.

![A notebook presented full-screen as a slide, with its heading, prose, and a live chart](./assets/present-slide.png)

## How cells become slides

Segmentation follows a small set of boundary rules:

1. A **markdown heading** at or above the slide level (default `##` / H2) starts a new slide.
2. A cell tagged **`slide`** forces a new slide, regardless of headings.
3. **PDF only.** A **thematic break** (`---` on its own line) *inside* a markdown cell splits it
   mid-cell into separate slides. The live deck keeps the cell whole, because it moves the real cell
   onto the stage so charts and `@bind` controls stay live, and a cell cannot be cut in half. Split
   the cell yourself to get the same break in both.
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

Set the **slide level** (the heading depth that starts a slide, 1 through 6, default 2 for `##`),
the **transition**, and the **aspect ratio** (16:9 or 4:3) per notebook in
**☰ → ⚙ Settings → This notebook** (see [Configuration](settings.md#This-notebook)). These pin
to the notebook and travel in its `.jl`.

The live deck follows the editor theme. A PDF deck takes its theme from the export dialog.

## Export a PDF deck

**☰ → ⬆ Export…**, format **PDF**, layout **🎞 Slides — presentation deck**. This renders a
typeset landscape deck **server-side via Typst** — one slide per page, 16:9 (or 4:3), auto-fit:

- **Code listings are hidden by default** on slides, since a deck usually shows results rather than
  source. Choosing any non-hidden **Code listings** size brings them back.
- **Vector figures** — CairoMakie embeds as PDF, ECharts as SVG (light+dark captured), so a
  slide stays crisp on a projector.
- **Speaker notes** — tick **Append speaker-notes pages to the deck** to follow the deck with a
  notes appendix (one page per slide that has `notes` cells).

The route is `GET /api/<id>/export.pdf?layout=slides`. `?theme=` sets the deck palette (as-is, light
or dark, as in the dialog), `?notes=1` appends the speaker-notes pages, `?code=` sizes or hides
listings, and `?columns=` is ignored for decks. See [Export](export.md) for the shared PDF options
and the editable Typst project (`export.typ`).

## Zen mode

**☰ → 🧘 Zen mode** is the other full-page reading view. It hides code and chrome on the same
scrollable page, leaving prose and output. `Esc` returns to the editor.

Present is the slide deck; Zen is the document.

!!! tip "One source, three artifacts"
    The same notebook is a live document, a full-screen presentation, and a typeset PDF deck. Add a
    few `##` headings and it's already a deck — refine with `slide` / `notes` tags and the
    per-notebook settings.
