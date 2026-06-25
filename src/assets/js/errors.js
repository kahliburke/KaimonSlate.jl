// ── Error line: highlight the offending source line + click-to-jump ───────────
// A cell that errored carries `errorLine` (1-based) — the `string:N` from the backtrace, i.e. the
// cell's OWN source line. We tint that line in the editor, and a click on the error message scrolls
// to and flashes it. Plain code cells have an always-on editor (window.editors[id]); @bind cells
// don't, so for those a click just scrolls to the cell.

// Called from the cell render effect (notebook.js) after output swaps in. Tints the offending line
// (CM6 line decoration via markErrorLine/clearErrorLine, editor.js). Suppressed while editing — the
// line numbers may no longer match the error.
function _applyErrorLine(c) {
  if (!c || !window.editors[c.id]) return;
  (c.errorLine && c.state !== 'edited') ? window.markErrorLine(c.id, c.errorLine) : window.clearErrorLine(c.id);
}
window._applyErrorLine = _applyErrorLine;

// Put the cell into edit mode with the cursor on `line1` (1-based) and flash it: select the cell,
// enter edit (focuses the code editor / opens the source editor for a @bind/md cell), then flash
// the line in the now-mounted editor (editor.js::flashLine focuses + scrolls + flashes).
function jumpToCellLine(cellId, line1) {
  if (typeof selectCell === 'function') selectCell(cellId, true);
  if (typeof enterEdit === 'function') enterEdit(cellId);
  requestAnimationFrame(() => { if (window.editors[cellId]) window.flashLine(cellId, line1); });
}
window.jumpToCellLine = jumpToCellLine;

// Click the error message (`.errjump`) or the backtrace's `string:N` (`.cellref`) → jump to the
// cell's offending line. (Real `path.jl:line` links keep their VS Code `.srcref` behavior.)
document.addEventListener('click', e => {
  if (!e.target.closest) return;
  const ref = e.target.closest('.cellref, .errjump');
  if (!ref) return;
  e.preventDefault();
  const cell = ref.closest('.cell');
  const line = parseInt(ref.dataset.line, 10);
  if (cell && cell.dataset && cell.dataset.cid && line) jumpToCellLine(cell.dataset.cid, line);
});
