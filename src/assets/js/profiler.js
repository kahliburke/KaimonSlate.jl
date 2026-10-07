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
import { signal, computed, effect } from '@preact/signals';
import { lockScroll } from './scrolllock.js';
import { specialistPane } from './specpane.js';
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
// What a bar's colour says: whose code it is, or how much time was spent in it (its self time).
const colorBy = signal(ls('slateProfColor', 'time'));   // 'time' | 'code'
const opened = signal(new Set()); // folded library bars clicked open
const codeAt = signal({ file: '', line: 0 });
const srcs = signal({});         // file → {text, error}, as the cell's machine has it
const optsOpen = signal(false);
const opts = signal((() => { try { return JSON.parse(ls('slateProfOpts', '')) || {}; } catch (_) { return {}; } })());
const runOpts = () => Object.assign({ mode: 'cpu', delay_ms: 1, buffer: 4000000, trace: true, alloc_rate: 0.001 }, opts.value);

const pct = (x) => !(x > 0) ? '' : x >= 0.995 ? '100%' : x >= 0.1 ? Math.round(x * 100) + '%' : x >= 0.001 ? (x * 100).toFixed(1) + '%' : '<0.1%';
const ms = (x) => !(x >= 0) ? '' : x >= 10000 ? (x / 1000).toFixed(1) + ' s' : x >= 1000 ? (x / 1000).toFixed(2) + ' s' : x >= 10 ? Math.round(x) + ' ms' : x.toFixed(1) + ' ms';
const bytes = (b) => !(b >= 0) ? '' : b >= 1 << 30 ? (b / (1 << 30)).toFixed(1) + ' GB' : b >= 1 << 20 ? (b / (1 << 20)).toFixed(1) + ' MB' : b >= 1 << 10 ? Math.round(b / (1 << 10)) + ' KB' : b + ' B';
// A file as a reader names it: a package's from the package, Julia's own from base or the stdlib,
// and anything else by its last two parts.
const shortFile = (f) => {
  if (!f || f.startsWith('cell:')) return f || '';
  const s = f.replace(/^.*\/(?:packages|dev)\/([^/]+)\/[^/]+\//, '$1/').replace(/^.*\/share\/julia\/(?:base|stdlib\/[^/]+)\//, '').replace(/^\.\//, '');
  const parts = s.split('/');
  return s.startsWith('/') && parts.length > 3 ? '…/' + parts.slice(-2).join('/') : s;
};
const K = { line: 0, compile: 1, gc: 2, other: 3, synth: 4 };
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
const escapeHtml = (s) => window.slateEscHtml(s);   // esc.js: the front end's one escaper

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
    // Names the compiler made: `#f#12` is the body of `f` (a function with keyword arguments is a
    // wrapper and a body), shown and counted as `f`; `#12` is a closure, shown as one.
    x.rawFunc = x.func;
    if (x.kind === K.line) {
      const kw = /^#([^#\d][^#]*)#\d+$/.exec(x.func);
      if (kw) x.func = kw[1];
      else if (/^#\d+$/.test(x.func) || /^#[^#]+##\d+/.test(x.func)) { x.closure = true; x.func = 'closure'; }
    }
    x.fk = x.kind === K.line ? (x.closure ? x.rawFunc : x.func) + '\x1f' + x.file : '\x1f' + x.func;
    x.key = (p ? p.key + '\x1e' : '') + x.rawFunc + '@' + x.file + ':' + x.line + '#' + x.kind;
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
           bytes: P.unit === 'bytes', delay: P.delay_ms || 1,
           // An allocation profile records a share of the allocations; its bytes stand for 1/rate as many.
           scale: P.unit === 'bytes' && P.alloc_rate ? 1 / P.alloc_rate : 1 };
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
  return M.bytes ? bytes(v * M.scale) : ms(v * M.delay);
}

const isLib = (n, M) => n.kind === K.line && !(n.pkg === 'cell' || n.pkg === 'notebook' || M.mine.has(n.pkg));

// With library code folded, the tables charge each sample to the deepest line of the reader's own
// code on its stack: a line's share is its own time and that of the library calls it makes (and
// the GC, compiling and BLAS under them), which is where a fix would go.
const ownTime = computed(() => {
  const M = model.value; if (!M) return null;
  const lines = new Map(), fns = new Map();
  for (const n of M.nodes) {
    if (!n || !n.self || n.id === 1) continue;
    let u = n;
    while (u && u.id !== 1 && !(u.kind === K.line && !isLib(u, M))) u = M.nodes[u.parent];
    if (!u || u.id === 1) continue;
    const k = u.file + '\x1f' + u.line;
    let r = lines.get(k);
    if (!r) {
      const b = (M.lines.get(u.file) || new Map()).get(u.line) || { incl: 0 };
      r = { line: u.line, incl: b.incl, file: u.file, self: 0, d: 0, g: 0, c: 0 };
      lines.set(k, r);
    }
    r.self += n.self / M.total; r.d += n.d || 0; r.g += n.g || 0; r.c += n.c || 0;
    fns.set(u.fk, (fns.get(u.fk) || 0) + n.self);
  }
  return { lines, fns };
});

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
  const get = (n) => by.get(n.fk) || (by.set(n.fk, { fk: n.fk, func: n.func, file: n.file, pkg: n.pkg, kind: n.kind, closure: n.closure,
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
  const add = (m, n, v) => { const e = m.get(n.fk) || { fk: n.fk, func: n.func, file: n.file, kind: n.kind, closure: n.closure, line: n.line, v: 0 };
                              e.v += v; if (n.line < e.line) e.line = n.line; m.set(n.fk, e); };
  // Folded, library frames are looked through: a caller is the nearest function of the reader's own
  // above, a callee their nearest function below, and time spent in library code directly is one
  // entry per package (GC and compiling keep their own).
  const own = fold.value, mine = (n) => n.kind === K.line && !isLib(n, M);
  const libCall = (k, v) => add(callees, k.pkg
    ? { fk: '\x1flib:' + k.pkg, func: k.pkg + ' (library calls)', file: '', kind: K.synth }
    : { fk: '\x1flib:' + k.func, func: k.func, file: '', kind: K.synth }, v);
  const below = (k) => {                   // returns the time in k's subtree accounted for
    if (mine(k)) { add(callees, k, k.total); return k.total; }
    let under = 0;
    for (const c of k.kids) under += below(c);
    if (k.total - under > 0) libCall(k, k.total - under);
    return k.total;
  };
  for (const n of f.nodes) {
    let p = M.nodes[n.parent];
    // A function's own lines are not its callers, and folded, neither is library code.
    while (p && p.id !== 1 && (p.fk === n.fk || (own && !mine(p)))) p = M.nodes[p.parent];
    if (p && p.id !== 1) add(callers, p, n.total);
    else add(callers, { fk: '\x1fcell', func: 'cell ' + M.P.cell, file: M.cellFile, kind: K.synth }, n.total);
    for (const k of n.kids) if (k.fk !== n.fk) own ? below(k) : add(callees, k, k.total);
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
// `kept`: a kept profile's id, to show that one rather than the latest (a run on the telemetry timeline).
export async function openProfile(cellId, kept = '') {
  resumeSpecialist();
  pf.value = { cell: cellId, side: '', status: 'loading', prepared: null, profile: null, source: cellSource(cellId), error: null };
  hist.value = []; base.value = null; query.value = '';
  resetView(cellId);
  loadHistory(cellId);
  try {
    if (kept) await showKept(kept);
    else {
      const r = await A('GET', '/api/profile/last?cell=' + encodeURIComponent(cellId));
      if (r && pf.value && pf.value.cell === cellId)
        pf.value = { ...pf.value, prepared: r.prepared || null, jet: r.jet, pkgManageable: r.pkgManageable !== false };
      if (r && r.kind === 'result') apply(r);
    }
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
  else if (p.kind === 'prepared') Object.assign(next, { status: 'idle', prepared: p, jet: p.static && p.static.available ? true : cur.jet });
  else if (p.kind === 'running') Object.assign(next, { status: 'running', error: null });
  else if (p.kind === 'waiting') Object.assign(next, { status: 'waiting', error: null, why: p.why });
  else if (p.kind === 'error') Object.assign(next, { status: 'error', error: p.error });
  else if (p.kind === 'result') {
    // A new profile is compared with the one shown before it, which is usually the question.
    const was = cur.profile && cur.status === 'done' ? { id: String(Math.round(cur.profile.at * 1000)), profile: cur.profile } : null;
    Object.assign(next, { status: 'done', profile: p.profile, source: p.source || cur.source, error: null,
                          shownId: String(Math.round(p.profile.at * 1000)) });
    if (was && !base.value) base.value = was;
    resetView(cur.cell);
    loadHistory(cur.cell);
  }
  pf.value = next;
}
window.onProfilePush = (p) => apply(p);
window.slateProfileCell = (id, kept) => openProfile(id, kept || '');
window.slateProfileOpen = () => !!pf.value;
effect(() => lockScroll('profiler', !!pf.value));   // the notebook stays still under the dock

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
  if (tab.value === 'timeline') {
    // The timeline zooms to the stretch of time the frame was on any thread.
    const TL = timeline.value; if (!TL) return;
    let a = Infinity, b = -Infinity;
    for (const L of TL.lanes) for (const r of L.rects) if (r.n.id === id) { a = Math.min(a, r.t0); b = Math.max(b, r.t1); }
    if (a < b) animateTo(tview, a / TL.end, b / TL.end);
    return;
  }
  const root = dview.value;
  if (root && (!_lay || _lay.root !== root)) _lay = layout(root);
  const sp = _lay && _lay.span.get(id);
  if (sp) animateTo(view, sp[0], sp[0] + sp[1]);
}
// A canvas pane is drawn again when its size changes (a split dragged, the window resized).
function useRedrawOnResize(boxRef, draw, live) {
  useEffect(() => {
    const el = boxRef.current; if (!el || !window.ResizeObserver) return;
    let raf = 0;
    const ro = new ResizeObserver(() => { cancelAnimationFrame(raf); raf = requestAnimationFrame(() => draw.current && draw.current()); });
    ro.observe(el);
    return () => { cancelAnimationFrame(raf); ro.disconnect(); };
  }, [live]);
}
// Wheel and drag for a canvas showing `sig`'s window. The wheel zooms about the pointer, and a
// sideways scroll (or shift + wheel) pans. Where the pane has rows to scroll to (`scrolls`: a deep
// graph), the wheel scrolls them and ⌘/Ctrl + wheel zooms; ⌥ + wheel always scrolls.
function useZoomPan(boxRef, canvasRef, sig, { scrolls = () => false } = {}) {
  useEffect(() => {
    const el = boxRef.current; if (!el) return;
    const wheel = (ev) => {
      const b = canvasRef.current && canvasRef.current.getBoundingClientRect(); if (!b) return;
      const { v0, v1 } = sig.value, f = v0 + clamp((ev.clientX - b.left) / b.width, 0, 1) * (v1 - v0);
      const px = ev.deltaMode === 1 ? 16 : ev.deltaMode === 2 ? b.height : 1;
      const dx = ev.deltaX * px, dy = ev.deltaY * px;
      if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); zoomAt(sig, f, Math.exp(dy * 0.0025)); }
      else if (Math.abs(dx) > Math.abs(dy) || ev.shiftKey) {
        ev.preventDefault();
        const d = (Math.abs(dx) > Math.abs(dy) ? dx : dy) / b.width * (v1 - v0);
        setV(sig, v0 + d, v1 + d);
      } else if (!ev.altKey && !scrolls(el)) { ev.preventDefault(); zoomAt(sig, f, Math.exp(dy * 0.002)); }
    };
    el.addEventListener('wheel', wheel, { passive: false });
    return () => el.removeEventListener('wheel', wheel);
  });
}
const _overflows = (el) => el.scrollHeight > el.clientHeight + 2;

// Shift + drag marks a span, and letting go zooms to it.
function rangeDrag(ev, canvas, sig, band, box) {
  const b = canvas.getBoundingClientRect(), { v0, v1 } = sig.value;
  const x0 = clamp(ev.clientX, b.left, b.right);
  const show = (x1) => Object.assign(band.style, {
    display: 'block', left: (canvas.offsetLeft + Math.min(x0, x1) - b.left) + 'px', width: Math.abs(x1 - x0) + 'px',
    top: box.scrollTop + 'px', height: box.clientHeight + 'px' });
  const mv = (e) => show(clamp(e.clientX, b.left, b.right));
  const up = (e) => {
    window.removeEventListener('mousemove', mv); window.removeEventListener('mouseup', up);
    band.style.display = 'none';
    const x1 = clamp(e.clientX, b.left, b.right);
    if (Math.abs(x1 - x0) < 4) return;
    const at = (x) => v0 + (x - b.left) / b.width * (v1 - v0);
    animateTo(sig, at(Math.min(x0, x1)), at(Math.max(x0, x1)));
  };
  window.addEventListener('mousemove', mv); window.addEventListener('mouseup', up);
  show(x0);
}
// Double-click on nothing: back out, twice as wide, about the pointer.
function zoomOutAt(ev, canvas, sig) {
  const b = canvas.getBoundingClientRect(), { v0, v1 } = sig.value;
  const f = v0 + clamp((ev.clientX - b.left) / b.width, 0, 1) * (v1 - v0), s = Math.min(1, (v1 - v0) * 2);
  const a = clamp(f - (f - v0) * 2, 0, 1 - s);
  animateTo(sig, a, a + s);
}
function dragPan(ev, dr, canvas, sig) {
  if (!dr || dr.range || ev.buttons !== 1) return false;
  const dx = ev.clientX - dr.x;
  if (Math.abs(dx) > 3) dr.moved = true;
  if (!dr.moved) return false;
  const d = -dx / canvas.getBoundingClientRect().width * (dr.v1 - dr.v0);
  setV(sig, dr.v0 + d, dr.v1 + d);
  return true;
}

// ── colour ────────────────────────────────────────────────────────────────────────────────────────
// A family of colours per kind of code, and within it a shade per function, so two neighbouring
// functions are told apart: teal for the notebook's own code, green for packages being worked on,
// slate for Base, a muted blue-to-violet for each other package. No warm colours: they read as
// "expensive", which is what the time colouring says, not this one.
const KIND_COLOR = { [K.compile]: '#8a6fd1', [K.gc]: '#cf5560', [K.other]: '#363b52', [K.synth]: '#454b6b' };
function hue(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0; return h; }
const _colors = new Map();
// Self time on a cool-to-hot scale, relative to the heaviest: where the time is actually spent
// glows, everything that only passes through is cool. A line is coloured by its own time over all
// the places it was called from, as the hot lines table counts it, so a line called from four places
// is as hot as its total.
function selfOf(dn, M) {
  const n = dn.n || dn;
  if (!dn.folded && n.kind === K.line) {
    const s = lineSelf(n, M);
    if (s != null) return s * M.total;
  }
  return dn.self;
}
// A line's self share as the hot lines table counts it: with library code folded, a line of the
// reader's own code also carries the library calls, GC and waiting under it.
function lineSelf(n, M) {
  const own = fold.value && !isLib(n, M) && ownTime.value;
  if (own) { const r = own.lines.get(n.file + '\x1f' + n.line); return r ? r.self : 0; }
  const row = M.lines.get(n.file) && M.lines.get(n.file).get(n.line);
  return row ? row.self : null;
}
function heatColor(self, M) {
  const key = fold.value ? 'maxOwn' : 'maxSelf';
  if (M[key] == null) {
    let m = 1;
    for (const rows of M.lines.values()) for (const r of rows.values()) m = Math.max(m, r.self * M.total);
    if (fold.value && ownTime.value) for (const r of ownTime.value.lines.values()) m = Math.max(m, r.self * M.total);
    for (const x of M.nodes) if (x && x.kind !== K.line && x.self > m) m = x.self;
    M[key] = m;
  }
  const f = Math.sqrt(Math.min(1, Math.max(0, self) / M[key]));
  if (f < 0.04) return 'hsl(222, 22%, 30%)';
  // Blue through violet to red-orange: one direction round the wheel, never through green.
  return `hsl(${Math.round(212 + 160 * f) % 360}, ${Math.round(48 + 32 * f)}%, ${Math.round(36 + 16 * f)}%)`;
}
// A bar's colour: its code's colour, or its self time's, as `colorBy` says.
const barColor = (dn, M) => colorBy.value === 'time' ? heatColor(selfOf(dn, M), M) : colorOf(dn.n || dn, M);

function colorOf(n, M) {
  // A runtime node that belongs to a package (BLAS work, under LinearAlgebra) takes the package's colour.
  if (n.kind !== K.line && !(n.kind === K.synth && n.pkg)) return KIND_COLOR[n.kind] || '#454b6b';
  const key = n.pkg + '\x1f' + n.func + (M.mine.has(n.pkg) ? '\x1fm' : '');
  let c = _colors.get(key);
  if (c) return c;
  const h = hue(n.func), j = (h % 1000) / 1000, j2 = ((h >>> 10) % 1000) / 1000;
  if (n.pkg === 'cell') c = `hsl(${180 + j * 16}, ${50 + j2 * 14}%, ${38 + j2 * 8}%)`;
  else if (n.pkg === 'notebook') c = `hsl(${198 + j * 14}, ${46 + j2 * 12}%, ${38 + j2 * 7}%)`;
  else if (M.mine.has(n.pkg)) c = `hsl(${138 + j * 18}, ${38 + j2 * 12}%, ${36 + j2 * 8}%)`;
  else if (n.pkg === 'Base') c = `hsl(${222 + j * 16}, ${14 + j2 * 8}%, ${38 + j2 * 8}%)`;
  else c = `hsl(${236 + hue(n.pkg) % 70}, ${22 + j2 * 10}%, ${40 + j * 8}%)`;
  _colors.set(key, c);
  return c;
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
// Placed in the window, beside the pointer and flipped away from an edge. Inside the scrolling pane
// it would lengthen the pane near the bottom, move it under the pointer, and lose the hover.
function placeTip(t, ev) {
  t.style.display = 'block';
  const w = t.offsetWidth, h = t.offsetHeight, pad = 8;
  let x = ev.clientX + 14, y = ev.clientY + 16;
  if (x + w > window.innerWidth - pad) x = ev.clientX - w - 14;
  if (y + h > window.innerHeight - pad) y = ev.clientY - h - 12;
  t.style.left = Math.max(pad, x) + 'px';
  t.style.top = Math.max(pad, y) + 'px';
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
      const sum = { total: 0, self: 0, d: 0, g: 0, c: 0 };   // the function's, over its lines here
      while (j < ks.length && key(ks[j]) === key(ks[i])) {
        gu += ks[j].total / T;
        for (const f of ['total', 'self', 'd', 'g', 'c']) sum[f] += ks[j][f];
        j++;
      }
      rects.push({ band: true, u, uw: gu, y, h: BAND, dn: { ...ks[i], ...sum }, d });
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

// `yOff`/`viewH`: the part of the graph on screen; only that is drawn, at `y - yOff`.
function drawFlame(g, L, W, vw, M, { mini = false, yOff = 0, viewH = Infinity } = {}) {
  const kx = W / (vw.v1 - vw.v0), out = [];
  const hl = hotLine.value, hv = hover.value, mt = matches.value, fsel = fnSel.value;
  for (const r of L.rects) {
    const x = (r.u - vw.v0) * kx, w = r.uw * kx;
    if (w < 0.5 || x + w < 0 || x > W) continue;
    if (!mini && (r.y + r.h < yOff || r.y > yOff + viewH)) continue;
    const cx = Math.max(0, x), cw = Math.min(W, x + w) - cx;
    const y = mini ? (r.d + 1) * 4 : r.y - yOff, h = mini ? (r.band ? 0 : 3) : r.h;
    if (h <= 0) continue;
    out.push({ ...r, x: cx, w: cw, y });
    const dn = r.dn, n = dn.n;
    const dim = mt && !mt.ids.has(n.id) && !r.top;
    g.globalAlpha = (r.band ? 0.42 : 1) * (dim ? 0.28 : 1);
    g.fillStyle = (!r.band && !dn.folded && diffColor(n, M)) || barColor(dn, M);
    const bw = Math.max(0.5, cw - 1), bh = h - (mini ? 0 : 1);
    if (!mini && bw > 4 && g.roundRect) {
      // A function's band and its line rows read as one block: rounded on the outside only.
      g.beginPath();
      g.roundRect(cx + (x >= 0 ? 0.5 : 0), y + 0.5, bw, bh, r.band ? [3, 3, 0, 0] : [0, 0, 2, 2]);
      g.fill();
    } else g.fillRect(cx + (x >= 0 ? 0.5 : 0), y + 0.5, bw, bh);
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
    const label = r.top ? funcLabel(dn) + '  ·  ' + (M.bytes ? '≈ ' + bytes(M.total * M.scale) + ' allocated' : M.P.samples + ' samples')
                : r.band ? funcLabel(dn) + (dn.folded ? '  ▸' : '') : cellLabel(dn);
    const room = cw - 8 - (r.band ? 0 : 14);
    if (room > 14) {
      g.fillStyle = r.band ? 'rgba(232,235,248,.92)' : '#fbfbfe';
      g.font = r.band ? '600 10px system-ui, sans-serif' : '11px ui-monospace, SFMono-Regular, Menlo, monospace';
      g.fillText(fit(g, label, room), cx + 4, r.y + r.h / 2 + 0.5);
    }
  }
  return out;
}

// How far down its scroll spacer a sticky canvas sits: the y in the graph its top row shows.
const scrolledBy = (c) => Math.max(0, c.getBoundingClientRect().top - c.parentNode.getBoundingClientRect().top);
function sizeCanvas(c, W, H) {
  const dpr = window.devicePixelRatio || 1;
  c.width = W * dpr; c.height = H * dpr; c.style.width = W + 'px'; c.style.height = H + 'px';
  const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
  return g;
}

// The canvas covers only the visible part of the scroll area, and is drawn for where it is scrolled
// to: a deep graph (or a timeline of many threads) stays inside the browser's canvas limits.
function Flame() {
  const M = model.value, root = dview.value, vw = view.value;
  // Read here so a change redraws: the canvas reads them only while drawing.
  void [sel.value, hover.value, hotLine.value, matches.value, fnSel.value, baseShare.value, unit.value, srcs.value, colorBy.value];
  const box = useRef(null), cv = useRef(null), mini = useRef(null), tip = useRef(null), drawn = useRef([]), drag = useRef(null);
  const draw = useRef(null);
  if (M && root && (!_lay || _lay.root !== root)) _lay = layout(root);
  draw.current = () => {
    const el = box.current, c = cv.current; if (!el || !c || !M || !root || !_lay) return;
    const W = Math.max(200, el.clientWidth - 18), viewH = Math.min(_lay.height, Math.max(40, el.clientHeight - 12));
    const g = sizeCanvas(c, W, viewH);
    drawn.current = drawFlame(g, _lay, W, view.value, M, { yOff: scrolledBy(c), viewH });
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
  };
  useEffect(() => { draw.current && draw.current(); });
  // Lines of other cells are labelled with their text, which the hub has.
  useEffect(() => {
    if (!M) return;
    const files = new Set();
    for (let i = 1; i < M.nodes.length; i++) { const f = M.nodes[i] && M.nodes[i].file; if (f && f.startsWith('cell:')) files.add(f); }
    for (const f of files) if (!srcText(f)) loadSource(f);
  }, [M]);
  useRedrawOnResize(box, draw, !!(M && root));
  useZoomPan(box, cv, view, { scrolls: _overflows });
  const stt = pf.value && pf.value.status;
  if (!M || !root) return html`<div class="pfflame pfempty">${
    stt === 'loading' ? html`<span class="hydspin"></span>`
    : stt === 'running' ? html`<span class="hydspin"></span> profiling`
    : stt === 'waiting' ? html`<span class="hydspin"></span> waiting to run`
    : stt === 'preparing' ? html`<span class="hydspin"></span> compiling`
    : html`<button class="pfbtn primary pfbig" onClick=${run}>▶ Run and profile</button>`}</div>`;
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
    placeTip(t, ev);
  };
  const band = useRef(null);
  const down = (ev) => {
    if (ev.button !== 0) return;
    if (ev.shiftKey && cv.current) { ev.preventDefault(); drag.current = { range: true, moved: true }; rangeDrag(ev, cv.current, view, band.current, box.current); return; }
    drag.current = { x: ev.clientX, ...view.value, moved: false };
  };
  const scrolled = () => requestAnimationFrame(() => draw.current && draw.current());
  const click = (ev) => {
    const dr = drag.current; drag.current = null;
    if (dr && dr.moved) return;
    const r = at(ev); if (!r) return;
    const dn = r.dn, n = dn.n;
    if (dn.folded) { opened.value = new Set([...opened.value, n.id]); return; }
    select(n);
  };
  const dbl = (ev) => { const r = at(ev); if (r && !r.dn.folded) focusOn(r.dn.n.id); else if (!r) zoomOutAt(ev, cv.current, view); };
  const miniDown = (ev) => {
    const go = (e) => {
      if (!mini.current) return up();      // the minimap went away mid-drag (zoomed back out)
      const b = mini.current.getBoundingClientRect(), f = clamp((e.clientX - b.left) / b.width, 0, 1);
      const { v0, v1 } = view.value, s = v1 - v0;
      setV(view, f - s / 2, f + s / 2);
    };
    const mv = (e) => go(e);
    function up() { window.removeEventListener('mousemove', mv); window.removeEventListener('mouseup', up); }
    window.addEventListener('mousemove', mv); window.addEventListener('mouseup', up);
    go(ev);
  };
  return html`<div class="pfgraph">
    ${vw.v1 - vw.v0 < 0.999 ? html`<canvas class="pfmini" ref=${mini} onMouseDown=${miniDown} title="the whole run; drag to move"></canvas>` : null}
    <div class="pfflame" ref=${box} onMouseMove=${move} onMouseDown=${down} onScroll=${scrolled}
      onMouseLeave=${() => { hover.value = null; drag.current = null; if (tip.current) tip.current.style.display = 'none'; }}>
      <div class="pfscroll" style=${'height:' + (_lay ? _lay.height : 0) + 'px'}>
        <canvas ref=${cv} onClick=${click} onDblClick=${dbl}></canvas>
      </div>
      <div class="pfrange" ref=${band}></div>
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
  let tmax = 0;
  for (const t of T.t) if (t > tmax) tmax = t;          // not Math.max(...): too many arguments for a long run
  const step = T.step_ms || M.delay, end = tmax + step;
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
  for (const ix of byThread.values()) ix.sort((a, b) => T.t[a] - T.t[b]);
  // The real sampling interval, which is longer than the one asked for (the sampler's own cost, and
  // on Linux it ticks with CPU time): the typical gap between samples of the busiest thread. A sample
  // is drawn that wide, so a stretch in one frame is one bar.
  const busiest = [...byThread.values()].reduce((a, b) => (b.length > a.length ? b : a));
  const gaps = [];
  for (let k = 1; k < busiest.length; k++) { const g = T.t[busiest[k]] - T.t[busiest[k - 1]]; if (g > 0) gaps.push(g); }
  gaps.sort((a, b) => a - b);
  const lstep = gaps.length ? Math.max(step, gaps[Math.floor(gaps.length * 0.75)]) : step;
  const lanes = [];
  let y = TL_AXIS;
  for (const th of [...byThread.keys()].sort((a, b) => a - b)) {
    const ix = byThread.get(th);
    const rects = [];
    let depth = 0;
    const open = [];                     // per depth: the bar being extended
    for (const i of ix) {
      const c = chain(T.node[i]), t0 = T.t[i], t1 = t0 + lstep;
      depth = Math.max(depth, Math.min(TL_DEPTH, c.length));
      for (let d = 0; d < Math.min(TL_DEPTH, c.length); d++) {
        const o = open[d];
        // A short gap is time this thread went unsampled (it waited on a collection, say), not time
        // in something else: the cell's line it was on runs on across one, and a frame below it
        // across a shorter one.
        if (o && o.n === c[d] && t0 - o.t1 <= lstep * (d === 0 ? 40 : 4)) o.t1 = t1;
        else { const r = { n: c[d], d, t0, t1 }; rects.push(r); open[d] = r; }
      }
      for (let d = Math.min(TL_DEPTH, c.length); d < open.length; d++) open[d] = null;
    }
    lanes.push({ thread: th, y, depth, rects, n: ix.length });
    y += depth * TL_ROW + TL_LANEGAP + 12;
  }
  // A thread with a handful of samples gets a few rows, so the busy ones stay in view.
  const most = Math.max(...lanes.map(L => L.n));
  y = TL_AXIS;
  for (const L of lanes) {
    L.y = y;
    if (L.n < most * 0.02) { L.depth = Math.min(L.depth, 4); L.rects = L.rects.filter(r => r.d < 4); }
    L.rows = Array.from({ length: L.depth }, () => []);
    for (const r of L.rects) L.rows[r.d].push(r);         // each row in time order
    y += L.depth * TL_ROW + TL_LANEGAP + 12;
  }
  return { lanes, end, height: y };
});

function Timeline() {
  const M = model.value, TL = timeline.value;
  void [sel.value, hover.value, matches.value, fnSel.value, baseShare.value, tview.value, srcs.value, colorBy.value, fold.value];
  const box = useRef(null), cv = useRef(null), tip = useRef(null), drawn = useRef([]), drag = useRef(null), draw = useRef(null);
  draw.current = () => {
    const el = box.current, c = cv.current; if (!el || !c || !TL) return;
    const vw = tview.value, viewH = Math.min(TL.height, Math.max(40, el.clientHeight - 12));
    const W = Math.max(200, el.clientWidth - 18), g0 = sizeCanvas(c, W, viewH), yOff = scrolledBy(c);
    g0.save(); g0.translate(0, -yOff);
    const g = g0;
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
      if (L.y > yOff + viewH || L.y + 12 + L.depth * TL_ROW < yOff) continue;    // off screen
      g.fillStyle = 'rgba(200,205,225,.7)'; g.font = '10px ui-monospace, SFMono-Regular, Menlo, monospace';
      g.fillText('thread ' + L.thread + '  ·  ' + L.n.toLocaleString() + ' samples', 2, L.y);
      L.rows.forEach((row, d) => {
        const y = L.y + 12 + d * TL_ROW;
        // Bars too narrow to see are gathered with their neighbours into one, drawn in the colour of
        // what took most of it: zoomed out, a row that switches between functions every few samples
        // reads as a band, and zooming in takes it apart.
        let run = null;
        const flush = () => {
          if (!run) return;
          let n = null, best = -1;
          for (const [k, v] of run.cover) if (v > best) { best = v; n = k; }
          const cw = run.x1 - run.x0, mixed = run.cover.size > 1;
          const hit = (k) => k.id === sel.value || (hv && hv.n && hv.n.id === k.id) || (fsel && k.fk === fsel) || (mt && mt.ids.has(k.id));
          g.globalAlpha = (mt && ![...run.cover.keys()].some(k => mt.ids.has(k.id)) ? 0.3 : 1) * (mixed ? 0.82 : 1);
          g.fillStyle = diffColor(n, M) || barColor(n, M);
          if (cw > 4 && g.roundRect) { g.beginPath(); g.roundRect(run.x0, y, cw - 0.5, TL_ROW - 1, 2); g.fill(); }
          else g.fillRect(run.x0, y, Math.max(0.5, cw - 0.5), TL_ROW - 1);
          g.globalAlpha = 1;
          if (hit(n) || (mixed && [...run.cover.keys()].some(hit))) {
            g.strokeStyle = n.id === sel.value ? '#fff' : '#ff6fd8'; g.lineWidth = 1.5;
            g.strokeRect(run.x0 + 0.5, y + 0.5, Math.max(1, cw - 1), TL_ROW - 2);
          }
          if (cw > 40 && !mixed) {
            g.fillStyle = '#f4f5fb'; g.textBaseline = 'middle';
            g.fillText(fit(g, n.kind === K.line ? (n.func === 'top-level scope' ? n.line + '  ' + cellLine(n.file, n.line) : n.func + ':' + n.line) : n.func, cw - 6), run.x0 + 3, y + TL_ROW / 2);
            g.textBaseline = 'top';
          }
          out.push({ x: run.x0, w: cw, y: y - yOff, h: TL_ROW, n, t0: run.t0, t1: run.t1, mixed: mixed ? run.cover.size : 0 });
          run = null;
        };
        for (const r of row) {
          const x = (r.t0 - t0) * kx, w = (r.t1 - r.t0) * kx;
          if (x + w < 0 || x > W) continue;
          const cx = Math.max(0, x), ce = Math.min(W, x + w);
          if (run && cx <= run.x1 + 1 && (ce - cx < 2 || run.x1 - run.x0 < 2 || (run.cover.has(r.n) && run.cover.size === 1))) {
            run.x1 = Math.max(run.x1, ce); run.t1 = Math.max(run.t1, r.t1);
            run.cover.set(r.n, (run.cover.get(r.n) || 0) + (ce - cx));
          } else {
            flush();
            run = { x0: cx, x1: ce, t0: r.t0, t1: r.t1, cover: new Map([[r.n, ce - cx]]) };
          }
        }
        flush();
      });
    }
    g0.restore();
    drawn.current = out;
  };
  useEffect(() => { draw.current && draw.current(); });
  useRedrawOnResize(box, draw, !!TL);
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
    t.innerHTML = tipHtml({ n: r.n, total: r.n.total, self: r.n.self, d: r.n.d, g: r.n.g, c: r.n.c, folded: false }, false, M) +
      (r.mixed ? '<div class="pftw">and ' + (r.mixed - 1) + ' more here; double-click to open</div>' : '');
    placeTip(t, ev);
  };
  const band = useRef(null);
  const down = (ev) => {
    if (ev.button !== 0) return;
    if (ev.shiftKey && cv.current) { ev.preventDefault(); drag.current = { range: true, moved: true }; rangeDrag(ev, cv.current, tview, band.current, box.current); return; }
    drag.current = { x: ev.clientX, ...tview.value, moved: false };
  };
  const click = (ev) => { const dr = drag.current; drag.current = null; if (dr && dr.moved) return; const r = at(ev); if (r) select(r.n); };
  // Double-click a bar: zoom to that stretch of time. On nothing: back out.
  const dbl = (ev) => {
    const r = at(ev);
    if (!r) return zoomOutAt(ev, cv.current, tview);
    const pad = (r.t1 - r.t0) * 0.08;
    animateTo(tview, clamp((r.t0 - pad) / TL.end, 0, 1), clamp((r.t1 + pad) / TL.end, 0, 1));
  };
  const scrolled = () => requestAnimationFrame(() => draw.current && draw.current());
  return html`<div class="pfflame" ref=${box} onMouseMove=${move} onMouseDown=${down} onScroll=${scrolled}
      onMouseLeave=${() => { hover.value = null; drag.current = null; if (tip.current) tip.current.style.display = 'none'; }}>
    <div class="pfscroll" style=${'height:' + TL.height + 'px'}><canvas ref=${cv} onClick=${click} onDblClick=${dbl}></canvas></div>
    <div class="pfrange" ref=${band}></div>
    <div class="pftip" ref=${tip}></div>
  </div>`;
}

// ── the functions view ────────────────────────────────────────────────────────────────────────────
function fnName(f) {
  if (f.kind !== K.line) return f.func;
  if (f.func === 'top-level scope') return 'cell ' + f.file.slice(5);
  return f.closure ? 'closure · line ' + f.line : f.func;
}
function Functions() {
  const M = model.value, fs = functions.value;
  if (!M || !fs) return html`<div class="pfflame pfempty">not profiled yet</div>`;
  const q = query.value.trim().toLowerCase();
  // Folded: the reader's own functions only, each with the time of the library code it calls.
  const own = fold.value && ownTime.value;
  const base = own ? fs.filter(f => f.kind === K.line && !isLib(f, M)).map(f => ({ ...f, self: own.fns.get(f.fk) || 0 })) : fs;
  const rows = sortRows(q ? base.filter(f => f.func.toLowerCase().includes(q) || f.file.toLowerCase().includes(q)) : base, fnSort,
                        { self: f => f.self, total: f => f.total, name: f => fnName(f).toLowerCase(), file: f => shortFile(f.file).toLowerCase() }).slice(0, 300);
  // Nothing picked: the heaviest by its own time, so the callers and callees always show something.
  const pickedFk = fnSel.value || (rows[0] && rows[0].fk) || '';
  const R = pickedFk ? relatives(pickedFk) : null;
  const pick = (f) => { fnSel.value = f.fk; if (f.kind === K.line) showCode(f.file, f.line); };
  const bar = (v) => html`<span class="pfbar"><i style=${'width:' + Math.max(1, Math.round(100 * v / M.total)) + '%'}></i></span>`;
  const rel = (title, list) => html`<div class="pfrel"><div class="pfrelhead">${title}</div>
    ${list.length ? list.slice(0, 40).map(e => html`<div class="pfrelrow" onClick=${() => e.fk[0] !== '\x1f' && pick(e)}>
      <span class="pfnum">${fmt(e.v, M)}</span>${bar(e.v)}<span class="pffn">${fnName(e)}</span>
      <span class="pfdim">${e.kind === K.line ? shortFile(e.file) : ''}</span></div>`)
      : html`<div class="pfdim pfrelrow">none</div>`}</div>`;
  return html`<div class="pffuncs" style=${'grid-template-rows:minmax(0,1fr) 0 minmax(0,' + pctOf('sandwich') + ')'}>
    <div class="pftable">
      <div class="pfthead">
        <${SortHead} sig=${fnSort} k="self" label="self" title=${own ? 'time in the function and in the library code it calls (fold libraries is on)' : 'time spent in the function itself'} /><span></span>
        <${SortHead} sig=${fnSort} k="total" label="total" title="time in the function and everything it called" />
        <${SortHead} sig=${fnSort} k="name" label=${own ? 'your functions' : 'function'} num=${false} />
        <${SortHead} sig=${fnSort} k="file" label="file" num=${false} /><span></span></div>
      ${rows.map(f => html`<div class=${'pftrow' + (pickedFk === f.fk ? ' on' : '')} onClick=${() => pick(f)}>
        <span class="pfnum">${fmt(f.self, M)}</span>${bar(f.self)}<span class="pfnum dim">${fmt(f.total, M)}</span>
        <span class="pffn">${fnName(f)}</span><span class="pfdim pffile">${f.kind === K.line ? shortFile(f.file) : ''}</span>
        <span class="pfmk">${f.d ? '⤳' : ''}${f.c ? '⚙' : ''}${f.g ? '♻' : ''}</span></div>`)}
    </div>
    <${Split} name="sandwich" dir="y" edge="after" min=${0.12} max=${0.8} />
    ${R ? html`<div class="pfsandwich">
      ${rel('called from', R.callers)}
      <div class="pfrelmid"><b>${fnName(R.f)}</b> <span class="pfdim">${fmt(R.f.total, M)} total · ${fmt(R.f.self, M)} self</span></div>
      ${rel('calls', R.callees)}
    </div>` : html`<div class="pfsandwich"></div>`}
  </div>`;
}

// ── the static check (Compile, with JET in the notebook's environment) ─────────────────────────────
function StaticCheck() {
  const P = pf.value, st = P && P.prepared && P.prepared.static;
  if (!st) return null;
  const head = html`<div class="pfrelhead">Static check${st.available && !st.error ? ' · JET · ' + st.n + ' reports on ' + staticCount(st) + ' lines' : ''}</div>`;
  if (!st.available) return html`<div class="pfdet">${head}<div class="pfdim">${st.why}</div></div>`;
  if (st.error) return html`<div class="pfdet">${head}<div class="pfwarn">${st.error}</div></div>`;
  if (!st.findings.length) return html`<div class="pfdet">${head}<div class="pfdim">nothing found</div></div>`;
  const where = (g) => g.file.startsWith('cell:') ? html`<b>${g.file.slice(5)}</b>:${g.line}` : shortFile(g.file) + ':' + g.line;
  const kinds = [...new Set(st.findings.flatMap(g => Object.keys(g.kinds)))].filter(k => STATIC_WHAT[k]);
  return html`<div class="pfdet">${head}
    <div class="pfjwhat">${kinds.map(k => html`<div><span class=${'pfjk ' + k}>${k === 'captured' ? 'boxed' : k}</span> ${STATIC_WHAT[k].replace(/^[^:]+: /, '')}</div>`)}</div>
    ${st.findings.map(g => html`<div class="pfjet" onClick=${() => showCode(g.file, g.line)}
        title=${[...g.sigs, ...g.libsigs.map(x => 'inside a library call: ' + x)].join('\n')}>
      <span class="pfjks">${Object.entries(g.kinds).map(([k, n]) => html`<span class=${'pfjk ' + k.replace(/\s+/g, '-')}>${k === 'captured' ? 'boxed' : k}${n > 1 ? ' ×' + n : ''}</span>`)}</span>
      <span class="pfloc">${where(g)}<span class="pfsnip">${cellLine(g.file, g.line)}</span></span>
      <span class="pfsig">${g.sig}${g.sigs.length > 1 ? html`<span class="pfdim">  +${g.sigs.length - 1}</span>` : null}${
        g.lib ? html`<span class="pfdim">  · ${g.lib} inside ${g.calls.slice(0, 3).join(', ')}${g.calls.length > 3 ? '…' : ''}</span>` : null}</span>
      <span class="pfjwhy">${explainStatic(g).map(e => html`<div>${withCode(e.why)}${e.fix ? html` <b>Fix:</b> ${withCode(e.fix)}` : null}</div>`)}</span>
    </div>`)}</div>`;
}

// A notebook line as the GPU table names it: the line alone in the profiled cell, `cell:line` in another.
const lineLabel = (file, line, P) =>
  (file === 'cell:' + P.cell ? line : file.slice(5) + ':' + line) + '  ' + (cellLine(file, line) || '').trim();

// ── details: compiling, dispatch, allocation types, the GPU ─────────────────────────────────────────
function Details() {
  const P = pf.value && pf.value.profile;
  // Compiled but not yet profiled: the static check is all there is to show.
  if (!P) return pf.value && pf.value.prepared && pf.value.prepared.static
    ? html`<div class="pfdetails"><${StaticCheck} /></div>`
    : html`<div class="pfflame pfempty"><button class="pfbtn primary pfbig" onClick=${run}>▶ Run and profile</button></div>`;
  // Every column but the last is a figure; the last (a type, a signature, a kernel) takes the rest.
  const tbl = (title, head, rows, empty) => {
    const cols = 'grid-template-columns:repeat(' + (head.length - 1) + ', 80px) minmax(0,1fr)';
    return html`<div class="pfdet"><div class="pfrelhead">${title}</div>
    ${rows && rows.length ? html`<div class="pfdetrow pfdethead" style=${cols}>${head.map(h => html`<span>${h}</span>`)}</div>
      ${rows.map(r => html`<div class="pfdetrow" style=${cols}>${r.map((c, i) => html`<span class=${i === r.length - 1 ? 'pfsig' : 'pfnum'} title=${i === r.length - 1 ? c : null}>${c}</span>`)}</div>`)}`
      : html`<div class="pfdim">${empty}</div>`}</div>`;
  };
  const g = P.gpu, dr = P.dropped ? Object.entries(P.dropped).filter(([, v]) => v > 0) : [];
  const facts = [['mode', P.mode || 'cpu'], ['ran', ms(P.duration_ms)],
    P.unit === 'bytes' ? ['recorded', (P.allocs || 0).toLocaleString() + ' allocations, ' + pct(P.alloc_rate) + ' of them']
                       : ['sampled', Number(P.samples).toLocaleString() + ' samples, every ' + ms(P.delay_ms) + (P.threads > 1 ? ', on ' + P.threads + ' threads' : '')],
    ['compiling', ms(P.compile_ms) || '0 ms'], ['GC', ms(P.gc_ms) || '0 ms'],
    ...(dr.length ? [['left out', dr.map(([k, v]) => v.toLocaleString() + ' ' + k).join(', ')]] : []),
    ...(P.buffer_full ? [['buffer', 'full: the end of the run is missing']] : []),
    ...(P.stalls ? [['stalled', ms(P.stalled_ms) + ' unsampled, in ' + P.stalls + ' pauses']] : []),
    ...(P.error ? [['threw', String(P.error).split('\n')[0]]] : [])];
  // Per notebook line: what the GPU ran for it, and what it spent waiting on the GPU, allocating its
  // memory and copying. Each CUDA call is placed by its own stack.
  const nl = (n, t) => n ? n.toLocaleString() + ' · ' + ms(t) : '';
  const byLine = g && g.lines ? g.lines.map(e => [ms(e.kernel_ms + e.copy_ms), e.launches || '', nl(e.sync[0], e.sync[1]),
      nl(e.alloc[0], e.alloc[1]), e.copy_bytes ? bytes(e.copy_bytes) : '',
      e.line > 0 && e.file ? lineLabel(e.file, e.line, P) : 'no notebook line on the stack']) : null;
  return html`<div class="pfdetails">
    <${StaticCheck} />
    <div class="pfdet"><div class="pfrelhead">The run</div>
      ${facts.map(([k, v]) => html`<div class="pfdetkv"><span>${k}</span><span>${v}</span></div>`)}</div>
    ${P.types ? tbl('Allocated, by type (scaled from the ' + pct(P.alloc_rate) + ' recorded)', ['bytes', 'count', 'type'],
                    P.types.map(([t, c, b]) => [bytes(b), c.toLocaleString(), t]), 'nothing recorded') : null}
    ${byLine ? tbl('On the GPU, by line', ['GPU time', 'launches', 'waits', 'allocations', 'copied', 'line'], byLine, 'no GPU work recorded') : null}
    ${g ? tbl('On the GPU' + (g.device_ms ? ' · ' + ms(g.device_ms) + ' of device time' : ''), ['time', 'calls', 'kernel or copy'],
              (g.kernels || []).map(([n, c, t]) => [ms(t), c, n]), g.error || 'no device work recorded') : null}
    ${P.compiled ? tbl('Compiled during the run · ' + P.compiled_n, ['time', 'times', 'method'],
                       P.compiled.map(([s, t, n]) => [ms(t), n || 1, s]), 'nothing compiled') : null}
    ${P.dispatched ? tbl('Dispatched at runtime · ' + P.dispatched_n + ' signatures', ['calls', 'signature'],
                         P.dispatched.map(([s, n]) => [n, s]), 'no runtime dispatch') : null}
    ${!P.types && !g && !P.compiled ? html`<div class="pfempty">no details recorded for this run</div>` : null}
  </div>`;
}

// What the colours mean, and the switch between the two ways of colouring. Width is always time.
function ColorKey() {
  const M = model.value; if (!M) return null;
  const sw = (c, label, title) => html`<span title=${title}><i class="pfsw" style=${'background:' + c}></i>${label}</span>`;
  const pick = (k) => { colorBy.value = k; lsSet('slateProfColor', k); };
  return html`<span class="pfkey pfcolorkey">
    <span class="pfseg pfseg-sm">${[['time', 'time'], ['code', 'code']].map(([k, l]) =>
      html`<button class=${colorBy.value === k ? 'on' : ''} onClick=${() => pick(k)}
        title=${k === 'code' ? 'colour each bar by whose code it is' : 'colour each bar by the time spent in it, not in what it calls'}>${l}</button>`)}</span>
    ${colorBy.value === 'time'
      ? html`<span title="self time: spent in the bar itself, not in what it calls"><i class="pfsw pfgrad"></i>less → more self time</span>`
      : html`${sw('hsl(188, 57%, 42%)', 'notebook', "this notebook's code")}${M.mine.size ? sw('hsl(147, 44%, 40%)', 'your packages', 'packages loaded from a path, being worked on') : null}${
             sw('hsl(230, 18%, 42%)', 'Base', "Julia's Base and Core")}${sw('hsl(268, 27%, 44%)', 'packages', 'installed packages, a hue each')}${
             sw(KIND_COLOR[K.gc], 'GC', 'garbage collection')}${sw(KIND_COLOR[K.compile], 'compiling', 'compiling during the run')}`}
  </span>`;
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
    ${tab.value === 'flame' || tab.value === 'timeline' ? html`<${ColorKey} />` : null}
    <span class="pfkey"><span><i style="color:#ffd27a">⤳</i>dispatch</span><span><i style="color:#c9b4ff">⚙</i>compiling</span><span><i style="color:#ff8a8a">♻</i>GC</span>
      ${staticFound() ? html`<span title="lines JET flagged when the cell was compiled: hover one for what it found"><i style="color:#ffd27a">◆</i>JET</span>` : null}
      ${baseShare.value ? html`<span><i style="color:#e05a5a">■</i>grew</span><span><i style="color:#5a8fe0">■</i>shrank</span>` : null}</span>
    ${tab.value === 'flame' || tab.value === 'timeline' ? html`<span class="pfzoom">
      <button onClick=${() => zoomAt(sig, mid, 2)} disabled=${x <= 1.0001} title="zoom out (-)">−</button>
      <span class="pfzx" title="scroll to zoom (⌘ + scroll on a graph taller than its pane) · drag to pan · shift + drag to zoom to a span · double-click a bar to zoom to it, empty space to zoom out">${x < 10 ? x.toFixed(1) : Math.round(x)}×</span>
      <button onClick=${() => zoomAt(sig, mid, 0.5)} title="zoom in (+)">+</button>
      <button onClick=${() => { zoom.value = 1; animateTo(sig, 0, 1); }} disabled=${x <= 1.0001} title="show the whole run (0)">Fit</button>
    </span>` : null}
  </div>`;
}

// ── the code pane ─────────────────────────────────────────────────────────────────────────────────
// A line JET flagged explains itself on hover, in a card beside the pointer.
const jetTip = signal(null);      // {g, x, y}: the finding under the pointer, where to draw it
function staticAt(file, line) {
  const st = pf.value && pf.value.prepared && pf.value.prepared.static;
  return st && st.findings ? st.findings.find(g => g.file === file && g.line === line) || null : null;
}
// `name` in an explanation is code.
const withCode = (t) => String(t).split('`').map((part, i) => i % 2 ? html`<code>${part}</code>` : part);
function JetCard() {
  const t = jetTip.value; if (!t) return null;
  const g = t.g, ex = explainStatic(g);
  return html`<div class="pfjcard" style=${'left:' + t.x + 'px;top:' + t.y + 'px'}>
    <div class="pfjchead"><span class="pfjks">${Object.entries(g.kinds).map(([k, n]) =>
      html`<span class=${'pfjk ' + k}>${k === 'captured' ? 'boxed' : k}${n > 1 ? ' ×' + n : ''}</span>`)}</span>
      <span class="pfdim">JET · line ${g.line}</span></div>
    ${Object.keys(g.kinds).filter(k => STATIC_WHAT[k]).map(k => html`<p class="pfjcwhat">${STATIC_WHAT[k].replace(/^[^:]+: /, '')}</p>`)}
    ${ex.map(e => html`<p>${withCode(e.why)}</p>${e.fix ? html`<p><b>Fix</b> ${withCode(e.fix)}</p>` : null}`)}
    ${g.sigs.length ? html`<div class="pfjcsigs">${g.sigs.slice(0, 4).map(x => html`<code>${x}</code>`)}${
      g.sigs.length > 4 ? html`<span class="pfdim">+${g.sigs.length - 4} more</span>` : null}</div>` : null}
  </div>`;
}

function Code() {
  const M = model.value, at = codeAt.value;
  const host = useRef(null), vw = useRef(null), box = useRef(null), ptr = useRef({ x: 0, y: 0 });
  useEffect(() => {
    if (!host.current || !window.slateSourceViewer) return;
    vw.current = window.slateSourceViewer(host.current, {
      heat: true,
      onLineHover: (ln) => {
        hotLine.value = ln ? { file: codeAt.value.file, line: ln } : null;
        const g = ln ? staticAt(codeAt.value.file, ln) : null;
        jetTip.value = g ? { g, ...ptr.current } : null;
      },
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
    const rows = new Map(M && M.lines.get(at.file) ? [...M.lines.get(at.file).values()].map(r => [r.line, { ...r }]) : []);
    // With library code folded, the gutter shows the same time per line as the hot lines table.
    const own = M && fold.value && ownTime.value;
    if (own && [...own.lines.values()].some(o => o.file === at.file))
      for (const r of rows.values()) { const o = own.lines.get(at.file + '\x1f' + r.line); r.self = o ? o.self : 0; }
    for (const s of staticRows(at.file)) rows.set(s.line, { incl: 0, self: 0, d: 0, g: 0, c: 0, ...(rows.get(s.line) || {}), ...s });
    v.setHeat([...rows.values()]);
  }, [text, at.file, M, pf.value && pf.value.prepared, fold.value]);
  useEffect(() => { const v = vw.current; if (v && at.line) v.setLine(at.line); }, [text, at.file, at.line]);
  useEffect(() => {
    const v = vw.current; if (!v) return;
    const h = hover.value;
    v.setHot(h && h.n && h.n.kind === K.line && !h.folded && h.n.file === at.file ? [h.n.line] : []);
  }, [hover.value, at.file]);
  const P = pf.value, isCell = P && at.file === 'cell:' + P.cell;
  // Where the card goes: beside the pointer, inside the pane, flipped up near the bottom.
  const track = (ev) => {
    const b = box.current && box.current.getBoundingClientRect(); if (!b) return;
    const x = Math.min(ev.clientX - b.left + 16, b.width - 440), y = ev.clientY - b.top + 18;
    ptr.current = { x: Math.max(8, x), y: y > b.height - 220 ? Math.max(8, y - 240) : y };
    if (jetTip.value) jetTip.value = { ...jetTip.value, ...ptr.current };   // the card follows the pointer
  };
  return html`<div class="pfcode" ref=${box} onMouseMove=${track} onMouseLeave=${() => { jetTip.value = null; }}>
    <div class="pfcodehead">
      <span class="pffile" title=${(s && s.path) || at.file}>${at.file.startsWith('cell:') ? 'cell ' + at.file.slice(5) : shortFile(at.file)}</span>
      ${!isCell && P ? html`<button class="pfback" onClick=${() => showCode('cell:' + P.cell, 0)}>back to the cell</button>` : null}
      ${s && s.loading ? html`<span class="hydspin"></span>` : s && s.error ? html`<span class="pfwarn">${s.error}</span>` : null}
    </div>
    <div class="pfcodebody" ref=${host}></div>
    <${JetCard} />
  </div>`;
}

// ── sortable tables ───────────────────────────────────────────────────────────────────────────────
// A table's sort: the column and its direction, kept across sessions. A header click sorts by its
// column, and a second click reverses it. Figures sort largest first, names A to Z.
function sortSignal(name, key) {
  const saved = ls('slateProfSort.' + name, '');
  const [k, d] = saved ? saved.split(':') : [key, 'desc'];
  const sig = signal({ key: k, desc: d !== 'asc' });
  sig.save = () => lsSet('slateProfSort.' + name, sig.value.key + ':' + (sig.value.desc ? 'desc' : 'asc'));
  return sig;
}
function SortHead({ sig, k, label, num = true, title = null }) {
  const on = sig.value.key === k;
  const click = () => { sig.value = on ? { key: k, desc: !sig.value.desc } : { key: k, desc: num }; sig.save(); };
  return html`<span class=${'pfsort' + (num ? ' pfnum' : '') + (on ? ' on' : '')} onClick=${click} title=${title}>${label}${on ? (sig.value.desc ? ' ↓' : ' ↑') : ''}</span>`;
}
function sortRows(rows, sig, val) {
  const { key, desc } = sig.value, v = val[key];
  if (!v) return rows;
  return rows.slice().sort((a, b) => {
    const x = v(a), y = v(b);
    const c = typeof x === 'string' ? x.localeCompare(y) : x - y;
    return desc ? -c : c;
  });
}
const hotSort = sortSignal('hot', 'self');
const fnSort = sortSignal('functions', 'self');

// ── the hot lines ─────────────────────────────────────────────────────────────────────────────────
function Hot() {
  const M = model.value; if (!M) return null;
  const B = baseModel.value;
  const rows = [], own = fold.value && ownTime.value;
  if (own) rows.push(...own.lines.values());
  else for (const [file, m] of M.lines) for (const r of m.values()) rows.push({ file, ...r });
  const wasOf = (r) => { const m = B && B.lines.get(r.file); const w = m && m.get(r.line); return w ? w.self : 0; };
  const where = (r) => (r.file.startsWith('cell:') ? r.file.slice(5) : shortFile(r.file)) + ':' + String(r.line).padStart(6, '0');
  rows.sort((a, b) => b.self - a.self || b.incl - a.incl);
  const top = sortRows(hotSort.value.key === 'self' ? rows.filter(r => r.self > 0) : rows, hotSort,
                       { self: r => r.self, incl: r => r.incl, before: wasOf, line: where }).slice(0, 60);
  const go = (r) => { select(heaviestAt(r.file, r.line)); showCode(r.file, r.line); };
  // Another cell's lines are named by their text too, which the hub has.
  for (const r of top) if (r.file.startsWith('cell:') && !srcText(r.file)) loadSource(r.file);
  const lead = Math.max(1e-9, ...top.slice(0, 200).map(r => r.self));
  return html`<div class="pfhot" style=${'flex-basis:' + pctOf('hot')}>
    <div class=${'pfhothead' + (B ? ' cmp' : '')}>
      <${SortHead} sig=${hotSort} k="self" label="self" title=${own ? 'time on the line and in the library code it calls (fold libraries is on)' : 'time spent on the line itself'} /><span></span>
      <${SortHead} sig=${hotSort} k="incl" label="total" title="time on the line and in everything it called" />
      ${B ? html`<${SortHead} sig=${hotSort} k="before" label="before" title="the line's own time in the profile compared with" />` : null}
      <${SortHead} sig=${hotSort} k="line" label=${own ? 'your lines' : 'line'} num=${false} /></div>
    ${top.map(r => html`<div class=${'pfhotrow' + (B ? ' cmp' : '')} onClick=${() => go(r)}
        onMouseEnter=${() => { hotLine.value = { file: r.file, line: r.line }; }}
        onMouseLeave=${() => { hotLine.value = null; }}>
      <span class="pfnum">${fmt(r.self * M.total, M)}</span>
      <span class="pfbar"><i style=${'width:' + Math.max(2, Math.round(100 * r.self / lead)) + '%'}></i></span>
      <span class="pfnum dim">${fmt(r.incl * M.total, M)}</span>
      ${B ? html`<span class="pfnum dim">${pct(wasOf(r)) || '–'}</span>` : null}
      <span class="pfloc" title=${r.file + ':' + r.line}>
        <span class="pfmk">${r.d ? '⤳' : ''}${r.c ? '⚙' : ''}${r.g ? '♻' : ''}</span>
        ${r.file.startsWith('cell:') ? html`<b>${r.file.slice(5)}</b>:${r.line}` : shortFile(r.file) + ':' + r.line}
        <span class="pfsnip">${cellLine(r.file, r.line)}</span></span>
    </div>`)}
  </div>`;
}

function Facts() {
  const P = pf.value, pr = P && P.profile, pp = P && P.prepared, B = base.value && base.value.profile;
  const dr = pr && pr.dropped ? Object.entries(pr.dropped).filter(([k, v]) => v > 0 && k !== 'idle') : [];
  const left = dr.reduce((t, [, v]) => t + v, 0);
  if (!pp && !pr) return null;
  const fig = (v, label, cls = '', title = null) => html`<span class=${'pffig ' + cls} title=${title}><b>${v}</b><i>${label}</i></span>`;
  const share = (x) => pr && pr.duration_ms > 0 ? ' · ' + pct(x / pr.duration_ms) : '';
  return html`<div class="pffacts">
    ${pr ? html`
      <span class="pfmode">${pr.mode || 'cpu'}</span>
      ${fig(ms(pr.duration_ms), B ? 'run · was ' + ms(B.duration_ms) : 'run')}
      ${pr.unit === 'bytes' ? fig('≈ ' + bytes(pr.samples / (pr.alloc_rate || 1)), 'allocated', '', (pr.allocs || 0).toLocaleString() + ' recorded, ' + pct(pr.alloc_rate) + ' of them')
        : html`${fig(Number(pr.samples).toLocaleString(), 'samples')}${pr.threads > 1 ? fig(pr.threads, 'threads') : null}`}
      ${pr.compile_ms > 0.5 ? fig(ms(pr.compile_ms), 'compiling' + share(pr.compile_ms), 'c') : null}
      ${pr.gc_ms > 0.5 ? fig(ms(pr.gc_ms), 'GC' + share(pr.gc_ms), 'g') : null}
      ${left ? fig(left.toLocaleString(), 'left out', 'dim', dr.map(([k, v]) => v + ' ' + k).join(', ')) : null}
      ${pr.stalls ? html`<span class="pfwarn" title=${'The sampler took nothing for ' + ms(pr.stalled_ms) + ' of the run. A thread in this process did not answer the sampler. On Linux this happens when Julia adopts a thread that a C library started with signals blocked.'}>sampling stalled · ${pct(pr.stalled_ms / pr.duration_ms)} of the run</span>` : null}
      ${pr.buffer_full ? html`<span class="pfwarn" title="the end of the run is missing: profile again with a larger buffer or a longer interval">buffer full</span>` : null}
      ${pr.error ? html`<span class="pfwarn" title=${pr.error}>threw ${String(pr.error).split('\n')[0]}</span>` : null}` : null}
    <span class="pfsp"></span>
    ${pp && pp.static ? html`<button class="pffigbtn" onClick=${() => setTabTo('details')} title=${pp.static.why || pp.static.error || 'found by JET without running the cell'}>${
        !pp.static.available ? fig('—', 'no static check (JET)', 'dim')
        : pp.static.error ? fig('!', 'static check failed', 'g')
        : fig(staticCount(pp.static), (staticCount(pp.static) === 1 ? 'line' : 'lines') + ' flagged by JET', staticCount(pp.static) ? 'j' : 'dim')}</button>` : null}
    ${pp ? (pp.ok ? fig(ms(pp.compile_ms), 'to compile ahead', 'dim')
                  : html`<span class="pfwarn" title=${pp.error}>${String(pp.error).split('\n')[0]}</span>`) : null}
  </div>`;
}

// JET in the notebook's environment turns on the static check. It is the notebook's to add, so the
// dock says whether it is there and offers to add it, through the same install as the package panel.
function JetStatus() {
  const P = pf.value; if (!P || P.jet == null) return null;
  if (P.jet) return html`<span class="pfjetpill" title="JET is in this notebook's environment: Compile also checks the cell statically">JET</span>`;
  if (!P.pkgManageable) return null;
  const add = async () => {
    const ok = window.confirmDark ? await window.confirmDark('Add JET to this notebook’s environment? Compile then also checks a cell statically, without running it. It installs (it may precompile for a minute) and the notebook re-runs.', 'Add JET')
                                  : window.confirm('Add JET to this notebook’s environment?');
    if (!ok) return;
    const stop = window.startPkgInstall ? window.startPkgInstall('Installing <b>JET</b> → notebook') : () => {};
    const r = await A('POST', '/api/package', { op: 'add', name: 'JET' });
    stop();
    if (r && r.ok === false) { window._pkgInstallFail ? window._pkgInstallFail(r.message) : alert('Add failed: ' + (r.message || '?')); return; }
    window.hidePkgInstalling && window.hidePkgInstalling();
    if (pf.value) { pf.value = { ...pf.value, jet: true }; prepare(); }
  };
  return html`<button class="pfbtn pfjetadd" onClick=${add} title="add JET to this notebook's environment, so Compile also checks the cell statically">＋ JET</button>`;
}
const staticCount = (st) => (st.findings || []).length;     // lines of the notebook's code flagged
const staticFound = () => { const st = pf.value && pf.value.prepared && pf.value.prepared.static; return !!(st && st.findings && st.findings.length); };
const setTabTo = (t) => { tab.value = t; lsSet('slateProfTab', t); };
// The static check's findings on `file`'s lines, for the code pane's margin.
// What a static finding means, its likely cause, and the usual fix, read from the types JET
// reports on the line. `what` is the same for every finding of a kind; `why` and `fix` are this one's.
const STATIC_WHAT = {
  dispatch: 'Runtime dispatch: the method is chosen while the code runs, not when it compiles. Slow, and it allocates.',
  captured: 'Boxed capture: a closure reassigns a variable it captured, so the variable lives in an untyped box.',
};
const ABSTRACT = /::(Real|Number|AbstractFloat|Integer|Signed|Unsigned|AbstractString|Function|DataType|Abstract\w*(?:\{[^}]*\})?)(?![\w{])/g;
function explainStatic(g) {
  const sigs = [...g.sigs, ...g.libsigs].join('\n');
  const out = [];
  if (g.kinds.captured) {
    const vars = [...new Set(g.sigs.map(s => (/^([^\s=]+) = Core\.Box/.exec(s) || [])[1]).filter(Boolean))];
    const v = vars.map(x => '`' + x + '`').join(' and ') || 'a variable';
    out.push({ why: 'The closure reassigns ' + v + '.',
               fix: 'Use a plain loop, or a `Ref`: `' + (vars[0] || 'x') + ' = Ref(…)`, then `' + (vars[0] || 'x') + '[] = …`.' });
  }
  if (g.kinds.dispatch) {
    const abs = [...new Set([...sigs.matchAll(ABSTRACT)].map(m => m[1]))];
    const anyT = /::Any\b/.test(sigs), anyArr = /\{Any\}|Array\{Any|Vector\{Any/.test(sigs);
    if (abs.length) out.push({ why: 'Abstract type: `' + abs.slice(0, 3).join('`, `') + '`.',
                               fix: 'Use a concrete type, or a type parameter: `struct P{T<:Real}; β::T; end`.' });
    if (anyArr) out.push({ why: 'A `[]` container holds `Any`.', fix: 'Give it an element type: `Float64[]`.' });
    if (anyT && !abs.length && !anyArr) out.push({ why: 'A value here is inferred as `Any`.',
                                                  fix: '`@code_warntype` on the function shows where the type is lost.' });
    if (!abs.length && !anyT) out.push({ why: 'The argument types are not known at compile time.',
                                         fix: '`@code_warntype` on the function shows which value.' });
  }
  if (g.lib) out.push({ why: 'Also flagged: ' + g.lib + ' in `' + g.calls.slice(0, 3).join('`, `') + '`, called from this line with the same values. Fixing this line fixes ' + (g.lib === 1 ? 'it' : 'them') + ' too.' });
  return out;
}

function staticRows(file) {
  const st = pf.value && pf.value.prepared && pf.value.prepared.static;
  if (!st || !st.findings) return [];
  const by = new Map();
  for (const g of st.findings) {
    if (g.file !== file) continue;
    by.set(g.line, { line: g.line, j: g.count });
  }
  return [...by.values()];
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
  const shown = P.shownId || (h[0] && h[0].id), b = base.value;
  const label = (e) => when(e.at) + ' · ' + (e.mode || 'cpu') + ' · ' + ms(e.duration_ms);
  return html`<span class="pfhist">
    <select title="a kept profile of this cell" value=${shown} onChange=${e => showKept(e.currentTarget.value)}>
      ${h.some(e => e.id === shown) ? null : html`<option value=${shown}>${when(P.profile.at)}</option>`}
      ${h.map(e => html`<option value=${e.id}>${label(e)}</option>`)}</select>
    <select title="compare with an earlier profile" value=${b ? b.id : ''} onChange=${e => compareWith(e.currentTarget.value)}>
      <option value="">compare with…</option>
      ${b && !h.some(e => e.id === b.id) ? html`<option value=${b.id}>${when(b.profile.at)}</option>` : null}
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
// Brought in with the model set for the role (Settings → agent roles). It works in a pane of the dock:
// what it was asked, its reasoning, each step it takes, and its questions, beside the profile it is
// reading. While it works, the code pane and the graph follow what it looks at.
const specOpen = signal(false);
const specFollow = signal(ls('slateProfFollow', '1') !== '0');
const resolveFile = (f) => {
  const M = model.value; f = String(f || '');
  if (!M || !f) return f;
  const files = [...M.lines.keys()];
  return files.find(x => x === f) || files.find(x => x === 'cell:' + f) ||
         files.find(x => x.endsWith('/' + f)) || (f.startsWith('cell:') ? f : f);
};
// Show what it is looking at: the source it reads, the subtree it asks for.
function follow(name, inp) {
  if (!specFollow.value || !pf.value) return;
  const M = model.value;
  if (name === 'prof_source' && inp.file) { showCode(resolveFile(inp.file), +inp.line || 0); return; }
  if (name === 'prof_tree' && inp.at && M) {
    const m = /^(.*):(\d+)$/.exec(String(inp.at));
    if (m) {
      const file = resolveFile(m[1]), line = +m[2], n = heaviestAt(file, line);
      if (n) select(n);
      showCode(file, line);
      return;
    }
    let best = null;
    for (const n of M.nodes) if (n && (n.func === inp.at || String(n.func).includes('#' + inp.at + '#')) && (!best || n.total > best.total)) best = n;
    if (best) { select(best); if (best.kind === K.line) showCode(best.file, best.line); }
  }
}
const spec = specialistPane('profiler', {
  summonPath: '/api/profile/agent',
  verbs: { prof_run: 'profile', prof_check: 'check', prof_summary: 'summary', prof_tree: 'tree', prof_source: 'source',
           prof_eval: 'eval', read: 'read', edit_cell: 'edit', spec_ask: 'ask', spec_done: 'done' },
  arg: (name, inp) => name === 'prof_tree' ? (inp.at || 'the whole cell')
    : name === 'prof_source' ? (inp.file || '') + (inp.line ? ':' + inp.line : '')
    : name === 'prof_eval' ? String(inp.code || '').split('\n')[0]
    : name === 'prof_run' ? (inp.mode || 'cpu')
    : name === 'read' || name === 'edit_cell' ? (inp.cells || inp.cell || '')
    : name === 'spec_ask' ? String(inp.question || inp.text || '').split('\n')[0]
    : name === 'spec_done' ? String(inp.summary || '').split('\n')[0] : '',
  onStep: follow,
});
let _resumed = false;
function resumeSpecialist() { if (!_resumed) { _resumed = true; spec.resume(); } }
async function summonSpecialist() {
  const P = pf.value; if (!P) return;
  specOpen.value = true;
  await spec.summon(P.cell);
}
function Specialist() {
  const here = !!spec.agent.value, w = spec.working.value, waiting = spec.asks.value.length > 0;
  if (!here) return html`<button class="pfbtn" disabled=${spec.summoning.value} onClick=${summonSpecialist}
      title="bring in a profiling specialist to work on this cell with you">${spec.summoning.value ? html`<span class="hydspin"></span>` : '＋ specialist'}</button>`;
  return html`<button class=${'pfbtn' + (specOpen.value ? ' on' : '') + (waiting ? ' pfwait' : '')} onClick=${() => specOpen.value = !specOpen.value}
      title=${specOpen.value ? 'hide the specialist (it keeps working)' : 'show the specialist'}>
    ${w ? html`<span class="hydspin"></span> ` : null}${waiting ? '❓ ' : ''}specialist</button>`;
}
function SpecialistPane() {
  return html`<${spec.Pane} title="Profiling specialist" onClose=${() => specOpen.value = false}
    extra=${html`<label class="pftog" title="move the code pane and the graph to what it is looking at">
      <input type="checkbox" checked=${specFollow.value}
        onChange=${e => { specFollow.value = e.currentTarget.checked; lsSet('slateProfFollow', specFollow.value ? '1' : '0'); }}/><i></i>follow</label>`} />`;
}
// With the dock closed, a specialist that is working or waiting on you still says so.
function SpecBadge() {
  if (pf.value || !spec.agent.value) return null;
  const waiting = spec.asks.value.length > 0, w = spec.working.value;
  if (!waiting && !w) return null;
  const cell = spec.agent.value.cell;
  return html`<button class=${'pfbadge' + (waiting ? ' wait' : '')} onClick=${async () => { if (cell) { await openProfile(cell); specOpen.value = true; } }}>
    ${waiting ? '❓ the profiling specialist is waiting on you' : html`<span class="hydspin"></span> profiling specialist working`}</button>`;
}

// ── pane sizes ────────────────────────────────────────────────────────────────────────────────────
// Each split is a share of its container, kept across sessions. Double-click a bar to put it back.
const SPLITS = { code: 0.38, hot: 0.28, sandwich: 0.4, spec: 0.28 };
const split = Object.fromEntries(Object.entries(SPLITS).map(([k, d]) => [k, signal(clamp(+ls('slateProfSplit.' + k, d) || d, 0.1, 0.85))]));
// A bar between two panes. `edge`: which pane the share is of, the one before the bar or after it.
function Split({ name, dir, edge = 'before', min = 0.12, max = 0.8 }) {
  const sig = split[name];
  const down = (ev) => {
    if (ev.button !== 0) return;
    ev.preventDefault();
    const bar = ev.currentTarget, box = bar.parentNode.getBoundingClientRect();
    bar.classList.add('on'); document.body.classList.add('pfdrag-' + dir);
    const mv = (e) => {
      const f = dir === 'x' ? (e.clientX - box.left) / box.width : (e.clientY - box.top) / box.height;
      sig.value = clamp(edge === 'before' ? f : 1 - f, min, max);
    };
    const up = () => {
      window.removeEventListener('mousemove', mv); window.removeEventListener('mouseup', up);
      bar.classList.remove('on'); document.body.classList.remove('pfdrag-' + dir);
      lsSet('slateProfSplit.' + name, String(sig.value));
    };
    window.addEventListener('mousemove', mv); window.addEventListener('mouseup', up);
  };
  const reset = () => { sig.value = SPLITS[name]; lsSet('slateProfSplit.' + name, String(sig.value)); };
  return html`<div class=${'pfsplit ' + dir} onMouseDown=${down} onDblClick=${reset}></div>`;
}
const pctOf = (name) => (100 * split[name].value).toFixed(2) + '%';

// ── the dock ──────────────────────────────────────────────────────────────────────────────────────
const searchRef = { current: null };
function Dock() {
  const P = pf.value;
  if (!P) return null;
  const busy = P.status === 'preparing' || P.status === 'running' || P.status === 'waiting';
  const showSpec = specOpen.value && !!spec.agent.value;
  const mt = matches.value;
  const setTab = (t) => { tab.value = t; lsSet('slateProfTab', t); };
  return html`<div class="pfbg" onClick=${e => { if (e.target.classList.contains('pfbg')) close(); else optsOpen.value = false; }}>
    <div class=${'pfdock' + (P.side ? ' remote' : '')}>
      <div class="pfhead">
        <span class="pftitle">Profile</span>
        <span class="pfcell">cell ${P.cell}</span>
        ${P.side ? html`<span class="pfside">on ${P.side}</span>` : null}
        <span class="pfstatus">${busy ? html`<span class="hydspin"></span> ${P.status === 'preparing' ? 'compiling' : P.status === 'waiting' ? 'waiting to run' : 'running'}` : ''}</span>
        ${P.status === 'error' ? html`<span class="pfwarn">${P.error}</span>` : null}
        <span class="pfsp"></span>
        <${History} />
        <${Specialist} />
        <${JetStatus} />
        <button class="pfbtn" disabled=${busy} onClick=${prepare} title=${P.jet ? "compile the cell's code without running it, and check it with JET" : "compile the cell's code without running it"}>Compile</button>
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
      <div class="pfbody" style=${'grid-template-columns:minmax(220px,' + pctOf('code') + ') 0 minmax(0,1fr)' +
                                  (showSpec ? ' 0 minmax(280px,' + pctOf('spec') + ')' : '')}>
        <${Code} />
        <${Split} name="code" dir="x" max=${0.7} />
        <div class="pfright">
          <${Crumbs} />
          ${tab.value === 'timeline' ? html`<${Timeline} />` : tab.value === 'functions' ? html`<${Functions} />`
            : tab.value === 'details' ? html`<${Details} />` : html`<${Flame} />`}
          ${(tab.value === 'flame' || tab.value === 'timeline') && model.value ? html`
            <${Split} name="hot" dir="y" edge="after" min=${0.08} max=${0.7} />
            <${Hot} />` : null}
        </div>
        ${showSpec ? html`<${Split} name="spec" dir="x" edge="after" min=${0.18} max=${0.5} /><div class="pfspecpane"><${SpecialistPane} /></div>` : null}
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
    // Escape in the search box clears the search; the box's own handler does that.
    if (e.target && e.target.classList && e.target.classList.contains('pfsearch') && query.value) return;
    if (optsOpen.value) { optsOpen.value = false; e.stopPropagation(); return; }
    e.stopPropagation(); close(); return;
  }
  const tag = (e.target && e.target.tagName) || '';
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'BUTTON' || (e.target && e.target.isContentEditable)) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
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
.pffacts { padding:7px 14px; border-bottom:1px solid var(--border); background:var(--bg2); font-size:.76rem;
  display:flex; flex-wrap:wrap; align-items:baseline; gap:6px 20px; color:var(--text); white-space:nowrap; }
.pffig { display:inline-flex; align-items:baseline; gap:5px; }
.pffig b { font-size:.92rem; font-weight:600; font-variant-numeric:tabular-nums; }
.pffig i { font-style:normal; color:var(--dim); font-size:.72rem; }
.pffig.dim b { color:var(--dim); font-weight:500; }
.pffacts .pfwarn { overflow:hidden; text-overflow:ellipsis; max-width:60ch; }
.pfprep { color:var(--dim); }
.pfmode { color:#e8933a; align-self:center; padding:1px 8px; border-radius:10px; font-size:.68rem; text-transform:uppercase; letter-spacing:.06em;
  border:1px solid color-mix(in srgb, #e8933a 50%, transparent); background:color-mix(in srgb, #e8933a 14%, transparent); }
.pffacts .c b { color:#b9a3f5; }
.pffacts .g b { color:#f08a92; }
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
.pfbody { flex:1 1 auto; min-height:0; display:grid; }
.pfcode { position:relative; display:flex; flex-direction:column; min-width:0; min-height:0; border-right:1px solid var(--border); }
.pfjcard { position:absolute; z-index:5; width:420px; max-width:calc(100% - 16px); pointer-events:none; padding:9px 12px 10px;
  border-radius:8px; background:var(--bg2); border:1px solid color-mix(in srgb, #ffd27a 35%, var(--border));
  box-shadow:0 10px 30px rgba(0,0,0,.5); font-size:.74rem; line-height:1.5; color:var(--text); }
.pfjcard p { margin:5px 0 0; }
.pfjcard p code, .pfjwhy code { font-family:var(--mono,ui-monospace,monospace); font-size:.95em; color:var(--text);
  padding:0 3px; border-radius:3px; background:color-mix(in srgb, var(--bg3) 80%, transparent); }
.pfjcard b { color:#ffd27a; font-weight:600; margin-right:3px; }
.pfjchead { display:flex; align-items:center; justify-content:space-between; gap:8px; }
.pfjcwhat { color:var(--dim); }
.pfjcsigs { display:flex; flex-direction:column; gap:2px; margin-top:7px; padding-top:6px; border-top:1px solid var(--border); }
.pfjcsigs code { font-family:var(--mono,ui-monospace,monospace); font-size:.68rem; color:var(--dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
/* A split bar has no width of its own: a 9px grab area straddles the border it sits on. */
.pfsplit { position:relative; z-index:3; flex:0 0 0; }
.pfsplit::before { content:''; position:absolute; transition:background .12s; }
.pfsplit.x::before { top:0; bottom:0; left:-5px; width:9px; cursor:col-resize; }
.pfsplit.y::before { left:0; right:0; top:-5px; height:9px; cursor:row-resize; }
.pfsplit:hover::before, .pfsplit.on::before { background:color-mix(in srgb, #e8933a 35%, transparent); }
body.pfdrag-x, body.pfdrag-x * { cursor:col-resize !important; user-select:none !important; }
body.pfdrag-y, body.pfdrag-y * { cursor:row-resize !important; user-select:none !important; }
.pfcodehead { display:flex; align-items:center; gap:8px; padding:5px 10px; border-bottom:1px solid var(--border);
  font-family:var(--mono,ui-monospace,monospace); font-size:.74rem; }
.pffile { color:var(--text); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfback { font:inherit; font-size:.7rem; padding:1px 7px; border-radius:5px; background:transparent; border:1px solid var(--border); color:var(--dim); cursor:pointer; }
.pfback:hover { color:var(--text); }
.pfcodebody { flex:1 1 auto; min-height:0; overflow:auto; overscroll-behavior:contain; }
.pfcodebody .cm-editor { height:100%; }
.pfright { display:flex; flex-direction:column; min-width:0; min-height:0; }
.pfcrumbs { display:flex; flex-wrap:wrap; align-items:center; gap:3px; padding:5px 10px; border-bottom:1px solid var(--border); font-size:.72rem; }
.pfcrumb { font:inherit; font-family:var(--mono,ui-monospace,monospace); padding:1px 6px; border-radius:4px; background:transparent; border:1px solid transparent; color:var(--dim); cursor:pointer; }
.pfcrumb:hover { border-color:var(--border); color:var(--text); }
.pfcrumb.on { color:var(--text); }
.pfsep { color:var(--dim); }
.pfkey { display:inline-flex; gap:10px; color:var(--dim); font-size:.7rem; }
.pfkey i { font-style:normal; margin-right:3px; }
.pfcolorkey { margin-right:14px; padding-right:14px; border-right:1px solid var(--border); align-items:center; }
.pfsw { display:inline-block; width:10px; height:10px; border-radius:2px; vertical-align:-1px; }
.pfgrad { width:46px; background:linear-gradient(90deg, hsl(222, 22%, 30%), hsl(212, 48%, 36%), hsl(292, 64%, 44%), hsl(12, 80%, 52%)); }
.pfseg-sm button { padding:0 6px; font-size:.68rem; }
.pfzoom { display:inline-flex; align-items:center; gap:3px; margin-left:10px; }
.pfzoom button { font:inherit; min-width:24px; padding:1px 7px; border-radius:5px; cursor:pointer;
  background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.pfzoom button:hover { border-color:#e8933a; }
.pfzoom button[disabled] { opacity:.45; cursor:default; }
.pfzx { min-width:38px; text-align:center; color:var(--dim); font-variant-numeric:tabular-nums; }
.pfgraph { display:flex; flex-direction:column; flex:1 1 60%; min-height:0; }
.pfmini { display:block; margin:4px 8px 0; cursor:pointer; border-bottom:1px solid var(--border); }
.pfflame { position:relative; flex:1 1 60%; min-height:0; overflow:auto; padding:6px 8px; overscroll-behavior:contain; }
.pfflame canvas { display:block; cursor:pointer; position:sticky; top:0; }
.pfflame:active canvas { cursor:grabbing; }
.pfrange { display:none; position:absolute; z-index:2; pointer-events:none; background:color-mix(in srgb, #e8933a 16%, transparent);
  border-left:1px solid #e8933a; border-right:1px solid #e8933a; }
.pfbtn.pfbig { font-size:.86rem; padding:8px 20px; }
.pfempty { display:flex; align-items:center; justify-content:center; gap:8px; color:var(--dim); font-size:.82rem; }
.pftip { display:none; position:fixed; z-index:80; max-width:250px; pointer-events:none; padding:6px 8px;
  border-radius:6px; background:var(--bg2); border:1px solid var(--border); box-shadow:0 6px 20px rgba(0,0,0,.4);
  font-size:.72rem; color:var(--text); }
.pftip b { font-family:var(--mono,ui-monospace,monospace); font-weight:600; }
.pftw { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); }
.pftm { color:#ffd27a; }
.pfhot { flex:0 0 28%; min-height:0; overflow:auto; overscroll-behavior:contain; border-top:1px solid var(--border); font-size:.74rem; }
.pfhothead, .pfhotrow { display:grid; grid-template-columns:56px 90px 56px minmax(0,1fr); gap:8px; align-items:center; padding:3px 12px; }
.pfhothead > span:nth-child(1), .pfhothead > span:nth-child(3), .pfhothead.cmp > span:nth-child(4) { text-align:right; }
.pfhothead.cmp, .pfhotrow.cmp { grid-template-columns:56px 90px 56px 56px minmax(0,1fr); }
.pfhothead { color:var(--dim); font-size:.66rem; text-transform:uppercase; letter-spacing:.05em; position:sticky; top:0; z-index:1;
  background:var(--bg); border-bottom:1px solid color-mix(in srgb, var(--border) 60%, transparent); padding-top:5px; padding-bottom:4px; }
.pfhotrow { cursor:pointer; border-radius:4px; margin:0 4px; }
.pfhotrow .pfmk { display:inline-block; min-width:0; margin-right:4px; }
.pfhotrow .pfbar { width:100%; }
.pfhotrow:hover { background:color-mix(in srgb, #e8933a 12%, transparent); }
.pfsort { cursor:pointer; user-select:none; }
.pfsort:hover { color:var(--text); }
.pfsort.on { color:#e8933a; }
.pfnum { text-align:right; font-variant-numeric:tabular-nums; white-space:nowrap; }
.pfnum.dim { color:var(--dim); }
.pfloc { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pfsnip { color:var(--dim); margin-left:8px; }
.pfmk { color:#ffd27a; }
.pffuncs { flex:1 1 auto; min-height:0; display:grid; }
.pftable { overflow:auto; overscroll-behavior:contain; font-size:.74rem; }
.pfthead, .pftrow { display:grid; grid-template-columns:56px 80px 56px minmax(0, 1.3fr) minmax(0, 1fr) 44px; gap:8px; align-items:center; padding:3px 12px; }
.pfthead { color:var(--dim); font-size:.66rem; text-transform:uppercase; letter-spacing:.05em; position:sticky; top:0; z-index:1;
  background:var(--bg); border-bottom:1px solid var(--border); padding-top:5px; padding-bottom:4px; }
.pftrow { cursor:pointer; border-radius:4px; margin:0 4px; }
.pftrow .pfbar { width:100%; }
.pftrow:hover { background:color-mix(in srgb, #e8933a 10%, transparent); }
.pftrow.on { background:color-mix(in srgb, #ff6fd8 14%, transparent); }
.pffn { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pffile { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:var(--mono,ui-monospace,monospace); }
.pfsandwich { border-top:1px solid var(--border); overflow:auto; display:grid; grid-template-columns:1fr auto 1fr; gap:10px; padding:6px 10px; font-size:.74rem; }
.pfsandwich.pfempty { display:flex; }
.pfrelhead { color:var(--dim); font-size:.68rem; text-transform:uppercase; letter-spacing:.04em; margin-bottom:3px; }
.pfrelrow { display:grid; grid-template-columns:56px 60px minmax(0,1fr) auto; gap:6px; align-items:center; padding:2px 0; cursor:pointer; }
.pfrelrow:hover .pffn { color:#ff6fd8; }
.pfrelmid { align-self:start; margin-top:18px; padding:8px 14px; text-align:center; font-family:var(--mono,ui-monospace,monospace);
  border:1px solid color-mix(in srgb, #ff6fd8 40%, var(--border)); border-radius:8px; background:color-mix(in srgb, #ff6fd8 8%, var(--bg2)); }
.pfrelmid .pfdim { display:block; }
.pfbar { display:inline-block; height:6px; background:color-mix(in srgb, var(--bg3) 70%, transparent); border-radius:3px; overflow:hidden; }
.pfbar i { display:block; height:100%; border-radius:3px; background:linear-gradient(90deg, #c8742a, #f0a54a); }
.pfdetails { flex:1 1 auto; overflow:auto; overscroll-behavior:contain; padding:8px 10px; display:flex; flex-direction:column; gap:14px; font-size:.74rem; }
.pfdetrow { display:grid; grid-template-columns:80px 80px minmax(0,1fr); gap:8px; padding:2px 0; }
.pfjetpill { align-self:center; padding:1px 8px; border-radius:10px; font-size:.68rem; letter-spacing:.04em; color:#ffd27a;
  border:1px solid color-mix(in srgb, #ffd27a 45%, transparent); background:color-mix(in srgb, #ffd27a 10%, transparent); cursor:default; }
.pfjetadd { color:var(--dim); border-style:dashed; }
.pfjetadd:hover { color:var(--text); }
.pfjwhat { display:flex; flex-direction:column; gap:4px; margin:0 6px 8px; color:var(--dim); font-size:.72rem; }
.pfjwhat .pfjk { margin-right:4px; }
.pfjwhy { grid-column:2 / -1; color:var(--dim); font-size:.7rem; line-height:1.45; }
.pfjwhy b { color:var(--text); font-weight:600; }
.pfspecpane { min-width:0; min-height:0; border-left:1px solid var(--border); }
.pfbtn.on { border-color:#e8933a; }
.pfbtn.pfwait { border-color:#ffd27a; color:#ffd27a; }
.pfbadge { position:fixed; right:18px; bottom:18px; z-index:65; display:inline-flex; align-items:center; gap:7px; padding:7px 13px;
  border-radius:18px; font:inherit; font-size:.78rem; cursor:pointer; color:var(--text); background:var(--bg2);
  border:1px solid color-mix(in srgb, #e8933a 50%, var(--border)); box-shadow:0 8px 24px rgba(0,0,0,.4); }
.pfbadge.wait { border-color:#ffd27a; color:#ffd27a; }
.pfjks { display:inline-flex; flex-wrap:wrap; gap:3px; }
.pfjet { display:grid; grid-template-columns:130px minmax(0, 360px) minmax(0, 1fr); gap:10px; align-items:center;
  padding:3px 6px; border-radius:4px; cursor:pointer; }
.pfjet:hover { background:color-mix(in srgb, #e8933a 10%, transparent); }
.pfjk { justify-self:start; padding:0 7px; border-radius:9px; font-size:.68rem; color:#ffd27a;
  border:1px solid color-mix(in srgb, #ffd27a 45%, transparent); background:color-mix(in srgb, #ffd27a 10%, transparent); }
.pfjk.captured { color:#7fd4ff; border-color:color-mix(in srgb, #7fd4ff 45%, transparent); background:color-mix(in srgb, #7fd4ff 10%, transparent); }
.pffigbtn { font:inherit; background:none; border:none; padding:0; cursor:pointer; color:inherit; }
.pffigbtn:hover i { color:var(--text); }
.pffacts .j b { color:#ffd27a; }
.cm-heatm .pfm.j { color:#ffd27a; }
.cm-jet { text-decoration:underline wavy color-mix(in srgb, #ffd27a 70%, transparent); text-underline-offset:3px; }
.pfdetkv { display:grid; grid-template-columns:90px minmax(0,1fr); gap:8px; padding:2px 0; }
.pfdetkv > span:first-child { color:var(--dim); }
.pfdet { max-width:1100px; }
.pfdethead { color:var(--dim); font-size:.68rem; }
.pfsig { font-family:var(--mono,ui-monospace,monospace); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
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
render(html`<${Dock} /><${SpecBadge} />`, host);
