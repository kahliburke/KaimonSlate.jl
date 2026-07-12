# Cell tags & caching

Every cell carries a small set of **tags** in its `#%%` header. Tags change how a cell behaves,
how it renders, and what role it plays in a document. Set them with the **🏷** button in the cell
header (a small tag editor), or type a token directly into the header.

```julia
#%% code id=setup collapsed        ← a `collapsed` behaviour tag in the header
using LinearAlgebra, Statistics
```

![The 🏷 tag editor popover over a cell header, toggling behaviour and role tags](./assets/tag-editor.png)

## Behaviour tags

| Tag | Effect |
| --- | --- |
| `collapsed` | Fold the cell (hide it in the notebook; omitted from slide/report export). |
| `hidecode` | Hide the editor, show only the output — a clean result without the source. |
| `trace` | Wrap the cell in `@trace` — collect every intermediate value into a trace table (also the cell's 🔍 button). See [Tracing](#tracing). |
| `nocache` | Opt **out** of durable memoization — for impure / side-effecting cells that must re-run. See [Caching](#caching). |

## Presentation tags

| Tag | Effect |
| --- | --- |
| `slide` | Force a new [slide](slides.md) at this cell, regardless of headings. |
| `notes` | Speaker notes — attached to the current slide, shown only in presenter/notes output. |

## Document-role tags

| Tag | Effect |
| --- | --- |
| `title` | This cell is the document [title block](documents.md#front-matter). |
| `abstract` | This cell is the academic abstract. |
| `bibliography` | This cell is the [bibliography](documents.md#bibliography) (BibTeX or `.bib` paths). |

## Site tags

| Tag | Effect |
| --- | --- |
| `home` | This notebook is the published [site's front page](publishing.md#front-page-and-document-listing). |
| `docindex` | Marks where the site's document listing is injected on a `home` notebook. |

Any other token is a **free-form tag** that simply round-trips in the `.jl` header — useful for
your own grouping or tooling.

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

See **[Memoization & Caching](memoization.md)** for the full model — the content-addressed store,
cache keys, restore, display-object elision, and the Arrow/typed codecs.
