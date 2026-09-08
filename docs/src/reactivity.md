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

Cells that depend on each other run in order. Cells that do not run **at the same time**, which is on
by default. Document order is the safety backstop, so two cells writing the same name still run in
order. Turn it off per notebook under **☰ → ⚙ Settings → This notebook** if a cell's side effects need strict
document order.

!!! warning "One namespace, last writer wins"
    All cells share one namespace. If two code cells define the same name, the later one wins, and
    editing the earlier one looks like reactivity has stopped working. Slate flags this with a ⚠
    badge naming the variable on every cell that defines it; click it to see the others. Give each
    value one defining cell, or rename.

Source files are reactive inputs too: saving a file in the project the notebook runs against restales
the cells that use what you changed. See [Editing project source](hot-reload.md).

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

Click the **🔗** button on a code cell to filter the notebook down to that cell's **dependency
chain**: its transitive precursors, the cell itself, and its transitive dependents. Everything
outside the chain collapses out of the flow, the focused cell gets an outline, and a banner names the
cell and how many cells are in the chain. Click the banner, click 🔗 again, or press `Esc` to exit.

This is the navigation companion to reactivity. The engine restales the downstream cone on a change;
the 🔗 view puts both directions on screen at once so you can trace a value to its cause and see what
it feeds.

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
