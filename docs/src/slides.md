# Slides & Present

Any notebook is also a **slide deck**. The same cells you edit group into slides by their
headings — no separate authoring mode, no second copy of the content. Present them live in the
browser, or export a typeset PDF deck.

## Present mode — 📽 Present

**☰ → 📽 Present** (or **⌘⇧P**) enters full-screen presentation. The notebook's cells are segmented
into slides and shown one at a time.

Because the deck *is* the notebook, your figures, tables, and `@bind` controls are all live on
the slide — a slider still drives its chart mid-presentation.

In the deck:

| Key | Action |
|:----|:-------|
| `→` `space` / `←` | next / previous step or slide |
| `⇧→` / `⇧←` | next / previous slide, skipping steps |
| `Home` / `End`, `3` `⏎` | first / last slide, go to slide 3 |
| `o` | overview of every slide |
| `a` / `p` | autoplay / pause timing |
| `t` | rehearse: time every step |
| `b` | black screen |
| `l` / `d` / `x` | laser pointer / draw on the slide / clear the drawing |
| `c` | show code |
| `r` / `v` | record / camera bubble |
| `s` / `f` / `?` | presenter window / fullscreen / key list |
| `Esc` | exit |

### The presenter window

Press `s` (or the 🪞 button, or *Open presenter window* in the palette) for a second window showing
live previews of the current position and the next click, a timer, and the **speaker notes** from
your `notes` cells. Arrow keys in either window drive the deck. On a video call, share only the
deck window and keep the presenter window to yourself.

### Rehearsal and autoplay

Press `t` (or *rehearse* in the presenter window) and click through the talk: every step is timed,
and pressing `t` again saves the timings to the notebook. The presenter window then shows the planned
length and whether you are ahead or behind, and autoplay (`a`) advances on the rehearsed timings.

### Recording

Press `r` to record the deck with your microphone. The browser asks which tab or window to capture,
a 3-2-1 countdown starts it, and `r` again stops it. The video is written beside the notebook in
`recordings/`, with a chapters file (`.vtt`) marking each slide and a `.json` of the step timings.
Press `v` for a camera bubble, which is part of the recording; drag it to move it, double-click to
enlarge it. The presenter window shows the recording time and a stop button.

A `notes` cell shows while you are **authoring** — marked with a dashed rule so you can tell at a
glance which cells are yours alone — and nowhere else. It never reaches a slide, the reading view
(`zen`, and an app) hides it, and the HTML and markdown exports omit it entirely rather than hiding
it in CSS, so the text is not in the published page's source either. The PDF carries notes only when
you ask for the appendix (below). Style them yourself with the `.cell-notes` class.

![A notebook presented full-screen as a slide, with its heading, prose, and a live chart](./assets/present-slide.png)

## Designing slides

A slide is a fixed 16:9 (or 4:3) canvas that scales to the window, so it lays out the same on a
laptop, a projector and a shared screen. Everything below is markup in the notebook itself: the deck
never holds a second copy of your content.

### Slide tags

Put these on any cell of a slide (the first cell that sets a key wins):

| Tag | Effect |
|:----|:-------|
| `layout=title` | centred, large gradient title |
| `layout=section` | a section divider |
| `layout=center` | content centred on the slide |
| `layout=cover` | the slide's first image or video fills the canvas, text over it |
| `bg=aurora` | a background: `aurora`, `nebula`, `midnight`, `ember`, `ocean`, `slate`, `paper`, a colour (`bg=#0b1020`), a gradient written without spaces, or an image or video path |
| `bgdim=0.5` | darken the background so text reads over it |
| `transition=zoom` | how this slide enters: `fade`, `slide`, `zoom`, `rise`, `none` |
| `auto=5` | advance by itself after 5 seconds per step |
| `class=name` | add a CSS class to the slide; `class=serif` sets its headings in a book face |

**Deck style** in Settings gives every slide without its own `bg` a background, dimmed behind
content slides and full strength on title and section slides.

### Columns

```markdown
:::: columns
::: {.column width="40%"}
Left
:::
::: column
Right takes the rest
:::
::::
```

Cells tagged `column=2` still sit beside the cell before them, on a slide as in the notebook.

### Builds

A slide can bring its content in a piece at a time. `→` walks the steps, then moves to the next
slide; going back to a slide lands on its finished state.

- `::: step` … `:::` appears on its own click, rising into place. Choose how with a class:
  `{.step .fade}`, `.fade-left`, `.fade-right`, `.fade-down`, `.zoom`, `.blur`. Three effects act on
  content that is already showing: `.highlight` lights it up, `.strike` crosses it out, `.fade-out`
  takes it away. `.dim` dims an item once the next one arrives. `step=3` puts it on a specific step.
- `::: incremental` around a list brings in one item per click.
- A line with `. . .` reveals the rest of the cell in one step.
- A cell tagged `step` (or `step=2`) appears as a whole.

Hidden steps keep their space, so the slide never reflows as it builds.

### Builds from computed state

`SlideSteps(n)` makes the step counter a value the notebook can compute with:

```julia
#%% code id=k hidecode
@bind k SlideSteps(5)

#%% code id=fit
echart(:line, x, partial_sum(x, k + 1))
```

`k` is 0 when the slide comes up and counts to 5 as you click, so the figure is recomputed at each
step instead of being duplicated across slides. The control is hidden while presenting; in the
notebook it is a slider for scrubbing through the build.

### Explaining mathematics

A few macros, usable in any math, let an equation be explained one piece at a time. They render as
ordinary coloured math in the notebook, and print unwraps them to the plain equation.

| Macro | Effect |
|:------|:-------|
| `\term{name}{…}` | names a piece; it keeps one colour everywhere it appears |
| `\termc{name}{blue}{…}` | the same, with the colour chosen |
| `\step{…}`, `\stepat{2}{…}` | the piece arrives on the next click, or on step 2 |
| `\hl{…}`, `\hlat{2}{…}` | lights the piece up |
| `\cancelat{2}{…}` | strikes it through on step 2 |
| `\fadeat{2}{…}` | removes it on step 2 |
| `\braceat{2}{…}{label}`, `\obraceat` | draws a brace under (over) the piece with a label on step 2 |
| `\focusat{2}{…}` | on step 2 everything else on the slide recedes |

Outside math, `::: {.step .focus}` spotlights a block the same way; whatever arrives on that step (a
caption, say) stays lit with it.

Terms take colours in the order they first appear in the notebook, so give each quantity one name and
use it in prose, in every equation, and as the name of the chart series that plots it: the series wears
the term's colour.

```markdown
$$\term{inertia}{m\ddot x} \stepat{1}{{}+ \term{damping}{c\,\dot x}} \stepat{2}{{}+ \term{spring}{k\,x}} = 0$$
```

A `::: derive` block shows a sequence of equations in one place, one at a time. Each click turns the
equation into the next: pieces with the same name glide to where they belong in the new equation, and
the rest fades across. Put a blank line between the equations.

```markdown
::: derive
$$\term{inertia}{m\ddot x} + \term{damping}{c\,\dot x} + \term{spring}{k\,x} = 0$$

$$\term{inertia}{\ddot x} + \term{damping}{2\gamma\,\dot x} + \term{spring}{\omega_0^2\,x} = 0$$

$$r = -\term{damping}{\gamma} \pm i\,\term{freq}{\omega_d}$$
:::
```

Named pieces carry between consecutive slides the same way, so the result of one slide can move into
place on the next.

### Figures on slides

A chart on a slide is restyled for the room: tick labels, axis names, legend and tooltip are set in
slide units, lines and points are heavier unless the cell chose their size, and the plot keeps room for
its labels. The cell's chart is untouched; leaving the slide puts it back as drawn.

`steps` walks a figure through views as the slide builds, with the axes animating from one to the next:

```julia
echart(:line, t, x; steps = [(x = (0, 12),),                       # step 1: the whole run
                             (x = (7.5, 12), y = (-0.16, 0.16)),   # step 2: zoom into the tail
                             (x = (0, 3), band = true)])           # step 3: back out, shade 0–3
```

A step with `band = true` keeps the view and shades that stretch of `x`. The figure's steps share the
slide's step counter with its other builds.

### Media and morphing

`![autoplay loop](clip.mp4)` is a video (and `![](talk.m4a)` audio). Flags in the alt text:
`autoplay` (starts when it comes on screen), `loop`, `muted`, `nocontrols`. Relative paths resolve
next to the notebook.

A heading or image that appears on two consecutive slides moves and resizes into its new place.
Name anything else to morph it the same way: `::: {.morph name=plot}`, or tag a cell `morph=plot`.

Two chart cells on consecutive slides tagged with the same `morph=` name are treated as one figure
changing form: the marks of the first travel into the second. Give data items a shared `groupId` to say
which go where; several items with one `groupId` gather into the single item that carries it on the
next slide, so points can collect into the histogram bar they fall in:

```julia
#%% code id=strip morph=dist
echart(; xAxis = (type = :value,), yAxis = (type = :value, show = false),
       series = [(type = :scatter, data = [(value = [v, rand()], groupId = "b$(bin(v))") for v in draws])])

#%% code id=hist morph=dist
echart(; xAxis = (type = :value,), yAxis = (type = :value,),
       series = [(type = :bar, data = [(value = [centre(b), count(b)], groupId = "b$b") for b in bins])])
```

## How cells become slides

Segmentation follows a small set of boundary rules:

1. A **markdown heading** at or above the slide level (default `##` / H2) starts a new slide.
2. A cell tagged **`slide`** forces a new slide, regardless of headings. It carries a small `slide`
   chip in the editor — the other boundaries are headings you can already see, this one isn't — and
   the `.slide-start` class if you want to mark it differently.
3. **PDF only.** A **thematic break** (`---` on its own line) *inside* a markdown cell splits it
   mid-cell into separate slides. The live deck keeps the cell whole, because it moves the real cell
   onto the stage so charts and `@bind` controls stay live, and a cell cannot be cut in half. Split
   the cell yourself to get the same break in both.
4. A cell tagged **`notes`** attaches to the current slide as **speaker notes** (never shown in
   the slide body, the reading view, or an export — see above).
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
