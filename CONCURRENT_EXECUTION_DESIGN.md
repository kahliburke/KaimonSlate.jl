# Slate Concurrent Execution — Design Proposal

Status: **proposal, for review.** Targets cross-cell parallelism (Phase 2), built on an async eval
spine (Step 1) that on its own fixes the two reported pains. Replaces the synchronous, 120 s-bounded,
lock-held eval model.

## Problems (one root cause)

A cell run is a **synchronous, 120 s-bounded gate request held under the notebook lock**:
`eval_stale! → eval_capture(GateKernel) → _tool("__slate_eval"; timeout=120.0)`, all inside
`lock(nb.lock)`. Therefore:
1. A cell running past 120 s hits `caller_timeout` and errors — **even though the worker keeps
   computing**.
2. The lock is held for the whole compute, so `add_cell`/`edit`/`delete` can't run — **you can't
   touch the notebook while a cell runs**.
3. Only one cell runs at a time and the server blocks on it — **no parallelism, no responsiveness**.

## Hard constraint that shapes the design

**Output capture is process-global.** `run_capture` uses `redirect_stdout`/`redirect_stderr` + the
display stack — per *process*, not per task. Two cells cannot capture concurrently in one worker
without clobbering each other. So **parallel cells ⇒ multiple worker processes**, each with its own
namespace — which makes parallelism a **namespace-coherence** problem (a global defined in worker A
must reach a dependent that runs in worker B).

---

## Architecture

### 1. Async, streamed eval (the spine — Step 1)

`__slate_eval` becomes **fire-and-forget**:
- Worker accepts the eval, returns `{started, run_id}` immediately, runs it on a task, and **PUBs the
  result** on the gate stream when done — reusing the bus that already carries
  `slate_progress`/`slate_revise`:
  ```
  slate_celldone : { run_id, cell_id, src_hash, wire }
  ```
- The server's existing poller routes `slate_celldone` → merges `wire` into the cell → broadcasts
  `celldone:` to the browser. The run pill/progress already stream, so "running" UX is unchanged for
  the whole (now unbounded) duration.
- **The lock is held only for the brief dispatch and the brief merge — never the compute.** Between,
  the notebook is free for add/edit/delete.

This removes the 120 s wall, makes the UI non-blocking, and is the foundation everything else sits on.
Pool size 1 ⇒ async-serial: correct, simple, ships first.

### 2. Server eval queue + dataflow scheduler

A per-notebook **eval queue**, scheduled over the dependency DAG we already maintain
(`cell.deps` / `dependents_of` / `cell.writes`):

- **Ready set** = stale cells whose every dependency is FRESH (or just completed) **and** whose
  write-set is disjoint from every in-flight run's write-set.
- Dispatch up to **N** ready cells to free workers concurrently; as each finishes, recompute the ready
  set (newly-unblocked dependents become ready). Standard topological-level dataflow.
- The queue is **manipulable while it drains**: adding/editing cells enqueues/re-stales without
  blocking the running ones.
- UI states per cell: `queued` · `running` · `done`/`errored` (the run pill already has the hooks).

### 3. Worker pool + namespace coherence

- `GateKernel` manages a **pool of N worker processes** (each booted exactly as today, own namespace).
  `pool_size` is configurable per notebook; **default 1** (serial) until parallelism is proven.
- **Broadcast-on-complete.** When a cell finishes in worker A, serialize its defined globals
  (`cell.writes`) and inject them into the other workers — **reusing the memoization serializer we
  already built** (`_memo_store`/`_memo_restore`: `Serialization` + `Core.eval` into a namespace).
- **Big-value handling.** Broadcasting a 2 GB array to N workers is wasteful. So:
  - Broadcast only globals whose serialized size is under a threshold;
  - **Co-locate** dependents of a heavy producer on the *same* worker (no broadcast needed);
  - Over-threshold values stay put and pin their consumers. Small scalars/configs replicate freely.

### 4. Version-guarded merge (correctness)

Every dispatched run is tagged `(cell_id, src_hash, run#)`. On `slate_celldone`:
- accept only if the cell still exists **and** its `src_hash` matches the tag — else **discard**
  (the cell was edited/deleted mid-run; it's been or will be re-dispatched);
- editing/deleting a running cell **supersedes** its in-flight run (bump run#; old result discarded;
  optionally cancel it worker-side).

### 5. Cancellation

A "stop" on a running cell sends `cancel_eval` (cooperative, via `Gate.is_cancelled()` checked in the
eval loop) — replacing today's only halt, "restart the worker." A superseded run is cancelled the same
way.

### 6. Safety / eligibility (what may run in parallel)

Only cells we can treat as **pure-ish** parallelize: disjoint write-sets, not `:opaque` (import
barrier), not `:nocache`/side-effecting. Anything else runs on **worker 0** (the serial lane), in
order. This reuses the memoization eligibility test. The cell-tags system gives the opt-out knob
(e.g. a `serial` tag forces the serial lane).

**Determinism caveats** (documented, not silently handled): unseeded `rand`, `time()`, file/network
I/O, and any hidden shared state make parallel order observable; such cells should be `serial`/
`nocache`. Duplicate-definition "last-writer-wins" is ill-defined under parallelism — the
disjoint-writes requirement already forbids two in-flight cells writing the same name.

---

## Contracts to lock before building

- **`slate_celldone` wire:** `{run_id::String, cell_id::String, src_hash::UInt64, wire::<run_capture form>}`.
- **Broadcast message (worker→worker via server):** `{from_run_id, names::Vector{String}, blob}` where
  `blob = Serialization` of `Dict(name=>value)` for the cell's `writes`; injected via `Core.eval`.
- **Scheduler invariants:** never dispatch a cell whose write-set intersects an in-flight write-set;
  never dispatch before all deps are done **and** their writes are visible in the target worker;
  a cell edited while queued/running is superseded, not duplicated.
- **Queue states + transitions** surfaced to the UI: `stale → queued → running → {fresh|errored}`,
  plus `superseded` (silently re-queued).
- **Pool lifecycle:** a worker dying mid-run → respawn + requeue its run; broadcasts to a dead worker
  are dropped and replayed on respawn (or the worker re-derives by re-running its lane).

## Failure modes

- Result arrives for a deleted/edited cell → discarded (src_hash mismatch).
- Worker death mid-run → run requeued on another worker; namespace rebuilt by replaying its lane (or
  from durable memo cache — they compose).
- Broadcast of a huge value → refused by threshold; consumers co-located instead.
- CPU oversubscription: `pool_size × threads_per_worker` must respect core count — set worker
  `--threads` / `OPENBLAS_NUM_THREADS` from `pool_size` (intra-cell threading and the pool share cores).

---

## Build steps (incremental, each shippable)

1. **Async spine (pool=1).** Fire-and-forget `__slate_eval` + `slate_celldone` stream + poller merge +
   lock-release + version-guarded merge + cancellation + the server queue (serial). **Fixes the 120 s
   timeout and add-while-running on its own.** Also: give the worker threads so a heavy cell
   parallelizes *internally* today.
2. **Worker pool + dataflow scheduler.** N processes, ready-set scheduling, broadcast-on-complete via
   the memo serializer, eligibility gating. **Delivers cross-cell parallelism.**
3. **Big-value co-location.** Size-thresholded broadcast + consumer pinning, so heavy producers don't
   replicate their output.

## Open questions

A. **Default `pool_size`** — 1 (opt in to parallel) or a small N like `min(4, ncores÷2)` by default?
B. **Broadcast size threshold** — what bytes count as "too big to replicate" (co-locate instead)?
C. **Thread budget** — split cores between pool width and intra-cell threads how (a cell that itself
   uses `@threads` inside a pool of 4)?
D. **UI** — how to show `queued` vs `running` vs the dependency wait, and a per-cell stop button.
E. **Eligibility opt-in/out** — auto-detect (disjoint writes + not opaque/nocache) only, or also an
   explicit `serial` / `parallel` cell tag?
