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

A worker can also run on **another machine** — a workstation, GPU box, or cloud VM — with the
notebook behaving exactly as if local. Set hosts up on the front page's **🖧 Remotes** dialog and
place a whole notebook with **Run on**, or route individual cells to a named
[region](regions.md) (kept warm for instant startup). See [Remotes](remotes.md).

## Remote worker timing

The SSH/connect/tunnel/transfer timeouts used when a worker runs on [another
machine](remotes.md) default to values tuned for a LAN. A slow-auth, high-latency, or cold
(heavy-precompile) host can legitimately exceed them — a cold cloud VM's first spawn, say,
outrunning the 120 s dial deadline. Rather than rebuild, override any of them per machine in a
`"remote"` object in `slate.json` (in your config home — `$XDG_CONFIG_HOME/kaimonslate/`, changes
apply on the next hub start):

```json
{
  "remote": {
    "dial_deadline_cold": 300,
    "ssh_connect_timeout": 30,
    "pkg_op_timeout": 1800
  }
}
```

Each key also has a `KAIMONSLATE_*` environment-variable equivalent (handy for a one-off run or a
test); precedence is **`slate.json` → env var → built-in default**. Values are **seconds** unless
noted.

| `slate.json` key | Env var | Default | Governs |
| --- | --- | --- | --- |
| `dial_deadline_cold` | `KAIMONSLATE_DIAL_DEADLINE_COLD` | `120` | Cold-spawn dial — covers remote Julia boot + KaimonGate load. |
| `dial_deadline_probe` | `KAIMONSLATE_DIAL_DEADLINE_PROBE` | `15` | Reattach-probe / warm-pool-adopt dial. |
| `dial_deadline_record` | `KAIMONSLATE_DIAL_DEADLINE_RECORD` | `5` | Record-first dial (a live worker answers in well under a second). |
| `connect_deadline_local` | `KAIMONSLATE_CONNECT_DEADLINE_LOCAL` | `90` | Local (`127.0.0.1`) worker connect deadline. |
| `ssh_connect_timeout` | `KAIMONSLATE_SSH_CONNECT_TIMEOUT` | `15` | `ConnectTimeout` for every ssh/scp/rsync op. |
| `ssh_control_persist` | `KAIMONSLATE_SSH_CONTROL_PERSIST` | `120` | SSH connection-mux master warm-hold past the last op. |
| `tunnel_alive_interval` | `KAIMONSLATE_TUNNEL_ALIVE_INTERVAL` | `5` | Supervised tunnel `ServerAliveInterval`. |
| `tunnel_alive_count` | `KAIMONSLATE_TUNNEL_ALIVE_COUNT` | `3` | Supervised tunnel `ServerAliveCountMax`. |
| `tunnel_respawn_backoff` | `KAIMONSLATE_TUNNEL_RESPAWN_BACKOFF` | `1` | Backoff after a dropped forward before respawning it. |
| `probe_timeout` | `KAIMONSLATE_PROBE_TIMEOUT` | `4` | `:direct` TCP port-open probe. |
| `firewall_giveup` | `KAIMONSLATE_FIREWALL_GIVEUP` | `10` | Sustained SYN-drop ⇒ declare a firewall and fail fast. |
| `pkg_op_timeout` | `KAIMONSLATE_PKG_OP_TIMEOUT` | `900` | Package add/rm/reconstruct — a heavy stack's resolve + precompile. |
| `sync_parent_timeout` | `KAIMONSLATE_SYNC_PARENT_TIMEOUT` | `600` | Parent-project `/src` sync. |
| `blob_xfer_timeout` | `KAIMONSLATE_BLOB_XFER_TIMEOUT` | `600` | Whole-binding / direct-blob boundary move. |
| `blob_chunk_timeout` | `KAIMONSLATE_BLOB_CHUNK_TIMEOUT` | `20` | Per-chunk ZMQ recv/send timeout on a transfer. |
| `sysimage_lock_stale` | `KAIMONSLATE_SYSIMAGE_LOCK_STALE` | `1800` | Concurrent sysimage-build lock staleness window. |
| `peer_bw_mbps` | `KAIMONSLATE_PEER_BW_MBPS` | `30` | Assumed rate (MB/s) for an unmeasured worker→worker link. |

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
