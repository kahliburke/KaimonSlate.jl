// ── Error line: highlight the offending source line + click-to-jump ───────────
// A cell that errored carries `errorLine` (1-based) — the `string:N` from the backtrace, i.e. the
// cell's OWN source line. We tint that line in the editor, and a click on the error message scrolls
// to and flashes it. Plain code cells have an always-on editor (window.editors[id]); @bind cells
// don't, so for those a click just scrolls to the cell.

function _clearErrorLine(ed) {
  if (ed && ed._errLine != null) {
    try { ed.removeLineClass(ed._errLine, 'background', 'cm-errorline'); } catch (_) {}
    ed._errLine = null;
  }
}

// Called from the cell render effect (notebook.js) after the output swaps in. Idempotent: it only
// touches CodeMirror when the highlighted line actually changes.
function _applyErrorLine(c, ed) {
  if (!ed || !ed.addLineClass) return;
  // Don't mislead while the user is editing — the line numbers may no longer match the error.
  const ln = (c && c.errorLine && c.state !== 'edited') ? c.errorLine - 1 : null;
  if (ed._errLine === ln) return;
  _clearErrorLine(ed);
  if (ln != null && ln >= 0 && ed.lineCount && ln < ed.lineCount()) {
    try { ed.addLineClass(ln, 'background', 'cm-errorline'); ed._errLine = ln; } catch (_) {}
  }
}
window._applyErrorLine = _applyErrorLine;

// Put the cell into edit mode with the cursor on `line1` (1-based) and flash it. Selects the cell,
// enters edit (focuses the code editor, or opens the source editor for a @bind/md cell), then —
// after that editor is mounted/refreshed — places the cursor on the line and scrolls it into view.
function jumpToCellLine(cellId, line1) {
  if (typeof selectCell === 'function') selectCell(cellId, true);
  if (typeof enterEdit === 'function') enterEdit(cellId);     // focus code editor / open source editor
  const ln = line1 - 1;
  requestAnimationFrame(() => {
    const ed = window.editors[cellId];
    if (!ed || !ed.setCursor || !ed.lineCount || ln < 0 || ln >= ed.lineCount()) return;
    try {
      ed.focus();
      ed.setCursor({ line: ln, ch: 0 });
      ed.scrollIntoView({ line: ln, ch: 0 }, 80);
      ed.addLineClass(ln, 'background', 'cm-errorline-flash');
      setTimeout(() => { try { ed.removeLineClass(ln, 'background', 'cm-errorline-flash'); } catch (_) {} }, 1000);
    } catch (_) {}
  });
}
window.jumpToCellLine = jumpToCellLine;

// Click the `string:N` reference in a backtrace → jump to that line in the cell. (Real
// `path.jl:line` links keep their VS Code `.srcref` behavior — they're a different element.)
document.addEventListener('click', e => {
  if (!e.target.closest) return;
  const ref = e.target.closest('.cellref');
  if (!ref) return;
  e.preventDefault();
  const cell = ref.closest('.cell');
  const line = parseInt(ref.dataset.line, 10);
  if (cell && cell.dataset && cell.dataset.cid && line) jumpToCellLine(cell.dataset.cid, line);
});
