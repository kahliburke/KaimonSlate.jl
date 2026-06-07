# Installation

KaimonSlate is a Julia package. It runs in two modes:

- **Standalone** — serve a notebook directly from a Julia session. Cells evaluate, widgets
  and figures work, history is recorded. The AI agent is unavailable (it needs Kaimon).
- **As a [Kaimon](https://github.com/kahliburke/Kaimon.jl) extension** — the full
  experience: cells evaluate in a per-notebook gate worker, and the AI agent can drive the
  notebook through the `slate.*` tools.

## Requirements

- Julia 1.10 or newer.
- A browser (any modern Chromium/Firefox/Safari).
- For the AI agent: [Kaimon](https://github.com/kahliburke/Kaimon.jl) with a logged-in
  `claude` CLI (for Claude models) and/or a running [Ollama](https://ollama.com) for local
  models.

## Add the package

```julia
using Pkg
Pkg.add(url = "https://github.com/kahliburke/KaimonSlate.jl")
```

## Standalone

```julia
using KaimonSlate

# Open one notebook and block, serving at http://127.0.0.1:8765
KaimonSlate.serve_notebook("analysis.jl")
```

Or start a non-blocking hub you can add notebooks to:

```julia
h = KaimonSlate.start_server("analysis.jl"; port = 8765)
# ... later ...
KaimonSlate.stop_server(h)
```

If the notebook file does not exist it is created with a starter cell. Open the printed
URL; the index page lists open notebooks and lets you open more.

::: tip In-process vs. gate worker
Standalone notebooks evaluate **in-process** unless they sit inside a Julia project and
Kaimon's gate is available, in which case each notebook gets its own worker process. The
worker gives you a clean namespace, a tailable log, package management, and isolation from
the server. See [Architecture](architecture.md).
:::

## As a Kaimon extension

Register KaimonSlate as a managed extension in Kaimon. Once loaded, the agent gains the
`slate.*` tools (`slate_open`, `slate_add_cell`, `slate_edit_cell`, `slate_run`,
`slate_view`, …) and the notebook UI exposes the **💬 agent** chat pane. See
[The AI Agent](agent.md) for the full tool surface and model/permission options.

## Next steps

- [Getting Started](getting-started.md) — open your first notebook and build a few cells.
- [Architecture](architecture.md) — how the pieces fit together.
