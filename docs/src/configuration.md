# Configuration

## Settings (⚙)

Open the gear in the top bar (or ⌘K → Settings). Settings persist per-browser in
localStorage.

| Setting | Effect |
| --- | --- |
| **Live-update debounce** | Minimum delay (ms) between live recomputes while dragging a control. Higher = fewer recomputes on a slow kernel. |
| **Full page width** | Use the full window width instead of the centered column. |
| **Theme** | Dark (default). |
| **Editor syntax** | Syntax-highlighting palette for the editor — Dark+, Monokai, Dracula, or Nord. |
| **Agent model** | Sonnet / Opus / Haiku, plus any locally-installed Ollama model. |
| **Agent permissions** | `lab` / `auto` / `default` / `bypass` preset for the agent. |

Model and permission changes [reap the agent](agent.md) so the next message respawns on the
new setting (the transcript is kept).

![The Settings modal](./assets/settings.png)

## Serving

The [`slate` app](installation.md) is the normal way to run the hub:

```sh
slate                 # start (or attach to) the hub + status TUI
slate notebook.jl     # also open a notebook
slate --own           # force a standalone hub even if a Kaimon extension is registered
```

The hub port is `KAIMONSLATE_PORT` (default 8765); set `KAIMONSLATE_NO_OPEN=1` to never open a
browser.

To drive the hub from your own script instead, the programmatic API is still available:

```julia
KaimonSlate.serve_notebook(path; host = "127.0.0.1", port = 8765)   # blocking
h = KaimonSlate.start_server(path; port = 8765)                     # non-blocking → Hub
KaimonSlate.stop_server(h)
```

`start_hub` / `open_notebook!` / `close_notebook!` / `stop_hub` give finer control over a
multi-notebook hub. See the [API Reference](api.md).

## Kernel selection

A notebook uses a **gate worker** when it sits inside a Julia project and Kaimon's gate is
available; otherwise it runs **in-process**. The gate worker gives you a clean namespace, a
tailable log (🪵), [package management](packages.md), and isolation. There's no setting for
this — it's chosen from the notebook's location. Restart a worker any time with **⟲ Restart
worker** (top bar), or rebuild the namespace with **↻ Rebuild**.

## Ollama (local models)

The agent model dropdown lists models from your local Ollama install, queried from its HTTP
API (embedding-only models are filtered out). Point at a non-default host with the standard
environment variable:

```bash
export OLLAMA_HOST=http://127.0.0.1:11434
```

Driving a local model requires Kaimon's Ollama agent backend. Selecting a model stores it as
`ollama:<name>`, which rides each chat turn.

## Environment variables

| Variable | Used for |
| --- | --- |
| `KAIMONSLATE_PORT` | Hub port for the `slate` app / server (default `8765`). |
| `KAIMONSLATE_NO_OPEN` | `=1` → never open a browser when the `slate` app starts. |
| `OLLAMA_HOST` | Ollama API endpoint for the model list (default `http://127.0.0.1:11434`). |
| `KAIMONSLATE_ASSET_BASE` | **Docs build only** — points the site at the docs-assets GitHub Release for generated demo media. Unset locally → served from `public/assets/`. |
