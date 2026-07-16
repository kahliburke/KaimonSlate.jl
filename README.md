<div align="center">

<img src="docs/src/public/assets/slate-logo.svg" alt="KaimonSlate logo" width="120"/>

# KaimonSlate.jl

[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://kahliburke.github.io/KaimonSlate.jl/dev/)
[![CI](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/CI.yml)
[![Documentation](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

A **reactive** Julia notebook with a live browser UI, packaged as a
[Kaimon](https://github.com/…/Kaimon.jl) extension. Cells form a dependency graph, so changing a
value recomputes exactly what depends on it — no hidden kernel state, no manual "run all". It's a
plain `.jl` file the whole way down, so the browser, the AI agent, and git share one source of truth.

📖 **Documentation:** <https://kahliburke.github.io/KaimonSlate.jl/dev/>

### Highlights

- ⚡ **Reactive cells** — edit a cell or drag a `@bind` widget and only the *downstream* cells
  recompute; every output always reflects its current inputs.
- 📊 **Rich, live output** — inline CairoMakie figures, interactive ECharts charts, sortable and
  filterable tables, and animations played back in the browser.
- 🤖 **Built-in AI agent** — builds and edits the notebook cell-by-cell through the `slate.*` tools,
  driven by Claude or a local model.
- 🖧 **Run anywhere** — a notebook's worker runs locally or on a remote host, with warm pools for
  near-instant startup and a durable cache that follows you.
- ☁ **Publish & cite** — turn notebooks into a web portfolio (GitHub Pages, Cloudflare, Netlify, …)
  or mint a permanent, citable Zenodo DOI.
- 🕰 **Time machine** — every run is recorded, so you can scrub back through a notebook's full history.

## Install

KaimonSlate is driven by the **`slate` app** — a small launcher installed with Julia's app system.
From the Pkg REPL (press `]`):

```julia-repl
pkg> app add KaimonSlate
```

That puts a `slate` launcher on your `PATH`. Then:

```sh
slate                 # start (or attach to) the notebook hub + a status TUI
slate my_analysis.jl  # also open that notebook in the browser (created if missing)
```

<div align="center">

<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/slate-tui.gif" alt="The slate status TUI — server state, hub URL, Kaimon-extension status, and a live table of open notebooks with their cell / running / stale / error counts" width="640"/>

*The `slate` status TUI: server state, the hub URL, Kaimon-extension status, and a live table of
your open notebooks. `↑↓`/`enter` opens one, `o` the hub index, `q` quits.*

</div>

### As a Kaimon extension (recommended)

The full experience — per-notebook gate workers **and** the AI agent. The first time you run `slate`
with [Kaimon](https://github.com/…/Kaimon.jl) installed, it offers to register itself as a Kaimon
extension — a one-time **consented** prompt (no longer automatic on package load). Say yes (Kaimon
picks it up dynamically — no restart): your agents get the `slate.*` tools (`slate.open` / `slate.list` / `slate.close` / …),
Kaimon serves your notebooks from its own hub — each in its own gate worker, pinned to the notebook's
Julia project — and running `slate` again **attaches** as a live status viewer. See the
[installation guide](https://kahliburke.github.io/KaimonSlate.jl/dev/installation).

### Standalone (without Kaimon)

`slate --own` runs the hub in-process, no Kaimon needed (also the default when Kaimon isn't
installed) — cells, widgets, figures, and the timeline all work; the AI agent needs Kaimon.

```sh
slate --own my_analysis.jl   # open http://127.0.0.1:8765
```

### Programmatic (embedding)

To drive the hub from your own script instead of the app, add the package as a **library** and call
the serving API directly:

```julia-repl
pkg> add KaimonSlate
```

```julia
using KaimonSlate
serve_notebook("notebook.jl"; port = 8765)   # blocks; open http://127.0.0.1:8765
```

See the [Architecture guide](https://kahliburke.github.io/KaimonSlate.jl/dev/architecture) for how
the pieces fit together.

## Status

Per-notebook gate workers and the single-server hub are in place; the AI agent drives notebooks
through the `slate.*` tools. See the
[documentation](https://kahliburke.github.io/KaimonSlate.jl/dev/) for the current feature set.
