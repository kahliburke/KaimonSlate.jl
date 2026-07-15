// ── Pipeline DAG pane — the notebook's dataflow graph, live ──────────────────
// Hamilton/dbt-style lineage view docked as a split pane: nodes are compact cards
// (type-tinted, id + duration chip + defined names INSIDE a small-radius rounded
// rect), edges follow dagre's ROUTED spline waypoints (around nodes, border to
// border) in their own violet hue family. State lives on card borders; a running
// cell BREATHES (smooth sinusoidal glow, not a blink) and its outgoing edges
// brighten, so a recompute visibly sweeps its subgraph. 🔥 heat mode recolors
// fills by accumulated compute cost with ×evals/↓pulls overlays (server stats).
//
// Rendered as ECharts CUSTOM series over invisible value axes (the `graph` series
// can't take edge waypoints and its roundRect corner radius scales into a pill).
// Pan/zoom = inside dataZoom on both axes (same wheel factor → aspect preserved);
// blocks scale with zoom (api.size) and their text degrades gracefully when small.
// The dagre layout is memoized (key: nodes+dims+links+dir+canvas) so the breathing
// animation loop re-paints without re-laying-out.
let _dagChart = null, _dagRaf = 0, _dagAnim = 0;
let _dagAnyRunning = false, _dagSel = null, _dagCtx = null;   // _dagCtx: {m, L, P} of the last render (click/tooltip)
let _dagHoverId = null, _dagHoverIdx = null, _dagEdgeV = 0;   // hover lineage: node id → highlighted edge indices
let _dagDrag = null, _dagGhost = null, _dagZoneHi = null, _dagSuppressClick = false;   // node drag → partition retag
const _dagRunning = new Set();          // ids running RIGHT NOW (cellrun → celldone)

const _dagOpen = () => document.getElementById('dagpane').classList.contains('open');
const _dagCardEl = () => document.getElementById('dagcard');

function _dagPalette() {
  const cs = getComputedStyle(document.documentElement);
  const v = (n, fb) => (cs.getPropertyValue(n) || '').trim() || fb;
  return {
    fresh: v('--accent', '#569cd6'), stale: v('--gold', '#d7ba7d'),
    errored: v('--red', '#f14c4c'), run: v('--green', '#3fb950'),
    dim: v('--dim', '#8a8f98'), text: v('--text', '#d4d4d4'),
    border: v('--border', '#333'), bg: v('--bg2', '#1b1f27'), bg3: v('--bg3', '#242a38'),
    edge: '#7d6f9e', edgeHot: '#b39ddb',              // muted violet, distinct from every card/border hue
  };
}
// blue = fresh · green = executing · gold = stale/edited (unsure) · red = errored
const _dagColor = (P, s) => s === 'running' ? P.run : s === 'fresh' ? P.fresh
                          : s === 'errored' ? P.errored : P.stale;

// ── Output-type classification → card tint + glyph ───────────────────────────
// What KIND of thing does this cell produce? Classified from what the browser already
// has (charts/tables/binds ride the cell payload; files/images/data-frames are sniffed
// from the rendered output). Exact value types (DataFrame vs path vs Figure) will come
// from the worker with a later pass; this heuristic covers the common shapes now.
// Wedge hues at FULL saturation — the corner marker is the sole type signal, so it can be vivid.
const _DAG_KINDS = {
  setup:   { hue: '#9ba3ad', icon: '📦' },   // using/import cells (deliberately neutral)
  control: { hue: '#00b4ff', icon: '🎛' },   // @bind widgets
  prose:   { hue: '#8a93a2', icon: '¶' },    // markdown that reads variables
  table:   { hue: '#00c9a7', icon: '🗃' },   // tables / data frames
  chart:   { hue: '#d066e2', icon: '📈' },   // echarts / animations
  image:   { hue: '#d066e2', icon: '🖼' },   // rendered figures (Makie et al.)
  file:    { hue: '#ff8f3d', icon: '📄' },   // path-valued results (downloads, exports)
  value:   { hue: '#3fa0ff', icon: '' },     // plain variables
};
function _dagKind(c) {
  if (c.binds && c.binds.length) return 'control';
  if (c.kind === 'md') return 'prose';
  if (/^\s*(using|import)\b/m.test(c.source || '')) return 'setup';
  if ((c.echarts && c.echarts.length) || (c.animations && c.animations.length)) return 'chart';
  if (c.tables && c.tables.length) return 'table';
  // sniff the rendered output as TEXT — it arrives HTML-escaped (&quot; not ")
  const out = (c.output || '').replace(/&quot;|&#34;/g, '"').replace(/<[^>]*>/g, '');
  if ((c.output || '').includes('<img')) return 'image';
  if (/DataFrame|GroupedDataFrame/.test(out)) return 'table';
  if (/^"[^"\n]*\/[^"\n]*"$/.test(out.trim())) return 'file';   // the WHOLE value is one quoted path
  return 'value';
}
// Blend two hex colors (solid result — translucent fills would wash the borders).
function _dagMix(a, b, t) {
  const pa = /^#?(..)(..)(..)/.exec(a), pb = /^#?(..)(..)(..)/.exec(b);
  if (!pa || !pb) return a;
  const c = i => Math.round(parseInt(pa[i], 16) * (1 - t) + parseInt(pb[i], 16) * t).toString(16).padStart(2, '0');
  return '#' + c(1) + c(2) + c(3);
}
// Cold→hot ramp for 🔥 heat mode (t ∈ [0,1]): green (cheap) → gold → orange → red.
function _dagRamp(t) {
  const stops = ['#2c4a33', '#7a6a2c', '#a85a28', '#c93a30'];
  const x = Math.max(0, Math.min(1, t)) * (stops.length - 1);
  const i = Math.min(stops.length - 2, Math.floor(x));
  return _dagMix(stops[i], stops[i + 1], x - i);
}
const _dagFmtMs = x => x >= 1000 ? (x / 1000).toFixed(1) + ' s' : Math.round(x) + ' ms';
function _dagAgo(ts) {
  if (!ts) return '';
  const s = Math.max(0, Date.now() / 1000 - ts);
  return s < 60 ? Math.floor(s) + 's ago' : s < 3600 ? Math.floor(s / 60) + 'm ago' : Math.floor(s / 3600) + 'h ago';
}

// The graph model: which cells are nodes and the edges between them. Nodes = every
// code cell, plus any cell touching an edge (md cells that read variables join in;
// pure-prose md stays out of the graph).
function _dagModel(cells) {
  const byId = {}; cells.forEach(c => { byId[c.id] = c; });
  const docIdx = {}; cells.forEach((c, i) => { docIdx[c.id] = i; });   // document order = topo order
  const touched = new Set();
  cells.forEach(c => (c.deps || []).forEach(d => { if (byId[d]) { touched.add(c.id); touched.add(d); } }));
  let nodes = cells.filter(c => c.kind === 'code' || touched.has(c.id));
  // Setup cells (using/import) are edge HUBS — nearly every cell depends on them, and those
  // edges aren't lineage: they'd blow one giant rank wide open (and even drawn faint, they
  // stretch the fit window). HIDDEN by default; the 📦 toggle brings them back as an aside
  // column with whisper edges, excluded from layout either way.
  const setup = new Set(nodes.filter(c => _dagKind(c) === 'setup').map(c => c.id));
  if (!_dagSetupOn) nodes = nodes.filter(c => !setup.has(c.id));
  const inc = new Set(nodes.map(c => c.id));
  const deps = id => ((byId[id].deps || []).filter(d => inc.has(d) && !setup.has(d)));

  // Longest-path layering for the no-dagre fallback (memoized DFS; the reactive
  // engine rejects cycles, but guard anyway so a pathological state can't hang the tab).
  const layer = {}, visiting = new Set();
  const L = id => {
    if (layer[id] != null) return layer[id];
    if (visiting.has(id)) return (layer[id] = 0);
    visiting.add(id);
    const ds = deps(id);
    const l = ds.length ? 1 + Math.max(...ds.map(L)) : 0;
    visiting.delete(id);
    return (layer[id] = l);
  };
  nodes.forEach(c => L(c.id));
  const layers = [];
  nodes.forEach(c => { (layers[layer[c.id]] ||= []).push(c.id); });
  const slot = {};
  layers.forEach((ids, li) => {
    if (li > 0) {
      const bary = id => {
        const ds = deps(id).map(d => slot[d]).filter(s => s != null);
        return ds.length ? ds.reduce((a, b) => a + b, 0) / ds.length : 1e9;   // no upstream → keep doc order (sort is stable)
      };
      ids.sort((a, b) => bary(a) - bary(b));
    }
    ids.forEach((id, i) => { slot[id] = i; });
  });

  // Opaque cells (parse error / barrier expressions) carry FABRICATED barrier deps — every
  // prior cell + every later cell. Those aren't dataflow: draw them as whispers, never as
  // routed edges, or one typo turns the whole graph into a hub-and-spoke tangle.
  const opaque = new Set(nodes.filter(c => c.opaque).map(c => c.id));
  const links = [];
  nodes.forEach(c => (byId[c.id].deps || []).forEach(d => {
    if (!inc.has(d)) return;
    links.push({ source: d, target: c.id,
                 manual: (byId[c.id].needs || []).includes(d),                // user-asserted (`needs=` tag) → dashed
                 dim: setup.has(d) || opaque.has(d) || opaque.has(c.id) });   // dim: faint, ignored by layout
  }));
  if (!_dagIsoOn) {
    // isolated cells (no edges at all once setup is filtered — e.g. a theme cell) hide too;
    // a dropped node had no links, so the link list stays valid
    const t2 = new Set();
    links.forEach(l => { t2.add(l.source); t2.add(l.target); });
    nodes = nodes.filter(c => t2.has(c.id));
  }
  return { nodes, links, layer, slot, layers, byId, setup, docIdx };
}

// Block metrics — one source of truth for layout (dagre needs each node's box) and
// paint (drawn size must match or blocks overlap).
// ECharts snapshots for chart-kind nodes/cards: the interactive instances already live in
// the notebook DOM (window.charts, cell id → [instances]), so a thumbnail is one cheap
// canvas read — cached per cell, invalidated when the cell re-runs or live-patches.
const _dagEcThumbs = {};
function _dagEcThumb(id, big) {
  const e = _dagEcThumbs[id];
  if (e) return big ? e.big : e.small;
  const inst = window.charts && window.charts[id] && window.charts[id][0];
  if (!inst || !inst.getDataURL) return null;
  const grab = () => ({ small: inst.getDataURL({ pixelRatio: 0.5, backgroundColor: 'transparent' }),
                        big: inst.getDataURL({ pixelRatio: 1.25, backgroundColor: 'transparent' }) });
  try {
    _dagEcThumbs[id] = grab();          // immediate — correct for an already-idle chart
    // Mid-animation case: 'finished' fires when rendering (incl. animations/progressive)
    // truly completes — re-grab there. One-shot: it fires on every future render too.
    const once = () => {
      inst.off('finished', once);
      try {
        if (!(inst.isDisposed && inst.isDisposed())) { _dagEcThumbs[id] = grab(); _dagQueue(); }
      } catch (_) {}
    };
    inst.on('finished', once);
    return big ? _dagEcThumbs[id].big : _dagEcThumbs[id].small;
  } catch (_) { return null; }
}

const _DAG_THUMB_H = 58;   // design height of the image-preview band inside a node
function _dagBlock(c) {
  // A defines row that just repeats the cell id is noise (the overwhelmingly common
  // `flights = …` in a cell named flights) — show only the OTHER names it defines.
  const defs = (c.defs || []).filter(n => n !== c.id).join(', ');
  let d2 = defs.length > 26 ? defs.slice(0, 24) + '…' : defs;
  const kind = _dagKind(c);
  // Kind-specific previews: a file's basename / a table's dimensions say more than defs;
  // figures embed a real thumbnail band (their PNG is already a data URI in the output).
  let thumb = null;
  if (kind === 'file') {
    const t = (c.output || '').replace(/&quot;|&#34;/g, '"').replace(/<[^>]*>/g, '');
    const m2 = /"([^"\n]+)"/.exec(t);
    if (m2) {
      const base = m2[1].split('/').pop() || '';
      d2 = '…/' + (base.length > 24 ? '…' + base.slice(-22) : base);   // capped — a long filename must not widen the block
    }
  } else if (kind === 'table' && c.tables && c.tables.length) {
    const t = c.tables[0] || {};
    const dims = (Array.isArray(t.rows) ? t.rows.length : '?') + '×' + (Array.isArray(t.columns) ? t.columns.length : '?');
    d2 = d2 ? `${d2} · ${dims}` : dims;
  } else if (kind === 'image' || kind === 'chart') {
    const m2 = /<img[^>]+src="([^"]+)"/.exec(c.output || '');
    thumb = m2 ? m2[1] : kind === 'chart' ? _dagEcThumb(c.id, false) : null;   // live ECharts → snapshot
  }
  const dur = c.duration == null ? '' : _dagFmtMs(c.duration);
  const icon = _DAG_KINDS[kind].icon;
  // Region provenance: a cell whose LAST run executed on the region kernel wears 🖧 in the node
  // — "where did this actually run" at a glance (stats.ranOn only ships while a region is
  // active; "local" is the unmarked default).
  const remote = c.stats && c.stats.ranOn && c.stats.ranOn !== 'local';
  const row1 = (remote ? '🖧 ' : '') + (icon ? icon + ' ' : '') + c.id;
  let w = Math.max((row1.length + (dur ? dur.length + 3 : 0)) * 7.8, d2.length * 6.2) + 22;
  let h = d2 ? 46 : 30;
  if (thumb) { h += _DAG_THUMB_H; w = Math.max(w, 130); }
  return { w, h, row1, dur, defs: d2, kind, thumb };
}

// Layout direction: 'auto' picks by pane aspect (tall split pane → top-down ranks;
// wide pane → left→right). Toggleable + persisted.
let _dagDirPref = (() => { try { return localStorage.getItem('slateDagDir') || 'auto'; } catch (_) { return 'auto'; } })();
// auto BIASES toward top-down (vertical stacking reads best); only a clearly-wide pane
// flips to LR, and the 1.35 threshold keeps the divider from toggling layouts at square.
const _dagDir = (w, h) => _dagDirPref === 'auto' ? (w > h * 1.35 ? 'LR' : 'TB') : _dagDirPref;
function dagDir() {
  _dagDirPref = _dagDirPref === 'auto' ? 'LR' : _dagDirPref === 'LR' ? 'TB' : 'auto';
  try { localStorage.setItem('slateDagDir', _dagDirPref); } catch (_) {}
  _dagDirBtn();
  dagFit();
}
function _dagDirBtn() {
  const b = document.getElementById('dagdir');
  if (b) b.textContent = _dagDirPref === 'auto' ? '⇅ auto' : _dagDirPref === 'LR' ? '⇄ LR' : '⇅ TB';
}

// ⚙ DAG display settings (persisted): setup cells (using/import — edge hubs that stretch
// the fit window) and isolated cells (no dataflow edges, e.g. a theme cell) are both
// HIDDEN by default; the gear popover brings either back.
let _dagSetupOn = (() => { try { return localStorage.getItem('slateDagSetup') === '1'; } catch (_) { return false; } })();
let _dagIsoOn = (() => { try { return localStorage.getItem('slateDagIso') === '1'; } catch (_) { return false; } })();
function dagSetupSet(v) {
  _dagSetupOn = !!v;
  try { localStorage.setItem('slateDagSetup', _dagSetupOn ? '1' : '0'); } catch (_) {}
  dagFit();
}
function dagIsoSet(v) {
  _dagIsoOn = !!v;
  try { localStorage.setItem('slateDagIso', _dagIsoOn ? '1' : '0'); } catch (_) {}
  dagFit();
}
function dagGearToggle(e) {
  if (e) e.stopPropagation();
  const p = document.getElementById('daggearpop'); if (!p) return;
  p.classList.toggle('open');
  if (p.classList.contains('open')) {
    const su = document.getElementById('dagoptsetup'), io = document.getElementById('dagoptiso');
    if (su) su.checked = _dagSetupOn;
    if (io) io.checked = _dagIsoOn;
  }
}

// 🔥 heat mode — fills recolor by accumulated compute cost; overlays ×evals ↓pulls.
let _dagHeatOn = (() => { try { return localStorage.getItem('slateDagHeat') === '1'; } catch (_) { return false; } })();
function dagHeat() {
  _dagHeatOn = !_dagHeatOn;
  try { localStorage.setItem('slateDagHeat', _dagHeatOn ? '1' : '0'); } catch (_) {}
  _dagHeatBtn();
  _dagQueue();
}
function _dagHeatBtn() { const b = document.getElementById('dagheat'); if (b) b.classList.toggle('on', _dagHeatOn); }

// 🖧 region map — fills recolor by WHERE each cell runs: the main kernel stays neutral, every
// remote region gets a stable hue, and a floating legend names the hosts. The global answer to
// "which cells live where" (the per-cell badge answers it one node at a time).
let _dagRegionsOn = (() => { try { return localStorage.getItem('slateDagRegions') === '1'; } catch (_) { return false; } })();
function dagRegions() {
  _dagRegionsOn = !_dagRegionsOn;
  try { localStorage.setItem('slateDagRegions', _dagRegionsOn ? '1' : '0'); } catch (_) {}
  _dagRegionsBtn(); _dagRegionLegend();
  _dagRoutesPoll(_dagRegionsOn);        // fetch + poll region-routing data while the overlay is on
  _dagQueue();
}
function _dagRegionsBtn() { const b = document.getElementById('dagregions'); if (b) b.classList.toggle('on', _dagRegionsOn); }
const _DAG_REGION_HUES = ['#4f7cf0', '#3fb96e', '#c07ae8', '#e8a13f', '#3fbdc0', '#e86a8a'];
// A cell's region for the overlay: the server's ranOn truth when it has run (auto-follow
// included), else the planned region from its tags — so the map is meaningful pre-run too.
function _dagCellRegion(c) {
  const st = c.stats;
  if (st && st.ranOn) {
    if (st.ranOn === 'local') return '';
    // ranOn is "<region> (<host>)" (a host running >1 region is disambiguated by name); older workers
    // reported the BARE host. Recover the region NAME so it matches the zones/hues either way.
    const raw = String(st.ranOn);
    const nm = raw.replace(/\s*\([^)]*\)\s*$/, '');                   // strip a trailing " (host)"
    const regs = _dagDeclaredRegions();
    if (regs.some(x => x.name === nm)) return nm;                     // "<region> (<host>)" form
    const byHost = regs.find(x => x.host === raw);                    // legacy bare-host form
    return byHost ? byHost.name : nm;
  }
  return _dagAssignedRegion(c);
}
// A cell's ASSIGNED region from its tags only ('' = local) — the placement you set, independent of
// where it last ran. Partition grouping uses THIS (so a just-dragged cell moves columns at once).
function _dagAssignedRegion(c) {
  const tags = (c && c.tags) || [];
  for (const t of tags) if (t.startsWith('region=')) return t.slice(7);
  return '';
}
// Regions PRESENT in the graph (some cell is tagged/ran there).
function _dagRegionNames() {
  const cs = _dagCtx ? Object.values(_dagCtx.m.byId) : [];
  return [...new Set(cs.map(_dagCellRegion).filter(Boolean))].sort();
}
// The notebook's DECLARED destinations (the `regions` footer, resolved against the registry) — may
// include regions with no cells yet, which still get a zone (an empty drop target). From server state.
function _dagDeclaredRegions() { return (typeof nbState !== 'undefined' && nbState && nbState.regions) || []; }
function _dagRegionHost(name) { const r = _dagDeclaredRegions().find(r => r.name === name); return r ? r.host : ''; }
// All region names = declared ∪ present, sorted → stable hue/zone ordering that doesn't dance.
function _dagRegionNamesAll() {
  return [...new Set([..._dagDeclaredRegions().map(r => r.name), ..._dagRegionNames()])].sort();
}
function _dagRegionHue(name) {
  if (!name) return null;
  return _DAG_REGION_HUES[Math.max(0, _dagRegionNamesAll().indexOf(name)) % _DAG_REGION_HUES.length];
}

// ── Region aliveness (join the live worker payload onto each zone) ──────────────────────────────
// The `workers` WS frame (window.onWorkersUpdate → _dagOnWorkers) carries each active worker's
// graduated status, freshest between full-state bumps; fall back to the last full state's list.
let _dagWorkersLive = null;
function _dagWorkersList() { return _dagWorkersLive || (window.__slateState && window.__slateState.workers) || []; }
// The worker backing a region — matched by `side` (== region name; '' is the local/main kernel).
function _dagRegionWorker(name) { return _dagWorkersList().find(w => (w.side || '') === name) || null; }
// Status → dot colour. `none` (no active worker for a declared region) is a hollow grey ring.
const _DAG_STATUS_COL = { ok: '#3fb96e', degraded: '#e8b23f', connecting: '#e8a13f', disconnected: '#e0596a', none: '#6a7183' };
function _dagWorkerStatus(w) { return w ? (w.status || (w.connected ? 'ok' : 'connecting')) : 'none'; }
function _dagRegionLegend() {
  const pane = document.getElementById('dagpane') || document.getElementById('dag');
  let el = document.getElementById('dagregleg');
  if (!_dagRegionsOn || !pane) {
    if (el) el.remove();
    const p = document.getElementById('dagpeerpanel'); if (p) p.remove();   // panel rides the overlay
    return;
  }
  if (!el) { el = document.createElement('div'); el.id = 'dagregleg'; el.className = 'dagregleg'; pane.appendChild(el); }
  const hasRemote = _dagRegionNamesAll().length > 0;
  el.innerHTML = `<span><i style="background:#3a3f55"></i>main (local)</span>` +
    _dagRegionNamesAll().map(n => `<span><i style="background:${_dagRegionHue(n)}"></i>${n === 'default' ? 'remote' : n}</span>`).join('') +
    (hasRemote ? `<button class="dagpeerbtn" onclick="_dagPeerPlan(false)" title="peer routing plan — how cross-region values move (direct / ssh-bridge / relay), the address each pair uses, and the mesh artifacts on each host">⇄ peer plan</button>` : '');
}

// ⇄ Peer routing plan — the DAG's window into how cross-region values actually move: the cached route
// verdict per host-pair (direct / ssh-bridge / relay + the chosen address, with age), the mesh artifacts
// present on each host, and the exact `ssh -L` each pull would run. `refresh` clears the cached verdicts
// (the "recalculate" action) — the fresh verdict lands on the NEXT transfer, since probing needs live
// workers. A plain click toggles the panel; recalculate re-fetches in place.
async function _dagPeerPlan(refresh) {
  const pane = document.getElementById('dagpane') || document.getElementById('dag');
  if (!pane) return;
  let el = document.getElementById('dagpeerpanel');
  if (el && !refresh) { el.remove(); return; }                 // toggle off on a second plain click
  if (!el) { el = document.createElement('div'); el.id = 'dagpeerpanel'; el.className = 'dagpeerpanel'; pane.appendChild(el); }
  el.innerHTML =
    `<div class="dagpeerhd"><b>⇄ peer routing plan</b><span>` +
    `<button onclick="_dagPeerPlan(true)" title="recalculate — clear the cached route verdicts so the next transfer re-probes">↻ recalculate</button>` +
    `<button onclick="{const p=document.getElementById('dagpeerpanel'); if(p) p.remove();}">✕</button>` +
    `</span></div><div class="dagpeerbody">${refresh ? 'recalculating…' : 'loading…'}</div>`;
  const body = el.querySelector('.dagpeerbody');
  try {
    const d = await (await fetch(_apipath('/api/peer-plan') + (refresh ? '?refresh=1' : ''))).json();
    if (body) body.innerHTML = _dagRenderPeerPlan(d);
  } catch (_) {
    if (body) body.textContent = 'failed to load the peer plan';
  }
}
window._dagPeerPlan = _dagPeerPlan;

// How each route KIND paints: direct = fast green, ssh-bridge = blue, relay = amber (via hub), unresolved
// = neutral (will probe on the next transfer). Mirrors the region hues' intent — a glance says the path.
const _DAG_ROUTE_COL = { direct: '#3fb96e', ssh: '#4f7cf0', relay: '#e8a13f', unresolved: '#6a7183' };
const _DAG_ROUTE_LBL = { direct: 'direct', ssh: 'ssh-bridge', relay: 'relay', unresolved: 'unresolved' };
function _dagAge(s) { return s < 0 ? '' : s < 90 ? s + 's ago' : Math.round(s / 60) + 'm ago'; }
function _dagEsc(s) { return String(s == null ? '' : s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }

// ── Region-routing overlay data ─────────────────────────────────────────────────────────────────
// The peer-plan routes, keyed 'src\0dst', fetched while the region overlay is on (verdicts + measured
// throughput evolve as transfers run). Drives the region→region edges and their tooltips.
let _dagRouteData = null, _dagRouteTimer = 0;
async function _dagFetchRoutes() {
  try {
    const d = await (await fetch(_apipath('/api/peer-plan'))).json();
    const map = {}; for (const r of (d.routes || [])) map[r.src + ' ' + r.dst] = r;
    _dagRouteData = map;
  } catch (_) { if (!_dagRouteData) _dagRouteData = {}; }
  if (_dagRegionsOn) _dagQueue();                          // repaint with fresh verdicts/throughput
}
function _dagRouteFor(src, dst) { return _dagRouteData ? _dagRouteData[src + ' ' + dst] : null; }
// Poll while the overlay is on (throughput/verdicts drift); stop when off.
function _dagRoutesPoll(on) {
  if (_dagRouteTimer) { clearInterval(_dagRouteTimer); _dagRouteTimer = 0; }
  if (on) { _dagFetchRoutes(); _dagRouteTimer = setInterval(_dagFetchRoutes, 5000); }
}
// px edge width HINTING throughput (log-scaled — MB/s spans orders of magnitude; unmeasured = thin default).
function _dagThroughputWidth(mbps) { return Math.max(2, Math.min(13, 2.4 + 3.3 * Math.log10(1 + (mbps || 0)))); }
// Speed label: "0.2 MB/s" · "12 MB/s" · "" when unmeasured.
function _dagSpeed(mbps) { return !mbps ? '' : (mbps >= 10 ? Math.round(mbps) : mbps) + ' MB/s'; }

function _dagRenderPeerPlan(d) {
  if (d && d.error) return `<div class="dagpp-empty">peer plan failed: ${_dagEsc(d.error)}</div>`;
  const routes = (d && d.routes) || [], hosts = (d && d.hosts) || [];
  let h = `<div class="dagpp-sec">routes${d && d.refreshed ? ' · <em>recalculated — resolves on next transfer</em>' : ''}</div>`;
  if (!routes.length) h += `<div class="dagpp-empty">no cross-host region pairs — same-host regions move over loopback</div>`;
  for (const r of routes) {
    const col = _DAG_ROUTE_COL[r.kind] || '#6a7183';
    h += `<div class="dagpp-route"><span class="dagpp-pair">${_dagEsc(r.dst)} <span class="dagpp-arrow">←</span> ${_dagEsc(r.src)}</span>` +
      `<span class="dagpp-kind" style="background:${col}">${_DAG_ROUTE_LBL[r.kind] || _dagEsc(r.kind)}</span>` +
      (r.addr ? `<span class="dagpp-addr">${_dagEsc(r.addr)}</span>` : '') +
      (r.age_s >= 0 ? `<span class="dagpp-age">${_dagAge(r.age_s)}</span>` : '') + `</div>`;
  }
  h += `<div class="dagpp-sec">mesh</div>`;
  if (!hosts.length) h += `<div class="dagpp-empty">—</div>`;
  for (const hh of hosts) {
    const g = hh.grants || [], p = hh.pins || [];
    h += `<div class="dagpp-host">${_dagEsc(hh.host)}${hh.reachable ? '' : ' <em class="dagpp-warn">(unreachable)</em>'}</div>`;
    if (!g.length && !p.length) { h += `<div class="dagpp-line dagpp-dim">no grants installed</div>`; continue; }
    for (const gr of g) h += `<div class="dagpp-line">↳ <b>${_dagEsc(gr.puller)}</b> may pull from <b>${_dagEsc(gr.source)}</b> · port ${gr.port}${gr.placeholder ? ' <span class="dagpp-dim">(placeholder — finalized at transfer)</span>' : ''}</div>`;
    for (const pn of p) h += `<div class="dagpp-line dagpp-dim">⚿ pins ${_dagEsc(pn.source)} @ ${_dagEsc((pn.addrs || []).join(', '))}</div>`;
  }
  return h;
}

function _dagState(c) { return _dagRunning.has(c.id) ? 'running' : (c.state || 'stale'); }

// Hover lineage with DIRECTION + DISTANCE: edges on paths into the node (upstream)
// vs out of it (downstream), each with hop count — direct neighbors render bold,
// further hops fall off. Returns Map(edge index → {up, d}).
const _DAG_UP_HUE = '#e2a63d', _DAG_DOWN_HUE = '#3fc6c0';   // amber = feeds it · teal = fed by it
function _dagLineageIdx(L, id) {
  if (!id) return null;
  const upD = new Map([[id, 0]]), dnD = new Map([[id, 0]]);
  let ch = true;
  while (ch) {
    ch = false;
    L.links.forEach(l => {
      if (upD.has(l.t)) { const d = upD.get(l.t) + 1; if (!upD.has(l.s) || upD.get(l.s) > d) { upD.set(l.s, d); ch = true; } }
      if (dnD.has(l.s)) { const d = dnD.get(l.s) + 1; if (!dnD.has(l.t) || dnD.get(l.t) > d) { dnD.set(l.t, d); ch = true; } }
    });
  }
  const idx = new Map();
  L.links.forEach((l, i) => {
    if (upD.has(l.t)) idx.set(i, { up: true, d: upD.get(l.t) + 1 });
    else if (dnD.has(l.s)) idx.set(i, { up: false, d: dnD.get(l.s) + 1 });
  });
  return idx;
}
// Bump the edge series' data version → every edge renderItem re-evaluates (hover states live
// OUTSIDE the option, so a repaint must be forced).
function _dagEdgeBump() {
  if (!_dagChart || !_dagCtx) return;
  _dagEdgeV++;
  try { _dagChart.setOption({ series: [{ id: 'dag-edges', data: _dagCtx.L.links.map((_, i) => [i, _dagEdgeV]) }] }); } catch (_) {}
}
function _dagSetHover(id) {
  if (_dagHoverId === id) return;
  _dagHoverId = id;
  _dagHoverIdx = _dagCtx ? _dagLineageIdx(_dagCtx.L, id) : null;
  _dagEdgeBump();
}
const _dagCost = c => (c.stats && c.stats.total_ms) || c.duration || 0;

// Layout → {nodes:[{c,b,x,y}], links:[{s,t,pts}], gw, gh}. With dagre: real Sugiyama
// (crossing minimization) AND routed edge waypoints (g.edge().points — around nodes,
// border to border). Fallback (dagre.min.js not yet cached): hand layering, straight edges.
function _dagLayout(m, w, h, dir) {
  const tb = dir === 'TB';
  if (window.dagre) {
    // Nodes whose EVERY edge is dim (the setup island: using/import hubs + their
    // satellites) leave dagre entirely and stack in a compact row above — dagre lays
    // disconnected components side by side, which would spend the width the hub-edge
    // removal saved. (Vacuously includes isolated nodes.)
    const aside = new Set();
    m.nodes.forEach(c => {
      const es = m.links.filter(l => l.source === c.id || l.target === c.id);
      if (es.every(l => l.dim)) aside.add(c.id);
    });
    // One dagre pass, optionally with row PINS. Rank-wrapping is expressed INSIDE dagre —
    // an invisible spine chain (one 1×1 node per final row) and zero-length pin edges tie
    // each real node to its row — so dagre's own router still draws every visible edge
    // around every node (hand-moving nodes after layout left edges slicing behind cells).
    // Mostly dagre DEFAULTS (default ranker, default edge weight/minlen) — only the
    // separations are tuned down for compact cards. The one structural addition is the
    // optional row-pin spine for rank wrapping.
    const build = assign => {
      const g = new dagre.graphlib.Graph();
      // edgesep kept tight: every edge crossing a pinned row inserts a virtual node into
      // that rank's ordering, and their spacing adds up to real width on busy graphs
      g.setGraph({ rankdir: dir, ranksep: 34, nodesep: 22, edgesep: 4, marginx: 16, marginy: 14 });
      g.setDefaultEdgeLabel(() => ({}));
      m.nodes.forEach(c => {
        if (aside.has(c.id)) return;
        const b = _dagBlock(c); g.setNode(c.id, { width: b.w + 6, height: b.h + 6 });
      });
      m.links.forEach(l => {
        if (!l.dim && !aside.has(l.source) && !aside.has(l.target)) g.setEdge(l.source, l.target);
      });
      if (assign) {
        let maxR = 0; assign.forEach(r => { maxR = Math.max(maxR, r); });
        for (let i = 0; i <= maxR + 1; i++) g.setNode('__spine' + i, { width: 1, height: 1 });
        for (let i = 0; i <= maxR; i++) g.setEdge('__spine' + i, '__spine' + (i + 1), { weight: 1, minlen: 1 });
        assign.forEach((r, id) => {
          // strictly BETWEEN the row's spine and the next (dagre rejects minlen 0):
          // spine_r < node < spine_{r+1} → exactly one rank per row
          g.setEdge('__spine' + r, id, { weight: 0, minlen: 1 });
          g.setEdge(id, '__spine' + (r + 1), { weight: 0, minlen: 1 });
        });
      }
      dagre.layout(g);
      return g;
    };
    let g = build(null);
    // Detect over-wide ranks (TB): pack each into rows within the pane budget (pass-1
    // x-order preserved → low crossings) and re-run dagre with those rows pinned.
    if (tb) {
      const budget = Math.max(w - 24, 420);
      const byRank = new Map();
      m.nodes.forEach(c => {
        if (aside.has(c.id)) return;
        const n = g.node(c.id), k2 = Math.round(n.y);
        byRank.has(k2) || byRank.set(k2, []);
        byRank.get(k2).push({ id: c.id, x: n.x, w: _dagBlock(c).w });
      });
      const SEP = 22;                                // keep the packer honest with nodesep
      const ranks = [...byRank.keys()].sort((a, b) => a - b).map(k2 => byRank.get(k2));
      const width = row => row.reduce((s2, n) => s2 + n.w + SEP, -SEP);
      if (ranks.some(r => width(r) > budget)) {
        const mkAssign = b2 => {
          const assign = new Map();
          let sub = 0;
          ranks.forEach(rank => {
            rank.sort((a, b) => a.x - b.x);
            let cw = 0, any = false;
            rank.forEach(n => {
              if (any && cw + n.w + SEP > b2) { sub++; cw = 0; }
              assign.set(n.id, sub); cw += n.w + SEP; any = true;
            });
            sub++;
          });
          return assign;
        };
        g = build(mkAssign(budget));
        // dagre's coordinate assignment spreads pinned rows beyond their packed width
        // (alignment chains); if the result overshoots the pane, re-pack ONCE with the
        // budget scaled by the overshoot so the final spread lands near the pane width.
        const spread = (g.graph().width || w) / Math.max(1, w);
        if (spread > 1.15) g = build(mkAssign(Math.max(300, budget / spread)));
      }
    }
    const gr = g.graph();
    // Aside nodes sit in a ROW ABOVE the flow (vertical growth is cheap in a tall pane).
    const asideList = m.nodes.filter(c => aside.has(c.id));
    let rowH = 0, ax = 16;
    const asidePos = {};
    if (asideList.length) {
      rowH = Math.max(...asideList.map(c => _dagBlock(c).h)) + 28;
      asideList.forEach(c => { const b = _dagBlock(c); asidePos[c.id] = [ax + b.w / 2, rowH / 2]; ax += b.w + 14; });
    }
    const nodes = m.nodes.map(c => {
      const b = _dagBlock(c);
      if (!aside.has(c.id)) { const n = g.node(c.id); return { c, b, x: n.x, y: n.y + rowH }; }
      return { c, b, x: asidePos[c.id][0], y: asidePos[c.id][1] };
    });
    const links = m.links.map(l => {
      const e = (!l.dim && g.hasEdge(l.source, l.target)) ? g.edge(l.source, l.target) : null;
      return { s: l.source, t: l.target, dim: l.dim, manual: l.manual,
               pts: (e && e.points && e.points.length > 1) ? e.points.map(p => [p.x, p.y + rowH]) : null };
    });
    const L = { nodes, links, gw: Math.max(gr.width || w, ax), gh: (gr.height || h) + rowH };
    _dagSqueeze(L, 0, 46);   // collapse empty full-height corridors (dagre's BK spread, spine overhead)
    _dagSqueeze(L, 1, 42);   // …and empty full-width bands between ranks
    return L;
  }
  const nL = m.layers.length, maxS = Math.max(...m.layers.map(l => l.length));
  const padA = 90, padB = 46;                       // main-axis / cross-axis padding
  const main = tb ? h : w, cross = tb ? w : h;
  const da = nL > 1 ? (main - 2 * padA) / (nL - 1) : 0;
  const db = Math.min(84, maxS > 1 ? (cross - 2 * padB) / (maxS - 1) : 0);
  const pos = {};
  m.nodes.forEach(c => {
    const n = m.layers[m.layer[c.id]].length;
    const a = nL > 1 ? padA + m.layer[c.id] * da : main / 2;
    const b = cross / 2 + (m.slot[c.id] - (n - 1) / 2) * db;
    pos[c.id] = tb ? [b, a] : [a, b];
  });
  return {
    nodes: m.nodes.map(c => ({ c, b: _dagBlock(c), x: pos[c.id][0], y: pos[c.id][1] })),
    links: m.links.map(l => ({ s: l.source, t: l.target, dim: l.dim, manual: l.manual, pts: [pos[l.source], pos[l.target]] })),
    gw: w, gh: h,
  };
}

// Gap squeeze: collapse EMPTY strips that span the whole graph on one axis to `maxGap`,
// shifting nodes and edge waypoints by the same piecewise offsets — relative geometry
// inside occupied regions is untouched, so dagre's routing stays valid while dead
// corridors (BK straightening spread, spine-pin rank overhead, tall-node bands) vanish.
function _dagSqueeze(L, axis, maxGap) {
  const iv = L.nodes.map(n => {
    const c = axis ? n.y : n.x, half = (axis ? n.b.h : n.b.w) / 2 + 8;
    return [c - half, c + half];
  }).sort((a, b) => a[0] - b[0]);
  const occ = [];
  iv.forEach(i => {
    const last = occ[occ.length - 1];
    if (last && i[0] <= last[1] + 1) last[1] = Math.max(last[1], i[1]);
    else occ.push([i[0], i[1]]);
  });
  const cuts = [];                                   // [gap start, excess to remove]
  for (let i = 1; i < occ.length; i++) {
    const gap = occ[i][0] - occ[i - 1][1];
    if (gap > maxGap) cuts.push([occ[i - 1][1], gap - maxGap]);
  }
  if (!cuts.length) return;
  const shift = v => {                               // points inside a gap compress smoothly
    let s = 0;
    for (const [pos, ex] of cuts) if (v > pos) s += Math.min(ex, v - pos);
    return v - s;
  };
  L.nodes.forEach(n => { if (axis) n.y = shift(n.y); else n.x = shift(n.x); });
  L.links.forEach(l => (l.pts || []).forEach(p => { p[axis] = shift(p[axis]); }));
  if (axis) L.gh = shift(L.gh); else L.gw = shift(L.gw);
}

// Memoized layout — the breathing animation re-paints ~25×/s; dagre must not re-run
// unless the graph actually changed (nodes, block dims, links, direction, canvas).
let _dagLayoutKey = '', _dagLayoutVal = null;
function _dagLayoutCached(m, w, h, dir) {
  const key = 'v5|' + (_dagSetupOn ? 'S' : 's') + (_dagIsoOn ? 'I|' : 'i|') + dir + '|' + w + 'x' + h + '|' +
    m.nodes.map(c => { const b = _dagBlock(c); return c.id + ':' + (b.w | 0) + ':' + b.h; }).join(',') + '|' +
    m.links.map(l => l.source + (l.dim ? '~' : l.manual ? '≈' : '>') + l.target).join(',');   // dim-ness shapes the layout; manual-ness is styling but rides the cached links
  if (key !== _dagLayoutKey || !_dagLayoutVal) { _dagLayoutKey = key; _dagLayoutVal = _dagLayout(m, w, h, dir); }
  return _dagLayoutVal;
}

// Region ZONES for the DAG: a container per compute env (`local` + one per region) with its member
// cells laid out inside, plus a placeholder box for a declared-but-empty region to aim cells at.
// Coords are in layout space (same as nodes) → api.coord() in the renderItem maps them to pixels.
//
// GRID PACKING: the envs are arranged in a GRID, not a single left→right row of full-height columns.
// The column count is chosen to best match the pane's aspect ratio, and each grid ROW is only as tall
// as its content — so `local + 3 hosts` in a tall/square pane becomes a 2×2 of quadrants instead of
// four tall, mostly-empty swimlanes, while a wide bottom-dock with a couple of regions still packs
// into a single row. Cells in the same grid row/column share width/height so the boxes line up clean.
// Dragging a cell between zones moves it to that compute env; cross-zone edges are the boundary
// transfers. Recomputed per render (dagre per env); notebooks with regions are modest.
// Node-by-id index, memoized per layout object (the placement optimizer builds a fresh candidate layout
// each try, so this is O(nodes) once per candidate instead of an O(nodes) `.find` on every edge lookup).
const _dagNdxCache = new WeakMap();
function _dagNdx(L) { let mp = _dagNdxCache.get(L); if (!mp) { mp = new Map(L.nodes.map(n => [n.c.id, n])); _dagNdxCache.set(L, mp); } return mp; }
function _dagSegX(a, b) { const d = (p, q, r) => (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]); const p1 = [a[0], a[1]], p2 = [a[2], a[3]], p3 = [b[0], b[1]], p4 = [b[2], b[3]]; const d1 = d(p3, p4, p1), d2 = d(p3, p4, p2), d3 = d(p1, p2, p3), d4 = d(p1, p2, p4); return ((d1 > 0) !== (d2 > 0)) && ((d3 > 0) !== (d4 > 0)); }
// Placement objective: crossings + total length of the CROSS-region straight segments (lower = cleaner).
function _dagCrossMetric(L) {
  const nd = id => _dagNdx(L).get(id);
  const segs = L.links.map(l => { const a = nd(l.s), b = nd(l.t); if (!a || !b || _dagAssignedRegion(a.c) === _dagAssignedRegion(b.c)) return null; return [a.x, a.y, b.x, b.y]; }).filter(Boolean);
  let len = 0; segs.forEach(s => len += Math.hypot(s[2] - s[0], s[3] - s[1]));
  let cr = 0; for (let i = 0; i < segs.length; i++) for (let j = i + 1; j < segs.length; j++) if (_dagSegX(segs[i], segs[j])) cr++;
  return { crossings: cr, length: len };
}
let _dagPlaceCache = { key: null, place: null };   // memoized optimizer placement — invariant to pane size

function _dagPartitionedLayout(m, w, h) {
  const assigned = m.nodes.map(_dagAssignedRegion).filter(Boolean);
  const sides = ['', ...new Set([..._dagDeclaredRegions().map(r => r.name), ...assigned])];   // local + declared ∪ assigned
  const CELLGAP = 44, PAD = 18, HEAD = 30, MINW = 156, MINH = 130;

  // 1. Sub-layout each env independently (dagre TB); capture its nodes in LOCAL coords (origin 0,0)
  //    and its intrinsic content size, so we can place the whole block into a grid cell afterwards.
  const cells = sides.map(side => {
    const sub = m.nodes.filter(c => _dagAssignedRegion(c) === side);   // group by ASSIGNMENT (tags), not where it ran
    const ids = new Set(sub.map(c => c.id));
    const subLinks = m.links.filter(l => ids.has(l.source) && ids.has(l.target));
    let cw = MINW, ch = MINH - HEAD; const snodes = [], slinks = {};
    if (sub.length) {
      const subL = _dagLayout({ nodes: sub, links: subLinks, byId: m.byId, layers: [], layer: {}, slot: {} }, 440, h, 'TB');
      let minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
      subL.nodes.forEach(n => { minx = Math.min(minx, n.x - n.b.w / 2); miny = Math.min(miny, n.y - n.b.h / 2); maxx = Math.max(maxx, n.x + n.b.w / 2); maxy = Math.max(maxy, n.y + n.b.h / 2); });
      cw = Math.max(MINW, maxx - minx); ch = Math.max(MINH - HEAD, maxy - miny);
      subL.nodes.forEach(n => snodes.push({ c: n.c, b: n.b, x: n.x - minx, y: n.y - miny }));   // origin-relative
      subL.links.forEach(l => { if (l.pts) slinks[l.s + '>' + l.t] = l.pts.map(p => [p[0] - minx, p[1] - miny]); });
    }
    return { side, empty: sub.length === 0, pw: cw + 2 * PAD, ph: HEAD + ch + 2 * PAD, snodes, slinks };
  });

  // 2. Pick the grid column count G (1…K) whose packed grid best matches the pane's aspect ratio.
  const K = cells.length;
  const gridFor = G => {
    const rows = Math.ceil(K / G), colW = new Array(G).fill(0), rowH = new Array(rows).fill(0);
    cells.forEach((c, i) => { const col = i % G, r = (i / G) | 0; colW[col] = Math.max(colW[col], c.pw); rowH[r] = Math.max(rowH[r], c.ph); });
    const gw = colW.reduce((a, b) => a + b, 0) + CELLGAP * (G - 1);
    const gh = rowH.reduce((a, b) => a + b, 0) + CELLGAP * (rows - 1);
    return { G, rows, colW, rowH, gw, gh };
  };
  const target = Math.max(0.2, (w || 1) / (h || 1));                  // desired grid aspect ≈ the pane's
  let best = gridFor(1);
  for (let G = 2; G <= K; G++) { const g = gridFor(G); if (Math.abs(Math.log(g.gw / g.gh / target)) < Math.abs(Math.log(best.gw / best.gh / target))) best = g; }
  const G = best.G, rows = best.rows, S = G * rows, slots = [];
  for (let i = 0; i < S; i++) slots.push({ col: i % G, row: (i / G) | 0 });

  // 3. build(place): realise an env→slot placement into geometry (same row → aligned height; same col →
  //    aligned width; empty rows/cols collapse; each block centered in its cell). Coords are global.
  const mkLinks = linkPts => m.links.map(l => ({ s: l.source, t: l.target, dim: l.dim, manual: l.manual, pts: linkPts[l.source + '>' + l.target] || null }));
  function build(place) {
    const envAtSlot = {}; place.forEach((sl, ei) => envAtSlot[sl] = ei);
    const colW = new Array(G).fill(0), rowH = new Array(rows).fill(0);
    for (let sl = 0; sl < S; sl++) { const ei = envAtSlot[sl]; if (ei == null) continue; colW[slots[sl].col] = Math.max(colW[slots[sl].col], cells[ei].pw); rowH[slots[sl].row] = Math.max(rowH[slots[sl].row], cells[ei].ph); }
    const colX = [0]; for (let c = 1; c < G; c++) colX[c] = colX[c - 1] + colW[c - 1] + (colW[c - 1] ? CELLGAP : 0);
    const rowY = [0]; for (let r = 1; r < rows; r++) rowY[r] = rowY[r - 1] + rowH[r - 1] + (rowH[r - 1] ? CELLGAP : 0);
    const nodes = [], parts = [], linkPts = {};
    cells.forEach((cell, ei) => {
      const sl = place[ei], col = slots[sl].col, r = slots[sl].row, x0 = colX[col], y0 = rowY[r], x1 = x0 + colW[col], y1 = y0 + rowH[r];
      const tx = x0 + Math.max(PAD, (colW[col] - cell.pw) / 2 + PAD), ty = y0 + HEAD + PAD;
      cell.snodes.forEach(n => nodes.push({ c: n.c, b: n.b, x: n.x + tx, y: n.y + ty }));
      for (const k in cell.slinks) linkPts[k] = cell.slinks[k].map(p => [p[0] + tx, p[1] + ty]);
      parts.push({ side: cell.side, x0, y0, x1, y1, empty: cell.empty });
    });
    return { nodes, parts, linkPts };
  }

  // 4. Choose placement: brute-force the env→slot assignment whose realised layout scores lowest —
  //    crossings then length (pulls connected envs adjacent, so their boundary-transfer routes stay short).
  //    Node-avoidance is the router's job, so it's off this hot path. Memoized by (envs, sizes, grid) —
  //    invariant to pane size — so a resize reuses it; env count is tiny, so the search is exact + cheap.
  let place = cells.map((_, i) => i);
  const pk = sides.join('|') + '#' + G + 'x' + rows + '#' + cells.map(c => c.pw + ',' + c.ph).join(';');
  if (_dagPlaceCache.key === pk) place = _dagPlaceCache.place;
  else {
    let arr = 1; for (let i = 0; i < K; i++) arr *= (S - i);
    if (arr <= 40320) {
      const scoreOf = pl => { const b = build(pl); const cm = _dagCrossMetric({ nodes: b.nodes, links: mkLinks(b.linkPts) }); return cm.crossings * 800 + cm.length + 0.01 * pl[0]; };
      let bestS = Infinity, bestPl = place, idxs = slots.map((_, i) => i);
      const rec = ch => { if (ch.length === K) { const s = scoreOf(ch); if (s < bestS) { bestS = s; bestPl = ch.slice(); } return; } for (let i = 0; i < idxs.length; i++) { if (ch.includes(idxs[i])) continue; ch.push(idxs[i]); rec(ch); ch.pop(); } };
      rec([]); place = bestPl;
    }
    _dagPlaceCache = { key: pk, place };
  }
  const fin = build(place);
  const gw = Math.max(...fin.parts.map(p => p.x1), MINW), gh = Math.max(...fin.parts.map(p => p.y1), MINH);
  return { nodes: fin.nodes, links: mkLinks(fin.linkPts), gw, gh, partitions: fin.parts };
}
// ── Boundary-transfer edge routing ──────────────────────────────────────────────────────────────
// Cross-zone edges are the data hand-offs between compute envs. Rather than cut straight across (over
// node boxes + zone-header text), they're ROUTED: A* on a coarse grid where node boxes AND zone headers
// are walls, with a clearance gradient (stay off boxes), a turn penalty (few, gentle bends), fan-out
// attach points (a node's transfers leave its border as a fan, not all from its centre), and a used-cell
// penalty (parallel transfers separate into lanes). Paths are string-pulled to drop grid staircases.
// Routes live in LAYOUT coords and are cached — recomputed only when the layout changes, NOT on a plain
// pane resize (which only rescales) — so they're off the reactive render hot path.
const _DAG_DIRS = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]];
function _dagAng(a, b) { const na = Math.hypot(a[0], a[1]), nb = Math.hypot(b[0], b[1]); return Math.acos(Math.max(-1, Math.min(1, (a[0] * b[0] + a[1] * b[1]) / (na * nb)))) / Math.PI; }
function _dagHPush(h, it) { h.push(it); let i = h.length - 1; while (i > 0) { const p = (i - 1) >> 1; if (h[p][0] <= h[i][0]) break; const t = h[p]; h[p] = h[i]; h[i] = t; i = p; } }
function _dagHPop(h) { const top = h[0], last = h.pop(); if (h.length) { h[0] = last; let i = 0, n = h.length; for (; ;) { let l = 2 * i + 1, r = l + 1, m = i; if (l < n && h[l][0] < h[m][0]) m = l; if (r < n && h[r][0] < h[m][0]) m = r; if (m === i) break; const t = h[m]; h[m] = h[i]; h[i] = t; i = m; } } return top; }
function _dagAstar(cost, used, free, start, goal, cols, rowsG) {
  const walk = (r, c) => free(r, c) || cost[r][c] > 0, mc = (r, c) => (free(r, c) ? 1 : cost[r][c]) + (used ? used[r][c] : 0);
  const SK = (r, c, d) => (r * cols + c) * 9 + (d + 1), h = (r, c) => Math.hypot(r - goal[0], c - goal[1]);
  const s0 = SK(start[0], start[1], -1), came = new Map(), gsc = new Map([[s0, 0]]), pos = { [s0]: [start[0], start[1], -1] }, closed = new Set(), heap = [];
  _dagHPush(heap, [h(start[0], start[1]), s0]);
  while (heap.length) {
    const bk = _dagHPop(heap)[1]; if (closed.has(bk)) continue; closed.add(bk);
    const [r, c, pd] = pos[bk];
    if (r === goal[0] && c === goal[1]) { const path = [[r, c]]; let k = bk; while (came.has(k)) { k = came.get(k); path.push([pos[k][0], pos[k][1]]); } return path.reverse(); }
    for (let di = 0; di < 8; di++) { const dr = _DAG_DIRS[di][0], dc = _DAG_DIRS[di][1], nr = r + dr, nc = c + dc; if (nr < 0 || nc < 0 || nr >= rowsG || nc >= cols || !walk(nr, nc)) continue;
      const turn = (pd >= 0 && pd !== di) ? 0.8 + _dagAng(_DAG_DIRS[pd], _DAG_DIRS[di]) * 2.4 : 0;
      const ng = gsc.get(bk) + ((dr && dc) ? 1.414 : 1) * mc(nr, nc) + turn, nk = SK(nr, nc, di);
      if (ng < (gsc.has(nk) ? gsc.get(nk) : Infinity)) { came.set(nk, bk); gsc.set(nk, ng); pos[nk] = [nr, nc, di]; _dagHPush(heap, [ng + h(nr, nc), nk]); }
    }
  }
  return null;
}
// A node's cross-edges leave/enter along its border on the side facing each target, ordered by direction.
function _dagFanAttach(L) {
  const nd = id => _dagNdx(L).get(id), byNode = new Map();
  L.links.forEach(l => { const a = nd(l.s), b = nd(l.t); if (!a || !b || _dagAssignedRegion(a.c) === _dagAssignedRegion(b.c)) return;
    for (const [self, other] of [[a, b], [b, a]]) { const k = self.c.id; (byNode.get(k) || byNode.set(k, []).get(k)).push({ key: l.s + '>' + l.t, self, other }); } });
  const attach = {};
  for (const [nid, arr] of byNode) {
    const self = arr[0].self, k = arr.length;
    arr.sort((p, q) => Math.atan2(p.other.y - p.self.y, p.other.x - p.self.x) - Math.atan2(q.other.y - q.self.y, q.other.x - q.self.x));
    arr.forEach((e, idx) => {
      const dx = e.other.x - self.x, dy = e.other.y - self.y, horiz = Math.abs(dx) >= Math.abs(dy);
      const span = (horiz ? self.b.h : self.b.w) * 0.62, off = k > 1 ? (idx - (k - 1) / 2) * Math.min(span / k, 15) : 0;
      attach[e.key + '@' + nid] = horiz ? [self.x + Math.sign(dx || 1) * self.b.w / 2, self.y + off] : [self.x + off, self.y + Math.sign(dy || 1) * self.b.h / 2];
    });
  }
  return attach;
}
function _dagRouteEdges(L) {
  const CELL = 18, MG = 8, CLEAR = 2, SOFT = 2.4, HEADER = 30, nd = id => _dagNdx(L).get(id);
  const attach = _dagFanAttach(L);
  let maxx = 0, maxy = 0;
  L.nodes.forEach(n => { maxx = Math.max(maxx, n.x + n.b.w); maxy = Math.max(maxy, n.y + n.b.h); });
  L.partitions.forEach(p => { maxx = Math.max(maxx, p.x1); maxy = Math.max(maxy, p.y1); });
  const cols = ((maxx / CELL) | 0) + 3, rowsG = ((maxy / CELL) | 0) + 3;
  const cellsOf = n => [Math.max(0, ((n.x - n.b.w / 2 - MG) / CELL) | 0), Math.max(0, ((n.y - n.b.h / 2 - MG) / CELL) | 0), Math.min(cols - 1, ((n.x + n.b.w / 2 + MG) / CELL) | 0), Math.min(rowsG - 1, ((n.y + n.b.h / 2 + MG) / CELL) | 0)];
  const wall = Array.from({ length: rowsG }, () => new Uint8Array(cols));
  L.nodes.forEach(n => { const [c0, r0, c1, r1] = cellsOf(n); for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) wall[r][c] = 1; });
  const dist = Array.from({ length: rowsG }, () => new Int16Array(cols).fill(99)); const q = [];
  for (let r = 0; r < rowsG; r++) for (let c = 0; c < cols; c++) if (wall[r][c]) { dist[r][c] = 0; q.push([r, c]); }
  for (let head = 0; head < q.length; head++) { const [r, c] = q[head]; if (dist[r][c] >= CLEAR) continue; for (const [dr, dc] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) { const nr = r + dr, nc = c + dc; if (nr < 0 || nc < 0 || nr >= rowsG || nc >= cols) continue; if (dist[nr][nc] > dist[r][c] + 1) { dist[nr][nc] = dist[r][c] + 1; q.push([nr, nc]); } } }
  const cost = Array.from({ length: rowsG }, (_, r) => Float32Array.from({ length: cols }, (_, c) => wall[r][c] ? 0 : 1 + (dist[r][c] > 0 && dist[r][c] <= CLEAR ? (CLEAR - dist[r][c] + 1) * SOFT : 0)));
  // Zone-header bars (region label + status dot) are SOFT obstacles, not walls. An edge entering a zone
  // from above MUST cross that zone's header to reach the nodes below it, so a hard wall forced ugly
  // detours around the whole zone. A crossing penalty instead lets an edge drop straight down through
  // the header's empty span while still discouraging it from running ALONG the header (over the text).
  L.partitions.forEach(p => { const c0 = Math.max(0, (p.x0 / CELL) | 0), c1 = Math.min(cols - 1, (p.x1 / CELL) | 0), r0 = Math.max(0, (p.y0 / CELL) | 0), r1 = Math.min(rowsG - 1, ((p.y0 + HEADER) / CELL) | 0);
    for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) if (!wall[r][c]) cost[r][c] += 5; });
  const losBlocked = (x0, y0, x1, y1, free) => { const steps = Math.ceil(Math.hypot(x1 - x0, y1 - y0) / (CELL * 0.6)); for (let i = 1; i < steps; i++) { const t = i / steps, r = ((y0 + (y1 - y0) * t) / CELL) | 0, c = ((x0 + (x1 - x0) * t) / CELL) | 0; if (r < 0 || c < 0 || r >= rowsG || c >= cols) continue; if (wall[r][c] && !free(r, c)) return true; } return false; };
  const used = Array.from({ length: rowsG }, () => new Float32Array(cols)), MARK = 3.2;
  const stamp = pts => { for (let s = 0; s + 1 < pts.length; s++) { const steps = Math.ceil(Math.hypot(pts[s + 1][0] - pts[s][0], pts[s + 1][1] - pts[s][1]) / (CELL * 0.5)); for (let i = 0; i <= steps; i++) { const t = i / steps, r = ((pts[s][1] + (pts[s + 1][1] - pts[s][1]) * t) / CELL) | 0, c = ((pts[s][0] + (pts[s + 1][0] - pts[s][0]) * t) / CELL) | 0; for (const [dr, dc] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) { const rr = r + dr, cc = c + dc; if (rr >= 0 && cc >= 0 && rr < rowsG && cc < cols) used[rr][cc] += (dr || dc) ? MARK * 0.5 : MARK; } } } };
  const xlinks = L.links.filter(l => { const a = nd(l.s), b = nd(l.t); return a && b && _dagAssignedRegion(a.c) !== _dagAssignedRegion(b.c); })
    .sort((p, q2) => { const pa = nd(p.s), pb = nd(p.t), qa = nd(q2.s), qb = nd(q2.t); return Math.hypot(qb.x - qa.x, qb.y - qa.y) - Math.hypot(pb.x - pa.x, pb.y - pa.y); });   // longest first
  const STUB = 16, TILT = 10 * Math.PI / 180;   // the approach may lean up to ±TILT off the border normal
  // Outward normal of the border the attach point sits on (robust for short/narrow nodes where a
  // dominant-axis guess would pick the wrong side) → used to approach the node SQUARE-ON.
  const bnorm = (pt, n) => { const rx = n.x + n.b.w / 2, lx = n.x - n.b.w / 2, by = n.y + n.b.h / 2, ty = n.y - n.b.h / 2;
    if (Math.abs(pt[0] - rx) < 1.5) return [1, 0]; if (Math.abs(pt[0] - lx) < 1.5) return [-1, 0];
    if (Math.abs(pt[1] - by) < 1.5) return [0, 1]; if (Math.abs(pt[1] - ty) < 1.5) return [0, -1]; return [0, 0]; };
  // Rotate a border normal up to TILT toward direction (tx,ty): the arrival need not be EXACTLY
  // perpendicular — leaning a few degrees toward the far end shortens the route and softens the bend
  // where the routed middle meets the stub, while still reading as square-on.
  const lean = (nrm, tx, ty) => { const tl = Math.hypot(tx, ty) || 1, ux = tx / tl, uy = ty / tl;
    const ang = Math.acos(Math.max(-1, Math.min(1, nrm[0] * ux + nrm[1] * uy))); if (ang < 1e-4) return nrm;
    const th = Math.min(ang, TILT), rot = a => [nrm[0] * Math.cos(a) - nrm[1] * Math.sin(a), nrm[0] * Math.sin(a) + nrm[1] * Math.cos(a)];
    const p = rot(th), m = rot(-th); return (p[0] * ux + p[1] * uy) >= (m[0] * ux + m[1] * uy) ? p : m; };
  const routes = {};
  xlinks.forEach(l => {
    const a = nd(l.s), b = nd(l.t);
    const ap = attach[l.s + '>' + l.t + '@' + a.c.id] || [a.x, a.y], bp = attach[l.s + '>' + l.t + '@' + b.c.id] || [b.x, b.y];
    // Lean each border normal toward the OTHER endpoint (≤ ±TILT), then step out along it to the stub tip.
    const na = lean(bnorm(ap, a), bp[0] - ap[0], bp[1] - ap[1]), nb = lean(bnorm(bp, b), ap[0] - bp[0], ap[1] - bp[1]);
    // Route between points just OUTSIDE each border, then step in along the (leaned) normal — so the edge
    // exits and enters its nodes near-square-on (neat, visible arrowheads) instead of grazing.
    const aS = [ap[0] + na[0] * STUB, ap[1] + na[1] * STUB], bS = [bp[0] + nb[0] * STUB, bp[1] + nb[1] * STUB];
    // free() opens ONLY the exact start + goal cells (never the whole box). Freeing a node's entire
    // footprint let A* shortcut THROUGH the node and reach the attach point from the inside — which
    // flipped the arrowhead 180° and looped the edge through the box. The stub tips sit outside the
    // wall, so this only matters for the border-to-border fallback (its endpoints ARE on the border).
    const cellOf = pt => [Math.min(rowsG - 1, Math.max(0, (pt[1] / CELL) | 0)), Math.min(cols - 1, Math.max(0, (pt[0] / CELL) | 0))];
    const only = (u, v) => (r, c) => (r === u[0] && c === u[1]) || (r === v[0] && c === v[1]);
    let sp = aS, gp = bS, prefix = [ap], suffix = [bp];
    const aSc = cellOf(aS), bSc = cellOf(bS);
    let free = only(aSc, bSc);
    let path = _dagAstar(cost, used, free, aSc, bSc, cols, rowsG);
    if (!path) { sp = ap; gp = bp; prefix = []; suffix = []; const apc = cellOf(ap), bpc = cellOf(bp); free = only(apc, bpc); path = _dagAstar(cost, used, free, apc, bpc, cols, rowsG); }   // a stub cell was blocked → route border-to-border
    if (!path) return;
    const pts = path.map(([r, c]) => [c * CELL + CELL / 2, r * CELL + CELL / 2]); pts[0] = sp; pts[pts.length - 1] = gp;
    const mid = [pts[0]]; let i = 0;
    while (i < pts.length - 1) { let j = pts.length - 1; while (j > i + 1 && losBlocked(pts[i][0], pts[i][1], pts[j][0], pts[j][1], free)) j--; mid.push(pts[j]); i = j; }
    const out = prefix.concat(mid, suffix);   // border point → perpendicular stub → routed middle → stub → border point
    routes[l.s + '>' + l.t] = out; stamp(out);
  });
  return routes;
}
let _dagRouteCache = { sig: null, routes: null };
function _dagCachedRoutes(L) {
  const sig = L.nodes.map(n => n.c.id + ':' + (n.x | 0) + ',' + (n.y | 0)).join('|') + '#' + L.partitions.map(p => (p.x0 | 0) + ',' + (p.y0 | 0) + ',' + (p.x1 | 0)).join('|');
  if (_dagRouteCache.sig !== sig) _dagRouteCache = { sig, routes: _dagRouteEdges(L) };
  return _dagRouteCache.routes;
}

// Partitions → zone rectangles for rendering + drop hit-testing. `local` is included (neutral tint);
// dropping a cell there un-tags it.
function _dagPartitionZones(parts) {
  return parts.map(p => {
    const isLocal = p.side === '';
    const w = isLocal ? null : _dagRegionWorker(p.side);   // the live worker serving this region (if any)
    return {
      name: p.side, isLocal,
      host: isLocal ? '' : ((w && w.host) || _dagRegionHost(p.side)),
      hue: isLocal ? '#586089' : (_dagRegionHue(p.side) || '#5a6a90'),
      x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1, empty: p.empty,
      worker: w, wstatus: _dagWorkerStatus(w),            // aliveness for the header dot + hover card
    };
  });
}

// The region zone under a pixel (topmost wins), or null for the local/main area. Used for drop
// hit-testing during a node drag — pixels → layout coords via the chart's cartesian.
function _dagZoneAtPixel(px, py) {
  if (!_dagChart || !_dagCtx || !_dagCtx.zones || !_dagCtx.zones.length) return null;
  const d = _dagChart.convertFromPixel({ gridIndex: 0 }, [px, py]); if (!d) return null;
  const x = d[0], y = d[1];
  for (let i = _dagCtx.zones.length - 1; i >= 0; i--) {
    const z = _dagCtx.zones[i];
    if (x >= z.x0 && x <= z.x1 && y >= z.y0 && y <= z.y1) return z;
  }
  return null;
}
// Outline the zone currently under the cursor while dragging (a zrender overlay, no chart re-render).
function _dagSetZoneHi(zn) {
  if (!_dagChart) return;
  const zr = _dagChart.getZr();
  if (_dagZoneHi) { zr.remove(_dagZoneHi); _dagZoneHi = null; }
  if (!zn) return;
  const tl = _dagChart.convertToPixel({ gridIndex: 0 }, [zn.x0, zn.y0]);
  const br = _dagChart.convertToPixel({ gridIndex: 0 }, [zn.x1, zn.y1]);
  if (!tl || !br) return;
  _dagZoneHi = new echarts.graphic.Rect({ silent: true, z: 99,
    shape: { x: tl[0], y: tl[1], width: br[0] - tl[0], height: br[1] - tl[1], r: 11 },
    style: { fill: 'rgba(124,156,240,0.10)', stroke: zn.hue || '#7c9cf0', lineWidth: 2.5 } });
  zr.add(_dagZoneHi);
}

function _dagOption() {
  const st = window.__slateState; if (!st) return null;
  const m = _dagModel(st.cells || []);
  const el = document.getElementById('dagcanvas');
  const w = el.clientWidth || 800, h = el.clientHeight || 400;
  const dir = _dagDir(w, h);
  // With regions active the canvas is PARTITIONED (local + one column per region, recomputed each
  // render — cells carry current state already). Otherwise the normal cached single layout, re-bound
  // to the current cell objects (a celldone patch swaps fresh objects into nbState).
  const _partitioned = _dagDeclaredRegions().length > 0 || m.nodes.some(c => _dagAssignedRegion(c));
  const L = _partitioned ? _dagPartitionedLayout(m, w, h) : _dagLayoutCached(m, w, h, dir);
  _partitioned || L.nodes.forEach(n => { const cur = m.byId[n.c.id]; if (cur) { n.c = cur; n.b = _dagBlock(cur); } });
  const P = _dagPalette();
  // Edge fallback (whisper edges + the no-dagre case): plain border-clipped straight
  // segments — every VISIBLE dataflow edge carries dagre-routed waypoints.
  const tb = dir === 'TB';                           // edge tangents follow the flow axis
  const ndOf = {}; L.nodes.forEach(n => { ndOf[n.c.id] = n; });
  // Cross-zone (boundary-transfer) edges carry no dagre waypoints; route them around the boxes + headers.
  // The routed polyline becomes the edge's `pts`, which the edge renderItem already draws as a smooth
  // spline — so no renderItem changes. Cached, so a plain pane resize doesn't re-route.
  const _routes = _partitioned ? _dagCachedRoutes(L) : null;
  L.links.forEach(l => {
    if (l.pts) return;
    const rt = _routes && _routes[l.s + '>' + l.t];
    if (rt) { l.pts = rt; return; }
    const a = ndOf[l.s], z = ndOf[l.t];
    if (!a || !z) { l.pts = [[0, 0], [0, 0]]; return; }
    const dx = z.x - a.x, dy = z.y - a.y;
    const clip = n => Math.min(dx ? Math.abs((n.b.w / 2 + 5) / dx) : 9, dy ? Math.abs((n.b.h / 2 + 5) / dy) : 9, 0.45);
    const tA = clip(a), tB = clip(z);
    l.pts = [[a.x + dx * tA, a.y + dy * tA], [z.x - dx * tB, z.y - dy * tB]];
  });
  // Snap each edge's ends exactly onto the source/target borders — dagre-routed edges stop a few px
  // short, which shows as a gap (and a floating arrowhead) when zoomed in. No-op for routed cross-edges.
  L.links.forEach(l => { if (!l.pts || l.pts.length < 2) return; const a = ndOf[l.s], z = ndOf[l.t];
    if (z && z.b) l.pts[l.pts.length - 1] = _dagClipToBorder(l.pts[l.pts.length - 2], l.pts[l.pts.length - 1], z);
    if (a && a.b) l.pts[0] = _dagClipToBorder(l.pts[1], l.pts[0], a);
  });
  const stOf = id => _dagState(m.byId[id]);
  _dagAnyRunning = m.nodes.some(c => _dagState(c) === 'running');
  const zones = _partitioned ? _dagPartitionZones(L.partitions) : [];   // the tiled compute-env columns
  _dagCtx = { m, L, P, zones };
  _dagRegionLegend();                              // regions-overlay legend follows every re-render
  _dagHoverIdx = _dagLineageIdx(L, _dagHoverId);   // keep hover lineage valid across live re-renders
  const cnt = document.getElementById('dagcount');
  if (cnt) cnt.textContent = `${L.nodes.length} cells · ${L.links.length} edges`;

  // Heat normalization — decidedly non-linear: everything under 100 ms is flat green
  // ("cheap, don't care"), then LOG-scaled from that floor up to the notebook's most
  // expensive node (with a 2 s minimum ceiling so a notebook whose worst stage is
  // 300 ms doesn't paint it blazing red).
  const HEAT_FLOOR = 100;
  const maxCost = Math.max(2000, ...L.nodes.map(n => _dagCost(n.c)));
  const heatT = c => {
    const cost = _dagCost(c);
    return cost <= HEAT_FLOOR ? 0 : Math.log(cost / HEAT_FLOOR) / Math.log(maxCost / HEAT_FLOOR);
  };

  // Tooltip stays BRIEF — essentials only (interaction hints live under the ? button;
  // the full stats live on the click card, and hover must not compete with it).
  const nodeTip = i => {
    if (_dagCardEl()) return '';
    const c = L.nodes[i].c, s = _dagState(c);
    const dur = c.duration == null ? '' : ` · ⏱ ${_dagFmtMs(c.duration)}`;
    const defs = c.defs || [];
    const rows = [`<b>${c.id}</b> — <span style="color:${_dagColor(P, s)}">${s}</span>${dur}` +
                  ` <span style="color:${P.dim}">· ${_dagKind(c)}</span>`];
    if (defs.length) rows.push(`<code>${defs.slice(0, 5).join(', ')}</code>${defs.length > 5 ? ` <span style="color:${P.dim}">+${defs.length - 5}</span>` : ''}`);
    if (c.opaque) rows.push(`<span style="color:${P.errored}">⚠ unparseable — dependencies unknown (treated as a barrier)</span>`);
    if (c.stats) rows.push(`<span style="color:${P.dim}">Σ ${_dagFmtMs(c.stats.total_ms)} · ×${c.stats.evals}${c.stats.pulls ? ` · ↓${c.stats.pulls}` : ''}</span>`);
    if (c.stats && c.stats.ranOn) rows.push(`<span style="color:${P.dim}">${c.stats.ranOn === 'local' ? '⌂ ran locally' : '🖧 ran on ' + c.stats.ranOn}</span>`);
    if (c.stats && c.stats.lastXfer) rows.push(`<span style="color:${P.dim}">⇄ ${c.stats.lastXfer}</span>`);
    return rows.join('<br>');
  };
  const edgeTip = i => _dagCardEl() ? '' : `${L.links[i].s} → ${L.links[i].t}`;

  // Fit window = the TRUE bounding box of nodes AND every edge waypoint (bus lanes can
  // run outside the node extent — nothing may escape the initial view). Aspect-preserving:
  // pad the shorter direction so one graph unit is the same number of pixels on both axes.
  // Then add SLACK beyond the fit window on every side — inside-dataZoom clamps its window
  // to the axis extent, so without slack there is nothing to pan at full fit. The initial
  // dataZoom start/end percentages select exactly the centered fit window.
  let bx0 = 0, by0 = 0, bx1 = L.gw, by1 = L.gh;
  L.nodes.forEach(n => {
    bx0 = Math.min(bx0, n.x - n.b.w / 2 - 6); bx1 = Math.max(bx1, n.x + n.b.w / 2 + 6);
    by0 = Math.min(by0, n.y - n.b.h / 2 - 6); by1 = Math.max(by1, n.y + n.b.h / 2 + 6);
  });
  L.links.forEach(l => (l.pts || []).forEach(p => {
    bx0 = Math.min(bx0, p[0] - 6); bx1 = Math.max(bx1, p[0] + 6);
    by0 = Math.min(by0, p[1] - 6); by1 = Math.max(by1, p[1] + 6);
  }));
  zones.forEach(zn => {                              // empty zones live in the right margin — keep them in the fit window
    bx0 = Math.min(bx0, zn.x0); bx1 = Math.max(bx1, zn.x1);
    by0 = Math.min(by0, zn.y0); by1 = Math.max(by1, zn.y1);
  });
  const bw = bx1 - bx0, bh = by1 - by0;
  const u = Math.max(bw / w, bh / h, 0.0001);
  const exX = (w * u - bw) / 2, exY = (h * u - bh) / 2;
  const mX = 0.6 * w * u, mY = 0.6 * h * u;                    // pan slack (60% of a viewport per side)
  const totX = bw + 2 * exX + 2 * mX, totY = bh + 2 * exY + 2 * mY;
  const zx = [mX / totX * 100, (mX + bw + 2 * exX) / totX * 100];
  const zy = [mY / totY * 100, (mY + bh + 2 * exY) / totY * 100];

  // ── Region→region transfer edges (overlay) ──────────────────────────────────────────────────────
  // Collapse the cross-zone CELL edges into ONE edge per (source region → dest region) pair — the data
  // hand-offs the region view is about. Each carries its route verdict + measured throughput (from
  // _dagRouteData). Built only while the overlay is on; endpoints connect the zones' facing edges so the
  // line runs in the gutter, not through cell boxes.
  const _regEdges = [];
  if (_dagRegionsOn && zones.length) {
    const zoneOf = {}; zones.forEach(z => { zoneOf[z.isLocal ? '' : z.name] = z; });
    const byPair = new Map();
    for (const l of L.links) {
      if (l.dim) continue;                             // skip setup/using whispers
      const sc = m.byId[l.s], tc = m.byId[l.t]; if (!sc || !tc) continue;
      const sr = _dagCellRegion(sc), tr = _dagCellRegion(tc);
      if (sr === tr) continue;                         // same env → in-process, not a transfer
      const k = sr + ' ' + tr, e = byPair.get(k) || { src: sr, dst: tr, n: 0 };
      e.n++; byPair.set(k, e);
    }
    for (const e of byPair.values()) {
      const zs = zoneOf[e.src], zt = zoneOf[e.dst]; if (zs && zt) _regEdges.push({ ...e, zs, zt });
    }
  }
  const regionEdgeTip = i => {
    const e = _regEdges[i]; if (!e) return '';
    const r = _dagRouteFor(e.src, e.dst), kind = r ? r.kind : 'unresolved';
    const via = { direct: 'direct peer', ssh: 'SSH bridge', relay: 'via hub (relay)', unresolved: 'not yet resolved' }[kind] || kind;
    let h = `<b>${_dagEsc(e.dst || 'local')} ← ${_dagEsc(e.src || 'local')}</b>` +
      `<br>transport: <b style="color:${_DAG_ROUTE_COL[kind] || P.text}">${via}</b>`;
    if (r && r.addr) h += `<br>address: ${_dagEsc(r.addr)}`;
    if (r && r.mbps) h += `<br>throughput: ${_dagSpeed(r.mbps)}`;
    if (r && r.age_s >= 0) h += `<br><span style="color:${P.dim}">probed ${_dagAge(r.age_s)}</span>`;
    h += `<br><span style="color:${P.dim}">${e.n} cross-region ${e.n === 1 ? 'value' : 'values'}</span>`;
    return h;
  };

  return {
    animation: false,
    tooltip: {
      show: !_dagCardEl(), trigger: 'item', confine: true, backgroundColor: P.bg, borderColor: P.border,
      textStyle: { color: P.text, fontSize: 12 }, extraCssText: 'max-width:340px; white-space:normal;',
      formatter: p => p.seriesName === 'nodes' ? nodeTip(p.dataIndex)
                    : p.seriesName === 'region-edges' ? regionEdgeTip(p.dataIndex)
                    : edgeTip(p.dataIndex),
    },
    grid: { left: 0, right: 0, top: 0, bottom: 0 },
    xAxis: { type: 'value', min: bx0 - exX - mX, max: bx1 + exX + mX, show: false },
    yAxis: { type: 'value', min: by0 - exY - mY, max: by1 + exY + mY, show: false, inverse: true },   // dagre's y grows DOWN
    dataZoom: [
      // wheel zoom is handled by our own listener (ECharts' rate is fixed and too hot) —
      // the inside zooms provide drag-pan + the programmatic window
      { type: 'inside', xAxisIndex: 0, filterMode: 'none', start: zx[0], end: zx[1],
        zoomOnMouseWheel: false, moveOnMouseMove: true, moveOnMouseWheel: false },
      { type: 'inside', yAxisIndex: 0, filterMode: 'none', start: zy[0], end: zy[1],
        zoomOnMouseWheel: false, moveOnMouseMove: true, moveOnMouseWheel: false },
    ],
    series: [
      { // PARTITION columns — one per compute env (local + each region), tiling the background. Silent
        // so cells stay clickable/draggable on top; the header names the env, the body is a drop target.
        type: 'custom', id: 'dag-zones', name: 'zones', coordinateSystem: 'cartesian2d', z: 0.5, silent: true,
        data: zones.map((_, i) => [i]),
        renderItem: (params, api) => {
          const zn = zones[params.dataIndex]; if (!zn) return null;
          const tl = api.coord([zn.x0, zn.y0]), br = api.coord([zn.x1, zn.y1]);
          const x = tl[0], y = tl[1], wpx = br[0] - tl[0], hpx = br[1] - tl[1];
          const hh = Math.min(24, hpx);
          const label = zn.isLocal ? 'local · main kernel'
            : zn.name + (zn.host ? '  ·  ' + zn.host : '');
          const kids = [
            { type: 'rect', silent: true, shape: { x, y, width: wpx, height: hpx, r: 12 },
              style: { fill: _dagMix(P.bg, zn.hue, zn.isLocal ? 0.05 : 0.08), stroke: zn.hue,
                       lineWidth: 1.2, lineDash: zn.empty ? [6, 5] : null, opacity: 0.9 } },
            { type: 'rect', silent: true, shape: { x, y, width: wpx, height: hh, r: [12, 12, 0, 0] },
              style: { fill: _dagMix(P.bg, zn.hue, 0.2), opacity: 0.9 } },
            { type: 'text', silent: true, style: { x: x + 12, y: y + hh / 2 + 1,
              text: (zn.isLocal ? '💻 ' : '🖧 ') + label, fill: zn.isLocal ? P.text : zn.hue,
              font: '600 12px sans-serif', textVerticalAlign: 'middle' } },
          ];
          if (zn.empty) kids.push({ type: 'text', silent: true, style: { x: x + wpx / 2, y: y + hpx / 2 + 8,
            text: 'drag cells here', fill: P.dim, font: '11px sans-serif', textAlign: 'center', textVerticalAlign: 'middle' } });
          // Aliveness dot at the header's right edge — filled = a live worker (green ok · amber degraded ·
          // orange connecting/disconnected), hollow grey = no worker running for this region. Hovering it
          // (hit-tested in the zr mousemove handler) opens the region worker card. Silent like the rest.
          if (!zn.isLocal) {
            const col = _DAG_STATUS_COL[zn.wstatus] || _DAG_STATUS_COL.none;
            const dcx = x + wpx - 14, dcy = y + Math.min(24, hpx) / 2 + 1;
            kids.push({ type: 'circle', silent: true, shape: { cx: dcx, cy: dcy, r: 5 },
              style: { fill: zn.wstatus === 'none' ? 'transparent' : col, stroke: col, lineWidth: 1.6, opacity: 0.95 } });
          }
          return { type: 'group', children: kids };
        },
      },
      { // REGION→REGION transfer edges (overlay): one bowed line per (src→dst) region pair, COLORED by the
        // route's transport (direct=green · ssh-bridge=blue · relay=amber-dashed · unresolved=grey-dotted),
        // WIDTH hints measured throughput; hovering shows method/speed/address. Above cell edges, below
        // nodes (z ABOVE dag-nodes so the hand-offs read as the foreground); endpoints join the zones'
        // facing edges so it runs in the gutter. Empty unless the overlay's on.
        type: 'custom', id: 'dag-region-edges', name: 'region-edges', coordinateSystem: 'cartesian2d', z: 3,
        data: _regEdges.map((_, i) => [i]),
        renderItem: (params, api) => {
          const e = _regEdges[params.dataIndex]; if (!e) return null;
          const zs = e.zs, zt = e.zt;
          let a, b;
          if (zt.x0 >= zs.x1)      { a = [zs.x1, (zs.y0 + zs.y1) / 2]; b = [zt.x0, (zt.y0 + zt.y1) / 2]; }
          else if (zs.x0 >= zt.x1) { a = [zs.x0, (zs.y0 + zs.y1) / 2]; b = [zt.x1, (zt.y0 + zt.y1) / 2]; }
          else                     { a = [(zs.x0 + zs.x1) / 2, zs.y0]; b = [(zt.x0 + zt.x1) / 2, zt.y0]; }
          const A = api.coord(a), B = api.coord(b);
          const r = _dagRouteFor(e.src, e.dst), kind = r ? r.kind : 'unresolved';
          const col = _DAG_ROUTE_COL[kind] || '#6a7183';
          const lw = _dagThroughputWidth(r ? r.mbps : 0);
          const mx = (A[0] + B[0]) / 2, my = (A[1] + B[1]) / 2;
          const cp = [mx, my - Math.abs(0.16 * (B[0] - A[0])) - 16];        // bow up so ↔ pairs don't overlap
          const dl = Math.hypot(B[0] - cp[0], B[1] - cp[1]) || 1, ux = (B[0] - cp[0]) / dl, uy = (B[1] - cp[1]) / dl;
          const ah = 11, hbx = B[0] - ux * ah, hby = B[1] - uy * ah;
          const dash = kind === 'relay' ? [9, 6] : kind === 'unresolved' ? [3, 5] : null;
          const spd = _dagSpeed(r ? r.mbps : 0);
          const lbl = (_DAG_ROUTE_LBL[kind] || kind) + (spd ? ' · ' + spd : '');
          const curve = { x1: A[0], y1: A[1], cpx1: cp[0], cpy1: cp[1], x2: hbx, y2: hby };
          return { type: 'group', children: [
            { type: 'bezierCurve', style: { fill: 'none', stroke: col, lineWidth: Math.max(14, lw + 12), opacity: 0.001 },
              shape: { x1: A[0], y1: A[1], cpx1: cp[0], cpy1: cp[1], x2: B[0], y2: B[1] } },   // wide hover target
            { type: 'bezierCurve', silent: true, shape: curve,
              style: { fill: 'none', stroke: col, lineWidth: lw, opacity: 0.92, lineDash: dash, shadowBlur: 7, shadowColor: col } },
            { type: 'polygon', silent: true, style: { fill: col, opacity: 0.95 },
              shape: { points: [[B[0], B[1]], [hbx - uy * 5, hby + ux * 5], [hbx + uy * 5, hby - ux * 5]] } },
            { type: 'text', silent: true, style: { x: cp[0], y: cp[1] - 3, text: lbl, fill: col,
              font: '600 11px sans-serif', textAlign: 'center', textVerticalAlign: 'bottom', stroke: P.bg, lineWidth: 3 } },
          ] };
        },
      },
      { // edges under nodes — routed/S-curve waypoints, smoothed, arrowhead at the target border
        type: 'custom', id: 'dag-edges', name: 'edges', coordinateSystem: 'cartesian2d', z: 1,
        data: L.links.map((_, i) => [i, _dagEdgeV]),
        renderItem: (params, api) => {
          const l = L.links[params.dataIndex];
          // hot ONLY when the SOURCE is computing (its result will flow out along this edge) —
          // a running leaf must not light up its inbound edges. Edges live in their own violet
          // family; only an errored source overrides (red). Setup edges (using/import — every
          // cell has one) are background whispers: faint, thin, no layout influence.
          // Hovering a node brightens its transitive lineage and fades everything else.
          const s = stOf(l.s), hot = !l.dim && s === 'running';
          const hv = _dagHoverIdx ? _dagHoverIdx.get(params.dataIndex) : null;
          const faded = _dagHoverIdx && !hv;
          // Link mode: hovering a MANUAL edge is a delete affordance — red, bold, ✕ badge at the middle.
          const del = _dagLinkMode && l.manual && params.dataIndex === _dagLinkHoverEdge;
          const col = del ? P.errored
                    : s === 'errored' ? P.errored
                    : hv ? (hv.up ? _DAG_UP_HUE : _DAG_DOWN_HUE)   // amber upstream · teal downstream
                    : hot ? P.edgeHot : P.edge;
          const lw = del ? 3 : hv ? (hv.d === 1 ? 2.8 : 1.8) : l.dim ? 0.8 : hot ? 2.4 : 1.4;
          let op = del ? 1
                 : hv ? (hv.d === 1 ? 0.98 : Math.max(0.3, 0.62 - 0.12 * (hv.d - 2)))
                 : faded ? (l.dim ? 0.04 : 0.15) : l.dim ? 0.12 : hot ? 0.95 : 0.6;
          // Region overlay: the region→region edges carry the story, so recede the cell-level edges (unless
          // hovered/hot/being-deleted — those still need to read).
          if (_dagRegionsOn && !hv && !del && !hot) op *= 0.28;
          // Decimate waypoints (Douglas-Peucker): keep endpoints + genuine detours, drop
          // micro-wiggles — the spline relaxes into longer arcs but still dodges nodes.
          const pts = _dagRdpStubs(l.pts.map(p => api.coord(p)), 18);
          const n = pts.length;
          const tip = pts[n - 1];
          const style = { fill: 'none', stroke: col, lineWidth: lw, opacity: op };
          if (l.manual) style.lineDash = [6, 4];       // user-asserted (`needs=`) — an assertion, not derived dataflow
          const kids = [];
          // Arrowhead tracks the zoom so it stays proportionate to the boxes, but clamped to a pixel
          // band — it grows as you zoom in (instead of pinning at a few px against a huge node) without
          // ballooning at extreme zoom or vanishing when zoomed out. Scale = mean px per layout unit.
          const _o0 = api.coord([0, 0]);
          const _sc = Math.max(0.85, Math.min(3.2, ((Math.abs(api.coord([1, 0])[0] - _o0[0]) + Math.abs(api.coord([0, 1])[1] - _o0[1])) / 2) || 1));
          const ah = 7 * _sc, aw = 3.4 * _sc;
          let ux, uy;                                  // arrival unit tangent → arrowhead direction
          // The stroke stops at the head's BASE (not the tip) so the semi-transparent line doesn't
          // show through the (also semi-transparent) arrowhead.
          if (!l.dim && n === 2) {
            // no detour → the canonical SYMMETRIC S: leave the source square along the flow
            // axis, inflect at the midpoint, arrive square — tangents vertical in TB.
            const s0 = pts[0], k = 0.45;
            const cp2 = tb ? [tip[0], tip[1] - k * (tip[1] - s0[1])] : [tip[0] - k * (tip[0] - s0[0]), tip[1]];
            const dl = Math.hypot(tip[0] - cp2[0], tip[1] - cp2[1]) || 1; ux = (tip[0] - cp2[0]) / dl; uy = (tip[1] - cp2[1]) / dl;
            const bx = tip[0] - ux * ah, by = tip[1] - uy * ah;
            const shp = tb
              ? { x1: s0[0], y1: s0[1], cpx1: s0[0], cpy1: s0[1] + k * (tip[1] - s0[1]), cpx2: cp2[0], cpy2: cp2[1], x2: bx, y2: by }
              : { x1: s0[0], y1: s0[1], cpx1: s0[0] + k * (tip[0] - s0[0]), cpy1: s0[1], cpx2: cp2[0], cpy2: cp2[1], x2: bx, y2: by };
            kids.push({ type: 'bezierCurve', style, shape: shp });
          } else if (n === 2) {
            const s0 = pts[0], dl = Math.hypot(tip[0] - s0[0], tip[1] - s0[1]) || 1; ux = (tip[0] - s0[0]) / dl; uy = (tip[1] - s0[1]) / dl;
            kids.push({ type: 'line', shape: { x1: s0[0], y1: s0[1], x2: tip[0] - ux * ah, y2: tip[1] - uy * ah }, style });
          } else {
            const prev = pts[n - 2], dl = Math.hypot(tip[0] - prev[0], tip[1] - prev[1]) || 1; ux = (tip[0] - prev[0]) / dl; uy = (tip[1] - prev[1]) / dl;
            const cpts = pts.slice(0, n - 1); cpts.push([tip[0] - ux * ah, tip[1] - uy * ah]);   // last point → arrow base
            const m2 = cpts.length, Pp = [cpts[0], cpts[0], ...cpts, cpts[m2 - 1], cpts[m2 - 1]];
            for (let i = 0; i + 3 < Pp.length; i++) {
              const a1 = Pp[i + 1], a2 = Pp[i + 2], a3 = Pp[i + 3];
              const sx2 = (a1[0] + 4 * a2[0] + a3[0]) / 6, sy2 = (a1[1] + 4 * a2[1] + a3[1]) / 6;
              const px2 = i === 0 ? cpts[0][0] : (Pp[i][0] + 4 * a1[0] + a2[0]) / 6;
              const py2 = i === 0 ? cpts[0][1] : (Pp[i][1] + 4 * a1[1] + a2[1]) / 6;
              kids.push({ type: 'bezierCurve', style, shape: {
                x1: px2, y1: py2,
                cpx1: (2 * a1[0] + a2[0]) / 3, cpy1: (2 * a1[1] + a2[1]) / 3,
                cpx2: (a1[0] + 2 * a2[0]) / 3, cpy2: (a1[1] + 2 * a2[1]) / 3,
                x2: sx2, y2: sy2 } });
            }
          }
          const bx = tip[0] - ux * ah, by = tip[1] - uy * ah;
          kids.push({ type: 'polygon', shape: { points: [[tip[0], tip[1]], [bx - uy * aw, by + ux * aw], [bx + uy * aw, by - ux * aw]] },
            style: { fill: col, opacity: Math.min(1, op + 0.1) } });
          if (del) {   // ✕ badge at the edge's midpoint — "click deletes this edge"
            const m = n === 2 ? [(pts[0][0] + tip[0]) / 2, (pts[0][1] + tip[1]) / 2] : pts[Math.floor(n / 2)];
            kids.push({ type: 'circle', shape: { cx: m[0], cy: m[1], r: 8 },
              style: { fill: P.bg, stroke: P.errored, lineWidth: 1.6, opacity: 1 } });
            kids.push({ type: 'text', style: { x: m[0], y: m[1], text: '✕', fill: P.errored,
              font: 'bold 11px sans-serif', textAlign: 'center', textVerticalAlign: 'middle', opacity: 1 } });
          }
          return { type: 'group', children: kids };
        },
      },
      { // breathing halo — a tight ring around RUNNING cards. This is the ONLY series the
        // animation loop touches (data = [nodeIdx, phase]), so hover/tooltip on nodes and
        // edges never flickers from re-renders.
        type: 'custom', id: 'dag-breath', name: 'breath', coordinateSystem: 'cartesian2d', z: 1.5, silent: true,
        data: L.nodes.flatMap((n, i) => _dagState(n.c) === 'running' ? [[i, 0.5]] : []),
        renderItem: (params, api) => {
          const nd = L.nodes[api.value(0)]; if (!nd) return null;
          const phase = api.value(1);
          const p = api.coord([nd.x, nd.y]);
          const pw = api.size([nd.b.w, 0])[0], ph = api.size([0, nd.b.h])[1], pad = 3;
          return { type: 'rect', silent: true,
            shape: { x: p[0] - pw / 2 - pad, y: p[1] - ph / 2 - pad, width: pw + 2 * pad, height: ph + 2 * pad, r: 7 },
            style: { fill: 'none', stroke: _dagMix(P.run, '#ffffff', 0.2 * phase),
                     lineWidth: 1.5 + 1.5 * phase, opacity: 0.3 + 0.5 * phase,
                     shadowColor: P.run, shadowBlur: 2 + 5 * phase } };   // reined in — a ring, not a flood
        },
      },
      { // node cards — small-radius rounded rects, text inside, degrading as zoom shrinks them.
        // Running style is STATIC here (green border, gentle tint) — the animated part is the
        // breath series above, so these elements survive across animation frames (stable hover).
        type: 'custom', id: 'dag-nodes', name: 'nodes', coordinateSystem: 'cartesian2d', z: 2,
        data: L.nodes.map(n => [n.x, n.y]),
        renderItem: (params, api) => {
          const nd = L.nodes[params.dataIndex], c = nd.c, b = nd.b;
          const s = _dagState(c), running = s === 'running', cache = (c.tags || []).includes('cache');
          const col = _dagColor(P, s);
          const sel = _dagSel === c.id;
          const K = _DAG_KINDS[b.kind];
          // uniform card; the wedge carries the type. 🔥 heat and 🖧 regions recolor the fill —
          // regions win when both are on (a location question beats a cost question).
          const regHue = _dagRegionsOn ? _dagRegionHue(_dagCellRegion(c)) : null;
          const baseFill = regHue ? _dagMix(P.bg3, regHue, 0.38)
                         : _dagHeatOn ? _dagRamp(heatT(c)) : P.bg3;
          const fill = running ? _dagMix(baseFill, P.run, 0.10) : baseFill;
          const p = api.coord([nd.x, nd.y]);
          const pw = api.size([b.w, 0])[0], ph = api.size([0, b.h])[1];
          const children = [{
            type: 'rect', shape: { x: p[0] - pw / 2, y: p[1] - ph / 2, width: pw, height: ph, r: 5 },
            style: { fill,                                   // type tint — or 🔥 cost ramp
                     stroke: col, lineWidth: running || sel ? 2.2 : 1.5,
                     lineDash: cache && !running ? [4, 3] : null,
                     shadowColor: col, shadowBlur: sel ? 10 : s === 'errored' ? 6 : 0,
                     opacity: s === 'stale' || s === 'edited' ? 0.85 : 1 },
          }];
          // Output-type corner wedge — the unmissable type signal (the fill tint is subtle,
          // and in heat mode the fill is repurposed for cost). Top-left, scales down with zoom.
          const ws = Math.min(13, pw * 0.25, ph * 0.5);
          if (ws >= 5) children.push({ type: 'polygon', silent: true,
            shape: { points: [[p[0] - pw / 2 + 1.5, p[1] - ph / 2 + 1.5], [p[0] - pw / 2 + 1.5 + ws, p[1] - ph / 2 + 1.5], [p[0] - pw / 2 + 1.5, p[1] - ph / 2 + 1.5 + ws]] },
            style: { fill: K.hue, opacity: 0.95 } });
          // Text geometry tracks the block's zoom scale: it shrinks 1:1 below design size
          // (so lines never leak past a zoomed-out border) and GROWS sub-linearly above it
          // (readable when zoomed in, capped at 2× so it never balloons to fill the card).
          // With a thumbnail band, text anchors in the zone ABOVE the band.
          const kz = ph / b.h;
          const k = kz <= 1 ? kz : Math.min(2, 1 + (kz - 1) * 0.45);
          const tzH = (b.thumb ? b.h - _DAG_THUMB_H : b.h) * kz;   // px height of the text zone
          const tCy = p[1] - ph / 2 + tzH / 2;                      // its center
          if (tzH >= 16) {
            const heatLine = _dagHeatOn && c.stats
              ? `Σ ${_dagFmtMs(c.stats.total_ms)} · ×${c.stats.evals}${c.stats.pulls ? ` ↓${c.stats.pulls}` : ''}` : '';
            const row2 = heatLine || b.defs;
            const two = !!row2 && tzH >= 30;
            children.push({ type: 'text', silent: true, style: {
              text: `{a|${b.row1}}${b.dur ? `{d|  ${b.dur}}` : ''}`,
              x: p[0], y: two ? tCy - 8 * k : tCy,
              align: 'center', verticalAlign: 'middle', textAlign: 'center', textVerticalAlign: 'middle',
              rich: { a: { fill: P.text, fontSize: 12.5 * k, fontWeight: 600 },
                      d: { fill: _dagHeatOn ? '#f0d9b5' : P.dim, fontSize: 10 * k } },
            } });
            if (two) children.push({ type: 'text', silent: true, style: {
              text: row2, x: p[0], y: tCy + 10.5 * k,
              align: 'center', verticalAlign: 'middle', textAlign: 'center', textVerticalAlign: 'middle',
              fill: heatLine ? '#f0d9b5' : P.dim, fontSize: 10.5 * k,
            } });
          }
          // Figure thumbnail band — the output PNG rendered inside the node.
          if (b.thumb) {
            const bandH = (_DAG_THUMB_H - 6) * kz, iw = pw - 12 * kz;
            if (bandH > 12 && iw > 16) children.push({ type: 'image', silent: true,
              style: { image: b.thumb, x: p[0] - iw / 2, y: p[1] + ph / 2 - bandH - 3 * kz,
                       width: iw, height: bandH } });
          }
          return { type: 'group', children };
        },
      },
    ],
  };
}

function _dagRender() {
  if (!_dagOpen()) return;
  const el = document.getElementById('dagcanvas'); if (!el) return;
  const opt = _dagOption(); if (!opt) return;
  if (!_dagChart) _dagChart = echarts.init(el);
  else if (el.clientWidth !== _dagChart.getWidth() || el.clientHeight !== _dagChart.getHeight()) _dagChart.resize();
  // Live re-renders use notMerge (states/structure replace wholesale) — carry the user's
  // pan/zoom window across, or every celldone would snap the view back to fit.
  try {
    const prev = _dagChart.getOption();
    if (prev && prev.dataZoom && prev.dataZoom.length === 2 && prev.dataZoom[0].start != null) {
      opt.dataZoom[0].start = prev.dataZoom[0].start; opt.dataZoom[0].end = prev.dataZoom[0].end;
      opt.dataZoom[1].start = prev.dataZoom[1].start; opt.dataZoom[1].end = prev.dataZoom[1].end;
    }
  } catch (_) {}
  _dagChart.setOption(opt, { notMerge: true });
  if (!_dagChart._dagWired) {
    _dagChart._dagWired = true;
    // ── Drag: a NODE retags into a region zone; a zone's HEADER BAR moves the whole zone (its
    // subgraph follows, offset persisted). Both freeze the pan for the drag's duration; grabbing
    // empty canvas still pans (dataZoom). Node drag is only meaningful when zones exist.
    const _zr = _dagChart.getZr();
    const _dagFreezePan = () => _dagChart.setOption({ dataZoom: [{ moveOnMouseMove: false }, { moveOnMouseMove: false }] });
    _dagChart.on('mousedown', p => {
      if (_dagLinkMode || !_dagCtx || p.seriesName !== 'nodes' || !_dagCtx.zones || !_dagCtx.zones.length) return;
      const nd = _dagCtx.L.nodes[p.dataIndex]; if (!nd) return;
      const ev = p.event || {};
      _dagDrag = { id: nd.c.id, from: _dagAssignedRegion(nd.c), moved: false, sx: ev.offsetX || 0, sy: ev.offsetY || 0 };
      _dagFreezePan();                                       // freeze NOW so ECharts' roam can't steal the drag
    });
    _zr.on('mousemove', e => {
      if (!_dagDrag) {                                        // not dragging → region header-dot hover
        const hit = _dagBadgeAtPixel(e.offsetX, e.offsetY);
        const cv = el.querySelector('canvas');
        if (hit) { _dagRegCardShow(hit.zn, hit.cx, hit.cy); if (cv) cv.style.cursor = 'pointer'; }
        else { if (_dagRegCardName) _dagRegCardScheduleHide(); if (cv) cv.style.cursor = ''; }
        return;
      }
      if (!_dagDrag.moved) {
        if (Math.hypot(e.offsetX - _dagDrag.sx, e.offsetY - _dagDrag.sy) < 4) return;   // still a click, not a drag
        _dagDrag.moved = true;                                // pan already frozen on mousedown
      }
      if (!_dagGhost) {                                       // node drag: a small card ghost + column highlight
        _dagGhost = new echarts.graphic.Rect({ silent: true, z: 100,
          shape: { x: 0, y: 0, width: 118, height: 32, r: 6 },
          style: { fill: 'rgba(124,156,240,0.20)', stroke: '#7c9cf0', lineWidth: 1.5 } });
        _zr.add(_dagGhost);
      }
      _dagGhost.attr({ shape: { x: e.offsetX - 59, y: e.offsetY - 16, width: 118, height: 32, r: 6 } });
      _dagSetZoneHi(_dagZoneAtPixel(e.offsetX, e.offsetY));
    });
    _zr.on('mouseup', e => {
      if (!_dagDrag) return;
      const drag = _dagDrag; _dagDrag = null;
      if (_dagGhost) { _zr.remove(_dagGhost); _dagGhost = null; }
      _dagSetZoneHi(null);
      _dagChart.setOption({ dataZoom: [{ moveOnMouseMove: true }, { moveOnMouseMove: true }] });   // restore pan
      if (!drag.moved) return;                               // a click, not a drag → leave it to the click handler
      _dagSuppressClick = true; setTimeout(() => { _dagSuppressClick = false; }, 0);   // swallow the click ECharts fires next
      const zn = _dagZoneAtPixel(e.offsetX, e.offsetY);      // which partition column did it land in?
      const target = zn ? zn.name : drag.from;               // a partition → that env (local column ⇒ ''); outside ⇒ no change
      if (target !== drag.from) setCellRegion(drag.id, target);
    });
    _dagChart.on('click', p => {
      if (!_dagCtx || _dagSuppressClick) return;
      if (p.seriesName === 'edges') {                        // link mode: click a dashed (manual) edge → remove it
        const l = _dagCtx.L.links[p.dataIndex];
        if (_dagLinkMode && l && l.manual) {
          _dagLinkHoverEdge = -1;
          _dagSetNeeds(l.t, (_dagCtx.m.byId[l.t].needs || []).filter(x => x !== l.s));
        }
        return;
      }
      if (p.seriesName !== 'nodes') return;
      const id = _dagCtx.L.nodes[p.dataIndex].c.id;
      if (_dagLinkMode) { _dagLinkClick(id); return; }       // link mode: two clicks draw a manual edge
      window.selectCell && selectCell(id, false);
      const raw = p.event && p.event.event;
      if (raw && raw.shiftKey) { _dagJump(id); return; }     // ⇧-click → navigate the editor
      _dagCard(id, p.event ? p.event.offsetX : 0, p.event ? p.event.offsetY : 0);   // click → details card
    });
    _dagChart.getZr().on('click', e => { if (!e.target) _dagCardClose(); });        // empty canvas → dismiss
    _dagChart.on('mouseover', p => {
      if (!_dagCtx) return;
      if (p.seriesName === 'nodes') {
        const id = _dagCtx.L.nodes[p.dataIndex].c.id;
        _dagSetHover(id);
        if (_dagLinkMode && _dagLinkSrc != null) _dagLinkPreview(id);   // rubber-band toward the hover
      } else if (p.seriesName === 'edges' && _dagLinkMode) {
        const l = _dagCtx.L.links[p.dataIndex];
        if (l && l.manual) { _dagLinkHoverEdge = p.dataIndex; _dagEdgeBump(); }   // red ✕ = click deletes
      }
    });
    _dagChart.on('mouseout', p => {
      if (p.seriesName === 'nodes') { _dagSetHover(null); _dagLinkPreview(null); }
      else if (p.seriesName === 'edges' && _dagLinkHoverEdge >= 0) { _dagLinkHoverEdge = -1; _dagEdgeBump(); }
    });
    // Gentle wheel zoom, anchored on the cursor. ECharts' built-in wheel rate is fixed
    // (~1.4× per tick) and way too hot; exp(-ΔY·k) is mild per tick AND continuous for
    // trackpad pixel deltas. Both axes get the same factor → aspect stays locked.
  }
  _dagPulseSync();
}

function _dagJump(id) {
  const el = document.getElementById('cell-' + id);          // header lands at top (scroll-margin clears the topbar)
  if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' });
}

// ── Node details card ─────────────────────────────────────────────────────────
// Click a node → a rich anchored card: type-colored header, error excerpt, the full
// run-statistics grid (evals/restores/pulls, mean±std, percentiles, totals), a
// sparkline of recent run times, defines/tags, and actions (run, cache-toggle).
// Navigation is ⇧-click on the node itself — no jump button here.
// Compact run-time strip: recent runs as dim bars, the LAST run highlighted — enough to
// see "was this run typical?" at a glance without a labeled chart.
function _dagSpark(recent, P) {
  if (!recent || recent.length < 2) return '';
  const W = 110, H = 20, n = recent.length, mx = Math.max(...recent) || 1;
  const bw = W / n;
  const bars = recent.map((v, i) =>
    `<rect x="${(i * bw).toFixed(1)}" y="${(H - Math.max(1.5, (v / mx) * H)).toFixed(1)}" width="${Math.max(1, bw - 1.2).toFixed(1)}" height="${Math.max(1.5, (v / mx) * H).toFixed(1)}" rx="1" fill="${i === n - 1 ? P.fresh : P.dim}" opacity="${i === n - 1 ? 1 : 0.45}"/>`).join('');
  return `<svg class="dagspark" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}"><title>recent run times (last highlighted)</title>${bars}</svg>`;
}
// A LARGE preview of the cell's output for the details card: the figure itself for
// images/charts, a mini table (first rows) for tables, the full path for files, a
// value excerpt otherwise. The node shows the tiny version; this is the readable one.
function _dagMiniTable(t) {
  const cols = (t.columns || []).slice(0, 8).map(x => (x && x.name) != null ? x.name : x);
  const rows = (t.rows || []).slice(0, 8);
  if (!cols.length || !rows.length) return '';
  return '<table class="dagcard-mini"><thead><tr>' + cols.map(h => `<th>${_esc(String(h))}</th>`).join('') +
    '</tr></thead><tbody>' + rows.map(r => '<tr>' + (Array.isArray(r) ? r : []).slice(0, 8).map(v =>
      `<td>${_esc(String(v))}</td>`).join('') + '</tr>').join('') + '</tbody></table>' +
    ((t.rows || []).length > 8 ? `<div class="dagcard-dim">… ${(t.rows || []).length} rows total</div>` : '');
}
function _dagPreview(c, kind) {
  const img = /<img[^>]+src="([^"]+)"/.exec(c.output || '');
  if (img) return `<img class="dagcard-thumb" src="${img[1]}"/>`;
  if (kind === 'chart') {
    const cap = _dagEcThumb(c.id, true);   // snapshot of the live instance
    return cap ? `<img class="dagcard-thumb" src="${cap}"/>`
               : '<div class="dagcard-dim">interactive chart — open the cell to explore it</div>';
  }
  if (kind === 'table' && c.tables && c.tables.length) return _dagMiniTable(c.tables[0] || {});
  const txt = (c.output || '').replace(/&quot;|&#34;/g, '"').replace(/<[^>]*>/g, '').trim();
  if (kind === 'file' && txt) return `<div class="dagcard-defs">${_esc(txt.replace(/^"|"$/g, ''))}</div>`;
  if (txt) return `<div class="dagcard-defs">${_esc(txt.slice(0, 180))}${txt.length > 180 ? '…' : ''}</div>`;
  return '';
}

function _dagCard(id, cx, cy) {
  _dagCardClose();
  const c = _dagCtx && _dagCtx.m.byId[id]; if (!c) return;
  const P = _dagCtx.P, s = _dagState(c);
  const kind = _dagKind(c), K = _DAG_KINDS[kind];
  const cache = (c.tags || []).includes('cache');
  const regs = (typeof _nbRegions === 'function') ? _nbRegions() : [];    // declared destinations → "run on" picker
  const curReg = (typeof cellAssignedRegion === 'function') ? cellAssignedRegion(c) : '';
  let err = '';
  if (s === 'errored' && c.output) {
    const t = document.createElement('div'); t.innerHTML = c.output;
    err = (t.textContent || '').trim().split('\n').filter(x => x.trim()).slice(0, 4).join('\n').slice(0, 400);
  }
  const prev = _dagPreview(c, kind);
  // Condensed stats — four chips carry what matters; the strip shows the shape.
  const st = c.stats;
  const chips = st ? [
    ['last', _dagFmtMs(st.last_ms) + (st.memo ? ` ${window._memoGlyph(st.memo)}` : '') + ` · ${_dagAgo(st.last_ts)}`],
    ['typical', `${_dagFmtMs(st.mean_ms)} ± ${_dagFmtMs(st.std_ms)}`],
    ['total', `${_dagFmtMs(st.total_ms)} · ×${st.evals}${st.restores ? ` ♻${st.restores}` : ''}`],
    ['used downstream', `↓ ${st.pulls}`],
  ] : [];
  // Region provenance chips: where the last run executed + what its inputs cost to move —
  // present only when a region is active for this notebook.
  if (st && st.ranOn) chips.push(['last ran', st.ranOn === 'local' ? '⌂ local' : `🖧 ${st.ranOn}`]);
  if (st && st.xferBytes) chips.push(['moved', `⇄ ${(st.xferBytes / 1048576).toFixed(1)} MB total`]);
  const defs = c.defs || [];
  const card = document.createElement('div');
  card.id = 'dagcard'; card.className = 'dagcard';
  card.innerHTML =
    `<div class="dagcard-h" style="border-left-color:${K.hue}">` +
      `<span class="dagcard-kico">${K.icon || '·'}</span><b class="dagcard-jump" title="jump to this cell in the notebook">${_esc(c.id)}</b>` +
      `<span class="dagcard-st" style="color:${_dagColor(P, s)}">${s}</span>` +
      `<span class="dagcard-kind" style="color:${K.hue}">${kind}</span></div>` +
    (c.opaque ? `<div class="dagcard-dim">⚠ this cell couldn’t be parsed — its dependencies are unknown, so the engine treats it as a barrier (everything below it is conservatively stale). Its graph edges are shown faded.</div>` : '') +
    (st && st.memo === 'handle' ? `<div class="dagcard-dim">⚡ produces a LIVE HANDLE (a DB / socket / file) — it isn’t cached (a restore would hand back a dangling pointer) and it can’t cross a region boundary. Tag this cell <code>resource</code> so each side — and each restore — opens its own.</div>` : '') +
    (err ? `<pre class="dagcard-err">${_esc(err)}</pre>` : '') +
    (prev ? `<div class="dagcard-sec">output</div>${prev}` : '') +
    (chips.length
      ? '<div class="dagcard-grid">' + chips.map(([k, v]) =>
          `<div class="dagchip"><span>${k}</span><b>${_esc(String(v))}</b></div>`).join('') + '</div>'
      : `<div class="dagcard-dim">no runs recorded this session yet</div>`) +
    (st ? _dagSpark(st.recent, P) : '') +
    (st && st.lastXfer ? `<div class="dagcard-sec">boundary transfer</div><div class="dagcard-defs">⇄ ${_esc(st.lastXfer)}</div>` : '') +
    (defs.length ? `<div class="dagcard-sec">defines (${defs.length})</div><div class="dagcard-defs">` +
      `${_esc(defs.slice(0, 12).join(', '))}${defs.length > 12 ? ` … +${defs.length - 12} more` : ''}</div>` : '') +
    ((c.tags || []).length ? `<div class="dagcard-sec">tags</div><div class="dagcard-defs">🏷 ${_esc(c.tags.join(', '))}</div>` : '') +
    (regs.length ? `<div class="dagcard-sec">run on</div><select class="dagrunon" title="assign this cell to a run destination">` +
      `<option value=""${curReg === '' ? ' selected' : ''}>💻 local (main kernel)</option>` +
      regs.map(r => `<option value="${_esc(r.name)}"${curReg === r.name ? ' selected' : ''}>🖧 ${_esc(r.name === 'default' ? 'remote' : r.name)} · ${_esc(r.host)}</option>`).join('') +
      `</select>` : '') +
    '<div class="dagcard-acts">' +
      '<button data-act="run" title="force re-evaluate this cell and its dependents">▶ Run</button>' +
      `<button data-act="cache" title="${cache ? 'stop persisting this cell’s result' : 'always persist this cell’s result (pipeline stage)'}">${cache ? '💾 Uncache' : '💾 Cache'}</button>` +
    '</div>';
  document.body.appendChild(card);   // viewport-centered (CSS) — big enough to read, above the pane
  const _ro = card.querySelector('.dagrunon');               // "run on" → retag the cell to a region
  if (_ro) _ro.addEventListener('change', async () => { const v = _ro.value; _dagCardClose(); await setCellRegion(c.id, v); });
  if (_dagChart) { try { _dagChart.dispatchAction({ type: 'hideTip' }); } catch (_) {} }
  _dagQueue();                                               // re-render with tooltip suppressed
  card.addEventListener('click', async e => {
    if (e.target.closest('.dagcard-jump')) { _dagCardClose(); _dagJump(c.id); return; }   // title → navigate
    const b = e.target.closest('button'); if (!b) return;
    const act = b.dataset.act;
    _dagCardClose();
    if (act === 'run') window.runCell && runCell(c.id, true);
    else if (act === 'cache') {
      const tags = (c.tags || []).filter(t => t !== 'cache');
      if (!cache) tags.push('cache');
      renderAll(await api('POST', '/api/tags/' + c.id, { tags }));
    }
  });
  setTimeout(() => {
    card._close = e => { if (!card.contains(e.target)) _dagCardClose(); };
    document.addEventListener('mousedown', card._close);
  }, 0);
}
function _dagCardClose() {
  const el = _dagCardEl();
  if (el) { el._close && document.removeEventListener('mousedown', el._close); el.remove(); _dagQueue(); }
}

// ── Region aliveness card — hover the header status dot for worker info + an inline reap ─────────
// The zones are silent, so the dot isn't an ECharts target; we hit-test it against the pixel canvas.
// Returns { zn, cx, cy } for the region zone whose header dot the pixel is over, else null.
let _dagRegCardName = null, _dagRegHideTimer = null;
function _dagBadgeAtPixel(px, py) {
  if (!_dagChart || !_dagCtx || !_dagCtx.zones) return null;
  for (const zn of _dagCtx.zones) {
    if (zn.isLocal) continue;
    const tl = _dagChart.convertToPixel({ gridIndex: 0 }, [zn.x0, zn.y0]);
    const br = _dagChart.convertToPixel({ gridIndex: 0 }, [zn.x1, zn.y1]);
    if (!tl || !br) continue;
    const cx = br[0] - 14, cy = tl[1] + Math.min(24, br[1] - tl[1]) / 2 + 1;
    if ((px - cx) ** 2 + (py - cy) ** 2 <= 100) return { zn, cx, cy };   // r≈10px hit halo
  }
  return null;
}
function _dagRegCardEl() { return document.getElementById('dagregcard'); }
function _dagRegCardHide() { const el = _dagRegCardEl(); if (el) el.remove(); _dagRegCardName = null; }
function _dagRegCardScheduleHide() {
  clearTimeout(_dagRegHideTimer);
  _dagRegHideTimer = setTimeout(() => { const el = _dagRegCardEl(); if (el && !el.matches(':hover')) _dagRegCardHide(); }, 220);
}
// Build (or keep) the hover card for a region's worker, anchored beside its header dot.
function _dagRegCardShow(zn, cx, cy) {
  clearTimeout(_dagRegHideTimer);
  const existing = _dagRegCardEl();
  if (existing && _dagRegCardName === zn.name && cx != null) return;   // hover re-fire, already open → leave it
  let keepL = null, keepT = null;                                       // refresh-in-place (live update): keep position
  if (existing && _dagRegCardName === zn.name) { keepL = existing.style.left; keepT = existing.style.top; }
  _dagRegCardHide();
  _dagRegCardName = zn.name;
  const w = zn.worker, st = zn.wstatus, col = _DAG_STATUS_COL[st] || _DAG_STATUS_COL.none;
  const decl = _dagDeclaredRegions().find(r => r.name === zn.name);
  const transport = (w && w.transport) || (decl && decl.transport) || '';
  const nm = zn.name === 'default' ? 'remote' : zn.name;
  const stLabel = st === 'none' ? 'no worker running' : st;
  const statsJson = (window._wpLive && window._wpLive[zn.name]) || (w && w.stats) || '';
  const chips = (typeof _wpStatsChips === 'function') ? _wpStatsChips(statsJson, w && w.note) : '';
  const meta = [
    zn.host ? `<span><i>host</i> ${_esc(zn.host)}</span>` : '',
    (w && w.port) ? `<span><i>port</i> ${w.port}</span>` : '',
    transport ? `<span><i>transport</i> ${_esc(transport)}</span>` : '',
  ].filter(Boolean).join('');
  const card = document.createElement('div');
  card.id = 'dagregcard'; card.className = 'dagregcard';
  card.innerHTML =
    `<div class="dagregcard-h"><span class="dagregdot" style="background:${st === 'none' ? 'transparent' : col};border-color:${col}"></span>` +
      `<b>🖧 ${_esc(nm)}</b><span class="dagregcard-st" style="color:${col}">${_esc(stLabel)}</span></div>` +
    (meta ? `<div class="dagregcard-meta">${meta}</div>` : '') +
    (chips ? `<div class="dagregcard-chips">${chips}</div>`
           : `<div class="dagcard-dim">${st === 'none' ? 'no worker is currently serving this region' : 'no telemetry yet'}</div>`) +
    (w ? '<div class="dagregcard-acts">' +
      '<button data-act="log" title="open this worker’s live log + telemetry">🪵 Log</button>' +
      ((zn.host && w.port) ? '<button data-act="reap" class="dagreap" title="kill this worker + remove its files — un-fetched results are lost">✕ Reap</button>' : '') +
      '</div>' : '');
  document.body.appendChild(card);
  if (cx != null) {                                                    // fresh hover → anchor beside the dot
    const cv = document.getElementById('dagcanvas'), r = cv ? cv.getBoundingClientRect() : { left: 0, top: 0 };
    card.style.left = Math.max(6, Math.min(window.innerWidth - card.offsetWidth - 8, r.left + cx - card.offsetWidth / 2)) + 'px';
    card.style.top = Math.min(window.innerHeight - card.offsetHeight - 8, r.top + cy + 12) + 'px';
  } else if (keepL != null) { card.style.left = keepL; card.style.top = keepT; }   // live refresh → keep position
  card.addEventListener('mouseenter', () => clearTimeout(_dagRegHideTimer));
  card.addEventListener('mouseleave', _dagRegCardScheduleHide);
  card.addEventListener('click', async e => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.act === 'log') { _dagRegCardHide(); if (typeof openWorkerPop === 'function') openWorkerPop(zn.name); return; }
    if (b.dataset.act === 'reap') {
      const host = zn.host, port = w.port;
      if (typeof confirmDark === 'function' &&
          !await confirmDark('Reap worker :' + port + ' on ' + host + '?\nThis kills it and removes its files — any un-fetched results are lost.', 'Reap', 'danger')) return;
      _dagRegCardHide();
      try { await api('POST', '/api/reap-worker', { host, port }); } catch (_) {}
    }
  });
}

// Reverse navigation: selecting a cell in the notebook lights up its node in the graph.
function _dagHighlight(id) {
  if (_dagSel === id) return;
  _dagSel = id;
  _dagQueue();
}

// Ramer–Douglas–Peucker polyline simplification (screen px tolerance).
function _dagRdp(pts, eps) {
  if (pts.length <= 2) return pts;
  const d2line = (p, a, b) => {
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const L2 = dx * dx + dy * dy;
    if (!L2) return Math.hypot(p[0] - a[0], p[1] - a[1]);
    const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2));
    return Math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy);
  };
  let maxD = 0, maxI = 0;
  for (let i = 1; i < pts.length - 1; i++) {
    const d = d2line(pts[i], pts[0], pts[pts.length - 1]);
    if (d > maxD) { maxD = d; maxI = i; }
  }
  if (maxD <= eps) return [pts[0], pts[pts.length - 1]];
  return _dagRdp(pts.slice(0, maxI + 1), eps).slice(0, -1).concat(_dagRdp(pts.slice(maxI), eps));
}
// Simplify a routed polyline while PRESERVING its endpoint stubs. The router lays the first and
// last segments perpendicular to the node borders they touch (square-on departure/arrival, keyed to
// which SIDE the transfer connects to), so those stubs carry the arrival angle — decimating them
// collapses the edge into a shallow graze along the border. Pin pts[0..1] and pts[n-2..n-1]; RDP only
// the interior span between the stub tips.
function _dagRdpStubs(pts, eps) {
  const n = pts.length;
  if (n <= 3) return pts;
  return [pts[0], ..._dagRdp(pts.slice(1, n - 1), eps), pts[n - 1]];
}
// Clip an edge's terminal point exactly onto its node's border, along the incoming direction. Dagre
// leaves a few-px gap between an edge and the node (invisible at fit, an obvious gap zoomed in); this
// snaps it — and for routed cross-edges (already on the border) it's a no-op. Returns the border point
// where the ray from `prev` through `end` first meets the box, or `end` if it doesn't cross it.
function _dagClipToBorder(prev, end, node) {
  const L0 = node.x - node.b.w / 2, R0 = node.x + node.b.w / 2, T0 = node.y - node.b.h / 2, B0 = node.y + node.b.h / 2;
  const dx = end[0] - prev[0], dy = end[1] - prev[1];
  if (!dx && !dy) return end;
  let best = null;
  const hit = (t, x, y, ok) => { if (t < 0 || !ok) return; if (!best || t < best[0]) best = [t, [x, y]]; };
  if (dx) { const t1 = (L0 - prev[0]) / dx, y1 = prev[1] + dy * t1; hit(t1, L0, y1, y1 >= T0 - 0.5 && y1 <= B0 + 0.5);
            const t2 = (R0 - prev[0]) / dx, y2 = prev[1] + dy * t2; hit(t2, R0, y2, y2 >= T0 - 0.5 && y2 <= B0 + 0.5); }
  if (dy) { const t1 = (T0 - prev[1]) / dy, x1 = prev[0] + dx * t1; hit(t1, x1, T0, x1 >= L0 - 0.5 && x1 <= R0 + 0.5);
            const t2 = (B0 - prev[1]) / dy, x2 = prev[0] + dx * t2; hit(t2, x2, B0, x2 >= L0 - 0.5 && x2 <= R0 + 0.5); }
  return best ? best[1] : end;
}

// ── Manual edges: 🔗 link mode ──────────────────────────────────────────────────
// The DAG is where a MISSING edge is visible (a table-creating cell and its readers sit
// disconnected), so the fix lives here: arm link mode with the 🔗 button in the pane header,
// then click one cell and click the other — the edge is asserted as a `needs=` tag on the
// downstream cell (the ordinary tag machinery persists it; the engine folds it into deps).
// Document order IS topological order, so any pair has exactly one legal direction — the
// gesture auto-directs, it cannot be drawn backward. While armed, clicking a dashed (manual)
// edge removes it. The mode STAYS armed for drawing several edges; Esc or 🔗 again exits.
let _dagLinkMode = false, _dagLinkSrc = null, _dagLinkHoverEdge = -1;
const _DAG_LINK_BASE = 'link mode — click two cells to connect (again to disconnect) · Esc exits';
function _dagLinkHint(msg) {
  let el = document.getElementById('daglinkhint');
  if (!msg) { el && el.remove(); return; }
  if (!el) {
    el = document.createElement('div'); el.id = 'daglinkhint';
    const pane = document.getElementById('dagpane'); if (!pane) return;
    pane.appendChild(el);
  }
  el.textContent = msg;
}
function dagLinkToggle() {
  _dagLinkMode = !_dagLinkMode; _dagLinkSrc = null; _dagLinkHoverEdge = -1;
  const b = document.getElementById('daglinkbtn'); b && b.classList.toggle('on', _dagLinkMode);
  _dagLinkHint(_dagLinkMode ? _DAG_LINK_BASE : null);
  _dagLinkPreview(null);
  _dagEdgeBump();                                          // repaint edges (delete-hover styling on/off)
  _dagLinkMode && _dagCardClose();
}
async function _dagSetNeeds(tgt, needs) {
  const c = _dagCtx && _dagCtx.m.byId[tgt]; if (!c) return;
  const tags = (c.tags || []).filter(t => !String(t).startsWith('needs='));
  needs = [...new Set(needs)];
  if (needs.length) tags.push('needs=' + needs.join(','));
  renderAll(await api('POST', '/api/tags/' + tgt, { tags }));
}
// Rubber-band preview while a source is armed: a dashed arrow from the armed cell to the
// hovered one, pointing the direction the edge WILL take (doc order decides — hover an earlier
// cell and the arrow points at YOUR cell). Violet = will connect · red = illegal pair (the
// earlier cell isn't code). An ALREADY-linked pair draws no phantom arrow — the EXISTING dashed
// edge lights up red + ✕ instead (same delete affordance as hovering the edge itself), because
// clicking will disconnect. NB `$action:'replace'` on every draw: after a graphic `remove`,
// re-adding the same id with the default merge action is silently ignored by ECharts — that
// exact quirk made the preview vanish for good after the first node-to-node move.
function _dagLinkPreview(id) {
  if (!_dagChart) return;
  const drop = () => { try { _dagChart.setOption({ graphic: [{ id: 'daglinkpv', $action: 'remove' }] }); } catch (_) {} };
  const unmark = () => { if (_dagLinkHoverEdge >= 0) { _dagLinkHoverEdge = -1; _dagEdgeBump(); } };
  if (!id || id === _dagLinkSrc || _dagLinkSrc == null || !_dagCtx) { drop(); unmark(); return; }
  const nd = x => _dagCtx.L.nodes.find(n => n.c.id === x);
  const a = nd(_dagLinkSrc), b = nd(id); if (!a || !b) { drop(); unmark(); return; }
  const di = _dagCtx.m.docIdx;
  const [s0, t0] = (di[a.c.id] ?? 0) < (di[b.c.id] ?? 0) ? [a, b] : [b, a];
  const sc = _dagCtx.m.byId[s0.c.id];
  const legal = sc && sc.kind === 'code';
  if (legal && (_dagCtx.m.byId[t0.c.id].needs || []).includes(s0.c.id)) {
    drop();                                                // linked pair → highlight the REAL edge
    const li = _dagCtx.L.links.findIndex(l => l.manual && l.s === s0.c.id && l.t === t0.c.id);
    if (li >= 0 && li !== _dagLinkHoverEdge) { _dagLinkHoverEdge = li; _dagEdgeBump(); }
    return;
  }
  unmark();
  let p1, p2;
  try {
    p1 = _dagChart.convertToPixel({ xAxisIndex: 0, yAxisIndex: 0 }, [s0.x, s0.y]);
    p2 = _dagChart.convertToPixel({ xAxisIndex: 0, yAxisIndex: 0 }, [t0.x, t0.y]);
  } catch (_) { drop(); return; }
  if (!p1 || !p2) { drop(); return; }
  const dx = p2[0] - p1[0], dy = p2[1] - p1[1], len = Math.hypot(dx, dy) || 1;
  const ux = dx / len, uy = dy / len;
  const q1 = [p1[0] + ux * 26, p1[1] + uy * 26], q2 = [p2[0] - ux * 30, p2[1] - uy * 30];
  const col = legal ? '#b39ddb' : _dagCtx.P.errored;
  const ah = 10, aw = 5, bx = q2[0] - ux * ah, by = q2[1] - uy * ah;
  try {
    _dagChart.setOption({ graphic: [{ id: 'daglinkpv', type: 'group', $action: 'replace', silent: true, children: [
      { type: 'line', shape: { x1: q1[0], y1: q1[1], x2: bx, y2: by },
        style: { stroke: col, lineWidth: 2.6, lineDash: [7, 5], opacity: 0.95 } },
      { type: 'polygon', shape: { points: [[q2[0], q2[1]], [bx - uy * aw, by + ux * aw], [bx + uy * aw, by - ux * aw]] },
        style: { fill: col, opacity: 0.95 } },
    ] }] });
  } catch (_) {}
}
function _dagLinkClick(id) {
  if (_dagLinkSrc == null) {
    _dagLinkSrc = id;
    _dagLinkHint('linking ' + id + ' — click the other cell');
    return;
  }
  const a = _dagLinkSrc; _dagLinkSrc = null; _dagLinkPreview(null);
  if (a === id || !_dagCtx) { _dagLinkHint(_DAG_LINK_BASE); return; }   // same cell twice → reset
  const di = _dagCtx.m.docIdx;
  const [src, tgt] = (di[a] ?? 0) < (di[id] ?? 0) ? [a, id] : [id, a];
  const sc = _dagCtx.m.byId[src];
  if (!sc || sc.kind !== 'code') {                        // only a code cell computes anything to wait for
    _dagLinkHint('only a code cell can be a dependency');
    setTimeout(() => _dagLinkMode && _dagLinkHint(_DAG_LINK_BASE), 2500);
    return;
  }
  _dagLinkHint(_DAG_LINK_BASE);                           // stay armed — draw the next edge
  const cur = _dagCtx.m.byId[tgt].needs || [];
  // Toggle: the same pair again REMOVES the manual edge (mirrors the preview's ✕).
  _dagSetNeeds(tgt, cur.includes(src) ? cur.filter(x => x !== src) : [...cur, src]);
}
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && _dagLinkMode) dagLinkToggle();
});

function _dagQueue() {
  if (!_dagOpen() || _dagRaf) return;
  _dagRaf = requestAnimationFrame(() => { _dagRaf = 0; _dagRender(); });
}

// Breathing loop while anything is running — ~25 fps, but it ONLY merges new
// [nodeIdx, phase] data into the halo series (same 2.4 s sinusoid as before).
// Nodes/edges are untouched between real state changes, so hovering never flickers.
function _dagBreatheApply() {
  if (!_dagChart || !_dagCtx) return;
  const phase = 0.5 + 0.5 * Math.sin((performance.now() % 2400) / 2400 * 2 * Math.PI);
  const data = [];
  _dagCtx.L.nodes.forEach((n, i) => { if (_dagState(n.c) === 'running') data.push([i, phase]); });
  try { _dagChart.setOption({ series: [{ id: 'dag-breath', data }] }); } catch (_) {}
}
function _dagPulseSync() {
  const need = () => (_dagRunning.size || _dagAnyRunning) && _dagOpen();
  if (need() && !_dagAnim) {
    const loop = () => {
      if (!need()) { _dagAnim = 0; _dagBreatheApply(); _dagQueue(); return; }   // clear halos + settle colors
      _dagBreatheApply();
      _dagAnim = setTimeout(() => requestAnimationFrame(loop), 40);
    };
    _dagAnim = 1; requestAnimationFrame(loop);
  }
}

// Dock side — right (deep TB graphs) or bottom (wide LR graphs); persisted. The auto
// layout direction follows the pane shape, so re-docking flips the layout by itself.
let _dagDock = (() => { try { return localStorage.getItem('slateDagDock') || 'right'; } catch (_) { return 'right'; } })();
function dagDock() {
  _dagDock = _dagDock === 'right' ? 'bottom' : 'right';
  try { localStorage.setItem('slateDagDock', _dagDock); } catch (_) {}
  _dagApplyDock();
  _dagReflowCharts();                                // dock flip reflows the whole notebook column
  dagFit();
}
function _dagApplyDock() {
  const p = document.getElementById('dagpane');
  p.classList.toggle('dock-right', _dagDock === 'right');
  p.classList.toggle('dock-bottom', _dagDock === 'bottom');
  document.body.classList.toggle('dag-right', _dagDock === 'right');
  document.body.classList.toggle('dag-bottom', _dagDock === 'bottom');
  const b = document.getElementById('dagdock');
  if (b) {
    b.textContent = _dagDock === 'right' ? '◨' : '⬓';
    b.title = _dagDock === 'right' ? 'docked right — click to dock at the bottom' : 'docked at the bottom — click to dock right';
  }
}

function toggleDag() {
  // The page reflows when the pane opens/closes (its width changes) — anchor the
  // top-most visible cell so the reader's place in the notebook doesn't drift.
  let anchor = null, off = 0;
  for (const el of document.querySelectorAll('#nb .cell')) {
    const r = el.getBoundingClientRect();
    if (r.bottom > 70) { anchor = el; off = r.top; break; }
  }
  const p = document.getElementById('dagpane');
  const open = p.classList.toggle('open');
  document.body.classList.toggle('dag-open', open);          // the notebook reflows around the pane
  if (anchor) requestAnimationFrame(() => {
    const r = anchor.getBoundingClientRect();
    Math.abs(r.top - off) > 1 && window.scrollBy(0, r.top - off);
  });
  _dagReflowCharts();                                        // the notebook column changed width
  if (open) requestAnimationFrame(_dagRender);               // after the pane lays out (sizes valid)
  else { _dagCardClose(); _dagPulseSync(); }
  _dagRoutesPoll(open && _dagRegionsOn);                     // region-routing poll rides the pane's open state
}
// The pane reflows the notebook column, but only window.resize normally re-measures the
// NOTEBOOK's chart instances — nudge them (and again post-layout) or they keep stale canvases.
function _dagReflowCharts() {
  const heal = () => Object.values(window.charts || {}).flat().forEach(inst => {
    try { const d = inst.getDom && inst.getDom(); if (d && d.isConnected) inst.resize(); } catch (_) {}
  });
  requestAnimationFrame(heal);
  setTimeout(heal, 260);
}
function dagFit() {
  _dagLayoutKey = '';                                        // force re-layout
  if (_dagChart) { _dagChart.dispose(); _dagChart = null; }
  _dagRender();
}

// Live wiring — CHAIN the existing hooks (runstatus.js owns onCellRun/onCellDone).
(() => {
  const prevRun = window.onCellRun, prevDone = window.onCellDone;
  window.onCellRun = id => { prevRun && prevRun(id); _dagRunning.add(id); _dagQueue(); _dagPulseSync(); };
  window.onCellDone = c => { prevDone && prevDone(c); _dagRunning.delete(c.id); delete _dagEcThumbs[c.id]; _dagQueue(); _dagPulseSync(); };
  window.onNbState = () => { _dagRunning.clear(); _dagQueue(); };      // full publish — structure may have changed
  window.onCellsPatched = cells => {                                   // targeted refresh — states/durations moved
    (cells || []).forEach(c => delete _dagEcThumbs[c.id]);             // chart may have re-rendered → re-snapshot
    _dagQueue();
  };
  // Live worker/region aliveness pushed over the WS (workers.js onWorkersUpdate) → refresh the region
  // header dots (and any open region card) without waiting for the next full notebook state.
  window._dagOnWorkers = ws => {
    _dagWorkersLive = ws || [];
    if (!_dagOpen()) return;
    _dagQueue();                                                       // repaint the header dots
    if (_dagRegCardName) {                                             // refresh the open card in place (no _dagCtx timing dep)
      const w = _dagRegionWorker(_dagRegCardName);
      _dagRegCardShow({ name: _dagRegCardName, isLocal: false, host: (w && w.host) || _dagRegionHost(_dagRegCardName),
                        worker: w, wstatus: _dagWorkerStatus(w) });
    }
  };
  window.addEventListener('resize', debounce(() => { if (_dagOpen() && _dagChart) { _dagChart.resize(); _dagQueue(); } }, 150));
})();

// Esc closes (card first, then the pane); selecting a cell highlights its node.
(() => {
  _dagDirBtn(); _dagHeatBtn(); _dagRegionsBtn();    // reflect persisted preferences
  document.addEventListener('click', () => {        // ⚙ popover closes on outside click
    const gp = document.getElementById('daggearpop'); if (gp) gp.classList.remove('open');
  });
  // Gentle wheel zoom, anchored on the cursor — ECharts' built-in rate is fixed and too
  // hot, so its wheel handling is off (zoomOnMouseWheel:false) and we drive dataZoom
  // ourselves. CAPTURE phase on the PANE: fires before zrender's canvas handlers, and
  // survives chart dispose/re-init. exp(-ΔY·k) is mild per tick and continuous for
  // trackpad pixel deltas; both axes get the same factor → aspect stays locked.
  const paneEl = document.getElementById('dagpane');
  if (paneEl) paneEl.addEventListener('wheel', e => {
    if (!_dagChart || !_dagOpen()) return;
    if (e.target.closest && e.target.closest('.dagcard, .daghelppop, .aphead')) return;   // cards/menus scroll normally
    e.preventDefault(); e.stopPropagation();
    const f = Math.exp(-e.deltaY * 0.0016);
    const o = _dagChart.getOption(); if (!o || !o.dataZoom || o.dataZoom.length < 2) return;
    const r = document.getElementById('dagcanvas').getBoundingClientRect();
    const apply = (z, frac, idx) => {
      const span = z.end - z.start;
      const ns = Math.max(0.5, Math.min(100, span / f));
      const pivot = z.start + span * Math.max(0, Math.min(1, frac));
      let s = pivot - ns * frac, en = s + ns;
      if (s < 0) { en -= s; s = 0; }
      if (en > 100) { s = Math.max(0, s - (en - 100)); en = 100; }
      _dagChart.dispatchAction({ type: 'dataZoom', dataZoomIndex: idx, start: s, end: en });
    };
    apply(o.dataZoom[0], (e.clientX - r.left) / r.width, 0);
    apply(o.dataZoom[1], (e.clientY - r.top) / r.height, 1);
  }, { passive: false, capture: true });
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape') return;
    // Esc that ORIGINATED in an editor/input belongs to IT (exit to command mode) — the
    // editor may already have blurred by the time this bubbles, so check the event's
    // target (not activeElement) and respect a handled event.
    if (e.defaultPrevented) return;
    const t = e.target;
    if (t && t.closest && t.closest('.cm-editor, input, textarea, [contenteditable]')) return;
    if (_dagCardEl()) { _dagCardClose(); return; }
    if (_dagOpen()) toggleDag();
  });
  const prevSel = window.selectCell;
  if (prevSel) window.selectCell = (id, scroll) => { prevSel(id, scroll); _dagHighlight(id); };
})();

// The divider: drag to resize the split (persisted per dock side). The notebook reflows
// live via --dagw/--dagh; the chart letterboxes while dragging and re-fits on release.
(() => {
  const pane = document.getElementById('dagpane'), grip = document.getElementById('daggrip');
  if (!pane || !grip) return;
  try { const w = localStorage.getItem('slateDagW'); if (w) document.body.style.setProperty('--dagw', w); } catch (_) {}
  try { const h = localStorage.getItem('slateDagH'); if (h) document.body.style.setProperty('--dagh', h); } catch (_) {}
  _dagApplyDock();                                   // reflect the persisted dock side on load
  let raf = 0;
  const move = e => {
    if (_dagDock === 'right') {
      const w = Math.max(340, Math.min(window.innerWidth * 0.78, window.innerWidth - e.clientX));
      document.body.style.setProperty('--dagw', w + 'px');
    } else {
      const h = Math.max(180, Math.min(window.innerHeight * 0.8, window.innerHeight - e.clientY));
      document.body.style.setProperty('--dagh', h + 'px');
    }
    if (!raf) raf = requestAnimationFrame(() => { raf = 0; _dagChart && _dagChart.resize(); });
  };
  const up = () => {
    grip.classList.remove('on');
    document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up);
    document.body.style.userSelect = '';
    try {
      if (_dagDock === 'right') localStorage.setItem('slateDagW', document.body.style.getPropertyValue('--dagw'));
      else localStorage.setItem('slateDagH', document.body.style.getPropertyValue('--dagh'));
    } catch (_) {}
    _dagReflowCharts();                              // the notebook column changed width too
    dagFit();                                        // re-layout for the new aspect
  };
  grip.addEventListener('pointerdown', e => {
    e.preventDefault(); grip.classList.add('on');
    document.body.style.userSelect = 'none';         // don't select notebook text while dragging
    document.addEventListener('pointermove', move); document.addEventListener('pointerup', up);
  });
})();
