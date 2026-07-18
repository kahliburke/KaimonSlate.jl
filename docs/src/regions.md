# Regions — split a notebook across kernels

A notebook runs on its **main kernel** (local, by default). With **regions** you send *some* of its
cells to a **second kernel on another host** — while the rest stay local — all in one notebook.
Boundary values cross automatically, so you can keep light cells local and push the heavy ones (a
GPU model, a big SQL query, a memory-hungry join) to a beefy remote, without splitting your work
into separate files.

Regions are **named compute definitions** managed globally — a host, a transport, a data root, and how
many workers to keep warm. Host setup and transports live in [Remotes & Pools](remotes.md); this page is
about defining a region, assigning cells to it, and how data crosses the boundary.

!!! note "New and evolving (v1)"
    Regions are a recent addition and still stabilizing. The single-worker path — running a *whole*
    notebook [on one host](remotes.md#run-a-notebook-on-a-remote) — is the settled option; per-cell
    regions add power with the [caveats below](#current-limits-v1).

## Assigning a cell to a region

A cell's region is a **cell tag**, so it travels in the `.jl`:

| Tag | Runs on |
| --- | --- |
| *(none)* | the main kernel — local |
| `region=<name>` | the named region |

You rarely type the tag by hand — three UI paths set it:

- **The 🏷 tag editor's "Run on" section** — radio rows: `💻 local` (main kernel, this machine) and one
  `🖧 <region>` per declared destination, plus **＋ Add destination…**.
- **The DAG node card's "Run on" picker** — a dropdown on any node in the [DAG pane](dag.md).
- **Drag a node into a region zone** — when regions exist, the DAG splits into columns (local + one
  per region); drop a cell into a column to run it there.

## Defining a region

A **region** is a global, named compute definition — it lives in the **🖧 Remotes → Regions** manager on
the front page, not in any one notebook. A region carries:

- a **host** (an SSH host) reached over a **transport** (`tunnel` or `direct`),
- an optional **preload** — a *local* project dir whose environment is replicated on the host and
  precompiled on idle workers, so a notebook adopts a ready worker instead of cold-booting,
- a **data root** — a *remote* path pinned as the workers' `datadir()` / `@sfile`,
- a **cache root** — a *remote* path for the region's own durable [cache](memoization.md), kept
  separate from other workers on the box (so a co-located region moves a blob across the boundary
  rather than deduping it to nothing against a shared store),
- a **warm** count — how many workers to keep booted and idle, ready to *adopt* (0 = cold spin on demand),
- and worker **thread counts** (`"<compute>,<interactive>"`).

Many regions can point at the **same host** with different config (e.g. `gpu` and `gpu_scratch` on one box
with different data roots). Names are folded to identifiers (`slate-remote` → `slate_remote`) so they
always match a `region=` tag.

![The Regions manager focused on a host: a region's config (warm count, transport, sysimage, data root), the New-region editor, and the host's live worker roster with per-worker telemetry and a parked warm worker](./assets/region-focus.png)

!!! note "Advanced, still settling"
    Two newer per-region knobs: an opt-in **sysimage** (a PackageCompiler image baked for the region's
    workers, for faster startup) and a **`curve`** toggle — the region's data channel is
    CURVE-encrypted by default; turn it off only for a co-located / loopback region where encryption is
    pure overhead.

## Using a region in a notebook

Open the **Destinations** manager (＋ Add destination… in the tag editor) and **enable** the regions this
notebook uses — you pick from the regions already defined on the front page. This writes their names into
the notebook's **`regions`** config footer (so the choice travels with the file); cells then tag
`region=<name>`. Clearing all destinations brings the whole notebook back to the local kernel.

!!! tip "Keep a region warm"
    A region with **warm > 0** keeps that many workers booted and idle; running a tagged cell then
    **adopts** a ready worker (~1 s) instead of cold-booting (~90 s). Set the region's `preload` to the
    notebook's project so the adopted worker already has its packages loaded.

## How boundary values cross

When a cell runs, any value it **reads** that was produced on a *different* kernel is shipped to the
cell's kernel first, **just in time** — you never move data by hand.

- **Only the boundary crosses.** A large frame that's produced *and* consumed on the same region
  never leaves it; only a value read across a side boundary transfers.
- **Content-addressed transfer.** Values cross as content-addressed blobs over the dedicated data
  channel; a `DataFrame` crosses as Arrow IPC (see [Memoization → Arrow](memoization.md#arrow-tables-and-codecs)).
  Identical content dedups at every hop, and an unchanged value doesn't re-ship — a per-transfer
  freshness token (source run + any mutators + the current `@bind` value + the destination worker's
  generation) collapses a repeat to nothing.
- **Progress is visible.** A transfer past a size threshold drives the cell's own progress bar
  (`⇄ <name>: N/M MB ← host`), so a big move never looks like a hang.

The DAG's **⇄ peer routing plan** shows how each region pair is wired — a resolved *direct* or *ssh-bridge*
route worker-to-worker, or a *relay* through the hub — plus the per-host grants and host-key pins:

![The peer routing plan panel: resolved routes between regions (gpu ← db direct, db ← gpu ssh-bridge, db ← local relay) and, under MESH, the per-host grants and pinned addresses](./assets/dag-peer-plan.png)

The first time two regions on different hosts need a worker-to-worker link, Slate asks before exchanging
keys — decline and transfers still work, just relayed through the hub:

![The connect-regions consent dialog: it lists the region pair and hosts to bridge, explains exactly what it installs (an on-host ed25519 key, a locked-down single-port grant, a host-key pin), and offers Not now / Connect & exchange keys](./assets/mesh-consent.png)

The DAG's **📊 transfers** dashboard summarizes every boundary move — total moved, throughput over time, a
region-to-region grid, and the rate distribution:

![The transfer summary dashboard: stat tiles (total moved, transfer count, average and peak MB/s), a throughput-over-time chart, a region peer-to-peer heatmap, and a rate-distribution curve](./assets/dag-transfers.png)
- **Live handles aren't shipped.** A cell that produces a live DB connection / socket / open file
  (a [`resource`](cell-tags.md) cell) can't cross the wire — instead its setup is **replayed** on the
  destination so each side opens its own handle. If a live handle would cross, the run stops and names
  the fix: tag the producing cell `resource`.

## Seeing where cells run

Every cell records **where it last ran** — surfaced across the [DAG pane](dag.md):

- **🖧 badge + chips** — a node whose last run was remote wears a `🖧` prefix; its details card shows a
  *last ran* chip (`⌂ local` / `🖧 <host>`) and a *moved ⇄ N MB* chip when a boundary transfer fed it.
- **Region zones** — the DAG lays out side-by-side columns (`💻 local · main kernel`, `🖧 <name> · <host>`);
  cross-column edges *are* the boundary transfers, and you drag cells between columns to reassign.
- **🖧 region map** — the DAG's region-map toggle recolors nodes by where they run, with a legend
  naming the hosts.

![The DAG laid out as region zones — local · main kernel, db · db-box, gpu · gpu-box — with each cell colored by where it ran and the cross-zone hand-offs drawn as labeled edges](./assets/dag-region-map.png)

Provenance only appears while a region is active — a plain local notebook shows none of it. For the
worker-level view (roster, telemetry, where a notebook's kernels live), see
[Remotes & Pools → Diagnostics](remotes.md#diagnostics).

## Restarting a region

Restart a single region from its worker controls — it kills that region's worker, marks its cells
stale, and re-runs them, leaving the rest of the notebook untouched. Closing the notebook or
restarting the main worker tears down region kernels too.

## Current limits (v1)

Regions are powerful but still settling. Today:

- **Keep the main kernel local** while a region is active.
- **`@bind`-declaring cells stay on the main kernel** — declare controls locally, read them anywhere.
- **Cross-boundary mutation is undefined.** A region cell should *produce* values, not mutate an
  object that lives on the main kernel. An untagged cell that mutates a region value auto-follows its
  target one hop, but deeper mutation chains aren't guaranteed.

Expect this surface to grow; the whole-notebook [remote placement](remotes.md#run-a-notebook-on-a-remote)
is the conservative choice when you want everything elsewhere.

## From the agent

Under [Kaimon](agent.md), define a region with `slate_region(name; host, warm, preload, data_root, …)`,
choose which regions a notebook uses with `slate_region_on(notebook, "name1,name2")`, and list the
registry with `slate_regions()`.

## See also

- [Remotes & Pools](remotes.md) — hosts, transports, warm pools, `sync_memo`, data-transfer settings.
- [The Dependency Graph](dag.md) — the DAG pane, zones, and the region map.
- [Memoization & Caching](memoization.md) — the content-addressed store the transfers ride on.
- [Cell Tags & Caching](cell-tags.md) — the `region=` and `resource` tags.
