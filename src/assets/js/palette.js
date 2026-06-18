// ── @bind control snippets ────────────────────────────────────────────────────
// One-click insert of a reactive control. Drops the snippet into the selected code
// cell's editor at the cursor, else seeds a fresh code cell below — then the user
// renames the variable and runs it. Surfaced both in ⌘K and the ☰ menu.
const BIND_SNIPPETS = [
  ['Slider',      '@bind n Slider(1:100)'],
  ['NumberField', '@bind x NumberField(0)'],
  ['Toggle',      '@bind flag Toggle(false)'],
  ['Checkbox',    '@bind on Checkbox(false)'],
  ['TextField',   '@bind s TextField("")'],
  ['TextArea',    '@bind txt TextArea("")'],
  ['Select',      '@bind choice Select(["a", "b", "c"])'],
  ['Radio',       '@bind pick Radio(["a", "b", "c"])'],
  ['MultiSelect', '@bind picks MultiSelect(["a", "b", "c"])'],
  ['ColorPicker', '@bind col ColorPicker("#56d364")'],
  ['DateField',   '@bind d DateField()'],
  ['TimeField',   '@bind t TimeField()'],
  ['Button',      '@bind go Button("Run")'],
];
async function insertBind(snippet) {
  const ed = selectedId && editors[selectedId];
  if (ed) { const cur = ed.getValue(); ed.replaceSelection((cur.trim() ? '\n' : '') + snippet); ed.focus(); return; }
  const id = await addCell(selectedId || '', 'code', false, true);   // fresh cell below, in edit mode
  if (id && editors[id]) { editors[id].setValue(snippet); editors[id].focus(); }
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
    { label: 'Undo', key: '⌘Z', run: undoNb },
    { label: 'Redo', key: '⌘⇧Z', run: redoNb },
    { label: 'Add code cell below', key: 'b', run: () => addCell(sel || '', 'code') },
    { label: 'Add code cell above', key: 'a', run: () => addCell(sel || '', 'code', true) },
    { label: 'Add markdown cell', run: () => addCell(sel || '', 'md') },
    { label: 'Edit selected cell', key: '↵', run: () => { if (sel) enterEdit(sel); } },
    { label: 'Delete selected cell', key: 'd d', run: () => { if (sel) delCell(sel); } },
    { label: 'Move selected cell up', key: '⇧↑', run: () => { if (sel) moveCell(sel, 'up'); } },
    { label: 'Move selected cell down', key: '⇧↓', run: () => { if (sel) moveCell(sel, 'down'); } },
    { label: 'Convert selected to markdown', key: 'm', run: () => { if (sel) toggleType(sel, 'md'); } },
    { label: 'Convert selected to code', key: 'y', run: () => { if (sel) toggleType(sel, 'code'); } },
    { label: 'Merge selected cell with below', key: '⇧M', run: () => { if (sel) mergeBelow(sel); } },
    { label: 'Split selected cell at cursor', run: () => { if (sel && editors[sel]) splitCell(sel, editors[sel]); } },
    { label: 'Rebuild (fresh namespace)', run: resetAll },
    { label: 'Restart worker', run: restartWorker },
    { label: 'Reload from disk', run: reload },
    { label: 'Hide code for all plot cells', run: () => hideAllPlotCode(true) },
    { label: 'Show code for all plot cells', run: () => hideAllPlotCode(false) },
    ...BIND_SNIPPETS.map(([name, snip]) => ({ tag: '@bind', label: 'Insert @bind: ' + name, run: () => insertBind(snip) })),
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

// ── Docs / help palette (⌘⇧K) — semantic search + live `?name` help browser ──
// Semantic search of the notebook's package docs, PLUS a REPL-style help viewer: the
// detail pane renders the docstring as markdown, links its `refs`, and — for a module —
// lists its exports so you can drill into a package. Typing an exact name resolves it live.
let _doc = [], _docSel = 0;
let _helpStack = [];                 // drill-down nav within the detail pane (refs / exports)
const _IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_!]*)*$/;
const _NOLINK = new Set(['true','false','nothing','missing','end','function','for','while','if','x','i','n','a','b']);
function openDocs() {
  document.getElementById('docbg').classList.add('show');
  const inp = document.getElementById('docin'); inp.value = ''; _doc = []; _docSel = 0; _helpStack = [];
  document.getElementById('doclist').innerHTML = '<li class="dochint">Describe an API in plain words — e.g. “draw a heatmap” — or type an exact name / module (e.g. <code>LinearAlgebra</code>) to browse it.</li>';
  document.getElementById('docdetail').innerHTML = '';
  inp.oninput = _docSearch; inp.focus();
}
function closeDocs() { document.getElementById('docbg').classList.remove('show'); }
const _docSearch = debounce(async () => {
  const q = document.getElementById('docin').value.trim();
  const ul = document.getElementById('doclist');
  if (!q) { ul.innerHTML = '<li class="dochint">Describe an API in plain words…</li>'; _doc = []; _helpStack = []; document.getElementById('docdetail').innerHTML = ''; return; }
  ul.innerHTML = '<li class="dochint">Searching…</li>';
  let res = [];
  try { const r = await api('GET', '/api/docsearch?q=' + encodeURIComponent(q)); res = (r && r.results) || []; } catch (_) {}
  // Exact lookup: a single identifier / dotted path resolves live — handles `?Module`
  // (→ its exports) and exact names that semantic search ranks low. Pinned at the top.
  if (_IDENT_RE.test(q)) {
    try {
      const hr = await api('GET', '/api/help?name=' + encodeURIComponent(q));
      if (hr && hr.name && (hr.docHtml || (hr.exports && hr.exports.length) || hr.kind !== 'unknown')) {
        res = [{ module: hr.module || hr.name, name: hr.name, doc: hr.doc, docHtml: hr.docHtml,
                 exports: hr.exports || [], kind: hr.kind, exact: true, _enriched: true },
               ...res.filter(r => !(r.name === hr.name && (r.module || '') === (hr.module || '')))];
      }
    } catch (_) {}
  }
  _doc = res; _docSel = 0; _helpStack = []; _renderDocs();
}, 200);
function _renderDocs() {
  const ul = document.getElementById('doclist');
  if (!_doc.length) { ul.innerHTML = '<li class="docempty">No matches — try different words.</li>'; document.getElementById('docdetail').innerHTML = ''; return; }
  ul.innerHTML = _doc.map((r, i) => {
    const right = r.exact ? '<span class="k exact">exact</span>'
                          : `<span class="k">${(Number(r.score) || 0).toFixed(2)}</span>`;
    return `<li class="${i === _docSel ? 'on' : ''}" data-i="${i}"><span class="docname">${_escc(r.module)}.<b>${_escc(r.name)}</b>${right}</span></li>`;
  }).join('');
  _renderDetail();
}
// The detail pane: the active help record (a drill-down view if any, else the selected
// search result), rendered as markdown with clickable refs + (for a module) its exports.
function _renderDetail() {
  const r = _helpStack.length ? _helpStack[_helpStack.length - 1] : _doc[_docSel];
  const d = document.getElementById('docdetail');
  if (!r) { d.innerHTML = ''; return; }
  d.innerHTML = _helpRecordHtml(r, _helpStack.length > 0);
  _linkifyDoc(d);
  d.scrollTop = 0;
  r._enriched || _enrichDetail(r);             // upgrade with live exports/doc on first view
}
const _lookupName = r => (r.module && r.module !== r.name) ? r.module + '.' + r.name : r.name;
// Lazily upgrade a selected result with a LIVE help lookup — fills in a module's exports
// (the drill-down grid) and a fresh docstring, so ANY module/binding becomes browseable,
// not just an exactly-typed query. One lookup per record (cached on the record).
async function _enrichDetail(r) {
  if (r._enriched || !r.name) return;
  r._enriched = true;
  let hr;
  try { hr = await api('GET', '/api/help?name=' + encodeURIComponent(_lookupName(r))); } catch (_) { return; }
  if (!hr || !hr.name) return;
  if (hr.docHtml) r.docHtml = hr.docHtml;
  if (hr.exports && hr.exports.length) r.exports = hr.exports;
  if (hr.kind && hr.kind !== 'unknown') r.kind = hr.kind;
  if (_currentDoc() === r) _renderDetail();    // still showing this one → repaint with exports
}
function _helpRecordHtml(r, showBack) {
  const kind = r.kind && r.kind !== 'unknown' ? `<span class="dockind">${_escc(r.kind)}</span>` : '';
  const mod = r.module || '';
  let nm = r.name;
  if (mod && nm.startsWith(mod + '.')) nm = nm.slice(mod.length + 1);   // de-dup "Mod.Mod.x" on drill-in
  const title = (mod && mod !== nm) ? `${_escc(mod)}.<b>${_escc(nm)}</b>` : `<b>${_escc(nm)}</b>`;
  const back = showBack ? `<button class="docback" onclick="helpBack()" title="back">‹ back</button>` : '';
  const body = r.docHtml ? `<div class="docmd">${r.docHtml}</div>` : '<div class="docmd dim">No documentation found.</div>';
  let exports = '';
  if (r.exports && r.exports.length) {
    const base = r.module || r.name;
    exports = `<div class="docexports"><div class="docexhdr">Exports · ${r.exports.length}</div><div class="docexgrid">` +
      r.exports.map(e => `<button class="docexport kind-${_escc(e.kind)}" data-name="${_escc(base + '.' + e.name)}" title="${_escc(e.kind)} — click to open">${_escc(e.name)}</button>`).join('') +
      '</div></div>';
  }
  return `<div class="dochead">${back}<h4>${title}</h4>${kind}</div>${body}${exports}` +
    '<div class="hint">↵ insert name · click a <code>ref</code> or export to drill in · esc to close</div>';
}
// Make inline-code identifiers in a docstring clickable → look them up in place.
function _linkifyDoc(root) {
  root.querySelectorAll('.docmd code').forEach(c => {
    const t = c.textContent.trim();
    if (t.length > 1 && _IDENT_RE.test(t) && !_NOLINK.has(t)) {
      const a = document.createElement('a'); a.className = 'doclink'; a.textContent = c.textContent;
      a.onclick = () => helpLookup(t); c.replaceWith(a);
    }
  });
}
// Drill into a name (a clicked ref or export). Pushes onto the nav stack; if nothing
// useful resolves, fall back to a fresh semantic search on the bare name.
async function helpLookup(name) {
  let hr;
  try { hr = await api('GET', '/api/help?name=' + encodeURIComponent(name)); } catch (_) { return; }
  if (!hr || !hr.name) return;
  if (!hr.docHtml && !(hr.exports && hr.exports.length)) {
    const inp = document.getElementById('docin'); inp.value = name.replace(/^.*\./, ''); _helpStack = []; _docSearch(); return;
  }
  _helpStack.push({ module: hr.module || hr.name, name: hr.name, doc: hr.doc, docHtml: hr.docHtml, exports: hr.exports || [], kind: hr.kind, _enriched: true });
  _renderDetail();
}
function helpBack() { _helpStack.pop(); _renderDetail(); }
function _paintDocs() {
  const ul = document.getElementById('doclist');
  [...ul.children].forEach((li, i) => li.classList.toggle('on', i === _docSel));
  const on = ul.children[_docSel]; if (on) on.scrollIntoView({ block: 'nearest' });
  _helpStack = [];                   // selecting a list row resets any drill-down
  _renderDetail();
}
// The record currently shown (drill-down view, else the selected search result).
function _currentDoc() { return _helpStack.length ? _helpStack[_helpStack.length - 1] : _doc[_docSel]; }
// Insert the bare name at the selected cell's cursor, else copy the qualified name.
function _docPick() {
  const r = _currentDoc(); if (!r) return;
  closeDocs();
  const ed = editors[selectedId];
  if (ed) { ed.replaceSelection(r.name.replace(/^.*\./, '')); ed.focus(); }
  else if (navigator.clipboard) { navigator.clipboard.writeText((r.module ? r.module + '.' : '') + r.name); }
}
// Click selects (shows the docstring); double-click / Enter inserts.
document.getElementById('doclist').addEventListener('mousedown', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) { e.preventDefault(); _docSel = +li.dataset.i; _paintDocs(); document.getElementById('docin').focus(); } });
document.getElementById('doclist').addEventListener('dblclick', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) { _docSel = +li.dataset.i; _helpStack = []; _docPick(); } });
// Drill into an export chip in the detail pane.
document.getElementById('docdetail').addEventListener('click', e => { const ex = e.target.closest('.docexport'); if (ex) helpLookup(ex.dataset.name); });
document.getElementById('docin').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { e.preventDefault(); _docSel = Math.min(_docSel + 1, _doc.length - 1); _paintDocs(); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); _docSel = Math.max(_docSel - 1, 0); _paintDocs(); }
  else if (e.key === 'Enter') { e.preventDefault(); _docPick(); }
  else if (e.key === 'Escape') { e.preventDefault(); _helpStack.length ? helpBack() : closeDocs(); }
});
document.getElementById('docbg').addEventListener('mousedown', e => { if (e.target.id === 'docbg') closeDocs(); });

// Global ⌘/Ctrl shortcuts (work everywhere, including inside the editor — CodeMirror
// doesn't bind these). Mirrored in the command palette's shortcut hints.
document.addEventListener('keydown', e => {
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); e.shiftKey ? openDocs() : openPalette(); }
  else if (mod && e.key === 'Enter') { e.preventDefault(); runAll(); }                       // ⌘↵  run stale
  else if (mod && e.shiftKey && (e.key === 'a' || e.key === 'A')) { e.preventDefault(); toggleAgent(); }   // ⌘⇧A agent
  else if (mod && e.shiftKey && (e.key === 'f' || e.key === 'F')) { e.preventDefault(); togglePalette(); } // ⌘⇧F controls
});

