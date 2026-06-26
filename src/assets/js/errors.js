// ── Error line: highlight the offending source line + click-to-jump ───────────
// A cell that errored carries `errorLine` (1-based) — the `string:N` from the backtrace, i.e. the
// cell's OWN source line. We tint that line in the editor, and a click on the error message scrolls
// to and flashes it. Plain code cells have an always-on editor (window.editors[id]); @bind cells
// don't, so for those a click just scrolls to the cell.

// Called from the cell render effect (notebook.js) after output swaps in. Tints the offending line
// (CM6 line decoration via markErrorLine/clearErrorLine, editor.js). The faint overlay stays as long
// as the cell is errored — regardless of whether the user has navigated in / is editing (CM6 maps
// the decoration through edits); it clears when the cell re-runs without error.
function _applyErrorLine(c) {
  if (!c || !window.editors[c.id]) return;
  c.errorLine ? window.markErrorLine(c.id, c.errorLine) : window.clearErrorLine(c.id);
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

// Click the error message (`.errjump`) or a backtrace frame (`.cellref`) → jump to the offending
// line. A `cell:<id>:N` frame carries its OWN `data-cid` → jump to THAT cell (cross-cell: a function
// defined elsewhere); otherwise fall back to the cell containing the error. (Real `path.jl:line`
// links keep their VS Code `.srcref` behavior.)
document.addEventListener('click', e => {
  if (!e.target.closest) return;
  const ref = e.target.closest('.cellref, .errjump');
  if (!ref) return;
  e.preventDefault();
  const line = parseInt(ref.dataset.line, 10);
  const cell = ref.closest('.cell');
  const cid = ref.dataset.cid || (cell && cell.dataset && cell.dataset.cid);
  if (cid && line) jumpToCellLine(cid, line);
});
