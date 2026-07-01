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
];
async function insertBind(snippet) {
  if (selectedId && editors[selectedId]) { const cur = edText(selectedId); edInsert(selectedId, (cur.trim() ? '\n' : '') + snippet); return; }
  const id = await addCell(selectedId || '', 'code', false, true);   // fresh cell below, in edit mode
  if (id && editors[id]) { edSetText(id, snippet); edFocus(id); }
  else if (!id) window.toast && window.toast('Still loading — try again in a moment', 3000);   // e.g. addCell no-ops while hydrating
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
  const id = await addCell(selectedId || '', 'code', false, true);   // fresh cell below, in edit mode
  if (id && editors[id]) { edSetText(id, code); edFocus(id); }
  else if (!id) window.toast && window.toast('Still loading — try again in a moment', 3000);   // e.g. addCell no-ops while hydrating
}

// ── Command palette (⌘K) ──────────────────────────────────────────────────────
function paletteCommands() {
  // `key` is the shortcut hint shown on the right of each row. Single-letter / ⇧-keys are
  // command-mode (a cell is selected and you're NOT editing it); ⌘-keys are global.
  const sel = selectedId;
  const cmds = [
    { label: 'Run stale cells', key: '⌘↵', run: runAll },
    { label: 'Command palette', key: '⌘K', run: openPalette },
    { label: 'Search docs…', key: '⌘⇧K', run: openDocs },
    { label: 'Toggle agent panel', key: '⌘⇧A', run: toggleAgent },
    { label: 'Toggle controls palette', key: '⌘⇧F', run: togglePalette },
    { label: 'Table of contents', key: '⌘⇧L', run: toggleTOC },
    { label: 'Undo', key: '⌘Z', run: undoNb },
    { label: 'Redo', key: '⌘⇧Z', run: redoNb },
    { label: 'Add code cell below', key: 'b', run: () => addCell(sel || '', 'code') },
    { label: 'Add code cell above', key: 'a', run: () => addCell(sel || '', 'code', true) },
    { label: 'Add markdown cell', run: () => addCell(sel || '', 'md') },
    { label: 'Edit selected cell', key: '↵', run: () => { if (sel) enterEdit(sel); } },
    { label: 'Run selected cell', key: '⇧↵', run: () => { if (sel) runCell(sel); } },
    { label: 'Delete selected cell(s)', key: 'd d', run: () => { if (sel) delCell(sel); } },
    { label: 'Copy selected cell(s)', key: 'c', run: () => { if (sel) copyCells(); } },
    { label: 'Cut selected cell(s)', key: 'x', run: () => { if (sel) cutCells(); } },
    { label: 'Paste cell(s)', key: 'v', run: () => pasteCells() },
    { label: 'Move selected cell up', key: '⌥↑', run: () => { if (sel) moveCell(sel, 'up'); } },
    { label: 'Move selected cell down', key: '⌥↓', run: () => { if (sel) moveCell(sel, 'down'); } },
    { label: 'Show dependency chain of selected', key: '🔗', run: () => { if (sel) toggleDeps(sel); } },
    { label: 'Convert selected to markdown', key: 'm', run: () => { if (sel) toggleType(sel, 'md'); } },
    { label: 'Convert selected to code', key: 'y', run: () => { if (sel) toggleType(sel, 'code'); } },
    { label: 'Merge selected cell with below', key: '⇧M', run: () => { if (sel) mergeBelow(sel); } },
    { label: 'Split selected cell at cursor', run: () => { if (sel && editors[sel]) splitCell(sel); } },
    { label: 'Rebuild (fresh namespace)', run: resetAll },
    { label: 'Restart worker', run: restartWorker },
    { label: 'Reload from disk', run: reload },
    { label: 'Hide code for all plot cells', run: () => hideAllPlotCode(true) },
    { label: 'Show code for all plot cells', run: () => hideAllPlotCode(false) },
    { label: 'Packages…', tag: 'panel', run: togglePackages },
    { label: 'Worker log', tag: 'panel', run: toggleLog },
    { label: 'History…', tag: 'panel', run: toggleHistory },
    { label: 'Present (slideshow)', tag: 'present', run: () => enterPresent() },
    { label: 'Open presenter window', tag: 'present', run: () => openPresenter() },
    { label: 'Export… (HTML · PDF · Markdown · standalone)', tag: 'export', run: () => openExport() },
    { label: 'Export PDF (slides)', tag: 'export', run: () => exportSlidesPdf() },
    ...BIND_SNIPPETS.map(([name, snip]) => ({ tag: '@bind', label: 'Insert @bind: ' + name, run: () => insertBind(snip) })),
    ...RECIPES.map(([name, code]) => ({ tag: 'recipe', label: 'Recipe: ' + name, run: () => insertRecipe(code) })),
    { label: 'Open notebook in VS Code', run: () => { const p = nbState && nbState.path; if (p) location.href = 'vscode://file' + p; } },
    { label: 'Open project in VS Code', run: () => { const d = nbState && (nbState.project || (nbState.path || '').replace(/\/[^\/]*$/, '')); if (d) location.href = 'vscode://file' + d; } },
    { label: 'Settings…', run: openSettings },
    { label: 'All notebooks', run: () => { location.href = '/'; } },
  ];
  cellIds().forEach(id => cmds.push({ tag: 'cell', label: 'Jump to cell: ' + id, run: () => selectCell(id, true) }));
  return cmds;
}
let _cmd = [], _cmdSel = 0;
const _escc = s => s.replace(/[&<>"]/g, x => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]));
function openPalette() {
  document.getElementById('cmdbg').classList.add('show');
  const inp = document.getElementById('cmdin'); inp.value = '';
  inp.oninput = () => renderPaletteList(inp.value);
  renderPaletteList(''); inp.focus();
}
function closePalette() { document.getElementById('cmdbg').classList.remove('show'); }
function renderPaletteList(filter) {
  const f = filter.trim().toLowerCase();
  _cmd = paletteCommands().filter(c => c.label.toLowerCase().includes(f));
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
function _cmdRun(i) { const c = _cmd[i]; closePalette(); if (c) c.run(); }
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
const _IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_!]*)*$/;
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
function _focusedEditorCM() {                       // whichever cell editor (EditorView) has focus, else null
  if (typeof editors === 'undefined') return null;
  for (const id in editors) { const v = editors[id]; if (v && v.hasFocus) return v; }
  return null;
}
// ⌘⇧K: help for the symbol under the cursor (refocus the cell on close), else toggle the dock.
// Exposed so the CM6 editor keymap can bind it — CM6's defaultKeymap otherwise eats ⌘⇧K (deleteLine).
function openDocsAtCursor() {
  const cm = _focusedEditorCM(), sym = cm ? _symbolAtCursor(cm) : '';
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
        if (hr && hr.name && (hr.docHtml || (hr.exports && hr.exports.length) || hr.kind !== 'unknown'))
          results = [{ module: hr.module || hr.name, name: hr.name, doc: hr.doc, docHtml: hr.docHtml,
                       exports: hr.exports || [], kind: hr.kind, exact: true, _enriched: true },
                     ...results.filter(r => !(r.name === hr.name && (r.module || '') === (hr.module || '')))];
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
  _linkifyDoc(dt, r); dt.scrollTop = 0;
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
// Make identifiers in a docstring clickable (drill-in via the #docdetail delegation):
//  • an inline `code` span that is itself a single name → the whole span links;
//  • inside a code block (a signature), each CamelCase type token (Vector, Float64, …) links.
function _linkifyDoc(root, r) {
  // When the page is a MODULE, its doc lists sibling exports as bare `names`; qualify them with
  // the module so the lookup resolves (the worker imports the head segment as a module).
  const isMod = r && (r.kind === 'module' || (r.exports && r.exports.length));
  const ctxMod = isMod ? (r.module && r.module !== r.name ? r.module + '.' + r.name : r.name) : '';
  root.querySelectorAll('.docmd code').forEach(c => {
    if (c.closest('pre')) { _linkifyCode(c); return; }       // signature / fenced block → bare type tokens
    const t = c.textContent.trim();
    if (t.length > 1 && _IDENT_RE.test(t) && !_NOLINK.has(t)) {
      const a = document.createElement('a'); a.className = 'doclink';
      a.dataset.name = (ctxMod && t.indexOf('.') < 0) ? ctxMod + '.' + t : t;   // qualify a sibling under the module
      a.textContent = c.textContent;
      c.replaceWith(a);
    }
  });
}
// CommonMark code blocks are plain text → safe to re-emit as escaped HTML with CamelCase
// type tokens wrapped as links (e.g. `-> Vector{Float64}` → Vector and Float64 clickable).
function _linkifyCode(el) {
  const TYPE = /[A-Z][A-Za-z0-9_]+/g, esc = s => s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
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
  const rec = (!hr.docHtml && !(hr.exports && hr.exports.length))
    ? { name, module: '', kind: 'unknown', exports: [], _enriched: true,
        docHtml: `<div class="dim">No documentation found for <code>${_escc(name)}</code> — it may not be loaded in this notebook's environment.</div>` }
    : { module: hr.module || hr.name, name: hr.name, doc: hr.doc, docHtml: hr.docHtml, exports: hr.exports || [], kind: hr.kind, _enriched: true };
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
let _docDebounce = null;
document.getElementById('docin').addEventListener('input', () => {
  clearTimeout(_docDebounce);
  _docDebounce = setTimeout(() => {
    const q = document.getElementById('docin').value.trim();
    if (q && q !== _docLastQ) _runDocSearch();   // new query settled → search
  }, 500);
});
document.getElementById('docin').addEventListener('keydown', e => {
  const v = _view(), sel = v ? v.sel : 0;
  if (e.key === 'ArrowDown') { e.preventDefault(); _select(sel + 1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); _select(sel - 1); }
  else if (e.key === 'Enter') {
    e.preventDefault();
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
  if (e.key === 'Escape' && !_docMin) { e.preventDefault(); e.stopPropagation(); minimizeDocs(); }
}, true);
_restoreDocs();

// Global ⌘/Ctrl shortcuts (work everywhere, including inside the editor — CodeMirror
// doesn't bind these). Mirrored in the command palette's shortcut hints.
document.addEventListener('keydown', e => {
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (e.key === 'k' || e.key === 'K')) {                          // ⌘K palette · ⌘⇧K docs
    if (e.shiftKey) {
      // ⌘⇧K: when a cell editor is focused, the editor's OWN Mod-Shift-k binding already handled this
      // (it opens the dock, which BLURS the editor — so a focus check here runs too late). That binding
      // stamps `__docsHotkey`; if it just fired (same keypress), bail so we don't call openDocsAtCursor a
      // second time and toggle the dock straight back shut. Outside an editor, we own the shortcut.
      if (window.__docsHotkey && Date.now() - window.__docsHotkey < 250) return;
      e.preventDefault();
      openDocsAtCursor();
    } else {
      e.preventDefault();
      openPalette();
    }
  }
  else if (mod && e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); runAll(); }         // ⌘↵  run stale (⌘⇧↵ is run+add-below, handled elsewhere)
  else if (mod && e.shiftKey && (e.key === 'a' || e.key === 'A')) { e.preventDefault(); toggleAgent(); }   // ⌘⇧A agent
  else if (mod && e.shiftKey && (e.key === 'f' || e.key === 'F')) { e.preventDefault(); togglePalette(); } // ⌘⇧F controls
  else if (mod && e.shiftKey && (e.key === 'l' || e.key === 'L')) { e.preventDefault(); toggleTOC(); }      // ⌘⇧L table of contents
  // ⌘⇧← / ⌘⇧→ : back/forward through selected-cell history — but ONLY outside an editor, where those
  // chords are text selection (select-to-line-start/end).
  else if (mod && e.shiftKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight') &&
           !(document.activeElement && document.activeElement.closest && document.activeElement.closest('.cm-editor, input, textarea'))) {
    e.preventDefault();
    (e.key === 'ArrowLeft' ? window.navBack : window.navFwd)?.();
  }
});

