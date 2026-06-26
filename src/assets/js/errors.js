// ── Error line: highlight the offending source line + click-to-jump ───────────
// A cell that errored carries `errorLine` (1-based) — the `string:N` from the backtrace, i.e. the
// cell's OWN source line. We tint that line in the editor, and a click on the error message scrolls
// to and flashes it. Plain code cells have an always-on editor (window.editors[id]); @bind cells
// don't, so for those a click just scrolls to the cell.

// Called from the cell render effect (notebook.js) after output swaps in. Marks two lines via CM6
// line decorations (editor.js): the ORIGIN — the actual offending line, possibly in another cell —
// gets the brighter `cm-errorline-origin`; the call site in THIS cell (when distinct) gets the faint
// `cm-errorline`. The origin is read from the rendered error message (`.errjump` carries the origin
// cell id + line — see render.jl). Both persist regardless of navigation/edit (CM6 maps them) and
// clear when the cell re-runs clean. `_originMarks` lets a cell clear the origin mark it owns.
const _originMarks = {};   // erroredCellId -> origin cellId it currently marks
function _applyErrorLine(c) {
  if (!c || !window.editors[c.id]) return;
  const cellEl = document.querySelector('.cell[data-cid="' + c.id + '"]');
  const ej = cellEl && cellEl.querySelector('.errjump');
  const oCid = ej && ej.dataset.cid, oLine = ej && parseInt(ej.dataset.line, 10);
  const prev = _originMarks[c.id];
  if (prev && prev !== oCid) { window.clearOriginLine(prev); delete _originMarks[c.id]; }   // origin moved/cleared
  if (c.errorLine && oCid && oLine && window.editors[oCid]) {
    window.markOriginLine(oCid, oLine);                                    // bright: the actual offending line
    _originMarks[c.id] = oCid;
    (oCid !== c.id || oLine !== c.errorLine)                              // faint call site only when distinct
      ? window.markErrorLine(c.id, c.errorLine) : window.clearErrorLine(c.id);
  } else if (c.errorLine) {
    window.markErrorLine(c.id, c.errorLine);                              // no origin info → faint own line
  } else {
    window.clearErrorLine(c.id);
    if (prev) { window.clearOriginLine(prev); delete _originMarks[c.id]; }
  }
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
