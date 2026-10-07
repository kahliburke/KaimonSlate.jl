// Cell profiler — Preact island: one dock over one cell's profile.
//
// The flame graph is keyed by SOURCE LINE (profile.jl): its first row is the cell's own lines, and
// every function below is a band over the lines inside it that the time went through, with the
// calls hanging under those lines. The code pane is the same data read the other way: the selected
// function's source with each line's share in the margin. The two point at each other: hovering a
// bar lights its line, hovering a line lights every bar it produced.
//
// Beside the graph: a timeline (the same samples in time order, a lane per thread), a functions
// view (time by function over every place it is called, with its callers and callees), and the
// details a run carries (what compiled, what dispatched at runtime, what was allocated, the GPU's
// kernels). Search, a share/time switch, a minimap, the keyboard, history and comparison with an
// earlier profile work across them.
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
const ls = (k, d) => { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (_) { return d; } };
const lsSet = (k, v) => { try { localStorage.setItem(k, v); } catch (_) {} };

// ── state ─────────────────────────────────────────────────────────────────────────────────────────
const pf = signal(null);         // {cell, side, status, prepared, profile, source, error, shownId}
const hist = signal([]);         // the cell's kept profiles, newest first, as their facts
const base = signal(null);       // an earlier profile to compare with: {id, profile}
const tab = signal(ls('slateProfTab', 'flame'));   // 'flame' | 'timeline' | 'functions' | 'details'
const query = signal('');        // search
const unit = signal(ls('slateProfUnit', 'share')); // 'share' | 'abs' (time or bytes)
const fnSel = signal('');        // the function selected in the functions view
const sel = signal(0);           // the selected node (model id), 0 for none
const zoom = signal(1);          // the node last zoomed to, for the breadcrumb
const hover = signal(null);      // the display node under the pointer
const hotLine = signal(null);    // {file, line} under the pointer in the code pane
const fold = signal(ls('slateProfFold', '1') !== '0');
const opened = signal(new Set()); // folded library bars clicked open
const codeAt = signal({ file: '', line: 0 });
const srcs = signal({});         // file → {text, error}, as the cell's machine has it
const optsOpen = signal(false);
const opts = signal((() => { try { return JSON.parse(ls('slateProfOpts', '')) || {}; } catch (_) { return {}; } })());
const runOpts = () => Object.assign({ mode: 'cpu', delay_ms: 1, buffer: 4000000, trace: true, alloc_rate: 0.01 }, opts.value);

const pct = (x) => !(x > 0) ? '' : x >= 0.995 ? '100%' : x >= 0.1 ? Math.round(x * 100) + '%' : x >= 0.001 ? (x * 100).toFixed(1) + '%' : '<0.1%';
const ms = (x) => !(x >= 0) ? '' : x >= 10000 ? (x / 1000).toFixed(1) + ' s' : x >= 1000 ? (x / 1000).toFixed(2) + ' s' : x >= 10 ? Math.round(x) + ' ms' : x.toFixed(1) + ' ms';
const bytes = (b) => !(b >= 0) ? '' : b >= 1 << 30 ? (b / (1 << 30)).toFixed(1) + ' GB' : b >= 1 << 20 ? (b / (1 << 20)).toFixed(1) + ' MB' : b >= 1 << 10 ? Math.round(b / (1 << 10)) + ' KB' : b + ' B';
const shortFile = (f) => !f ? '' : f.startsWith('cell:') ? f : f.replace(/^.*\/(?:packages|dev)\/([^/]+)\/[^/]+\//, '$1/').replace(/^.*\/share\/julia\/(?:base|stdlib\/[^/]+)\//, '');
const K = { line: 0, compile: 1, gc: 2, other: 3, synth: 4 };
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// ── the model ─────────────────────────────────────────────────────────────────────────────────────
// Nodes as the worker sent them (ids 1-based, parents first), with children in reading order: the
// lines of one function together, in source order, and the runtime's own time last. Each node has
// a path key (to match it in another profile) and a function key (to gather a function's nodes).
function buildModel(P) {
  if (!P || !P.nodes) return null;
  const S = P.strings, N = P.nodes, n = N.parent.length;
  const str = (k) => (k > 0 ? S[k - 1] : '');
  const nodes = new Array(n + 1);
  for (let i = 1; i <= n; i++) {
    nodes[i] = { id: i, parent: N.parent[i - 1], file: str(N.file[i - 1]), line: N.line[i - 1],
                 func: str(N.func[i - 1]), pkg: str(N.pkg[i - 1]), kind: N.kind[i - 1],
                 total: N.total[i - 1], self: N.self[i - 1], d: N.dispatch[i - 1],
                 g: N.gc[i - 1], c: N.compile[i - 1], kids: [], depth: 0 };
  }
  for (let i = 1; i <= n; i++) {
    const x = nodes[i], p = x.parent ? nodes[x.parent] : null;
    if (p) { p.kids.push(x); x.depth = p.depth + 1; }
    x.fk = x.kind === K.line ? x.func + '\x1f' + x.file : '\x1f' + x.func;
    x.key = (p ? p.key + '\x1e' : '') + x.func + '@' + x.file + ':' + x.line + '#' + x.kind;
  }
  for (let i = 1; i <= n; i++) {
    const ks = nodes[i].kids;
    if (ks.length < 2) continue;
    const first = new Map();
    for (const k of ks) if (k.kind === K.line && (!first.has(k.fk) || k.line < first.get(k.fk))) first.set(k.fk, k.line);
    ks.sort((a, b) => (a.kind === K.line) !== (b.kind === K.line) ? (a.kind === K.line ? -1 : 1)
      : a.kind !== K.line ? b.total - a.total
      : (first.get(a.fk) - first.get(b.fk)) || a.fk.localeCompare(b.fk) || a.line - b.line);
  }
  const lines = new Map();       // file → Map(line → {incl, self, d, g, c}) as shares
  const L = P.lines, tot = Math.max(1, P.samples);
  for (let i = 0; i < L.file.length; i++) {
    const f = str(L.file[i]);
    if (!lines.has(f)) lines.set(f, new Map());
    lines.get(f).set(L.line[i], { line: L.line[i], incl: L.incl[i] / tot, self: L.self[i] / tot,
                                  d: L.dispatch[i], g: L.gc[i], c: L.compile[i] });
  }
  return { P, nodes, lines, total: tot, cellFile: 'cell:' + P.cell, mine: new Set(P.mine || []),
           bytes: P.unit === 'bytes', delay: P.delay_ms || 1 };
}
const model = computed(() => buildModel(pf.value && pf.value.profile));
const baseModel = computed(() => buildModel(base.value && base.value.profile));
// A node's share in the comparison profile, by its path.
const baseShare = computed(() => {
  const B = baseModel.value; if (!B) return null;
  const m = new Map();
  for (let i = 1; i < B.nodes.length; i++) m.set(B.nodes[i].key, B.nodes[i].total / B.total);
  return m;
});

// What a weight reads as: a share of the run, or the time (or bytes) it stands for. A sample is one
// thread's `delay` of CPU time, so time adds up across threads.
function fmt(v, M) {
  if (!M) return '';
  if (unit.value === 'share') return pct(v / M.total);
  return M.bytes ? bytes(v) : ms(v * M.delay);
}

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
const dview = computed(() => { const M = model.value; return M ? dtree(M.nodes[1], M) : null; });

// Search: the nodes whose function or file contains the query, and the share of the run under
// them, each sample counted once however many matches it passes through.
const matches = computed(() => {
  const M = model.value, q = query.value.trim().toLowerCase();
  if (!M || !q) return null;
  const ids = new Set(); let under = 0;
  const walk = (x, inside) => {
    const hit = x.id !== 1 && (x.func.toLowerCase().includes(q) || x.file.toLowerCase().includes(q));
    if (hit) ids.add(x.id);
    if (hit && !inside) under += x.total;
    for (const k of x.kids) walk(k, inside || hit);
  };
  walk(M.nodes[1], false);
  return { ids, share: under / M.total };
});

// ── functions: a function's time over every place it is called ─────────────────────────────────────
// Total counts a sample once per function however deep a recursion goes; self is the time in the
// function's own lines. Callers and callees are the functions directly above and below its nodes.
const functions = computed(() => {
  const M = model.value; if (!M) return null;
  const by = new Map();
  const get = (n) => by.get(n.fk) || (by.set(n.fk, { fk: n.fk, func: n.func, file: n.file, pkg: n.pkg, kind: n.kind,
    self: 0, total: 0, d: 0, g: 0, c: 0, nodes: [], line: n.line }), by.get(n.fk));
  const walk = (x, on) => {
    let added = null;
    if (x.id !== 1 && x.kind !== K.synth) {
      const f = get(x);
      f.self += x.self; f.d += x.d; f.g += x.g; f.c += x.c; f.nodes.push(x);
      if (x.kind === K.line && x.line < f.line) f.line = x.line;
      if (!on.has(x.fk)) { f.total += x.total; added = x.fk; }
    }
    if (added) on.add(added);
    for (const k of x.kids) walk(k, on);
    if (added) on.delete(added);
  };
  walk(M.nodes[1], new Set());
  return [...by.values()].sort((a, b) => b.self - a.self || b.total - a.total);
});
function relatives(fk) {
  const M = model.value, fs = functions.value; if (!M || !fs) return null;
  const f = fs.find(x => x.fk === fk); if (!f) return null;
  const callers = new Map(), callees = new Map();
  const add = (m, n, v) => { const e = m.get(n.fk) || { fk: n.fk, func: n.func, file: n.file, kind: n.kind, v: 0 }; e.v += v; m.set(n.fk, e); };
  for (const n of f.nodes) {
    let p = M.nodes[n.parent];
    while (p && p.fk === n.fk) p = M.nodes[p.parent];        // a function's own lines are not its callers
    if (p && p.id !== 1) add(callers, p, n.total);
    else add(callers, { fk: '\x1fcell', func: 'cell ' + M.P.cell, file: M.cellFile, kind: K.synth }, n.total);
    for (const k of n.kids) if (k.fk !== n.fk) add(callees, k, k.total);
  }
  const sorted = (m) => [...m.values()].sort((a, b) => b.v - a.v);
  return { f, callers: sorted(callers), callees: sorted(callees) };
}

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
    srcs.value = { ...srcs.value, [file]: { text: r.text || '', error: r.error || null, path: r.path } };
  } catch (_) {
    srcs.value = { ...srcs.value, [file]: { text: '', error: 'could not fetch the source' } };
  }
}
function showCode(file, line) {
  if (!file) return;
  codeAt.value = { file, line: line || 0 };
  loadSource(file);
}
// The heaviest node at a place in the source.
function heaviestAt(file, line) {
  const M = model.value; if (!M) return null;
  let best = null;
  for (let i = 1; i < M.nodes.length; i++) {
    const n = M.nodes[i];
    if (n.kind === K.line && n.file === file && n.line === line && (!best || n.total > best.total)) best = n;
  }
  return best;
}
function select(n) {
  if (!n) return;
  sel.value = n.id;
  if (n.kind === K.line) showCode(n.file, n.line);
}

// ── verbs ─────────────────────────────────────────────────────────────────────────────────────────
function cellSource(id) {
  return (window.edText && window.edText(id)) ||
         (((window.__slateState || {}).cells || []).find(c => c.id === id) || {}).source || '';
}
function resetView(cell) {
  sel.value = 0; zoom.value = 1; opened.value = new Set(); srcs.value = {};
  view.value = { v0: 0, v1: 1 }; tview.value = { v0: 0, v1: 1 }; fnSel.value = '';
  codeAt.value = { file: 'cell:' + cell, line: 0 };
}
async function loadHistory(cell) {
  try {
    const r = await A('GET', '/api/profile/history?cell=' + encodeURIComponent(cell));
    if (pf.value && pf.value.cell === cell) hist.value = (r && r.profiles) || [];
  } catch (_) {}
}
export async function openProfile(cellId) {
  pf.value = { cell: cellId, side: '', status: 'loading', prepared: null, profile: null, source: cellSource(cellId), error: null };
  hist.value = []; base.value = null; query.value = '';
  resetView(cellId);
  loadHistory(cellId);
  try {
    const r = await A('GET', '/api/profile/last?cell=' + encodeURIComponent(cellId));
    if (r && r.kind === 'result') apply(r);
  } catch (_) {}
  if (pf.value && pf.value.cell === cellId && pf.value.status === 'loading') pf.value = { ...pf.value, status: 'idle' };
}
const close = () => { pf.value = null; hover.value = null; hotLine.value = null; optsOpen.value = false; };
const prepare = () => pf.value && A('POST', '/api/profile/prepare', { cell: pf.value.cell });
const run = () => { optsOpen.value = false; return pf.value && A('POST', '/api/profile/run', { cell: pf.value.cell, ...runOpts() }); };

// Show a kept profile instead of the latest; the latest is still a click away.
async function showKept(id) {
  const P = pf.value; if (!P) return;
  try {
    const r = await A('GET', '/api/profile/load?cell=' + encodeURIComponent(P.cell) + '&id=' + encodeURIComponent(id));
    if (r && r.profile) {
      pf.value = { ...pf.value, profile: r.profile, source: r.source || P.source, shownId: id, status: 'done' };
      if (base.value && base.value.id === id) base.value = null;
      resetView(P.cell);
    }
  } catch (_) {}
}
async function compareWith(id) {
  const P = pf.value; if (!P) return;
  if (!id) { base.value = null; return; }
  try {
    const r = await A('GET', '/api/profile/load?cell=' + encodeURIComponent(P.cell) + '&id=' + encodeURIComponent(id));
    if (r && r.profile) base.value = { id, profile: r.profile };
  } catch (_) {}
}

function apply(p) {
  const cur = pf.value;
  if (!cur || p.cell !== cur.cell) return;
  const next = { ...cur, side: p.side || cur.side };
  if (p.kind === 'preparing') Object.assign(next, { status: 'preparing', error: null });
  else if (p.kind === 'prepared') Object.assign(next, { status: 'idle', prepared: p });
  else if (p.kind === 'running') Object.assign(next, { status: 'running', error: null });
  else if (p.kind === 'error') Object.assign(next, { status: 'error', error: p.error });
  else if (p.kind === 'result') {
    // A new profile is compared with the one shown before it, which is usually the question.
    const was = cur.profile && cur.status === 'done' ? { id: String(Math.round(cur.profile.at * 1000)), profile: cur.profile } : null;
    Object.assign(next, { status: 'done', profile: p.profile, source: p.source || cur.source, error: null, shownId: '' });
    if (was && !base.value) base.value = was;
    resetView(cur.cell);
    loadHistory(cur.cell);
  }
  pf.value = next;
}
window.onProfilePush = (p) => apply(p);
window.slateProfileCell = (id) => openProfile(id);
window.slateProfileOpen = () => !!pf.value;

// ── zooming a span ────────────────────────────────────────────────────────────────────────────────
// The graph and the timeline each show a window onto their whole, as fractions [v0, v1]. Double-click
// or a crumb zooms to a bar; ⌘/Ctrl + wheel (or a pinch) zooms about the pointer; dragging or a
// sideways scroll pans.
const view = signal({ v0: 0, v1: 1 });
const tview = signal({ v0: 0, v1: 1 });
const MINSPAN = 1e-5;
const _anim = new Map();
function setV(sig, v0, v1) {
  const s = clamp(v1 - v0, MINSPAN, 1);
  v0 = clamp(v0, 0, 1 - s);
  sig.value = { v0, v1: v0 + s };
}
function zoomAt(sig, f, factor) {
  const { v0, v1 } = sig.value, s = v1 - v0, ns = clamp(s * factor, MINSPAN, 1);
  const a = (f - v0) / s;
  setV(sig, f - a * ns, f - a * ns + ns);
}
function animateTo(sig, t0, t1) {
  cancelAnimationFrame(_anim.get(sig) || 0);
  const { v0, v1 } = sig.value, start = performance.now(), D = 200;
  const step = (now) => {
    const k = Math.min(1, (now - start) / D), e = 1 - Math.pow(1 - k, 3);
    setV(sig, v0 + (t0 - v0) * e, v1 + (t1 - v1) * e);
    if (k < 1) _anim.set(sig, requestAnimationFrame(step));
  };
  _anim.set(sig, requestAnimationFrame(step));
}
let _lay = null;                  // the graph's current layout, for zooming to a node from outside it
function focusOn(id) {
  zoom.value = id;
  const sp = _lay && _lay.span.get(id);
  if (sp) animateTo(view, sp[0], sp[0] + sp[1]);
}
// Wheel and drag for a canvas showing `sig`'s window.
function useZoomPan(boxRef, canvasRef, sig) {
  useEffect(() => {
    const el = boxRef.current; if (!el) return;
    const wheel = (ev) => {
      const b = canvasRef.current && canvasRef.current.getBoundingClientRect(); if (!b) return;
      const { v0, v1 } = sig.value, f = v0 + clamp((ev.clientX - b.left) / b.width, 0, 1) * (v1 - v0);
      if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); zoomAt(sig, f, Math.exp(ev.deltaY * 0.0025)); }
      else if (Math.abs(ev.deltaX) > Math.abs(ev.deltaY) || ev.shiftKey) {
        ev.preventDefault();
        const d = (Math.abs(ev.deltaX) > Math.abs(ev.deltaY) ? ev.deltaX : ev.deltaY) / b.width * (v1 - v0);
        setV(sig, v0 + d, v1 + d);
      }
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  });
}
function dragPan(ev, dr, canvas, sig) {
  if (!dr || ev.buttons !== 1) return false;
  const dx = ev.clientX - dr.x;
  if (Math.abs(dx) > 3) dr.moved = true;
  if (!dr.moved) return false;
  const d = -dx / canvas.getBoundingClientRect().width * (dr.v1 - dr.v0);
  setV(sig, dr.v0 + d, dr.v1 + d);
  return true;
}

// ── colour ────────────────────────────────────────────────────────────────────────────────────────
const PKG_COLOR = { cell: '#d8913a', notebook: '#c27b34' };
const KIND_COLOR = { [K.compile]: '#8f74d6', [K.gc]: '#d4555f', [K.other]: '#3b4058', [K.synth]: '#4a5072' };
function hue(s) { let h = 0; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0; return h % 360; }
function colorOf(n, M) {
  if (n.kind !== K.line) return KIND_COLOR[n.kind] || '#4a5072';
  if (PKG_COLOR[n.pkg]) return PKG_COLOR[n.pkg];
  if (M.mine.has(n.pkg)) return '#4f8fd0';
  if (n.pkg === 'Base') return '#5e6788';
  return `hsl(${hue(n.pkg)}, 28%, 44%)`;
}
// Comparing: red where the share grew, blue where it shrank, grey where it held.
function diffColor(n, M) {
  const B = baseShare.value; if (!B) return null;
  const was = B.get(n.key) || 0, now = n.total / M.total, d = now - was;
  const k = clamp(Math.abs(d) / 0.05, 0, 1);
  if (k < 0.08) return '#4a4f63';
  return d > 0 ? `hsl(0, ${35 + 45 * k}%, ${38 + 10 * k}%)` : `hsl(212, ${35 + 45 * k}%, ${38 + 10 * k}%)`;
}
function funcLabel(dn) {
  const n = dn.n;
  if (n.kind !== K.line) return n.func;
  if (dn.folded) return n.pkg;
  return n.func === 'top-level scope' ? (n.pkg === 'cell' ? 'cell ' + n.file.slice(5) : n.file) : n.func;
}
function cellLabel(dn) {
  const n = dn.n;
  if (n.kind !== K.line) return n.func;
  if (dn.folded) return n.func;
  const t = cellLine(n.file, n.line);
  return n.line + (t ? '  ' + t : '');
}
function fit(g, label, room) {
  let t = label;
  while (t.length > 1 && g.measureText(t).width > room) t = t.slice(0, Math.max(1, Math.floor(t.length * room / g.measureText(t).width) - 1));
  return t === label ? t : t.slice(0, -1) + '…';
}
function tipHtml(dn, band, M) {
  const n = dn.n, T = M.total;
  const where = n.kind !== K.line ? '' : n.pkg === 'cell' && !dn.folded ? n.file + ' line ' + n.line : shortFile(n.file) + ':' + n.line;
  const mk = [dn.d ? 'dispatch ' + pct(dn.d / T) : '', dn.c ? 'compiling ' + pct(dn.c / T) : '', dn.g ? 'GC ' + pct(dn.g / T) : ''].filter(Boolean).join(' · ');
  const B = baseShare.value;
  const was = B && !dn.folded ? B.get(n.key) || 0 : null;
  return '<b>' + escapeHtml(dn.folded ? n.pkg + ' › ' + n.func : funcLabel(dn)) + '</b>' +
    (band ? '' : (where ? '<div class="pftw">' + escapeHtml(where) + '</div>' : '')) +
    '<div>' + fmt(dn.total, M) + (unit.value === 'share' ? ' of the run' : '') + (band ? '' : ' · self ' + (fmt(dn.self, M) || '0')) + '</div>' +
    (was !== null ? '<div class="pftw">was ' + (pct(was) || '0%') + ' of its run</div>' : '') +
    (mk ? '<div class="pftm">' + mk + '</div>' : '') +
    (dn.folded ? '<div class="pftw">click to open</div>' : '');
}
function placeTip(t, ev, box) {
  const b = box.getBoundingClientRect();
  t.style.display = 'block';
  t.style.left = Math.min(ev.clientX - b.left + 14, b.width - 260) + 'px';
  t.style.top = (ev.clientY - b.top + box.scrollTop + 16) + 'px';
}

// ── the flame graph ───────────────────────────────────────────────────────────────────────────────
// Each level is a BAND naming the function and, under it, one cell per line of that function the
// time passed through. The root level is the cell itself, whose lines are the first row.
const BAND = 14, ROW = 19, GAP = 3, LEVEL = BAND + ROW + GAP;

// Positions as fractions of the root, so zooming only remaps them.
function layout(root) {
  const rects = [], span = new Map([[root.n.id, [0, 1]]]);
  let depth = 0;
  const T = Math.max(1, root.total);
  const key = (k) => (k.folded ? 'f:' : '') + k.n.fk + '\x1f' + k.n.kind;
  const place = (parent, u0, d) => {
    depth = Math.max(depth, d);
    const y = d * LEVEL;
    let u = u0, i = 0;
    const ks = parent.kids;
    while (i < ks.length) {
      let j = i, gu = 0;
      while (j < ks.length && key(ks[j]) === key(ks[i])) { gu += ks[j].total / T; j++; }
      rects.push({ band: true, u, uw: gu, y, h: BAND, dn: ks[i], d });
      for (let k = i; k < j; k++) {
        const cu = ks[k].total / T;
        rects.push({ band: false, u, uw: cu, y: y + BAND, h: ROW, dn: ks[k], d });
        span.set(ks[k].n.id, [u, cu]);
        if (ks[k].kids.length) place(ks[k], u, d + 1);
        u += cu;
      }
      i = j;
    }
  };
  rects.push({ band: true, u: 0, uw: 1, y: 0, h: BAND, dn: root, top: true, d: -1 });
  place(root, 0, 0);
  return { rects, span, height: (depth + 1) * LEVEL + 4, root };
}

function drawFlame(g, L, W, vw, M, { mini = false } = {}) {
  const kx = W / (vw.v1 - vw.v0), out = [];
  const hl = hotLine.value, hv = hover.value, mt = matches.value, fsel = fnSel.value;
  for (const r of L.rects) {
    const x = (r.u - vw.v0) * kx, w = r.uw * kx;
    if (w < 0.5 || x + w < 0 || x > W) continue;
    const cx = Math.max(0, x), cw = Math.min(W, x + w) - cx;
    const y = mini ? (r.d + 1) * 4 : r.y, h = mini ? (r.band ? 0 : 3) : r.h;
    if (h <= 0) continue;
    out.push({ ...r, x: cx, w: cw });
    const dn = r.dn, n = dn.n;
    const dim = mt && !mt.ids.has(n.id) && !r.top;
    g.globalAlpha = (r.band ? 0.55 : 1) * (dim ? 0.3 : 1);
    g.fillStyle = (!r.band && !dn.folded && diffColor(n, M)) || colorOf(n, M);
    g.fillRect(cx + (x >= 0 ? 0.5 : 0), y + 0.5, Math.max(0.5, cw - 1), h - (mini ? 0 : 1));
    g.globalAlpha = 1;
    if (mini || r.band) continue;
    const hot = hl && n.kind === K.line && !dn.folded && n.file === hl.file && n.line === hl.line;
    const found = mt && mt.ids.has(n.id);
    const ofFn = fsel && n.fk === fsel;
    if (n.id === sel.value || hot || found || ofFn || (hv && hv.n.id === n.id)) {
      g.strokeStyle = hot ? '#ffd75e' : n.id === sel.value ? '#ffffff' : found || ofFn ? '#ff6fd8' : 'rgba(255,255,255,.55)';
      g.lineWidth = hot || n.id === sel.value || found || ofFn ? 2 : 1;
      g.strokeRect(cx + 1, y + 1, Math.max(1, cw - 2), h - 2);
    }
  }
  if (mini) return out;
  g.textBaseline = 'middle';
  for (const r of out) {
    const dn = r.dn, cw = r.w, cx = r.x;
    if (!r.band) {
      const share = (v) => v / Math.max(1, dn.total);
      let mx = cx + cw - 4;
      g.textAlign = 'right'; g.font = '11px system-ui, sans-serif';
      for (const [v, ch, col] of [[dn.g, '♻', '#ff8a8a'], [dn.c, '⚙', '#c9b4ff'], [dn.d, '⤳', '#ffd27a']]) {
        if (share(v) >= 0.05 && cw > 40) { g.fillStyle = col; g.fillText(ch, mx, r.y + r.h / 2 + 0.5); mx -= 12; }
      }
      g.textAlign = 'left';
    }
    const label = r.top ? funcLabel(dn) + '  ·  ' + (M.bytes ? bytes(M.total) + ' allocated' : M.P.samples + ' samples')
                : r.band ? funcLabel(dn) + (dn.folded ? '  ▸' : '') : cellLabel(dn);
    const room = cw - 8 - (r.band ? 0 : 14);
    if (room > 14) {
      g.fillStyle = r.band ? 'rgba(235,238,250,.85)' : '#f4f5fb';
      g.font = r.band ? '10px system-ui, sans-serif' : '11px ui-monospace, SFMono-Regular, Menlo, monospace';
      g.fillText(fit(g, label, room), cx + 4, r.y + r.h / 2 + 0.5);
    }
  }
  return out;
}

function sizeCanvas(c, W, H) {
  const dpr = window.devicePixelRatio || 1;
  c.width = W * dpr; c.height = H * dpr; c.style.width = W + 'px'; c.style.height = H + 'px';
  const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
  return g;
}

function Flame() {
  const M = model.value, root = dview.value, vw = view.value;
  const box = useRef(null), cv = useRef(null), mini = useRef(null), tip = useRef(null), drawn = useRef([]), drag = useRef(null);
  if (M && root && (!_lay || _lay.root !== root)) _lay = layout(root);
  useEffect(() => {
    const el = box.current, c = cv.current; if (!el || !c || !M || !root || !_lay) return;
    const W = Math.max(200, el.clientWidth - 18);
    drawn.current = drawFlame(sizeCanvas(c, W, _lay.height), _lay, W, vw, M);
    // The minimap: the whole run, small, with the window on screen marked.
    const m = mini.current;
    if (m) {
      const depth = Math.min(10, Math.round(_lay.height / LEVEL));
      const g = sizeCanvas(m, W, depth * 4 + 6);
      drawFlame(g, { rects: _lay.rects.filter(r => r.d < depth) }, W, { v0: 0, v1: 1 }, M, { mini: true });
      g.fillStyle = 'rgba(255,255,255,.08)'; g.strokeStyle = 'rgba(255,255,255,.7)'; g.lineWidth = 1;
      g.fillRect(vw.v0 * W, 0, (vw.v1 - vw.v0) * W, depth * 4 + 6);
      g.strokeRect(vw.v0 * W + 0.5, 0.5, Math.max(2, (vw.v1 - vw.v0) * W) - 1, depth * 4 + 5);
    }
  });
  useZoomPan(box, cv, view);
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
    if (dragPan(ev, drag.current, cv.current, view)) { if (tip.current) tip.current.style.display = 'none'; return; }
    const r = at(ev), t = tip.current;
    hover.value = r && !r.band ? r.dn : null;
    if (!t) return;
    if (!r) { t.style.display = 'none'; return; }
    t.innerHTML = tipHtml(r.dn, r.band, M);
    placeTip(t, ev, box.current);
  };
  const down = (ev) => { if (ev.button === 0) drag.current = { x: ev.clientX, ...view.value, moved: false }; };
  const click = (ev) => {
    const dr = drag.current; drag.current = null;
    if (dr && dr.moved) return;
    const r = at(ev); if (!r) return;
    const dn = r.dn, n = dn.n;
    if (dn.folded) { opened.value = new Set([...opened.value, n.id]); return; }
    select(n);
  };
  const dbl = (ev) => { const r = at(ev); if (r && !r.dn.folded) focusOn(r.dn.n.id); };
  const miniDown = (ev) => {
    const go = (e) => {
      const b = mini.current.getBoundingClientRect(), f = clamp((e.clientX - b.left) / b.width, 0, 1);
      const { v0, v1 } = view.value, s = v1 - v0;
      setV(view, f - s / 2, f + s / 2);
    };
    go(ev);
    const mv = (e) => go(e), up = () => { window.removeEventListener('mousemove', mv); window.removeEventListener('mouseup', up); };
    window.addEventListener('mousemove', mv); window.addEventListener('mouseup', up);
  };
  return html`<div class="pfgraph">
    ${vw.v1 - vw.v0 < 0.999 ? html`<canvas class="pfmini" ref=${mini} onMouseDown=${miniDown} title="the whole run; drag to move"></canvas>` : null}
    <div class="pfflame" ref=${box} onMouseMove=${move} onMouseDown=${down}
      onMouseLeave=${() => { hover.value = null; drag.current = null; if (tip.current) tip.current.style.display = 'none'; }}>
      <canvas ref=${cv} onClick=${click} onDblClick=${dbl}></canvas>
      <div class="pftip" ref=${tip}></div>
    </div>
  </div>`;
}

// ── the timeline ──────────────────────────────────────────────────────────────────────────────────
// The samples in time order, a lane per thread, each lane the stacks over time (cell lines on top).
// Runs of samples in the same frame are one bar. Folded library code folds here as in the graph.
const TL_ROW = 13, TL_DEPTH = 14, TL_LANEGAP = 10, TL_AXIS = 18;
const timeline = computed(() => {
  const M = model.value, P = M && M.P, T = P && P.timeline;
  if (!T || !T.node || !T.node.length) return null;
  const step = T.step_ms || M.delay, end = Math.max(...T.t) + step;
  const chainOf = new Map();
  const chain = (id) => {
    if (chainOf.has(id)) return chainOf.get(id);
    const c = [];
    for (let n = M.nodes[id]; n && n.id !== 1; n = M.nodes[n.parent]) c.push(n);
    c.reverse();
    const shown = fold.value ? c.filter((n, i) => !(isLib(n, M) && i > 0 && isLib(c[i - 1], M) && !opened.value.has(c[i - 1].id))) : c;
    chainOf.set(id, shown); return shown;
  };
  const byThread = new Map();
  for (let i = 0; i < T.node.length; i++) {
    const th = T.thread[i];
    if (!byThread.has(th)) byThread.set(th, []);
    byThread.get(th).push(i);
  }
  const lanes = [];
  let y = TL_AXIS;
  for (const th of [...byThread.keys()].sort((a, b) => a - b)) {
    const ix = byThread.get(th).sort((a, b) => T.t[a] - T.t[b]);
    const rects = [];
    let depth = 0;
    const open = [];                     // per depth: the bar being extended
    for (const i of ix) {
      const c = chain(T.node[i]), t0 = T.t[i], t1 = t0 + step;
      depth = Math.max(depth, Math.min(TL_DEPTH, c.length));
      for (let d = 0; d < Math.min(TL_DEPTH, c.length); d++) {
        const o = open[d];
        if (o && o.n === c[d] && t0 - o.t1 <= step * 1.5) o.t1 = t1;
        else { const r = { n: c[d], d, t0, t1 }; rects.push(r); open[d] = r; }
      }
      for (let d = Math.min(TL_DEPTH, c.length); d < open.length; d++) open[d] = null;
    }
    lanes.push({ thread: th, y, depth, rects, n: ix.length });
    y += depth * TL_ROW + TL_LANEGAP + 12;
  }
  return { lanes, end, height: y };
});

function Timeline() {
  const M = model.value, TL = timeline.value, vw = tview.value;
  const box = useRef(null), cv = useRef(null), tip = useRef(null), drawn = useRef([]), drag = useRef(null);
  useEffect(() => {
    const el = box.current, c = cv.current; if (!el || !c || !TL) return;
    const W = Math.max(200, el.clientWidth - 18), g = sizeCanvas(c, W, TL.height);
    const span = TL.end * (vw.v1 - vw.v0), t0 = TL.end * vw.v0, kx = W / span, out = [];
    // The time axis.
    g.fillStyle = 'rgba(200,205,225,.55)'; g.font = '10px system-ui, sans-serif'; g.textBaseline = 'top';
    const stepT = Math.pow(10, Math.floor(Math.log10(span / 6))) * ([1, 2, 5].find(m => span / (Math.pow(10, Math.floor(Math.log10(span / 6))) * m) <= 8) || 10);
    for (let t = Math.ceil(t0 / stepT) * stepT; t <= t0 + span; t += stepT) {
      const x = (t - t0) * kx;
      g.fillRect(x, TL_AXIS - 5, 1, 4); g.fillText(ms(t), x + 2, 2);
    }
    const hv = hover.value, mt = matches.value, fsel = fnSel.value;
    for (const L of TL.lanes) {
      g.fillStyle = 'rgba(200,205,225,.7)'; g.fillText('thread ' + L.thread + '  ·  ' + L.n + ' samples', 2, L.y);
      for (const r of L.rects) {
        const x = (r.t0 - t0) * kx, w = (r.t1 - r.t0) * kx;
        if (x + w < 0 || x > W || w < 0.3) continue;
        const cx = Math.max(0, x), cw = Math.min(W, x + w) - cx, y = L.y + 12 + r.d * TL_ROW;
        const n = r.n, dim = mt && !mt.ids.has(n.id);
        g.globalAlpha = dim ? 0.3 : 1;
        g.fillStyle = diffColor(n, M) || colorOf(n, M);
        g.fillRect(cx, y, Math.max(0.5, cw - 0.5), TL_ROW - 1);
        g.globalAlpha = 1;
        if (n.id === sel.value || (hv && hv.n && hv.n.id === n.id) || (fsel && n.fk === fsel) || (mt && mt.ids.has(n.id))) {
          g.strokeStyle = n.id === sel.value ? '#fff' : '#ff6fd8'; g.lineWidth = 1.5;
          g.strokeRect(cx + 0.5, y + 0.5, Math.max(1, cw - 1), TL_ROW - 2);
        }
        if (cw > 40) {
          g.fillStyle = '#f4f5fb'; g.font = '10px ui-monospace, SFMono-Regular, Menlo, monospace'; g.textBaseline = 'middle';
          g.fillText(fit(g, n.kind === K.line ? (n.func === 'top-level scope' ? n.line + '  ' + cellLine(n.file, n.line) : n.func + ':' + n.line) : n.func, cw - 6), cx + 3, y + TL_ROW / 2);
          g.textBaseline = 'top';
        }
        out.push({ x: cx, w: cw, y, h: TL_ROW, n });
      }
    }
    drawn.current = out;
  });
  useZoomPan(box, cv, tview);
  if (!M) return html`<div class="pfflame pfempty">not profiled yet</div>`;
  if (!TL) return html`<div class="pfflame pfempty">${M.bytes ? 'an allocation profile has no timeline' : 'this profile has no timeline'}</div>`;
  const at = (ev) => {
    const c = cv.current; if (!c) return null;
    const b = c.getBoundingClientRect(), x = ev.clientX - b.left, y = ev.clientY - b.top, rs = drawn.current;
    for (let i = rs.length - 1; i >= 0; i--) { const r = rs[i]; if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) return r; }
    return null;
  };
  const move = (ev) => {
    if (dragPan(ev, drag.current, cv.current, tview)) { if (tip.current) tip.current.style.display = 'none'; return; }
    const r = at(ev), t = tip.current;
    hover.value = r ? { n: r.n } : null;
    if (!t) return;
    if (!r) { t.style.display = 'none'; return; }
    t.innerHTML = tipHtml({ n: r.n, total: r.n.total, self: r.n.self, d: r.n.d, g: r.n.g, c: r.n.c, folded: false }, false, M);
    placeTip(t, ev, box.current);
  };
  const down = (ev) => { if (ev.button === 0) drag.current = { x: ev.clientX, ...tview.value, moved: false }; };
  const click = (ev) => { const dr = drag.current; drag.current = null; if (dr && dr.moved) return; const r = at(ev); if (r) select(r.n); };
  return html`<div class="pfflame" ref=${box} onMouseMove=${move} onMouseDown=${down}
      onMouseLeave=${() => { hover.value = null; drag.current = null; if (tip.current) tip.current.style.display = 'none'; }}>
    <canvas ref=${cv} onClick=${click}></canvas>
    <div class="pftip" ref=${tip}></div>
  </div>`;
}

// ── the functions view ────────────────────────────────────────────────────────────────────────────
function fnName(f) { return f.kind === K.line ? (f.func === 'top-level scope' ? 'cell ' + f.file.slice(5) : f.func) : f.func; }
function Functions() {
  const M = model.value, fs = functions.value;
  if (!M || !fs) return html`<div class="pfflame pfempty">not profiled yet</div>`;
  const q = query.value.trim().toLowerCase();
  const rows = (q ? fs.filter(f => f.func.toLowerCase().includes(q) || f.file.toLowerCase().includes(q)) : fs).slice(0, 300);
  const R = fnSel.value ? relatives(fnSel.value) : null;
  const pick = (f) => { fnSel.value = f.fk; if (f.kind === K.line) showCode(f.file, f.line); };
  const bar = (v) => html`<span class="pfbar"><i style=${'width:' + Math.max(1, Math.round(100 * v / M.total)) + '%'}></i></span>`;
  const rel = (title, list) => html`<div class="pfrel"><div class="pfrelhead">${title}</div>
    ${list.length ? list.slice(0, 40).map(e => html`<div class="pfrelrow" onClick=${() => e.fk !== '\x1fcell' && pick(e)}>
      <span class="pfnum">${fmt(e.v, M)}</span>${bar(e.v)}<span class="pffn">${fnName(e)}</span>
      <span class="pfdim">${e.kind === K.line ? shortFile(e.file) : ''}</span></div>`)
      : html`<div class="pfdim pfrelrow">none</div>`}</div>`;
  return html`<div class="pffuncs">
    <div class="pftable">
      <div class="pfthead"><span>self</span><span>total</span><span>function</span><span>file</span><span></span></div>
      ${rows.map(f => html`<div class=${'pftrow' + (fnSel.value === f.fk ? ' on' : '')} onClick=${() => pick(f)}>
        <span class="pfnum">${fmt(f.self, M)}</span><span class="pfnum dim">${fmt(f.total, M)}</span>
        <span class="pffn">${fnName(f)}</span><span class="pfdim pffile">${f.kind === K.line ? shortFile(f.file) : ''}</span>
        <span class="pfmk">${f.d ? '⤳' : ''}${f.c ? '⚙' : ''}${f.g ? '♻' : ''}</span></div>`)}
    </div>
    ${R ? html`<div class="pfsandwich">
      ${rel('called from', R.callers)}
      <div class="pfrelmid"><b>${fnName(R.f)}</b> <span class="pfdim">${fmt(R.f.total, M)} total · ${fmt(R.f.self, M)} self</span></div>
      ${rel('calls', R.callees)}
    </div>` : html`<div class="pfsandwich pfempty">select a function to see what calls it and what it calls</div>`}
  </div>`;
}

// ── details: compiling, dispatch, allocation types, the GPU ─────────────────────────────────────────
function Details() {
  const P = pf.value && pf.value.profile;
  if (!P) return html`<div class="pfflame pfempty">not profiled yet</div>`;
  // Every column but the last is a figure; the last (a type, a signature, a kernel) takes the rest.
  const tbl = (title, head, rows, empty) => {
    const cols = 'grid-template-columns:repeat(' + (head.length - 1) + ', 80px) minmax(0,1fr)';
    return html`<div class="pfdet"><div class="pfrelhead">${title}</div>
    ${rows && rows.length ? html`<div class="pfdetrow pfdethead" style=${cols}>${head.map(h => html`<span>${h}</span>`)}</div>
      ${rows.map(r => html`<div class="pfdetrow" style=${cols}>${r.map((c, i) => html`<span class=${i === r.length - 1 ? 'pfsig' : 'pfnum'} title=${i === r.length - 1 ? c : null}>${c}</span>`)}</div>`)}`
      : html`<div class="pfdim pfdetrow">${empty}</div>`}</div>`;
  };
  const g = P.gpu;
  return html`<div class="pfdetails">
    ${P.types ? tbl('Allocated, by type (scaled from the ' + pct(P.alloc_rate) + ' recorded)', ['bytes', 'count', 'type'],
                    P.types.map(([t, c, b]) => [bytes(b), c.toLocaleString(), t]), 'nothing recorded') : null}
    ${g ? tbl('On the GPU' + (g.device_ms ? ' · ' + ms(g.device_ms) + ' of device time' : ''), ['time', 'calls', 'kernel or copy'],
              (g.kernels || []).map(([n, c, t]) => [ms(t), c, n]), g.error || 'no device work recorded') : null}
    ${P.compiled ? tbl('Compiled during the run · ' + P.compiled_n, ['time', 'times', 'method'],
                       P.compiled.map(([s, t, n]) => [ms(t), n || 1, s]), 'nothing compiled') : null}
    ${P.dispatched ? tbl('Dispatched at runtime · ' + P.dispatched_n + ' signatures', ['calls', 'signature'],
                         P.dispatched.map(([s, n]) => [n, s]), 'no runtime dispatch') : null}
    ${!P.types && !g && !P.compiled ? html`<div class="pfempty">no details recorded for this run</div>` : null}
  </div>`;
}

function Crumbs() {
  const M = model.value; if (!M) return null;
  const path = [];
  for (let n = M.nodes[zoom.value]; n; n = M.nodes[n.parent]) path.unshift(n);
  const sig = tab.value === 'timeline' ? tview : view;
  const { v0, v1 } = sig.value, x = 1 / (v1 - v0), mid = (v0 + v1) / 2;
  return html`<div class="pfcrumbs">
    ${tab.value === 'flame' ? path.map((n, i) => html`
      ${i ? html`<span class="pfsep">›</span>` : null}
      <button class=${'pfcrumb' + (i === path.length - 1 ? ' on' : '')} onClick=${() => focusOn(n.id)}>
        ${i === 0 ? 'cell ' + M.P.cell : (n.kind === K.line ? n.func + ':' + n.line : n.func)}</button>`) : null}
    <span class="pfsp"></span>
    <span class="pfkey"><span><i style="color:#ffd27a">⤳</i>dispatch</span><span><i style="color:#c9b4ff">⚙</i>compiling</span><span><i style="color:#ff8a8a">♻</i>GC</span>
      ${baseShare.value ? html`<span><i style="color:#e05a5a">■</i>grew</span><span><i style="color:#5a8fe0">■</i>shrank</span>` : null}</span>
    ${tab.value === 'flame' || tab.value === 'timeline' ? html`<span class="pfzoom">
      <button onClick=${() => zoomAt(sig, mid, 2)} disabled=${x <= 1.0001} title="zoom out (-)">−</button>
      <span class="pfzx" title="⌘/Ctrl + scroll to zoom, drag to pan">${x < 10 ? x.toFixed(1) : Math.round(x)}×</span>
      <button onClick=${() => zoomAt(sig, mid, 0.5)} title="zoom in (+)">+</button>
      <button onClick=${() => { zoom.value = 1; animateTo(sig, 0, 1); }} disabled=${x <= 1.0001} title="show the whole run (0)">Fit</button>
    </span>` : null}
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
        const best = heaviestAt(codeAt.value.file, ln);
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
    const v = vw.current; if (!v) return;
    const h = hover.value;
    v.setHot(h && h.n && h.n.kind === K.line && !h.folded && h.n.file === at.file ? [h.n.line] : []);
  }, [hover.value, at.file]);
  const P = pf.value, isCell = P && at.file === 'cell:' + P.cell;
  return html`<div class="pfcode">
    <div class="pfcodehead">
      <span class="pffile" title=${(s && s.path) || at.file}>${isCell ? 'cell ' + P.cell : shortFile(at.file)}</span>
      ${!isCell && P ? html`<button class="pfback" onClick=${() => showCode('cell:' + P.cell, 0)}>back to the cell</button>` : null}
      ${s && s.loading ? html`<span class="hydspin"></span>` : s && s.error ? html`<span class="pfwarn">${s.error}</span>` : null}
    </div>
    <div class="pfcodebody" ref=${host}></div>
  </div>`;
}

// ── the hot lines ─────────────────────────────────────────────────────────────────────────────────
function Hot() {
  const M = model.value; if (!M) return null;
  const B = baseModel.value;
  const rows = [];
  for (const [file, m] of M.lines) for (const r of m.values()) rows.push({ file, ...r });
  rows.sort((a, b) => b.self - a.self || b.incl - a.incl);
  const top = rows.filter(r => r.self > 0).slice(0, 14);
  const wasOf = (r) => { const m = B && B.lines.get(r.file); const w = m && m.get(r.line); return w ? w.self : 0; };
  const go = (r) => { select(heaviestAt(r.file, r.line)); showCode(r.file, r.line); };
  return html`<div class="pfhot">
    <div class=${'pfhothead' + (B ? ' cmp' : '')}><span>self</span><span>total</span>${B ? html`<span>before</span>` : null}<span>line</span></div>
    ${top.map(r => html`<div class=${'pfhotrow' + (B ? ' cmp' : '')} onClick=${() => go(r)}
        onMouseEnter=${() => { hotLine.value = { file: r.file, line: r.line }; }}
        onMouseLeave=${() => { hotLine.value = null; }}>
      <span class="pfnum">${fmt(r.self * M.total, M)}</span><span class="pfnum dim">${fmt(r.incl * M.total, M)}</span>
      ${B ? html`<span class="pfnum dim">${pct(wasOf(r)) || '–'}</span>` : null}
      <span class="pfloc">${r.file.startsWith('cell:') ? html`<b>${r.file.slice(5)}</b>:${r.line}` : shortFile(r.file) + ':' + r.line}
        <span class="pfsnip">${cellLine(r.file, r.line)}</span></span>
      <span class="pfmk">${r.d ? '⤳' : ''}${r.c ? '⚙' : ''}${r.g ? '♻' : ''}</span>
    </div>`)}
  </div>`;
}

function Facts() {
  const P = pf.value, pr = P && P.profile, pp = P && P.prepared, B = base.value && base.value.profile;
  const dr = pr && pr.dropped ? Object.entries(pr.dropped).filter(([k, v]) => v > 0 && k !== 'idle') : [];
  const left = dr.reduce((t, [, v]) => t + v, 0);
  if (!pp && !pr) return null;
  return html`<div class="pffacts">
    ${pp ? (pp.ok ? html`<span class="pfprep">compiled ${ms(pp.compile_ms)}</span>`
                  : html`<span class="pfwarn" title=${pp.error}>${String(pp.error).split('\n')[0]}</span>`) : null}
    ${pr ? html`
      <span class="pfmode">${pr.mode || 'cpu'}</span>
      <span>${ms(pr.duration_ms)}${B ? html` <span class="pfdim">(was ${ms(B.duration_ms)})</span>` : null}</span>
      ${pr.unit === 'bytes' ? html`<span>${bytes(pr.samples)} · ${(pr.allocs || 0).toLocaleString()} allocations</span>`
        : html`<span>${pr.samples} samples</span>${pr.threads > 1 ? html`<span>${pr.threads} threads</span>` : null}`}
      ${pr.compile_ms > 0.5 ? html`<span class="c">⚙ ${ms(pr.compile_ms)}</span>` : null}
      ${pr.gc_ms > 0.5 ? html`<span class="g">♻ ${ms(pr.gc_ms)}</span>` : null}
      ${left ? html`<span class="pfdim" title=${dr.map(([k, v]) => v + ' ' + k).join(', ')}>left out ${left}</span>` : null}
      ${pr.buffer_full ? html`<span class="pfwarn" title="the end of the run is missing: profile again with a larger buffer or a longer interval">buffer full</span>` : null}
      ${pr.error ? html`<span class="pfwarn" title=${pr.error}>threw ${String(pr.error).split('\n')[0]}</span>` : null}` : null}
  </div>`;
}

// ── run options, history, comparison, export ───────────────────────────────────────────────────────
function Options() {
  if (!optsOpen.value) return null;
  const o = runOpts();
  const set = (k, v) => { opts.value = { ...opts.value, [k]: v }; lsSet('slateProfOpts', JSON.stringify(opts.value)); };
  const seg = (k, choices) => html`<span class="pfseg">${choices.map(([v, l]) => html`
    <button class=${o[k] === v ? 'on' : ''} onClick=${() => set(k, v)}>${l}</button>`)}</span>`;
  return html`<div class="pfopts" onClick=${e => e.stopPropagation()}>
    <div class="pforow"><span>measure</span>${seg('mode', [['cpu', 'CPU'], ['wall', 'wall time'], ['alloc', 'allocations'], ['gpu', 'GPU']])}</div>
    ${o.mode === 'alloc' ? html`<div class="pforow"><span>record</span>${seg('alloc_rate', [[0.001, '0.1%'], [0.01, '1%'], [0.1, '10%'], [1, 'all']])}</div>`
      : html`<div class="pforow"><span>sample every</span>${seg('delay_ms', [[0.1, '0.1 ms'], [0.5, '0.5 ms'], [1, '1 ms'], [5, '5 ms'], [10, '10 ms']])}</div>
             <div class="pforow"><span>buffer</span>${seg('buffer', [[1000000, '8 MB'], [4000000, '32 MB'], [16000000, '128 MB'], [64000000, '512 MB']])}</div>`}
    <div class="pforow"><span>trace</span><label class="pftog"><input type="checkbox" checked=${o.trace}
      onChange=${e => set('trace', e.currentTarget.checked)}/><i></i>what compiles, and runtime dispatch</label></div>
  </div>`;
}
const when = (at) => { const d = new Date(at * 1000); return d.toLocaleDateString() === new Date().toLocaleDateString() ? d.toLocaleTimeString() : d.toLocaleString(); };
function History() {
  const P = pf.value, h = hist.value;
  if (!P || h.length < 1) return null;
  const shown = P.shownId || (h[0] && h[0].id);
  const label = (e) => when(e.at) + ' · ' + (e.mode || 'cpu') + ' · ' + ms(e.duration_ms);
  return html`<span class="pfhist">
    <select title="a kept profile of this cell" value=${shown} onChange=${e => showKept(e.currentTarget.value)}>
      ${h.map(e => html`<option value=${e.id}>${label(e)}</option>`)}</select>
    <select title="compare with an earlier profile" value=${base.value ? base.value.id : ''} onChange=${e => compareWith(e.currentTarget.value)}>
      <option value="">compare with…</option>
      ${h.filter(e => e.id !== shown).map(e => html`<option value=${e.id}>${label(e)}</option>`)}</select>
  </span>`;
}
function exportAs(format) {
  const P = pf.value; if (!P || !P.profile) return;
  const id = P.shownId || String(Math.round(P.profile.at * 1000));
  const a = document.createElement('a');
  a.href = window._apipath ? window._apipath('/api/profile/export?cell=' + encodeURIComponent(P.cell) + '&id=' + id + '&format=' + format)
                           : '/api/' + encodeURIComponent(window.__slateState.id) + '/profile/export?cell=' + encodeURIComponent(P.cell) + '&id=' + id + '&format=' + format;
  a.download = ''; document.body.appendChild(a); a.click(); a.remove();
}

// ── the profiler specialist ───────────────────────────────────────────────────────────────────────
// Summoned from the dock; it works in the chat pane, where its reasoning and tool calls stream.
const models = signal(null);
const pickOpen = signal(false);
const pickQ = signal('');
const summoning = signal(false);
const bareModel = (m) => String(m).replace(/^acp:\w+:/, '').replace(/^.*\//, '');
const lastModel = () => ls('slateProfModel', ls('slateDbgModel', ''));
async function summon(model) {
  const P = pf.value; if (!P || summoning.value) return;
  summoning.value = true; pickOpen.value = false;
  lsSet('slateProfModel', model);
  try { await A('POST', '/api/profile/agent', { cell: P.cell, model }); } catch (_) {}
  summoning.value = false;
}
function Specialist() {
  const open = async () => {
    pickOpen.value = !pickOpen.value; pickQ.value = '';
    if (!models.value) { try { const r = await A('GET', '/api/acp-models'); models.value = (r && r.models) || []; } catch (_) { models.value = []; } }
  };
  const q = pickQ.value.trim().toLowerCase(), all = models.value || [];
  const shown = (q ? all.filter(m => m.toLowerCase().includes(q)) : all).slice(0, 60);
  const prev = lastModel();
  return html`<span class="pfspec">
    <button class="pfbtn" disabled=${summoning.value} onClick=${open} title="bring in a profiling specialist to work on this cell with you">
      ${summoning.value ? html`<span class="hydspin"></span>` : '＋ specialist'}</button>
    ${pickOpen.value ? html`<div class="pfspecmenu">
      <input autofocus placeholder="search models…" value=${pickQ.value} onInput=${e => pickQ.value = e.target.value}
        onKeyDown=${e => { if (e.key === 'Escape') pickOpen.value = false; else if (e.key === 'Enter' && shown.length) summon(shown[0]); }}/>
      <div class="pfspeclist">
        ${!q && prev ? html`<div class="pfspecrow" onClick=${() => summon(prev)}>↩ ${bareModel(prev)}</div>` : null}
        ${!q ? html`<div class="pfspecrow" onClick=${() => summon('')}>Default model</div>` : null}
        ${models.value === null ? html`<div class="pfspecnote"><span class="hydspin"></span></div>`
          : shown.map(m => html`<div class="pfspecrow" key=${m} onClick=${() => summon(m)}>${bareModel(m)}</div>`)}
      </div>
    </div>` : null}
  </span>`;
}

// ── the dock ──────────────────────────────────────────────────────────────────────────────────────
const searchRef = { current: null };
function Dock() {
  const P = pf.value;
  if (!P) return null;
  const busy = P.status === 'preparing' || P.status === 'running';
  const mt = matches.value;
  const setTab = (t) => { tab.value = t; lsSet('slateProfTab', t); };
  return html`<div class="pfbg" onClick=${e => { if (e.target.classList.contains('pfbg')) close(); else optsOpen.value = false; }}>
    <div class=${'pfdock' + (P.side ? ' remote' : '')}>
      <div class="pfhead">
        <span class="pftitle">Profile</span>
        <span class="pfcell">cell ${P.cell}</span>
        ${P.side ? html`<span class="pfside">on ${P.side}</span>` : null}
        <span class="pfstatus">${busy ? html`<span class="hydspin"></span> ${P.status === 'preparing' ? 'compiling' : 'running'}` : ''}</span>
        ${P.status === 'error' ? html`<span class="pfwarn">${P.error}</span>` : null}
        <span class="pfsp"></span>
        <${History} />
        <${Specialist} />
        <button class="pfbtn" disabled=${busy} onClick=${prepare} title="compile the cell's code without running it">Compile</button>
        <span class="pfrunwrap">
          <button class="pfbtn primary" disabled=${busy} onClick=${run}>▶ Run and profile</button>
          <button class="pfbtn pfmore" onClick=${e => { e.stopPropagation(); optsOpen.value = !optsOpen.value; }} title="what to measure, and how">▾</button>
          <${Options} />
        </span>
        <button class="pfx" onClick=${close} title="close (Esc)">✕</button>
      </div>
      <${Facts} />
      <div class="pfbar2">
        <span class="pftabs">${[['flame', 'Flame graph'], ['timeline', 'Timeline'], ['functions', 'Functions'], ['details', 'Details']].map(([k, l]) =>
          html`<button class=${tab.value === k ? 'on' : ''} onClick=${() => setTab(k)}>${l}</button>`)}</span>
        <input class="pfsearch" ref=${el => (searchRef.current = el)} placeholder="search functions and files  /" value=${query.value}
          onInput=${e => query.value = e.target.value} onKeyDown=${e => { if (e.key === 'Escape') { query.value = ''; e.currentTarget.blur(); e.stopPropagation(); } }}/>
        ${mt ? html`<span class="pfdim">${mt.ids.size} · ${pct(mt.share) || '0%'}</span>` : null}
        <span class="pfsp"></span>
        <span class="pfseg">${[['share', '%'], ['abs', model.value && model.value.bytes ? 'bytes' : 'time']].map(([k, l]) =>
          html`<button class=${unit.value === k ? 'on' : ''} onClick=${() => { unit.value = k; lsSet('slateProfUnit', k); }}>${l}</button>`)}</span>
        <label class="pftog" title="fold library code into one bar per package">
          <input type="checkbox" checked=${fold.value}
            onChange=${e => { fold.value = e.currentTarget.checked; lsSet('slateProfFold', fold.value ? '1' : '0'); }}/><i></i>fold libraries</label>
        <span class="pfexport">export
          <button onClick=${() => exportAs('speedscope')} title="for speedscope.app">speedscope</button>
          <button onClick=${() => exportAs('pprof')} title="for go tool pprof and its viewers">pprof</button></span>
      </div>
      <div class="pfbody">
        <${Code} />
        <div class="pfright">
          <${Crumbs} />
          ${tab.value === 'timeline' ? html`<${Timeline} />` : tab.value === 'functions' ? html`<${Functions} />`
            : tab.value === 'details' ? html`<${Details} />` : html`<${Flame} />`}
          ${tab.value === 'flame' || tab.value === 'timeline' ? html`<${Hot} />` : null}
        </div>
      </div>
    </div>
  </div>`;
}

// ── keys ──────────────────────────────────────────────────────────────────────────────────────────
// While the dock is open and no text field has the keys: arrows walk the graph (← → siblings,
// ↑ caller, ↓ heaviest callee), Enter zooms to the selection, + − 0 zoom, / searches.
document.addEventListener('keydown', (e) => {
  if (!pf.value) return;
  if (e.key === 'Escape') {
    if (optsOpen.value || pickOpen.value) { optsOpen.value = false; pickOpen.value = false; e.stopPropagation(); return; }
    e.stopPropagation(); close(); return;
  }
  const tag = (e.target && e.target.tagName) || '';
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (e.target && e.target.isContentEditable)) return;
  const M = model.value; if (!M) return;
  const sig = tab.value === 'timeline' ? tview : view, { v0, v1 } = sig.value, mid = (v0 + v1) / 2;
  const cur = M.nodes[sel.value] || null;
  const sib = (d) => { if (!cur) return null; const p = M.nodes[cur.parent]; if (!p) return null; const i = p.kids.indexOf(cur); return p.kids[i + d] || null; };
  let n = null;
  switch (e.key) {
    case '/': e.preventDefault(); searchRef.current && searchRef.current.focus(); return;
    case '+': case '=': zoomAt(sig, mid, 0.5); break;
    case '-': case '_': zoomAt(sig, mid, 2); break;
    case '0': zoom.value = 1; animateTo(sig, 0, 1); break;
    case 'Enter': if (cur) focusOn(cur.id); break;
    case 'ArrowUp': n = cur ? M.nodes[cur.parent] : null; break;
    case 'ArrowDown': n = cur ? cur.kids.reduce((b, k) => (!b || k.total > b.total ? k : b), null) : (M.nodes[1].kids[0] || null); break;
    case 'ArrowLeft': n = sib(-1); break;
    case 'ArrowRight': n = sib(1); break;
    default: return;
  }
  e.preventDefault();
  if (n && n.id !== 1) select(n);
}, true);

const style = document.createElement('style');
style.textContent = `
.pfbg { position:fixed; inset:0; z-index:70; background:rgba(0,0,0,.55); display:flex; align-items:center;
  justify-content:center; padding:24px; }
body.agent-open .pfbg { right:var(--agentw, 380px); }
.pfdock { position:relative; display:flex; flex-direction:column; width:min(1700px,100%); height:min(980px,100%);
  background:var(--bg); border:1px solid color-mix(in srgb, #e8933a 40%, var(--border)); border-radius:12px;
  overflow:hidden; box-shadow:0 18px 60px rgba(0,0,0,.45); }
.pfdock.remote { border-color:color-mix(in srgb, var(--purple) 45%, var(--border)); }
.pfhead { display:flex; align-items:center; gap:10px; padding:8px 12px; border-bottom:1px solid var(--border);
  background:color-mix(in srgb, #e8933a 8%, var(--bg2)); }
.pftitle { color:#e8933a; font-weight:600; font-size:.86rem; }
.pfcell, .pfside { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); font-size:.78rem; }
.pfside { color:var(--purple); }
.pfstatus { display:inline-flex; align-items:center; gap:6px; color:var(--text); font-size:.76rem; }
.pfsp { flex:1 1 auto; }
.pfwarn { color:var(--red); font-size:.74rem; }
.pfdim { color:var(--dim); font-size:.72rem; }
.pfbtn { font:inherit; font-size:.76rem; padding:4px 12px; border-radius:6px; cursor:pointer;
  background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.pfbtn:hover { border-color:#e8933a; }
.pfbtn.primary { border-color:color-mix(in srgb, #e8933a 60%, var(--border)); background:color-mix(in srgb, #e8933a 18%, var(--bg3)); }
.pfbtn[disabled] { opacity:.5; cursor:default; }
.pfrunwrap { position:relative; display:inline-flex; }
.pfrunwrap .primary { border-top-right-radius:0; border-bottom-right-radius:0; }
.pfmore { border-top-left-radius:0; border-bottom-left-radius:0; border-left:none; padding:4px 8px; }
.pfopts { position:absolute; right:0; top:calc(100% + 4px); z-index:6; min-width:360px; padding:10px 12px;
  display:flex; flex-direction:column; gap:8px; background:var(--bg2); border:1px solid var(--border);
  border-radius:8px; box-shadow:0 12px 32px rgba(0,0,0,.5); font-size:.74rem; }
.pforow { display:flex; align-items:center; gap:10px; }
.pforow > span:first-child { width:90px; color:var(--dim); }
.pfseg { display:inline-flex; gap:2px; }
.pfseg button { font:inherit; font-size:.72rem; padding:2px 8px; border:1px solid var(--border); border-radius:5px;
  background:none; color:var(--dim); cursor:pointer; }
.pfseg button:hover { color:var(--text); }
.pfseg button.on { color:var(--text); background:color-mix(in srgb, #e8933a 20%, transparent); border-color:color-mix(in srgb, #e8933a 55%, transparent); }
.pfx { padding:2px 8px; border-radius:6px; background:transparent; border:1px solid transparent; color:var(--dim); cursor:pointer; }
.pfx:hover { color:var(--red); border-color:var(--border); background:var(--bg3); }
.pftog { display:inline-flex; align-items:center; gap:6px; color:var(--dim); font-size:.74rem; cursor:pointer; user-select:none; }
.pftog input { display:none; }
.pftog i { position:relative; width:24px; height:13px; border-radius:7px; background:var(--bg3); border:1px solid var(--border); }
.pftog i::after { content:''; position:absolute; top:1px; left:1px; width:9px; height:9px; border-radius:50%; background:var(--dim); transition:transform .15s; }
.pftog input:checked + i { border-color:#e8933a; background:color-mix(in srgb, #e8933a 30%, transparent); }
.pftog input:checked + i::after { transform:translateX(11px); background:#e8933a; }
.pfhist { display:inline-flex; gap:4px; }
.pfhist select { font:inherit; font-size:.72rem; max-width:220px; padding:3px 5px; border-radius:5px; background:var(--bg3);
  color:var(--text); border:1px solid var(--border); }
.pffacts { padding:6px 12px; border-bottom:1px solid var(--border); background:var(--bg2); font-size:.76rem;
  display:flex; flex-wrap:wrap; align-items:center; gap:14px; color:var(--text); white-space:nowrap; }
.pffacts .pfwarn { overflow:hidden; text-overflow:ellipsis; max-width:60ch; }
.pfprep { color:var(--dim); }
.pfmode { color:#e8933a; }
.pffacts .c { color:#b9a3f5; }
.pffacts .g { color:#f08a92; }
.pfbar2 { display:flex; align-items:center; gap:10px; padding:5px 12px; border-bottom:1px solid var(--border); font-size:.74rem; }
.pftabs { display:inline-flex; gap:2px; }
.pftabs button { font:inherit; font-size:.76rem; padding:3px 10px; border:1px solid transparent; border-radius:6px;
  background:none; color:var(--dim); cursor:pointer; }
.pftabs button:hover { color:var(--text); }
.pftabs button.on { color:var(--text); border-color:var(--border); background:var(--bg3); }
.pfsearch { font:inherit; font-size:.74rem; width:240px; padding:3px 8px; border-radius:5px; background:var(--bg);
  color:var(--text); border:1px solid var(--border); }
.pfexport { display:inline-flex; align-items:center; gap:4px; color:var(--dim); }
.pfexport button { font:inherit; font-size:.72rem; padding:2px 7px; border-radius:5px; cursor:pointer; background:var(--bg3);
  color:var(--text); border:1px solid var(--border); }
.pfexport button:hover { border-color:#e8933a; }
.pfbody { flex:1 1 auto; min-height:0; display:grid; grid-template-columns:minmax(320px, 38%) minmax(0, 1fr); }
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
.pfkey { display:inline-flex; gap:10px; color:var(--dim); font-size:.7rem; }
.pfkey i { font-style:normal; margin-right:3px; }
.pfzoom { display:inline-flex; align-items:center; gap:3px; margin-left:10px; }
.pfzoom button { font:inherit; min-width:24px; padding:1px 7px; border-radius:5px; cursor:pointer;
  background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.pfzoom button:hover { border-color:#e8933a; }
.pfzoom button[disabled] { opacity:.45; cursor:default; }
.pfzx { min-width:38px; text-align:center; color:var(--dim); font-variant-numeric:tabular-nums; }
.pfgraph { display:flex; flex-direction:column; flex:1 1 60%; min-height:0; }
.pfmini { display:block; margin:4px 8px 0; cursor:pointer; border-bottom:1px solid var(--border); }
.pfflame { position:relative; flex:1 1 60%; min-height:0; overflow:auto; padding:6px 8px; }
.pfflame canvas { display:block; cursor:pointer; }
.pfflame:active canvas { cursor:grabbing; }
.pfempty { display:flex; align-items:center; justify-content:center; gap:8px; color:var(--dim); font-size:.82rem; }
.pftip { display:none; position:absolute; z-index:2; max-width:250px; pointer-events:none; padding:6px 8px;
  border-radius:6px; background:var(--bg2); border:1px solid var(--border); box-shadow:0 6px 20px rgba(0,0,0,.4);
  font-size:.72rem; color:var(--text); }
.pftip b { font-family:var(--mono,ui-monospace,monospace); font-weight:600; }
.pftw { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); }
.pftm { color:#ffd27a; }
.pfhot { flex:0 0 auto; max-height:30%; overflow:auto; border-top:1px solid var(--border); font-size:.74rem; }
.pfhothead, .pfhotrow { display:grid; grid-template-columns:64px 64px minmax(0,1fr) 48px; gap:6px; padding:3px 10px; }
.pfhothead.cmp, .pfhotrow.cmp { grid-template-columns:64px 64px 56px minmax(0,1fr) 48px; }
.pfhothead { color:var(--dim); font-size:.68rem; position:sticky; top:0; background:var(--bg); }
.pfhotrow { cursor:pointer; }
.pfhotrow:hover { background:color-mix(in srgb, #e8933a 12%, transparent); }
.pfnum { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
.pfnum.dim { color:var(--dim); }
.pfloc { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfsnip { color:var(--dim); margin-left:8px; }
.pfmk { color:#ffd27a; }
.pffuncs { flex:1 1 auto; min-height:0; display:grid; grid-template-rows:minmax(0,1fr) minmax(0, 40%); }
.pftable { overflow:auto; font-size:.74rem; }
.pfthead, .pftrow { display:grid; grid-template-columns:64px 64px minmax(0, 1.3fr) minmax(0, 1fr) 44px; gap:8px; padding:3px 10px; }
.pfthead { color:var(--dim); font-size:.68rem; position:sticky; top:0; background:var(--bg); border-bottom:1px solid var(--border); }
.pftrow { cursor:pointer; }
.pftrow:hover { background:color-mix(in srgb, #e8933a 10%, transparent); }
.pftrow.on { background:color-mix(in srgb, #ff6fd8 14%, transparent); }
.pffn { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pffile { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:var(--mono,ui-monospace,monospace); }
.pfsandwich { border-top:1px solid var(--border); overflow:auto; display:grid; grid-template-columns:1fr auto 1fr; gap:10px; padding:6px 10px; font-size:.74rem; }
.pfsandwich.pfempty { display:flex; }
.pfrelhead { color:var(--dim); font-size:.68rem; text-transform:uppercase; letter-spacing:.04em; margin-bottom:3px; }
.pfrelrow { display:grid; grid-template-columns:56px 60px minmax(0,1fr) auto; gap:6px; align-items:center; padding:2px 0; cursor:pointer; }
.pfrelrow:hover .pffn { color:#ff6fd8; }
.pfrelmid { align-self:center; text-align:center; font-family:var(--mono,ui-monospace,monospace); }
.pfrelmid .pfdim { display:block; }
.pfbar { display:inline-block; height:6px; background:var(--bg3); border-radius:3px; overflow:hidden; }
.pfbar i { display:block; height:100%; background:#e8933a; }
.pfdetails { flex:1 1 auto; overflow:auto; padding:8px 10px; display:flex; flex-direction:column; gap:14px; font-size:.74rem; }
.pfdetrow { display:grid; grid-template-columns:80px 80px minmax(0,1fr); gap:8px; padding:2px 0; }
.pfdethead { color:var(--dim); font-size:.68rem; }
.pfsig { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfspec { position:relative; }
.pfspecmenu { position:absolute; right:0; top:calc(100% + 4px); z-index:5; width:280px; padding:6px;
  background:var(--bg2); border:1px solid var(--border); border-radius:8px; box-shadow:0 12px 32px rgba(0,0,0,.5); }
.pfspecmenu input { width:100%; box-sizing:border-box; font:inherit; font-size:.76rem; padding:4px 7px; border-radius:5px;
  background:var(--bg); color:var(--text); border:1px solid var(--border); }
.pfspeclist { max-height:300px; overflow:auto; margin-top:5px; }
.pfspecrow { padding:4px 7px; border-radius:5px; cursor:pointer; font-size:.76rem; font-family:var(--mono,ui-monospace,monospace); }
.pfspecrow:hover { background:color-mix(in srgb, #e8933a 14%, transparent); }
.pfspecnote { padding:6px; text-align:center; }
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
