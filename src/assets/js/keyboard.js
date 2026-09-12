// ── Command/edit mode + Jupyter-style keyboard shortcuts ──────────────────────
// Command mode: a cell is "selected" (PURPLE ring) and single keys act on it —
// j/k or ↑/↓ to move, a/b to insert above/below, dd to delete, m/y to set
// markdown/code, Enter to edit. Edit mode: focus inside the CodeMirror (TEAL
// ring + a ✎ chip in the header); Esc returns to command mode.
//
// Which mode you are in is STATE, not a class on the element: it lives in the
// store's `editing` signal and <Cell> folds it into the cell's class. The ring
// used to be poked onto the DOM here, so the first keystroke — which rewrites
// that class as the cell goes fresh → edited — silently erased it, and the
// chrome then showed command mode while the keyboard was still in the editor.
let selectedId = null, anchorId = null, _dPending = false, _dTimer = null;
// `selectedId` is a classic-script `let`, so it is NOT a property of `window` and an ES module
// island can't read it. Islands that need the selection (the Extensions gallery) call this.
window.slateSelectedId = () => selectedId || '';
const cellIds = () => ((nbState && nbState.cells) || []).map(c => c.id);
// The current selection as an ordered (notebook-order) id list; falls back to the active cell.
function selectedIds() {
  const s = window.slateStore && window.slateStore.selectedSet.value;
  if (!s || !s.size) return selectedId ? [selectedId] : [];
  return cellIds().filter(id => s.has(id));
}
// Single-select: clear to just `id` (also resets the range anchor here).
function selectCell(id, scroll) {
  selectedId = id; anchorId = id;
  window.slateStore && window.slateStore.setSelected(id);     // feed the Preact signals store
  window._navRecord && window._navRecord(id);                 // record in the back/forward nav history
  const el = id && document.getElementById('cell-' + id);
  if (el && scroll) el.scrollIntoView({ block: 'nearest' });
}
// Extend the selection from the fixed anchor to `id` (shift-click / shift-arrow). `id` becomes active.
function selectRangeTo(id, scroll) {
  const ids = cellIds();
  let a = ids.indexOf(anchorId); const b = ids.indexOf(id);
  if (b < 0) return;
  if (a < 0) { a = b; anchorId = id; }
  const [lo, hi] = a <= b ? [a, b] : [b, a];
  selectedId = id;
  window.slateStore && window.slateStore.setSelection(ids.slice(lo, hi + 1), id);
  const el = document.getElementById('cell-' + id);
  if (el && scroll) el.scrollIntoView({ block: 'nearest' });
}
// Toggle `id` in/out of the selection (⌘/ctrl-click); it becomes the active cell + new anchor.
function toggleSelect(id) {
  selectedId = id; anchorId = id;
  window.slateStore && window.slateStore.toggleInSelection(id);
}
// Clicking the empty page AROUND the cells clears the selection, and must NOT start editing.
//
// The `preventDefault` is what buys the second half: clicking a block that contains a
// `contenteditable` makes WebKit and Blink place the caret in the nearest editable text, which
// level with a line of code is that cell's editor — focusing it. Only the mousedown default does
// that, so this can't move to the click.
//
// Deliberately narrow: the target must BE a layout container, not something drawn on one, so a
// click on output text, a button or the editor is left alone.
function _isPageBackground(t) {
  return t === document.body ||
         (t instanceof Element && (t.id === 'nb' || t.classList.contains('page')));
}
document.addEventListener('mousedown', e => {
  if (e.button !== 0 || !_isPageBackground(e.target)) return;
  e.preventDefault();                       // the caret never goes looking for an editor
  const a = document.activeElement;          // leaving edit mode is the point, so give up focus
  if (a && a.closest && a.closest('.cm-editor')) a.blur();
  selectCell(null);
});
// Enter/leave EDIT mode for `id`. The mode lives in the store, not in a classList toggle: <Cell>
// owns the cell's `class` and rewrites it whenever its computed value changes, so a DOM-poked
// `.editing` disappeared on the first keystroke (fresh → edited) and the chrome then claimed you
// were in command mode while the keyboard was still in the editor.
function setEditing(id, on) {
  window.slateStore && window.slateStore.setEditingCell(id, on);
  if (on) selectCell(id);
}
// (a global `function` declaration in a classic script IS window.setEditing — notebook.js calls it there)
// Is this cell showing its raw-source overlay? (md / @bind cells render output by default.)
function _srcOpen(id) {
  const cell = document.getElementById('cell-' + id); if (!cell) return false;
  const sed = cell.querySelector('.srcedit');
  return !!(sed && sed.style.display !== 'none');
}
function enterEdit(id) {
  const c = _cellById(id); if (!c) return;
  // A web cell has an inline editor too (its first pane, registered in editors[id]), so Enter focuses it
  // like a code cell — not the markdown/source overlay.
  if ((c.kind === 'code' || c.kind === 'web' || c.kind === 'tool') && !hasBinds(c)) {
    const ed = window.ensureEditor ? window.ensureEditor(id) : editors[id];
    if (ed) ed.focus();
    // Enter means "edit this", so vim starts in insert (no-op when vim is off).
    window.slateVimEnterInsert && window.slateVimEnterInsert(id);
  }
  else editSource(id, c.kind === 'md' ? 'markdown' : 'julia');
}
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey) return;
  if (document.getElementById('modalbg').classList.contains('show')) return;
  const inField = e.target.closest('.cm-editor') || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
  if (inField) return;                                  // edit mode / typing → leave keys alone
  const ids = cellIds(); if (!ids.length) return;
  if (!selectedId || !ids.includes(selectedId)) {
    if (e.key === 'ArrowDown' || e.key === 'j' || e.key === 'Enter') { selectCell(ids[0], true); e.preventDefault(); }
    return;
  }
  const idx = ids.indexOf(selectedId), k = e.key;
  // Alt+↑/↓ MOVES the active cell (this was Shift+↑/↓ before multi-select claimed Shift).
  if (e.altKey) {
    if (k === 'ArrowUp')        { e.preventDefault(); moveCell(selectedId, 'up'); }
    else if (k === 'ArrowDown') { e.preventDefault(); moveCell(selectedId, 'down'); }
    return;                                             // ignore other Alt combos in command mode
  }
  // Shift+↑/↓ (or ⇧K/⇧J) EXTEND the selection from the anchor; plain keys navigate (single-select).
  // The shift branches must precede the plain arrows so the modifier wins.
  if (e.shiftKey && (k === 'ArrowUp' || k === 'K')) { e.preventDefault(); if (idx > 0) selectRangeTo(ids[idx - 1], true); }
  else if (e.shiftKey && (k === 'ArrowDown' || k === 'J')) { e.preventDefault(); if (idx < ids.length - 1) selectRangeTo(ids[idx + 1], true); }
  else if (k === 'Enter' && !e.shiftKey) { e.preventDefault(); enterEdit(selectedId); }   // ⇧⏎ is run, handled below
  // Escape in COMMAND mode, in order: collapse a raw-source overlay left open by the Escape that
  // brought you here, then collapse a multi-selection to the active cell. Closing the overlay goes
  // through toggleSource, so a changed source is COMMITTED rather than dropped — Escape never
  // destroys work.
  else if (k === 'Escape') {
    if (_srcOpen(selectedId)) { e.preventDefault(); const c = _cellById(selectedId); toggleSource(selectedId, c && c.kind === 'md' ? 'markdown' : 'julia'); }
    else if (selectedIds().length > 1) { e.preventDefault(); selectCell(selectedId); }
  }
  else if (k === 'ArrowDown' || k === 'j') { e.preventDefault(); if (idx < ids.length - 1) selectCell(ids[idx + 1], true); }
  else if (k === 'ArrowUp' || k === 'k') { e.preventDefault(); if (idx > 0) selectCell(ids[idx - 1], true); }
  else if (k === 'a') { e.preventDefault(); addCell(selectedId, 'code', true); }
  else if (k === 'b') { e.preventDefault(); addCell(selectedId, 'code', false); }
  else if (k === 'c') { e.preventDefault(); copyCells(); }              // copy selected cell(s)
  else if (k === 'x') { e.preventDefault(); cutCells(); }               // cut selected cell(s)
  else if (k === 'v') { e.preventDefault(); pasteCells(); }             // paste below the active cell
  else if (k === 'm') { e.preventDefault(); const c = _cellById(selectedId); if (c && c.kind !== 'md') toggleType(selectedId, 'md'); }
  else if (k === 'y') { e.preventDefault(); const c = _cellById(selectedId); if (c && c.kind !== 'code') toggleType(selectedId, 'code'); }
  else if (k === 'w') { e.preventDefault(); const c = _cellById(selectedId); if (c && c.kind !== 'web') toggleType(selectedId, 'web'); }   // convert to a web (HTML/CSS/JS) cell
  else if (k === 'M') { e.preventDefault(); mergeBelow(selectedId); }    // Shift-M: merge with cell below
  else if (k === 'd') { e.preventDefault();
    if (_dPending) { _dPending = false; clearTimeout(_dTimer); delCell(selectedId); }   // delCell deletes the whole selection
    else { _dPending = true; _dTimer = setTimeout(() => _dPending = false, 650); } }
});
// Run shortcuts in COMMAND mode (a cell is selected but not being edited) — mirror the
// in-editor keys: ⇧⏎ runs the cell and moves to the next; ⌘/Ctrl⇧⏎ runs and opens a fresh
// cell below. (In edit mode CodeMirror's extraKeys handle these, so we bail when in a field.)
// Only plain code cells have the always-on editor runCell reads; md/@bind cells just advance.
document.addEventListener('keydown', e => {
  if (e.key !== 'Enter' || !e.shiftKey || e.altKey) return;
  if (document.getElementById('modalbg').classList.contains('show')) return;
  const inField = e.target.closest('.cm-editor') || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
  if (inField) return;
  const ids = cellIds(); if (!selectedId || !ids.includes(selectedId)) return;
  e.preventDefault();
  const id = selectedId, c = _cellById(id);
  const ran = (c && c.kind === 'code' && !hasBinds(c)) ? runCell(id) : Promise.resolve();
  if (e.metaKey || e.ctrlKey) ran.then(() => addCell(id, 'code', false, true));            // run + new cell below (edit it)
  else ran.then(() => { const a = cellIds(), i = a.indexOf(id); if (i >= 0 && i < a.length - 1) selectCell(a[i + 1], true); });
});
// Click selects (mousedown precedes editor focus); double-click the id label renames it.
// Shift-click extends a range from the anchor; ⌘/Ctrl-click toggles one cell — both suppress
// the default (text selection / editor focus) so they don't drop you into edit mode.
document.getElementById('nb').addEventListener('mousedown', e => {
  const cell = e.target.closest('.cell'); if (!cell) return;
  const id = cell.dataset.cid;
  if (e.shiftKey) { e.preventDefault(); selectRangeTo(id, false); const s = window.getSelection && window.getSelection(); s && s.removeAllRanges(); }
  else if (e.metaKey || e.ctrlKey) { e.preventDefault(); toggleSelect(id); }
  else selectCell(id);
});
document.getElementById('nb').addEventListener('dblclick', e => {
  const span = e.target.closest('.cid'); if (span) startRename(span);
});
function startRename(span) {
  const oldid = span.closest('.cell').dataset.cid;
  const inp = document.createElement('input'); inp.className = 'cidedit'; inp.value = oldid;
  span.replaceWith(inp); inp.focus(); inp.select();
  // Ids must be header-safe — fold spaces/punctuation to underscores as you type
  // (1:1, so the caret doesn't jump).
  inp.oninput = () => { const p = inp.selectionStart; inp.value = inp.value.replace(/[^A-Za-z0-9_]/g, '_'); inp.setSelectionRange(p, p); };
  let done = false;
  const finish = async commit => {
    if (done) return; done = true;
    const v = inp.value.trim();
    if (commit && v && v !== oldid) {
      const r = await fetch(_apipath('/api/cell-rename/' + oldid),
        { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ newid: v }) });
      if (r.ok) { renderAll(await r.json()); selectCell(v); return; }
      await alertDark('Rename failed: ' + (await r.text()));
    }
    // Cancel (Esc/blur) or a failed commit: put the ORIGINAL label node back. We can't lean on
    // renderAll(nbState) here — the state is unchanged, so Preact diffs identical vdom and skips the
    // re-render, leaving our raw <input> orphaned in the DOM (that was the "Esc won't close it" bug).
    if (inp.isConnected) inp.replaceWith(span);
  };
  inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); finish(true); }
    else if (e.key === 'Escape') { e.preventDefault(); finish(false); } };
  inp.onblur = () => finish(true);
}

