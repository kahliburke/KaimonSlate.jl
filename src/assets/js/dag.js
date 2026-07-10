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

  const links = [];
  nodes.forEach(c => (byId[c.id].deps || []).forEach(d => {
    if (!inc.has(d)) return;
    links.push({ source: d, target: c.id, dim: setup.has(d) });   // dim: drawn faint, ignored by layout
  }));
  if (!_dagIsoOn) {
    // isolated cells (no edges at all once setup is filtered — e.g. a theme cell) hide too;
    // a dropped node had no links, so the link list stays valid
    const t2 = new Set();
    links.forEach(l => { t2.add(l.source); t2.add(l.target); });
    nodes = nodes.filter(c => t2.has(c.id));
  }
  return { nodes, links, layer, slot, layers, byId, setup };
}

// Block metrics — one source of truth for layout (dagre needs each node's box) and
// paint (drawn size must match or blocks overlap).
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
    if (m2) thumb = m2[1];
  }
  const dur = c.duration == null ? '' : _dagFmtMs(c.duration);
  const icon = _DAG_KINDS[kind].icon;
  const row1 = (icon ? icon + ' ' : '') + c.id;
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

function _dagState(c) { return _dagRunning.has(c.id) ? 'running' : (c.state || 'stale'); }
const _dagCost = c => (c.stats && c.stats.total_ms) || c.duration || 0;

// Layout → {nodes:[{c,b,x,y}], links:[{s,t,pts}], gw, gh}. With dagre: real Sugiyama
// (crossing minimization) AND routed edge waypoints (g.edge().points — around nodes,
// border to border). Fallback (dagre.min.js not yet cached): hand layering, straight edges.
function _dagLayout(m, w, h, dir) {
  const tb = dir === 'TB';
  if (window.dagre) {
    // Nodes whose EVERY edge is dim (the setup island: using/import hubs + their
    // satellites) leave dagre entirely and stack in a compact left column — dagre lays
    // disconnected components side by side, which would spend the width the hub-edge
    // removal just saved.
    const aside = new Set();
    m.nodes.forEach(c => {
      // aside: every incident edge is a whisper — OR no edges at all (an isolated node
      // handed to dagre becomes its own side-by-side component and widens the graph)
      const es = m.links.filter(l => l.source === c.id || l.target === c.id);
      if (es.every(l => l.dim)) aside.add(c.id);
    });
    const g = new dagre.graphlib.Graph();
    g.setGraph({ rankdir: dir, ranker: 'tight-tree',
                 ranksep: tb ? 38 : 52, nodesep: tb ? 14 : 18, edgesep: 10, marginx: 16, marginy: 14 });
    g.setDefaultEdgeLabel(() => ({}));
    m.nodes.forEach(c => {
      if (aside.has(c.id)) return;
      const b = _dagBlock(c); g.setNode(c.id, { width: b.w + 6, height: b.h + 6 });
    });
    m.links.forEach(l => {
      if (!l.dim && !aside.has(l.source) && !aside.has(l.target)) g.setEdge(l.source, l.target);
    });
    dagre.layout(g);
    const gr = g.graph();
    // Aside nodes sit in a ROW ABOVE the flow (vertical growth is cheap in a tall pane;
    // a side column would spend the width the hub-edge removal saved).
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
    let links = m.links.map(l => {
      const e = (!l.dim && g.hasEdge(l.source, l.target)) ? g.edge(l.source, l.target) : null;
      return { s: l.source, t: l.target, dim: l.dim,
               pts: (e && e.points && e.points.length > 1) ? e.points.map(p => [p.x, p.y + rowH]) : null };
    });
    let gw = Math.max(gr.width || w, ax), gh = (gr.height || h) + rowH;
    // TB rank WRAPPING: a rank wider than the pane forces a tiny fit scale and strands
    // the tall pane's vertical space. Pack each over-wide rank into stacked rows (dagre's
    // x-order preserved → low crossing), trading width for depth. Node positions move,
    // so routed edge points are dropped — edges re-render as border-clipped straight
    // lines (see _dagOption's fallback).
    if (tb) {
      const budget = Math.max(w - 24, 420);
      const main = nodes.filter(n => !aside.has(n.c.id));
      const byRank = new Map();
      main.forEach(n => { const k2 = Math.round(n.y); byRank.has(k2) || byRank.set(k2, []); byRank.get(k2).push(n); });
      const ranks = [...byRank.keys()].sort((a, b) => a - b).map(k2 => byRank.get(k2));
      const width = row => row.reduce((s2, n) => s2 + n.b.w + 14, -14);
      if (ranks.some(r => width(r) > budget)) {
        let cursor = rowH + 14, maxW = 0;
        ranks.forEach(rank => {
          rank.sort((a, b) => a.x - b.x);
          const rows = [[]]; let cw = 0;
          rank.forEach(n => {
            if (cw + n.b.w + 14 > budget && rows[rows.length - 1].length) { rows.push([]); cw = 0; }
            rows[rows.length - 1].push(n); cw += n.b.w + 14;
          });
          rows.forEach(row => {
            const rw = width(row), rh = Math.max(...row.map(n => n.b.h));
            let x = -rw / 2;
            row.forEach(n => { n.x = x + n.b.w / 2; n.y = cursor + rh / 2; x += n.b.w + 14; });
            maxW = Math.max(maxW, rw);
            cursor += rh + 16;
          });
          cursor += 22;                              // rank separation
        });
        const cx2 = maxW / 2 + 12;
        main.forEach(n => { n.x += cx2; });          // recenter into positive coords
        links = links.map(l => ({ ...l, pts: null }));
        gw = Math.max(maxW + 24, ax); gh = cursor;
      }
    }
    return { nodes, links, gw, gh };
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
    links: m.links.map(l => ({ s: l.source, t: l.target, dim: l.dim, pts: [pos[l.source], pos[l.target]] })),
    gw: w, gh: h,
  };
}

// Memoized layout — the breathing animation re-paints ~25×/s; dagre must not re-run
// unless the graph actually changed (nodes, block dims, links, direction, canvas).
let _dagLayoutKey = '', _dagLayoutVal = null;
function _dagLayoutCached(m, w, h, dir) {
  const key = 'v5|' + (_dagSetupOn ? 'S' : 's') + (_dagIsoOn ? 'I|' : 'i|') + dir + '|' + w + 'x' + h + '|' +
    m.nodes.map(c => { const b = _dagBlock(c); return c.id + ':' + (b.w | 0) + ':' + b.h; }).join(',') + '|' +
    m.links.map(l => l.source + (l.dim ? '~' : '>') + l.target).join(',');   // dim-ness shapes the layout
  if (key !== _dagLayoutKey || !_dagLayoutVal) { _dagLayoutKey = key; _dagLayoutVal = _dagLayout(m, w, h, dir); }
  return _dagLayoutVal;
}

function _dagOption() {
  const st = window.__slateState; if (!st) return null;
  const m = _dagModel(st.cells || []);
  const el = document.getElementById('dagcanvas');
  const w = el.clientWidth || 800, h = el.clientHeight || 400;
  const dir = _dagDir(w, h);
  const L = _dagLayoutCached(m, w, h, dir);
  // The memoized layout captured cell OBJECTS as they were at layout time; a celldone patch
  // swaps fresh objects into nbState (new state/duration/stats). Re-bind every node to the
  // CURRENT cell so geometry is reused but state/text are never stale. (Cell state is
  // deliberately not in the layout key — a state flip must not re-run dagre.)
  L.nodes.forEach(n => { const cur = m.byId[n.c.id]; if (cur) { n.c = cur; n.b = _dagBlock(cur); } });
  const P = _dagPalette();
  // Edge fallback (wrapped ranks, whisper edges): S-CURVES that leave the source's
  // outflow border and enter the target's inflow border (bottom→top in TB), so edges
  // keep the routed look — smooth, arrowheads landing square on the border — even
  // when node positions came from rank-wrapping rather than dagre.
  const tb = dir === 'TB';
  const ndOf = {}; L.nodes.forEach(n => { ndOf[n.c.id] = n; });
  L.links.forEach(l => {
    if (l.pts) return;
    const a = ndOf[l.s], z = ndOf[l.t];
    if (!a || !z) { l.pts = [[0, 0], [0, 0]]; return; }
    const fwd = tb ? z.y - z.b.h / 2 > a.y + a.b.h / 2 : z.x - z.b.w / 2 > a.x + a.b.w / 2;
    if (tb && fwd) {
      const sy = a.y + a.b.h / 2, ty = z.y - z.b.h / 2;
      const bend = Math.max(10, Math.min(30, (ty - sy) * 0.3));
      l.pts = [[a.x, sy], [a.x, sy + bend], [z.x, ty - bend], [z.x, ty]];
    } else if (!tb && fwd) {
      const sx = a.x + a.b.w / 2, tx = z.x - z.b.w / 2;
      const bend = Math.max(10, Math.min(30, (tx - sx) * 0.3));
      l.pts = [[sx, a.y], [sx + bend, a.y], [tx - bend, z.y], [tx, z.y]];
    } else {
      // non-forward (rare: aside/whisper geometry) — border-clipped straight segment
      const dx = z.x - a.x, dy = z.y - a.y;
      const clip = n => Math.min(dx ? Math.abs((n.b.w / 2 + 5) / dx) : 9, dy ? Math.abs((n.b.h / 2 + 5) / dy) : 9, 0.45);
      const tA = clip(a), tB = clip(z);
      l.pts = [[a.x + dx * tA, a.y + dy * tA], [z.x - dx * tB, z.y - dy * tB]];
    }
  });
  const stOf = id => _dagState(m.byId[id]);
  _dagAnyRunning = m.nodes.some(c => _dagState(c) === 'running');
  _dagCtx = { m, L, P };
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
    if (c.stats) rows.push(`<span style="color:${P.dim}">Σ ${_dagFmtMs(c.stats.total_ms)} · ×${c.stats.evals}${c.stats.pulls ? ` · ↓${c.stats.pulls}` : ''}</span>`);
    return rows.join('<br>');
  };
  const edgeTip = i => _dagCardEl() ? '' : `${L.links[i].s} → ${L.links[i].t}`;

  // Aspect-preserving axis ranges: pad the shorter direction so one graph unit is the
  // same number of pixels on both axes (blocks keep their shape), graph centered.
  // Then add SLACK beyond the fit window on every side — inside-dataZoom clamps its
  // window to the axis extent, so without slack there is nothing to pan at full fit.
  // The initial dataZoom start/end percentages select exactly the centered fit window.
  const u = Math.max(L.gw / w, L.gh / h, 0.0001);
  const exX = (w * u - L.gw) / 2, exY = (h * u - L.gh) / 2;
  const mX = 0.6 * w * u, mY = 0.6 * h * u;                    // pan slack (60% of a viewport per side)
  const totX = L.gw + 2 * exX + 2 * mX, totY = L.gh + 2 * exY + 2 * mY;
  const zx = [mX / totX * 100, (mX + L.gw + 2 * exX) / totX * 100];
  const zy = [mY / totY * 100, (mY + L.gh + 2 * exY) / totY * 100];

  return {
    animation: false,
    tooltip: {
      show: !_dagCardEl(), trigger: 'item', confine: true, backgroundColor: P.bg, borderColor: P.border,
      textStyle: { color: P.text, fontSize: 12 }, extraCssText: 'max-width:340px; white-space:normal;',
      formatter: p => p.seriesName === 'nodes' ? nodeTip(p.dataIndex) : edgeTip(p.dataIndex),
    },
    grid: { left: 0, right: 0, top: 0, bottom: 0 },
    xAxis: { type: 'value', min: -exX - mX, max: L.gw + exX + mX, show: false },
    yAxis: { type: 'value', min: -exY - mY, max: L.gh + exY + mY, show: false, inverse: true },   // dagre's y grows DOWN
    dataZoom: [
      // wheel zoom is handled by our own listener (ECharts' rate is fixed and too hot) —
      // the inside zooms provide drag-pan + the programmatic window
      { type: 'inside', xAxisIndex: 0, filterMode: 'none', start: zx[0], end: zx[1],
        zoomOnMouseWheel: false, moveOnMouseMove: true, moveOnMouseWheel: false },
      { type: 'inside', yAxisIndex: 0, filterMode: 'none', start: zy[0], end: zy[1],
        zoomOnMouseWheel: false, moveOnMouseMove: true, moveOnMouseWheel: false },
    ],
    series: [
      { // edges under nodes — dagre's routed waypoints, smoothed, with an arrowhead at the target border
        type: 'custom', id: 'dag-edges', name: 'edges', coordinateSystem: 'cartesian2d', z: 1,
        data: L.links.map((_, i) => [i]),
        renderItem: (params, api) => {
          const l = L.links[params.dataIndex];
          // hot ONLY when the SOURCE is computing (its result will flow out along this edge) —
          // a running leaf must not light up its inbound edges. Edges live in their own violet
          // family; only an errored source overrides (red). Setup edges (using/import — every
          // cell has one) are background whispers: faint, thin, no layout influence.
          const s = stOf(l.s), hot = !l.dim && s === 'running';
          const col = s === 'errored' ? P.errored : hot ? P.edgeHot : P.edge;
          const pts = l.pts.map(p => api.coord(p));
          const n = pts.length, x1 = pts[n - 2][0], y1 = pts[n - 2][1], x2 = pts[n - 1][0], y2 = pts[n - 1][1];
          const len = Math.hypot(x2 - x1, y2 - y1) || 1, ux = (x2 - x1) / len, uy = (y2 - y1) / len;
          const ah = 7, aw = 3.4, bx = x2 - ux * ah, by = y2 - uy * ah;
          return { type: 'group', children: [
            { type: 'polyline', shape: { points: pts.slice(0, -1).concat([[bx, by]]), smooth: 0.22 },
              style: { fill: 'none', stroke: col, lineWidth: l.dim ? 0.8 : hot ? 2.4 : 1.4,
                       opacity: l.dim ? 0.12 : hot ? 0.95 : 0.6 } },
            { type: 'polygon', shape: { points: [[x2, y2], [bx - uy * aw, by + ux * aw], [bx + uy * aw, by - ux * aw]] },
              style: { fill: col, opacity: l.dim ? 0.15 : hot ? 0.95 : 0.7 } },
          ] };
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
          const baseFill = _dagHeatOn ? _dagRamp(heatT(c)) : P.bg3;   // uniform card; the wedge carries the type
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
    _dagChart.on('click', p => {
      if (!_dagCtx || p.seriesName !== 'nodes') return;
      const id = _dagCtx.L.nodes[p.dataIndex].c.id;
      window.selectCell && selectCell(id, false);
      const raw = p.event && p.event.event;
      if (raw && raw.shiftKey) { _dagJump(id); return; }     // ⇧-click → navigate the editor
      _dagCard(id, p.event ? p.event.offsetX : 0, p.event ? p.event.offsetY : 0);   // click → details card
    });
    _dagChart.getZr().on('click', e => { if (!e.target) _dagCardClose(); });        // empty canvas → dismiss
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
  if (kind === 'chart') return '<div class="dagcard-dim">interactive chart — open the cell to explore it</div>';
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
  let err = '';
  if (s === 'errored' && c.output) {
    const t = document.createElement('div'); t.innerHTML = c.output;
    err = (t.textContent || '').trim().split('\n').filter(x => x.trim()).slice(0, 4).join('\n').slice(0, 400);
  }
  const prev = _dagPreview(c, kind);
  // Condensed stats — four chips carry what matters; the strip shows the shape.
  const st = c.stats;
  const chips = st ? [
    ['last', _dagFmtMs(st.last_ms) + (st.memo ? ` ${st.memo === 'restored' ? '♻' : '💾'}` : '') + ` · ${_dagAgo(st.last_ts)}`],
    ['typical', `${_dagFmtMs(st.mean_ms)} ± ${_dagFmtMs(st.std_ms)}`],
    ['total', `${_dagFmtMs(st.total_ms)} · ×${st.evals}${st.restores ? ` ♻${st.restores}` : ''}`],
    ['used downstream', `↓ ${st.pulls}`],
  ] : [];
  const defs = c.defs || [];
  const card = document.createElement('div');
  card.id = 'dagcard'; card.className = 'dagcard';
  card.innerHTML =
    `<div class="dagcard-h" style="border-left-color:${K.hue}">` +
      `<span class="dagcard-kico">${K.icon || '·'}</span><b class="dagcard-jump" title="jump to this cell in the notebook">${_esc(c.id)}</b>` +
      `<span class="dagcard-st" style="color:${_dagColor(P, s)}">${s}</span>` +
      `<span class="dagcard-kind" style="color:${K.hue}">${kind}</span></div>` +
    (err ? `<pre class="dagcard-err">${_esc(err)}</pre>` : '') +
    (prev ? `<div class="dagcard-sec">output</div>${prev}` : '') +
    (chips.length
      ? '<div class="dagcard-grid">' + chips.map(([k, v]) =>
          `<div class="dagchip"><span>${k}</span><b>${_esc(String(v))}</b></div>`).join('') + '</div>'
      : `<div class="dagcard-dim">no runs recorded this session yet</div>`) +
    (st ? _dagSpark(st.recent, P) : '') +
    (defs.length ? `<div class="dagcard-sec">defines (${defs.length})</div><div class="dagcard-defs">` +
      `${_esc(defs.slice(0, 12).join(', '))}${defs.length > 12 ? ` … +${defs.length - 12} more` : ''}</div>` : '') +
    ((c.tags || []).length ? `<div class="dagcard-sec">tags</div><div class="dagcard-defs">🏷 ${_esc(c.tags.join(', '))}</div>` : '') +
    '<div class="dagcard-acts">' +
      '<button data-act="run" title="force re-evaluate this cell and its dependents">▶ Run</button>' +
      `<button data-act="cache" title="${cache ? 'stop persisting this cell’s result' : 'always persist this cell’s result (pipeline stage)'}">${cache ? '💾 Uncache' : '💾 Cache'}</button>` +
    '</div>';
  document.body.appendChild(card);   // viewport-centered (CSS) — big enough to read, above the pane
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
  const p = document.getElementById('dagpane');
  const open = p.classList.toggle('open');
  document.body.classList.toggle('dag-open', open);          // the notebook reflows around the pane
  if (open) requestAnimationFrame(_dagRender);               // after the pane lays out (sizes valid)
  else { _dagCardClose(); _dagPulseSync(); }
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
  window.onCellDone = c => { prevDone && prevDone(c); _dagRunning.delete(c.id); _dagQueue(); _dagPulseSync(); };
  window.onNbState = () => { _dagRunning.clear(); _dagQueue(); };      // full publish — structure may have changed
  window.onCellsPatched = () => { _dagQueue(); };                      // targeted refresh — states/durations moved
  window.addEventListener('resize', debounce(() => { if (_dagOpen() && _dagChart) { _dagChart.resize(); _dagQueue(); } }, 150));
})();

// Esc closes (card first, then the pane); selecting a cell highlights its node.
(() => {
  _dagDirBtn(); _dagHeatBtn();                      // reflect persisted preferences
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
    dagFit();                                        // re-layout for the new aspect
  };
  grip.addEventListener('pointerdown', e => {
    e.preventDefault(); grip.classList.add('on');
    document.body.style.userSelect = 'none';         // don't select notebook text while dragging
    document.addEventListener('pointermove', move); document.addEventListener('pointerup', up);
  });
})();
