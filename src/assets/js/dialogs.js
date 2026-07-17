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
// Run EVERY cell (force), keeping the live worker/namespace — the notebook top-to-bottom.
async function rerunAll(){ updateStates(await api('POST', '/api/rerun-all', {})); }
// Run the given cell and every code cell BELOW it (positional), forced, in order.
async function runCellAndBelow(id){
  if (!id) return;
  const ids = cellIds(); const i = ids.indexOf(id); if (i < 0) return;
  for (let j = i; j < ids.length; j++) { const c = _cellById(ids[j]); if (c && c.kind === 'code') await runCell(ids[j], true); }
}
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
  if ((document.getElementById('htmlrunnable') || {}).checked) {
    parts.push('bundle=1');
    if ((document.getElementById('htmlhistory') || {}).checked) parts.push('history=1');   // ship full git history
    const mp = _memoParam(); if (mp !== '') parts.push('memo=' + mp);   // precomputed-results budget for the embedded bundle
  }
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
// Slugify a title/name into a URL-safe path segment (shared by the publish flow).
function _slug(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''); }
// Self-contained single-source .jl: cells + full Project/Manifest + source (+ a git bundle when the
// project is a repo). Can take a moment (tars the env + source).
async function exportStandalone() {
  showLoading('Bundling environment + source…');
  try {
    const mp = _memoParam();
    const r = await fetch(_apipath('/api/export.standalone.jl') + (mp === '' ? '' : '?memo=' + mp));
    if (!r.ok) { await alertDark('Standalone export failed:\n' + (await r.text())); return; }
    _saveBlob(await r.blob(), '.standalone.jl');
  } catch (e) { await alertDark('Standalone export failed: ' + e); }
  finally { hideLoading(); }
}
// ── Precomputed-results (memo) quality slider ─────────────────────────────────
// The standalone / runnable-HTML formats can embed THIS notebook's memoizable cell results so it
// springs to life on import (expensive cells RESTORE instead of recompute). The slider is a byte
// BUDGET over the density-ranked catalog (compute-saved-per-byte): drag it down and only the
// densest entries survive. The client mirrors the server's greedy fill so the live readout ("N
// results · size · seconds saved") matches exactly what ships.
let _memoCat = null;   // { entries:[{cell,bytes,ms}], total_bytes, total_ms } — densest first
async function _memoLoadCatalog() {
  _memoCat = null;
  const ro = document.getElementById('memoreadout'); if (ro) ro.textContent = 'measuring…';
  try { const r = await fetch(_apipath('/api/memo-catalog')); if (r.ok) _memoCat = await r.json(); } catch (_) {}
  _memoSyncReadout();
}
function _memoPlan() {   // {count, bytes, ms, total} at the current slider budget
  const q = +((document.getElementById('memoquality') || {}).value) || 0;
  const ents = (_memoCat && _memoCat.entries) || [];
  const budget = (q / 100) * ((_memoCat && _memoCat.total_bytes) || 0);
  let count = 0, bytes = 0, ms = 0;
  for (const e of ents) { if (bytes + e.bytes > budget) continue; count++; bytes += e.bytes; ms += e.ms || 0; }
  return { count, bytes, ms, total: ents.length };
}
function _fmtBytes(n) { return n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB'; }
function _memoSyncReadout() {
  const ro = document.getElementById('memoreadout'); if (!ro) return;
  const mq = document.getElementById('memoquality'); if (mq) localStorage.setItem('slate_memoquality', mq.value);
  if (!_memoCat || !(_memoCat.entries || []).length) { ro.innerHTML = 'no cacheable results in this notebook'; return; }
  const p = _memoPlan();
  if (p.count === 0) { ro.innerHTML = '<b>off</b> — cells recompute on import'; return; }
  const s = p.ms / 1000;
  ro.innerHTML = `<b>${p.count}</b> of ${p.total} · <b>${_fmtBytes(p.bytes)}</b> · saves ~${s < 10 ? s.toFixed(1) : Math.round(s)} s`;
}
// The `memo=<MB>` value for the export URL: "" = all (slider max / nothing to embed), "0" = none,
// else the budget in MB (server re-derives bytes and fills densest-first within it).
function _memoParam() {
  const q = +((document.getElementById('memoquality') || {}).value);
  if (!_memoCat || !(_memoCat.entries || []).length) return '';
  if (q >= 100) return '';
  if (q <= 0) return '0';
  return (((q / 100) * (_memoCat.total_bytes || 0)) / 1048576).toFixed(3);
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
  // The bundle-only rows (git history + precomputed results) apply only to a RUNNABLE html page —
  // hide them when html isn't runnable, where they'd have nowhere to embed.
  if (f === 'html') {
    const run = (document.getElementById('htmlrunnable') || {}).checked;
    ['htmlhistory', 'memorow'].forEach(id => {
      const el = document.getElementById(id); const row = el && el.closest('.exrow');
      if (row) row.style.display = run ? '' : 'none';
    });
  }
  // Standalone / runnable-HTML can embed precomputed results — measure the catalog once the row shows.
  if ((f === 'standalone' || f === 'html') && _memoCat === null) _memoLoadCatalog();
}
// Two separate flows, deliberately: LIVE SITES (github/s3/r2/rsync/cloudflare/netlify) are a
// re-pushable multiselect; ZENODO is a distinct "mint a permanent DOI version" action (immutable —
// you can't edit/delete it), so it's split out with its own warning below.
const _STATIC_KINDS = ['github-pages', 's3', 'r2', 'rsync', 'cloudflare-pages', 'netlify'];
const _NEW_SITE = '__new_site__';
let _siteTargets = [], _sitePickList = [];
// Populate the "Into site" picker from saved sites, plus available destinations (for a new site) and
// Zenodo archive targets (a separate permanent-DOI flow). Site-first: you publish INTO a site, and the
// site's one canonical build is what syncs to its destinations.
async function _loadSitePicker() {
  const sel = document.getElementById('sitepick'); if (!sel) return;
  try {
    const v = await (await fetch('/api/publish/ledger', { cache: 'no-store' })).json();
    _siteTargets = v.targets || []; _sitePickList = v.sites || [];
  } catch (e) { _siteTargets = []; _sitePickList = []; }
  const remembered = localStorage.getItem('slate_site') || '';
  sel.innerHTML = _sitePickList.map(s =>
    '<option value="' + _escHtml(s.name) + '"' + (s.name === remembered ? ' selected' : '') + '>' + _escHtml(s.name) + '</option>').join('') +
    '<option value="' + _NEW_SITE + '"' + (_sitePickList.length ? '' : ' selected') + '>＋ New site…</option>';
  // Zenodo archive targets (separate, permanent)
  const zhost = document.getElementById('sitezenodo');
  if (zhost) {
    const zt = _siteTargets.filter(t => t.kind === 'zenodo');
    zhost.innerHTML = zt.length ? zt.map((t, i) =>
      '<label class="pubpick"><input type="radio" name="zenodotgt" value="' + _escHtml(t.name) + '"' + (i === 0 ? ' checked' : '') + '/>' +
      '<span class="publ">' + _escHtml(t.name) + '</span> <span class="pubdim">' + (t.config.sandbox ? 'sandbox' : 'zenodo') + '</span></label>').join('')
      : '<div class="pubdim" style="font-size:.78rem">No Zenodo target — add one in the manager (with your token in Secrets) to mint a citable DOI.</div>';
  }
  _onSitePick();
}
// Chip markup for a destination name (inline-styled — no extra CSS needed).
function _destChip(n) { return '<span style="display:inline-block;padding:1px 8px;border-radius:10px;border:1px solid var(--border);color:var(--dim);font-size:.72rem;margin:0 4px 4px 0">' + _escHtml(n) + '</span>'; }
// React to the site selection: a NEW site reveals the name field + a destination checklist; an EXISTING
// site shows its configured destinations (read-only — edit them in the manager).
function _onSitePick() {
  const sel = document.getElementById('sitepick'); if (!sel) return;
  const isNew = sel.value === _NEW_SITE;
  const nr = document.getElementById('sitenewrow'); if (nr) nr.style.display = isNew ? '' : 'none';
  const dest = document.getElementById('sitedests'); if (!dest) return;
  if (isNew) {
    const deployable = _siteTargets.filter(t => _STATIC_KINDS.indexOf(t.kind) >= 0);
    dest.innerHTML = deployable.length ? deployable.map(t => {
      const d = t.kind === 'github-pages' ? (t.config.repo || '') : (t.config.dest || t.config.url || t.config.project || t.config.siteId || '');
      return '<label class="pubpick"><input type="checkbox" class="sitedest" value="' + _escHtml(t.name) + '"/>' +
        '<span class="publ">' + _escHtml(t.name) + '</span> <span class="pubdim">' + _escHtml(t.kind) + '</span>' +
        ' <span class="pubdim" style="font-family:monospace;font-size:.76rem">' + _escHtml(d) + '</span></label>';
    }).join('') : '<div class="pubdim" style="font-size:.8rem">No destinations yet — leave empty for a local-only site, or add targets in the manager (☰ → 🗂).</div>';
  } else {
    const s = _sitePickList.filter(x => x.name === sel.value)[0] || { targets: [] };
    dest.innerHTML = (s.targets || []).length
      ? (s.targets.map(_destChip).join('') + '<span class="pubdim" style="font-size:.76rem">— edit destinations in the manager</span>')
      : '<span class="pubdim" style="font-size:.8rem">Local-only (no destinations). Add some in the manager, then ▶ Sync.</span>';
  }
}
window._onSitePick = _onSitePick;

// Shared SSE runner for /api/{id}/publish-run — streams per-target progress into the dialog log.
// Used by the Zenodo archive flow (a direct per-target publish, not a site build).
let _pubDone = false;
function _streamPublish(names, buildOpts) {
  const q = new URLSearchParams(Object.assign({ targets: names.join(',') }, buildOpts || {}));
  _streamSSE(_apipath('/api/publish-run') + '?' + q.toString());
}
// SSE runner for /api/{id}/site-publish?site=… — build into the site + sync all destinations.
function _streamSite(site, buildOpts) {
  const q = new URLSearchParams(Object.assign({ site: site }, buildOpts || {}));
  _streamSSE(_apipath('/api/site-publish') + '?' + q.toString());
}
// Publish-button + Cancel-label lifecycle, so the dialog always looks honest about what's happening.
// 'busy' disables Publish with a spinner + "Publishing…"; 'done'/'retry' re-enable it with a clear
// next-step label — never a plain, re-clickable "Publish" mid-run, nor an ambiguous state once it
// finishes. On success Cancel becomes "Close" (nothing left to cancel). `_resetPubUi` restores idle.
function _setPubBtn(state) {
  const btn = document.getElementById('sitepublishbtn'); if (!btn) return;
  if (!btn.dataset.idle) btn.dataset.idle = btn.textContent;      // remember "☁ Publish into site"
  btn.disabled = state === 'busy';
  btn.classList.toggle('busy', state === 'busy');
  btn.textContent = state === 'busy' ? 'Publishing…' : state === 'done' ? '☁ Publish again'
    : state === 'retry' ? '↻ Retry publish' : (btn.dataset.idle || btn.textContent);
}
function _setCancelLabel(txt) { const c = document.getElementById('excancel'); if (c) c.textContent = txt; }
function _resetPubUi() {
  _setPubBtn('idle'); _setCancelLabel('Cancel');
  const row = document.getElementById('sitepubrow'); if (row) row.style.display = 'none';
}

// The actual EventSource plumbing shared by both: stream status/log into the dialog log panel, and
// drive the button lifecycle — immediate feedback the moment it starts (spinner + a "Starting…" line
// so the panel is never blank), and a clear terminal state (a clickable site link) when it finishes.
function _streamSSE(url) {
  const row = document.getElementById('sitepubrow'), log = document.getElementById('sitepublog');
  row.style.display = ''; log.innerHTML = ''; _pubDone = false;
  _setPubBtn('busy');                                             // immediate: disabled + spinner + "Publishing…"
  try { row.scrollIntoView({ block: 'center' }); } catch (e) {}   // bring the log into view in the tall dialog
  const line = (t, c) => { const d = document.createElement('div'); d.className = 'publogln ' + (c || ''); d.textContent = t; log.appendChild(d); log.scrollTop = log.scrollHeight; return d; };
  line('Starting…', 'st');                                        // instant status so nothing looks stuck
  const linkLine = u => { if (!u) return; const d = line('↗ ', 'ok'); const a = document.createElement('a'); a.href = u; a.target = '_blank'; a.rel = 'noopener'; a.textContent = u; d.appendChild(a); log.scrollTop = log.scrollHeight; };
  const es = new EventSource(url);
  es.addEventListener('status', e => line(e.data, 'st'));
  es.addEventListener('log', e => line(e.data));
  es.addEventListener('done', e => {
    _pubDone = true; es.close();
    let d = {}; try { d = JSON.parse(e.data); } catch (_) {}
    const ok = d.ok || d.localOnly;
    line(d.localOnly ? '✓ Built locally (no destinations to sync)' : d.ok ? '✓ Done' : 'Finished with errors', ok ? 'ok' : 'err');
    if (ok) linkLine(d.url || ((d.results || []).map(r => r && r.url).filter(Boolean))[0]);
    _setPubBtn(ok ? 'done' : 'retry'); if (ok) _setCancelLabel('Close');
    toast(ok ? 'Done' : 'Finished with errors', 4500, ok ? '' : 'warn');
  });
  es.addEventListener('failed', e => { _pubDone = true; es.close(); line('✗ ' + e.data, 'err'); _setPubBtn('retry'); });
  es.onerror = () => { if (_pubDone) return; _pubDone = true; line('✗ connection lost', 'err'); _setPubBtn('retry'); try { es.close(); } catch (_) {} };
}

// SITE-FIRST publish — render this notebook into the chosen site's canonical build, then sync that
// build to every destination the site deploys to (create the site first if it's new).
async function publishToSite() {
  const sel = document.getElementById('sitepick'); if (!sel) return;
  let site = sel.value;
  let dests;
  if (site === _NEW_SITE) {
    site = ((document.getElementById('sitenewname') || {}).value || '').trim();
    if (!site) { await alertDark('Name the new site (e.g. “portfolio”).'); return; }
    dests = Array.from(document.querySelectorAll('.sitedest:checked')).map(c => c.value);
    try {
      await fetch('/api/publish/site', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: site, targets: dests }) });
    } catch (e) { await alertDark('Could not create the site.'); return; }
  } else {
    const existing = _sitePickList.filter(x => x.name === site)[0] || { targets: [] };
    dests = existing.targets || [];
  }
  const where = dests.length ? ('\n\nDeploys to:\n· ' + dests.join('\n· ')) : '\n\n(local-only staging — no destinations yet; add some in the manager, then ▶ Sync)';
  if (!await confirmDark('Publish “' + ((nbState && nbState.title) || 'this notebook') + '” into site “' + site + '”.' + where, 'Publish')) return;
  localStorage.setItem('slate_site', site);
  // Remember the publish options so the dialog reopens with the same choices (openExport reads these).
  const _stt = document.getElementById('sitetheme'); if (_stt) localStorage.setItem('slate_sitetheme', _stt.value);
  localStorage.setItem('slate_sitesource', (document.getElementById('sitesource') || {}).checked ? '1' : '0');
  localStorage.setItem('slate_siterunnable', (document.getElementById('siterunnable') || {}).checked ? '1' : '0');
  localStorage.setItem('slate_sitehistory', (document.getElementById('sitehistory') || {}).checked ? '1' : '0');
  const slug = _slug(((document.getElementById('siteslug') || {}).value || '').trim()) || _slug((nbState && nbState.title) || (nbState && nbState.id) || '');
  _streamSite(site, {
    slug: slug, siteTitle: ((document.getElementById('sitetitle') || {}).value || '').trim(),
    theme: (document.getElementById('sitetheme') || {}).value || 'dark',
    outputs: (document.getElementById('exoutputs') || {}).value || 'all',
    source: (document.getElementById('sitesource') || {}).checked ? '1' : '0',
    bundle: (document.getElementById('siterunnable') || {}).checked ? '1' : '0',
    history: (document.getElementById('sitehistory') || {}).checked ? '1' : '0'
  });
}
window.publishToSite = publishToSite;

// ZENODO — deliberate, permanent: mint a citable DOI version (immutable; can't edit/delete).
async function archiveZenodo() {
  const sel = document.querySelector('input[name=zenodotgt]:checked');
  if (!sel) { await alertDark('No Zenodo target configured. Add one in the Publishing manager (with your Zenodo token in Secrets).'); return; }
  const name = sel.value;
  if (!await confirmDark('Archive “' + ((nbState && nbState.title) || 'this notebook') +
      '” to Zenodo (“' + name + '”).\n\nThis mints a PERMANENT, citable DOI version — you cannot edit or delete it afterward. ' +
      'Do this at a milestone (a release, a paper), not for a small tweak.', 'Mint DOI', 'danger')) return;
  // archive:1 — the server treats deposits as a distinct verb from site publishing (see run_publish)
  _streamPublish([name], { archive: '1', history: (document.getElementById('sitehistory') || {}).checked ? '1' : '0' });
}
window.archiveZenodo = archiveZenodo;

// Publish shortcut → the export dialog on its Website tab (publishing IS Export → Website).
function openPublish() { openExport('website'); }
window.openPublish = openPublish;
function openExport(preset) {
  let fmt = preset === 'slides' ? 'pdf' : preset === 'website' ? 'website' : (localStorage.getItem('slate_exfmt') || 'html');
  if (preset !== 'website' && fmt === 'website') fmt = 'html';   // Website is Publish now, not an Export format
  document.getElementById('exfmt').value = fmt;
  ['pdftheme', 'pdflayout', 'pdfbody', 'pdfcode'].forEach(id => {
    const v = localStorage.getItem('slate_' + id); if (v != null) document.getElementById(id).value = v;
  });
  document.getElementById('pdfparams').checked = localStorage.getItem('slate_pdfparams') === '1';
  document.getElementById('pdftypst').checked = localStorage.getItem('slate_pdftypst') === '1';
  document.getElementById('pdfnotes').checked = localStorage.getItem('slate_pdfnotes') === '1';
  const hs = document.getElementById('htmlsource'); if (hs) hs.checked = localStorage.getItem('slate_htmlsource') !== '0';
  const hr = document.getElementById('htmlrunnable'); if (hr) hr.checked = localStorage.getItem('slate_htmlrunnable') === '1';
  const hh = document.getElementById('htmlhistory'); if (hh) hh.checked = localStorage.getItem('slate_htmlhistory') === '1';
  const ms = document.getElementById('mdsource'); if (ms) ms.checked = localStorage.getItem('slate_mdsource') !== '0';
  const rm = document.getElementById('mdreadme'); if (rm) rm.checked = localStorage.getItem('slate_mdreadme') === '1';
  const stt = document.getElementById('sitetitle'); if (stt && !stt.value) stt.value = localStorage.getItem('slate_sitetitle') || '';
  // Auto-fill this document's slug from the notebook title (editable). Pre-filled so publishing "just works".
  const ssl = document.getElementById('siteslug');
  if (ssl && !ssl.value) ssl.value = (nbState && nbState.publishSlug) || _slug((nbState && nbState.title) || (nbState && nbState.id) || '');
  const ss = document.getElementById('sitesource'); if (ss) ss.checked = localStorage.getItem('slate_sitesource') !== '0';
  const srn = document.getElementById('siterunnable'); if (srn) srn.checked = localStorage.getItem('slate_siterunnable') === '1';
  const sh = document.getElementById('sitehistory'); if (sh) sh.checked = localStorage.getItem('slate_sitehistory') === '1';
  ['htmltheme', 'htmlcode', 'exoutputs', 'mdimg', 'sitetheme'].forEach(id => { const el = document.getElementById(id), v = localStorage.getItem('slate_' + id); if (el && v != null) el.value = v; });
  if (preset === 'slides') document.getElementById('pdflayout').value = 'slides|1';
  _memoCat = null;                                          // re-measure precomputed results per dialog open
  const mq = document.getElementById('memoquality'); if (mq) mq.value = localStorage.getItem('slate_memoquality') || '100';
  document.getElementById('exfmt').onchange = _exSyncRows;
  document.getElementById('pdflayout').onchange = _exSyncRows;
  _loadSitePicker();             // populate the "Into site" picker from saved sites + destinations
  _exSyncRows();
  // Publish mode (opened via ☁ Publish…): focus the dialog on the Website flow — retitle it and hide
  // the format picker, so it reads as "put this online", clearly distinct from Export's format menu.
  const _pub = preset === 'website';
  document.getElementById('exhdr').textContent = _pub ? 'Publish' : 'Export';
  document.getElementById('exsub').textContent = _pub ? '— publish this notebook to the web' : '— render or package this notebook';
  document.getElementById('exfmtrow').style.display = _pub ? 'none' : '';
  // A notebook tagged `home` becomes the site's FRONT PAGE (renders to the root, not a /<slug>/ doc), so
  // the Document-path field is irrelevant and the instructions differ. Detect it and adjust the dialog.
  const _home = _isHomeNotebook();
  const _slugRow = document.getElementById('siteslugrow'); if (_slugRow) _slugRow.style.display = _home ? 'none' : '';
  const _hint = document.getElementById('sitehint');
  if (_hint) {
    if (!_hint.dataset.doc) _hint.dataset.doc = _hint.innerHTML;   // capture the default (per-document) hint once
    _hint.innerHTML = _home
      ? 'This notebook is tagged <code>home</code>, so it becomes the site’s <b>front page</b> — it renders to the site root (its <code>docindex</code> cell lists the other documents), not a <code>/&lt;path&gt;/</code> page. Publishing then syncs the whole build to the site’s destinations.'
      : _hint.dataset.doc;
  }
  _resetPubUi();   // idle button + "Cancel" label + no empty log, so a reopened dialog isn't stuck on a prior run's state
  document.getElementById('exportbg').classList.add('show');
}
// A notebook is the site's front page when any cell is tagged `home` (matches the server's _home_notebook).
function _isHomeNotebook() {
  return Array.isArray(nbState && nbState.cells) &&
    nbState.cells.some(c => c && Array.isArray(c.tags) && c.tags.includes('home'));
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
    const hh = document.getElementById('htmlhistory'); if (hh) localStorage.setItem('slate_htmlhistory', hh.checked ? '1' : '0');
    ['htmltheme', 'htmlcode'].forEach(id => { const el = document.getElementById(id); if (el) localStorage.setItem('slate_' + id, el.value); });
    return exportHtml(true);
  }
  if (fmt === 'markdown') {
    const ms = document.getElementById('mdsource'); localStorage.setItem('slate_mdsource', ms && ms.checked ? '1' : '0');
    const rm = document.getElementById('mdreadme'); localStorage.setItem('slate_mdreadme', rm && rm.checked ? '1' : '0');
    const mi = document.getElementById('mdimg'); if (mi) localStorage.setItem('slate_mdimg', mi.value);
    return exportMarkdown(go === 'copy' ? 'copy' : 'file');
  }
  if (fmt === 'website') return;   // publishing runs via the ☁ button → publishToSite(), not through closeExport
  if (fmt === 'standalone') return exportStandalone();
  return _runPdfExport();
}
// Back-compat entry points (palette / keys): open the unified modal, PDF preselecting the deck.
function exportPdf(preset) { return openExport(preset === 'slides' ? 'slides' : undefined); }
function exportSlidesPdf() { return openExport('slides'); }
// Dismiss the export modal on backdrop-click and Esc (parity with the settings/confirm modals).
// closeExport(false) = cancel: hide without persisting any option choices.
document.getElementById('exportbg').addEventListener('mousedown', e => { if (e.target.id === 'exportbg') closeExport(false); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && document.getElementById('exportbg').classList.contains('show')) { e.stopPropagation(); closeExport(false); }
}, true);

