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

// Scroll to a cell's offending line and flash it.
function scrollToErrorLine(cellId) {
  const cellEl = document.getElementById('cell-' + cellId);
  if (cellEl) cellEl.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  const c = (typeof _cellById === 'function') ? _cellById(cellId) : null;
  const ed = window.editors[cellId];
  if (ed && ed.addLineClass && c && c.errorLine) {
    const ln = c.errorLine - 1;
    if (ln >= 0 && ed.lineCount && ln < ed.lineCount()) {
      try {
        ed.scrollIntoView({ line: ln, ch: 0 }, 80);
        ed.addLineClass(ln, 'background', 'cm-errorline-flash');
        setTimeout(() => { try { ed.removeLineClass(ln, 'background', 'cm-errorline-flash'); } catch (_) {} }, 1000);
      } catch (_) {}
    }
  }
}
window.scrollToErrorLine = scrollToErrorLine;

// Click an error message → jump to the offending line. A real `path.jl:line` link (.srcref) keeps
// its VS Code behavior; clicking anywhere else in the error block jumps within the cell.
document.addEventListener('click', e => {
  if (!e.target.closest) return;
  if (e.target.closest('.srcref')) return;
  const err = e.target.closest('.output .err.errjumpable');
  if (!err) return;
  const cell = err.closest('.cell');
  if (cell && cell.dataset && cell.dataset.cid) scrollToErrorLine(cell.dataset.cid);
});
