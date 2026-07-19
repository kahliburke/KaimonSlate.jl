# Getting Started

This walkthrough opens a notebook, builds a few reactive cells, adds a control, and hands
a task to the AI agent.

## Open a notebook

Run the **`slate` app** (installed with `pkg> app add KaimonSlate` — see
[Installation](installation.md)):

```sh
slate                 # start the hub + status TUI, and open the front page
slate intro.jl        # …or jump straight into a notebook (created if new)
```

`slate` starts (or attaches to) the notebook hub and shows a status TUI in your terminal. Under
**Kaimon** it attaches to Kaimon's hub, so the **💬 agent** is available; standalone
(`slate --own`) it owns the hub itself.

### The front page

Plain `slate` opens the hub's **front page** in your browser (at **`http://127.0.0.1:8765`**) — the
launcher for every notebook, and where you open or upload a document:

![The KaimonSlate hub front page: an open-a-notebook row with path completion, a Run-on selector, ⬆ Upload and 🖧 Remotes buttons, a ☁ Publishing manager, the list of open notebooks, and a published-sites strip](./assets/home.png)

- **Open by path** — type a `.jl` path (Tab completes) and hit **Open**, or pass it on the shell as
  `slate path/to/notebook.jl`. A path that doesn't exist yet is created.
- **⬆ Upload** — pick a `.jl` from *this* computer; the hub saves it and opens it. (You can also just
  ask the **💬 agent** to open one.)
- **Open notebooks** — everything currently open on the hub; click to jump back in.
- **Run on** — choose where a notebook's worker runs: locally, or on a remote SSH host you set up with
  **🖧 Remotes**. See [Remotes](remotes.md).
- **☁ Publishing** — manage published sites and destinations. See [Publishing](publishing.md).

Open one and you're in the notebook itself:

![A KaimonSlate notebook: a title, a frequency slider and toggle, and a live ECharts chart that redraws as you change them](./assets/hero.png)

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

!!! tip "Insert a control fast"
    Press **⌘K** and type "bind" to insert any widget snippet (Slider, Toggle, Select, …) at
    the cursor.

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

## Publish

To share it on the web, **☰ → ☁ Publish…** renders the notebook into a personal **site** — each
document at its own URL behind a generated front page. One build deploys to GitHub Pages,
Cloudflare, Netlify, or your own server, and you can mint a citable **Zenodo DOI** at milestones.
Manage every site and target from the hub's **☁ Publishing** manager. See
[Publishing](publishing.md).
