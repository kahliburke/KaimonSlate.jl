# Getting Started

This walkthrough opens a notebook, builds a few reactive cells, adds a control, and hands
a task to the AI agent.

## Open a notebook

Run the **`slate` app** (install it with `pkg> app add KaimonSlate` — see
[Installation](installation.md) for the full steps):

```sh
slate                 # start the hub and show the status TUI
slate intro.jl        # …or jump straight into a notebook (created if new)
```

Those go in your **terminal**, not the Julia REPL — installing the app puts a `slate` executable in
Julia's app bin (`~/.julia/bin`; `slate.bat` on Windows), which you add to your `PATH` once. If your
shell reports `command not found`, that `PATH` step is what's missing; see
[Installation](installation.md).

`slate` starts (or attaches to) the notebook hub and shows a status TUI in your terminal. Under
**Kaimon** it attaches to Kaimon's hub, so the **💬 agent** is available; standalone
(`slate --own`) it owns the hub itself.

### The front page

The hub's **front page** lives at **`http://127.0.0.1:8765`**. It is the launcher for every notebook,
and where you open or upload a document. Press **`o`** in the status TUI to open it, or visit that
address yourself. Only `slate <file.jl>` opens a browser on its own.

![The KaimonSlate hub front page: an open-a-notebook row with path completion, a Run-on selector, ⬆ Upload and 🖧 Remotes buttons, a ☁ Publishing manager, the list of open notebooks, and a published-sites strip](./assets/home.png)

- **Open by path** — type a path (Tab completes) and hit **Open**, or pass it on the shell as
  `slate path/to/notebook.jl`. A path that doesn't exist yet is created.
- **＋ New notebook** — create an empty notebook at a path you pick, starting from the last directory
  you opened from.
- **⬆ Upload** — pick a file from *this* computer; the hub saves it and opens it. (You can also just
  ask the **💬 agent** to open one.)
- **Launch worker on open** — checked, a notebook boots its worker and runs as it opens. Unchecked, it
  opens inactive as a static preview you can launch later. The setting sticks per browser.
- **Open notebooks** — everything currently open on the hub; click to jump back in.
- **Recent** — a searchable list of notebooks you have opened, kept per browser.
- **Run on** — choose where a notebook's worker runs: locally, or on a remote SSH host you set up with
  **🖧 Remotes**. See [Remotes](remotes.md).
- **☁ Publishing** — manage published sites and destinations. See [Publishing](publishing.md).

Open and Upload both classify whatever you point them at. A Slate notebook opens directly. A plain
Julia script is copied beside itself as `<stem>-notebook.jl` and opened as a notebook, leaving your
original untouched. A self-contained bundle offers to be expanded into a project rather than opened
bare. A runnable `.html` export has its embedded notebook extracted first, then follows the bundle
path.

A notebook opened from a bundle you downloaded or uploaded starts **inactive**: it shows the render
stored inside it and spawns nothing. Clicking the grey *Inactive* pill opens a popover naming the
packages involved and warning about precompile time, then boots the worker, restores cached results
and runs. Your own files open live.

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

A cell's left border shows its state: green = fresh, gold = stale, orange = edited (unsaved),
blue and pulsing = running, red = errored.

## Reactivity

Add another cell that reads `x`:

```julia
y = x * 2
```

Now change the first cell to `x = 50` and run it. The second cell **restales and recomputes
automatically** — it depends on `x`, so KaimonSlate re-runs it for you. This is the core
idea; see [Reactive Cells](reactivity.md).

To see what a cell is connected to, click the **🔗** button on its header. The notebook filters down
to that cell's dependency chain, its precursors and its dependents, and a banner appears across the
top. Click the banner or press `Esc` to return to the whole notebook.

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
**☰ → ⚙ Settings**. See [The AI Agent](agent.md).

## Export

When you're done, **☰ → ⬆ Export…** offers a self-contained **HTML** page, a publication-quality
**PDF** (typeset server-side with Typst, with themes, columns and vector figures), **Markdown** for
pasting elsewhere, a fully reproducible **self-contained `.jl`** (cells + environment + source), and
an **App** folder that runs as an application. See [Export](export.md) and
[App Mode](app-mode.md).

## Publish

To share it on the web, **☰ → ☁ Publish…** renders the notebook into a personal **site** — each
document at its own URL behind a generated front page. One build deploys to GitHub Pages,
Cloudflare, Netlify, or your own server, and you can mint a citable **Zenodo DOI** at milestones.
Manage every site and target from the hub's **☁ Publishing** manager. See
[Publishing](publishing.md).
