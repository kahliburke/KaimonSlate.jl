// `force` (the ▶ play button) re-evaluates even when the source is unchanged. Shift-Enter and
// the keyboard/palette flow leave it false: a clean cell isn't re-run (just commits any edit +
// advances), so stepping through a notebook doesn't redundantly recompute expensive cells.
async function runCell(id, force = false) {
  const before = _cellById(id);                // shape BEFORE the run (from the live state)
  // An ERRORED cell always re-runs on an explicit run (⇧⏎ / palette), even with unchanged source —
  // the whole point is to retry it. A clean cell with unchanged source is still skipped (advance-only).
  if (!force && before && before.state === 'errored') force = true;
  setState(id, 'running');
  const state = await api('POST', '/api/cell/' + id, { source: editors[id] ? edText(id) : (srcMap[id] || ''), force: !!force });
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
  const oldIds = new Set(cellIds());
  const state = await api('POST', '/api/cell-add', { after, kind, before: !!before });
  renderAll(state);
  const neu = (state.cells || []).map(c => c.id).find(id => !oldIds.has(id));
  // renderAll restores the prior scroll on the next frame, so scroll to the new cell a frame
  // later (otherwise the restore wins). Center it in the viewport — but if it's near the top of
  // the document (can't center without scrolling past the top), just bring it to the top.
  if (neu) requestAnimationFrame(() => requestAnimationFrame(() => {
    selectCell(neu, false);
    if (edit) enterEdit(neu);
    const el = document.getElementById('cell-' + neu);
    if (el) {
      const r = el.getBoundingClientRect();
      const block = (r.height >= window.innerHeight * 0.9) ? 'start'   // taller than the viewport → top
                  : (window.scrollY + r.top < window.innerHeight / 2) ? 'start'   // near doc top → top
                  : 'center';
      el.scrollIntoView({ block, behavior: 'smooth' });
    }
  }));
  return neu;
}
// ⌘/Ctrl-⇧-Enter in edit mode: run (or commit) the cell, then open a fresh code
// cell below and drop into it — the keyboard-driven "next cell" flow.
async function runAndAddBelow(id)    { await runCell(id);       await addCell(id, 'code', false, true); }
async function commitAndAddBelow(id) { await commitSource(id);  await addCell(id, 'code', false, true); }
// Right-click on a ＋ add button → a tiny code/markdown chooser at the cursor. `before` inserts
// ABOVE the reference cell (the top inter-cell gap) instead of below it (the default).
function addMenu(e, cellId, before = false) {
  const m = document.getElementById('addmenu');
  m.innerHTML = '';
  const where = before ? 'above' : 'below';
  [['code', '＋ code ' + where], ['md', '＋ markdown ' + where], ['web', '＋ web widget ' + where]].forEach(([k, label]) => {
    const b = document.createElement('button'); b.textContent = label;
    b.onclick = () => { hideAddMenu(); addCell(cellId, k, before); }; m.appendChild(b);
  });
  m.style.left = Math.min(e.clientX, window.innerWidth - 180) + 'px';
  m.style.top = Math.min(e.clientY, window.innerHeight - 80) + 'px';
  m.classList.add('show');
}
function hideAddMenu() { document.getElementById('addmenu').classList.remove('show'); }
document.addEventListener('mousedown', e => { if (!e.target.closest('#addmenu') && !e.target.closest('.cellgap-add')) hideAddMenu(); });
document.addEventListener('mousedown', e => { if (!e.target.closest('#ctlpop') && !e.target.closest('.autoctl')) hideControlPicker(); });
document.addEventListener('keydown', e => { if (e.key === 'Escape') hideControlPicker(); });
// Split a code cell at the editor cursor into two cells.
async function splitCell(id, view) {
  const v = view || editors[id]; if (!v) return;
  const idx = v.state.selection.main.head, val = v.state.doc.toString();
  renderAll(await api('POST', '/api/cell-split/' + id, { before: val.slice(0, idx), after: val.slice(idx) }));
}
// Merge a cell with the one below it (same kind only); sends current editor text.
// @bind cells ARE mergeable: a cell may hold several @bind statements (they render a combined
// control strip), so consolidating side-by-side control cells into one is exactly the point.
// The server re-analyzes the merged source, so multiple binds are picked up automatically.
async function mergeBelow(id) {
  const ids = cellIds(), i = ids.indexOf(id);
  if (i < 0 || i >= ids.length - 1) return;
  const a = _cellById(id), b = _cellById(ids[i + 1]);
  if (!a || !b || a.kind !== b.kind) return;
  const sa = editors[id] ? edText(id) : (srcMap[id] || '');
  const sb = editors[ids[i + 1]] ? edText(ids[i + 1]) : (srcMap[ids[i + 1]] || '');
  renderAll(await api('POST', '/api/cell-merge/' + id, { source: sa.replace(/\s+$/, '') + '\n' + sb.replace(/^\s+/, '') }));
  selectCell(id, true);
}
// A single cell is named by its id in toasts/labels; multiples are counted ("3 cells").
function _idsLabel(ids) { return ids.length === 1 ? ids[0] : ids.length + ' cells'; }
async function delCell(id) {
  const sel = selectedIds();
  if (sel.length > 1) return delCells(sel);            // multi-selection → delete them all (one undo step)
  const idx = cellIds().indexOf(id);
  renderAll(await api('POST', '/api/cell-delete/' + id));
  const after = cellIds();
  // Select the PREVIOUS cell (idx-1), not the one that shifted up into the gap; clamp so
  // deleting the first cell falls back to the new first. selectCell scrolls it into view.
  after.length ? selectCell(after[Math.min(Math.max(0, idx - 1), after.length - 1)], true) : selectCell(null);
  toast('Deleted ' + id, 2000);
}
// Delete several cells atomically (multi-select dd / cut). Selects the cell before the first
// removed. `verb` ("delete"/"cut") labels the undo entry so it reads "Undo cut 2 cells". A plain
// delete toasts here; a cut stays silent (cutCells fires its own "cut" toast).
async function delCells(ids, verb) {
  const all = cellIds();
  const firstIdx = Math.min(...ids.map(i => all.indexOf(i)).filter(i => i >= 0));
  renderAll(await api('POST', '/api/cells-delete', { ids, verb: verb || 'delete' }));
  const after = cellIds();
  after.length ? selectCell(after[Math.min(Math.max(0, firstIdx - 1), after.length - 1)], true) : selectCell(null);
  if (verb !== 'cut') toast('Deleted ' + _idsLabel(ids), 2000);
}
async function moveCell(id, dir)     { renderAll(await api('POST', '/api/cell-move/' + id, { dir })); }
// ── Upstream-dependency navigation (🔗) ───────────────────────────────────────
// Light up a cell's transitive upstream cone — every precursor cell whose code it
// (transitively) reads from, computed client-side from each cell's `deps` (shipped in
// state_json). Lets you SEE what feeds a cell and click a precursor to jump to it.
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
// Does this cell render a result (plot/value/table/echart) that controls can pair with?
const _hasResult = c => !!(c && (c.output || (c.echarts && c.echarts.length) || (c.tables && c.tables.length)));
// Names a cell can surface into its control strip: its OWN @bind vars FIRST (only when the cell
// also shows a result — so a mixed plot+@bind cell can fold its own widget into the same strip as
// the external controls; a pure @bind cell stays as-is), then the transitively-affecting external
// binds. This is the picker's/🎛's source list — own + external in one arrangeable strip.
function surfaceableNames(c) {
  if (!c) return [];
  const own = _hasResult(c) ? (c.binds || []).map(b => b.name) : [];
  const ext = transBinduses(c).filter(n => !own.includes(n));
  return [...own, ...ext];
}
// Every @bind control declared anywhere in the notebook (unique, notebook order).
function allBindNames() {
  const seen = new Set(), out = [];
  ((nbState && nbState.cells) || []).forEach(c => (c.binds || []).forEach(b => {
    if (!seen.has(b.name)) { seen.add(b.name); out.push(b.name); }
  }));
  return out;
}
// What the 🎛 picker offers a cell: the controls AFFECTING it first (own + transitively-read),
// then every OTHER @bind in the notebook — so you can dock any control (incl. one just created),
// consistent with drag-from-palette. `all` is the full controllable set (for the apply step).
function pickerNames(c) {
  const aff = surfaceableNames(c), affSet = new Set(aff);
  const other = allBindNames().filter(n => !affSet.has(n));
  return { aff, other, all: [...aff, ...other] };
}
// 🔗 → dep-focus: render ONLY this cell's dependency chain (precursors + itself + dependents);
// click again (or Esc) to return to the full notebook. Filtering lives in the Preact <Notebook>.
function toggleDeps(id) { window.slateStore && window.slateStore.setFocus(id); }
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && window.slateStore && window.slateStore.focus.value) window.slateStore.setFocus(null);
});
async function moveCellRel(id, target, before) { renderAll(await api('POST', '/api/cell-move/' + id, { target, before })); }
async function toggleType(id, kind)  {
  // Carry the editor's CURRENT text along with the kind change, so converting (e.g. code→md after
  // Esc, which keeps the text in the editor but never commits it) preserves unsaved edits. Sent in
  // one request so the server converts WITHOUT evaluating — pressing m/y must not run the code yet.
  const body = { kind };
  if (window.editors[id]) body.source = edText(id);
  renderAll(await api('POST', '/api/cell-type/' + id, body));
}
async function undoNb() { const s = await api('POST', '/api/undo'); renderAll(s); if (s && s.undid) toast('Undid ' + s.undid, 2000); }
async function redoNb() { const s = await api('POST', '/api/redo'); renderAll(s); if (s && s.redid) toast('Redid ' + s.redid, 2000); }
// ── Cell clipboard: copy / cut / paste (command-mode c / x / v) ────────────────
// An internal clipboard of {kind, source} cells, mirrored to localStorage so you can copy
// cells in one notebook tab and paste them into another. The .jl source is ALSO written to the
// system clipboard (best-effort) so a copy can be pasted into an editor. Paste inserts below the
// active cell; the pasted cells land STALE (not auto-run) and become the new selection.
const CLIP_KEY = 'slateClipboard';
function _writeClip(cells) { try { localStorage.setItem(CLIP_KEY, JSON.stringify(cells)); } catch (e) {} }
function _readClip() { try { return JSON.parse(localStorage.getItem(CLIP_KEY) || 'null'); } catch (e) { return null; } }
function _cellsData(ids) {
  const want = new Set(ids);                           // preserve notebook order, take live editor text
  return ((nbState && nbState.cells) || []).filter(c => want.has(c.id)).map(c => ({
    kind: c.kind, source: editors[c.id] ? edText(c.id) : (srcMap[c.id] || c.source || '')
  }));
}
function copyCells(silent) {
  const ids = selectedIds(); if (!ids.length) return;
  const data = _cellsData(ids); _writeClip(data);
  try { navigator.clipboard && navigator.clipboard.writeText(data.map(c => c.source).join('\n\n')); } catch (e) {}
  if (!silent) toast(_idsLabel(ids) + ' copied', 2000);
}
async function cutCells() {
  const ids = selectedIds(); if (!ids.length) return;
  copyCells(true); await delCells(ids, 'cut');      // silent copy + silent delete — one "cut" toast
  toast(_idsLabel(ids) + ' cut', 2000);
}
async function pasteCells() {
  const clip = _readClip(); if (!clip || !clip.length) { toast('Clipboard is empty', 2000); return; }
  const after = selectedId || (cellIds().slice(-1)[0] || '');
  const oldIds = new Set(cellIds());
  const state = await api('POST', '/api/cells-paste', { after, cells: clip });
  renderAll(state);
  const neu = (state.cells || []).map(c => c.id).filter(id => !oldIds.has(id));
  if (neu.length) {
    selectedId = neu[neu.length - 1]; anchorId = neu[0];
    window.slateStore && window.slateStore.setSelection(neu, selectedId);
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const el = document.getElementById('cell-' + neu[0]); if (el) el.scrollIntoView({ block: 'nearest' });
    }));
  }
  toast((neu.length ? _idsLabel(neu) : clip.length + ' cell' + (clip.length === 1 ? '' : 's')) + ' pasted', 2000);
}
