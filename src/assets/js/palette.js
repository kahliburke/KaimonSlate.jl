// ── @bind control snippets ────────────────────────────────────────────────────
// One-click insert of a reactive control. Drops the snippet into the selected code
// cell's editor at the cursor, else seeds a fresh code cell below — then the user
// renames the variable and runs it. Surfaced both in ⌘K and the ☰ menu.
const BIND_SNIPPETS = [
  ['Slider',      '@bind n Slider(1:100)'],
  ['NumberField', '@bind x NumberField(0)'],
  ['Toggle',      '@bind flag Toggle(false; on="On", off="Off")'],
  ['Checkbox',    '@bind on Checkbox(false)'],
  ['TextField',   '@bind s TextField("")'],
  ['TextArea',    '@bind txt TextArea("")'],
  ['Select',      '@bind choice Select(["a" => "Option A", "b" => "Option B"])'],
  ['Radio',       '@bind pick Radio(["a" => "Choice A", "b" => "Choice B"]; label="Pick one")'],
  ['MultiSelect', '@bind picks MultiSelect(["a" => "A", "b" => "B", "c" => "C"])'],
  ['MultiCheckBox', '@bind picks MultiCheckBox(["a" => "A", "b" => "B", "c" => "C"])'],
  ['ColorPicker', '@bind col ColorPicker("#56d364")'],
  ['DateField',   '@bind d DateField()'],
  ['TimeField',   '@bind t TimeField()'],
  ['Button',      '@bind go Button("Run")'],
  ['FileUpload',  '@bind f FileUpload(; accept = ".csv", label = "Data")'],
  ['RangeSlider', '@bind span RangeSlider(0:100; default = (20, 80), label = "range")'],
  ['TableSelect', '@bind sel TableSelect(df)   # click a row → sel is a NamedTuple (sel.col)'],
];
async function insertBind(snippet) {
  if (selectedId && editors[selectedId]) { const cur = edText(selectedId); edInsert(selectedId, (cur.trim() ? '\n' : '') + snippet); return; }
  await addCellWithSource(selectedId || '', snippet);   // race-free: commits source server-side
}
// ── Recipes ───────────────────────────────────────────────────────────────────
// Starter code for common tasks (mostly Makie plots, dark theme). Each drops into a
// fresh code cell below the selection, ready to edit and run. Surfaced in ⌘K.
const RECIPES = [
  ['Plotting setup — CairoMakie + dark theme',
`using CairoMakie
set_theme!(theme_dark())`],
  ['Line plot',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; xlabel = "x", ylabel = "y", title = "Line")
x = range(0, 2π; length = 200)
lines!(ax, x, sin.(x))
fig`],
  ['Scatter plot',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; xlabel = "x", ylabel = "y", title = "Scatter")
scatter!(ax, randn(200), randn(200); markersize = 7, color = (:cyan, 0.6))
fig`],
  ['Multi-series + legend',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; xlabel = "x", ylabel = "y", title = "Series")
x = range(0, 2π; length = 200)
lines!(ax, x, sin.(x); label = "sin")
lines!(ax, x, cos.(x); label = "cos")
axislegend(ax)
fig`],
  ['Bar chart',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; xlabel = "category", ylabel = "value", title = "Bar")
barplot!(ax, 1:5, [3, 1, 4, 1, 5])
fig`],
  ['Histogram',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; xlabel = "value", ylabel = "count", title = "Histogram")
hist!(ax, randn(1000); bins = 30)
fig`],
  ['Heatmap + colorbar',
`fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; title = "Heatmap")
hm = heatmap!(ax, randn(24, 24))
Colorbar(fig[1, 2], hm)
fig`],
  ['Subplots (2×1)',
`fig = Figure(size = (640, 480))
x = range(0, 2π; length = 200)
lines!(Axis(fig[1, 1]; title = "top"), x, sin.(x))
lines!(Axis(fig[2, 1]; title = "bottom"), x, cos.(x))
fig`],
  ['Reactive plot — slider + Makie',
`@bind freq Slider(1:20; default = 5, label = "freq")
fig = Figure(size = (640, 360))
ax = Axis(fig[1, 1]; title = "sin(\$(freq)·x)")
x = range(0, 2π; length = 400)
lines!(ax, x, sin.(freq .* x))
fig`],
  ['DataFrame + interactive table',
`using DataFrames
df = DataFrame(x = 1:50, y = randn(50), grp = rand(["a", "b", "c"], 50))
slate_table(df)`],
  // ECharts DSL — `echart(:kind, x, y; …)` (Express) or `echart(series(…), …; …)` (multi).
  // Any extra kwarg / top-level component (grid, dataZoom, visualMap, …) passes through raw.
  ['ECharts line',
`echart(:line, ["Mon", "Tue", "Wed", "Thu", "Fri"], [120, 200, 150, 80, 70];
       title = "Weekly", smooth = true)`],
  ['ECharts bar',
`echart(:bar, ["A", "B", "C", "D", "E"], [5, 20, 36, 10, 12]; title = "Counts")`],
  ['ECharts pie',
`echart(:pie, ["A", "B", "C", "D"], [40, 30, 20, 10]; title = "Share")`],
  ['ECharts scatter',
`echart(:scatter, randn(60), randn(60); symbolSize = 9)`],
  ['ECharts multi-series',
`x = range(0, 2π; length = 120)
echart(
    series(:line, x, sin.(x); name = "sin", smooth = true),
    series(:line, x, cos.(x); name = "cos", smooth = true);
    title = "Trig", legend = true,
)`],
  ['ECharts raw option',
`# Full control: any ECharts option, Symbol/NamedTuple-friendly.
echart(
    xAxis  = (type = :category, data = ["A", "B", "C"]),
    yAxis  = (type = :value,),
    series = [(type = :bar, data = [5, 9, 3])],
    dataZoom = [(type = :slider,)],
)`],
];
async function insertRecipe(code) {
  await addCellWithSource(selectedId || '', code);      // race-free: commits source server-side
}

// ── Extension-contributed commands ────────────────────────────────────────────
// The host global behind SlateExtensionsBase's `register_palette_command!`, mirroring
// `slateRegisterCellAction`. An extension's injected script calls this once per command; the registry
// keys by `id` so a re-injection (every run drain re-runs `__slate_frontend`) replaces rather than
// stacks, and insertion order keeps a package's commands grouped.
//
// It registers into the SAME registry as the built-ins, which is what makes an extension's command
// bindable from the Keyboard panel: it gets a row, it can be given a chord, and a `key:` it declares
// is honoured as that command's default binding rather than being printed as decoration. The id is
// namespaced so a package cannot collide with a core command or with another package.
window.slateRegisterCommand = function (spec) {
  if (!spec || !spec.id || typeof spec.run !== 'function') return;
  const ext = spec.ext || spec.tag || 'ext';
  window.slateCmd.register({
    id: 'ext/' + ext + '/' + spec.id,
    label: spec.label || spec.id,
    group: 'Extension: ' + ext,
    ctx: spec.ctx && spec.ctx.length ? spec.ctx : ['command'],
    keys: spec.key ? [spec.key] : [],
    ext: ext,
    // An extension's `run` takes the selected cell id, so it can act on a cell without reaching into
    // our globals. Errors are reported rather than thrown: one bad extension must not take the
    // keyboard down with it.
    run: t => spec.run(t.id || ''),
  });
  window.slateKeymap && window.slateKeymap.rebuild();   // a declared `key:` has to reach the index
};
window.slateUnregisterCommand = function (id) {
  for (const c of window.slateCmd.all()) {
    if (c.id.startsWith('ext/') && c.id.endsWith('/' + id)) window.slateCmd.unregister(c.id);
  }
  window.slateKeymap && window.slateKeymap.rebuild();
};

// ── Command palette (⌘K) ──────────────────────────────────────────────────────
// The list is DERIVED from the command registry (commands.js), so an action is written down once and
// its palette row, its shortcut hint and its keybinding cannot disagree. The hint in particular used
// to be a hand-typed glyph string — `'⌥↑'`, `'d d'` — with nothing tying it to the handler that ran,
// so the palette went on advertising chords that had been changed or removed.
//
// What stays local to this file is everything that is NOT an action on the document: source snippets
// to insert, and the editor hand-offs. Those have no keybinding and nothing else needs their ids.
//
// A WORKBOOK gets a narrow ALLOWLIST rather than a filter over the authoring list. Same reasoning as
// the route allowlist in server_app.jl: a filter has to be remembered every time a command is added,
// and forgetting is silent. This way a new authoring command is absent from a workbook until someone
// puts it here on purpose. Everything listed either reads the document or runs the reader's own code —
// the two things a workbook already permits.
const _WORKBOOK_CMDS = ['view.docs', 'view.settings', 'view.keymap', 'view.scratch', 'view.toc',
                        'nb.runStale', 'cell.run', 'cell.runAdvance'];

// One registry command → one palette row. The hint is asked for at render time, so reopening the
// palette after a rebind shows the new chord with nothing to invalidate.
const _row = c => ({
  label: c.label,
  key: window.slateCmd.hint(c.id),
  tag: c.ext || _TAGS[c.id] || '',
  run: () => window.slateCmd.run(c.id),
});
// A few rows carry a badge that groups them visually in the list. Cosmetic, and deliberately sparse.
const _TAGS = { 'view.packages': 'panel', 'view.workerLog': 'panel', 'view.history': 'panel',
                'view.extensions': 'panel', 'view.settings': 'panel', 'view.keymap': 'panel',
                'view.sessions': 'panel',
                'view.files': 'panel', 'view.zen': 'zen', 'view.present': 'present',
                'view.presenter': 'present', 'view.export': 'export', 'view.publish': 'publish' };

function paletteCommands() {
  const workbook = typeof SLATE_IS_WORKBOOK !== 'undefined' && SLATE_IS_WORKBOOK;
  const cmds = [];
  for (const c of window.slateCmd.listed()) {
    if (workbook && _WORKBOOK_CMDS.indexOf(c.id) < 0) continue;
    cmds.push(_row(c));
  }
  if (!workbook) {
    // Palette-only rows: they insert source or hand off to another program, so there is nothing to
    // bind a key to and no id anything else would ask for.
    cmds.push(
      { label: 'Settings: this notebook… (config / overrides)', tag: 'panel', run: () => openSettings('notebook') },
      { label: 'Export PDF (slides)', tag: 'export', run: () => exportSlidesPdf() },
      ...BIND_SNIPPETS.map(([name, snip]) => ({ tag: '@bind', label: 'Insert @bind: ' + name, run: () => insertBind(snip) })),
      ...RECIPES.map(([name, code]) => ({ tag: 'recipe', label: 'Recipe: ' + name, run: () => insertRecipe(code) })),
      { label: 'Open notebook in VS Code', run: () => { const p = nbState && nbState.path; if (p) location.href = 'vscode://file' + p; } },
      { label: 'Open project in VS Code', run: () => { const d = nbState && (nbState.project || window.PLATFORM.dirOf(nbState.path || '').replace(/[\/\\]$/, '')); if (d) location.href = 'vscode://file' + d; } },
    );
  }
  // Jump-to-cell is generated per cell, and stays even in a workbook: it is navigation, and a reader
  // has no other way to move to a cell by name.
  for (const c of window.slateCellCommands()) cmds.push({ label: c.label, tag: 'cell', run: c.run });
  return cmds;
}
let _cmd = [], _cmdSel = 0;
const _escc = s => window.slateEscHtml(s);
// Recently-used commands bubble to the top (persisted in localStorage) — the palette learns your habits.
const _MRU_KEY = 'slate.palette.mru';
function _mruLoad() { try { return JSON.parse(localStorage.getItem(_MRU_KEY) || '[]'); } catch (_) { return []; } }
function _mruBump(label) {
  try { let a = _mruLoad().filter(l => l !== label); a.unshift(label); localStorage.setItem(_MRU_KEY, JSON.stringify(a.slice(0, 12))); } catch (_) {}
}
function openPalette() {
  document.getElementById('cmdbg').classList.add('show');
  const inp = document.getElementById('cmdin'); inp.value = '';
  inp.oninput = () => renderPaletteList(inp.value);
  renderPaletteList(''); inp.focus();
}
function closePalette() { document.getElementById('cmdbg').classList.remove('show'); }
// What the `view.palette` command runs: a second press of the chord dismisses the palette rather than
// reopening it on itself.
window.slateTogglePalette = () =>
  document.getElementById('cmdbg').classList.contains('show') ? closePalette() : openPalette();
function renderPaletteList(filter) {
  const f = filter.trim().toLowerCase();
  const mru = _mruLoad(), rank = c => { const i = mru.indexOf(c.label); return i < 0 ? Infinity : i; };
  // Filter by substring, then STABLE-sort recently-used first (by MRU position); everything else keeps its
  // declared order. Applies with or without a query, so a searched-for common command also ranks up.
  _cmd = paletteCommands().filter(c => c.label.toLowerCase().includes(f))
    .map((c, i) => [c, i]).sort((a, b) => (rank(a[0]) - rank(b[0])) || (a[1] - b[1])).map(x => x[0]);
  _cmdSel = 0;
  document.getElementById('cmdlist').innerHTML = _cmd.map((c, i) => {
    const right = (c.key ? `<span class="kb">${_escc(c.key)}</span>` : '') + (c.tag ? `<span class="k">${_escc(c.tag)}</span>` : '');
    return `<li class="${i === 0 ? 'on' : ''}" data-i="${i}"><span>${_escc(c.label)}</span><span class="cright">${right}</span></li>`;
  }).join('');
}
function _paintCmd() {
  const ul = document.getElementById('cmdlist');
  [...ul.children].forEach((li, i) => li.classList.toggle('on', i === _cmdSel));
  const on = ul.children[_cmdSel]; if (on) on.scrollIntoView({ block: 'nearest' });
}
function _cmdRun(i) { const c = _cmd[i]; closePalette(); if (c) { _mruBump(c.label); c.run(); } }
document.getElementById('cmdlist').addEventListener('mousedown', e => { const li = e.target.closest('li'); if (li) { e.preventDefault(); _cmdRun(+li.dataset.i); } });
document.getElementById('cmdin').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { e.preventDefault(); _cmdSel = Math.min(_cmdSel + 1, _cmd.length - 1); _paintCmd(); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); _cmdSel = Math.max(_cmdSel - 1, 0); _paintCmd(); }
  else if (e.key === 'Enter') { e.preventDefault(); _cmdRun(_cmdSel); }
  else if (e.key === 'Escape') { e.preventDefault(); closePalette(); }
});
document.getElementById('cmdbg').addEventListener('mousedown', e => { if (e.target.id === 'cmdbg') closePalette(); });

// ── Docs / help browser (⌘⇧K) — semantic search + live `?name` help, in a dockable panel ──
// A bottom-right dock: semantic search of the notebook's package docs PLUS a REPL-style help
// viewer (markdown docstrings, clickable `refs`, module-exports drill-down). Searches and
// opened pages form a back/forward history; the panel minimizes to a launcher and restores.
// `!` is legal at the end of a bare Julia identifier (`cut!`, `assign!`), not just in a dotted segment —
// without it, a `!`-suffixed name skipped the live `?name` lookup and only hit the semantic index (which
// misses newly-defined / not-yet-indexed symbols), so you'd have to qualify it (`NeuroDSL.cut!`) to resolve.
const _IDENT_RE = /^[A-Za-z_][A-Za-z0-9_!]*(\.[A-Za-z_][A-Za-z0-9_!]*)*$/;
const _NOLINK = new Set(['true','false','nothing','missing','end','function','for','while','if','x','i','n','a','b']);
const _DOC_HINT = '<li class="dochint">Describe an API in plain words — e.g. “draw a heatmap” — or type an exact name / module (e.g. <code>LinearAlgebra</code>) to browse it.</li>';

// History of "views". A view = { q, results, sel, rec }; rec=null shows results[sel].
let _hist = [], _hpos = -1, _docMin = true;
const _view = () => _hpos >= 0 ? _hist[_hpos] : null;
function _go(v) {                                   // push a view, truncating any forward history
  _hist = _hist.slice(0, _hpos + 1); _hist.push(v); _hpos = _hist.length - 1;
  if (_hist.length > 100) { _hist.shift(); _hpos--; }
  _renderView(); _saveDocs();
}
function _navBack() { if (_hpos > 0) { _hpos--; _renderView(); _saveDocs(); } else minimizeDocs(); }
function _navFwd()  { if (_hpos < _hist.length - 1) { _hpos++; _renderView(); _saveDocs(); } }

function openDocs() {                               // show the dock (un-minimize); keeps prior state
  _docReturn = null;                               // opened directly (not from a cell) → nothing to return to
  _docMin = false;
  document.getElementById('docpanel').classList.remove('min');
  document.getElementById('doclauncher').classList.add('hidden');
  _hpos < 0 ? _go({ q: '', results: [], sel: 0, rec: null }) : _renderView();
  document.getElementById('docin').focus(); _saveDocs();
}
function minimizeDocs() {                           // collapse to the launcher pill (state retained)
  _docMin = true;
  document.getElementById('docpanel').classList.add('min');
  document.getElementById('doclauncher').classList.remove('hidden');
  _saveDocs();
  const r = _docReturn; _docReturn = null;         // return focus to the cell ⌘⇧K was fired from
  if (r && r.cm) { try { r.cm.focus(); r.cm.dispatch({ selection: { anchor: r.pos } }); } catch (_) {} }
}
const closeDocs = minimizeDocs;                     // "close" now means minimize
function toggleDocs() { _docMin ? openDocs() : minimizeDocs(); }   // ⌘⇧K — open ↔ minimize

// The dotted identifier the cursor sits on or beside, in a focused cell editor — powers
// ⌘⇧K "help on this symbol". Expands over `[\w!.]` both ways, then trims stray dots
// (so `a.b.` → `a.b`, and a cursor just past `foo` still resolves `foo`).
function _symbolAtCursor(view) {                    // CM6 EditorView
  const head = view.state.selection.main.head, line = view.state.doc.lineAt(head);
  const text = line.text, ch = head - line.from;
  const ident = c => c && /[A-Za-z0-9_!.]/.test(c);
  let a = ch, b = ch;
  while (a > 0 && ident(text[a - 1])) a--;
  while (b < text.length && ident(text[b])) b++;
  return text.slice(a, b).replace(/^\.+|\.+$/g, '');
}
// Whichever editor has focus, from the REGISTRY rather than the cell map. `window.editors` holds one
// view per cell, so a web cell's CSS and JS panes are not in it and a file editor never is — asking
// it which view has focus answered a page-wide question with a map that cannot know.
function _focusedEditorCM() {
  const all = (window.slateAllEditors && window.slateAllEditors()) || [];
  for (const v of all) if (v && v.hasFocus) return v;
  return null;
}
// Symbol help is JULIA documentation, so it applies where the text is Julia. A view's `_edctx.lang`
// names a non-Julia grammar (a web cell's html/css/js pane, or a file the Julia tree would only
// mis-colour); no `lang` is the Julia tree, which covers code cells, markdown cells and .jl files.
//
// Without this, the same web cell behaved two ways: its HTML pane is the one registered for the
// cell, so ⌘⇧K there looked up an HTML token in Base, while the CSS and JS panes were invisible here
// and quietly toggled the dock instead.
const _juliaTree = v => { const c = v && v._edctx; return !!c && !c.lang; };
// ⌘⇧K: help for the symbol under the cursor (refocus the cell on close), else toggle the dock.
// Exposed so the CM6 editor keymap can bind it — CM6's defaultKeymap otherwise eats ⌘⇧K (deleteLine).
function openDocsAtCursor() {
  const cm = _focusedEditorCM(), sym = (cm && _juliaTree(cm)) ? _symbolAtCursor(cm) : '';
  if (sym) { const pos = cm.state.selection.main.head; openDocsFor(sym); _docReturn = { cm, pos }; }
  else toggleDocs();
}
window.openDocsAtCursor = openDocsAtCursor;
// Where to send focus back when the help pane closes (set when ⌘⇧K is fired from a cell).
let _docReturn = null;
// Open the help dock searching for `name` (semantic docsearch + live `?name` lookup, pinned).
function openDocsFor(name) {
  openDocs();
  const inp = document.getElementById('docin'); inp.value = name; _docSearch();
}
function _saveDocs() {
  try { localStorage.setItem('slateDocs', JSON.stringify({ min: _docMin, q: (_view() && _view().q) || '' })); } catch (_) {}
}
function _restoreDocs() {
  let s; try { s = JSON.parse(localStorage.getItem('slateDocs') || '{}'); } catch (_) { s = {}; }
  if (s && s.min === false) { openDocs(); if (s.q) { document.getElementById('docin').value = s.q; _docSearch(); } }
}
// Search runs on Enter (not as-you-type) — the docs search is an expensive embedding+FTS query, so
// firing it per keystroke was both laggy and wasteful. `_docLastQ` is the query last searched, so
// the first Enter on a new query SEARCHES and a subsequent Enter OPENS the selected result.
let _docLastQ = null;
async function _runDocSearch() {
  const q = document.getElementById('docin').value.trim();
  _docLastQ = q;
  let results = [];
  if (q) {
    try { const r = await api('GET', '/api/docsearch?q=' + encodeURIComponent(q)); results = (r && r.results) || []; } catch (_) {}
    if (_IDENT_RE.test(q)) {                        // exact name/module → live lookup, pinned on top
      try {
        const hr = await api('GET', '/api/help?name=' + encodeURIComponent(q));
        const hname = _bareName(hr && hr.module, hr && hr.name);
        if (hr && hr.name && (hr.docHtml || (hr.exports && hr.exports.length) || hr.kind !== 'unknown'))
          results = [{ module: hr.module || hr.name, name: hname, doc: hr.doc, docHtml: hr.docHtml,
                       exports: hr.exports || [], kind: hr.kind, exact: true, _enriched: true },
                     ...results.filter(r => !(r.name === hname && (r.module || '') === (hr.module || '')))];
      } catch (_) {}
    }
  }
  results = _rankResults(results, q);              // float literal name matches above pure-semantic hits
  const cur = _view();
  if (cur && cur.rec == null) { cur.q = q; cur.results = results; cur.sel = 0; _renderView(); _saveDocs(); }   // live-update the search view
  else _go({ q, results, sel: 0, rec: null });     // a new search after viewing a page → new history step
}
const _docSearch = _runDocSearch;   // callers that programmatically set the input + search (run immediately)
// Re-rank: a result whose NAME matches the query (exact > prefix > substring) outranks a
// closer-embedding but lexically-unrelated hit — semantic search alone buries obvious matches.
function _rankResults(results, q) {
  const ql = q.trim().toLowerCase();
  return results.map((r, i) => {
    const n = (r.name || '').toLowerCase();
    let b = 0; r._nameMatch = false;
    if (r.exact) b = 1000;
    else if (ql.length >= 2) {
      if (n === ql) { b = 100; r._nameMatch = true; }
      else if (n.startsWith(ql)) { b = 60; r._nameMatch = true; }
      else if (n.includes(ql)) { b = 30; r._nameMatch = true; }
    }
    return { r, b, i };
  }).sort((a, b) => (b.b - a.b) || ((Number(b.r.score) || 0) - (Number(a.r.score) || 0)) || (a.i - b.i)).map(x => x.r);
}
function _select(i) {                               // pick a result row (in place — not a history step)
  const v = _view(); if (!v || !v.results.length) return;
  v.sel = Math.max(0, Math.min(i, v.results.length - 1)); v.rec = null;
  _renderView(); _saveDocs();
}
// Paint the current view into both panes + the nav buttons + the search box.
function _renderView() {
  const v = _view(), ul = document.getElementById('doclist'), dt = document.getElementById('docdetail');
  const bb = document.getElementById('docback2'), fb = document.getElementById('docfwd');
  if (bb) bb.disabled = _hpos <= 0; if (fb) fb.disabled = _hpos >= _hist.length - 1;
  const inp = document.getElementById('docin'); if (v && document.activeElement !== inp && inp.value !== v.q) inp.value = v.q;
  if (!v || !v.q) ul.innerHTML = _DOC_HINT;
  else if (!v.results.length) ul.innerHTML = '<li class="docempty">No matches — try different words.</li>';
  else ul.innerHTML = v.results.map((r, i) => {
    // Tag only meaningful relevance: exact/name matches. The raw fusion (RRF) score is tiny and
    // near-uniform (~0.04) — useless to a human — so semantic-only hits show no number; the list
    // order already conveys relevance.
    const right = r.exact ? '<span class="k exact">exact</span>'
                : r._nameMatch ? '<span class="k exact">name</span>' : '';
    const label = (r.module && r.module !== r.name) ? `${_escc(r.module)}.<b>${_escc(r.name)}</b>` : `<b>${_escc(r.name)}</b>`;
    return `<li class="${i === v.sel && !v.rec ? 'on' : ''}" data-i="${i}"><span class="docname">${label}${right}</span></li>`;
  }).join('');
  const rel = document.getElementById('docrelated');
  const r = v && (v.rec || (v.results && v.results[v.sel]));
  if (!r) { dt.innerHTML = ''; rel.innerHTML = ''; return; }
  dt.innerHTML = _helpRecordHtml(r);
  // Docstrings carry `$…$` / `$$…$$` as often as prose cells do (Base and the SciML/plotting
  // ecosystem write their maths that way). markdown_html leaves the TeX verbatim for KaTeX, so
  // without this the help pane shows the raw delimiters. After linkify: that rewrites `code`
  // spans, which KaTeX ignores anyway.
  _linkifyDoc(dt, r); _typesetDoc(dt); dt.scrollTop = 0;
  _renderRelated(r);                           // the right rail (referenced + related)
  r._enriched || _enrichDetail(r);             // upgrade with live exports/doc on first view
}
const _shownRecord = () => { const v = _view(); return v && (v.rec || (v.results && v.results[v.sel])); };
// Names linked in the current detail pane (the type/ref tokens we just linkified), unique.
function _referenced() {
  const seen = new Set(), out = [];
  document.querySelectorAll('#docdetail .doclink[data-name]').forEach(a => { const n = a.dataset.name; if (n && !seen.has(n)) { seen.add(n); out.push(n); } });
  return out;
}
// The right rail: "Referenced" (type/ref tokens in the doc) + "Related" (semantic neighbors,
// fetched once and cached on the record). Empty rail collapses via .docrelated:empty.
async function _renderRelated(r) {
  const el = document.getElementById('docrelated');
  const chip = (name, label) => `<button class="relchip" data-name="${_escc(name)}">${_escc(label || name)}</button>`;
  const sec = (title, chips) => chips.length ? `<div class="relhdr">${title}</div><div class="relgrid">${chips.join('')}</div>` : '';
  const refs = _referenced().map(n => chip(n, n.replace(/^.*\./, '')));
  const rel = Array.isArray(r._related) ? r._related.map(n => chip((n.module ? n.module + '.' : '') + n.name, n.name)) : [];
  el.innerHTML = sec('Referenced', refs) + sec('Related', rel);
  if (r._related === undefined && r.name) {     // fetch semantic neighbors once
    r._related = null;
    let res = [];
    try { const x = await api('GET', '/api/docsearch?q=' + encodeURIComponent(_lookupName(r))); res = (x && x.results) || []; } catch (_) {}
    r._related = res.filter(n => !(n.name === r.name && (n.module || '') === (r.module || ''))).slice(0, 8);
    if (_shownRecord() === r) _renderRelated(r); // repaint with the related section
  }
}
const _lookupName = r => (r.module && r.module !== r.name) ? r.module + '.' + r.name : r.name;
// A record keeps `name` BARE and `module` as the qualifier, and everything that displays or re-looks-up
// a record composes the two. `/api/help?name=Mod.fn` answers with the qualified name in `name`, so a
// record built straight from that reply renders `Mod.Mod.fn`. Only reachable by searching a dotted
// name, which is what name completion now produces.
const _bareName = (mod, nm) => (mod && nm && nm.startsWith(mod + '.')) ? nm.slice(mod.length + 1) : nm;
// Lazily upgrade the shown record with a LIVE help lookup — fills in a module's exports
// (the drill-down grid) + a fresh docstring, so ANY module/binding becomes browseable, not
// just an exactly-typed query. One lookup per record (cached on the record).
async function _enrichDetail(r) {
  if (r._enriched || !r.name) return;
  r._enriched = true;
  let hr;
  try { hr = await api('GET', '/api/help?name=' + encodeURIComponent(_lookupName(r))); } catch (_) { return; }
  if (!hr || !hr.name) return;
  if (hr.docHtml) r.docHtml = hr.docHtml;
  if (hr.exports && hr.exports.length) r.exports = hr.exports;
  if (hr.kind && hr.kind !== 'unknown') r.kind = hr.kind;
  const v = _view(), shown = v && (v.rec || (v.results && v.results[v.sel]));
  if (shown === r) _renderView();              // still showing this one → repaint with exports
}
function _helpRecordHtml(r) {
  const kind = r.kind && r.kind !== 'unknown' ? `<span class="dockind">${_escc(r.kind)}</span>` : '';
  const mod = r.module || '';
  let nm = r.name;
  if (mod && nm.startsWith(mod + '.')) nm = nm.slice(mod.length + 1);   // de-dup "Mod.Mod.x" on drill-in
  const title = (mod && mod !== nm) ? `${_escc(mod)}.<b>${_escc(nm)}</b>` : `<b>${_escc(nm)}</b>`;
  const body = r.docHtml ? `<div class="docmd">${r.docHtml}</div>` : '<div class="docmd dim">No documentation found.</div>';
  let exports = '';
  if (r.exports && r.exports.length) {
    const base = r.module || r.name;
    exports = `<div class="docexports"><div class="docexhdr">Exports · ${r.exports.length}</div><div class="docexgrid">` +
      r.exports.map(e => `<button class="docexport kind-${_escc(e.kind)}" data-name="${_escc(base + '.' + e.name)}" title="${_escc(e.kind)} — click to open">${_escc(e.name)}</button>`).join('') +
      '</div></div>';
  }
  return `<div class="dochead"><h4>${title}</h4>${kind}</div>${body}${exports}` +
    '<div class="hint">↵ open · double-click a result to insert its name · click a <code>ref</code> or export to drill in · ‹ › or esc to go back</div>';
}
// KaTeX over a rendered docstring. `typeset` is core.js's global (a no-op before KaTeX loads).
function _typesetDoc(el) { if (window.typeset) try { window.typeset(el); } catch (_) {} }
// Make identifiers in a docstring clickable (drill-in via the #docdetail delegation):
//  • an inline `code` span that is itself a single name → the whole span links;
//  • inside a code block (a signature), each CamelCase type token (Vector, Float64, …) links.
function _linkifyDoc(root, r) {
  // When the page is a MODULE, its doc lists sibling exports as bare `names`; qualify them with
  // the module so the lookup resolves (the worker imports the head segment as a module).
  const isMod = r && (r.kind === 'module' || (r.exports && r.exports.length));
  const ctxMod = isMod ? (r.module && r.module !== r.name ? r.module + '.' + r.name : r.name) : '';
  const params = _sigParams(root);   // this doc's OWN parameter names — back-ticked in prose but not symbols
  // Documenter's ``[`name`](@ref)`` is the ecosystem's cross-reference syntax, and Base's own
  // docstrings are written in it. The href is a MARKER rather than a URL — Documenter resolves it at
  // build time against its own page set — so it is resolved here into a lookup instead, honouring the
  // `(@ref target)` form where the link text and the target differ.
  root.querySelectorAll('.docmd a[href^="@ref"]').forEach(a => {
    const target = a.getAttribute('href').slice(4).trim() || a.textContent.trim();
    if (!target) return;
    const link = document.createElement('a');
    link.className = 'doclink';
    link.dataset.name = (ctxMod && target.indexOf('.') < 0) ? ctxMod + '.' + target : target;
    link.innerHTML = a.innerHTML;                            // keep the `code` styling inside
    a.replaceWith(link);
  });
  root.querySelectorAll('.docmd code').forEach(c => {
    if (c.closest('.doclink')) return;                       // already a cross-reference (an `@ref`)
    if (c.closest('pre')) { _linkifyCode(c); return; }       // signature / fenced block → bare type tokens
    const t = c.textContent.trim();
    if (t.length > 1 && _IDENT_RE.test(t) && !_NOLINK.has(t) && !params.has(t)) {
      const a = document.createElement('a'); a.className = 'doclink';
      a.dataset.name = (ctxMod && t.indexOf('.') < 0) ? ctxMod + '.' + t : t;   // qualify a sibling under the module
      a.textContent = c.textContent;
      c.replaceWith(a);
    }
  });
}
// A function docstring's leading signature block lists its own parameters (`inbound`, `head`, `target`,
// …). Those get back-ticked throughout the prose but aren't referenceable symbols, so linking them makes
// dead "not found" refs (and clutters the Referenced rail). Collect them from the first signature block so
// _linkifyDoc can skip them — real referenced symbols (types, other functions) still link.
function _sigParams(root) {
  const params = new Set();
  const pre = root.querySelector('.docmd pre code');
  if (!pre) return params;
  const m = pre.textContent.match(/\(([\s\S]*)\)/);          // the arg list (positional; kwargs after ;)
  if (m) for (const seg of m[1].split(/[,;]/)) {
    const nm = seg.trim().match(/^[A-Za-z_][A-Za-z0-9_!]*/);
    if (nm) params.add(nm[0]);
  }
  return params;
}
// CommonMark code blocks are plain text → safe to re-emit as escaped HTML with CamelCase
// type tokens wrapped as links (e.g. `-> Vector{Float64}` → Vector and Float64 clickable).
function _linkifyCode(el) {
  const TYPE = /[A-Z][A-Za-z0-9_]+/g, esc = s => window.slateEscHtml(s);
  const txt = el.textContent; let out = '', last = 0, m;
  while ((m = TYPE.exec(txt))) {
    out += esc(txt.slice(last, m.index));
    out += _NOLINK.has(m[0]) ? esc(m[0]) : `<a class="doclink" data-name="${esc(m[0])}">${esc(m[0])}</a>`;
    last = m.index + m[0].length;
  }
  out += esc(txt.slice(last));
  el.innerHTML = out;
}
// Drill into a name (clicked ref or export) → a new history page. Unresolvable names get a
// navigable "not found" page rather than hijacking the search.
async function helpLookup(name) {
  let hr;
  try { hr = await api('GET', '/api/help?name=' + encodeURIComponent(name)); } catch (_) { return; }
  if (!hr || !hr.name) return;
  const v = _view() || { q: '', results: [], sel: 0 };
  // "No docstring" and "no such binding" are different answers and must read differently. A name the
  // kernel RESOLVED reports a kind and a module, so it is documented-or-not; only a name that failed
  // to resolve is a question about the environment.
  const resolved = hr.kind && hr.kind !== 'unknown';
  const rec = (!hr.docHtml && !(hr.exports && hr.exports.length) && !resolved)
    ? { name, module: '', kind: 'unknown', exports: [], _enriched: true,
        docHtml: `<div class="dim">No binding named <code>${_escc(name)}</code> in this notebook — check the spelling, or whether its package is loaded here.</div>` }
    : { module: hr.module || hr.name, name: _bareName(hr.module, hr.name), doc: hr.doc, docHtml: hr.docHtml, exports: hr.exports || [], kind: hr.kind, _enriched: true };
  _go({ q: v.q || '', results: v.results || [], sel: v.sel || 0, rec });
}
// Insert the bare name at the selected cell's cursor, else copy the qualified name.
function _docPick() {
  const v = _view(), r = v && (v.rec || (v.results && v.results[v.sel])); if (!r) return;
  const ed = editors[selectedId];
  if (ed) { edInsert(selectedId, r.name.replace(/^.*\./, '')); minimizeDocs(); }
  else if (navigator.clipboard) { navigator.clipboard.writeText((r.module ? r.module + '.' : '') + r.name); }
}
// List: click selects; double-click inserts.
document.getElementById('doclist').addEventListener('mousedown', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) { e.preventDefault(); _select(+li.dataset.i); document.getElementById('docin').focus(); } });
document.getElementById('doclist').addEventListener('dblclick', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) { _select(+li.dataset.i); _docPick(); } });
// Detail: drill into an export chip or a doc link (signature type / inline ref). Also
// neutralize REAL markdown links rendered inside a docstring — a relative href would
// otherwise navigate to /n/<garbage> → 302 → the index, kicking you out of the notebook.
document.getElementById('docdetail').addEventListener('click', e => {
  const t = e.target.closest('.docexport, .doclink');
  if (t && t.dataset.name) { e.preventDefault(); helpLookup(t.dataset.name); return; }
  const a = e.target.closest('a[href]');
  if (a) { e.preventDefault(); const h = a.getAttribute('href') || '';
    if (/^https?:\/\//i.test(h)) window.open(h, '_blank', 'noopener'); }   // external → new tab; relative/@ref → ignore
});
// Related-items rail: a chip drills into that name.
document.getElementById('docrelated').addEventListener('click', e => { const c = e.target.closest('.relchip'); if (c && c.dataset.name) helpLookup(c.dataset.name); });
// Auto-search as you type, DEBOUNCED 500ms — the docs search is an expensive embedding+FTS query,
// so we coalesce keystrokes rather than fire per-character. Enter still works: it forces an
// immediate search on a new query, or opens the selected result once the query has been searched.
let _docDebounce = null, _docSugDebounce = null;
// The same typing pause the cell editor's popup uses (Settings → Editing, `slateCompleteDelay`,
// default 250ms). Read per keystroke so the slider applies without a reload, and deliberately NOT
// the 500ms search debounce above: suggesting a name is a cheap lookup, running the semantic search
// is not, so they settle at different speeds.
const _docCompleteDelay = () => { const n = parseInt(localStorage.getItem('slateCompleteDelay'), 10); return Number.isFinite(n) ? n : 250; };
document.getElementById('docin').addEventListener('input', () => {
  clearTimeout(_docDebounce); clearTimeout(_docSugDebounce);
  _docSugDebounce = setTimeout(_docSuggest, _docCompleteDelay());
  _docDebounce = setTimeout(() => {
    const q = document.getElementById('docin').value.trim();
    if (q && q !== _docLastQ) _runDocSearch();   // new query settled → search
  }, 500);
});

// ── Name completion for the search box ───────────────────────────────────────────────────────────
// Searching docs means knowing the name, which is the thing you came here to find out. Two sources,
// because they answer different halves: `/complete` resolves where the kernel's bindings live (what
// this notebook has actually loaded, including its own definitions), and `/pkg-complete` matches
// installable + stdlib names (so `Linea` finds LinearAlgebra before anything has loaded it).
//
// `/pkg-complete` is NOT on a workbook's route allowlist (server_app.jl), and rightly so — a reader
// there cannot install anything, and offering a package whose docs `/help` then can't produce is a
// dead end. So an app asks only the first source.
//
// Keys are only taken while the list is OPEN. Closed, Tab keeps moving between the panel's controls
// and the arrows keep driving the results list, so a reader who never wants names never notices this.
let _docCands = [], _docSelIdx = -1;
const _docsug = () => document.getElementById('docsug');
function _docHideSug() { _docCands = []; _docSelIdx = -1; const d = _docsug(); if (d) d.style.display = 'none'; }
function _docPaintSug() {
  const d = _docsug(); if (!d) return;
  if (!_docCands.length) { _docHideSug(); return; }
  d.innerHTML = _docCands.map((c, i) =>
    `<div class="${i === _docSelIdx ? 'on' : ''}" data-i="${i}">` +
    `<span>${_escc(c.text)}</span><span class="dsk">${_escc(c.kind)}</span></div>`).join('');
  d.style.display = 'block';
  const on = d.children[_docSelIdx]; if (on) on.scrollIntoView({ block: 'nearest' });
}
// The token being completed: the trailing dotted identifier.
function _docToken(q) {
  const m = /([A-Za-z_][A-Za-z0-9_!]*(?:\.[A-Za-z_][A-Za-z0-9_!]*)*\.?)$/.exec(q);
  return m ? m[1] : '';
}
// Names are only suggested when the WHOLE query is a name lookup — one identifier, possibly dotted.
// This box has two jobs, and the other one is semantic prose search ("draw a heatmap"), whose last
// word is identifier-shaped too. Suggesting there would put a highlighted name under Enter and
// answer a question nobody asked, and would take the arrow keys away from the results list while
// someone is reading it. A name query has neither problem, which is what makes autoselect safe.
const _docNameQuery = q => _IDENT_RE.test(q) || /^[A-Za-z_][A-Za-z0-9_!]*(\.[A-Za-z_][A-Za-z0-9_!]*)*\.$/.test(q);
let _docSugSeq = 0;
async function _docSuggest() {
  const inp = document.getElementById('docin'), q = inp.value.trim();
  const tok = _docToken(q);
  if (tok.length < 2 || !_docNameQuery(q)) { _docHideSug(); return; }
  const seq = ++_docSugSeq;
  const seen = new Set(), out = [];
  const add = (text, kind) => { if (text && !seen.has(text)) { seen.add(text); out.push({ text, kind }); } };
  try {
    const r = await api('POST', '/api/complete', { code: tok, pos: tok.length });
    for (const c of ((r && r.completions) || []).slice(0, 40)) add(c.text, c.kind || 'name');
  } catch (_) {}
  if (!(window.__SLATE_APP__ && window.__SLATE_APP__.on)) {
    const bare = tok.indexOf('.') < 0 ? tok : '';       // a package name is never dotted
    if (bare) {
      try {
        const p = await api('GET', '/api/pkg-complete?q=' + encodeURIComponent(bare));
        for (const n of ((p && p.names) || []).slice(0, 20)) add(n, 'package');
      } catch (_) {}
    }
  }
  if (seq !== _docSugSeq) return;                       // a later keystroke already answered
  // Top entry selected, so Enter commits it without a trip through the arrows. Safe because this
  // only runs for a name query (see `_docNameQuery`) — Enter had nothing else to mean here.
  _docCands = out.slice(0, 30); _docSelIdx = _docCands.length ? 0 : -1;
  _docPaintSug();
}
// Move the highlight by `dir`, wrapping. Shared by the arrows and by Tab in navigate-mode.
function _docMoveSug(dir) {
  const n = _docCands.length; if (!n) return;
  _docSelIdx = dir < 0 ? (_docSelIdx <= 0 ? n - 1 : _docSelIdx - 1)
                       : (_docSelIdx < 0 ? 0 : (_docSelIdx + 1) % n);
  _docPaintSug();
}
// Replace the completed token in place, so `Base.sin` completes its tail without losing the prefix.
// NOT `_docPick` — that name is taken by the results-list action above (insert the name into the
// selected cell). Two same-named function declarations in one scope silently keep the later one.
function _docSugAccept(i) {
  const c = _docCands[i]; if (!c) return;
  const inp = document.getElementById('docin'), q = inp.value, tok = _docToken(q);
  const head = tok ? q.slice(0, q.length - tok.length) : q;
  const dot = tok.lastIndexOf('.');
  inp.value = head + (dot >= 0 ? tok.slice(0, dot + 1) : '') + c.text;
  _docHideSug();
  inp.focus();
  // Both timers: a suggest still in flight would re-open the list over the name just committed, and
  // the search debounce is superseded by the immediate run below.
  clearTimeout(_docDebounce); clearTimeout(_docSugDebounce);
  _docSugSeq++;                                         // and disown any request already awaiting
  _runDocSearch();                                      // a chosen name is a query worth answering now
}
_docsug().addEventListener('mousedown', e => {
  const d = e.target.closest('div[data-i]'); if (d) { e.preventDefault(); _docSugAccept(+d.dataset.i); }
});
document.getElementById('docin').addEventListener('blur', () => setTimeout(_docHideSug, 120));
document.getElementById('docin').addEventListener('keydown', e => {
  const v = _view(), sel = v ? v.sel : 0;
  const sugOpen = _docCands.length > 0;
  // While the name list is open it owns the keys: arrows move the highlight, Enter commits it, and
  // Escape dismisses the list — which hands the arrows back to the RESULTS list below.
  if (sugOpen && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
    e.preventDefault();
    _docMoveSug(e.key === 'ArrowUp' ? -1 : 1);
    return;
  }
  // Tab obeys `slateCompleteTab` (Settings → Editing), the same preference the cell editor's popup
  // reads — one answer to "what does Tab do in a completion list", not two that can disagree.
  if (sugOpen && e.key === 'Tab') {
    const nav = (localStorage.getItem('slateCompleteTab') || 'accept') === 'navigate';
    if (!nav && !e.shiftKey) { e.preventDefault(); _docSugAccept(_docSelIdx < 0 ? 0 : _docSelIdx); return; }
    if (nav) { e.preventDefault(); _docMoveSug(e.shiftKey ? -1 : 1); return; }
    // accept-mode Shift-Tab: nothing to accept backwards, so let it leave the field as usual.
  }
  // (Escape never reaches here: the dock's capture-phase listener handles it, and closes the name
  // list before the dock.)
  if (e.key === 'ArrowDown') { e.preventDefault(); _select(sel + 1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); _select(sel - 1); }
  else if (e.key === 'Enter') {
    e.preventDefault();
    if (sugOpen && _docSelIdx >= 0) { _docSugAccept(_docSelIdx); return; }   // commit the highlighted name
    clearTimeout(_docDebounce);                  // pre-empt the pending debounced search
    const q = document.getElementById('docin').value.trim();
    if (q && q !== _docLastQ) { _runDocSearch(); return; }   // new query → search
    // Already searched: OPEN the selected result (drill into its docs). Enter must never paste into
    // the editor — double-click a result for that. (Now that search runs as-you-type, Enter would
    // otherwise hit the old insert path immediately.)
    const r = v && (v.rec || (v.results && v.results[v.sel]));
    if (r) helpLookup(_lookupName(r));
  }
});
// Esc anywhere in the open dock closes it (minimizes) — users expect Escape to dismiss the popup,
// not walk history. Back/forward stay on the ‹ › nav buttons.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !_docMin) {
    e.preventDefault(); e.stopPropagation();
    // Innermost first. The name list is a popup INSIDE the dock, and this listener is on `document`
    // in the CAPTURE phase — it sees Escape before the search box does, so dismissing the list has
    // to happen here or not at all. One press closes the list, a second closes the dock.
    if (_docCands.length) { _docHideSug(); return; }
    minimizeDocs();
  }
}, true);
_restoreDocs();

// The global ⌘/Ctrl shortcuts that used to be a hand-written if/else ladder here are registry
// commands now (commands.js, `ctx: ['global']`), dispatched by keymap.js. The one behaviour worth
// recording: ⌘⇧K needed a `window.__docsHotkey` timestamp to spot the editor's own binding firing for
// the same keypress, with a 250ms window in which the right answer depended on handler timing. The
// keymap resolves it structurally — an event from inside `.cm-editor` skips any command CodeMirror
// also owns — so both the flag and the race are gone.

