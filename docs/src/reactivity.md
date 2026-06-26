# Reactive Cells

KaimonSlate cells form a **dependency graph**, not a linear script. When something changes,
only the cells affected by it recompute — and they always recompute in dependency order.

## Reads, writes, and the DAG

For each code cell, the engine analyzes which variables it **reads** and which it **writes**.
A cell that reads `x` depends on whichever cell writes `x`. From these edges KaimonSlate
builds a directed acyclic graph and evaluates cells in topological order.

```julia
# cell A          # cell B (depends on A)      # cell C (depends on B)
x = 10            y = x + 1                     z = y^2
```

Editing **A** marks A, B, and C stale; running stale cells recomputes all three in order.
Editing **C** marks only C.

## Cell states

The left border and badge show each cell's state:

| State | Meaning |
| --- | --- |
| **fresh** (blue) | up to date |
| **stale** (gold) | an upstream dependency changed — needs recompute |
| **edited** (orange) | the source changed in the editor but hasn't been run |
| **running** (green) | currently evaluating |
| **errored** (red) | last run raised |

**▶ Run stale** recomputes every stale/edited cell. The button shows the count.

## Seeing dependencies

Click the **🔗** button on a code cell to highlight its **upstream cone** — every precursor
it (transitively) reads from is bordered gold with an "⬆ feeds <id>" badge, and the view
scrolls to the topmost precursor. Click a precursor to jump to it; press `Esc` or click 🔗
again to clear.

This is the navigation companion to reactivity: the engine already restales the *downstream*
cone on a change; the 🔗 view lets you trace *upstream* to find a cause.

![Dependency-chain focus: only the selected cell's precursors and dependents are shown](./assets/deps-cone.png)

## Widgets drive reactivity

A `@bind` control is just another writer. Changing `@bind n Slider(1:100)` restales every
cell that reads `n` and recomputes them — the same machinery as editing a cell. The defining
cell itself only re-runs if it *also* reads the control (e.g. `@bind d Slider(1:a)` reading
`a`). See [Widgets & @bind](widgets.md).

Drag the slider and the downstream chart recomputes and animates in place — live:

![Dragging a slider re-renders the dependent chart live](./assets/reactivity.webm)

## Async updates

A long-running cell can push results progressively. Calling `slate_refresh(:data)` from a
cell's async task restales the **readers** of `data` (not the producer), recomputes them, and
pushes a lightweight live update to the browser — so streaming/async workflows stay reactive
without re-triggering themselves.

## Why this matters

There is no hidden kernel state that silently goes stale. If a cell is blue, its output
reflects its inputs. If you change an input, the things that depend on it turn gold until they
catch up. This is the same guarantee that makes spreadsheets and Pluto trustworthy, applied to
a plain `.jl` file.
