<div align="center">

<img src="docs/src/public/assets/slate-logo.svg" alt="KaimonSlate logo" width="120"/>

# KaimonSlate.jl

[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://kahliburke.github.io/KaimonSlate.jl/dev/)
[![Documentation](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

A warm-session, **reactive** Julia notebook with a live browser UI — packaged as a
[Kaimon](https://github.com/…/Kaimon.jl) extension.

📖 **Documentation:** <https://kahliburke.github.io/KaimonSlate.jl/dev/>

Edit a cell or drag a `@bind` widget and only the *downstream* cells recompute
(pruned dependency graph). Makie/MIME figures and interactive ECharts render inline.
The source round-trips to a plain `.jl` file, so the agent and the browser share one
source of truth.

Runs **out-of-process on HTTP 2.0** — independent of Kaimon core's HTTP version; the
two talk over the Gate (ZMQ).

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
extension — a one-time **consented** prompt (no longer automatic on package load). Say yes and
restart Kaimon: your agents get the `slate.*` tools (`slate.open` / `slate.list` / `slate.close` / …),
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

See [PLAN.md](PLAN.md) for the architecture and roadmap.

## Status

Phase 0 (extraction) complete: 145 tests pass, serves end-to-end. Phase 2
(per-notebook gate workers + single-server hub) in progress — see PLAN.md.
