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

// ── Docs search palette (⌘⇧K) — semantic search of the notebook's package docs ──
let _doc = [], _docSel = 0;
function openDocs() {
  document.getElementById('docbg').classList.add('show');
  const inp = document.getElementById('docin'); inp.value = ''; _doc = []; _docSel = 0;
  document.getElementById('doclist').innerHTML = '<li class="dochint">Describe an API in plain words — e.g. “draw a heatmap”, “group rows and aggregate”.</li>';
  inp.oninput = _docSearch; inp.focus();
}
function closeDocs() { document.getElementById('docbg').classList.remove('show'); }
const _docSearch = debounce(async () => {
  const q = document.getElementById('docin').value.trim();
  const ul = document.getElementById('doclist');
  if (!q) { ul.innerHTML = '<li class="dochint">Describe an API in plain words…</li>'; _doc = []; return; }
  ul.innerHTML = '<li class="dochint">Searching…</li>';
  let res = [];
  try { const r = await api('GET', '/api/docsearch?q=' + encodeURIComponent(q)); res = (r && r.results) || []; } catch (_) {}
  _doc = res; _docSel = 0; _renderDocs();
}, 200);
function _renderDocs() {
  const ul = document.getElementById('doclist');
  if (!_doc.length) { ul.innerHTML = '<li class="docempty">No matches — try different words.</li>'; document.getElementById('docdetail').innerHTML = ''; return; }
  ul.innerHTML = _doc.map((r, i) =>
    `<li class="${i === _docSel ? 'on' : ''}" data-i="${i}"><span class="docname">${_escc(r.module)}.<b>${_escc(r.name)}</b>` +
    `<span class="k">${(Number(r.score) || 0).toFixed(2)}</span></span></li>`).join('');
  _renderDetail();
}
// Full docstring of the highlighted result — the "show me the details" pane.
function _renderDetail() {
  const r = _doc[_docSel], d = document.getElementById('docdetail');
  if (!r) { d.innerHTML = ''; return; }
  d.innerHTML = `<h4>${_escc(r.module)}.${_escc(r.name)}</h4>` +
    `<pre>${_escc(String(r.doc || '').trim() || 'No docstring.')}</pre>` +
    `<div class="hint">↵ insert name · double-click a result · esc to close</div>`;
  d.scrollTop = 0;
}
function _paintDocs() {
  const ul = document.getElementById('doclist');
  [...ul.children].forEach((li, i) => li.classList.toggle('on', i === _docSel));
  const on = ul.children[_docSel]; if (on) on.scrollIntoView({ block: 'nearest' });
  _renderDetail();
}
// Pick a result → insert the bare name at the selected cell's cursor, else copy it.
function _docPick(i) {
  const r = _doc[i]; if (!r) return;
  closeDocs();
  const ed = editors[selectedId];
  if (ed) { ed.replaceSelection(r.name); ed.focus(); }
  else if (navigator.clipboard) { navigator.clipboard.writeText(r.module + '.' + r.name); }
}
// Click selects (shows the docstring); double-click / Enter inserts.
document.getElementById('doclist').addEventListener('mousedown', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) { e.preventDefault(); _docSel = +li.dataset.i; _paintDocs(); document.getElementById('docin').focus(); } });
document.getElementById('doclist').addEventListener('dblclick', e => { const li = e.target.closest('li'); if (li && li.dataset.i !== undefined) _docPick(+li.dataset.i); });
document.getElementById('docin').addEventListener('keydown', e => {
  if (e.key === 'ArrowDown') { e.preventDefault(); _docSel = Math.min(_docSel + 1, _doc.length - 1); _paintDocs(); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); _docSel = Math.max(_docSel - 1, 0); _paintDocs(); }
  else if (e.key === 'Enter') { e.preventDefault(); _docPick(_docSel); }
  else if (e.key === 'Escape') { e.preventDefault(); closeDocs(); }
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

