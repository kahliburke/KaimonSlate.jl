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
- **🖧 region map** — color cells by *where they run* (see [Regions](#regions-run-cells-on-another-kernel)).

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
host) while the rest stay local. The DAG pane is where you **see and steer** that split; the region
model itself — defining regions, declaring destinations, how boundary values cross — is in
**[Regions](regions.md)**.

## Steering regions from the DAG

Turn on the **🖧 region map** and the graph reorganizes into **side-by-side zones** — `💻 local` and
one per region — with each node tinted by where it runs and the cross-zone edges drawn as the
boundary hand-offs (labeled by transport: *direct* / *ssh-bridge* / *relay*). **Drag a node between
zones** to reassign it. A node wears a **🖧** badge when its last run executed on a region kernel,
and the legend along the bottom names the hosts and hosts the region toolbar.

![The DAG pane with the region map on: cells laid out in side-by-side zones (local · main kernel, db · db-box, gpu · gpu-box), each node tinted by where it runs, with the region hand-off edges labeled by transport (direct / relay)](./assets/dag-region-map.png)

**Click any node** for its detail card. For a cell whose last run was remote it shows the
**provenance**: a *last ran* `🖧 host` chip, a *moved* `⇄ N MB` chip for the inputs that had to
cross the boundary, a per-transfer breakdown (size · route · throughput), and a **Run on** picker to
reassign the cell to a different kernel in place.

![A DAG node's detail card for a remote cell: timing chips, a "last ran 🖧 gpu (gpu-box)" chip, a "moved ⇄ 220 MB total" chip, a region-transfers breakdown (size · direct · MB/s), the region= tag, and a "Run on" picker set to gpu · gpu-box](./assets/dag-node-card.png)

Each region **zone header** carries a live status dot — hover it for the region's worker card:
connection status, host, transport, and CPU / RSS / running-cell telemetry, with **🪵 Log** and
**✕ Reap** actions.

![A region's worker hover card in the DAG: status OK, host gpu-box, port, transport tunnel, cpu/rss/running/memo chips, and Log / Reap buttons](./assets/region-hover-card.png)

### The region toolbar

The region-map legend hosts three tools for the cross-region plumbing.

**⇄ peer routing plan** — how each region pair is wired: a resolved **direct** or **ssh-bridge**
route worker-to-worker, or a **relay** through the hub, with per-host grants and host-key pins.
**↻ recalculate** probes every pair live so throughput and route are measured *now* rather than on
the next real transfer.

![The peer routing plan panel: resolved routes between regions (gpu ← db direct, db ← gpu ssh-bridge, db ← local relay) with addresses and ages, and per-host grants and pinned addresses under MESH](./assets/dag-peer-plan.png)

![The peer routing plan mid-recalculate: a "testing gpu → db (1/3)…" progress line above the route list as each pair is probed](./assets/dag-peer-plan-probing.png)

**📊 transfers** — a dashboard of every boundary move: total moved, throughput over time, a
region-to-region grid, and the rate distribution — to see where the data actually flows and how fast.

![The transfer summary dashboard: stat tiles (total moved, transfer count, average and peak MB/s), a throughput-over-time chart, a region peer-to-peer heatmap, and a rate-distribution curve](./assets/dag-transfers.png)

**⇄ connect** — the first time two regions on different hosts need a direct worker-to-worker link,
Slate asks before exchanging keys (decline and transfers still work — they just relay through the
hub). The dialog spells out exactly what it installs — an on-host **ed25519 key**, a locked-down
**single-port grant**, a **host-key pin** — then arms the bridge with live progress.

![The connect-regions consent dialog listing the region pair and hosts, what it installs (ed25519 key, single-port grant, host-key pin), and Not now / Connect & exchange keys buttons](./assets/mesh-consent.png)

![The same dialog mid-connect: an "exchanging keys · gpu → db (1/2)" progress line and a disabled "Connecting…" button](./assets/mesh-connecting.png)

While a value crosses the boundary, the **consuming cell** shows a live progress bar
(`⇄ <name>: N/M MB ← host`) — driven on its own data channel, so a big move never looks like a hang.

![A running cell with a boundary-transfer progress bar reading "⇄ feat: 79/210 MB ← 🖧 gpu-box · 38%" above the cell](./assets/cell-transfer-progress.png)

## See also

- [Reactive Cells](reactivity.md) — the reactive model the graph drives, and the 🔗 upstream focus.
- [Regions](regions.md) — running part of a notebook on a second kernel, steered from the DAG.
- [Remotes & Pools](remotes.md) — hosts, transports, and warm pools.
- [Cell Tags & Caching](cell-tags.md) — the `needs=` and `region=` tags in the header.
