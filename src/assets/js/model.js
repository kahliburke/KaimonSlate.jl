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

  // side -> worker record, for THIS page's notebook: derived from the facts below, plus the latest
  // telemetry sample for each (which is a measurement, not a fact, and arrives on its own stream).
  let _workers = {};
  // region -> payload | null (asking) | undefined (never asked)
  let _allocations = {};
  const _subs = [];

  const subscribe = (fn) => { if (typeof fn === 'function') _subs.push(fn); return fn; };
  const _notify = () => { for (const f of _subs) { try { f(); } catch (_) {} } };

  const getWorkers = () => _workers;
  const getWorker = (side) => _workers[side || ''];
  const workerList = () => Object.values(_workers);

  // ── the hub's facts ───────────────────────────────────────────────────────────────────────────
  // The one description of the hub's state (server_facts.jl): `worker/<notebook>/<side>` and
  // `session/<host>`, kept current over one stream for the whole page. Everything below that shows a
  // worker or a session reads it, and nothing else holds a copy. Instants, not durations: `hubNow()` is
  // the hub's clock as this page reckons it, so a walltime or an idle stretch is measured here.
  let _facts = {};
  let _rev = -1;
  let _offset = 0;                       // hub seconds minus this machine's
  let _es = null;
  const hubNow = () => Date.now() / 1000 + _offset;
  const getFacts = () => _facts;

  // The notebook this page shows ('' on the home page): `/n/<id>` is the notebook route.
  let _pageNb = null;                   // set only by the node tests, which have no location
  const pageNotebook = () => {
    if (_pageNb !== null) return _pageNb;
    const m = typeof location !== 'undefined' && /^\/n\/([^/]+)/.exec(location.pathname);
    return m ? decodeURIComponent(m[1]) : '';
  };
  const _setPageNotebook = (nb) => { _pageNb = nb; _rebuildWorkers(); };

  // A worker fact as components read it: the fact, its latest sample, and its clocks.
  function _workerRecord(f) {
    const w = Object.assign({}, f);
    const smp = _samples['worker/' + f.nb + '/' + (f.side || '')];
    if (smp) w.stats = smp.stats;
    return w;
  }

  /** The workers of notebook `nb`, each as `_workerRecord`. */
  const workersOf = (nb) => Object.keys(_facts)
    .filter(k => k.startsWith('worker/' + nb + '/')).map(k => _workerRecord(_facts[k]));

  /** The region registry, by name. */
  const regions = () => Object.keys(_facts).filter(k => k.startsWith('region/')).map(k => _facts[k])
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  /** Parked region wires: a live connection kept for a notebook that was closed. */
  const parked = () => Object.keys(_facts).filter(k => k.startsWith('parked/')).map(k => _facts[k]);

  /** Every host there is something to sign in to; given `nb`, only the hosts that notebook uses. */
  const sessions = (nb) => Object.keys(_facts).filter(k => k.startsWith('session/')).map(k => _facts[k])
    .filter(s => !nb || (s.nbs || []).includes(nb)).sort((a, b) => a.host.localeCompare(b.host));
  const session = (host) => _facts['session/' + host];

  function _rebuildWorkers() {
    const nb = pageNotebook();
    const next = {};
    if (nb) for (const w of workersOf(nb)) next[w.side || ''] = w;
    _workers = next;
  }

  // The latest sample for each worker, by fact key, as `{stats, at}` (`at` in the hub's clock). A
  // measurement riding the facts stream, never merged into the facts.
  const _samples = {};
  const sampleOf = (key) => _samples[key];

  function _applySample(m) {
    _samples[m.key] = { stats: m.stats, at: m.at };
    const pre = 'worker/' + pageNotebook() + '/', side = m.key.startsWith(pre) ? m.key.slice(pre.length) : null;
    if (side !== null && _workers[side])
      _workers = Object.assign({}, _workers, { [side]: Object.assign({}, _workers[side], { stats: m.stats }) });
    _notify();
  }

  function _applyFrame(m) {
    if (m && m.t === 'sample') return _applySample(m);
    if (!m || m.t !== 'facts') return;
    if (typeof m.now === 'number') _offset = m.now - Date.now() / 1000;
    if (m.full) _facts = Object.assign({}, m.set || {});
    else if (m.rev !== _rev + 1) return _resync();     // a delta was missed: load the whole set
    else {
      const next = Object.assign({}, _facts);
      for (const k of Object.keys(m.set || {})) next[k] = m.set[k];
      for (const k of (m.del || [])) delete next[k];
      _facts = next;
    }
    _rev = m.rev;
    _rebuildWorkers();
    _notify();
  }

  function _resync() {
    return fetch('/api/facts').then(r => r.json()).then(_applyFrame).catch(() => {});
  }

  // One stream for the page. The hub sends the whole set when it opens (and again after a
  // reconnect), then each change. EventSource reconnects by itself.
  function connectFacts() {
    if (_es || typeof EventSource === 'undefined') return;
    _es = new EventSource('/api/facts/events');
    _es.onmessage = (e) => { try { _applyFrame(JSON.parse(e.data)); } catch (_) {} };
  }

  // A telemetry sample for one of this page's workers. Kept beside the facts, never in them.
  function applyTelemetry(side, stats) {
    side = side || '';
    _samples['worker/' + pageNotebook() + '/' + side] = { stats, at: hubNow() };
    if (!_workers[side]) return;
    _workers = Object.assign({}, _workers, { [side]: Object.assign({}, _workers[side], { stats }) });
    _notify();
  }

  // A worker fact in the shape a host roster lists a worker (`/api/remote-workers`): its manifest built
  // from the hub's record, so a view merging hub kernels with host rosters reads both the same way.
  function asRosterEntry(f) {
    const mf = { nbid: f.nb, notebook: f.notebookName || '', side: f.side || 'local', region: f.side || '',
                 transport: f.transport || '', project: f.env || '', port: String(f.port || ''),
                 stream_port: f.streamPort ? String(f.streamPort) : '', pid: f.pid ? String(f.pid) : '',
                 path: f.path || '' };
    const e = Object.assign({}, f, { host: f.host || 'local', region: f.side || '', manifest: JSON.stringify(mf) });
    if (f.viaHost) e.viaHost = f.viaHost;
    return e;
  }

  // ── clocks, from the instants the facts carry ─────────────────────────────────────────────────
  // Seconds of walltime left on a worker's allocation, or -1 when it has none.
  const walltimeLeft = (w) => (w && +w.until > 0) ? Math.max(0, +w.until - hubNow()) : -1;
  // Seconds since the region was last used, or -1 when it does not release on idle.
  const idleFor = (w) => (w && +w.lastUsed > 0) ? Math.max(0, hubNow() - +w.lastUsed) : -1;

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

  // Why a worker is not well, in words. The hub sends a code; the words are here, once, for every
  // place that shows a worker. `note` is free text for the one case that is commentary rather than
  // state: what a worker being started is doing.
  function workerNote(w) {
    if (!w) return '';
    switch (w.noteCode) {
      case 'allocation_ended':
        return 'the allocation on ' + (w.noteHost || 'the compute node') + ' ended — the next run requests a new node';
      case 'not_signed_in':
        return 'not signed in to ' + (w.noteHost || 'the host') + ' — use the padlock at the top of the page';
      case 'unresponsive':
        return 'worker stopped responding — press ▶ or re-run to reconnect';
      case 'busy_no_reply': {
        const el = Math.max(0, Math.round(hubNow() - (+w.busySince || 0)));
        return 'busy for ' + el + 's — every thread is occupied, so it is not answering requests; telemetry continues';
      }
      case 'no_reply': {
        // Counted here, from when it stopped answering: the hub says when, not for how long.
        const el = Math.max(0, Math.round(hubNow() - (+w.unresponsiveSince || 0)));
        return w.remote ? 'no liveness reply for ' + el + 's — auto-drops & reconnects at ' + (w.graceS || 0) + 's'
                        : 'no liveness reply for ' + el + 's — the worker may be wedged; interrupt it or reboot the worker';
      }
      default:
        return w.note || '';
    }
  }

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

  // ── what a region is ──────────────────────────────────────────────────────────────────────────
  // A machine is a region of its own name; a variant names the machine it narrows. Every picker
  // shows the two apart the same way.
  const regionKind = (r) => !r || !r.machine ? 'region' : r.machine === r.name ? 'machine' : 'variant';
  const regionIcon = (r) => regionKind(r) === 'machine' ? '🖥' : '🖧';
  const regionLabel = (r) => regionKind(r) === 'variant' ? r.name + ' · ' + r.machine : r.name;

  // ── what a telemetry sample says ──────────────────────────────────────────────────────────────
  // CPU against what the worker may use, memory against the limit that would stop it, and the GPUs,
  // as every display of a sample shows them. Memory follows the hub's own reading (`_memory_state` in
  // server.jl): the job's cgroup where there is one, else the host's total less what is available.
  // `null` where the sample cannot say.
  const coresText = (cpu) => cpu == null || cpu < 0 ? '—' : cpu >= 100 ? (cpu / 100).toFixed(1) + ' cores' : Math.round(cpu) + '% of a core';
  const sampleCores = (s) => (s && s.host && ((s.host.cores && s.host.cores.length) || s.host.ncpu)) || 0;
  function reading(s) {
    if (!s) return null;
    const job = s.job || {}, host = s.host || {};
    const hostCores = sampleCores(s);
    const allow = job.cpus > 0 ? job.cpus : hostCores;
    const cpu = s.cpu >= 0 ? s.cpu : null;
    const mem = job.mem_max > 0 && job.mem_cur >= 0 ? { used: job.mem_cur, limit: job.mem_max, of: 'job' }
      : host.mem_avail >= 0 && s.sys_mem_total > 0 ? { used: s.sys_mem_total - host.mem_avail, limit: s.sys_mem_total, of: 'host' }
      : null;
    const gpus = (s.gpus || []).map(g => ({ i: g.i, name: g.name,
      util: g.util >= 0 ? g.util : null, peak: g.util_max >= 0 ? g.util_max : null,
      memUsed: g.mem_used >= 0 ? g.mem_used : null, memTotal: g.mem_total > 0 ? g.mem_total : null,
      temp: g.temp >= 0 ? g.temp : null, power: g.power_w >= 0 ? g.power_w : null,
      powerLimit: g.power_limit_w > 0 ? g.power_limit_w : null }));
    const busy = gpus.filter(g => g.util != null);
    return {
      cpu, cpuText: coresText(cpu), hostCores, allow,
      cpuFrac: cpu == null ? null : allow ? cpu / 100 / allow : cpu / 100,
      hostCpu: s.sys_cpu >= 0 ? s.sys_cpu : null,
      rss: s.rss > 0 ? s.rss : null,
      mem, memFrac: mem ? mem.used / mem.limit : null,
      gpus, gpuAvg: busy.length ? busy.reduce((a, g) => a + g.util, 0) / busy.length : null,
    };
  }

  const model = {
    subscribe,
    reading, coresText, sampleCores,
    regionKind, regionIcon, regionLabel,
    getWorkers, getWorker, workerList, applyTelemetry,
    getFacts, workersOf, sessions, session, hubNow, connectFacts, pageNotebook,
    walltimeLeft, idleFor, asRosterEntry, sampleOf, regions, parked, refresh: _resync, _applyFrame, _setPageNotebook,
    isHeld, isScheduled, allocState, releaseVerb,
    isAlive, workerState, workerStatus, workerSeverity, workerNote,
    getAllocation, loadAllocation, refreshAllocation,
    rosterKey, mergeWorker,
  };

  if (typeof window !== 'undefined') {
    window.slateModel = model;
    // An app's reader is not shown workers or sessions, and the hub does not serve it the facts.
    if (!(window.__SLATE_APP__ && window.__SLATE_APP__.on)) connectFacts();
  }
  if (typeof globalThis !== 'undefined') globalThis.slateModel = model;   // for the node tests
})();
