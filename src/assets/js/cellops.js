async function runCell(id) {
  if (_hydrating) return;                      // env still reconstructing — preview is read-only
  const ed = editors[id];
  const before = _cellById(id);                // shape BEFORE the run (from the live state)
  setState(id, 'running');
  const state = await api('POST', '/api/cell/' + id, { source: ed ? ed.getValue() : '' });
  const after = (state.cells || []).find(c => c.id === id);
  // A code cell that gains (or loses) @bind widgets — or flips kind — changes its DOM
  // *structure*: the in-place patch (updateStates) can't inject the widget rows, so the
  // controls wouldn't appear. Rebuild fully in that case; otherwise patch in place.
  if (before && after && (hasBinds(before) !== hasBinds(after) || before.kind !== after.kind))
    renderAll(state);
  else
    updateStates(state);
}
async function addCell(after, kind, before, edit) {
  if (_hydrating) return;
  const oldIds = new Set(cellIds());
  const state = await api('POST', '/api/cell-add', { after, kind, before: !!before });
  renderAll(state);
  const neu = (state.cells || []).map(c => c.id).find(id => !oldIds.has(id));
  // renderAll restores the prior scroll on the next frame, so scroll to the new
  // cell a frame later (otherwise the restore wins and it doesn't move).
  // `nearest` jams a bottom-added cell against the viewport edge; nudge it up so a
  // small gap stays below it (the .page bottom padding gives the room to scroll).
  if (neu) requestAnimationFrame(() => requestAnimationFrame(() => {
    selectCell(neu, false);
    if (edit) enterEdit(neu);
    const el = document.getElementById('cell-' + neu);
    if (el) {
      el.scrollIntoView({ block: 'nearest' });
      const gap = 90, overflow = el.getBoundingClientRect().bottom - (window.innerHeight - gap);
      if (overflow > 0) window.scrollBy({ top: overflow, behavior: 'smooth' });
    }
  }));
  return neu;
}
// ⌘/Ctrl-⇧-Enter in edit mode: run (or commit) the cell, then open a fresh code
// cell below and drop into it — the keyboard-driven "next cell" flow.
async function runAndAddBelow(id)    { await runCell(id);       await addCell(id, 'code', false, true); }
async function commitAndAddBelow(id) { await commitSource(id);  await addCell(id, 'code', false, true); }
// Right-click on a ＋ add button → a tiny code/markdown chooser at the cursor.
function addMenu(e, cellId) {
  const m = document.getElementById('addmenu');
  m.innerHTML = '';
  [['code', '＋ code below'], ['md', '＋ markdown below']].forEach(([k, label]) => {
    const b = document.createElement('button'); b.textContent = label;
    b.onclick = () => { hideAddMenu(); addCell(cellId, k); }; m.appendChild(b);
  });
  m.style.left = Math.min(e.clientX, window.innerWidth - 180) + 'px';
  m.style.top = Math.min(e.clientY, window.innerHeight - 80) + 'px';
  m.classList.add('show');
}
function hideAddMenu() { document.getElementById('addmenu').classList.remove('show'); }
document.addEventListener('mousedown', e => { if (!e.target.closest('#addmenu') && !e.target.closest('.addbtn')) hideAddMenu(); });
document.addEventListener('mousedown', e => { if (!e.target.closest('#ctlpop') && !e.target.closest('.autoctl')) hideControlPicker(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') hideControlPicker(); });
// Split a code cell at the editor cursor into two cells.
async function splitCell(id, cm) {
  const idx = cm.indexFromPos(cm.getCursor()), val = cm.getValue();
  renderAll(await api('POST', '/api/cell-split/' + id, { before: val.slice(0, idx), after: val.slice(idx) }));
}
// Merge a cell with the one below it (same kind only); sends current editor text.
async function mergeBelow(id) {
  const ids = cellIds(), i = ids.indexOf(id);
  if (i < 0 || i >= ids.length - 1) return;
  const a = _cellById(id), b = _cellById(ids[i + 1]);
  if (!a || !b || a.kind !== b.kind || hasBinds(a) || hasBinds(b)) return;
  const sa = editors[id] ? editors[id].getValue() : (srcMap[id] || '');
  const sb = editors[ids[i + 1]] ? editors[ids[i + 1]].getValue() : (srcMap[ids[i + 1]] || '');
  renderAll(await api('POST', '/api/cell-merge/' + id, { source: sa.replace(/\s+$/, '') + '\n' + sb.replace(/^\s+/, '') }));
  selectCell(id, true);
}
async function delCell(id) {
  const idx = cellIds().indexOf(id);
  renderAll(await api('POST', '/api/cell-delete/' + id));
  const after = cellIds();
  // Select the PREVIOUS cell (idx-1), not the one that shifted up into the gap; clamp so
  // deleting the first cell falls back to the new first. selectCell scrolls it into view.
  after.length ? selectCell(after[Math.min(Math.max(0, idx - 1), after.length - 1)], true) : (selectedId = null);
}
async function moveCell(id, dir)     { renderAll(await api('POST', '/api/cell-move/' + id, { dir })); }
// ── Upstream-dependency navigation (🔗) ───────────────────────────────────────
// Light up a cell's transitive upstream cone — every precursor cell whose code it
// (transitively) reads from, computed client-side from each cell's `deps` (shipped in
// state_json). Lets you SEE what feeds a cell and click a precursor to jump to it.
let _depFocus = null;
function clearDeps() { window.slateStore && window.slateStore.setFocus(null); }
function _upstreamCone(id) {
  const byId = {}; ((nbState && nbState.cells) || []).forEach(c => byId[c.id] = c);
  const up = new Set(), stack = [id];
  while (stack.length) {
    const c = byId[stack.pop()]; if (!c) continue;
    for (const d of (c.deps || [])) { if (d === id || up.has(d)) continue; up.add(d); stack.push(d); }
  }
  return up;
}
// Transitive @bind controls a cell is affected by: not just the ones it reads directly
// (server-computed `binduses` = reads ∩ bound vars), but any whose value flows into it
// through the dependency graph — e.g. a plot of `data` where `data = f(N)` and `N` is an
// @bind. Union each upstream cell's direct binduses over the cell's dependency cone, so a
// control can be surfaced on a downstream plot even though the plot never names it.
function transBinduses(c) {
  if (!c) return [];
  const own = new Set((c.binds || []).map(b => b.name));
  const acc = new Set((c.binduses || []).filter(n => !own.has(n)));
  for (const up of _upstreamCone(c.id)) {
    const u = _cellById(up);
    ((u && u.binduses) || []).forEach(n => { if (!own.has(n)) acc.add(n); });
  }
  return [...acc].sort();
}
function _depFlag(el, text, title) {
  const f = document.createElement('span'); f.className = 'depflag';
  f.textContent = text; if (title) f.title = title; f.onclick = clearDeps; el.appendChild(f);
}
// 🔗 → dep-focus: render ONLY this cell's dependency chain (precursors + itself + dependents);
// click again (or Esc) to return to the full notebook. Filtering lives in the Preact <Notebook>.
function toggleDeps(id) { window.slateStore && window.slateStore.setFocus(id); }
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && window.slateStore && window.slateStore.focus.value) window.slateStore.setFocus(null);
});
async function moveCellRel(id, target, before) { renderAll(await api('POST', '/api/cell-move/' + id, { target, before })); }
async function toggleType(id, kind)  { renderAll(await api('POST', '/api/cell-type/' + id, { kind })); }
async function undoNb() { renderAll(await api('POST', '/api/undo')); }
async function redoNb() { renderAll(await api('POST', '/api/redo')); }
