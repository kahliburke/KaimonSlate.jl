# Cell tags & caching

Every cell carries a small set of **tags** in its `#%%` header. Tags change how a cell behaves,
how it renders, and what role it plays in a document. Set them with the **🏷** button in the cell
header (a small tag editor), or type a token directly into the header.

```julia
#%% code id=setup collapsed        ← a `collapsed` behaviour tag in the header
using LinearAlgebra, Statistics
```

![The 🏷 tag editor popover over a cell header, toggling behaviour and role tags](./assets/tag-editor.png)

## Caching and execution tags

| Tag | Effect |
| --- | --- |
| `cache` | Always persist the result, regardless of how long the cell took. See [Caching](#caching). |
| `nocache` | Opt **out** of durable memoization, for impure or side-effecting cells that must re-run. Also stops everything downstream from being restored. |
| `resource` | The cell opens a live external handle (a database connection, a file, a socket). It re-runs every time the notebook opens instead of restoring, and unlike `nocache` it leaves everything downstream cacheable. |
| `locked` | Freeze the result. The cell never re-runs from an upstream change or a reload, only from its ▶ button, and its cache entry is pinned so eviction cannot drop it. See [Locking a result](#Locking-a-result). |
| `volatile` | The cell's value changes on its own (wall-clock, a live feed). Like `nocache` it is never memoized and poisons downstream keys. |
| `trace` | Wrap the cell in `@trace` — collect every intermediate value into a trace table (also the cell's 🔍 button). See [Tracing](#tracing). |
| `everywhere` | Run this cell on every [region](regions.md) worker, not just the main one. For a cell that registers process-global state. |

If a cell returns a live handle without being tagged `resource`, the worker declines to cache it and
says so, naming the tag.

## Display tags

| Tag | Effect |
| --- | --- |
| `collapsed` | Fold the cell (hide it in the notebook; omitted from slide/report export). |
| `hidecode` | Hide the editor, show only the output — a clean result without the source. |

## Tags that take a value

| Tag | Effect |
| --- | --- |
| `needs=id1,id2` | Assert a dependency on earlier cells that dataflow analysis cannot see. The case this exists for is coupling through something other than a variable, such as a cell reading a table another cell created. Only earlier code cells can be named. |
| `mutates=name1,name2` | Assert that the cell modifies those values in place, when it does so through a function call or an alias that analysis cannot follow. |
| `region=<name>` | Run this cell on a named compute target. See [Regions](regions.md). |

`needs=` is also what the DAG view's link gesture writes, so you can draw the edge instead of typing
it.

Two more value tags, `lockedkey=` and `frozenat=`, are written by Slate itself to track a `locked`
cell. Leave them alone.

## Presentation tags

| Tag | Effect |
| --- | --- |
| `slide` | Force a new [slide](slides.md) at this cell, regardless of headings. |
| `notes` | Speaker notes — attached to the current slide, shown only in presenter/notes output. |

## Document-role tags

| Tag | Effect |
| --- | --- |
| `title` | This cell is the document [title block](documents.md#Front-matter). |
| `abstract` | This cell is the academic abstract. |
| `caption` | This markdown cell is the figure caption for the output above it. |
| `bibliography` | This cell is the [bibliography](documents.md#bibliography) (BibTeX or `.bib` paths). |

## Site tags

| Tag | Effect |
| --- | --- |
| `home` | This notebook is the published [site's front page](publishing.md#Front-page-and-document-listing). |
| `docindex` | Marks where the site's document listing is injected on a `home` notebook. |

## App tags

| Tag | Effect |
| --- | --- |
| `workbook` | In a [workbook](app-mode.md#Workbook-mode), this code cell stays editable and runnable for the reader. Everything untagged stays read-only. |

There is no checkbox for `workbook` in the tag editor. Type it into the header, or add it through
the editor's custom-tag input.

A token outside the set documented on this page is a **free-form tag** that round-trips in the `.jl`
header without doing anything, which is useful for your own grouping or tooling.

## Tracing

Tagging a cell `trace` (or clicking its 🔍 button) wraps it in `@trace`: each line's value is
collected into a **trace table** you can open and inspect, so you can see every intermediate
without scattering `@show`. You can also write `@trace begin … end` by hand around part of a cell.

## Caching

KaimonSlate durably **memoizes** cell results to disk: a cell that takes more than a moment (about
150 ms) is cached automatically, keyed by its source and inputs, and **restored** instead of
recomputed after a worker restart or when you reopen the notebook. Two tags tune it:

- **`cache`** — force a cell's result to persist regardless of runtime, for a deterministic pipeline
  stage whose inputs rarely change.
- **`nocache`** — opt out, for impure or side-effecting cells (randomness you want fresh, network
  calls) where a restored value would be wrong. It also stops everything downstream from being
  restored, since they depend on a value that must re-run.

!!! tip "Structure for the cache"
    Put an expensive computation (a simulation, a large read, a fit) in its **own** cell so its
    result is cached independently of the cheap cells that render it. The reactive engine already
    recomputes only what changed; the cache makes that survive restarts.

## Locking a result

Some results are not reproducible from the code that made them: a benchmark, a training run, sampled
data. `locked` freezes such a cell. It stops responding to upstream changes and to reopening the
notebook, and re-runs only when you press its ▶ button. Slate records the cell's cache key as of the
run it froze on and pins that entry, so the value survives both upstream drift and cache eviction.

Downstream cells key off the frozen identity rather than the cell's source, so two runs of identical
code that produced different values do not collide.

Do not lock a cell carrying [`@replay`](replay.md). Such a cell has no computed key to pin, so it
cannot be restored on reopen.

See **[Memoization & Caching](memoization.md)** for the full model — the content-addressed store,
cache keys, restore, display-object elision, and the Arrow/typed codecs.
