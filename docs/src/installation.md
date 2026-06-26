# Installation

KaimonSlate is a Julia package designed to run as a **[Kaimon](https://github.com/kahliburke/Kaimon.jl)
extension** — that's the full experience, and the recommended way to install it. Each notebook
evaluates in its own gate worker (clean namespace, package management, a tailable log) and the
**AI agent** can drive the notebook through the `slate.*` tools. A lighter **standalone** mode
is also available for a quick look without Kaimon.

## Requirements

- Julia 1.10 or newer.
- A browser (any modern Chromium/Firefox/Safari).
- **[Kaimon](https://github.com/kahliburke/Kaimon.jl)** — for the gate workers and the AI agent.
  For the agent's models: a logged-in `claude` CLI (Claude models) and/or a running
  [Ollama](https://ollama.com) (local models).

## Recommended: as a Kaimon extension

This is the path most users want. Kaimon manages the KaimonSlate subprocess, gives each
notebook its own worker, and exposes the notebook to the agent.

1. **Install Kaimon** and make sure it runs (see the Kaimon docs). Log in the `claude` CLI
   and/or start Ollama if you want the agent.

2. **Get KaimonSlate.** Clone it (or `Pkg.add` it into an environment Kaimon can see):

   ```julia
   using Pkg
   Pkg.add(url = "https://github.com/kahliburke/KaimonSlate.jl")
   ```

3. **Register it as an extension.** Point Kaimon at the KaimonSlate.jl project directory (the
   one containing `kaimon.toml`) — either through the **Extensions tab** in the Kaimon UI
   (easiest) or by adding the path to `~/.config/kaimon/extensions.json`. The bundled
   `kaimon.toml` declares the `slate` namespace and the tools/event wiring:

   ```toml
   [extension]
   namespace = "slate"
   module    = "KaimonSlate"
   ```

4. **Reload extensions.** Kaimon loads the `slate` namespace and the agent gains the
   `slate.*` tools — `slate.open`, `slate.list`, `slate.close`, plus the per-notebook
   `slate_add_cell` / `slate_edit_cell` / `slate_run` / `slate_view` / … Each notebook runs
   in its own gate worker, pinned to the Julia project its `.jl` file lives in.

Now ask the agent to open a notebook (`slate.open`), or open one yourself — the **💬 agent**
chat pane is available in the UI. See [The AI Agent](agent.md) for the full tool surface and
the model / permission options.

## Standalone (without Kaimon)

For a quick look — cells evaluate, widgets and figures work, and the [Timeline](history.md)
records history. The AI agent is unavailable (it needs Kaimon), and notebooks evaluate
**in-process** rather than in a per-notebook worker.

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

If the notebook file does not exist it is created with a starter cell. Open the printed URL;
the index page lists open notebooks and lets you open more.

::: tip In-process vs. gate worker
Even standalone, a notebook gets its own **gate worker** when it sits inside a Julia project
and Kaimon's gate is available — giving it a clean namespace, a tailable log, package
management, and isolation from the server. Otherwise it evaluates in-process. See
[Architecture](architecture.md).
:::

## Next steps

- [Getting Started](getting-started.md) — open your first notebook and build a few cells.
- [The AI Agent](agent.md) — hand work to the agent through the `slate.*` tools.
- [Architecture](architecture.md) — how the pieces fit together.
