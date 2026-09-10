# Notebook Basics

## Cell types

There are four kinds:

- **Code cells** evaluate Julia. The last expression's value renders below, along with
  stdout and any rich display (images, ECharts, tables, LaTeX).
- **Markdown cells** render GitHub-flavored markdown with LaTeX math and double-brace
  interpolation of Julia values. GFM tables work, as do `!!! note "Title"` admonitions; the category
  is free-form, so a notebook can coin its own.
- **Web cells** hold HTML, CSS and JS in their own panes, for building an interface that talks to
  Julia. See [Front-end Extensions](frontend-extensions.md).
- **Tool cells** hold an `@tool name(...)` call, defining a tool the [agent](agent.md) can call. They
  are never swept up by an automatic run, so reopening a notebook does not re-fire one.

The cell header shows a button for each kind the cell is *not* (`{·}` code, `</>` web, `⌁` tool,
`M↓` markdown). In command mode, `y` / `m` / `w` convert to code, markdown and web.

A code cell shows an always-on editor with tree-based Julia highlighting (CodeMirror 6 + the
Lezer Julia grammar), the run button, timing, and state badge:

![A code cell with Julia syntax highlighting, run button, timing, and FRESH badge](./assets/editor-highlighting.png)

## Command mode vs. edit mode

KaimonSlate uses a Jupyter-style two-mode model:

- **Command mode** — the cell has an accent ring and single keys act on it.
- **Edit mode** — focus is inside the editor (green ring); `Esc` returns to command mode.

| Key | Action |
| --- | --- |
| `↑`/`k`, `↓`/`j` | move selection |
| `⇧↑` / `⇧↓` (also `⇧K` / `⇧J`) | extend the selection to the cell above / below |
| `⌥↑` / `⌥↓` | **move the cell** up/down |
| `Esc` | collapse a multi-selection back to one cell |
| `⏎` | enter edit mode |
| `a` / `b` | add cell above / below |
| `c` / `x` / `v` | copy / cut / paste cell(s) |
| `m` / `y` / `w` | to markdown / to code / to [web](frontend-extensions.md) |
| `dd` | delete cell |
| `⇧M` | merge with the cell below |

Select several cells with shift-click (a range) or ⌘/Ctrl-click (toggle one), as well as the
⇧-arrow keys. Delete, cut, copy and the type-toggle keys then act on the whole selection, and a
floating chip shows how many are selected. The cell clipboard is shared across notebook tabs.

You can also reorder with the mouse: drag the **⠿** grip in a cell's header and a drop line shows
where it will land, or use the header's ↑/↓ buttons to move it one place.

In edit mode:

| Key | Action |
| --- | --- |
| `⇧⏎` | run (or commit a markdown/bind cell) |
| `⌘⇧⏎` / `Ctrl⇧⏎` | run and open a fresh cell below |
| `⌘⇧-` / `Ctrl⇧-` | split the cell at the cursor |
| `⇥` | completion (Julia REPL completions + cell-local bindings) |
| `⌘⌥↑` / `⌘⌥↓` | add a caret on the line above / below |
| `⌥`-click | add a caret at the click |
| `⌘D` / `CtrlD` | select the word under the caret, then each next occurrence |

Extra carets type together.
`Esc` drops back to a single caret, or clears a selection, and a second `Esc` returns to command mode.
Under the vim keymap `Esc` keeps its vim meaning: it leaves insert or visual mode, and from normal mode it returns to command mode without collapsing the carets.

Notebook-wide:

| Key | Action |
| --- | --- |
| `⌘↵` | run stale cells |
| `⌘F` / `⌘⌥F` | find across every cell / find and replace |
| `⌘G` / `⇧⌘G` | next / previous match |
| `⌘K` / `⌘⇧K` | command palette / docs search |
| `⌘⇧A` | agent panel |
| `⌘⇧F` | controls palette |
| `⌘⇧L` | table of contents |
| `⌘⇧G` | dependency graph |
| `⌘⇧S` | scratchpad |
| `⌘Z` / `⌘⇧Z` | undo / redo structural changes |

### Finding across the notebook

**⌘F** opens one find bar for the whole document rather than a panel inside the focused cell — in a
notebook what you are looking for is usually in a *different* cell. It walks every cell in order,
counts the hits and steps between them across cell boundaries with **⏎** or **⌘G**. **⌘⌥F** opens the
replace row as well; **⌘⏎** there replaces every match in the notebook.

The three switches on the bar are match case (`Aa`), whole word (`ab`) and regular expression (`.*`).
Whole word is decided by character category rather than `\b`, so it behaves sensibly for the Unicode
names Julia encourages: searching `α` matches a standalone `α` and not the `α` inside `αβ`. In regex
mode `$1`…`$9`, `$&` and `$$` expand in the replacement; in plain mode a `$` stays a `$`.

Cells that have not been scrolled to yet still contribute to the count — their text comes from the
last saved source. Stepping onto a match in a markdown or `@bind` cell opens that cell's source so
the match can be shown, and replacing into one does the same.

Inside the **Files** tab's whole-file editor, ⌘F keeps CodeMirror's own single-document find panel,
scoped to that one file.

## Running cells

Run a single cell with **⇧⏎**, or press **⌘⏎** (**Ctrl⏎**) to recompute every stale cell. The same
action is in the command palette as *Run stale cells*. The kernel dot in the top bar breathes while a
computation is in flight.

### Stopping a run

A run in flight can be interrupted. That leaves the namespace intact, so everything computed so far
is still there. **⟲ Restart worker** is the heavier option: it discards the run and the namespace
with it.

### When a run gets stuck

A supervisor sweeps every few seconds and raises a badge in the top bar when something looks wrong:
amber for a warning, red for something critical. Clicking it opens a panel naming each alert, a
stalled kernel or a runaway loop, with the recovery action for that alert (stop the run, or restart
the worker).

## The scratchpad

**☰ → 🧪 Scratchpad** (⌘⇧S) opens a panel where you can run Julia in the notebook's own kernel
without creating a cell or touching the `.jl`. Results stream in with a timestamp, 🧹 clears them,
and the 🧪 pill in the top bar lights up while something is running there.

It is the place for a quick check that is not part of the document. The [agent](agent.md)'s
`slate_eval` runs in the same scratchpad.

## Opening a cold notebook

The first open of a notebook whose packages are not yet precompiled shows a banner reading
*Precompiling k/N · <package>*, with elapsed time and a collapsible build log. This is one-time;
later opens are fast, and you can keep editing while it runs.

Installing a package mid-session is different: that shows a blocking overlay, because the notebook is
paused while its environment resolves and precompiles.

A notebook can also open **inactive**, showing its stored results with no worker behind it. See
[the front page](getting-started.md#The-front-page).

## Quiet cells

A code cell whose last non-comment line ends in `;` suppresses display of the value (stdout
and explicit `display()` still show) — handy for setup cells.

```julia
big = rand(1000, 1000);   # no 1000×1000 dump
```

## Markdown interpolation

Inside a markdown cell, a double-brace `expr` block splices a Julia value into the rendered output:

```markdown
Mean: {{ round(mean(data); digits=2) }}

{{ echart(spec) }}          <!-- an interactive chart -->
{{ slate_table(df) }}       <!-- an interactive table -->
```

Scalars render inline; images, charts, and tables render as blocks. Interpolation works
inside math (`$…$`) too.

![A markdown cell with interpolated values and typeset LaTeX math](./assets/markdown.png)

## Images and clips

An image alone in its paragraph is treated as a figure and centred; one sitting inside a run of
prose stays inline where you put it. An attribute block directly after the image (no space, as in
Pandoc/Quarto) overrides how it is drawn:

```markdown
![A phase portrait](plot.png){width=300}
![Logo](logo.svg){width=40% align=right}
![Detail](detail.png){.zoomable #fig-detail title="click to enlarge"}
```

`width`/`height` take a bare number as pixels (`300` → `300px`) or any CSS length or percentage;
`align` is `left`, `right`, or `center`; `.name` adds a class, `#name` sets an id. The same block
works on a `<video>` or `<audio>` you dropped into the cell, and on an interpolated `{{ }}` image.
Sizes carry into the HTML export and the PDF; unrecognised keys are dropped rather than emitted.

## Completion

Tab-completion uses Julia's REPL completions against the live kernel **plus** the cell's own
local bindings (assignments, loop/comprehension variables, function parameters) so names
complete even before the cell has run. The popup carries a docstring preview, and method
completions insert tab-through argument placeholders. LaTeX/emoji shortcuts work — type
`\pi`⇥ → `π`.

![The completion popup with a docstring preview card](./assets/completion.png)

## Renaming cells

Cell ids are header-safe labels. Double-click a cell's id to rename it; renames are tracked
as renames in [history](history.md), and dependencies (which are by id) are rebuilt.
