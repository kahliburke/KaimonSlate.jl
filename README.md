<div align="center">

<img src="docs/src/public/assets/slate-logo.svg" alt="KaimonSlate logo" width="110"/>

# KaimonSlate.jl

[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://kahliburke.github.io/KaimonSlate.jl/dev/)
[![CI](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/CI.yml)
[![Documentation](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/kahliburke/KaimonSlate.jl/actions/workflows/Docs.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A reactive Julia notebook for ambitious work. Cells can run across several machines, large live output stays interactive in the browser, an AI agent is available to assist in building the notebook content, and anything can be integrated through ordinary Julia packages.

[Documentation](https://kahliburke.github.io/KaimonSlate.jl/dev/) · [Getting started](https://kahliburke.github.io/KaimonSlate.jl/dev/getting-started)

<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/hero.png" alt="A reactive Slate notebook: a frequency slider and toggle driving a live chart" width="720"/>

</div>

## Overview

Cells form a dependency graph. When you change a value or move a `@bind` control, only the cells downstream of it recompute; there is no hidden kernel state and no manual "run all".

The graph is also the execution plan. A cell can run on a different machine, and values move between machines automatically over an encrypted, content-addressed channel, so the work is not bounded by the machine in front of you. Large outputs stream back to the browser fast enough to stay interactive. Extensions are first class: widgets, output types, front-end assets and whole subsystems are ordinary Julia packages.

The rest of this page covers the parts that go beyond a standard notebook.

## Run cells on another machine

Tag a cell with a region and it runs on a remote host (a GPU box, a big-memory server, a cloud VM) while the rest of the notebook stays local. Values that cross the boundary transfer automatically over an encrypted, content-addressed channel, so you don't move data by hand. The dependency graph lays out a zone per machine and shows which one ran each cell and how much data moved; warm pools keep workers ready, and a notebook's on-disk cache can move to the remote so results are restored there instead of recomputed.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/dag-region-map.png" alt="The dependency graph split into region zones" height="260"/>
&nbsp;
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/remote-activity.png" alt="Live per-region worker activity" height="260"/>
</div>

## AI agent

The agent edits the notebook by writing cells into the same `.jl` you edit. Ask it to add a control, draw a plot, or restructure a pipeline, and each change lands as a normal cell. It runs on Claude or a local model, and only when Kaimon is installed.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/agent-panel.png" alt="The agent panel adding a slider and a chart cell" width="260"/>
</div>

## Interactive output

Output renders inline and updates as you change `@bind` controls (sliders, toggles, selects, color and date pickers, buttons): CairoMakie figures, interactive ECharts plots, sortable and filterable tables, and animations played back in the browser.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/chart.png" alt="An interactive chart" width="215"/>
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/table-formatted.png" alt="A formatted table with in-cell bars" width="215"/>
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/animate.png" alt="A browser-played animation" width="215"/>
</div>

## Dependency graph & caching

The DAG pane shows the graph directly: cells colored by state (fresh, stale, running, errored) or by compute time, manual `needs=` edges for dependencies no variable carries, and which machine each cell last ran on. Expensive cells are memoized to a content-addressed store on disk, so a cached result is restored after a restart instead of recomputed, and identical results are stored once.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/dag-pane.png" alt="The DAG pane" height="260"/>
&nbsp;
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/dag-transfers.png" alt="A summary of cross-machine data transfers" height="260"/>
</div>

## Publish, present & export

A built-in manager publishes notebooks as a website, with targets for GitHub Pages, Cloudflare Pages, Netlify, S3/R2, and rsync, and can archive a citable version to Zenodo for a DOI. Any notebook is also a slide deck (a full-screen present mode), and exports to a Typst-typeset PDF, a self-contained HTML file, or a single `.jl` that bundles its full environment and git history for reproduction.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/publishing-manager.png" alt="The publishing manager listing documents and targets" width="325"/>
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/export-dialog.png" alt="The export dialog: PDF, HTML, or self-contained .jl" width="325"/>
</div>

## Reproducible environments

Each notebook is pinned to its own Julia project. Add and remove packages from the browser, and the resolved environment travels with the notebook's exports, so a shared notebook rebuilds the same versions elsewhere.

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/packages-panel.png" alt="The packages panel showing the notebook's environment" width="260"/>
</div>

## Timeline

Every run is recorded. The timeline steps back through a notebook's earlier states, outputs included.

## Install

The `slate` app is the usual entry point. **Requires Julia 1.12+.**

KaimonSlate is in the General registry. Install the app from the Pkg REPL (press `]`):

```julia-repl
pkg> app add KaimonSlate
```

Installing the app writes a **`slate` executable** — a shell script, or `slate.bat` on Windows — into
Julia's app bin directory, `~/.julia/bin`. That directory isn't on your `PATH` by default (`app add`
prints a reminder), so add it once:

```sh
export PATH="$HOME/.julia/bin:$PATH"     # in ~/.zshrc, ~/.bashrc, …
```

Now run `slate` **at your shell prompt** — it's a terminal command, not a Julia function:

```sh
slate                 # start or attach to the hub, with a status TUI
slate my_analysis.jl  # open a notebook in the browser (created if missing)
```

(At the `julia>` prompt it would just be an undefined variable; shell out with `;slate my_analysis.jl`
if you're already in the REPL.)

<div align="center">
<img src="https://github.com/kahliburke/KaimonSlate.jl/releases/download/docs-assets/slate-tui.gif" alt="The slate status TUI" width="560"/>
</div>

Slate runs in two ways:

- **With [Kaimon](https://github.com/kahliburke/Kaimon.jl)** — per-notebook workers, each pinned to the notebook's Julia project, plus the AI agent's `slate.*` tools. The first run asks once to register as a Kaimon extension.
- **Standalone** — `slate --own my_analysis.jl` runs the hub in-process, no Kaimon required. Cells, widgets, figures, and the timeline work; the AI agent needs Kaimon.

To embed the hub in your own script, add the package as a library and call the serving API:

```julia
using KaimonSlate
serve_notebook("notebook.jl"; port = 8765)   # blocks; open http://127.0.0.1:8765
```

See the [installation guide](https://kahliburke.github.io/KaimonSlate.jl/dev/installation) and the [architecture overview](https://kahliburke.github.io/KaimonSlate.jl/dev/architecture) for details.
