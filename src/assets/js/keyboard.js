// ── Command/edit mode + Jupyter-style keyboard shortcuts ──────────────────────
// Command mode: a cell is "selected" (accent ring) and single keys act on it —
// j/k or ↑/↓ to move, a/b to insert above/below, dd to delete, m/y to set
// markdown/code, Enter to edit. Edit mode: focus inside the CodeMirror (green
// ring); Esc returns to command mode.
let selectedId = null, _dPending = false, _dTimer = null;
const cellIds = () => ((nbState && nbState.cells) || []).map(c => c.id);
function selectCell(id, scroll) {
  selectedId = id;
  window.slateStore && window.slateStore.setSelected(id);     // feed the Preact signals store
  document.querySelectorAll('.cell').forEach(el => el.classList.toggle('selected', el.dataset.cid === id));
  const el = id && document.getElementById('cell-' + id);
  if (el && scroll) el.scrollIntoView({ block: 'nearest' });
}
function setEditing(id, on) {
  const el = document.getElementById('cell-' + id); if (el) el.classList.toggle('editing', on);
  if (on) selectCell(id);
}
function enterEdit(id) {
  const c = _cellById(id); if (!c) return;
  if (c.kind === 'code' && !hasBinds(c)) { const ed = editors[id]; if (ed) ed.focus(); }
  else editSource(id, c.kind === 'md' ? 'markdown' : 'julia');
}
document.addEventListener('keydown', e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (document.getElementById('modalbg').classList.contains('show')) return;
  const inField = e.target.closest('.CodeMirror') || /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
  if (inField) return;                                  // edit mode / typing → leave keys alone
  const ids = cellIds(); if (!ids.length) return;
  if (!selectedId || !ids.includes(selectedId)) {
    if (e.key === 'ArrowDown' || e.key === 'j' || e.key === 'Enter') { selectCell(ids[0], true); e.preventDefault(); }
    return;
  }
  const idx = ids.indexOf(selectedId), k = e.key;
  // Shift+↑/↓ (or Shift+K/J) MOVE the selected cell; plain keys just navigate. The
  // shift branches must precede the plain arrows so the modifier wins.
  if (e.shiftKey && (k === 'ArrowUp' || k === 'K')) { e.preventDefault(); moveCell(selectedId, 'up'); }
  else if (e.shiftKey && (k === 'ArrowDown' || k === 'J')) { e.preventDefault(); moveCell(selectedId, 'down'); }
  else if (k === 'Enter') { e.preventDefault(); enterEdit(selectedId); }
  else if (k === 'ArrowDown' || k === 'j') { e.preventDefault(); if (idx < ids.length - 1) selectCell(ids[idx + 1], true); }
  else if (k === 'ArrowUp' || k === 'k') { e.preventDefault(); if (idx > 0) selectCell(ids[idx - 1], true); }
  else if (k === 'a') { e.preventDefault(); addCell(selectedId, 'code', true); }
  else if (k === 'b') { e.preventDefault(); addCell(selectedId, 'code', false); }
  else if (k === 'm') { e.preventDefault(); const c = _cellById(selectedId); if (c && c.kind !== 'md') toggleType(selectedId, 'md'); }
  else if (k === 'y') { e.preventDefault(); const c = _cellById(selectedId); if (c && c.kind !== 'code') toggleType(selectedId, 'code'); }
  else if (k === 'M') { e.preventDefault(); mergeBelow(selectedId); }    // Shift-M: merge with cell below
  else if (k === 'd') { e.preventDefault();
    if (_dPending) { _dPending = false; clearTimeout(_dTimer); delCell(selectedId); }
    else { _dPending = true; _dTimer = setTimeout(() => _dPending = false, 650); } }
});
// Click selects (mousedown precedes editor focus); double-click the id label renames it.
document.getElementById('nb').addEventListener('mousedown', e => {
  const cell = e.target.closest('.cell'); if (cell) selectCell(cell.dataset.cid);
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
      if (r.ok) { renderAll(await r.json()); selectCell(v); }
      else { await alertDark('Rename failed: ' + (await r.text())); renderAll(nbState); }
    } else { renderAll(nbState); }   // cancel → rebuild the label
  };
  inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); finish(true); }
    else if (e.key === 'Escape') { e.preventDefault(); finish(false); } };
  inp.onblur = () => finish(true);
}

