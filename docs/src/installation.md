# Installation

KaimonSlate runs best as a **[Kaimon](https://github.com/kahliburke/Kaimon.jl) extension** —
that's the full experience: each notebook evaluates in its own gate worker (clean namespace,
package management, a tailable log) and the **AI agent** can drive the notebook through the
`slate.*` tools. A lighter **standalone** mode works without Kaimon for a quick look.

Either way, you drive it with the **`slate` app** — a small launcher, installed with Julia's app
system, that starts (or attaches to) the notebook hub and shows a status TUI.

## Requirements

- **Julia 1.12 or newer** — the `slate` app uses Julia's app system.
- A browser (any modern Chromium/Firefox/Safari).
- **[Kaimon](https://github.com/kahliburke/Kaimon.jl)** (recommended) — for the gate workers and
  the AI agent. For the agent's models: a logged-in `claude` CLI (Claude models) and/or a running
  [Ollama](https://ollama.com) (local models).

## Recommended path

### 1. Install Kaimon

Install Kaimon and make sure it runs (see the Kaimon docs). Log in the `claude` CLI and/or start
Ollama if you want the agent. This gives KaimonSlate its gate workers and the agent runtime.

### 2. Install the `slate` app

From the Pkg REPL (press `]`), install KaimonSlate as an **app** — this puts a `slate` launcher on
your `PATH`. During the pre-release, install it as a **developed app**: a plain `app add <url>` can't
yet resolve the bundled `SlateExtensionsBase` (it's shipped in the repo's `lib/`, not a registry — that
arrives with registration).

```julia-repl
pkg> app dev https://github.com/kahliburke/KaimonSlate.jl
```

This clones the repo to `~/.julia/dev/KaimonSlate`. `Pkg.Apps` doesn't instantiate the dev'd project,
so do it once yourself — this resolves `SlateExtensionsBase` (dev'd in place from the clone's `lib/`)
and the rest of the dependencies:

```julia-repl
pkg> activate ~/.julia/dev/KaimonSlate
pkg> instantiate
pkg> activate                 # back to your default environment
```

The launcher lands in Julia's app bin — if `slate` isn't found, add that directory (printed by
`app dev`) to your `PATH`. (Once KaimonSlate is registered in General, `pkg> app add KaimonSlate` will
be the one-liner.)

### 3. Run `slate`

```sh
slate                 # start (or attach to) the hub + status TUI
slate my_analysis.jl  # also open that notebook in the browser (created if missing)
```

The **first time** you run it with Kaimon installed, `slate` offers to register itself as a
Kaimon extension:

```
Register Slate as a Kaimon extension now?  [Y]es · [n]o · [d]on't ask again
```

Say **yes** — Kaimon scans for extensions dynamically, so it's picked up without a restart. `slate`
stays open and **attaches the moment Kaimon brings the hub up**. Now your agents have the `slate.*`
tools and **Kaimon serves your notebooks from its own hub — no extra process** — and running `slate`
again **attaches** to that hub as a live status viewer.

!!! tip "Consented, not automatic"
    Registration is a one-time prompt you approve — it replaces the old silent auto-register on
    package load. Nothing wires itself into Kaimon behind your back;
    `KaimonSlate.register_extension()` registers manually, and `slate` never overwrites a
    registration you removed.

### 4. Open the browser

`slate` opens your notebook automatically. Otherwise browse the hub index at
**`http://127.0.0.1:8765`** (set `KAIMONSLATE_PORT` to move it) — it lists open notebooks and
opens more by path — or just **ask the 💬 agent** to open one (`slate.open`). See
[The AI Agent](agent.md) for the full tool surface.

## Standalone (without Kaimon)

`slate --own` runs the hub **in-process**, without Kaimon (also the default when Kaimon isn't
installed):

```sh
slate --own                 # own the hub locally, even if a Kaimon extension is registered
slate --own analysis.jl
```

Cells evaluate, widgets and figures work, and the [Timeline](history.md) records history. The AI
agent is unavailable (it needs Kaimon), and notebooks evaluate in-process rather than in a
per-notebook worker.

## The status TUI

However you start it, `slate` shows a terminal dashboard:

![The slate status TUI: server state, the hub URL, Kaimon-extension status, and a live table of open notebooks with their cell / running / stale / error counts](./assets/slate-tui.gif)

- **Server** — whether the hub is *up* (this process owns it), *attached* (an external
  Kaimon-extension hub), or *waiting* for the extension to come up — plus the hub URL and whether
  Slate is registered with Kaimon.
- **Notebooks** — a live table of every open notebook: cells, running / stale / errored counts,
  its worker port, and URL.
- **Keys** — `↑↓`/`enter` open the selected notebook, `o` opens the hub index, `r` restarts the
  hub you own, `s` starts a local hub (when waiting on the extension), `q` quits.

## Embedding (programmatic)

To drive the hub from your own script instead of the app, the REPL API is still available —
`serve_notebook` / `start_server` / `stop_server` — see [Configuration](configuration.md#serving)
and the [API Reference](api.md).

!!! tip "In-process vs. gate worker"
    Even standalone, a notebook gets its own **gate worker** when it sits inside a Julia project
    and Kaimon's gate is available — giving it a clean namespace, a tailable log, package
    management, and isolation from the server. Otherwise it evaluates in-process. See
    [Architecture](architecture.md).

## Next steps

- [Getting Started](getting-started.md) — open your first notebook and build a few cells.
- [The AI Agent](agent.md) — hand work to the agent through the `slate.*` tools.
- [Architecture](architecture.md) — how the pieces fit together.
