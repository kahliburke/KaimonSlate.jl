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

## Regions — run cells on another kernel

When a notebook is split into **regions**, some cells run on a second kernel (usually on another
host) while the rest stay local. The DAG pane is how you *see and steer* that split:

- it lays out **side-by-side zones** — `💻 local` and one per region — and you **drag a cell into a
  zone** to run it there;
- the **🖧 region map** toggle colors each node by where it runs (a legend names the hosts), and a
  node wears a **🖧** badge when its last run executed on a region kernel.

![The DAG pane with the region map on: cells laid out in side-by-side zones (local · main kernel, db · db-box, gpu · gpu-box), each node tinted by where it runs, with the region hand-off edges labeled by transport (direct / relay)](./assets/dag-region-map.png)

The full story — assigning cells, declaring destinations, how boundary values cross, and the
provenance chips — is in **[Regions](regions.md)**.

## See also

- [Reactive Cells](reactivity.md) — the reactive model the graph drives, and the 🔗 upstream focus.
- [Regions](regions.md) — running part of a notebook on a second kernel, steered from the DAG.
- [Remotes & Pools](remotes.md) — hosts, transports, and warm pools.
- [Cell Tags & Caching](cell-tags.md) — the `needs=` and `region=` tags in the header.
