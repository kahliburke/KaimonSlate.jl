# Regions — split a notebook across kernels

A notebook runs on its **main kernel** (local, by default). With **regions** you send *some* of its
cells to a **second kernel on another host** — while the rest stay local — all in one notebook.
Boundary values cross automatically, so you can keep light cells local and push the heavy ones (a
GPU model, a big SQL query, a memory-hungry join) to a beefy remote, without splitting your work
into separate files.

Regions build on the remote-execution machinery — host setup, transports, and warm pools all live in
[Remotes & Pools](remotes.md). This page is about assigning cells to a region and understanding how
data crosses the boundary.

!!! note "New and evolving (v1)"
    Regions are a recent addition and still stabilizing. The single-worker path — running a *whole*
    notebook [on one host](remotes.md#run-a-notebook-on-a-remote) — is the settled option; per-cell
    regions add power with the [caveats below](#current-limits-v1).

## Assigning a cell to a region

A cell's region is a **cell tag**, so it travels in the `.jl`:

| Tag | Runs on |
| --- | --- |
| *(none)* | the main kernel — local |
| `remote` | the **`default`** region (sugar for `region=default`) |
| `region=<name>` | the named region |

You rarely type the tag by hand — three UI paths set it:

- **The 🏷 tag editor's "Run on" section** — radio rows: `💻 local` (main kernel, this machine) and one
  `🖧 <region>` per declared destination, plus **＋ Add destination…**.
- **The DAG node card's "Run on" picker** — a dropdown on any node in the [DAG pane](dag.md).
- **Drag a node into a region zone** — when regions exist, the DAG splits into columns (local + one
  per region); drop a cell into a column to run it there.

## Declaring destinations

A **destination** is a host (or [warm pool](remotes.md#warm-pools)) a region points at. Open the
**Destinations** manager (＋ Add destination… in the tag editor). You don't re-type a host here — you
**enable** one already set up on the front page's [🖧 Remotes](remotes.md#set-up-a-host)
dialog (SSH hosts, remembered remotes, and configured pools all appear). The **first** destination is
named `default`, so the bare `remote` tag works; later ones take the host's name.

!!! tip "Point a region at a warm pool"
    A destination backed by a [warm pool](remotes.md#warm-pools) **adopts** a ready worker (~1 s)
    instead of cold-booting (~90 s), because the region's remote project is keyed the same way the
    pool is. Set the pool's `preload` to the notebook's project and the region drops straight in.

Under the hood this writes a **`regionon`** entry into the notebook's config footer (so it travels
with the file):

- **One default region** → the bare form `host[,transport[,port,stream]]` (e.g. `hetzner-a100,direct`).
- **Several / named** → `name:spec;name2:spec2` (e.g. `gpu:hetzner-a100,direct;bigmem:slate-remote`).
- Each spec may add `root=PATH` to pin the region worker's data directory (its `@sfile` / data root).
  The path can't contain a comma.

Clearing all destinations brings the whole notebook back to the local kernel.

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

Under [Kaimon](agent.md), `slate_region_on(notebook, host)` sets a notebook's region destination
(the same `regionon` footer the Destinations manager writes).

## See also

- [Remotes & Pools](remotes.md) — hosts, transports, warm pools, `sync_memo`, data-transfer settings.
- [The Dependency Graph](dag.md) — the DAG pane, zones, and the region map.
- [Memoization & Caching](memoization.md) — the content-addressed store the transfers ride on.
- [Cell Tags & Caching](cell-tags.md) — the `region=`, `remote`, and `resource` tags.
