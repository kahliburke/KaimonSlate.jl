// One model per worker, shared by every component that shows one.
//
// Before this, each component fetched its own copy and worked out for itself what the copy meant.
// Four of them decided "is a node held" from three different fields; seven decided "is this worker
// alive" from four different tests, two of which disagreed whenever `alive` was absent. The same
// worker could read as attached in the activity monitor and idle in the remotes roster, on the same
// page, at the same moment — not because the data was stale, but because there were several copies
// of it and several opinions about it.
//
// So: the hub answers those questions (`held`, `allocState`, `alive`, `state`, `status` — see
// `_worker_entry` in server_history.jl and `_region_alloc_facts` in server_complete.jl), this file
// holds the answer, and components render it. A component that finds itself computing one of these
// is reintroducing the bug.
//
// A CLASSIC script, deliberately, and first in the ordered list on both pages. It was briefly an ES
// module, which is deferred: a classic script that renders during load (`reload()` → `renderWorkers`)
// reached it before it existed. Classic-first is the one order that holds, because ES modules always
// run after classic scripts — so the module consumers can rely on `window.slateModel` at their own
// top level, while a module could never promise the same to them.
//
// Plain state plus `subscribe`, not signals, for the same reason: signals would need an import.
// Preact islands mirror it into a signal of their own (one line) to re-render.
//
// Keyed by SIDE, which is the worker's identity on a notebook page: '' is the main kernel, anything
// else is the region of that name. The home page has no notebook, so it keys its roster by host and
// port instead — `rosterKey`.
(function () {
  'use strict';

  // side -> worker record.
  let _workers = {};
  // region -> payload | null (asking) | undefined (never asked)
  let _allocations = {};
  const _subs = [];

  const subscribe = (fn) => { if (typeof fn === 'function') _subs.push(fn); return fn; };
  const _notify = () => { for (const f of _subs) { try { f(); } catch (_) {} } };

  const getWorkers = () => _workers;
  const getWorker = (side) => _workers[side || ''];
  const workerList = () => Object.values(_workers);

  // Replace the whole set. This is what `{t:'workers'}` and `/api/state` carry: a complete list, so a
  // worker that has gone must disappear rather than linger from the previous set.
  function applyWorkers(list) {
    if (!Array.isArray(list)) return;
    const next = {};
    for (const w of list) if (w && typeof w.side === 'string') next[w.side] = w;
    _workers = next;
    _notify();
  }

  // Everything `_region_alloc_facts` may contribute. Listed so a stale one can be cleared: these are
  // the fields whose ABSENCE is meaningful, and a leftover from an earlier frame reads as current.
  const ALLOC_KEYS = ['scheduler', 'held', 'allocState', 'walltimeLeft',
                      'idleRelease', 'idleWarn', 'idleFor'];

  // A telemetry frame: fresh stats, and the allocation clocks the hub recomputes on every sample.
  // MERGED rather than replacing, because a frame is about one worker and carries only what changed.
  //
  // `alloc` is the whole allocation answer or absent; when present it REPLACES the previous one
  // rather than merging into it, so a field that stops applying (the walltime of a node that just
  // went back) actually goes away instead of persisting from the last frame that had it.
  function applyTelemetry(side, stats, alloc) {
    side = side || '';
    const prev = _workers[side];
    if (!prev) return;                     // a worker we don't know yet; the next list push carries it
    const next = Object.assign({}, prev);
    if (stats !== undefined) next.stats = stats;
    if (alloc && typeof alloc === 'object') {
      for (const k of ALLOC_KEYS) delete next[k];
      Object.assign(next, alloc);
    }
    _workers = Object.assign({}, _workers, { [side]: next });
    _notify();
  }

  // ── the questions components used to answer for themselves ────────────────────────────────────
  // Each of these has exactly one definition now, and each is a plain read of what the hub said. They
  // take a record rather than a side so a caller holding a roster entry can use them too.

  // Does this worker's region hold a node, or a place in the queue? False for a worker with no
  // scheduler — `scheduler` absent means the question does not apply, which is NOT the same as no.
  const isHeld = (w) => !!(w && w.held);

  // Is an allocation possible here at all? Governs whether allocation UI appears, not what it says.
  const isScheduled = (w) => !!(w && w.scheduler && w.scheduler !== 'none');

  // 'running' (a granted node), 'pending' (queued for one), 'none', or '' when not applicable.
  const allocState = (w) => (w && w.scheduler ? (w.allocState || 'none') : '');

  // A queued request is withdrawn, a granted node is released. Same button, different promise.
  const releaseVerb = (w) => (allocState(w) === 'pending' ? 'Cancel' : 'Release');

  // Is the process there? `alive !== false` rather than `alive`, because a record that omits the
  // field is one the hub did not speak about, not one it declared dead — the two readings of this
  // were the bug where a worker showed green in one list and grey in another.
  const isAlive = (w) => !!w && w.alive !== false;

  // 'attached' (a live wire to this notebook), 'idle' (a process with no wire), 'dead' (a process
  // that has gone), 'none' (no process was ever started — a region with a pill but no worker yet).
  //
  // `dead` and `none` are both "not alive" and are NOT the same thing: one is a worker to clean up,
  // the other a region waiting to start one, and a row that conflates them offers Reap for something
  // that does not exist.
  function workerState(w) {
    if (!w) return 'none';
    if (isAlive(w)) return w.state || 'idle';
    return w.state === 'none' ? 'none' : 'dead';
  }

  // Graduated health for a pill: ok → degraded → connecting → disconnected. Six copies of this
  // expression existed, one of which checked `connected` first and so ranked a degraded worker as
  // healthy whenever its wire happened to be up.
  const workerStatus = (w) => (!w ? 'none' : (w.status || (w.connected ? 'ok' : 'connecting')));

  const SEVERITY = { disconnected: 4, degraded: 3, connecting: 2, none: 1, ok: 0 };
  const workerSeverity = (w) => (SEVERITY[workerStatus(w)] || 0);

  // ── what the SCHEDULER says (as opposed to what the hub believes) ─────────────────────────────
  // The worker record carries the hub's cached placement, which is free and current enough for a
  // pill. `/api/allocation` asks the cluster itself, which costs an ssh round trip and is the
  // reconciliation: the hub drops a placement the scheduler contradicts. Worth caching, and worth
  // caching in ONE place — the region panel and the remotes row were each keeping their own, so
  // releasing a node in one left the other showing it.
  const getAllocation = (name) => _allocations[name];

  function loadAllocation(name, force) {
    if (!name) return Promise.resolve(null);
    if (!force && _allocations[name] !== undefined) return Promise.resolve(_allocations[name]);
    _allocations = Object.assign({}, _allocations, { [name]: null });
    _notify();
    const set = (d) => {
      _allocations = Object.assign({}, _allocations, { [name]: d });
      _notify();
      return d;
    };
    return fetch('/api/allocation?region=' + encodeURIComponent(name))
      .then((r) => r.json()).then((d) => set(d || { ok: false }))
      .catch(() => set({ ok: false, error: 'unreachable' }));
  }

  // After anything that changes what is held. Re-asks rather than guessing the new answer, because
  // the scheduler is the authority and this is the call that reconciles the hub against it.
  const refreshAllocation = (name) => loadAllocation(name, true);

  // ── roster entries (home page) ────────────────────────────────────────────────────────────────
  // Workers discovered on a host rather than owned by a notebook. A different source, deliberately
  // the same vocabulary, so `isAlive`/`workerState` apply to both and a view merging them cannot end
  // up with one reading for the roster's copy and another for the hub's.
  const rosterKey = (host, port) => String(host) + ':' + String(port);

  // The hub's record wins where both exist: it knows whether the wire is live, and the on-host
  // sidecar only knows a process is running. Merging the other way is what made the monitor and the
  // roster disagree about the same worker.
  function mergeWorker(rosterEntry, hubEntry) {
    if (!hubEntry) return rosterEntry;
    if (!rosterEntry) return hubEntry;
    return Object.assign({}, rosterEntry, hubEntry);
  }

  const model = {
    subscribe,
    getWorkers, getWorker, workerList, applyWorkers, applyTelemetry,
    isHeld, isScheduled, allocState, releaseVerb,
    isAlive, workerState, workerStatus, workerSeverity,
    getAllocation, loadAllocation, refreshAllocation,
    rosterKey, mergeWorker,
    ALLOC_KEYS,
  };

  if (typeof window !== 'undefined') window.slateModel = model;
  if (typeof globalThis !== 'undefined') globalThis.slateModel = model;   // for the node tests
})();
