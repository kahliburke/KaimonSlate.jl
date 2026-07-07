// Publishing manager — a full-screen surface over the publish ledger: this document ↔ its targets ↔
// history, the shared target/secret config, and the local sites (folding in the old "Pages in site"
// pill list as compact rows). Classic global-scope script (see notebook.html load order); scoped
// endpoints go through api()/_apipath, global ledger/site endpoints through raw fetch.
(function () {
  'use strict';
  let _view = null;       // last /api/publish/ledger view (targets, secrets, availableKinds, backend)
  let _doc = null;        // this notebook's /api/{id}/publish/doc (docId, slug, assignedTargets, events)
  let _es = null;         // active publish EventSource

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const el = id => document.getElementById(id);
  const val = id => (el(id) ? el(id).value : '');

  function openPublishing() {
    el('pubbg').classList.add('show');
    refreshAll();
  }
  function closePublishing() {
    if (_es) { try { _es.close(); } catch (e) {} _es = null; }
    el('pubbg').classList.remove('show');
  }
  window.openPublishing = openPublishing;
  window.closePublishing = closePublishing;

  async function refreshAll() { await Promise.all([loadLedger(), loadDoc(), loadSites()]); }

  async function loadLedger() {
    try { _view = await (await fetch('/api/publish/ledger', { cache: 'no-store' })).json(); }
    catch (e) { _view = { documents: [], targets: [], sites: [], secretRefs: [], availableKinds: [] }; }
    const b = el('pubbackend'); if (b) b.textContent = _view.backend ? '— ledger: ' + _view.backend : '';
    renderTargets(); renderSecrets(); renderDocTargets();
  }
  async function loadDoc() {
    try { _doc = await api('GET', '/api/publish/doc'); } catch (e) { _doc = null; }
    renderDoc(); renderDocTargets(); renderHistory();
  }

  // ── this document ────────────────────────────────────────────────────────────────────────────
  function renderDoc() {
    const d = _doc || {};
    el('pubdoc').innerHTML =
      '<div class="pubrow"><span class="publ">' + esc(d.title || d.slug || '(untitled)') + '</span>' +
        '<span class="pubdim">' + esc(d.slug || '') + '</span></div>' +
      (d.sourceRepo ? '<div class="pubrow"><span class="pubdim">' + esc(d.sourceRepo) + ' / ' +
        esc(d.sourcePath || '') + '</span></div>' : '') +
      '<div class="pubrow"><span class="pubdim" style="font-size:.68rem">' + esc(d.docId || '') + '</span></div>';
  }
  function renderDocTargets() {
    const targets = (_view && _view.targets) || [];
    const assigned = new Set((_doc && _doc.assignedTargets) || []);
    const host = el('pubdoctargets');
    if (!targets.length) { host.innerHTML = '<span class="pubdim">No targets yet — add one under Targets →</span>'; return; }
    host.innerHTML = targets.map(t =>
      '<label class="pubtag"><input type="checkbox" class="pubtgt" value="' + esc(t.name) + '" ' +
      (assigned.has(t.name) ? 'checked' : '') + '/> ' + esc(t.name) +
      ' <span class="pubdim">' + esc(t.kind) + '</span></label>').join('');
  }

  async function runPublish() {
    const names = Array.from(document.querySelectorAll('.pubtgt:checked')).map(c => c.value);
    if (!names.length) { toast('Select at least one target', 4500, 'warn'); return; }
    try { _doc = await api('POST', '/api/publish/doc-targets', { targets: names }); } catch (e) {}
    const log = el('pubprogress'); log.style.display = 'block'; log.innerHTML = '';
    const btn = el('pubrunbtn'); btn.disabled = true;
    const line = (txt, cls) => {
      const d = document.createElement('div'); d.className = 'publogln ' + (cls || '');
      d.textContent = txt; log.appendChild(d); log.scrollTop = log.scrollHeight;
    };
    if (_es) { try { _es.close(); } catch (e) {} }
    const url = _apipath('/api/publish-run') + '?targets=' + encodeURIComponent(names.join(','));
    const es = new EventSource(url); _es = es;
    es.addEventListener('status', e => line(e.data, 'st'));
    es.addEventListener('log', e => line(e.data));
    es.addEventListener('done', e => {
      es.close(); _es = null; btn.disabled = false;
      let d = {}; try { d = JSON.parse(e.data); } catch (_) {}
      line(d.ok ? '✓ done' : 'finished with errors', d.ok ? 'ok' : 'err');
      toast(d.ok ? 'Published' : 'Publish finished with errors', 4500, d.ok ? '' : 'warn');
      loadDoc(); loadLedger();
    });
    es.addEventListener('failed', e => {
      es.close(); _es = null; btn.disabled = false; line('✗ ' + e.data, 'err');
      toast('Publish failed', 4500, 'warn');
    });
    es.onerror = () => { if (_es) { line('✗ connection lost', 'err'); btn.disabled = false; try { es.close(); } catch (_) {} _es = null; } };
  }
  window.runPublish = runPublish;

  // ── targets ────────────────────────────────────────────────────────────────────────────────────
  function cfgSummary(t) {
    const c = t.config || {};
    if (t.kind === 'github-pages') return c.repo || '';
    if (t.kind === 'zenodo') return (c.secretRef ? 'secret:' + c.secretRef : '') + (c.sandbox ? ' (sandbox)' : '');
    return c.dest || c.url || '';
  }
  function renderTargets() {
    const targets = (_view && _view.targets) || [];
    const kinds = (_view && _view.availableKinds) || ['github-pages', 's3', 'r2', 'rsync', 'zenodo'];
    const rows = targets.length ? targets.map(t =>
      '<div class="pubrow"><span class="publ">' + esc(t.name) + '</span> <span class="pubchip">' +
      esc(t.kind) + '</span> <span class="pubdim pubcfg">' + esc(cfgSummary(t)) + '</span>' +
      '<button class="pubmini" title="delete" onclick="pubDelTarget(\'' + esc(t.name) + '\')">✕</button></div>'
    ).join('') : '<div class="pubdim">None yet.</div>';
    const form =
      '<div class="pubform"><input id="pubtname" class="pubinp" placeholder="name (e.g. gh:site)"/>' +
      '<select id="pubtkind" class="pubinp" onchange="pubKindFields()">' +
      kinds.map(k => '<option value="' + esc(k) + '">' + esc(k) + '</option>').join('') + '</select>' +
      '<div id="pubtfields"></div>' +
      '<button class="pubmini primary" onclick="pubAddTarget()">+ Add / update target</button></div>';
    el('pubtargets').innerHTML = rows + form;
    pubKindFields();
  }
  // Field builders for the add-target form (ids prefixed pubf_ so readKindFields can pick them up).
  const fld = (id, ph) => '<input id="pubf_' + id + '" class="pubinp" placeholder="' + esc(ph) + '"/>';
  const chk = (id, label, on) => '<label class="pubtag"><input type="checkbox" id="pubf_' + id + '" ' +
    (on ? 'checked' : '') + '/> ' + esc(label) + '</label>';
  function refSelect(id, refs) {
    return '<select id="pubf_' + id + '" class="pubinp">' +
      '<option value="">— secret ref —</option>' +
      (refs || []).map(r => '<option value="' + esc(r) + '">' + esc(r) + '</option>').join('') + '</select>';
  }
  function pubKindFields() {
    const k = val('pubtkind');
    const refs = (_view && _view.secretRefs) || [];
    let h = '';
    if (k === 'github-pages') h = fld('repo', 'owner/name') + fld('branch', 'branch (default gh-pages)') +
      fld('subdir', 'subdir (optional)') + chk('private', 'Private repo') + chk('create', 'Create repo if missing', true);
    else if (k === 's3' || k === 'r2') h = fld('dest', 's3://bucket/prefix') + fld('url', 'public URL (optional)') +
      (k === 'r2' ? fld('endpoint', 'R2 endpoint URL') : '') + chk('delete', 'Mirror deletes', true);
    else if (k === 'rsync') h = fld('dest', 'user@host:/var/www/site') + fld('url', 'public URL (optional)') +
      chk('delete', 'Mirror deletes', true);
    else if (k === 'zenodo') h = refSelect('secretRef', refs) + chk('sandbox', 'Use Zenodo sandbox');
    el('pubtfields').innerHTML = h;
  }
  window.pubKindFields = pubKindFields;
  function readKindFields(kind) {
    const c = {};
    const put = (k, id) => { const v = (val('pubf_' + id) || '').trim(); if (v) c[k] = v; };
    const bool = (k, id) => { const e = el('pubf_' + id); if (e) c[k] = e.checked; };
    if (kind === 'github-pages') { put('repo', 'repo'); put('branch', 'branch'); put('subdir', 'subdir'); bool('private', 'private'); bool('create', 'create'); }
    else if (kind === 's3' || kind === 'r2') { put('dest', 'dest'); put('url', 'url'); put('endpoint', 'endpoint'); bool('delete', 'delete'); }
    else if (kind === 'rsync') { put('dest', 'dest'); put('url', 'url'); bool('delete', 'delete'); }
    else if (kind === 'zenodo') { put('secretRef', 'secretRef'); bool('sandbox', 'sandbox'); }
    return c;
  }
  async function pubAddTarget() {
    const name = val('pubtname').trim(), kind = val('pubtkind');
    if (!name) { toast('Target needs a name', 4500, 'warn'); return; }
    const config = readKindFields(kind);
    try {
      _view = await (await fetch('/api/publish/target', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, kind, config })
      })).json();
      toast('Target saved'); renderTargets(); renderDocTargets();
    } catch (e) { toast('Save failed', 4500, 'warn'); }
  }
  window.pubAddTarget = pubAddTarget;
  function pubDelTarget(name) {
    confirmDark('Delete target “' + name + '”? Published history is kept.', async () => {
      try {
        _view = await (await fetch('/api/publish/target-delete', {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name })
        })).json();
        renderTargets(); renderDocTargets();
      } catch (e) { toast('Delete failed', 4500, 'warn'); }
    });
  }
  window.pubDelTarget = pubDelTarget;

  // ── history ────────────────────────────────────────────────────────────────────────────────────
  function renderHistory() {
    const evs = (_doc && _doc.events) || [];
    el('pubhistory').innerHTML = evs.length ? evs.map(e =>
      '<div class="pubrow"><span class="pubdim">' + esc(e.ts) + '</span> <span class="pubchip ' +
      (e.status === 'ok' ? 'ok' : 'err') + '">' + esc(e.target) + '</span>' +
      (e.url ? ' <a class="publink" href="' + esc(e.url) + '" target="_blank" rel="noopener">open</a>' : '') +
      (e.doi ? ' <span class="pubdim">DOI ' + esc(e.doi) + '</span>' : '') +
      (e.commit ? ' <span class="pubdim">' + esc(String(e.commit).slice(0, 8)) + '</span>' : '') +
      '</div>').join('') : '<div class="pubdim">No publishes yet.</div>';
  }

  // ── secrets (write-only; values never leave the config home) ───────────────────────────────────
  function renderSecrets() {
    const refs = (_view && _view.secretRefs) || [];
    const rows = refs.length ? refs.map(r =>
      '<div class="pubrow"><span class="publ">' + esc(r) + '</span> <span class="pubchip ok">set</span>' +
      '<button class="pubmini" onclick="pubDelSecret(\'' + esc(r) + '\')">✕</button></div>').join('')
      : '<div class="pubdim">None.</div>';
    const form =
      '<div class="pubform"><input id="pubsref" class="pubinp" placeholder="ref name (e.g. zenodo-token)"/>' +
      '<input id="pubsval" class="pubinp" type="password" placeholder="secret value"/>' +
      '<button class="pubmini primary" onclick="pubSetSecret()">Save secret</button></div>' +
      '<div class="pubdim" style="font-size:.72rem">Stored only in your config home (chmod 600) — never in the ledger/gist.</div>';
    el('pubsecrets').innerHTML = rows + form;
  }
  async function pubSetSecret() {
    const ref = val('pubsref').trim(), value = val('pubsval');
    if (!ref) { toast('Secret needs a ref name', 4500, 'warn'); return; }
    await pubSecretPost(ref, value); toast('Secret saved');
  }
  window.pubSetSecret = pubSetSecret;
  function pubDelSecret(ref) {
    confirmDark('Delete secret “' + ref + '”?', async () => { await pubSecretPost(ref, ''); });
  }
  window.pubDelSecret = pubDelSecret;
  async function pubSecretPost(ref, value) {
    try {
      const r = await (await fetch('/api/publish/secret', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ref, value })
      })).json();
      if (_view) _view.secretRefs = r.refs || [];
      renderSecrets(); pubKindFields();
    } catch (e) { toast('Secret save failed', 4500, 'warn'); }
  }

  // ── local sites (folds in the old export-dialog "Pages in site" list as compact rows) ──────────
  async function loadSites() {
    let sites = [];
    try { const d = await (await fetch('/api/sites', { cache: 'no-store' })).json(); sites = d.sites || []; }
    catch (e) {}
    const host = el('pubsites');
    if (!sites.length) { host.innerHTML = '<div class="pubdim">No local sites. Build one via Export → Website (local build).</div>'; return; }
    host.innerHTML = sites.map(s =>
      '<div class="pubsite"><div class="pubrow"><span class="publ">' + esc(s) + '</span>' +
      '<a class="publink" href="/sites/' + encodeURIComponent(s) + '/" target="_blank" rel="noopener">open</a></div>' +
      '<div class="pubpages" id="pubpages_' + esc(s) + '"><span class="pubdim">…</span></div></div>').join('');
    sites.forEach(loadSitePages);
  }
  async function loadSitePages(site) {
    let docs = [];
    try { docs = await (await fetch('/api/site-docs?name=' + encodeURIComponent(site), { cache: 'no-store' })).json(); }
    catch (e) {}
    const host = el('pubpages_' + site); if (!host) return;
    host.innerHTML = (docs && docs.length) ? docs.map(d =>
      '<div class="pubrow pubsub2"><span>' + esc(d.title || d.slug) + '</span>' +
      '<button class="pubmini" onclick="pubUnexport(\'' + esc(site) + '\',\'' + esc(d.slug) + '\')">remove</button></div>'
    ).join('') : '<div class="pubdim">no pages</div>';
  }
  function pubUnexport(site, slug) {
    confirmDark('Remove “' + slug + '” from local site “' + site + '”?', async () => {
      try {
        await fetch('/api/site-unexport', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: site, slug })
        });
        loadSitePages(site);
      } catch (e) { toast('Remove failed', 4500, 'warn'); }
    });
  }
  window.pubUnexport = pubUnexport;

  // backdrop-click + Esc to close (mirrors settings.js)
  document.addEventListener('DOMContentLoaded', () => {
    const bg = el('pubbg'); if (!bg) return;
    bg.addEventListener('mousedown', e => { if (e.target.id === 'pubbg') closePublishing(); });
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && bg.classList.contains('show')) { e.stopPropagation(); closePublishing(); }
    }, true);
  });
})();
