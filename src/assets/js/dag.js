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
    const r = _dagDeclaredRegions().find(x => x.host === st.ranOn);   // ranOn is the HOST → map back to the region NAME
    return r ? r.name : st.ranOn;
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
function _dagRegionLegend() {
  const pane = document.getElementById('dagpane') || document.getElementById('dag');
  let el = document.getElementById('dagregleg');
  if (!_dagRegionsOn || !pane) { if (el) el.remove(); return; }
  if (!el) { el = document.createElement('div'); el.id = 'dagregleg'; el.className = 'dagregleg'; pane.appendChild(el); }
  el.innerHTML = `<span><i style="background:#3a3f55"></i>main (local)</span>` +
    _dagRegionNamesAll().map(n => `<span><i style="background:${_dagRegionHue(n)}"></i>${n === 'default' ? 'remote' : n}</span>`).join('');
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

// Region ZONES for the DAG: a hull around each region's member cells (a compute-env container you
// can see the subgraph forming inside), plus a placeholder box for a declared-but-empty region so
// there's somewhere to aim cells. Coords are in layout space (same as nodes) → api.coord() in the
// renderItem maps them to pixels. Members can interleave with local flow; the hull just bounds them.
// Partitioned layout: with regions active, the WHOLE canvas splits into side-by-side columns —
// `local` (main kernel) first, then one per region — each laid out independently and tiled left to
// right. Dragging a cell between columns moves it to that compute env; cross-column edges are the
// boundary transfers. Recomputed per render (dagre per column); notebooks with regions are modest.
function _dagPartitionedLayout(m, w, h) {
  const assigned = m.nodes.map(_dagAssignedRegion).filter(Boolean);
  const sides = ['', ...new Set([..._dagDeclaredRegions().map(r => r.name), ...assigned])];   // local + declared ∪ assigned
  const COLGAP = 56, PAD = 18, HEAD = 30, MINW = 156, MINH = 130;
  let xOff = 0;
  const nodes = [], parts = [], linkPts = {};
  sides.forEach(side => {
    const sub = m.nodes.filter(c => _dagAssignedRegion(c) === side);   // group by ASSIGNMENT (tags), not where it ran
    const ids = new Set(sub.map(c => c.id));
    const subLinks = m.links.filter(l => ids.has(l.source) && ids.has(l.target));
    let colW = MINW, colH = MINH;
    if (sub.length) {
      const subL = _dagLayout({ nodes: sub, links: subLinks, byId: m.byId, layers: [], layer: {}, slot: {} }, 440, h, 'TB');
      let minx = Infinity, miny = Infinity, maxx = -Infinity, maxy = -Infinity;
      subL.nodes.forEach(n => { minx = Math.min(minx, n.x - n.b.w / 2); miny = Math.min(miny, n.y - n.b.h / 2); maxx = Math.max(maxx, n.x + n.b.w / 2); maxy = Math.max(maxy, n.y + n.b.h / 2); });
      colW = Math.max(MINW, maxx - minx); colH = Math.max(MINH - HEAD, maxy - miny);
      const tx = xOff + PAD - minx, ty = HEAD + PAD - miny;
      subL.nodes.forEach(n => nodes.push({ c: n.c, b: n.b, x: n.x + tx, y: n.y + ty }));
      subL.links.forEach(l => { if (l.pts) linkPts[l.s + '>' + l.t] = l.pts.map(p => [p[0] + tx, p[1] + ty]); });
    }
    const fullW = colW + 2 * PAD;
    parts.push({ side, x0: xOff, y0: 0, x1: xOff + fullW, y1: HEAD + colH + 2 * PAD, empty: sub.length === 0 });
    xOff += fullW + COLGAP;
  });
  const maxY = Math.max(...parts.map(p => p.y1), MINH);
  parts.forEach(p => { p.y1 = maxY; });                 // columns share the tallest height → full-height bands
  const links = m.links.map(l => ({ s: l.source, t: l.target, dim: l.dim, manual: l.manual,
                                    pts: linkPts[l.source + '>' + l.target] || null }));   // cross-column → null → straight
  return { nodes, links, gw: Math.max(xOff - COLGAP, MINW), gh: maxY, partitions: parts };
}
// Partitions → zone rectangles for rendering + drop hit-testing. `local` is included (neutral tint);
// dropping a cell there un-tags it.
function _dagPartitionZones(parts) {
  return parts.map(p => ({
    name: p.side, isLocal: p.side === '',
    host: p.side === '' ? '' : _dagRegionHost(p.side),
    hue: p.side === '' ? '#586089' : (_dagRegionHue(p.side) || '#5a6a90'),
    x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1, empty: p.empty,
  }));
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
  L.links.forEach(l => {
    if (l.pts) return;
    const a = ndOf[l.s], z = ndOf[l.t];
    if (!a || !z) { l.pts = [[0, 0], [0, 0]]; return; }
    const dx = z.x - a.x, dy = z.y - a.y;
    const clip = n => Math.min(dx ? Math.abs((n.b.w / 2 + 5) / dx) : 9, dy ? Math.abs((n.b.h / 2 + 5) / dy) : 9, 0.45);
    const tA = clip(a), tB = clip(z);
    l.pts = [[a.x + dx * tA, a.y + dy * tA], [z.x - dx * tB, z.y - dy * tB]];
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

  return {
    animation: false,
    tooltip: {
      show: !_dagCardEl(), trigger: 'item', confine: true, backgroundColor: P.bg, borderColor: P.border,
      textStyle: { color: P.text, fontSize: 12 }, extraCssText: 'max-width:340px; white-space:normal;',
      formatter: p => p.seriesName === 'nodes' ? nodeTip(p.dataIndex) : edgeTip(p.dataIndex),
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
          return { type: 'group', children: kids };
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
          const op = del ? 1
                   : hv ? (hv.d === 1 ? 0.98 : Math.max(0.3, 0.62 - 0.12 * (hv.d - 2)))
                   : faded ? (l.dim ? 0.04 : 0.15) : l.dim ? 0.12 : hot ? 0.95 : 0.6;
          // Decimate waypoints (Douglas-Peucker): keep endpoints + genuine detours, drop
          // micro-wiggles — the spline relaxes into longer arcs but still dodges nodes.
          const pts = _dagRdp(l.pts.map(p => api.coord(p)), 18);
          const n = pts.length;
          let x1 = pts[n - 2][0], y1 = pts[n - 2][1];
          const x2 = pts[n - 1][0], y2 = pts[n - 1][1];
          const style = { fill: 'none', stroke: col, lineWidth: lw, opacity: op };
          if (l.manual) style.lineDash = [6, 4];       // user-asserted (`needs=`) — an assertion, not derived dataflow
          const kids = [];
          if (!l.dim && n === 2) {
            // no detour → the canonical SYMMETRIC S: leave the source square along the flow
            // axis, inflect at the midpoint, arrive square — tangents vertical in TB.
            const s0 = pts[0], k = 0.45;
            const shp = tb
              ? { x1: s0[0], y1: s0[1], cpx1: s0[0], cpy1: s0[1] + k * (y2 - s0[1]),
                  cpx2: x2, cpy2: y2 - k * (y2 - s0[1]), x2, y2 }
              : { x1: s0[0], y1: s0[1], cpx1: s0[0] + k * (x2 - s0[0]), cpy1: s0[1],
                  cpx2: x2 - k * (x2 - s0[0]), cpy2: s0[1], x2, y2 };
            kids.push({ type: 'bezierCurve', style, shape: shp });
            x1 = shp.cpx2; y1 = shp.cpy2;             // arrow follows the arrival tangent
          } else if (n === 2) {
            kids.push({ type: 'line', shape: { x1: pts[0][0], y1: pts[0][1], x2, y2 }, style });
          } else {
            const Pp = [pts[0], pts[0], ...pts, pts[n - 1], pts[n - 1]];
            for (let i = 0; i + 3 < Pp.length; i++) {
              const a1 = Pp[i + 1], a2 = Pp[i + 2], a3 = Pp[i + 3];
              const sx2 = (a1[0] + 4 * a2[0] + a3[0]) / 6, sy2 = (a1[1] + 4 * a2[1] + a3[1]) / 6;
              const px2 = i === 0 ? pts[0][0] : (Pp[i][0] + 4 * a1[0] + a2[0]) / 6;
              const py2 = i === 0 ? pts[0][1] : (Pp[i][1] + 4 * a1[1] + a2[1]) / 6;
              kids.push({ type: 'bezierCurve', style, shape: {
                x1: px2, y1: py2,
                cpx1: (2 * a1[0] + a2[0]) / 3, cpy1: (2 * a1[1] + a2[1]) / 3,
                cpx2: (a1[0] + 2 * a2[0]) / 3, cpy2: (a1[1] + 2 * a2[1]) / 3,
                x2: sx2, y2: sy2 } });
            }
          }
          const len = Math.hypot(x2 - x1, y2 - y1) || 1, ux = (x2 - x1) / len, uy = (y2 - y1) / len;
          const ah = 7, aw = 3.4, bx = x2 - ux * ah, by = y2 - uy * ah;
          kids.push({ type: 'polygon', shape: { points: [[x2, y2], [bx - uy * aw, by + ux * aw], [bx + uy * aw, by - ux * aw]] },
            style: { fill: col, opacity: Math.min(1, op + 0.1) } });
          if (del) {   // ✕ badge at the edge's midpoint — "click deletes this edge"
            const m = n === 2 ? [(pts[0][0] + x2) / 2, (pts[0][1] + y2) / 2] : pts[Math.floor(n / 2)];
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
      if (!_dagDrag) return;
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
    ['last', _dagFmtMs(st.last_ms) + (st.memo ? ` ${st.memo === 'restored' ? '♻' : st.memo === 'handle' ? '🔌' : '💾'}` : '') + ` · ${_dagAgo(st.last_ts)}`],
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
    (st && st.memo === 'handle' ? `<div class="dagcard-dim">🔌 produces a LIVE HANDLE (a DB / socket / file) — it isn’t cached (a restore would hand back a dangling pointer) and it can’t cross a region boundary. Tag this cell <code>resource</code> so each side — and each restore — opens its own.</div>` : '') +
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
