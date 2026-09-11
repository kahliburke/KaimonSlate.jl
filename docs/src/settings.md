# Settings

Settings live in one dialog with two **scopes**. **Global** is your own preference, kept per browser
and applied to every notebook. **This notebook** is the per-notebook override, and the pinned ones
travel *in the `.jl`* so the notebook reopens the same way anywhere.

Open it from **☰ → ⚙ Settings**, or ⌘K → *Settings*. ⌘K → *Settings: this notebook* opens the
same dialog already on the second scope.

A section list runs down the side and a search box sits above it. The search covers both scopes and
matches tooltips and placeholders as well as visible text, so typing "vim", "trackpad" or "svg" finds
the setting even when the word is not its label.

## Global

Four sections.

**Display**

| Setting | Effect |
| --- | --- |
| **Full page width** | Use the full window width instead of the centered column. |
| **Page width** | The content column's width, when not using full width. |
| **Figure width** | How wide figures render, independently of the text column. |
| **Chart scroll-zoom** | How much a wheel notch zooms a chart that has zooming enabled. |
| **Wrap text output** | Soft-wrap long lines of cell output instead of scrolling them. |
| **Wrap code editor** | Soft-wrap long lines in the editor. |
| **Line numbers** | Show a line-number gutter in every code cell. Off by default — a cell is usually short enough not to need one. The Files tab always numbers its lines. |
| **Indent guides** | Draw a hairline at each indent level, so a nested block's extent is visible at a glance. |
| **Code folding** | Let Julia blocks be collapsed from the gutter: `function`, `struct`, `module`, `macro`, `if`, `for`, `while`, `try`, `let`, `begin`, `quote` and `do`. A folded block keeps its own header line and its `end`. Markdown cells have no grammar to fold. |
| **Highlight matching words** | Select a word and its other occurrences in that cell are tinted. On by default. |
| **Match highlight** | Colour of that tint, as a row of swatches. **Theme accent** (the default, marked with a ring) follows the notebook theme, so it recolours when you switch theme; the named hues override it. A theme can set its own via the `--selmatch` CSS variable. |

**Appearance**

| Setting | Effect |
| --- | --- |
| **Theme** | The notebook UI's colour theme: Midnight (default), Graphite, Nord, Dracula, Solarized Dark, and the light Daylight and Solarized Light. |
| **Chart renderer** | How interactive charts are drawn: *Auto* (each chart's own setting), *Canvas*, or *SVG*. See below. |
| **Editor syntax** | Syntax-highlighting palette for the editor: Dark+, Monokai, Dracula, Nord, Tokyo Night, GitHub Dark, Gruvbox Dark, Solarized Dark, and the light One Light and Solarized Light. |

**Editing**

| Setting | Effect |
| --- | --- |
| **Editor keymap** | Default, Vim or Emacs bindings in the cell editor. See below. |
| **Live-update debounce** | Minimum delay (ms) between live recomputes while dragging a control. Higher = fewer recomputes on a slow kernel. |
| **Autocomplete delay** | How long to wait before the completion popup opens. |
| **Tab in autocomplete** | Whether ⇥ accepts the highlighted completion. |

#### Saving under the Vim and Emacs keymaps

A notebook has no save separate from execution, so "write this buffer" means *apply it* — and what
that does depends on where you are:

| You are in | `:w` (vim) · `C-x C-s` (emacs) does |
| --- | --- |
| a code cell | runs it |
| a markdown or `@bind` cell's source | commits the source and returns to the rendered view |
| a file in the **Files** tab | writes the file |

Vim also takes `:wq` and `:x` (apply, then leave the editor), `:q` (leave, keeping your edits, the
same as clicking away) and `:q!` (discard the edit and leave — the one way to abandon it in a single
action). ⌘S saves a file under every keymap.

**Agent**

| Setting | Effect |
| --- | --- |
| **Agent model** | Sonnet / Opus / Haiku, any model served locally by Ollama or vmlx (both listed automatically, stored as `ollama:<name>` / `vmlx:<name>`), or a custom model id typed in. |
| **Agent permissions** | `lab` / `auto` / `default` / `bypass` preset for the agent. |

Model and permission changes [reap the agent](agent.md) so the next message respawns on the
new setting (the transcript is kept).

![The Settings dialog: a Global / This notebook scope switch, a search box, the section list down the side, and the settings rows](./assets/settings.png)

### Chart renderer

ECharts draws to a canvas, and some browser and driver combinations fail to composite it. The chart
then runs correctly behind a blank rectangle. Switching to **SVG** avoids that path.

Which renderer works depends on the browser doing the viewing, so this reader setting outranks the
[`renderer =`](visualization.md#Choosing-a-renderer) keyword an author put on a chart. Changing it
rebuilds every chart on the page, because ECharts fixes the renderer when a chart is created.

A static export has no Settings dialog, so a reader who hits this can add `?renderer=svg` to the URL
instead.

## This notebook

The second scope. Each setting starts from your global default and can be **pinned to this
notebook**, and the pinned ones travel in the `.jl`.

A row that has not been pinned is badged **default** and says which value it is following, so you can
tell an inherited setting from one this document has decided. The header says **all defaults** when
nothing has been pinned at all.

![The Settings dialog on its This notebook scope: sections for Agent, Execution, Slides, Publishing and Agent (local only), with an unpinned row badged default and showing the value it follows](./assets/settings-notebook.png)

It holds:

- **Worker threads** (`"<compute>,<interactive>"`) and **Extra Julia flags** (appended to this
  notebook's worker command line, e.g. `--gcthreads=4,1 --heap-size-hint=4G`). Changing either
  respawns the worker.
- **Parallel cells** — run independent cells concurrently.
- **Hot-reload /src edits** — whether edits to the project's own source re-enter the running kernel.
  See [Editing project source](hot-reload.md).
- **Macro-aware deps** — expand unknown macros in the kernel to recover their real reads and writes.
  Off falls back to conservative static analysis, which is what you want for the rare macro with
  expansion-time side effects.
- **Slides** — heading level, transition, and PDF aspect ratio for a [slide deck](slides.md).
- **Bibliography style** — see [Documents & Citations](documents.md).
- **Agent model** — override the global agent default for this notebook. (Agent permissions are a
  ⚙ Settings item, remembered locally and never written to the file.)
- **Series** — the publishing series this notebook belongs to.
- **Replay resolution** — read-only here, showing what the export dialog's
  [replay step](replay.md#exporting) decided. The panel is where you clear it.

Whether a notebook runs its cells as it opens is not a config setting. It is chosen when the notebook
is opened, from the front page's **Launch worker on open** checkbox.

Where a value crosses into other UI: the notebook's **run location** is the toolbar "Running on"
picker (whole-notebook placement, [Remotes](remotes.md)), and its **regions** are the
[Destinations](regions.md#Using-a-region-in-a-notebook) it enables — both are saved in the same
config footer.
