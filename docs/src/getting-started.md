# Getting Started

This walkthrough opens a notebook, builds a few reactive cells, adds a control, and hands
a task to the AI agent.

## Open a notebook

```julia
using KaimonSlate
KaimonSlate.serve_notebook("intro.jl")
```

Open the printed URL (default `http://127.0.0.1:8765`). The index page lists open
notebooks; click one to enter it, or type a path to open another.

![A KaimonSlate notebook: code, a slider widget, an inline ECharts chart, a table, and an error cell](./assets/overview.png)

## Add and run a cell

Click **＋ cell** (or press `b` in command mode to add below the selection). Type some
Julia and run it:

```julia
x = 21
```

- **⇧⏎** runs the cell.
- **⌘⇧⏎** (or **Ctrl⇧⏎**) runs and opens a fresh cell below — the keyboard "next cell" flow.

A cell's left border shows its state: blue = fresh, gold = stale, orange = edited (unsaved),
green = running, red = errored.

## Reactivity

Add another cell that reads `x`:

```julia
y = x * 2
```

Now change the first cell to `x = 50` and run it. The second cell **restales and recomputes
automatically** — it depends on `x`, so KaimonSlate re-runs it for you. This is the core
idea; see [Reactive Cells](reactivity.md).

To see what feeds a cell, click the **🔗** button on its header: every upstream precursor
lights up gold, and the view scrolls to the topmost one. Press `Esc` to clear.

## Add a control with @bind

Controls are real Julia widget constructors. Add a bind cell:

```julia
@bind n Slider(1:100)
```

Then read `n` from another cell:

```julia
using CairoMakie
set_theme!(theme_dark())
lines(1:n, (1:n).^2)
```

Drag the slider — the figure re-renders live. You can surface the control into another
cell's *control strip* by dragging it, or open the **🎛 Controls palette** to see every
declared `@bind`. See [Widgets & @bind](widgets.md).

::: tip Insert a control fast
Press **⌘K** and type "bind" to insert any widget snippet (Slider, Toggle, Select, …) at
the cursor.
:::

## Markdown and math

Switch a cell to markdown (`m` in command mode, or the `M↓` header button). Markdown cells
render GitHub-flavored markdown, LaTeX math (`$…$` / `$$…$$`), and **interpolation**:

```markdown
The answer is {{ x }}, and here is a chart: {{ echart(spec) }}
```

## Hand a task to the agent

Open the **💬 agent** pane. Ask it to build something — it works incrementally, adding and
running cells one at a time so you can watch:

> Plot the first 50 Fibonacci numbers on a log scale with ECharts.

Click **✨** on a cell to scope a turn to that cell and its dependency cone, or type **@**
in the chat to reference a specific cell by id. Pick the model and permission preset in
**⚙ Settings**. See [The AI Agent](agent.md).

## Export

When you're done, export from the **☰** menu: a self-contained **HTML** document, a
publication-quality **PDF** (typeset server-side with Typst — themes, columns, vector
figures), **Print HTML** for a quick browser PDF, or a fully reproducible **self-contained
`.jl`** (cells + environment + source). See [Export](export.md).
