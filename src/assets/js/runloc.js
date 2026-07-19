// ── Run-location picker (toolbar) ─────────────────────────────────────────────────────────────────
// The "Running on: X" control. Three layers resolve server-side (session > notebook > global default);
// this UI shows the EFFECTIVE value + which layer set it, and lets you switch (session-only), persist
// (save in the .jl), clear, TEST + prime a host (preflight checklist), or manage/reap remote workers.
// Per-notebook actions go through api() (NB_ID-scoped); the host-list/preflight/registry routes are
// GLOBAL, so gapi() hits them raw (no NB_ID rewrite) — the same routes the home dialogs reuse.

let _rlHosts = null;     // cached {hosts:[~/.ssh/config aliases], global:"default host"}
let _rlSel = '';         // selected host in the open menu ('' = local, '__custom__' = typed)
let _launching = false;  // guard against double-launch while the bring-up POST is in flight

const gapi = async (method, path, body) => {
  const r = await fetch(path, { method, headers: { 'Content-Type': 'application/json' },
                                body: body ? JSON.stringify(body) : undefined });
  return r.json();
};
const _rlEsc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Reflect the effective run-location into the toolbar pill (called from updateChrome on every state).
function renderRunLoc(state) {
  const el = document.getElementById('runloc'); if (!el) return;
  // INACTIVE (dormant standalone): by design no worker is running, so render a grey "click to launch"
  // pill in place of the run-location/health chrome. The whole pill launches (onRunLocClick).
  const caret = el.querySelector('.runloccaret');
  if (state && state.inactive) {
    el.style.display = '';   // reveal the pill even with no worker running (nothing else will here)
    el.classList.add('inactive'); el.classList.remove('remote', 'reconnecting');
    document.getElementById('runlocicon').textContent = '⏸';
    document.getElementById('runloclabel').textContent = 'Inactive — click to launch';
    const se = document.getElementById('runlocsrc'); if (se) se.style.display = 'none';
    const rs = document.getElementById('runlocstat'); if (rs) rs.style.display = 'none';
    if (caret) caret.style.display = 'none';   // no run-location picker while dormant
    el.title = 'This notebook is dormant — no worker is running. Click to launch its live environment.';
    return;
  }
  el.classList.remove('inactive');
  if (caret) caret.style.display = '';
  closeLaunchPop();   // a launch flipped it live — dismiss any lingering launch popover
  const loc = (state && state.runLocation) || '';
  const src = (state && state.runLocationSource) || 'default';
  const host = loc ? loc.split(',')[0] : '';
  document.getElementById('runlocicon').textContent = host ? '🖧' : '💻';
  // Worker-health overlay: while the worker is (re)provisioning/connecting — a restart, a fresh remote
  // spawn, or a genuine disconnect of a runnable notebook — the pill must NOT sit there looking
  // connected. It goes amber and pulses with "· starting…"/"· reconnecting…" so a slow remote respawn
  // is visible here (this is the pill people watch), not just on the small worker dot.
  const w = (state && state.worker) || {};
  const runnable = ((state && state.cells) || []).some(c => c.kind === 'code');
  const busy = !!(state && state.hydrating) || (w.kind === 'gate' && !w.connected && runnable);
  const suffix = busy ? (state.hydrating ? ' · starting…' : ' · reconnecting…') : '';
  document.getElementById('runloclabel').textContent = (host || 'local') + suffix;
  el.classList.toggle('remote', !!host);
  el.classList.toggle('reconnecting', busy);
  const srcTxt = src === 'session' ? 'session' : src === 'notebook' ? 'saved' : src === 'global' ? 'global' : '';
  const se = document.getElementById('runlocsrc'); se.textContent = busy ? '' : srcTxt; se.style.display = (!busy && srcTxt) ? '' : 'none';
  // While starting/reconnecting, hide the cpu·rss stat too — showing "starting… 0% · 694MB" is
  // self-contradictory (the numbers are meaningless mid-boot) and clutters the pill.
  const rs = document.getElementById('runlocstat'); if (rs) rs.style.display = busy ? 'none' : '';
  el.title = busy ? ((host ? ('worker on ' + host) : 'local worker') + ' — ' +
                     (state.hydrating ? 'starting up (provisioning / connecting)…' : 'reconnecting…'))
           : host ? ('worker runs on ' + host + ' (' + (srcTxt || 'set') + ') — click to change')
                  : 'worker runs locally — click to run it on another machine';
}

async function toggleRunLoc(ev) {
  ev && ev.stopPropagation();
  const bg = document.getElementById('runlocbg');
  if (bg.classList.contains('show')) { closeRunLoc(); return; }
  document.getElementById('rlresult').innerHTML = '';
  await rlBuild();
  bg.classList.add('show');
}
function closeRunLoc() {
  if (_rlES) { try { _rlES.close(); } catch (_) {} _rlES = null; }
  document.getElementById('runlocbg').classList.remove('show');
}

// Known remotes = ~/.ssh/config hosts ∪ the locally-remembered ones (shared with the home Remotes
// manager via the same localStorage key), so a host you set up on the front page is pickable here too.
function _rlKnownHosts() {
  const hosts = ((_rlHosts && _rlHosts.hosts) || []).slice();
  try { JSON.parse(localStorage.getItem('slateRemotes') || '[]').forEach(spec => {
    const h = String(spec).split(',')[0]; if (h && !hosts.includes(h)) hosts.push(h); }); } catch (_) {}
  return hosts;
}
async function rlBuild() {
  if (!_rlHosts) { try { _rlHosts = await gapi('GET', '/api/ssh-hosts'); } catch (_) { _rlHosts = { hosts: [], global: '' }; } }
  const cur = (nbState && nbState.runLocation) || '', p = cur.split(',');
  const curHost = p[0] || '', curTr = p[1] || 'tunnel';
  const srcMap = { session: 'session', notebook: 'saved in notebook', global: 'global default', default: 'local' };
  document.getElementById('rlsourcebadge').textContent = srcMap[(nbState && nbState.runLocationSource) || 'default'] || '';
  document.getElementById('rlcustom').value = curHost;
  document.getElementById('rllocalbtn').classList.toggle('active', !curHost);
  const trIn = document.querySelector('input[name="rltr"][value="' + (curTr === 'direct' ? 'direct' : 'tunnel') + '"]');
  if (trIn) trIn.checked = true;
  document.getElementById('rlport').value = p[2] || ''; document.getElementById('rlstream').value = p[3] || '';
  _rlSyncTransport();
  rlRenderKnown(curHost);
}
// The "known remotes" list (★ marks the global default). The whole row is the click target — clicking
// it selects that remote (fills the host field); the currently-selected one is marked `.on`.
function rlRenderKnown(curHost) {
  const known = _rlKnownHosts(), el = document.getElementById('rlknown');
  if (!known.length) { el.innerHTML = ''; return; }
  el.innerHTML = '<div class="rlknownhead">Known remotes</div>' + known.map(h => {
    const isDef = h === ((_rlHosts && _rlHosts.global) || '');
    return '<div class="rlrow' + (h === curHost ? ' on' : '') + '" role="button" title="use this remote" onclick="rlUse(\'' +
      _rlEsc(h) + '\')"><span>' + (isDef ? '★' : '🖧') + ' ' + _rlEsc(h) + (isDef ? ' <em>(default)</em>' : '') + '</span></div>';
  }).join('');
}
function rlUse(h) {
  document.getElementById('rlcustom').value = h;
  document.getElementById('rllocalbtn').classList.remove('active');
  _rlSyncTransport(); rlRenderKnown(h);
}
function rlPickLocal() {
  document.getElementById('rlcustom').value = '';
  document.getElementById('rllocalbtn').classList.add('active');
  _rlSyncTransport(); rlRenderKnown('');
}
function rlCustomChanged() {
  document.getElementById('rllocalbtn').classList.toggle('active', !document.getElementById('rlcustom').value.trim());
  _rlSyncTransport(); rlRenderKnown(_rlSelectedHost());
}
function _rlSelectedHost() { return document.getElementById('rlcustom').value.trim(); }
function _rlSyncTransport() {
  const h = _rlSelectedHost();
  document.getElementById('rltransport').style.display = h ? '' : 'none';
  const tr = (document.querySelector('input[name="rltr"]:checked') || {}).value || 'tunnel';
  const pr = document.getElementById('rlports');
  if (pr) pr.style.display = (h && tr === 'direct') ? '' : 'none';   // ports only matter for :direct
}
// The "host[,transport[,port,stream]]" spec. tunnel is the default → omit it for a clean value. For
// :direct, append pinned ports when given (needed behind a firewall); blank ports mean auto.
function _rlSpec() {
  const h = _rlSelectedHost(); if (!h) return 'local';   // explicit local (force local even if a global default is set)
  const tr = (document.querySelector('input[name="rltr"]:checked') || {}).value || 'tunnel';
  if (tr !== 'direct') return h;
  const p = (document.getElementById('rlport').value || '').trim();
  const s = (document.getElementById('rlstream').value || '').trim();
  return p ? (h + ',direct,' + p + (s ? ',' + s : '')) : (h + ',direct');
}

async function rlApply(scope) {
  const spec = scope === 'clear' ? '' : _rlSpec();
  closeRunLoc();
  const s = await api('POST', '/api/run-on', { host: spec, scope });
  try { renderAll(s); } catch (_) {}
  const where = spec ? ("'" + spec + "'") : 'local';
  toast(scope === 'clear' ? 'Run-location cleared → follows global/local' :
        scope === 'notebook' ? ('Saved — this notebook runs on ' + where) :
        ('Switching worker to ' + where + '…'), 2600);
}

let _rlES = null;
// Stream the preflight over SSE so each step fills in live (a cold host provisions for minutes).
// Browser-triggerable directly — no MCP tool involved.
function rlTest() {
  const host = _rlSelectedHost();
  const box = document.getElementById('rlresult');
  if (!host) { box.innerHTML = '<div class="rlnote">Pick a host to test.</div>'; return; }
  const tr = (document.querySelector('input[name="rltr"]:checked') || {}).value || 'tunnel';
  if (_rlES) { try { _rlES.close(); } catch (_) {} _rlES = null; }
  box.innerHTML = '<div class="rlnote" id="rlnote"><span class="hydspin"></span> Testing ' + _rlEsc(host) + ' (' + tr +
    ')… a first-time host provisions Julia deps and can take a few minutes.</div><div id="rlsteps"></div>';
  const steps = document.getElementById('rlsteps'), rows = {};
  const es = new EventSource('/api/preflight-stream?host=' + encodeURIComponent(host) + '&transport=' + encodeURIComponent(tr));
  _rlES = es;
  es.addEventListener('step', e => {
    let s; try { s = JSON.parse(e.data); } catch (_) { return; }
    let el = rows[s.name];
    if (!el) { el = document.createElement('div'); rows[s.name] = el; steps.appendChild(el); }
    const running = s.status === 'run';
    const m = running ? '<span class="hydspin"></span>' : s.status === 'ok' ? '✓' : s.status === 'skip' ? '–' : '✗';
    el.className = 'rlstep ' + (running ? 'run' : s.status);
    el.innerHTML = '<span class="rlmark">' + m + '</span> <b>' + _rlEsc(s.name) + '</b> <span class="rlms">' +
      (running ? '…' : s.ms + 'ms') + '</span>' + (s.detail ? '<div class="rldetail">' + _rlEsc(s.detail) + '</div>' : '');
  });
  es.addEventListener('done', e => {
    let d = {}; try { d = JSON.parse(e.data); } catch (_) {}
    es.close(); _rlES = null;
    const note = document.getElementById('rlnote'); if (note) note.remove();
    const v = document.createElement('div'); v.className = 'rlverdict ' + (d.ok ? 'ok' : 'fail');
    v.textContent = d.ok ? '✅ All checks passed — host is primed and ready.' : '❌ Some checks failed — see above.';
    steps.parentNode.insertBefore(v, steps);
  });
  es.addEventListener('failed', e => { es.close(); _rlES = null;
    steps.insertAdjacentHTML('beforeend', '<div class="rlnote err">' + _rlEsc(e.data) + '</div>'); });
  es.onerror = () => { if (!_rlES) return; };   // normal close after done/failed already handled
}

async function rlManageWorkers(ev) {
  ev && ev.preventDefault();
  const host = _rlSelectedHost() || (_rlHosts && _rlHosts.global) || '';
  const box = document.getElementById('rlresult');
  if (!host) { box.innerHTML = '<div class="rlnote">Pick a host to list its workers.</div>'; return; }
  box.innerHTML = '<div class="rlnote"><span class="hydspin"></span> Listing workers on ' + _rlEsc(host) + '…</div>';
  let r; try { r = await gapi('GET', '/api/remote-workers?host=' + encodeURIComponent(host)); }
  catch (_) { box.innerHTML = '<div class="rlnote err">Could not list workers.</div>'; return; }
  const ws = r.workers || [];
  if (!ws.length) { box.innerHTML = '<div class="rlnote">No Slate workers on ' + _rlEsc(host) + '.</div>'; return; }
  const now = Date.now() / 1000;
  const rows = ws.map(w => {
    let mf = {}; try { mf = JSON.parse(w.manifest || '{}'); } catch (_) {}
    const age = w.lastActivity ? (Math.round((now - w.lastActivity) / 60) + 'm ago') : 'never';
    const abandoned = w.alive && w.lastActivity && (now - w.lastActivity > 3600);
    return '<div class="rlworker"><div class="rlwinfo"><b>' + (w.alive ? '🟢' : '⚪') + ' :' + w.port + '</b> ' +
      _rlEsc(mf.notebook || '?') + '<div class="rldetail">last activity: ' + age +
      (abandoned ? ' · <span class="rlabandon">possibly abandoned</span>' : '') +
      (mf.spawned ? ' · since ' + _rlEsc(mf.spawned) : '') + '</div></div>' +
      '<button class="rlreap" onclick="rlReap(\'' + _rlEsc(host) + '\',' + w.port + ')" title="kill this worker + remove its files">Reap</button></div>';
  }).join('');
  box.innerHTML = '<div class="rlnote">Workers on ' + _rlEsc(host) + ' — reap only ones you\'re sure about (results are lost):</div>' + rows;
}
async function rlReap(host, port) {
  if (!await confirmDark('Reap worker :' + port + ' on ' + host + '?\nThis kills it and removes its files — any un-fetched results are lost.', 'Reap', 'danger')) return;
  await gapi('POST', '/api/reap-worker', { host, port });
  rlManageWorkers();
}

// Backdrop click / Esc close the modal (mirrors the Settings modal).
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'runlocbg') closeRunLoc(); });
document.addEventListener('keydown', e => {
  const bg = document.getElementById('runlocbg');
  if (e.key === 'Escape' && bg && bg.classList.contains('show')) { e.stopPropagation(); closeRunLoc(); }
}, true);
// Pill click dispatcher: a dormant (inactive) notebook opens the launch popover (2-click launch);
// a live one opens the worker log popup.
function onRunLocClick(ev) {
  // Use the pill's OWN class (set by renderRunLoc) — authoritative and local, unlike the `nbState`
  // global which isn't reliably present on `window` here.
  const el = document.getElementById('runloc');
  if (el && el.classList.contains('inactive')) { toggleLaunchPop(ev); return; }
  openWorkerPop('', ev);
}
// The launch popover expands under the pill (like the worker-status panel): FIRST click on the pill
// opens it with the precompile heads-up; the "Launch" button here is the deliberate SECOND click.
function toggleLaunchPop(ev) {
  ev && ev.stopPropagation();
  const pop = document.getElementById('launchpop'); if (!pop) return;
  (pop.style.display !== 'none') ? closeLaunchPop() : openLaunchPop();
}
function openLaunchPop() {
  const pop = document.getElementById('launchpop'), pill = document.getElementById('runloc');
  if (!pop || !pill) return;
  // Best-effort package hints (which packages may precompile) if the server provided them.
  const deps = ((window.__slateState || {}).launchDeps) || [];
  const box = document.getElementById('launchpop-deps');
  if (box) box.innerHTML = deps.length
    ? ('<div class="ldephead">' + deps.length + ' package' + (deps.length === 1 ? '' : 's') + ' in this environment</div>'
       + deps.map(d => '<span class="ldep">' + _rlEsc(d) + '</span>').join(' ')) : '';
  pop.style.display = 'block';
  const r = pill.getBoundingClientRect();
  pop.style.left = Math.round(r.left) + 'px';
  pop.style.top = Math.round(r.bottom + 6) + 'px';
  const pr = pop.getBoundingClientRect();   // nudge back on-screen if the pill sits near the right edge
  if (pr.right > window.innerWidth - 8) pop.style.left = Math.max(8, window.innerWidth - 8 - pr.width) + 'px';
}
function closeLaunchPop() { const pop = document.getElementById('launchpop'); if (pop) pop.style.display = 'none'; }
// The deliberate second click: flip the notebook live. The server runs the standard bring-up, which
// RESTORES locked/expensive results from the bundle instead of recomputing them.
async function doLaunch() {
  closeLaunchPop();
  if (_launching) return;
  _launching = true;
  try {
    const r = await api('POST', '/api/launch', {});
    if (r && r.ok === false) toast(r.note === 'already active' ? 'Already running' : 'Could not launch', 2200);
  } catch (_) { toast('Could not launch the notebook', 2600); }
  finally { _launching = false; }
}
// Dismiss the popover on outside click / Esc (but not when clicking the pill itself — that toggles).
document.addEventListener('mousedown', e => {
  const pop = document.getElementById('launchpop');
  if (pop && pop.style.display !== 'none' && !e.target.closest('#launchpop') && !e.target.closest('#runloc')) closeLaunchPop();
});
document.addEventListener('keydown', e => {
  const pop = document.getElementById('launchpop');
  if (e.key === 'Escape' && pop && pop.style.display !== 'none') { e.stopPropagation(); closeLaunchPop(); }
}, true);
window.onRunLocClick = onRunLocClick;
window.toggleLaunchPop = toggleLaunchPop;
window.closeLaunchPop = closeLaunchPop;
window.doLaunch = doLaunch;
window.renderRunLoc = renderRunLoc;
