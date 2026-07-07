// Notebook publishing panel — publish THIS notebook to one of your saved targets (or a new GitHub
// repo, owner auto-filled), with the familiar preflight confirmation, and see where it's already
// published (target · date · version). Managing targets/portfolios lives in the standalone manager
// (front page). Classic global-scope script (see notebook.html load order).
(function () {
  'use strict';
  let _view = null;   // ledger view (targets, ghUser)
  let _doc = null;    // this notebook's doc info (docId, slug, events)

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const el = id => document.getElementById(id);

  function openPublishing() { el('pubbg').classList.add('show'); refresh(); }
  function closePublishing() { el('pubbg').classList.remove('show'); }
  window.openPublishing = openPublishing;
  window.closePublishing = closePublishing;

  async function refresh() { await Promise.all([loadLedger(), loadDoc()]); }
  async function loadLedger() {
    try { _view = await (await fetch('/api/publish/ledger', { cache: 'no-store' })).json(); }
    catch (e) { _view = { targets: [], ghUser: '' }; }
    renderTargetPick();
  }
  async function loadDoc() {
    try { _doc = await api('GET', '/api/publish/doc'); } catch (e) { _doc = null; }
    const t = el('pubdoctitle'); if (t) t.textContent = _doc ? ('— ' + (_doc.title || _doc.slug)) : '';
    renderHistory(); renderPlacement();
  }

  // Is THIS notebook the site's home/front page? (tagged `home` — the same rule publish_site uses.)
  function isHome() {
    return Array.isArray(nbState && nbState.cells) &&
      nbState.cells.some(c => c && Array.isArray(c.tags) && c.tags.includes('home'));
  }
  function ghTargets() { return ((_view && _view.targets) || []).filter(t => t.kind === 'github-pages'); }

  // ── pick a destination: a saved GitHub target, or a new repo under your account ─────────────────
  function renderTargetPick() {
    const ts = ghTargets(), user = (_view && _view.ghUser) || '';
    let h = ts.map((t, i) =>
      '<label class="pubpick"><input type="radio" name="pubtgt" value="saved:' + i + '"' + (i === 0 ? ' checked' : '') + '/>' +
      '<span class="publ">' + esc(t.name) + '</span> <span class="pubdim">' + esc(t.config.repo || '') + '</span></label>'
    ).join('');
    h += '<label class="pubpick"><input type="radio" name="pubtgt" value="new"' + (ts.length ? '' : ' checked') + '/>' +
      '<span>New GitHub repo</span> <span class="pubdim">' + (user ? esc(user) + '&nbsp;/' : 'owner/') + '</span>' +
      '<input id="pubnewrepo" class="pubinp" style="max-width:190px" placeholder="repo-name" onfocus="pubPickNew()"/></label>';
    el('pubtargetpick').innerHTML = h;
  }
  window.pubPickNew = function () { const r = document.querySelector('input[name=pubtgt][value=new]'); if (r) r.checked = true; };

  // The owner/name repo for the current selection ("" if incomplete).
  function selectedRepo() {
    const sel = document.querySelector('input[name=pubtgt]:checked');
    if (!sel) return '';
    if (sel.value === 'new') {
      const name = (el('pubnewrepo').value || '').trim(); if (!name) return '';
      if (name.includes('/')) return name;                       // they typed owner/name themselves
      const user = (_view && _view.ghUser) || '';
      return user ? user + '/' + name : name;
    }
    const t = ghTargets()[parseInt(sel.value.split(':')[1], 10)];
    return t ? (t.config.repo || '') : '';
  }

  function renderPlacement() {
    el('pubplacement').innerHTML = isHome()
      ? '🏠 Tagged <b>home</b> — publishes as the site\'s front page (root).'
      : 'Publishes as a card at <b>/' + esc((_doc && _doc.slug) || '') + '/</b> under the target\'s home page.';
  }

  // ── this doc's history, grouped by target: latest date + a version count ────────────────────────
  function renderHistory() {
    const evs = (_doc && _doc.events) || [];
    if (!evs.length) { el('pubhistory').innerHTML = '<div class="pubdim">Not published yet.</div>'; return; }
    const byT = {};
    evs.forEach(e => { (byT[e.target] = byT[e.target] || []).push(e); });   // events already newest-first
    el('pubhistory').innerHTML = Object.keys(byT).map(t => {
      const list = byT[t], latest = list[0];
      return '<div class="pubrow"><span class="publ">' + esc(t) + '</span>' +
        '<span class="pubchip ' + (latest.status === 'ok' ? 'ok' : 'err') + '">v' + list.length + '</span>' +
        '<span class="pubdim">' + esc((latest.ts || '').slice(0, 10)) + '</span>' +
        (latest.url ? ' <a class="publink" href="' + esc(latest.url) + '" target="_blank" rel="noopener">open</a>' : '') +
        (latest.doi ? ' <span class="pubdim">DOI ' + esc(latest.doi) + '</span>' : '') + '</div>';
    }).join('');
  }

  // ── publish: preflight → confirm → push (records to the ledger server-side) ──────────────────────
  async function runPublish() {
    const repo = selectedRepo();
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) { toast('Pick a target or enter a repo name', 4500, 'warn'); return; }
    let pf = {};
    try { pf = await api('POST', '/api/publish-check', { repo }); } catch (e) {}
    if (pf.gh === false) { alertDark('`gh` was not found on the server. Install it and run `gh auth login`, then retry.'); return; }
    const slug = (_doc && _doc.slug) || '', home = isHome();
    const docs = Array.isArray(pf.docs) ? pf.docs : [];
    const already = docs.find(d => d && d.slug === slug);
    const others = docs.filter(d => d && d.slug !== slug).length;
    let msg, ok;
    if (!pf.exists) {
      msg = 'Create a new public repo ' + repo + ' as a site and publish ' + (home ? 'its front page' : '/' + slug + '/') + '.';
      ok = 'Create & publish';
    } else if (home) {
      msg = 'Publish the FRONT PAGE of ' + repo + '.' + (docs.length ? '\n\n' + docs.length + ' document(s) already in the site are preserved.' : '');
      ok = 'Publish front page';
    } else {
      msg = (already ? '↻ Update the existing document at /' + slug + '/' : '＋ Add a new document at /' + slug + '/') + ' in ' + repo + '.' +
        (others ? '\n\n' + others + ' other document(s) preserved.' : '');
      ok = already ? 'Update & publish' : 'Publish';
    }
    if (!await confirmDark(msg, ok)) return;

    const log = el('pubprogress'); log.style.display = 'block';
    log.innerHTML = '<div class="publogln st">Building + pushing to GitHub Pages…</div>';
    const btn = el('pubrunbtn'); btn.disabled = true;
    let res = null, err = null;
    try {
      const r = await fetch(_apipath('/api/publish'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ repo, slug })
      });
      res = r.ok ? await r.json() : { error: await r.text() };
    } catch (e) { err = e; }
    btn.disabled = false;
    if (err || (res && res.error)) {
      log.innerHTML = '<div class="publogln err">✗ ' + esc(String(err || res.error)) + '</div>';
      return;
    }
    log.innerHTML = '<div class="publogln ok">✓ Published → ' + esc(res.url || '') + '</div>' +
      (res.pagesError ? '<div class="publogln err">' + esc(res.pagesError) + '</div>' : '');
    toast('Published');
    loadLedger(); loadDoc();
  }
  window.runPublish = runPublish;

  // backdrop-click + Esc to close; auto-open when reached with a #publish hash (front-page hand-off).
  document.addEventListener('DOMContentLoaded', () => {
    const bg = el('pubbg'); if (!bg) return;
    bg.addEventListener('mousedown', e => { if (e.target.id === 'pubbg') closePublishing(); });
    document.addEventListener('keydown', e => {
      if (e.key === 'Escape' && bg.classList.contains('show')) { e.stopPropagation(); closePublishing(); }
    }, true);
    if (location.hash === '#publish') {
      try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
      setTimeout(openPublishing, 400);
    }
  });
})();
