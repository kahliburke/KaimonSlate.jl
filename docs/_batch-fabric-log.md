# The event log: making a sweep cost O(changes), not O(units)

Supersedes §6.3 of `_batch-fabric.md`. That section named the constraint correctly and the
implementation drifted from it. No migration: existing stores are deleted and re-run.

## What went wrong

§6.1 says a metadata storm is the thing the reporting design exists to avoid, and §6.3 specifies
one status file per chunk read by a single directory listing. Both were built. `write_status!` runs
on every chunk and `read_status` is called by nothing: `plan` opens one manifest **per unit** to
count what landed, and the poll pulls the whole `manifests/` tree to do it.

Measured on a 1,600-unit sweep mid-flight: 7,579 manifests and 31 MB per poll, against 571 status
files and 2.2 MB that already held the answer. The card's poll passed its 30 s deadline.

Raising the chunk size does not fix it. Chunk size is chosen to fit a walltime and a node, so the
file count follows the grid: a 10M-point grid is 10M files whatever the chunking.

## What the substrate allows

On NFS and Lustre the dependable primitives are narrow: `rename()` within a directory is atomic,
`O_CREAT|O_EXCL` is atomic, and `close()` is visible to a later `open()`. Appends are not atomic
across clients, and byte-range locks need a lock manager that is often absent.

So no embedded database is usable by concurrent writers here, and that is what those projects say
about themselves: SQLite's concurrency rests on POSIX advisory locks and its WAL needs shared
memory, LMDB requires local storage, DuckDB takes one writer per file. A server database the nodes
dial into is the callback model §6.2 already rejected, for the same reason.

Every store that survives this environment is built the same way: **writers only ever create new
immutable files**, so no two writers touch the same object and no locking is needed. TileDB calls
them fragments, Iceberg and Delta commit by atomic create, Zarr writes one file per chunk. Nextflow
and Snakemake solve our exact problem this way and put their database where there is one writer: on
the driver, not the shared filesystem.

Surveyed for something to adopt: no Julia package or JLL provides an NFS-safe multi-writer log.
`iceberg_rust_ffi_jll` exists but is a bare C ABI with no wrapper, and Iceberg's commit wants a
catalog service, which compute nodes cannot reach. The part nobody provides is the small part.

## Layout

    blobs/sha256/xx/<hash>          result values, content addressed
    manifests/<sweep>.toml          sweep descriptor
    manifests/<chunk>.toml          chunk descriptor
    events/<ts>-<jobid>-<chunk>     immutable, written once by rename
    jobs/                           hub-owned markers

Gone: `manifests/<shard>.toml`, one per unit, and `status/<chunk>.toml`.

**No global sequence.** A sequence number would need coordination between writers, which is the one
thing unavailable. It is not needed: each event names one chunk, events for different chunks
commute, and within a chunk the later timestamp wins. The reader's watermark is `find -newer`
against a stamp file on the store, so only the store's clock matters and node skew is irrelevant.

**An event carries the unit rows this job completed since its last event.** The fold is then a plain
union, with no special final event. A chunk emits one event per cadence tick plus one at the end, so
file count is O(chunks x ticks) and is bounded by time rather than by grid size. A retried chunk
re-emits rows for the units it re-ran and the later timestamp wins.

A row is the record that used to be the shard manifest: key, status, ms, `ran_on`, artifacts, the
inline value and its key order, the summary, and either `bindings` or `dataset` plus `shape`.

**Do not key the log by content hash.** A log needs order and content addressing destroys it: two
jobs reporting the same counts would hash alike and collapse. Lifetimes differ too, and that matters
more: the CAS evicts on an LRU cap and an unconsumed event must never be evicted.

## The fold

Everything the hub answers is a fold over the log: progress counts, per-chunk aggregates for the
grid, the failure list, the results table, the sweeps table. Hold it in memory per store, advance it
with the events that arrived since last time, so a poll costs O(new events). A restart replays,
which is O(chunks).

Per-unit state is never held in aggregate form: chunk aggregates are O(chunks) and failures are
bounded by the breaker. No relational index is needed; `slate_query` already serves ad-hoc queries
over parameters on demand.

The same reader folds the same events whether the store is a cluster's scratch or `cluster=here`,
which keeps one mental model rather than forking into files over there and a database over here.

## Resolutions

**Unit reuse moves to plan time.** `shard_key(sweep, param)` hashes the sweep key and the parameter
point; the chunk index is not in it, so the same body and point give the same key whatever the
chunking, and cross-run reuse is what the pilot-then-full-sweep pattern depends on. The hub folds
the store, knows which keys already have blobs, and omits those units when writing chunk
descriptors. A compute node never does a global lookup: it reads only its own chunk's events, and
only to resume a retry. `is_done` per unit leaves the task path. A stale fold re-runs a unit that
was already done, which costs compute and not correctness, and the blob dedups.

**GC roots move with the records.** `gc` refcounts blobs by parsing every surviving manifest. Move
rows into events and every result blob has a refcount of zero, so past the grace window they are all
deleted. The root scan reads `events/` as well, and gets cheaper doing it: O(chunks) rather than
O(units). Events are roots and are never evictable. This lands in the same change as the format.
Cell memoization is unaffected: it lives in a different root (`<cache>/memo`) with no `events/`.

**Deletion must reach the log.** `forget_results!` and reset drop a unit's manifest and blob, and a
status file that still counted it brought the deleted result straight back: a reset that reported
four done out of three. Events have the same hazard and cannot be edited in place, so releasing or
resetting a run deletes that run's events outright. That is the right meaning for reset, which is
"start this run over", and it keeps the log's only mutation a whole-run delete.

**Compaction is the hub's, opportunistically.** Write `snapshot-<ts>` by atomic rename, then delete
events older than it past a grace window, reusing the pattern the CAS already has. Snapshot first,
delete second, so snapshot plus surviving events is the complete state at every instant. A reader
takes the newest snapshot then events newer than it. Compute nodes never read another chunk's
events, so deletion cannot disturb a running job. Never required for correctness, only for directory
size.
