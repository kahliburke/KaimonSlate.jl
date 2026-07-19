// Notebook publishing panel — publish THIS notebook to one of your saved targets (or a new GitHub
// repo, owner auto-filled), with the familiar preflight confirmation, and see where it's already
// published (target · date · version). Managing targets/portfolios lives in the standalone manager
// (front page). Classic global-scope script (see notebook.html load order).
(function () {
  'use strict';
  let _view = null;   // ledger view (targets, ghUser)
  let _doc = null;    // this notebook's doc info (docId, slug, events)
  let _sitesData = null;   // this notebook's per-site membership/front-page state (for the confirm-on-replace check)

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const el = id => document.getElementById(id);

  function openPublishing() { el('pubbg').classList.add('show'); refresh(); }
  function closePublishing() { el('pubbg').classList.remove('show'); }
  window.openPublishing = openPublishing;
  window.closePublishing = closePublishing;

  async function refresh() { pubRestoreOpts(); await Promise.all([loadLedger(), loadDoc(), loadSites()]); }

  // Publish build options (Run-live bundle / source / git history / theme) — shared with the website
  // EXPORT dialog via the same localStorage keys, so the two flows stay in sync.
  function pubBuildOpts() {
    const ck = id => !!(el(id) && el(id).checked);
    const val = id => (el(id) && el(id).value) || '';
    // Theme picker (As-is / Light / Dark) resolves the same way as the export dialog: page-chrome theme,
    // Slate chart PALETTE, and whether native Makie figures are re-rendered under it (override).
    const pick = val('pubopt_theme') || 'asis';
    const t = (typeof _resolveExportTheme === 'function') ? _resolveExportTheme(pick)
              : { theme: pick === 'light' ? 'light' : 'dark', charttheme: '', override: pick !== 'asis' };
    const o = { bundle: ck('pubopt_runnable') ? '1' : '0', source: ck('pubopt_source') ? '1' : '0',
                history: ck('pubopt_history') ? '1' : '0', outputs: val('pubopt_outputs') || 'all',
                theme: t.theme, charttheme: t.charttheme || '', override: t.override ? '1' : '0',
                slug: (el('pubopt_slug') && el('pubopt_slug').value.trim()) || '' };
    try {
      localStorage.setItem('slate_siterunnable', o.bundle); localStorage.setItem('slate_sitesource', o.source);
      localStorage.setItem('slate_sitehistory', o.history); localStorage.setItem('slate_sitetheme', pick);
      localStorage.setItem('slate_siteoutputs', o.outputs);
    } catch (e) {}
    return o;
  }
  function pubRestoreOpts() {
    const g = k => { try { return localStorage.getItem(k); } catch (e) { return null; } };
    const set = (id, v) => { const e = el(id); if (e && v != null) e.checked = v === '1'; };
    const sel = (id, v) => { const e = el(id); if (e && v) e.value = v; };
    set('pubopt_runnable', g('slate_siterunnable')); set('pubopt_source', g('slate_sitesource'));
    set('pubopt_history', g('slate_sitehistory'));
    sel('pubopt_theme', g('slate_sitetheme')); sel('pubopt_outputs', g('slate_siteoutputs'));
  }

  // ── Sites: this notebook's membership + front-page state across every site ───────────────────────
  async function loadSites() {
    let d = null;
    try { d = await api('GET', '/api/publish/sites'); } catch (e) {}
    _sitesData = (d && d.sites) || [];
    const slugIn = el('pubopt_slug'); if (slugIn && d && d.slug) slugIn.placeholder = d.slug;   // show the auto path
    renderSites(d);
  }
  function renderSites(d) {
    const box = el('pubsites'); if (!box) return;
    const sites = (d && d.sites) || [];
    if (!sites.length) {
      box.innerHTML = '<div class="pubdim" style="font-size:.82rem">No sites yet. Create one in the '
        + '<a class="publink" href="/#publishing" target="_blank" rel="noopener">Publishing manager</a>'
        + ' (a site deploys to your targets), then add this notebook to it here.</div>';
      return;
    }
    box.innerHTML = sites.map(s => {
      const nm = esc(s.name), tgts = (s.targets || []).length ? esc(s.targets.join(', ')) : 'local only';
      // A site can have ONE front page. If a DIFFERENT notebook already holds it, note who — ★ replaces it.
      const otherHome = (s.hasHome && s.homeTitle) ? s.homeTitle : '';
      const starTitle = otherHome ? ('Make this the front page — replaces “' + otherHome + '”') : 'Make this notebook the site’s front page (home)';
      return '<div class="pubsite' + (s.member ? ' is-member' : '') + '">'
        + '<label class="pubpick" style="flex:1" title="Add/remove this notebook to the site">'
        + '<input type="checkbox" ' + (s.member ? 'checked' : '') + ' onchange="pubToggleMember(\'' + nm + '\', this.checked)"/>'
        + '<span class="publ">' + esc(s.title || s.name) + '</span> <span class="pubdim">' + tgts + '</span></label>'
        + '<label class="pubpick" title="' + esc(starTitle) + '" style="opacity:' + (s.member ? '1' : '.4') + '">'
        + '<input type="checkbox" ' + (s.isHome ? 'checked' : '') + (s.member ? '' : ' disabled')
        + ' onchange="pubToggleHome(\'' + nm + '\', this.checked)"/> ★ front page</label>'
        + (otherHome ? '<span class="pubdim" style="font-size:.72rem" title="Current front page">↩ ' + esc(otherHome) + '</span>' : '')
        + (s.member ? '<button class="pubmini" onclick="pubPublishSite(\'' + nm + '\')">☁ Publish</button>' : '')
        + (s.url ? ' <a class="publink" href="' + esc(s.url) + '" target="_blank" rel="noopener">open ↗</a>' : '')
        + '</div>';
    }).join('');
  }
  window.pubToggleMember = async function (site, on) {
    try { await api('POST', '/api/publish/site-membership', { site: site, member: on }); }
    catch (e) { toast('Could not update membership', 4000, 'warn'); }
    loadSites();
  };
  window.pubToggleHome = async function (site, on) {
    // Replacing an existing (different) front page is destructive to that notebook's home role — confirm.
    if (on) {
      const s = (_sitesData || []).filter(x => x.name === site)[0];
      if (s && s.hasHome && s.homeTitle && !await confirmDark('“' + s.homeTitle + '” is currently the front page of “' + (s.title || site) + '”. Make this notebook the front page instead?', 'Replace front page')) {
        loadSites(); return;
      }
    }
    try { await api('POST', '/api/publish/site-home', { site: site, home: on }); }
    catch (e) { toast('Could not update front page', 4000, 'warn'); }
    loadSites();
  };
  // Build this notebook into the site + sync — streaming per-notebook progress into the panel log.
  window.pubPublishSite = function (site) {
    const log = el('pubsitesprog'); if (!log) return;
    log.style.display = 'block'; log.innerHTML = '';
    const line = (t, c) => { const n = document.createElement('div'); n.className = 'publogln ' + (c || ''); n.textContent = t; log.appendChild(n); log.scrollTop = log.scrollHeight; return n; };
    line('Publishing into ' + site + '…', 'st');
    const o = pubBuildOpts();
    const q = new URLSearchParams({ site: site, theme: o.theme, source: o.source, bundle: o.bundle,
                                    history: o.history, outputs: o.outputs });
    if (o.charttheme) q.set('charttheme', o.charttheme);
    if (o.override === '1') q.set('override', '1');
    if (o.slug) q.set('slug', o.slug);
    const es = new EventSource(_apipath('/api/site-publish') + '?' + q.toString());
    es.addEventListener('status', e => line(e.data, 'st'));
    es.addEventListener('log', e => line(e.data));
    es.addEventListener('done', e => { es.close(); let d = {}; try { d = JSON.parse(e.data); } catch (_) {} line(d.ok !== false ? '✓ Published' : '✗ Failed', d.ok !== false ? 'ok' : 'err'); loadSites(); });
    es.addEventListener('failed', e => { es.close(); line('✗ ' + e.data, 'err'); });
    es.onerror = () => { try { es.close(); } catch (_) {} };
  };
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
    if (!el('pubtargetpick')) return;   // the GitHub-repo section was removed — sites are the one path now
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
    if (!el('pubplacement')) return;    // placement hint belonged to the removed GitHub-repo section
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
