# Memoization & Caching

KaimonSlate persists expensive cell results to a **durable, content-addressed store on disk**. When
you reopen a notebook — or its worker restarts — results **restore instead of recomputing**, so a
pipeline that takes minutes to build comes back instantly. It's automatic for expensive cells,
tunable per cell, and it invalidates *precisely* when a cell's real inputs change.

This is what makes a long-lived notebook feel warm: edit one cell and only its dependents recompute
(see [Reactive Cells](reactivity.md)); reopen tomorrow and nothing recomputes at all.

!!! note "Gate workers only"
    The durable store lives in the notebook's **gate worker**. A notebook running
    [in-process](hub.md#Kernel-selection) (no worker) has no durable cache — its results
    live only as long as the session.

## The durable store

The cache is a content-addressed store under your cache home (`$XDG_CACHE_HOME/kaimonslate/memo`,
falling back to `~/.cache/…`). It has two kinds of file:

- **Manifests** — one small TOML per cache key. A manifest records *which* globals a cell produced
  and, for each, a reference to its value blob. Manifests are `ls`-able and human-readable.
- **Blobs** — the actual value bytes, each named by the SHA-256 of its content. Because a blob is
  keyed by content, **identical values dedup to a single blob** — across cells, and even across
  notebooks. Re-keying an entry (e.g. after a `src/` edit) rewrites only the ~1 KB manifest; the data
  bytes are already there.

The store is **bounded**: an LRU cap (set `KAIMONSLATE_MEMO_CAP_GB`, else an adaptive fraction of
free disk) evicts the oldest entries first, and a blob is deleted only when no surviving manifest
references it. Persist the cap instead with `KaimonSlate.set_memo_cap_gb!(gb)`, which writes
`memo_cap_gb` to the config and restarts running workers so it takes effect immediately; pass `0` to
clear the override.

A [`locked`](cell-tags.md#Locking-a-result) cell's entry is **pinned** and never evicted, so pins can
hold the store above its cap. Everything else is subject to the LRU, including a `cache`-tagged
entry. A single value larger than the cap can never stay cached.

## What gets cached, and when

- **Automatically** — an error-free cell whose run takes more than a moment (about 150 ms of wall
  time, compilation included, so a cell's first run in a session often qualifies) is cached without you
  doing anything. Fast cells never pay the serialization cost.
- **`cache` tag** — opt **in** regardless of runtime. Persist a pipeline stage's result so it always
  restores instead of recomputing, even when the cell itself is quick. Ideal for a deterministic
  stage whose *inputs* rarely change.
- **`nocache` tag** — opt **out**, for impure or side-effecting cells (a network write, a file the
  cell appends to). A `nocache` cell is never memoized — and, correctly, it **poisons the cache keys of
  everything downstream**, because restoring a downstream result against a producer that must re-run
  would resurrect stale data.
- **`volatile` tag** — the same, for a cell whose result differs run to run (`rand()` without a seed,
  the current time). Slate doesn't detect this itself; a cell calling `rand` caches like any other
  unless you tag it.
- **`locked` tag** — freezes a result and always stores it, whatever its runtime.

Set these with the 🏷 tag editor or a `#%%` header token — see [Cell Tags](cell-tags.md#caching).

![The tag editor popover over a cell header, with the Caching & execution group offering cache, nocache, resource, locked and trace](./assets/tag-editor.png)

Never cached:

- markdown cells, and cells whose run errored;
- cells tagged `nocache` or `volatile`;
- [`resource`](cell-tags.md) cells (live DB/file/socket handles);
- cells that declare a `reactive` or carry [`@replay`](replay.md), since both create live session
  state by running;
- a `using` whose package exports Slate couldn't resolve yet (a resolved `using` cell caches, and its
  imports are replayed on restore);
- cells that run `eval` or `include` (they re-run each session; see below for the cells under them);
- cells holding a value that can't be stored: a live handle you haven't tagged `resource`, a value
  that won't serialize, or a function that can't be replayed (see below).

The cell's cache badge names the specific reason.

Three of these also keep the cells **below** them from being cached, because their value can differ
from one run to the next: `nocache`, `volatile`, and an `eval`/`include` cell or an unresolved `using`
that hasn't run yet. Once an `eval` or `include` cell has run, Slate knows what it binds and the cells
below cache normally, in later sessions too.

`@replay` in particular is excluded because restoring a memoized cell skips its body, which would
bring the figure back with no sweep registered.

### Cells that define functions

A cell can define helpers next to the slow work that uses them. Its cache entry stores the computed
values and leaves the definitions out: on restore they are evaluated again from the cell's source,
which is cheap, and cells below can call them as usual. This covers functions (plain, docstring'd or
`@inline`), structs and other types, macros, `const`s bound to a literal, a global bound to an
anonymous function (`g = x -> …` or `g = function (x) … end`), definitions inside a top-level `begin`,
a top-level `let` that only names literal or global values and defines functions, and
`g = let … end` whose value is such a function.

A cell still doesn't cache when one of its functions comes from somewhere a replay can't reach: a
`let` that computes something (`let k = rand()`), or a function returned from a computation. Its
cache badge says which function. Moving the definitions to their own cell, or the computation out of
the `let`, makes it cacheable. A cell that defines functions with an `@eval` loop isn't cached
either; it re-runs each session, which is usually cheap, and the cells below it still cache.

Values of a type the notebook defines restore like any other value.

## Cache keys — what invalidates a result

A cell's result restores only when **all** of its real inputs are unchanged. The key is a hash of:

- the cell's own source, and the source of **every cell upstream of it**;
- the current values of any named session state the cell reads — `@bind` controls and `reactive`
  values alike (moving a slider or pushing a new reactive value re-keys);
- the contents of any `@asset` files, or files read with `include("literal path")`, that it or an
  upstream cell references;
- the version (and git tree hash) of each package the notebook's environment adds directly. A
  change in a package only reached through another package's dependencies doesn't re-key;
- the **developed `src/`** of the project and of any path-developed package: every definition in it,
  by content. Editing any definition re-keys every cell, so nothing computed under the old code is
  restored; a change to comments or whitespace doesn't;
- the freeze stamp of any [`locked`](cell-tags.md#Locking-a-result) cell upstream, so refreshing a
  frozen value re-keys everything below it.

Toggling `trace` on a cell re-keys it too.

Change any of those and the cell recomputes; change nothing and it restores. Set
`KAIMONSLATE_MEMO_DEBUG=1` to log the source and package digests each key was built with.

!!! tip "Assert two values are really the same — `slate_fingerprint`"
    `slate_fingerprint(xs...)` returns a canonical content hash with `isequal` semantics
    (order-independent Dicts/Sets, `NaN ≡ NaN`, `missing ≠ nothing`). It's the robust way to check a
    restored / recomputed / transferred value is identical across runs, sessions, and workers.

## Restore on reopen or restart

On a cold open or a worker restart, before a cell runs its source, the worker looks for a manifest
matching the cell's key and, if every blob is present, **restores the values into the namespace — no
recompute**. Restored cells are surfaced as such (a "restored" state, logged as "restored (no
recompute)"). Provider cells (`using`/`import`), `@bind` cells, and theme setters restore and then
**replay** just their cheap side effects, so downstream cells see the right scope and theme.

The **▶ play** button on a cell forces a fresh recompute (skips restore and re-stores the result).

## Seeing what's cached

Two helpers, callable from a cell:

- **`slate_memo_stats()`** → `(; manifests, blobs, bytes, root)` — entry count, unique content blobs
  (the dedup shows here), total on-disk bytes, and the store root.
- **`slate_memo_entries(; name="")`** → a `Vector` of rows, newest first: `(; key, names, bytes,
  blobs, elided, created)` — the globals each entry restores and their (shared-when-deduped) content
  hashes. It lists the whole store, which notebooks share; `name="x"` filters to entries carrying a
  binding `x`.

And to answer **"why did this cell (not) restore?"**, there is an agent tool, called from an agent or
the MCP toolset rather than from cell code:

- **`slate_memo_trace(notebook; cell="")`** → what the cache *did* on each cell's latest eval:
  the action (**restored / stored / recomputed / unkeyed**), the full cache key with its source- and
  package-digest components (compare across hosts to spot a key drift), the per-binding blobs read or
  written, and the exact **miss reason** on a recompute (no manifest · blob missing · decode failed ·
  below threshold · …). Reads the live worker, so run a cell first.

## Display objects are elided

Makie/Plots figures are pathological to serialize — a huge scene graph, seconds of work — for a chart
whose rendered **pixels already ride the wire**. So when nothing downstream reads a display object,
KaimonSlate **elides** it: the manifest keeps only the rendered image, not the object. It self-heals
— if you later add a cell that *reads* the figure, the entry misses and re-stores the real object.
Elided names show up in `slate_memo_entries` (the `elided` column).

## Arrow tables and codecs

!!! note "Newer, still settling"
    The typed codecs below are a recent optimization. Behavior is accurate to the current code but may
    evolve; the universal fallback always applies, so correctness never depends on them.

A value becomes blob bytes through one of three **codecs**, chosen automatically by type:

| You return | Codec | On restore | External-readable |
| --- | --- | --- | --- |
| a **`DataFrame`** (with `DataFrames` **and** `Arrow` loaded) | Arrow IPC | memory-mapped off disk, zero-copy | **yes** — the blob is a valid Arrow file |
| a non-empty **isbits `Array`** (`Vector{Float64}`, `Matrix{Int}`, …) | raw | memory-mapped, zero-copy | no (internal format) |
| anything else | Julia `Serialization` (`jls`) | deserialized | no |

The `jls` fallback handles *any* Julia value, so caching always works; the typed codecs just make
large tabular/array data reopen and transfer far faster.

- **To get the fast path for a table, return a `DataFrame`.** An `Arrow.Table`, a `Vector` of
  `NamedTuple`s, or a `SlateTable` falls back to `jls` — only a `DataFrame` triggers the Arrow codec.
  It requires `using DataFrames, Arrow` in the notebook (both); without them a `DataFrame` still
  caches correctly, just as `jls`.
- **Zero-copy** restore (an mmap-backed view) is used only when the dependency graph proves nothing
  downstream **mutates** the value. If you then mutate a zero-copy-restored value you'll get an
  error (a `ReadOnlyMemoryError` for an array) rather than a silent change; re-running the producer
  re-stores it mutably.
- The Arrow blob is a plain Arrow IPC file on disk, so its bytes are readable by external tools
  (DuckDB, pyarrow). Note this is a property of the stored bytes — KaimonSlate doesn't currently
  surface the blob path for you.
- **These codecs also power [region boundary transfers](regions.md#How-boundary-values-cross)** — a
  `DataFrame` crosses between kernels as Arrow IPC, moved zero-copy over the data channel.

## Your cache follows you

When a notebook runs on a [remote worker](remotes.md), `slate_sync_memo` pushes the whole store to it
(dedup-aware) so the remote **restores** cached results instead of recomputing them. On attach, recent
entries are carried automatically when moving them beats recomputing. See
[Remotes → Your cache follows you](remotes.md#Your-cache-follows-you).

## See also

- [Cell Tags & Caching](cell-tags.md) — the `cache` / `nocache` / `resource` tags in the header.
- [Reactive Cells](reactivity.md) — the dependency graph that defines a cell's inputs (and its key).
- [Remotes](remotes.md) — carrying the cache to another machine.
