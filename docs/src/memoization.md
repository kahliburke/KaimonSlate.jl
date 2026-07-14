# Memoization & Caching

KaimonSlate persists expensive cell results to a **durable, content-addressed store on disk**. When
you reopen a notebook — or its worker restarts — results **restore instead of recomputing**, so a
pipeline that takes minutes to build comes back instantly. It's automatic for expensive cells,
tunable per cell, and it invalidates *precisely* when a cell's real inputs change.

This is what makes a long-lived notebook feel warm: edit one cell and only its dependents recompute
(see [Reactive Cells](reactivity.md)); reopen tomorrow and nothing recomputes at all.

!!! note "Gate workers only"
    The durable store lives in the notebook's **gate worker**. A notebook running
    [in-process](configuration.md#kernel-selection) (no worker) has no durable cache — its results
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
references it.

## What gets cached, and when

- **Automatically** — an error-free cell whose run takes more than a moment (about 150 ms) is cached
  without you doing anything. Fast cells never pay the serialization cost.
- **`cache` tag** — opt **in** regardless of runtime. Persist a pipeline stage's result so it always
  restores instead of recomputing, even when the cell itself is quick. Ideal for a deterministic
  stage whose *inputs* rarely change.
- **`nocache` tag** — opt **out**, for impure or side-effecting cells (randomness, wall-clock, a
  network write). A `nocache` cell is never memoized — and, correctly, it **poisons the cache keys of
  everything downstream**, because restoring a downstream result against a producer that must re-run
  would resurrect stale data.

Set these with the 🏷 tag editor or a `#%%` header token — see [Cell Tags](cell-tags.md#caching).
Markdown cells, `using`/`import` barriers, notebook-local function definitions, and
[`resource`](cell-tags.md) cells (live DB/file/socket handles) are never cached.

## Cache keys — what invalidates a result

A cell's result restores only when **all** of its real inputs are unchanged. The key is a hash of:

- the cell's own source, and the source of **every cell upstream of it**;
- the current values of any `@bind` controls the cell reads (moving a slider re-keys);
- the contents of any `@asset` files it (or an upstream cell) references;
- the notebook's **package versions**;
- the **developed `src/`** of the project — so editing a function a cell calls invalidates the entry.

Change any of those and the cell recomputes; change nothing and it restores. Set
`KAIMONSLATE_MEMO_DEBUG=1` to log the key components.

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
  hashes. `slate_table(slate_memo_entries())` renders exactly what a cold open will restore;
  `name="x"` filters to entries carrying a binding `x`.

And to answer **"why did this cell (not) restore?"** directly:

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
  downstream **mutates** the value. If you then mutate a zero-copy-restored value you'll get a
  `ReadOnlyMemoryError` — a safe failure; re-running the producer re-stores it mutably.
- The Arrow blob is a plain Arrow IPC file on disk, so its bytes are readable by external tools
  (DuckDB, pyarrow). Note this is a property of the stored bytes — KaimonSlate doesn't currently
  surface the blob path for you.
- **These codecs also power [region boundary transfers](regions.md#how-boundary-values-cross)** — a
  `DataFrame` crosses between kernels as Arrow IPC, moved zero-copy over the data channel.

## Your cache follows you

When a notebook runs on a [remote worker](remotes.md), `slate_sync_memo` pushes the whole store to it
(dedup-aware) so the remote **restores** cached results instead of recomputing them. On attach, recent
entries are carried automatically when moving them beats recomputing. See
[Remotes → Your cache follows you](remotes.md#your-cache-follows-you).

## See also

- [Cell Tags & Caching](cell-tags.md) — the `cache` / `nocache` / `resource` tags in the header.
- [Reactive Cells](reactivity.md) — the dependency graph that defines a cell's inputs (and its key).
- [Remotes](remotes.md) — carrying the cache to another machine.
