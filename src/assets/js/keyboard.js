// ── Command/edit mode + Jupyter-style keyboard shortcuts ──────────────────────
// Command mode: a cell is "selected" (PURPLE ring) and single keys act on it —
// j/k or ↑/↓ to move, a/b to insert above/below, dd to delete, m/y to set
// markdown/code, Enter to edit. Edit mode: focus inside the CodeMirror (TEAL
// ring + a ✎ chip in the header); Esc returns to command mode. The command-mode bindings are a
// table (`KEY_ACTIONS`, below) that localStorage can override.
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
// ── The command-mode keymap ───────────────────────────────────────────────────
// Every command-mode shortcut is a named ACTION with a body and a default key list. The handler
// resolves the pressed key through this table rather than testing keys inline, so a binding can be
// moved or dropped without touching the dispatch, and so the bindings can be listed.
//
// A key is written as `event.key`, prefixed `Alt-` when Alt is held and `Shift-` when Shift is
// needed to tell it apart. A printable character already carries Shift ('K' IS shift-k), so only
// named keys take the `Shift-` prefix: `Shift-ArrowUp`, but plain `K`.
//
// Overrides live in localStorage `slateKeymap` as an action → key-list object. There is no UI for
// them yet; the console is the interface:
//
//   slateKeymap()                            list the resolved bindings
//   slateBindKey('cell-add-above', [])       unbind — the key does nothing
//   slateBindKey('cell-add-above', 'i')      rebind (taking 'i' off whatever held it)
//   slateBindKey('cell-add-above')           restore the default
//   slateKeymapReset()                       drop all overrides
//
// An action body gets `{id, ids, idx, e}` and returns `false` to decline the key, which lets the
// browser default stand; anything else counts as handled and the default is suppressed.
const KEY_ACTIONS = {
  'select-next':        { keys: ['ArrowDown', 'j'], run: c => { if (c.idx < c.ids.length - 1) selectCell(c.ids[c.idx + 1], true); } },
  'select-prev':        { keys: ['ArrowUp', 'k'],   run: c => { if (c.idx > 0) selectCell(c.ids[c.idx - 1], true); } },
  // Shift+↑/↓ (or ⇧J/⇧K) EXTEND the selection from the anchor; plain keys navigate (single-select).
  'select-extend-next': { keys: ['Shift-ArrowDown', 'J'], run: c => { if (c.idx < c.ids.length - 1) selectRangeTo(c.ids[c.idx + 1], true); } },
  'select-extend-prev': { keys: ['Shift-ArrowUp', 'K'],   run: c => { if (c.idx > 0) selectRangeTo(c.ids[c.idx - 1], true); } },
  // Alt+↑/↓ MOVES the active cell (this was Shift+↑/↓ before multi-select claimed Shift).
  'cell-move-up':       { keys: ['Alt-ArrowUp'],   run: c => moveCell(c.id, 'up') },
  'cell-move-down':     { keys: ['Alt-ArrowDown'], run: c => moveCell(c.id, 'down') },
  'cell-edit':          { keys: ['Enter'], run: c => enterEdit(c.id) },      // ⇧⏎ is run, handled below
  // Escape in COMMAND mode, in order: collapse a raw-source overlay left open by the Escape that
  // brought you here, then collapse a multi-selection to the active cell. Closing the overlay goes
  // through toggleSource, so a changed source is COMMITTED rather than dropped — Escape never
  // destroys work.
  'escape':             { keys: ['Escape'], run: c => {
      if (_srcOpen(c.id)) { const cell = _cellById(c.id); toggleSource(c.id, cell && cell.kind === 'md' ? 'markdown' : 'julia'); }
      else if (selectedIds().length > 1) selectCell(c.id);
      else return false;
    } },
  'cell-add-above':     { keys: ['a'], run: c => addCell(c.id, 'code', true) },
  'cell-add-below':     { keys: ['b'], run: c => addCell(c.id, 'code', false) },
  'cell-copy':          { keys: ['c'], run: () => copyCells() },             // copy selected cell(s)
  'cell-cut':           { keys: ['x'], run: () => cutCells() },              // cut selected cell(s)
  'cell-paste':         { keys: ['v'], run: () => pasteCells() },            // paste below the active cell
  'cell-to-markdown':   { keys: ['m'], run: c => { const cell = _cellById(c.id); if (cell && cell.kind !== 'md') toggleType(c.id, 'md'); } },
  'cell-to-code':       { keys: ['y'], run: c => { const cell = _cellById(c.id); if (cell && cell.kind !== 'code') toggleType(c.id, 'code'); } },
  'cell-to-web':        { keys: ['w'], run: c => { const cell = _cellById(c.id); if (cell && cell.kind !== 'web') toggleType(c.id, 'web'); } },
  'cell-merge-below':   { keys: ['M'], run: c => mergeBelow(c.id) },
  // dd — press twice inside the window. delCell deletes the whole selection.
  'cell-delete':        { keys: ['d'], run: c => {
      if (_dPending) { _dPending = false; clearTimeout(_dTimer); delCell(c.id); }
      else { _dPending = true; _dTimer = setTimeout(() => _dPending = false, 650); }
    } },
};
let _keymap = {}, _keyToAction = new Map();
function _storedKeymap() {
  try { const o = JSON.parse(localStorage.getItem('slateKeymap') || '{}'); return (o && typeof o === 'object') ? o : {}; }
  catch { return {}; }
}
// Defaults with the stored overrides applied, then inverted to key → action. An override that
// claims a key takes it away from whatever held it by default, so rebinding never leaves two
// actions racing for one key.
function _buildKeymap() {
  const over = _storedKeymap();
  _keymap = {};
  for (const a in KEY_ACTIONS) _keymap[a] = KEY_ACTIONS[a].keys.slice();
  for (const a in over) {
    if (!(a in KEY_ACTIONS)) continue;
    const ks = over[a] == null ? [] : (Array.isArray(over[a]) ? over[a] : [over[a]]).map(String);
    for (const b in _keymap) if (b !== a) _keymap[b] = _keymap[b].filter(k => !ks.includes(k));
    _keymap[a] = ks;
  }
  _keyToAction = new Map();
  for (const a in _keymap) for (const k of _keymap[a]) if (!_keyToAction.has(k)) _keyToAction.set(k, a);
  return _keymap;
}
_buildKeymap();
// `undefined` keys restores the default; `[]` or null unbinds.
window.slateBindKey = (action, keys) => {
  if (!(action in KEY_ACTIONS)) throw new Error('no such action: ' + action + ' (see slateKeymap())');
  const over = _storedKeymap();
  if (keys === undefined) delete over[action];
  else over[action] = keys == null ? [] : (Array.isArray(keys) ? keys : [keys]);
  localStorage.setItem('slateKeymap', JSON.stringify(over));
  return _buildKeymap();
};
window.slateKeymap = () => _buildKeymap();
window.slateKeymapReset = () => { localStorage.removeItem('slateKeymap'); return _buildKeymap(); };
function _keyToken(e) {
  let t = e.key;
  if (e.shiftKey && t.length > 1) t = 'Shift-' + t;
  if (e.altKey) t = 'Alt-' + t;
  return t;
}
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey) return;
  if (document.getElementById('modalbg').classList.contains('show')) return;
  const inField = e.target.closest('.cm-editor') || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
  if (inField) return;                                  // edit mode / typing → leave keys alone
  const ids = cellIds(); if (!ids.length) return;
  const action = _keyToAction.get(_keyToken(e));
  if (!selectedId || !ids.includes(selectedId)) {
    // Nothing selected: the first key that would move down or start editing selects the first cell.
    // Modifiers are ignored here so ⇧⏎ also lands on a cell (the run handler below then takes it).
    const boot = action || _keyToAction.get(e.key);
    if (boot === 'select-next' || boot === 'cell-edit') { selectCell(ids[0], true); e.preventDefault(); }
    return;
  }
  if (!action) return;
  const ran = KEY_ACTIONS[action].run({ id: selectedId, ids, idx: ids.indexOf(selectedId), e });
  if (ran !== false) e.preventDefault();
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

