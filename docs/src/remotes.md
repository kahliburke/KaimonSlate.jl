# Remotes

A notebook's **worker** — the Julia process that evaluates its cells — normally runs on your
machine. It can just as easily run on **another machine**: a beefy workstation, a GPU box, a cloud
VM. Reactivity, hot-reload, package management, figures, and streaming all stay transparent — only
the compute moves.

There are two ways to use another machine:

- **Move the whole notebook** — place its entire worker on a host with **`run_on`**. Every cell,
  main kernel included, runs there.
- **Send some cells** — keep the main kernel local and route heavy cells to a named
  **[region](regions.md)**, which can also keep workers *warm* for instant startup.

This page covers host setup, whole-notebook placement, and diagnostics. Per-cell regions — and warm
workers — live in **[Regions](regions.md)**.

## Requirements

A remote is any **SSH host you already reach with key auth** — a `Host` entry in `~/.ssh/config`
(or a `user@host` you can `ssh` to without a password prompt). KaimonSlate provisions the rest:
it checks the host, ensures a Julia + environment is present, and starts the worker for you.

## Set up a host

On the hub's [front page](getting-started.md#the-front-page), click **🖧 Remotes** to add and test a
host:

- **Host** — the SSH target (`my-workstation`, or `user@host`).
- **Transport** — how the notebook talks to the worker:
  - **SSH tunnel** (default) — traffic is forwarded over the SSH connection. Works anywhere `ssh`
    works, opens no extra ports, needs no firewall changes. The safe default.
  - **Direct · CURVE** — encrypted ZeroMQ sockets straight to the host (CurveZMQ), lower overhead than
    an ssh forward. Needs the worker's ports reachable through any firewall — pin them under **Ports**
    (blank = auto, `9100+`) and open them on the host.

  Either way, cache and boundary-value transfers ride a dedicated **data channel** (a CURVE socket on
  `direct`, its own ssh forward on `tunnel`) so a big shipment never queues ahead of cell results.
- **🩺 Test & prime** — a full reported dry-run: SSH reachability, Julia presence (+ version),
  environment provisioning, gate load, a CURVE key (for `direct`), then a real
  spawn → connect → round-trip eval → clean teardown. It returns a step-by-step checklist **and
  primes the host**, so the first real notebook run is fast (cold provisioning happens here, once).

!!! tip "Run the preflight first"
    Always **Test & prime** a new host before running a notebook on it — it catches setup problems
    (missing Julia, closed ports, key auth) with a clear checklist instead of a stuck worker, and
    warms the host so the first real run doesn't pay provisioning time.

## Run a notebook on a remote

Two ways to place a notebook's worker:

- **When you open it** — the front page's **Run on** selector (next to Open / ⬆ Upload) picks
  *local* or a configured host before the notebook opens.
- **On a live notebook** — switch it any time; the worker moves and the notebook re-runs.

Placement has a **scope**, so you control how sticky it is:

| Scope | Meaning |
| --- | --- |
| **session** | This session only — not saved. The default. |
| **notebook** | Durable — saved in the `.jl` so the notebook **reopens on that host**. |
| **clear** | Drop the overrides and fall back to the global default / local. |

## Keeping workers warm

A whole-notebook `run_on` **spawns** a fresh worker on the host — a cold boot (provision + start
Julia + load packages) that can be ~90 s the first time (a later reattach reuses a parked
connection). To keep workers **pre-booted and ready to adopt** — startup in about a second instead of
a cold boot — define a **[region](regions.md)** with a `warm` count and route cells to it. Warm
pooling is now part of the region model: a region with `warm > 0` *is* a warm pool, and its
`preload` replicates a project so the adopted worker already has its packages loaded. See
[Regions → Defining a region](regions.md#defining-a-region).

## Your cache follows you

KaimonSlate's [durable cache](memoization.md) can move to the remote so it **restores** cached
results there instead of recomputing them — "your session follows you."

- **On attach**, cached results are carried over automatically **when moving them beats recomputing**
  — and never if a single entry would take longer than the **carry-time budget** to transfer (that
  cell just recomputes remotely instead).
- **`sync_memo(notebook)`** pushes **everything** — all of the notebook's local cache blobs — to the
  remote, deduping against what it already has. It works over either transport (`direct` dials the
  CURVE data socket; `tunnel` uses a dedicated ssh forward, so a big shipment never queues ahead of
  cell results), and it also runs automatically in the boot window on every remote (re)attach.

Tune the transfer under **🖧 Remotes → Data transfer** (applies to all notebooks):

| Setting | Effect |
| --- | --- |
| **Transfer chunk size** | MB moved per round-trip. Transfers ride their own channel, so this never delays cell results — smaller chunks bound per-chunk timeouts and let an abort land sooner on a slow uplink; bigger ones move data faster on a good link. |
| **Carry-time budget** | On attach, an entry is only carried if moving it is worth it and it fits in this budget; otherwise the cell recomputes. (`sync_memo` ignores this — it always pushes everything.) |
| **Confirm transfers over** | When a cell needs a value that must cross the network, it pauses with an exact size + estimated-time preview if the transfer would take longer than this; run the cell again to proceed. `0` never asks. |

## Diagnostics

When a notebook runs remotely — or across [regions](regions.md) — several surfaces show what's
happening and where.

**Where a notebook runs** (agent tools; also usable from any REPL):

- **`whereis(notebook)`** — this notebook's live placement: local (pid/port) or remote host, the
  transport, ports (main / stream / data), connection state, and, for a remote, whether it **adopted
  a warm worker** — plus its latest telemetry.
- **`remote_workers(host)`** — a host's full roster: each worker's lifecycle badge (⚪ stopped ·
  🔵 warm·region · 🟡 idle · 🟢 attached/running), the notebook it serves, last-activity age, and
  telemetry (cpu %, RSS, cache size, running count) alongside host-wide cpu / load / memory.
- **`regions()`** — the compute registry: every configured region (host, warm count, preload, data
  root, last reconcile) and parked wires. (See [Regions](regions.md).)

**The Remote activity strip** — on the hub's front page, a live "top" for your remote/region workers,
**grouped by region**: each worker row shows a CPU meter, RSS, and *what it's doing* (▶ running-cell
ids · ⏳ warming · ✓ ready · idle), with a click-through detail popup (cpu/rss sparklines + full
telemetry). It refreshes every few seconds and hides itself when you have no regions or remote hosts.

**Inside the notebook:**

- **The worker/region pill** (top bar) — a live status pill for the notebook's worker, and one per
  active region, ranked so the one needing attention shows first. Click it for a dropdown of every
  worker plus a side panel that **streams that worker's log and telemetry** (cpu / rss / running cell)
  live over the page's WebSocket — no polling.
- **🪵 Worker log** (**☰ → Worker log**, or the command palette) — a full tail of the main worker's
  log, following the bottom as it grows. For a remote worker it interleaves the local orchestration
  log and the remote worker's own log.
- The [DAG pane](dag.md)'s **🖧 region map** and per-cell provenance chips show where each cell last
  ran and how much data crossed the boundary — see [Regions → Seeing where cells run](regions.md#seeing-where-cells-run).
- **📋 Activity log** — a per-cell run feed (distinct from the worker pill and the front-page strip).

!!! note "`slate_diag` is browser diagnostics, not worker state"
    Despite the name, `slate_diag` reports the **browser tab's console** (JS errors, failed asset
    loads) — useful for a broken widget or a 404, not for where a notebook runs. For execution and
    worker state use `whereis` / `remote_workers` / `regions` and the 🪵 worker log.

## From the agent

Under [Kaimon](agent.md), the agent drives all of this through `slate.*` tools — each one's schema
has the full parameters (`slate_api("remote")` lists them):

| Tool | Does |
| --- | --- |
| `slate_run_on(notebook, host, scope)` | Place a **whole** notebook's worker (local / SSH host; transport; scope). |
| `slate_check_remote(host, transport)` | Preflight + prime a host (the **Test & prime** dry-run). |
| `slate_remote_workers(host)` | A host's live worker roster + telemetry. |
| `slate_reap_worker(host, port)` | Kill and remove one remote worker. |
| `slate_whereis(notebook)` | Where a notebook runs right now. |
| `slate_sync_memo(notebook)` | Push the notebook's full cache to its remote worker. |

Defining named regions and assigning them to a notebook has its own tools — `slate_region`,
`slate_region_on`, `slate_regions` — see [Regions → From the agent](regions.md#from-the-agent).

## See also

- [Regions](regions.md) — run *part* of one notebook on a remote kernel while the rest stays local.
- [Memoization & Caching](memoization.md) — the durable cache that `sync_memo` moves.
- [Configuration](configuration.md) — hub port, kernel selection, environment variables.
- [Packages](packages.md) — a notebook's per-project environment (what `preload` replicates).
