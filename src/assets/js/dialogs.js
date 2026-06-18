// ── Dark modal + loading overlay (shared confirm/alert + wait UX) ─────────────
let _modalResolve = null;
function _modalClose(v) {
  if (_modalResolve) { const r = _modalResolve; _modalResolve = null;
    document.getElementById('modalbg').classList.remove('show'); r(v); }
}
function dlg(message, buttons) {
  return new Promise(resolve => {
    _modalResolve = resolve;
    const row = document.getElementById('modalrow');
    document.getElementById('modalmsg').textContent = message; row.innerHTML = '';
    buttons.forEach(b => { const el = document.createElement('button'); el.textContent = b.label;
      if (b.cls) el.className = b.cls; el.onclick = () => _modalClose(b.value); row.appendChild(el); });
    document.getElementById('modalbg').classList.add('show');
    const pr = row.querySelector('.primary') || row.lastChild; if (pr) pr.focus();
  });
}
const confirmDark = (msg, ok, cls) => dlg(msg, [{ label: 'Cancel', value: false }, { label: ok || 'OK', value: true, cls: cls || 'primary' }]);
const alertDark = msg => dlg(msg, [{ label: 'OK', value: true, cls: 'primary' }]);
function showLoading(m) { document.getElementById('lmsg').textContent = m || 'Working…'; document.getElementById('loading').classList.add('show'); }
function hideLoading() { document.getElementById('loading').classList.remove('show'); }
document.addEventListener('keydown', e => {
  const bg = document.getElementById('modalbg');
  if (bg && bg.classList.contains('show') && e.key === 'Escape') { e.stopPropagation(); _modalClose(false); }
}, true);
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'modalbg') _modalClose(false); });

async function runAll()  {
  if (_hydrating) return;
  const shape = c => (hasBinds(c) ? 'b' : c.kind);          // structural signature
  const before = new Map(((nbState && nbState.cells) || []).map(c => [c.id, shape(c)]));
  const state = await api('POST', '/api/run');
  // If any cell changed structural shape (gained/lost @bind widgets, flipped kind, or the
  // cell set changed), patch-in-place can't restructure — rebuild fully.
  const changed = (state.cells || []).length !== before.size
    || (state.cells || []).some(c => before.get(c.id) !== shape(c));
  changed ? renderAll(state) : updateStates(state);
}
async function resetAll(){ updateStates(await api('POST', '/api/reset')); }
async function restartWorker(){
  if (!await confirmDark("Restart this notebook's worker? Its process is killed and cells re-run from a fresh namespace.", 'Restart')) return;
  showLoading('Restarting worker — respawning the process and re-running cells…');
  try { renderAll(await api('POST', '/api/restart')); } finally { hideLoading(); }
}
async function reload()  { const s = await api('GET', '/api/state'); lastVersion = s.version; renderAll(s); }
// ── Static export (HTML / print → PDF) ────────────────────────────────────────
// Download a self-contained HTML document of the notebook (figures embedded, math via
// KaTeX). PDF goes through the browser's own print dialog on that same static doc.
function exportHtml() {
  const a = document.createElement('a');
  a.href = _apipath('/api/export.html?dl=1'); a.download = (nbState && nbState.title || 'notebook') + '.html';
  document.body.appendChild(a); a.click(); a.remove();
}
function printNotebook() {
  const w = window.open(_apipath('/api/export.html'), '_blank');
  if (w) w.addEventListener('load', () => setTimeout(() => w.print(), 300));
}
// Self-contained single-source .jl: cells + full Project/Manifest + local source (+ a git
// bundle when the project is a repo). Can take a moment (tars the env + source).
async function exportStandalone() {
  showLoading('Bundling environment + source…');
  try {
    const r = await fetch(_apipath('/api/export.standalone.jl'));
    if (!r.ok) { await alertDark('Standalone export failed:\n' + (await r.text())); return; }
    const blob = await r.blob(), url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = (nbState && nbState.title || 'notebook') + '.standalone.jl';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  } catch (e) { await alertDark('Standalone export failed: ' + e); }
  finally { hideLoading(); }
}
// Publication-quality PDF, rendered server-side via Typst. Options (theme, layout, code
// size) come from a small modal; the last choices are remembered. Can take a few seconds
// (first run also fetches the Typst packages), so show the loading overlay + blob-download.
// Figures embed as vector (CairoMakie PDF / ECharts SVG) when available.
let _pdfResolve = null;
function closePdfDialog(go) {
  document.getElementById('pdfbg').classList.remove('show');
  if (_pdfResolve) { const r = _pdfResolve; _pdfResolve = null; r(go); }
}
function _pdfPick() {
  return new Promise(resolve => {
    _pdfResolve = resolve;
    ['pdftheme', 'pdflayout', 'pdfbody', 'pdfcode'].forEach(id => {
      const v = localStorage.getItem('slate_' + id); if (v != null) document.getElementById(id).value = v;
    });
    document.getElementById('pdfbg').classList.add('show');
  });
}
async function exportPdf() {
  const go = await _pdfPick();
  if (!go) return;
  const theme = document.getElementById('pdftheme').value;
  const [style, columns] = document.getElementById('pdflayout').value.split('|');
  const body = document.getElementById('pdfbody').value;
  const code = document.getElementById('pdfcode').value;
  ['pdftheme', 'pdflayout', 'pdfbody', 'pdfcode'].forEach(id => localStorage.setItem('slate_' + id, document.getElementById(id).value));
  showLoading('Rendering PDF with Typst…');
  try {
    const qs = '?theme=' + theme + '&style=' + style + '&columns=' + columns + '&body=' + body + '&code=' + code;
    const r = await fetch(_apipath('/api/export.pdf') + qs);
    if (!r.ok) { await alertDark('PDF export failed:\n' + (await r.text())); return; }
    const blob = await r.blob(), url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = (nbState && nbState.title || 'notebook') + '.pdf';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  } catch (e) { await alertDark('PDF export failed: ' + e); }
  finally { hideLoading(); }
}

