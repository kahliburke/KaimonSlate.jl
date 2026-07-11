// ── Trace inspector modal ─────────────────────────────────────────────────────
// A traced cell (🔍) renders a `.slate-trace-wrap` containing a compact preview table plus a
// JSON `data-trace` payload of {line,name,value} rows. Clicking that wrap (or toggling trace
// on) opens this modal: the cell's SOURCE shown line-by-line with each line's captured values
// aligned beside it. Loop lines show every iteration's value in sequence. Line numbers align
// 1:1 with the source because the @trace wrapper joins on one line (see eval.jl).

function _trcEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Build the integrated "code + values" view for `source` (string) and `rows` ([{line,name,value}]).
// Each source line renders as a code row. Lines captured ONCE show their value directly below.
// Loop-body lines (a line captured more than once) are gathered into an ITERATION TABLE placed
// under the loop — one row per pass, variables as columns — so the values from the same iteration
// stay together. Everything wraps within the modal; nothing runs off-screen.
function _renderTraceView(source, rows) {
  const lines = (source || '').split('\n');
  rows = rows || [];
  const freq = {};
  rows.forEach(r => { freq[r.line] = (freq[r.line] || 0) + 1; });
  const looped = l => (freq[l] || 0) > 1;                 // a line captured >1× ⇒ inside a loop
  const recorded = new Set(rows.map(r => r.line));

  // rows for a single (non-loop) line, in capture order
  const byLine = new Map();
  rows.forEach(r => { if (!byLine.has(r.line)) byLine.set(r.line, []); byLine.get(r.line).push(r); });

  // Loop blocks: maximal runs of looped lines, broken only by a NON-looped recorded line (which
  // belongs to a separate statement). Each block renders one iteration table after its last line.
  const blocks = []; let cur = null;
  for (let ln = 1; ln <= lines.length; ln++) {
    if (looped(ln)) { if (!cur) cur = { start: ln, end: ln }; cur.end = ln; }
    else if (cur && recorded.has(ln)) { blocks.push(cur); cur = null; }
  }
  if (cur) blocks.push(cur);
  const blockAt = ln => blocks.find(b => ln >= b.start && ln <= b.end && looped(ln));

  // Reconstruct iterations of a block: walk its rows; a column key repeating starts a new pass.
  function reconstruct(b) {
    const brows = rows.filter(r => r.line >= b.start && r.line <= b.end && looped(r.line));
    const cols = []; const iterations = []; let pass = null, seen = null;
    brows.forEach(r => {
      const key = r.line + ':' + r.name;
      if (!pass || seen.has(key)) { pass = {}; seen = new Set(); iterations.push(pass); }
      pass[key] = r.value; seen.add(key);
      if (!cols.some(c => c.key === key)) cols.push({ key: key, name: r.name });
    });
    return { cols, iterations };
  }

  let html = '<div class="traceview">';
  for (let i = 0; i < lines.length; i++) {
    const lineNo = i + 1;
    const blk = blockAt(lineNo);
    html += '<div class="tvline' + (recorded.has(lineNo) ? ' tv-has' : '') + '">'
      + '<span class="tv-ln">' + lineNo + '</span>'
      + '<code class="tv-code">' + (_trcEsc(lines[i]) || ' ') + '</code></div>';
    if (blk && lineNo === blk.end) {
      const r = reconstruct(blk);
      html += '<div class="tvloop"><table class="tvtab"><thead><tr><th class="tv-it">#</th>'
        + r.cols.map(c => '<th><span class="tv-name">' + _trcEsc(c.name) + '</span></th>').join('')
        + '</tr></thead><tbody>'
        + r.iterations.map((it, k) => '<tr><td class="tv-it">' + (k + 1) + '</td>'
          + r.cols.map(c => '<td>' + (it[c.key] != null ? '<span class="tv-val">' + _trcEsc(it[c.key]) + '</span>' : '') + '</td>').join('')
          + '</tr>').join('')
        + '</tbody></table></div>';
    } else if (!blk && byLine.has(lineNo)) {
      const groups = [];
      byLine.get(lineNo).forEach(r => {
        let g = groups.find(x => x.name === r.name);
        if (!g) { g = { name: r.name, values: [] }; groups.push(g); }
        g.values.push(r.value);
      });
      const chips = groups.map(g => {
        const nm = g.name === 'result'
          ? '<span class="tv-res">result</span>'
          : '<span class="tv-name">' + _trcEsc(g.name) + '</span>';
        const vs = g.values.map(v => '<span class="tv-val">' + _trcEsc(v) + '</span>')
          .join('<span class="tv-arrow">→</span>');
        return '<span class="tv-grp">' + nm + ' = ' + vs + '</span>';
      }).join('');
      html += '<div class="tvvals">' + chips + '</div>';
    }
  }
  return html + '</div>';
}

let _traceCell = null;                                  // cell id the popup is currently showing

function openTraceModal(cellId) {
  const c = (typeof _cellById === 'function') ? _cellById(cellId) : null;
  // Rows ride on the cell state (`traceData`) — the cell's NORMAL output is shown in place.
  const rows = (c && c.traceData) || [];
  const source = (c && c.source) || '';
  _traceCell = cellId;
  document.getElementById('tracetitle').textContent = 'Trace · ' + cellId;
  const nlines = source.split('\n').length;
  document.getElementById('tracesub').textContent =
    rows.length + ' value' + (rows.length === 1 ? '' : 's') + ' · ' + nlines + ' line' + (nlines === 1 ? '' : 's');
  document.getElementById('tracebody').innerHTML = rows.length
    ? _renderTraceView(source, rows)
    : '<div class="tracenone">No values were traced (the cell may have errored, or has no assignments). Run it, then reopen.</div>';
  document.getElementById('tracebg').classList.add('show');
}
function closeTraceModal() { document.getElementById('tracebg').classList.remove('show'); }
// Stop tracing the cell the popup is showing (turns the flag off + re-runs normally).
async function stopTraceModal() {
  const id = _traceCell; closeTraceModal();
  if (id != null) renderAll(await api('POST', '/api/cell-flag', { flag: 'trace', value: false, cells: [id] }));
}

// Esc closes it (capture phase, like the other modals); backdrop click closes it.
document.addEventListener('keydown', e => {
  const bg = document.getElementById('tracebg');
  if (bg && bg.classList.contains('show') && e.key === 'Escape') { e.stopPropagation(); closeTraceModal(); }
}, true);
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'tracebg') closeTraceModal(); });
