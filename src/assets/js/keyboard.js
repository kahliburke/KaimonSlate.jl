// ── Command/edit mode: the selection, and what a click does to it ─────────────
// Command mode: a cell is "selected" (PURPLE ring) and single keys act on it — j/k or ↑/↓ to move,
// a/b to insert above/below, dd to delete, m/y to set markdown/code, Enter to edit. Edit mode: focus
// inside the CodeMirror (TEAL ring + a ✎ chip in the header); Esc returns to command mode.
//
// The KEYS themselves are not here any more. Every shortcut in the notebook is a registered command
// (commands.js) resolved through one keymap (keymap.js), so they are rebindable and the palette's
// shortcut hints read the live binding. What stays here is the selection model (single-select,
// range-extend, toggle), the mouse gestures that drive it, and the id-label rename.
//
// Which mode you are in is STATE, not a class on the element: it lives in the store's `editing` signal
// and <Cell> folds it into the cell's class. The ring used to be poked onto the DOM here, so the first
// keystroke — which rewrites that class as the cell goes fresh → edited — silently erased it, and the
// chrome then showed command mode while the keyboard was still in the editor.
let selectedId = null, anchorId = null;
// `selectedId` is a classic-script `let`, so it is NOT a property of `window` and an ES module island
// can't read it. Everything outside this file — islands, commands.js, the keymap — goes through these.
window.slateSelectedId = () => selectedId || '';
const cellIds = () => ((nbState && nbState.cells) || []).map(c => c.id);
window.slateCellIds = cellIds;
// The current selection as an ordered (notebook-order) id list; falls back to the active cell.
function selectedIds() {
  const s = window.slateStore && window.slateStore.selectedSet.value;
  if (!s || !s.size) return selectedId ? [selectedId] : [];
  return cellIds().filter(id => s.has(id));
}
window.slateSelectedIds = selectedIds;
// Single-select: clear to just `id` (also resets the range anchor here).
function selectCell(id, scroll) {
  selectedId = id; anchorId = id;
  window.slateStore && window.slateStore.setSelected(id);     // feed the Preact signals store
  window._navRecord && window._navRecord(id);                 // record in the back/forward nav history
  const el = id && document.getElementById('cell-' + id);
  if (el && scroll) el.scrollIntoView({ block: 'nearest' });
}
// Extend the selection from the fixed anchor to `id` (shift-click / shift-arrow). `id` becomes active.
// Published for the selection-extending commands, which compute the target id from the cell list.
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
window.slateSelectRangeTo = selectRangeTo;
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
// Is this cell showing its raw-source overlay? (md / @bind cells render output by default.) The
// command-mode Escape asks, so it can close the overlay before collapsing the selection.
function _srcOpen(id) {
  const cell = document.getElementById('cell-' + id); if (!cell) return false;
  const sed = cell.querySelector('.srcedit');
  return !!(sed && sed.style.display !== 'none');
}
window.slateSrcOpen = _srcOpen;
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

