// ── Dark modal + loading overlay (shared confirm/alert + wait UX) ─────────────
let _modalResolve = null;
function _modalClose(v) {
  if (_modalResolve) { const r = _modalResolve; _modalResolve = null;
    document.getElementById('modalbg').classList.remove('show'); r(v); }
}
// `opts.html` = true renders `message` as HTML (caller must supply trusted/escaped markup); default is
// safe textContent. `opts.buttons` on a button entry closes with that value.
function dlg(message, buttons, opts) {
  return new Promise(resolve => {
    _modalResolve = resolve;
    const row = document.getElementById('modalrow'), msgEl = document.getElementById('modalmsg');
    if (opts && opts.html) msgEl.innerHTML = message; else msgEl.textContent = message;
    row.innerHTML = '';
    buttons.forEach(b => { const el = document.createElement('button'); el.textContent = b.label;
      if (b.cls) el.className = b.cls; el.onclick = () => _modalClose(b.value); row.appendChild(el); });
    document.getElementById('modalbg').classList.add('show');
    const pr = row.querySelector('.primary') || row.lastChild; if (pr) pr.focus();
  });
}
const _escHtml = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
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
async function reload()  { const s = await api('GET', '/api/state'); lastVersion = s.version; renderAll(s); window.reconcileBackup && window.reconcileBackup(s); }
// ── Export (one modal → HTML · PDF · Standalone) ──────────────────────────────
// A single "Export" entry opens a modal with a format selector + per-format options; each
// format's rows carry an `fmt-<format>` class so `_exSyncRows` shows only the active set. The
// last format + option choices are remembered. Backends are the per-format routes (export.html /
// export.pdf / export.typ / export.standalone.jl); this is the front-end consolidation.
function _dlName(ext) { return (nbState && nbState.title || 'notebook') + ext; }
function _saveBlob(blob, ext) {
  const url = URL.createObjectURL(blob), a = document.createElement('a');
  a.href = url; a.download = _dlName(ext); document.body.appendChild(a); a.click(); a.remove(); URL.revokeObjectURL(url);
}
// The shared Outputs filter (all | figures | none) — appends `&outputs=` when not the default.
function _outputsQS() { const v = (document.getElementById('exoutputs') || {}).value || 'all'; return v === 'all' ? '' : '&outputs=' + v; }
// Self-contained HTML page (figures embedded, math via KaTeX). `dl=false` opens it in a tab.
function exportHtml(dl) {
  const src = document.getElementById('htmlsource');
  const theme = (document.getElementById('htmltheme') || {}).value || 'dark';
  const code = (document.getElementById('htmlcode') || {}).value || 'normal';
  const parts = [];
  if (src && !src.checked) parts.push('source=0');
  if (theme !== 'dark') parts.push('theme=' + theme);
  if (code !== 'normal') parts.push('code=' + code);
  const outv = (document.getElementById('exoutputs') || {}).value || 'all'; if (outv !== 'all') parts.push('outputs=' + outv);
  if ((document.getElementById('htmlrunnable') || {}).checked) parts.push('bundle=1');
  const q = parts.length ? '?' + parts.join('&') : '';
  if (dl === false) { window.open(_apipath('/api/export.html' + q), '_blank'); return; }
  const a = document.createElement('a');
  a.href = _apipath('/api/export.html' + (q ? q + '&dl=1' : '?dl=1')); a.download = _dlName('.html');
  document.body.appendChild(a); a.click(); a.remove();
}
// Downscale one `data:image/…;base64,…` URI to `maxW` px wide (canvas re-encode, PNG kept for
// transparency). Returns the original if it's already narrow enough or anything fails.
function _downscaleDataUri(uri, maxW) {
  return new Promise(resolve => {
    const img = new Image();
    img.onload = () => {
      if (!img.width || img.width <= maxW) { resolve(uri); return; }
      const w = maxW, h = Math.round(img.height * (maxW / img.width));
      const cv = document.createElement('canvas'); cv.width = w; cv.height = h;
      try { cv.getContext('2d').drawImage(img, 0, 0, w, h); resolve(cv.toDataURL('image/png')); }
      catch (_) { resolve(uri); }
    };
    img.onerror = () => resolve(uri);
    img.src = uri;
  });
}
// Shrink every embedded data-URI image in `md` to `maxW` px (dedup'd), so the Markdown fits
// upload/paste size limits. maxW=0 → unchanged.
async function _compactMarkdownImages(md, maxW) {
  if (!maxW) return md;
  const re = /data:image\/[a-z+]+;base64,[A-Za-z0-9+/=]+/g;
  const uniq = [...new Set(md.match(re) || [])];
  if (!uniq.length) return md;
  const scaled = await Promise.all(uniq.map(u => _downscaleDataUri(u, maxW)));
  const map = new Map(uniq.map((u, i) => [u, scaled[i]]));
  return md.replace(re, m => map.get(m) || m);
}
// GitHub-flavored Markdown. `mode='copy'` → clipboard (download fallback), else save a `.md` file.
async function exportMarkdown(mode) {
  const src = document.getElementById('mdsource');
  const parts = [];
  if (src && !src.checked) parts.push('source=0');
  const outv = (document.getElementById('exoutputs') || {}).value || 'all'; if (outv !== 'all') parts.push('outputs=' + outv);
  const q = parts.length ? '?' + parts.join('&') : '';
  try {
    const r = await fetch(_apipath('/api/export.md' + q));
    if (!r.ok) { await alertDark('Markdown export failed:\n' + (await r.text())); return; }
    let md = await r.text();
    const mw = { medium: 800, small: 480 }[(document.getElementById('mdimg') || {}).value] || 0;
    md = await _compactMarkdownImages(md, mw);
    const readme = document.getElementById('mdreadme');
    const name = readme && readme.checked ? 'README.md' : _dlName('.md');
    const save = () => {                                  // download the markdown as `name`
      const url = URL.createObjectURL(new Blob([md], { type: 'text/markdown' })), a = document.createElement('a');
      a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove(); URL.revokeObjectURL(url);
    };
    if (mode === 'copy') {
      try {
        await navigator.clipboard.writeText(md);
        showLoading('Copied Markdown to clipboard ✓'); setTimeout(hideLoading, 850);
      } catch (_) { save(); }                             // clipboard blocked → download instead
    } else {
      save();
    }
  } catch (e) { await alertDark('Markdown export failed: ' + e); }
}
// Publishable website (index.html + og-image.png) as a .tar.gz. Rendering the og:image (first figure,
// or a Typst title card) can take a moment.
async function exportSite() {
  const theme = (document.getElementById('sitetheme') || {}).value || 'dark';
  const outv = (document.getElementById('exoutputs') || {}).value || 'all';
  const parts = ['theme=' + theme]; if (outv !== 'all') parts.push('outputs=' + outv);
  if (!(document.getElementById('sitesource') || { checked: true }).checked) parts.push('source=0');
  if ((document.getElementById('siterunnable') || {}).checked) parts.push('bundle=1');
  showLoading('Building site + preview image…');
  try {
    const r = await fetch(_apipath('/api/export.site?' + parts.join('&')));
    if (!r.ok) { await alertDark('Site export failed:\n' + (await r.text())); return; }
    _saveBlob(await r.blob(), '.site.tar.gz');
  } catch (e) { await alertDark('Site export failed: ' + e); }
  finally { hideLoading(); }
}
// Publish the site to GitHub Pages via the server's `gh` CLI. Prompts for the repo, pushes to
// gh-pages, and reports the URL. Pages can take ~1 min to go live after the first publish.
// A site hosts MANY documents: each notebook publishes to its own /<slug>/, and the repo's root
// index.html is a generated blog page linking to all of them. Publishing is ADDITIVE — it adds/updates
// just this doc and preserves the others already in the site.
function _slug(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''); }
async function publishSite() {
  const repo = ((document.getElementById('siterepo') || {}).value || '').trim();
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) { await alertDark('Enter the target repo as owner/name.'); return; }
  const isPrivate = ((document.getElementById('sitevis') || {}).value || 'public') === 'private';
  const create = !!(document.getElementById('sitecreate') || { checked: true }).checked;
  const theme = (document.getElementById('sitetheme') || {}).value || 'dark';
  const source = (document.getElementById('sitesource') || { checked: true }).checked ? '1' : '0';
  const bundle = !!(document.getElementById('siterunnable') || {}).checked;
  const outv = (document.getElementById('exoutputs') || {}).value || 'all';
  const siteTitle = ((document.getElementById('sitetitle') || {}).value || '').trim();
  const slug = _slug(((document.getElementById('siteslug') || {}).value || '').trim()) ||
               _slug((nbState && nbState.title) || (nbState && nbState.id) || '');
  // A notebook tagged `home` is the site's FRONT PAGE (publishes to the root, not a /<slug>/ card).
  const isHome = Array.isArray(nbState && nbState.cells) &&
    nbState.cells.some(c => c && Array.isArray(c.tags) && c.tags.includes('home'));
  // Preflight: additive publish — say whether this adds a new doc or updates one, and list the others.
  let pf;
  try {
    const pr = await fetch(_apipath('/api/publish-check'), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ repo: repo }) });
    pf = pr.ok ? await pr.json() : {};
  } catch (_) { pf = {}; }
  if (pf.gh === false) { await alertDark('The `gh` CLI was not found on the server. Install it and run `gh auth login`, then retry.'); return; }
  const docs = Array.isArray(pf.docs) ? pf.docs : [];
  const already = docs.find(d => d && d.slug === slug);
  let msg, ok = 'Publish', cls = 'primary';
  if (!pf.exists) {
    if (!create) { await alertDark('Repo ' + repo + ' does not exist, and “Create the repo if it doesn’t exist” is off.\n\nEnable it, or create the repo first.'); return; }
    msg = 'Create a NEW ' + (isPrivate ? 'private' : 'public') + ' repo ' + repo + ' as a site, and publish this notebook to /' + slug + '/.' +
      (isPrivate ? '\n\n⚠ GitHub Pages needs a PUBLIC repo on the free plan (private Pages requires GitHub Pro), so a private repo may not serve.' : '');
    ok = 'Create & publish';
  } else if (isHome) {
    msg = 'Publish the FRONT PAGE of the site ' + repo + ' (' + (pf.visibility || 'unknown') + '; visibility unchanged).\n\n' +
      'This notebook is tagged `home` — it becomes the site root, and its `docindex` cell shows the document listing.' +
      (docs.length ? '\n\n' + docs.length + ' document' + (docs.length === 1 ? '' : 's') + ' already in the site are preserved.' : '');
    ok = 'Publish front page';
  } else {
    const others = docs.filter(d => d && d.slug !== slug);
    msg = 'Publish to the site ' + repo + ' (' + (pf.visibility || 'unknown') + '; visibility unchanged).\n\n' +
      (already ? '↻ Updates the existing document “' + (already.title || slug) + '” at /' + slug + '/.'
               : '＋ Adds a new document at /' + slug + '/.') +
      (others.length ? '\n\n' + others.length + ' other document' + (others.length === 1 ? '' : 's') + ' in this site are preserved:\n· ' +
        others.slice(0, 6).map(d => d.title || d.slug).join('\n· ') + (others.length > 6 ? '\n· …' : '')
        : (pf.hasGhPages ? '' : '\n\nA gh-pages branch will be created and Pages enabled.'));
    if (already) { ok = 'Update & publish'; }
  }
  if (!await confirmDark(msg, ok, cls)) return;
  showLoading('Building + pushing to GitHub Pages…');
  let result = null, err = null;
  try {
    const r = await fetch(_apipath('/api/publish'), { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repo: repo, slug: slug, siteTitle: siteTitle, private: isPrivate, create: create, theme: theme, outputs: outv, source: source, bundle: bundle }) });
    result = r.ok ? await r.json() : { error: await r.text() };
  } catch (e) { err = e; }
  hideLoading();                                          // drop the spinner BEFORE the result dialog
  if (err) { await alertDark('Publish failed: ' + err); return; }
  if (result.error) { await alertDark('Publish failed:\n' + result.error); return; }
  localStorage.setItem('slate_siterepo', repo);
  if (siteTitle) localStorage.setItem('slate_sitetitle', siteTitle);
  const docUrl = result.docUrl || result.url;
  const dlink = '<a href="' + _escHtml(docUrl) + '" target="_blank" rel="noopener" style="color:var(--accent)">' + _escHtml(docUrl) + '</a>';
  const slink = '<a href="' + _escHtml(result.url) + '" target="_blank" rel="noopener" style="color:var(--accent)">' + _escHtml(result.url) + '</a>';
  if (result.pagesEnabled === false) {
    // The site was pushed, but GitHub Pages isn't serving it (usually: private repo on the free plan).
    await dlg('⚠ Pushed to <code>gh-pages</code>, but GitHub Pages could not be enabled:<br><br>' +
      _escHtml(result.pagesError || 'unknown reason') + '<br><br>Once Pages is available this document will serve at ' + dlink + '.',
      [{ label: 'OK', value: true, cls: 'primary' }], { html: true });
    return;
  }
  const count = result.docCount ? (result.docCount + ' document' + (result.docCount === 1 ? '' : 's') + ' in the site.') : '';
  const headline = result.home ? 'Front page published ✓<br><br>Site: ' + slink
                               : 'Published ✓<br><br>This document: ' + dlink + '<br>Site index: ' + slink;
  const v = await dlg(headline + '<br><br>' + (result.created ? 'Repo created. ' : '') + count +
    '<br>GitHub Pages may take ~1 minute to go live on the first publish.',
    [{ label: 'Close', value: false }, { label: result.home ? 'Open site' : 'Open document', value: 'open', cls: 'primary' }], { html: true });
  if (v === 'open') window.open(result.home ? result.url : docUrl, '_blank', 'noopener');
}
// Self-contained single-source .jl: cells + full Project/Manifest + source (+ a git bundle when the
// project is a repo). Can take a moment (tars the env + source).
async function exportStandalone() {
  showLoading('Bundling environment + source…');
  try {
    const r = await fetch(_apipath('/api/export.standalone.jl'));
    if (!r.ok) { await alertDark('Standalone export failed:\n' + (await r.text())); return; }
    _saveBlob(await r.blob(), '.standalone.jl');
  } catch (e) { await alertDark('Standalone export failed: ' + e); }
  finally { hideLoading(); }
}
// Publication-quality PDF via Typst, driven by the modal's pdf* controls. Can take a few seconds
// (first run also fetches Typst packages) → loading overlay + blob-download. Figures embed as vector.
async function _runPdfExport() {
  const theme = document.getElementById('pdftheme').value;
  const [style, columns] = document.getElementById('pdflayout').value.split('|');
  const slides = style === 'slides';
  const body = document.getElementById('pdfbody').value;
  const code = document.getElementById('pdfcode').value;
  const params = document.getElementById('pdfparams').checked;
  const notes = slides && document.getElementById('pdfnotes').checked;
  const typst = document.getElementById('pdftypst').checked;
  ['pdftheme', 'pdflayout', 'pdfbody', 'pdfcode'].forEach(id => localStorage.setItem('slate_' + id, document.getElementById(id).value));
  localStorage.setItem('slate_pdfparams', params ? '1' : '0');
  localStorage.setItem('slate_pdftypst', typst ? '1' : '0');
  localStorage.setItem('slate_pdfnotes', notes ? '1' : '0');
  showLoading('Rendering PDF with Typst…');
  try {
    const qs = '?theme=' + theme + '&style=' + style + '&columns=' + columns + '&body=' + body + '&code=' + code + (params ? '&params=1' : '')
      + (slides ? '&layout=slides' : '') + (notes ? '&notes=1' : '') + _outputsQS();
    const r = await fetch(_apipath('/api/export.pdf') + qs);
    if (!r.ok) { await alertDark('PDF export failed:\n' + (await r.text())); return; }
    _saveBlob(await r.blob(), '.pdf');
    if (typst) {                                        // also fetch the editable Typst project bundle
      const tr = await fetch(_apipath('/api/export.typ') + qs);
      tr.ok ? _saveBlob(await tr.blob(), '.typ.tar.gz') : await alertDark('Typst bundle failed:\n' + (await tr.text()));
    }
  } catch (e) { await alertDark('PDF export failed: ' + e); }
  finally { hideLoading(); }
}
// ── The unified modal ─────────────────────────────────────────────────────────
function _exFormat() { return document.getElementById('exfmt').value; }
function closeExportModal() { document.getElementById('exportbg').classList.remove('show'); }
// Show the speaker-notes row only for the slides layout (PDF only).
function _pdfSyncSlides() {
  const slides = (document.getElementById('pdflayout').value || '').startsWith('slides');
  const row = document.getElementById('pdfnotesrow');
  if (row) row.style.display = (_exFormat() === 'pdf' && slides) ? '' : 'none';
}
// Show only the rows for the selected format.
function _exSyncRows() {
  const f = _exFormat();
  document.querySelectorAll('#exportbg .exrow').forEach(el => { el.style.display = el.classList.contains('fmt-' + f) ? '' : 'none'; });
  if (f === 'pdf') _pdfSyncSlides();
}
function openExport(preset) {
  const fmt = preset === 'slides' ? 'pdf' : (localStorage.getItem('slate_exfmt') || 'html');
  document.getElementById('exfmt').value = fmt;
  ['pdftheme', 'pdflayout', 'pdfbody', 'pdfcode'].forEach(id => {
    const v = localStorage.getItem('slate_' + id); if (v != null) document.getElementById(id).value = v;
  });
  document.getElementById('pdfparams').checked = localStorage.getItem('slate_pdfparams') === '1';
  document.getElementById('pdftypst').checked = localStorage.getItem('slate_pdftypst') === '1';
  document.getElementById('pdfnotes').checked = localStorage.getItem('slate_pdfnotes') === '1';
  const hs = document.getElementById('htmlsource'); if (hs) hs.checked = localStorage.getItem('slate_htmlsource') !== '0';
  const hr = document.getElementById('htmlrunnable'); if (hr) hr.checked = localStorage.getItem('slate_htmlrunnable') === '1';
  const ms = document.getElementById('mdsource'); if (ms) ms.checked = localStorage.getItem('slate_mdsource') !== '0';
  const rm = document.getElementById('mdreadme'); if (rm) rm.checked = localStorage.getItem('slate_mdreadme') === '1';
  const sr = document.getElementById('siterepo'); if (sr && !sr.value) sr.value = localStorage.getItem('slate_siterepo') || '';
  const stt = document.getElementById('sitetitle'); if (stt && !stt.value) stt.value = localStorage.getItem('slate_sitetitle') || '';
  // Auto-fill this document's slug from the notebook title (editable). Pre-filled so publishing "just works".
  const ssl = document.getElementById('siteslug');
  if (ssl && !ssl.value) ssl.value = _slug((nbState && nbState.title) || (nbState && nbState.id) || '');
  const ss = document.getElementById('sitesource'); if (ss) ss.checked = localStorage.getItem('slate_sitesource') !== '0';
  const srn = document.getElementById('siterunnable'); if (srn) srn.checked = localStorage.getItem('slate_siterunnable') === '1';
  ['htmltheme', 'htmlcode', 'exoutputs', 'mdimg', 'sitetheme', 'sitevis'].forEach(id => { const el = document.getElementById(id), v = localStorage.getItem('slate_' + id); if (el && v != null) el.value = v; });
  if (preset === 'slides') document.getElementById('pdflayout').value = 'slides|1';
  document.getElementById('exfmt').onchange = _exSyncRows;
  document.getElementById('pdflayout').onchange = _exSyncRows;
  _exSyncRows();
  document.getElementById('exportbg').classList.add('show');
}
// `go`: false = cancel, true = primary export, 'copy' = Markdown-to-clipboard.
function closeExport(go) {
  if (!go) { closeExportModal(); return; }
  const fmt = _exFormat(); localStorage.setItem('slate_exfmt', fmt);
  const ex = document.getElementById('exoutputs'); if (ex) localStorage.setItem('slate_exoutputs', ex.value);
  closeExportModal();
  if (fmt === 'html') {
    const hs = document.getElementById('htmlsource'); localStorage.setItem('slate_htmlsource', hs && hs.checked ? '1' : '0');
    const hr = document.getElementById('htmlrunnable'); if (hr) localStorage.setItem('slate_htmlrunnable', hr.checked ? '1' : '0');
    ['htmltheme', 'htmlcode'].forEach(id => { const el = document.getElementById(id); if (el) localStorage.setItem('slate_' + id, el.value); });
    return exportHtml(true);
  }
  if (fmt === 'markdown') {
    const ms = document.getElementById('mdsource'); localStorage.setItem('slate_mdsource', ms && ms.checked ? '1' : '0');
    const rm = document.getElementById('mdreadme'); localStorage.setItem('slate_mdreadme', rm && rm.checked ? '1' : '0');
    const mi = document.getElementById('mdimg'); if (mi) localStorage.setItem('slate_mdimg', mi.value);
    return exportMarkdown(go === 'copy' ? 'copy' : 'file');
  }
  if (fmt === 'website') {
    ['sitetheme', 'sitevis'].forEach(id => { const el = document.getElementById(id); if (el) localStorage.setItem('slate_' + id, el.value); });
    const ss = document.getElementById('sitesource'); if (ss) localStorage.setItem('slate_sitesource', ss.checked ? '1' : '0');
    const srn = document.getElementById('siterunnable'); if (srn) localStorage.setItem('slate_siterunnable', srn.checked ? '1' : '0');
    return go === 'publish' ? publishSite() : exportSite();
  }
  if (fmt === 'standalone') return exportStandalone();
  return _runPdfExport();
}
// Back-compat entry points (palette / keys): open the unified modal, PDF preselecting the deck.
function exportPdf(preset) { return openExport(preset === 'slides' ? 'slides' : undefined); }
function exportSlidesPdf() { return openExport('slides'); }

