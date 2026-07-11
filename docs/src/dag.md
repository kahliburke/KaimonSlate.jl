# The Dependency Graph

Every notebook is a **directed acyclic graph** of cells: the engine reads which variables each cell
reads and writes, and draws an edge wherever one cell consumes another's value. That graph is what
makes the notebook [reactive](reactivity.md) — change a value and only the downstream cells restale.

This page is about **seeing and shaping** that graph: the DAG pane, manual edges for effects no
variable carries, and running part of a notebook on another kernel (regions).

## The DAG pane

Open the pane with the **🕸 DAG** button in the top bar, or **⌘⇧G**. It's a live map of the
notebook's dataflow — one node per cell, an edge wherever a cell reads a value another cell writes —
laid out automatically and updated as you edit and run.

![The DAG pane: the notebook's cells as a dataflow graph, each node colored by state, with heat-map and region-map toggles](./assets/dag-pane.png)

- **Node color** mirrors each cell's [state](reactivity.md#cell-states) — fresh / stale / running /
  errored — so a wave of gold shows exactly what a change restaled.
- **⚙ display** — **show setup cells** (`using`/`import` and their edges) and **show isolated cells**
  (cells with no dataflow edges) are off by default, keeping the graph to the cells that actually
  pass data.
- **⇅ direction** — layout orientation; *auto* follows the pane shape (a tall pane lays out
  top-down).
- **◨ dock** and the **grip** re-side and resize the pane.
- **🔥 heat map** — color cells by accumulated compute time (hotter = more expensive), to find the
  bottleneck in a pipeline.
- **🖧 region map** — color cells by *where they run* (see [Regions](#regions)).

## Manual edges

The engine infers edges from the variables a cell reads and writes. Some dependencies aren't carried
by any variable, though — a cell that writes a file, seeds a database table, or mutates global state
that a later cell reads back. Assert those yourself so the engine keeps the two in order:

- **`needs=id1,id2`** header tag — set it with the **🏷 tag editor** or directly in the cell header.
  It names the earlier code cells this one depends on.
- **🔗 link mode** in the DAG pane — click it, then click two cells to draw a manual edge (shown
  **dashed**); click a dashed edge to remove it.

Manual edges are first-class: they drive staleness, run order, and cache keys exactly like inferred
ones. A `needs=` that names no earlier code cell (deleted, moved below, or a markdown cell) is inert
and flagged with a **🔗⚠** badge on the cell.

## Regions

A **region** (destination) is a *second kernel* — usually on another machine — where **some** of a
notebook's cells run, while the rest stay on the main kernel. It lets you keep light cells local and
push the heavy ones (a GPU model, a large query) to a beefy host, all in **one** notebook.

- Tag a cell **`region=<name>`** — or the bare **`remote`** tag, which is sugar for the `default`
  region — and it executes on that region's kernel. **Boundary values cross automatically** as
  content-addressed blobs; you don't move data by hand.
- Declare destinations in the **Destinations manager** (the per-cell *Run on* picker in the 🏷 tag
  editor, and a notebook-level declare/remove). Point a region at a [warm pool](remotes.md#warm-pools)
  so it **adopts** a ready worker instead of paying a cold boot.
- The DAG pane's **🖧 region map** colors cells by where they run, with a legend naming the hosts, and
  a cell wears a **🖧** badge when its last run executed on a region kernel.

Regions build directly on the remote-execution machinery — host setup, transports, and the
data-transfer settings that govern how boundary values cross the wire all live in
[Remotes & Pools](remotes.md).

!!! note "Regions are new and evolving"
    Named regions and the DAG region map are a recent addition — the surface may still shift. The
    single-worker path (a whole notebook [placed on one host](remotes.md#run-a-notebook-on-a-remote))
    is the stable option when you want the entire notebook elsewhere.

## See also

- [Reactive Cells](reactivity.md) — the reactive model the graph drives, and the 🔗 upstream focus.
- [Remotes & Pools](remotes.md) — hosts, transports, warm pools, and the data-transfer settings
  regions rely on.
- [Cell Tags & Caching](cell-tags.md) — the `needs=`, `remote`, and `region=` tags in the header.
