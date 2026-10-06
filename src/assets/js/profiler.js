// Cell profiler — Preact island: one dock over one cell's profile.
//
// The flame graph is keyed by SOURCE LINE (profile.jl): its first row is the cell's own lines, and
// every function below is a band over the lines inside it that the time went through, with the
// calls hanging under those lines. The code pane is the same data read the other way: the selected
// function's source with each line's share in the margin. The two point at each other: hovering a
// bar lights its line, hovering a line lights every bar it produced.
//
// Library code (Base, the stdlibs, packages that are not the notebook's own) folds into one bar per
// package until it is clicked open, so the reader's code is what the graph is made of.
//
// Nothing here is remote-aware. The hub runs the profile on whichever kernel the cell runs on
// (server_profile.jl) and pushes the result; source for a frame comes from that machine too.
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';
import { useRef, useEffect } from 'preact/hooks';

const A = (m, p, b) => window.api(m, p, b);

// ── state ─────────────────────────────────────────────────────────────────────────────────────────
const pf = signal(null);         // {cell, side, status, prepared, profile, source, error}
const sel = signal(0);           // the selected node (model id), 0 for none
const zoom = signal(1);          // the node last zoomed to, for the breadcrumb
const hover = signal(null);      // the display node under the pointer
const hotLine = signal(null);    // {file, line} under the pointer in the code pane
const fold = signal((() => { try { return localStorage.getItem('slateProfFold') !== '0'; } catch (_) { return true; } })());
const opened = signal(new Set()); // folded library bars clicked open
const codeAt = signal({ file: '', line: 0 });
const srcs = signal({});         // file → {text, error}, as the cell's machine has it

const pct = (x) => !(x > 0) ? '' : x >= 0.995 ? '100%' : x >= 0.1 ? Math.round(x * 100) + '%' : (x * 100).toFixed(1) + '%';
const ms = (x) => !(x >= 0) ? '' : x >= 10000 ? (x / 1000).toFixed(1) + ' s' : x >= 1000 ? (x / 1000).toFixed(2) + ' s' : Math.round(x) + ' ms';
const shortFile = (f) => !f ? '' : f.startsWith('cell:') ? f : f.replace(/^.*\/(?:packages|dev)\/([^/]+)\/[^/]+\//, '$1/').replace(/^.*\/share\/julia\/(?:base|stdlib\/[^/]+)\//, '').replace(/^.*\//, (m) => m);
const K = { line: 0, compile: 1, gc: 2, other: 3, synth: 4 };

// ── the model ─────────────────────────────────────────────────────────────────────────────────────
// Nodes as the worker sent them (ids 1-based, parents first), with children in reading order: the
// lines of one function together, in source order, and the runtime's own time last.
const model = computed(() => {
  const P = pf.value && pf.value.profile;
  if (!P || !P.nodes) return null;
  const S = P.strings, N = P.nodes, n = N.parent.length;
  const str = (k) => (k > 0 ? S[k - 1] : '');
  const nodes = new Array(n + 1);
  for (let i = 1; i <= n; i++) {
    nodes[i] = { id: i, parent: N.parent[i - 1], file: str(N.file[i - 1]), line: N.line[i - 1],
                 func: str(N.func[i - 1]), pkg: str(N.pkg[i - 1]), kind: N.kind[i - 1],
                 total: N.total[i - 1], self: N.self[i - 1], d: N.dispatch[i - 1],
                 g: N.gc[i - 1], c: N.compile[i - 1], kids: [] };
  }
  for (let i = 2; i <= n; i++) { const p = nodes[i].parent; if (p) nodes[p].kids.push(nodes[i]); }
  for (let i = 1; i <= n; i++) {
    const ks = nodes[i].kids;
    if (ks.length < 2) continue;
    const first = new Map();
    for (const k of ks) {
      const g = k.func + '\x1f' + k.file;
      if (k.kind === K.line && (!first.has(g) || k.line < first.get(g))) first.set(g, k.line);
    }
    ks.sort((a, b) => (a.kind === K.line) !== (b.kind === K.line) ? (a.kind === K.line ? -1 : 1)
      : a.kind !== K.line ? b.total - a.total
      : (first.get(a.func + '\x1f' + a.file) - first.get(b.func + '\x1f' + b.file)) ||
        (a.func + a.file).localeCompare(b.func + b.file) || a.line - b.line);
  }
  const lines = new Map();       // file → Map(line → {incl, self, d, g, c}) as shares of the samples
  const L = P.lines, tot = Math.max(1, P.samples);
  for (let i = 0; i < L.file.length; i++) {
    const f = str(L.file[i]);
    if (!lines.has(f)) lines.set(f, new Map());
    lines.get(f).set(L.line[i], { line: L.line[i], incl: L.incl[i] / tot, self: L.self[i] / tot,
                                  d: L.dispatch[i], g: L.gc[i], c: L.compile[i] });
  }
  return { P, nodes, lines, total: tot, cellFile: 'cell:' + P.cell, mine: new Set(P.mine || []) };
});

const isLib = (n, M) => n.kind === K.line && !(n.pkg === 'cell' || n.pkg === 'notebook' || M.mine.has(n.pkg));

// The graph as drawn: with folding on, a run of library frames becomes one bar named after its
// package, holding the first frames below it that are not library code.
function dtree(n, M) {
  if (fold.value && isLib(n, M) && !opened.value.has(n.id)) {
    const frontier = []; let d = 0, g = 0, c = 0;
    const walk = (x) => { d += x.d; g += x.g; c += x.c;
                          for (const k of x.kids) (isLib(k, M) ? walk(k) : frontier.push(k)); };
    walk(n);
    const under = frontier.reduce((s, k) => s + k.total, 0);
    return { n, folded: true, total: n.total, self: n.total - under, d, g, c,
             kids: frontier.map(k => dtree(k, M)) };
  }
  return { n, folded: false, total: n.total, self: n.self, d: n.d, g: n.g, c: n.c, kids: n.kids.map(k => dtree(k, M)) };
}

const dview = computed(() => {
  const M = model.value; if (!M) return null;
  return dtree(M.nodes[1], M);
});

// ── source ────────────────────────────────────────────────────────────────────────────────────────
function cellLine(file, line) {
  const t = srcText(file); if (!t) return '';
  return (t.split('\n')[line - 1] || '').trim();
}
function srcText(file) {
  const s = srcs.value[file];
  if (s) return s.text || '';
  const P = pf.value;
  if (P && file === 'cell:' + P.cell) return P.source || '';
  return '';
}
async function loadSource(file) {
  const P = pf.value;
  if (!file || srcs.value[file] || !P || file === 'cell:' + P.cell) return;
  srcs.value = { ...srcs.value, [file]: { text: '', error: null, loading: true } };
  try {
    const r = await A('GET', '/api/profile/source?cell=' + encodeURIComponent(P.cell) + '&file=' + encodeURIComponent(file));
    srcs.value = { ...srcs.value, [file]: { text: r.text || '', error: r.error || null } };
  } catch (_) {
    srcs.value = { ...srcs.value, [file]: { text: '', error: 'could not fetch the source' } };
  }
}
function showCode(file, line) {
  if (!file) return;
  codeAt.value = { file, line: line || 0 };
  loadSource(file);
}

// ── verbs ─────────────────────────────────────────────────────────────────────────────────────────
function cellSource(id) {
  return (window.edText && window.edText(id)) ||
         (((window.__slateState || {}).cells || []).find(c => c.id === id) || {}).source || '';
}
export async function openProfile(cellId) {
  pf.value = { cell: cellId, side: '', status: 'loading', prepared: null, profile: null, source: cellSource(cellId), error: null };
  sel.value = 0; zoom.value = 1; opened.value = new Set(); srcs.value = {}; view.value = { v0: 0, v1: 1 };
  codeAt.value = { file: 'cell:' + cellId, line: 0 };
  try {
    const r = await A('GET', '/api/profile/last?cell=' + encodeURIComponent(cellId));
    if (r && r.kind === 'result') apply(r);
  } catch (_) {}
  if (pf.value && pf.value.cell === cellId && pf.value.status === 'loading') pf.value = { ...pf.value, status: 'idle' };
}
const close = () => { pf.value = null; hover.value = null; hotLine.value = null; };
const prepare = () => pf.value && A('POST', '/api/profile/prepare', { cell: pf.value.cell });
const run = () => pf.value && A('POST', '/api/profile/run', { cell: pf.value.cell, mode: 'cpu' });

function apply(p) {
  const cur = pf.value;
  if (!cur || p.cell !== cur.cell) return;
  const next = { ...cur, side: p.side || cur.side };
  if (p.kind === 'preparing') Object.assign(next, { status: 'preparing', error: null });
  else if (p.kind === 'prepared') Object.assign(next, { status: 'idle', prepared: p });
  else if (p.kind === 'running') Object.assign(next, { status: 'running', error: null });
  else if (p.kind === 'error') Object.assign(next, { status: 'error', error: p.error });
  else if (p.kind === 'result') {
    Object.assign(next, { status: 'done', profile: p.profile, source: p.source || cur.source, error: null });
    sel.value = 0; zoom.value = 1; opened.value = new Set(); srcs.value = {}; view.value = { v0: 0, v1: 1 };
    codeAt.value = { file: 'cell:' + cur.cell, line: 0 };
  }
  pf.value = next;
}
window.onProfilePush = (p) => apply(p);
window.slateProfileCell = (id) => openProfile(id);
window.slateProfileOpen = () => !!pf.value;

// ── the flame graph ───────────────────────────────────────────────────────────────────────────────
// Each level is a BAND naming the function and, under it, one cell per line of that function the
// time passed through. The root level is the cell itself, whose lines are the first row.
const BAND = 14, ROW = 19, GAP = 3, LEVEL = BAND + ROW + GAP;

const PKG_COLOR = { cell: '#d8913a', notebook: '#c27b34' };
const KIND_COLOR = { [K.compile]: '#8f74d6', [K.gc]: '#d4555f', [K.other]: '#3b4058', [K.synth]: '#4a5072' };
function hue(s) { let h = 0; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0; return h % 360; }
function colorOf(dn, M) {
  const n = dn.n;
  if (n.kind !== K.line) return KIND_COLOR[n.kind] || '#4a5072';
  if (PKG_COLOR[n.pkg]) return PKG_COLOR[n.pkg];
  if (M.mine.has(n.pkg)) return '#4f8fd0';
  if (n.pkg === 'Base') return '#5e6788';
  return `hsl(${hue(n.pkg) % 360}, 28%, 44%)`;
}
function funcLabel(dn) {
  const n = dn.n;
  if (n.kind !== K.line) return n.func;
  if (dn.folded) return n.pkg;
  return n.func === 'top-level scope' ? (n.pkg === 'cell' ? 'cell ' + n.file.slice(5) : n.file) : n.func;
}
function cellLabel(dn, M) {
  const n = dn.n;
  if (n.kind !== K.line) return n.func;
  if (dn.folded) return n.func;
  const t = cellLine(n.file, n.line);
  return n.line + (t ? '  ' + t : '');
}

// Horizontal zoom: the part of the run on screen, as fractions of the whole. Double-click a bar or
// click a crumb to zoom to it; ⌘/Ctrl + wheel (or a pinch) zooms about the pointer; dragging or a
// sideways scroll pans. The callers of whatever is zoomed to stay on screen above it.
const view = signal({ v0: 0, v1: 1 });
const MINSPAN = 1e-5;
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
let _lay = null;                  // the current layout, for zooming to a node from outside the graph
let _anim = 0;

function setView(v0, v1) {
  const s = clamp(v1 - v0, MINSPAN, 1);
  v0 = clamp(v0, 0, 1 - s);
  view.value = { v0, v1: v0 + s };
}
function zoomAt(f, factor) {
  const { v0, v1 } = view.value, s = v1 - v0, ns = clamp(s * factor, MINSPAN, 1);
  const a = (f - v0) / s;
  setView(f - a * ns, f - a * ns + ns);
}
function animateTo(t0, t1) {
  cancelAnimationFrame(_anim);
  const { v0, v1 } = view.value, start = performance.now(), D = 200;
  const step = (now) => {
    const k = Math.min(1, (now - start) / D), e = 1 - Math.pow(1 - k, 3);
    setView(v0 + (t0 - v0) * e, v1 + (t1 - v1) * e);
    if (k < 1) _anim = requestAnimationFrame(step);
  };
  _anim = requestAnimationFrame(step);
}
function focusOn(id) {
  zoom.value = id;
  const sp = _lay && _lay.span.get(id);
  if (sp) animateTo(sp[0], sp[0] + sp[1]);
}

// Positions as fractions of the root, so zooming only remaps them.
function layout(root, M) {
  const rects = [], span = new Map([[root.n.id, [0, 1]]]);
  let depth = 0;
  const T = Math.max(1, root.total);
  const key = (k) => (k.folded ? 'f:' : '') + k.n.func + '\x1f' + k.n.file + '\x1f' + k.n.kind;
  const place = (parent, u0, d) => {
    depth = Math.max(depth, d);
    const y = d * LEVEL;
    let u = u0, i = 0;
    const ks = parent.kids;
    while (i < ks.length) {
      // A band per run of siblings in the same function.
      let j = i, gu = 0;
      while (j < ks.length && key(ks[j]) === key(ks[i])) { gu += ks[j].total / T; j++; }
      rects.push({ band: true, u, uw: gu, y, h: BAND, dn: ks[i] });
      for (let k = i; k < j; k++) {
        const cu = ks[k].total / T;
        rects.push({ band: false, u, uw: cu, y: y + BAND, h: ROW, dn: ks[k] });
        span.set(ks[k].n.id, [u, cu]);
        if (ks[k].kids.length) place(ks[k], u, d + 1);
        u += cu;
      }
      i = j;
    }
  };
  rects.push({ band: true, u: 0, uw: 1, y: 0, h: BAND, dn: root, top: true });
  place(root, 0, 0);
  return { rects, span, height: (depth + 1) * LEVEL + 4, root };
}

function Flame() {
  const M = model.value, root = dview.value, vw = view.value;
  const box = useRef(null), cv = useRef(null), tip = useRef(null), drawn = useRef([]), drag = useRef(null);
  if (M && root && (!_lay || _lay.root !== root)) _lay = layout(root, M);
  useEffect(() => {
    const el = box.current, c = cv.current; if (!el || !c || !M || !root || !_lay) return;
    const W = Math.max(200, el.clientWidth - 18), L = _lay;
    const dpr = window.devicePixelRatio || 1;
    c.width = W * dpr; c.height = L.height * dpr; c.style.width = W + 'px'; c.style.height = L.height + 'px';
    const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, L.height);
    g.textBaseline = 'middle';
    const kx = W / (vw.v1 - vw.v0), hl = hotLine.value, hv = hover.value, out = [];
    for (const r of L.rects) {
      const x = (r.u - vw.v0) * kx, w = r.uw * kx;
      if (w < 0.5 || x + w < 0 || x > W) continue;
      const cx = Math.max(0, x), cw = Math.min(W, x + w) - cx;
      out.push({ ...r, x: cx, w: cw });
      const dn = r.dn, n = dn.n;
      g.globalAlpha = r.band ? 0.55 : 1;
      g.fillStyle = colorOf(dn, M);
      g.fillRect(cx + (x >= 0 ? 0.5 : 0), r.y + 0.5, Math.max(0.5, cw - 1), r.h - 1);
      g.globalAlpha = 1;
      if (!r.band) {
        const hot = hl && n.kind === K.line && !dn.folded && n.file === hl.file && n.line === hl.line;
        if (n.id === sel.value || hot || (hv && hv.n.id === n.id)) {
          g.strokeStyle = hot ? '#ffd75e' : n.id === sel.value ? '#ffffff' : 'rgba(255,255,255,.55)';
          g.lineWidth = hot || n.id === sel.value ? 2 : 1;
          g.strokeRect(cx + 1, r.y + 1, Math.max(1, cw - 2), r.h - 2);
        }
        // Marks: a share of the time under runtime dispatch, compilation or GC.
        const share = (v) => v / Math.max(1, dn.total);
        let mx = cx + cw - 4;
        g.textAlign = 'right'; g.font = '11px system-ui, sans-serif';
        for (const [v, ch, col] of [[dn.g, '♻', '#ff8a8a'], [dn.c, '⚙', '#c9b4ff'], [dn.d, '⤳', '#ffd27a']]) {
          if (share(v) >= 0.05 && cw > 40) { g.fillStyle = col; g.fillText(ch, mx, r.y + r.h / 2 + 0.5); mx -= 12; }
        }
        g.textAlign = 'left';
      }
      const label = r.top ? funcLabel(dn) + '  ·  ' + M.P.samples + ' samples'
                  : r.band ? funcLabel(dn) + (dn.folded ? '  ▸' : '') : cellLabel(dn, M);
      const room = cw - 8 - (r.band ? 0 : 14);
      if (room > 14) {
        g.fillStyle = r.band ? 'rgba(235,238,250,.85)' : '#f4f5fb';
        g.font = r.band ? '10px system-ui, sans-serif' : '11px ui-monospace, SFMono-Regular, Menlo, monospace';
        let t = label;
        while (t.length > 1 && g.measureText(t).width > room) t = t.slice(0, Math.max(1, Math.floor(t.length * room / g.measureText(t).width) - 1));
        if (t !== label) t = t.slice(0, -1) + '…';
        g.fillText(t, cx + 4, r.y + r.h / 2 + 0.5);
      }
    }
    drawn.current = out;
  });
  // Zooming and sideways scrolling are the graph's; an ordinary scroll still scrolls a deep graph.
  useEffect(() => {
    const el = box.current; if (!el) return;
    const wheel = (ev) => {
      const b = cv.current && cv.current.getBoundingClientRect(); if (!b) return;
      const { v0, v1 } = view.value, f = v0 + clamp((ev.clientX - b.left) / b.width, 0, 1) * (v1 - v0);
      if (ev.ctrlKey || ev.metaKey) {
        ev.preventDefault();
        zoomAt(f, Math.exp(ev.deltaY * 0.0025));
      } else if (Math.abs(ev.deltaX) > Math.abs(ev.deltaY) || ev.shiftKey) {
        ev.preventDefault();
        const d = (Math.abs(ev.deltaX) > Math.abs(ev.deltaY) ? ev.deltaX : ev.deltaY) / b.width * (v1 - v0);
        setView(v0 + d, v1 + d);
      }
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  }, [!!M]);
  const stt = pf.value && pf.value.status;
  if (!M || !root) return html`<div class="pfflame pfempty">${
    stt === 'loading' ? html`<span class="hydspin"></span>`
    : stt === 'running' ? html`<span class="hydspin"></span> profiling`
    : stt === 'preparing' ? html`<span class="hydspin"></span> compiling` : 'not profiled yet'}</div>`;
  const at = (ev) => {
    const c = cv.current; if (!c) return null;
    const b = c.getBoundingClientRect(), x = ev.clientX - b.left, y = ev.clientY - b.top, rs = drawn.current;
    for (let i = rs.length - 1; i >= 0; i--) {
      const r = rs[i];
      if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return r;
    }
    return null;
  };
  const move = (ev) => {
    const dr = drag.current;
    if (dr && ev.buttons === 1) {
      const dx = ev.clientX - dr.x;
      if (Math.abs(dx) > 3) dr.moved = true;
      if (dr.moved) {
        const d = -dx / cv.current.getBoundingClientRect().width * (dr.v1 - dr.v0);
        setView(dr.v0 + d, dr.v1 + d);
        if (tip.current) tip.current.style.display = 'none';
        return;
      }
    }
    const r = at(ev), t = tip.current;
    hover.value = r && !r.band ? r.dn : null;
    if (!t) return;
    if (!r) { t.style.display = 'none'; return; }
    const dn = r.dn, n = dn.n, T = M.total;
    const where = n.kind !== K.line ? '' : n.pkg === 'cell' && !dn.folded ? n.file + ' line ' + n.line
                : (shortFile(n.file) + ':' + n.line);
    const mk = [dn.d ? 'dispatch ' + pct(dn.d / T) : '', dn.c ? 'compiling ' + pct(dn.c / T) : '',
                dn.g ? 'GC ' + pct(dn.g / T) : ''].filter(Boolean).join(' · ');
    t.innerHTML = '<b>' + escapeHtml(dn.folded ? n.pkg + ' › ' + n.func : funcLabel(dn)) + '</b>' +
      (r.band ? '' : (where ? '<div class="pftw">' + escapeHtml(where) + '</div>' : '')) +
      '<div>' + pct(dn.total / T) + ' of the run' + (r.band ? '' : ' · self ' + (pct(dn.self / T) || '0%')) + '</div>' +
      (mk ? '<div class="pftm">' + mk + '</div>' : '') +
      (dn.folded ? '<div class="pftw">click to open</div>' : '');
    const b = box.current.getBoundingClientRect();
    t.style.display = 'block';
    t.style.left = Math.min(ev.clientX - b.left + 14, b.width - 260) + 'px';
    t.style.top = (ev.clientY - b.top + box.current.scrollTop + 16) + 'px';
  };
  const down = (ev) => { if (ev.button === 0) drag.current = { x: ev.clientX, ...view.value, moved: false }; };
  const click = (ev) => {
    const dr = drag.current; drag.current = null;
    if (dr && dr.moved) return;
    const r = at(ev); if (!r) return;
    const dn = r.dn, n = dn.n;
    if (dn.folded) { opened.value = new Set([...opened.value, n.id]); return; }
    sel.value = n.id;
    if (n.kind === K.line) showCode(n.file, n.line);
  };
  const dbl = (ev) => { const r = at(ev); if (r && !r.dn.folded) focusOn(r.dn.n.id); };
  return html`<div class="pfflame" ref=${box} onMouseMove=${move} onMouseDown=${down}
      onMouseLeave=${() => { hover.value = null; drag.current = null; if (tip.current) tip.current.style.display = 'none'; }}>
    <canvas ref=${cv} onClick=${click} onDblClick=${dbl}></canvas>
    <div class="pftip" ref=${tip}></div>
  </div>`;
}
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// The way to what is zoomed to, and the zoom controls.
function Crumbs() {
  const M = model.value; if (!M) return null;
  const path = [];
  for (let n = M.nodes[zoom.value]; n; n = M.nodes[n.parent]) path.unshift(n);
  const { v0, v1 } = view.value, x = 1 / (v1 - v0);
  const mid = (v0 + v1) / 2;
  return html`<div class="pfcrumbs">
    ${path.map((n, i) => html`
      ${i ? html`<span class="pfsep">›</span>` : null}
      <button class=${'pfcrumb' + (i === path.length - 1 ? ' on' : '')} onClick=${() => focusOn(n.id)}>
        ${i === 0 ? 'cell ' + M.P.cell : (n.kind === K.line ? n.func + ':' + n.line : n.func)}</button>`)}
    <span class="pfsp"></span>
    <span class="pfkey"><span><i style="color:#ffd27a">⤳</i>dispatch</span><span><i style="color:#c9b4ff">⚙</i>compiling</span><span><i style="color:#ff8a8a">♻</i>GC</span></span>
    <span class="pfzoom">
      <button onClick=${() => zoomAt(mid, 2)} disabled=${x <= 1.0001} title="zoom out">−</button>
      <span class="pfzx" title="⌘/Ctrl + scroll to zoom, drag to pan">${x < 10 ? x.toFixed(1) : Math.round(x)}×</span>
      <button onClick=${() => zoomAt(mid, 0.5)} title="zoom in">+</button>
      <button onClick=${() => { zoom.value = 1; animateTo(0, 1); }} disabled=${x <= 1.0001} title="show the whole run">Fit</button>
    </span>
  </div>`;
}

// ── the code pane ─────────────────────────────────────────────────────────────────────────────────
function Code() {
  const M = model.value, at = codeAt.value;
  const host = useRef(null), vw = useRef(null);
  useEffect(() => {
    if (!host.current || !window.slateSourceViewer) return;
    vw.current = window.slateSourceViewer(host.current, {
      heat: true,
      onLineHover: (ln) => { hotLine.value = ln ? { file: codeAt.value.file, line: ln } : null; },
      onLineClick: (ln) => {
        const Mm = model.value; if (!Mm) return;
        // The heaviest bar this line produced.
        let best = null;
        for (let i = 1; i < Mm.nodes.length; i++) {
          const n = Mm.nodes[i];
          if (n.kind === K.line && n.file === codeAt.value.file && n.line === ln && (!best || n.total > best.total)) best = n;
        }
        if (best) sel.value = best.id;
        codeAt.value = { ...codeAt.value, line: ln };
      },
    });
    return () => { try { vw.current && vw.current.destroy(); } catch (_) {} vw.current = null; };
  }, []);
  const text = srcText(at.file), s = srcs.value[at.file];
  useEffect(() => {
    const v = vw.current; if (!v) return;
    v.setDoc(text, 1);
    const rows = M && M.lines.get(at.file);
    v.setHeat(rows ? [...rows.values()] : []);
    if (at.line) v.setLine(at.line);
  }, [text, at.file, at.line, M]);
  useEffect(() => {
    const v = vw.current, Mm = model.value; if (!v || !Mm) return;
    const h = hover.value;
    v.setHot(h && h.n.kind === K.line && !h.folded && h.n.file === at.file ? [h.n.line] : []);
  }, [hover.value, at.file]);
  const P = pf.value, isCell = P && at.file === 'cell:' + P.cell;
  return html`<div class="pfcode">
    <div class="pfcodehead">
      <span class="pffile" title=${(s && s.path) || at.file}>${isCell ? 'cell ' + P.cell : shortFile(at.file)}</span>
      ${!isCell && P ? html`<button class="pfback" onClick=${() => showCode('cell:' + P.cell, 0)}>back to the cell</button>` : null}
      ${s && s.loading ? html`<span class="pfdim">loading…</span>` : s && s.error ? html`<span class="pfwarn">${s.error}</span>` : null}
    </div>
    <div class="pfcodebody" ref=${host}></div>
  </div>`;
}

// ── the hot lines ─────────────────────────────────────────────────────────────────────────────────
function Hot() {
  const M = model.value; if (!M) return null;
  const rows = [];
  for (const [file, m] of M.lines) for (const r of m.values()) rows.push({ file, ...r });
  rows.sort((a, b) => b.self - a.self || b.incl - a.incl);
  const top = rows.filter(r => r.self > 0).slice(0, 14);
  const go = (r) => {
    let best = null;
    for (let i = 1; i < M.nodes.length; i++) {
      const n = M.nodes[i];
      if (n.kind === K.line && n.file === r.file && n.line === r.line && (!best || n.total > best.total)) best = n;
    }
    if (best) sel.value = best.id;
    showCode(r.file, r.line);
  };
  return html`<div class="pfhot">
    <div class="pfhothead"><span>self</span><span>total</span><span>line</span></div>
    ${top.map(r => html`<div class="pfhotrow" onClick=${() => go(r)}
        onMouseEnter=${() => { hotLine.value = { file: r.file, line: r.line }; }}
        onMouseLeave=${() => { hotLine.value = null; }}>
      <span class="pfnum">${pct(r.self)}</span><span class="pfnum dim">${pct(r.incl)}</span>
      <span class="pfloc">${r.file.startsWith('cell:') ? html`<b>${r.file.slice(5)}</b>:${r.line}` : shortFile(r.file) + ':' + r.line}
        <span class="pfsnip">${cellLine(r.file, r.line)}</span></span>
      <span class="pfmk">${r.d ? '⤳' : ''}${r.c ? '⚙' : ''}${r.g ? '♻' : ''}</span>
    </div>`)}
  </div>`;
}

function Facts() {
  const P = pf.value, pr = P && P.profile, pp = P && P.prepared;
  // Idle threads are not the cell's and say nothing about it; samples from other cells or the
  // worker's own tasks are worth knowing were left out.
  const dr = pr && pr.dropped ? Object.entries(pr.dropped).filter(([k, v]) => v > 0 && k !== 'idle') : [];
  const left = dr.reduce((t, [, v]) => t + v, 0);
  if (!pp && !pr) return null;
  return html`<div class="pffacts">
    ${pp ? (pp.ok ? html`<span class="pfprep">compiled ${ms(pp.compile_ms)}</span>`
                  : html`<span class="pfwarn" title=${pp.error}>${String(pp.error).split('\n')[0]}</span>`) : null}
    ${pr ? html`
      <span>${ms(pr.duration_ms)}</span>
      <span>${pr.samples} samples</span>
      ${pr.threads > 1 ? html`<span>${pr.threads} threads</span>` : null}
      ${pr.compile_ms > 0.5 ? html`<span class="c">⚙ ${ms(pr.compile_ms)}</span>` : null}
      ${pr.gc_ms > 0.5 ? html`<span class="g">♻ ${ms(pr.gc_ms)}</span>` : null}
      ${left ? html`<span class="pfdim" title=${dr.map(([k, v]) => v + ' ' + k).join(', ')}>left out ${left}</span>` : null}
      ${pr.error ? html`<span class="pfwarn" title=${pr.error}>threw ${String(pr.error).split('\n')[0]}</span>` : null}` : null}
  </div>`;
}

function Dock() {
  const P = pf.value;
  if (!P) return null;
  const busy = P.status === 'preparing' || P.status === 'running';
  return html`<div class="pfbg" onClick=${e => { if (e.target.classList.contains('pfbg')) close(); }}>
    <div class=${'pfdock' + (P.side ? ' remote' : '')}>
      <div class="pfhead">
        <span class="pftitle">Profile</span>
        <span class="pfcell">cell ${P.cell}</span>
        ${P.side ? html`<span class="pfside">on ${P.side}</span>` : null}
        <span class="pfstatus">${busy ? html`<span class="hydspin"></span> ${P.status === 'preparing' ? 'compiling' : 'running'}` : ''}</span>
        ${P.status === 'error' ? html`<span class="pfwarn">${P.error}</span>` : null}
        <span class="pfsp"></span>
        <label class="pftog" title="fold library code into one bar per package">
          <input type="checkbox" checked=${fold.value}
            onChange=${e => { fold.value = e.currentTarget.checked; try { localStorage.setItem('slateProfFold', fold.value ? '1' : '0'); } catch (_) {} }}/><i></i>fold libraries</label>
        <button class="pfbtn" disabled=${busy} onClick=${prepare} title="compile the cell's code without running it">Compile</button>
        <button class="pfbtn primary" disabled=${busy} onClick=${run}>▶ Run and profile</button>
        <button class="pfx" onClick=${close} title="close (Esc)">✕</button>
      </div>
      <${Facts} />
      <div class="pfbody">
        <${Code} />
        <div class="pfright">
          <${Crumbs} />
          <${Flame} />
          <${Hot} />
        </div>
      </div>
    </div>
  </div>`;
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && pf.value) { e.stopPropagation(); close(); }
}, true);

const style = document.createElement('style');
style.textContent = `
.pfbg { position:fixed; inset:0; z-index:70; background:rgba(0,0,0,.55); display:flex; align-items:center;
  justify-content:center; padding:24px; }
body.agent-open .pfbg { right:var(--agentw, 380px); }
.pfdock { position:relative; display:flex; flex-direction:column; width:min(1640px,100%); height:min(940px,100%);
  background:var(--bg); border:1px solid color-mix(in srgb, #e8933a 40%, var(--border)); border-radius:12px;
  overflow:hidden; box-shadow:0 18px 60px rgba(0,0,0,.45); }
.pfdock.remote { border-color:color-mix(in srgb, var(--purple) 45%, var(--border)); }
.pfhead { display:flex; align-items:center; gap:10px; padding:8px 12px; border-bottom:1px solid var(--border);
  background:color-mix(in srgb, #e8933a 8%, var(--bg2)); }
.pftitle { color:#e8933a; font-weight:600; font-size:.86rem; }
.pfcell, .pfside { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); font-size:.78rem; }
.pfside { color:var(--purple); }
.pfstatus { color:var(--text); font-size:.76rem; }
.pfsp { flex:1 1 auto; }
.pfwarn { color:var(--red); font-size:.74rem; }
.pfdim { color:var(--dim); font-size:.72rem; }
.pfbtn { font:inherit; font-size:.76rem; padding:4px 12px; border-radius:6px; cursor:pointer;
  background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.pfbtn:hover { border-color:#e8933a; }
.pfbtn.primary { border-color:color-mix(in srgb, #e8933a 60%, var(--border)); background:color-mix(in srgb, #e8933a 18%, var(--bg3)); }
.pfbtn[disabled] { opacity:.5; cursor:default; }
.pfx { padding:2px 8px; border-radius:6px; background:transparent; border:1px solid transparent; color:var(--dim); cursor:pointer; }
.pfx:hover { color:var(--red); border-color:var(--border); background:var(--bg3); }
.pftog { display:inline-flex; align-items:center; gap:6px; color:var(--dim); font-size:.74rem; cursor:pointer; user-select:none; }
.pftog input { display:none; }
.pftog i { position:relative; width:24px; height:13px; border-radius:7px; background:var(--bg3); border:1px solid var(--border); }
.pftog i::after { content:''; position:absolute; top:1px; left:1px; width:9px; height:9px; border-radius:50%; background:var(--dim); transition:transform .15s; }
.pftog input:checked + i { border-color:#e8933a; background:color-mix(in srgb, #e8933a 30%, transparent); }
.pftog input:checked + i::after { transform:translateX(11px); background:#e8933a; }
.pffacts { padding:6px 12px; border-bottom:1px solid var(--border); background:var(--bg2); font-size:.76rem;
  display:flex; flex-wrap:wrap; align-items:center; gap:14px; color:var(--text); white-space:nowrap; }
.pffacts .pfwarn { overflow:hidden; text-overflow:ellipsis; max-width:60ch; }
.pfprep { color:var(--dim); }
.pffacts .c { color:#b9a3f5; }
.pffacts .g { color:#f08a92; }
.pfkey { display:inline-flex; gap:10px; color:var(--dim); font-size:.7rem; }
.pfkey i { font-style:normal; margin-right:3px; }
.pfbody { flex:1 1 auto; min-height:0; display:grid; grid-template-columns:minmax(320px, 40%) minmax(0, 1fr); }
.pfcode { display:flex; flex-direction:column; min-width:0; min-height:0; border-right:1px solid var(--border); }
.pfcodehead { display:flex; align-items:center; gap:8px; padding:5px 10px; border-bottom:1px solid var(--border);
  font-family:var(--mono,ui-monospace,monospace); font-size:.74rem; }
.pffile { color:var(--text); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfback { font:inherit; font-size:.7rem; padding:1px 7px; border-radius:5px; background:transparent; border:1px solid var(--border); color:var(--dim); cursor:pointer; }
.pfback:hover { color:var(--text); }
.pfcodebody { flex:1 1 auto; min-height:0; overflow:auto; }
.pfcodebody .cm-editor { height:100%; }
.pfright { display:flex; flex-direction:column; min-width:0; min-height:0; }
.pfcrumbs { display:flex; flex-wrap:wrap; align-items:center; gap:3px; padding:5px 10px; border-bottom:1px solid var(--border); font-size:.72rem; }
.pfcrumb { font:inherit; font-family:var(--mono,ui-monospace,monospace); padding:1px 6px; border-radius:4px; background:transparent; border:1px solid transparent; color:var(--dim); cursor:pointer; }
.pfcrumb:hover { border-color:var(--border); color:var(--text); }
.pfcrumb.on { color:var(--text); }
.pfsep { color:var(--dim); }
.pfflame { position:relative; flex:1 1 60%; min-height:0; overflow:auto; padding:6px 8px; }
.pfflame canvas { display:block; cursor:pointer; }
.pfflame:active canvas { cursor:grabbing; }
.pfzoom { display:inline-flex; align-items:center; gap:3px; }
.pfzoom button { font:inherit; min-width:24px; padding:1px 7px; border-radius:5px; cursor:pointer;
  background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.pfzoom button:hover { border-color:#e8933a; }
.pfzoom button[disabled] { opacity:.45; cursor:default; }
.pfzx { min-width:38px; text-align:center; color:var(--dim); font-variant-numeric:tabular-nums; }
.pfempty { display:flex; align-items:center; justify-content:center; gap:8px; color:var(--dim); font-size:.82rem; }
.pfstatus { display:inline-flex; align-items:center; gap:6px; }
.pftip { display:none; position:absolute; z-index:2; max-width:250px; pointer-events:none; padding:6px 8px;
  border-radius:6px; background:var(--bg2); border:1px solid var(--border); box-shadow:0 6px 20px rgba(0,0,0,.4);
  font-size:.72rem; color:var(--text); }
.pftip b { font-family:var(--mono,ui-monospace,monospace); font-weight:600; }
.pftw { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); }
.pftm { color:#ffd27a; }
.pfhot { flex:0 0 auto; max-height:34%; overflow:auto; border-top:1px solid var(--border); font-size:.74rem; }
.pfhothead, .pfhotrow { display:grid; grid-template-columns:56px 56px minmax(0,1fr) 48px; gap:6px; padding:3px 10px; }
.pfhothead { color:var(--dim); font-size:.68rem; position:sticky; top:0; background:var(--bg); }
.pfhotrow { cursor:pointer; }
.pfhotrow:hover { background:color-mix(in srgb, #e8933a 12%, transparent); }
.pfnum { text-align:right; font-variant-numeric:tabular-nums; }
.pfnum.dim { color:var(--dim); }
.pfloc { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfsnip { color:var(--dim); margin-left:8px; }
.pfmk { color:#ffd27a; }
/* The code pane's heat (editor.js slateSourceViewer, heat: true). */
.cm-heatgutter { min-width:74px; }
.cm-heatm { position:relative; display:flex; align-items:center; gap:3px; height:100%; padding:0 4px 0 2px; font-size:10px; }
.cm-heatm b { position:absolute; left:0; top:20%; height:60%; background:color-mix(in srgb, #e8933a 45%, transparent); border-radius:2px; }
.cm-heatm em { position:relative; font-style:normal; color:var(--text); min-width:34px; text-align:right; font-variant-numeric:tabular-nums; }
.cm-heatm .pfm { position:relative; font-style:normal; }
.cm-heatm .pfm.d { color:#ffd27a; } .cm-heatm .pfm.c { color:#c9b4ff; } .cm-heatm .pfm.g { color:#ff8a8a; }
.cm-heat { background:color-mix(in srgb, #e8933a calc(var(--heat) * 34%), transparent); }
.cm-heathot { box-shadow:inset 3px 0 0 #ffd75e; background:color-mix(in srgb, #ffd75e 16%, transparent); }
`;
document.head.appendChild(style);

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Dock} />`, host);
