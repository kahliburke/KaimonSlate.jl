# Remotes & Worker Pools

A notebook's **worker** — the Julia process that evaluates its cells — normally runs on your
machine. It can just as easily run on **another machine**: a beefy workstation, a GPU box, a cloud
VM. Reactivity, hot-reload, package management, figures, and streaming all stay transparent — the
notebook behaves exactly as if it were local; only the compute moves.

Each notebook is placed **independently**, so one can run locally while another runs on a remote
host, each in its own worker.

## Requirements

A remote is any **SSH host you already reach with key auth** — a `Host` entry in `~/.ssh/config`
(or a `user@host` you can `ssh` to without a password prompt). KaimonSlate provisions the rest:
it checks the host, ensures a Julia + environment is present, and starts the worker for you.

## Set up a host — 🖧 Remotes

On the hub's [front page](getting-started.md#the-front-page), click **🖧 Remotes** to add and test a
host:

- **Host** — the SSH target (`my-workstation`, or `user@host`).
- **Transport** — how the notebook talks to the worker:
  - **SSH tunnel** (default) — traffic is forwarded over the SSH connection. Works anywhere `ssh`
    works, opens no extra ports, needs no firewall changes. The safe default.
  - **Direct · CURVE** — encrypted ZeroMQ sockets straight to the host (CurveZMQ). Lower overhead,
    and it's what enables the **data channel** that carries your cache (see
    [below](#your-cache-follows-you)). Needs the worker's ports reachable through any firewall — pin
    them under **Ports** (blank = auto, `9100+`) and open them on the host.
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

## Warm pools

A cold remote worker pays a one-time boot (provision + start Julia + load packages) that can be
~90 s. A **warm pool** removes that wait: keep a few prewarmed workers idling on a host, and opening
a matching notebook **adopts** one in about a second.

- **`warm_pool(host; n, preload)`** — keep `n` prewarmed workers on `host`. Each is a booted Julia
  process with the gate serving and the eval path warmed; `preload` (a local project directory)
  additionally replicates that environment on the host and imports its packages while idle. Opening
  a notebook whose project matches `preload` then **adopts** a pool worker (dial + namespace swap —
  packages and cache survive) instead of cold-booting, and the pool refills itself in the
  background. `n=0` drains idle pool workers (attached workers are never touched). Safe to re-run —
  it reconciles toward `n`.
- **`pools()`** — the hub's view: every configured pool (host, target size, preload env, transport)
  and every **parked wire** (a live connection kept across a notebook close for instant reattach).
- **`remote_workers(host)`** — a host's live roster: which notebook each worker serves, its state
  (attached / idle / pool), telemetry (cpu / rss / cache size), and whether it looks abandoned.
- **`reap_worker(host, port)`** — explicitly kill one worker and remove its files. Manual only —
  nothing is auto-reaped, so a worker holding useful results is safe until you remove it.
- **`whereis(notebook)`** — where a given notebook runs right now (local pid/port or remote host),
  with transport, ports, connection state, and pool provenance.

## Your cache follows you

KaimonSlate's [durable cache](cell-tags.md#caching) can move to the remote so it **restores** cached
results there instead of recomputing them — "your session follows you."

- **On attach**, cached results are carried over automatically **when moving them beats recomputing**
  — and never if a single entry would take longer than the **carry-time budget** to transfer (that
  cell just recomputes remotely instead).
- **`sync_memo(notebook)`** pushes **everything** — all of the notebook's local cache blobs — to the
  remote, deduping against what it already has. Requires a **`direct`**-transport worker (the cache
  rides the CURVE data channel, gate port + 2).

Tune the transfer under **🖧 Remotes → Data transfer** (applies to all notebooks):

| Setting | Effect |
| --- | --- |
| **Transfer chunk size** | MB moved per round-trip. Transfers ride their own channel, so this never delays cell results — smaller chunks bound per-chunk timeouts and let an abort land sooner on a slow uplink; bigger ones move data faster on a good link. |
| **Carry-time budget** | On attach, an entry is only carried if moving it is worth it and it fits in this budget; otherwise the cell recomputes. (`sync_memo` ignores this — it always pushes everything.) |
| **Confirm transfers over** | When a cell needs a value that must cross the network, it pauses with an exact size + estimated-time preview if the transfer would take longer than this; run the cell again to proceed. `0` never asks. |

## From the agent

Under [Kaimon](agent.md), the agent drives all of this through `slate.*` tools — each one's schema
has the full parameters (`slate_api("remote")` lists them):

| Tool | Does |
| --- | --- |
| `slate_run_on(notebook, host, scope)` | Place a notebook's worker (local / SSH host; transport; scope). |
| `slate_check_remote(host, transport)` | Preflight + prime a host (the **Test & prime** dry-run). |
| `slate_warm_pool(host; n, preload)` | Maintain a warm pool for instant adoption. |
| `slate_pools()` | Configured pools + parked wires (the hub view). |
| `slate_remote_workers(host)` | A host's live worker roster + telemetry. |
| `slate_reap_worker(host, port)` | Kill and remove one remote worker. |
| `slate_whereis(notebook)` | Where a notebook runs right now. |
| `slate_sync_memo(notebook)` | Push the notebook's full cache to a `direct` remote. |

## See also

- [Configuration](configuration.md) — hub port, kernel selection, environment variables.
- [Cell Tags & Caching](cell-tags.md) — the durable cache that `sync_memo` moves.
- [Packages](packages.md) — a notebook's per-project environment (what `preload` replicates).
