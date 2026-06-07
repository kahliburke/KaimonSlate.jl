# Notebook Basics

## Cell types

- **Code cells** evaluate Julia. The last expression's value renders below, along with
  stdout and any rich display (images, ECharts, tables, LaTeX).
- **Markdown cells** render GitHub-flavored markdown with LaTeX math and `{{ … }}`
  interpolation of Julia values.

Toggle a cell's type with the header button (`M↓` / `{·}`) or press `m` / `y` in command
mode.

## Command mode vs. edit mode

KaimonSlate uses a Jupyter-style two-mode model:

- **Command mode** — the cell has an accent ring and single keys act on it.
- **Edit mode** — focus is inside the editor (green ring); `Esc` returns to command mode.

| Key | Action |
| --- | --- |
| `↑`/`k`, `↓`/`j` | move selection |
| `⇧↑` / `⇧↓` | **move the cell** up/down |
| `⏎` | enter edit mode |
| `a` / `b` | add cell above / below |
| `m` / `y` | to markdown / to code |
| `dd` | delete cell |
| `⇧M` | merge with the cell below |

In edit mode:

| Key | Action |
| --- | --- |
| `⇧⏎` | run (or commit a markdown/bind cell) |
| `⌘⇧⏎` / `Ctrl⇧⏎` | run and open a fresh cell below |
| `⌘⇧-` / `Ctrl⇧-` | split the cell at the cursor |
| `⇥` | completion (Julia REPL completions + cell-local bindings) |

Notebook-wide: **⌘Z / ⌘⇧Z** undo/redo structural changes, **⌘K** the command palette,
**⌘⇧K** the docs search palette.

## Running cells

Run a single cell with **⇧⏎**, or **▶ Run stale** in the top bar to recompute every stale
cell. The kernel dot in the top bar breathes while a computation is in flight.

## Quiet cells

A code cell whose last non-comment line ends in `;` suppresses display of the value (stdout
and explicit `display()` still show) — handy for setup cells.

```julia
big = rand(1000, 1000);   # no 1000×1000 dump
```

## Markdown interpolation

Inside a markdown cell, `{{ expr }}` splices a Julia value into the rendered output:

```markdown
Mean: {{ round(mean(data); digits=2) }}

{{ echart(spec) }}          <!-- an interactive chart -->
{{ slate_table(df) }}       <!-- an interactive table -->
```

Scalars render inline; images, charts, and tables render as blocks. Math interpolation
works too: `$\mu = {{ mu }}$`.

## Completion

Tab-completion uses Julia's REPL completions against the live kernel **plus** the cell's own
local bindings (assignments, loop/comprehension variables, function parameters) so names
complete even before the cell has run. LaTeX/emoji shortcuts work — type `\pi`⇥ → `π`.

## Renaming cells

Cell ids are header-safe labels. Double-click a cell's id to rename it; renames are tracked
as renames in [history](history.md), and dependencies (which are by id) are rebuilt.
