// ── History (time machine) ──────────────────────────────────────────────────
// Durable, append-only edit history. The rail lists every checkpoint (👤 human /
// 🤖 agent / 📝 external / ↩ restore / 🌱 open / · auto-draft); selecting one shows
// a line-diff of that step against its parent, and you can restore (non-destructive)
// or ▶ replay the whole buildup. Sources are fetched lazily and cached by hash.
let histEntries = [], histCurrent = '', histSel = '', histReplaying = false;
const _histSrcCache = {};
const _histIcon = { browser:'👤', agent:'🤖', external:'📝', restore:'↩', open:'🌱', auto:'·' };
function _reltime(ts) {
  const s = Math.max(0, Date.now() / 1000 - ts);
  if (s < 60) return Math.floor(s) + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}
// ── Worker log ────────────────────────────────────────────────────────────────
// Tail the gate worker's stdout/stderr — what the kernel is doing when it evaluates.
let _logPoll = null, _logTail = true;
function toggleLog() {
  const p = document.getElementById('logpanel'); p.classList.toggle('open');
  if (p.classList.contains('open')) { loadLog(); _logPoll = _logPoll || setInterval(loadLog, 1500); }
  else if (_logPoll) { clearInterval(_logPoll); _logPoll = null; }
}
function toggleTail() {
  _logTail = !_logTail;
  document.getElementById('logtail').classList.toggle('stop', !_logTail);
  if (_logTail) { const b = document.getElementById('logbox'); b.scrollTop = b.scrollHeight; }
}
async function loadLog() {
  try {
    const r = await api('GET', '/api/worker-log'); if (!r) return;
    const box = document.getElementById('logbox');
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 30;
    box.textContent = r.log || '(empty)';
    const w = r.worker || {};
    document.getElementById('logstatus').textContent =
      w.kind === 'gate' ? `worker :${w.port} · ${w.connected ? 'connected' : 'down'}` : (w.kind || '');
    if (_logTail || atBottom) box.scrollTop = box.scrollHeight;
  } catch (_) {}
}

// ── Packages panel ────────────────────────────────────────────────────────────
// List + add/remove the notebook project's dependencies (the worker's active env).
// Add/remove installs/uninstalls then re-runs cells, so a `using` lights up live.
let _pkgManageable = false;
function togglePackages() {
  const p = document.getElementById('pkgpanel'); p.classList.toggle('open');
  if (p.classList.contains('open')) loadPackages();
}
async function loadPackages() {
  const r = await api('GET', '/api/packages') || {};
  _pkgManageable = !!r.manageable;
  const byName = (a, b) => a.name.localeCompare(b.name);
  const nb = (r.notebook || []).slice().sort(byName);
  const parent = (r.parent || []).slice().sort(byName);
  document.getElementById('pkgstatus').textContent =
    nb.length + ' notebook' + (parent.length ? ' · ' + parent.length + ' from parent' : (r.detached ? ' · detached' : '')) +
    (_pkgManageable ? '' : ' · read-only (no project)');
  const inp = document.getElementById('pkgin'); inp.disabled = !_pkgManageable;
  const row = (p, removable) =>
    `<div class="pkgrow"><span class="pkgname">${_esc(p.name)}</span><span class="pkgver">${_esc(p.version || '')}</span>` +
    (removable ? `<button class="cdel" onclick="pkgRm('${_esc(p.name)}')" title="remove">✕</button>` : '') + '</div>';
  let html = '';
  html += `<div class="pkggrouphdr">Notebook${r.detached ? ' (detached — all deps)' : ' adds'}</div>`;
  html += nb.length ? nb.map(p => row(p, _pkgManageable)).join('') : '<div class="phint">No notebook-specific packages yet.</div>';
  if (parent.length) {
    html += `<div class="pkggrouphdr">Parent project <span class="pkgpath">${_esc((r.parentPath || '').replace(/^.*\//, ''))}</span></div>`;
    html += parent.map(p => row(p, false)).join('');
  }
  document.getElementById('pkglist').innerHTML = html;
}
async function pkgAdd() {
  if (!_pkgManageable) return;
  const inp = document.getElementById('pkgin'), name = inp.value.trim(); if (!name) return;
  if (!await confirmDark('Add package “' + name + '” to this notebook’s project? It is installed (may precompile) and the notebook re-runs.', 'Add')) return;
  inp.value = ''; document.getElementById('pkgstatus').textContent = 'adding ' + name + '…';
  const r = await api('POST', '/api/package', { op: 'add', name });
  if (r && r.ok === false) await alertDark('Add failed:\n' + (r.message || '?'));
  loadPackages();
}
async function pkgRm(name) {
  if (!await confirmDark('Remove package “' + name + '” from this notebook’s project?', 'Remove', 'danger')) return;
  document.getElementById('pkgstatus').textContent = 'removing ' + name + '…';
  const r = await api('POST', '/api/package', { op: 'rm', name });
  if (r && r.ok === false) await alertDark('Remove failed:\n' + (r.message || '?'));
  loadPackages();
}
// Package-name completion: a custom dropdown anchored under the input (a native <datalist>
// renders its popup off to the side and unbounded — it drifts over the panel). Fetches registry
// matches as you type; ↑/↓ move, ↵ picks the highlighted one (else adds what's typed), click
// picks, esc/blur hides. The list is scrollable + height-capped so a flood of matches stays put.
const _pkgsug = () => document.getElementById('pkgsug');
let _pkgCands = [], _pkgSel = -1;
function _pkgPaintSug() {
  const el = _pkgsug();
  if (!_pkgCands.length) { el.style.display = 'none'; el.innerHTML = ''; return; }
  el.innerHTML = _pkgCands.map((n, i) => `<div class="${i === _pkgSel ? 'on' : ''}" data-i="${i}">${_esc(n)}</div>`).join('');
  el.style.display = '';
  if (_pkgSel >= 0 && el.children[_pkgSel]) el.children[_pkgSel].scrollIntoView({ block: 'nearest' });
}
function _pkgHideSug() { _pkgCands = []; _pkgSel = -1; _pkgPaintSug(); }
function _pkgPick(i) {
  const n = _pkgCands[i]; if (n == null) return;
  const inp = document.getElementById('pkgin'); inp.value = n; _pkgHideSug(); inp.focus();
}
const _pkgComplete = debounce(async () => {
  const q = document.getElementById('pkgin').value.trim();
  if (q.length < 2) { _pkgHideSug(); return; }
  let names = [];
  try { const r = await api('GET', '/api/pkg-complete?q=' + encodeURIComponent(q)); names = (r && r.names) || []; } catch (_) {}
  _pkgCands = names; _pkgSel = -1; _pkgPaintSug();
}, 160);
document.getElementById('pkgin').addEventListener('input', _pkgComplete);
document.getElementById('pkgin').addEventListener('keydown', e => {
  const open = _pkgCands.length > 0;
  if (e.key === 'ArrowDown' && open) { e.preventDefault(); _pkgSel = Math.min(_pkgSel + 1, _pkgCands.length - 1); _pkgPaintSug(); }
  else if (e.key === 'ArrowUp' && open) { e.preventDefault(); _pkgSel = Math.max(_pkgSel - 1, 0); _pkgPaintSug(); }
  else if (e.key === 'Enter') { e.preventDefault(); (open && _pkgSel >= 0) ? _pkgPick(_pkgSel) : (_pkgHideSug(), pkgAdd()); }
  else if (e.key === 'Escape' && open) { e.preventDefault(); _pkgHideSug(); }
});
_pkgsug().addEventListener('mousedown', e => { const d = e.target.closest('div[data-i]'); if (d) { e.preventDefault(); _pkgPick(+d.dataset.i); } });
document.getElementById('pkgin').addEventListener('blur', () => setTimeout(_pkgHideSug, 120));

// ── Topbar ☰ overflow menu ──────────────────────────────────────────────────
function toggleTopMenu(e) { if (e) e.stopPropagation(); document.getElementById('topmenu').classList.toggle('open'); }
function closeTopMenu() { document.getElementById('topmenu').classList.remove('open'); }
document.addEventListener('click', e => { if (!e.target.closest('.menuwrap')) closeTopMenu(); });

let _histPoll = null;
async function toggleHistory() {
  const p = document.getElementById('histpanel'); p.classList.toggle('open');
  if (p.classList.contains('open')) {
    await loadHistory();
    // Light poll so the rail also reflects the user's own browser edits (which
    // don't fire SSE). Cheap GET; paused during replay.
    _histPoll = _histPoll || setInterval(() => { if (!histReplaying) loadHistory(); }, 3000);
  } else if (_histPoll) { clearInterval(_histPoll); _histPoll = null; }
}
async function loadHistory() {
  const r = await api('GET', '/api/history');
  histEntries = (r && r.entries) || []; histCurrent = (r && r.current) || '';
  document.getElementById('histcount').textContent = histEntries.length + ' steps';
  renderHistList();
}
function renderHistList() {
  const el = document.getElementById('histlist');
  // newest first
  el.innerHTML = histEntries.slice().reverse().map(e => {
    const cur = e.hash === histCurrent ? ' cur' : '', sel = e.hash === histSel ? ' sel' : '';
    const draft = e.kind === 'draft' ? ' draft' : '';
    const icon = _histIcon[e.source] || '•';
    return `<div class="hrow${cur}${sel}${draft}" onclick="histSelect('${e.hash}')">
      <span class="hsrc">${icon}</span>
      <span class="hlabel">${_esc(e.label)}${cur ? ' · now' : ''}</span>
      <span class="htime">${_reltime(e.ts)}</span></div>`;
  }).join('');
}
async function _histSrc(hash) {
  if (_histSrcCache[hash] != null) return _histSrcCache[hash];
  const r = await api('GET', '/api/history/' + hash);
  return (_histSrcCache[hash] = (r && r.source) || '');
}
// Minimal LCS line-diff → array of {t:'add'|'del'|'ctx', s}.
function _lineDiff(a, b) {
  const A = a.split('\n'), B = b.split('\n'), n = A.length, m = B.length;
  const C = Array.from({ length: n + 1 }, () => new Int32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    C[i][j] = A[i] === B[j] ? C[i + 1][j + 1] + 1 : Math.max(C[i + 1][j], C[i][j + 1]);
  const out = []; let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { out.push({ t: 'ctx', s: A[i] }); i++; j++; }
    else if (C[i + 1][j] >= C[i][j + 1]) { out.push({ t: 'del', s: A[i] }); i++; }
    else { out.push({ t: 'add', s: B[j] }); j++; }
  }
  while (i < n) out.push({ t: 'del', s: A[i++] });
  while (j < m) out.push({ t: 'add', s: B[j++] });
  return out;
}
async function histSelect(hash) {
  histSel = hash; renderHistList();
  const idx = histEntries.findIndex(e => e.hash === hash);
  const e = histEntries[idx]; if (!e) return;
  const cur = await _histSrc(hash);
  const parent = idx > 0 ? await _histSrc(histEntries[idx - 1].hash) : '';
  const diff = _lineDiff(parent, cur).map(d =>
    `<span class="dl ${d.t === 'add' ? 'add' : d.t === 'del' ? 'del' : 'ctx'}">${d.t === 'add' ? '+' : d.t === 'del' ? '-' : ' '} ${_esc(d.s)}</span>`).join('');
  const isCur = hash === histCurrent;
  document.getElementById('histprev').innerHTML =
    `<div class="pvhead"><span>${_histIcon[e.source] || '•'} ${_esc(e.label)}</span>
       ${isCur ? '<span class="hint">current state</span>'
               : `<button class="hbtn" onclick="histRestore('${hash}')">↩ Restore this version</button>`}</div>${diff}`;
}
async function histRestore(hash) {
  const st = await api('POST', '/api/history/restore', { hash });
  if (st && st.cells) { renderAll(st); lastVersion = st.version; }
  _histSrcCache[hash] = _histSrcCache[hash];          // keep cache
  await loadHistory(); histSelect(histCurrent);
}
async function histReplay() {
  const btn = document.getElementById('histplay');
  if (histReplaying) { histReplaying = false; return; }
  if (!histEntries.length) return;
  histReplaying = true; btn.textContent = '⏹ Stop'; btn.classList.add('stop');
  for (const e of histEntries) {
    if (!histReplaying) break;
    await histSelect(e.hash);
    document.querySelector('.hrow.sel')?.scrollIntoView({ block: 'nearest' });
    await new Promise(r => setTimeout(r, 850));
  }
  histReplaying = false; btn.textContent = '▶ Replay'; btn.classList.remove('stop');
}

// ── Source-reload banner (parent /src hot-reload) ─────────────────────────────
// Persistent, top-left. The change detector is best-effort (~file-granular), so rather than
// silently trust it we keep this up until the user acts: run our guess (the stale cells), or
// re-run the whole notebook (safe). Parse errors show a red, button-less variant.
function hideSrcBanner() { const b = document.getElementById('srcbanner'); b.style.display = 'none'; b.innerHTML = ''; }
function showSrcReload(n) {
  const b = document.getElementById('srcbanner'); b.className = 'srcbanner';
  b.innerHTML =
    `<span class="msg">🔁 <b>Project source changed</b> — ~${n} cell${n === 1 ? '' : 's'} likely affected ` +
    `(our guess may be incomplete).</span>` +
    `<button class="primary" id="srcrunaff">Run affected${n ? ` (${n})` : ''}</button>` +
    `<button id="srcrunall">Re-run all (safe)</button>` +
    `<button class="x" title="dismiss">✕</button>`;
  b.style.display = 'flex';
  b.querySelector('.x').onclick = hideSrcBanner;
  b.querySelector('#srcrunaff').onclick = async () => { hideSrcBanner(); updateStates(await api('POST', '/api/run', {})); };
  b.querySelector('#srcrunall').onclick = async () => { hideSrcBanner(); updateStates(await api('POST', '/api/rerun-all', {})); };
}
function showSrcError(msg) {
  const b = document.getElementById('srcbanner'); b.className = 'srcbanner err';
  b.innerHTML = `<span class="msg">⚠ <b>Source didn’t compile</b> — ${_esc(msg)}</span>` +
    `<button class="x" title="dismiss">✕</button>`;
  b.style.display = 'flex';
  b.querySelector('.x').onclick = hideSrcBanner;
}

// ── Connection liveness (detect disconnect → modal → reconnect + resync) ──────
// When the server restarts (or the network drops), requests silently fail and a cell can
// sit on "running" forever. We surface it: a failed fetch (api()) or a dropped SSE arms a
// short grace timer; if we don't recover, a blocking modal informs and waits.
//
// We DON'T trust EventSource's built-in retry: once the HTTP server is back but the
// notebook isn't re-registered yet, the SSE returns 404, and a browser EventSource treats
// any 4xx as fatal and gives up PERMANENTLY. So instead we actively poll /api/state while
// down; the notebook id is stable (derived from the filename), so the moment it's
// re-registered the poll succeeds — then we open a FRESH SSE and resync. In-editor edits
// survive (CodeMirror is created once, never reset on re-render), so a resync only
// refreshes badges/outputs/controls; the user's unsaved source stays put, ready to re-run.
const _GRACE_MS = 1200, _PROBE_MS = 1500;
let _es = null, _connDown = false, _modalShown = false, _graceTimer = null, _probeTimer = null;
// Trouble detected. Arm a grace timer (show the modal only if we don't bounce back quickly)
// and start actively polling for recovery. Idempotent while already handling a drop.
function _onConnTrouble() {
  if (_connDown) return;
  _connDown = true;
  window.backupEdits && window.backupEdits();     // snapshot in-flight edits immediately, before any reload/restart loses them
  _graceTimer = setTimeout(() => { if (_connDown) { _modalShown = true; const m = document.getElementById('disconnmodal'); if (m) m.style.display = 'flex'; } }, _GRACE_MS);
  _probeTimer = setInterval(_probe, _PROBE_MS);
  _probe();                                      // try immediately too (covers a one-off blip)
}
// Update the modal's live status line — tells the user WHERE recovery is (down → re-opening →
// starting worker → done) instead of an opaque spinner.
function _setConnStatus(text) { const el = document.getElementById('dm-status'); if (el) el.textContent = text; }
// Probe the server and report the phase. We only DISMISS once the server answers AND the worker is
// live — a fresh start has to re-open the notebook and spin up its kernel, and we surface each step.
async function _probe() {
  if (!_connDown) return;
  let r;
  try { r = await fetch(_apipath('/api/state')); }
  catch (_) { _setConnStatus('Waiting for the server to come back online…'); return; }   // no response — still down
  let state = null;
  if (r.status === 404) {                          // server is up but the notebook isn't registered yet
    _setConnStatus('Server is back — re-opening the notebook and starting the worker…');
    state = await _reopenByPath();                 // blocks while the notebook loads + its kernel spins up
  } else if (r.ok) {
    try { state = await r.json(); } catch (_) { return; }
  } else { _setConnStatus('Waiting for the server…'); return; }
  if (!state || !_connDown) return;                // nothing usable, or a concurrent probe already recovered
  // The HTTP server answered — but the WORKER may still be coming up (reconstructing a standalone's
  // env, or a gate kernel reconnecting). Keep the modal up, with progress, until it's actually live.
  const w = state.worker || {};
  if (state.hydrating) { _setConnStatus('Server is back — reconstructing the environment & packages…'); return; }
  if (!(w.kind === 'inproc' || w.connected)) { _setConnStatus('Server is back — starting the worker process…'); return; }
  // Fully recovered: server up + worker live.
  _connDown = false;
  clearTimeout(_graceTimer); clearInterval(_probeTimer); _graceTimer = _probeTimer = null;
  connectLive();                                 // fresh SSE — the old one gave up on the 404
  updateStates(state);                           // resync (editors preserved)
  window.reconcileBackup && window.reconcileBackup(state);   // if boot 404'd, restore unsaved edits now that we have state
  if (_modalShown) { const m = document.getElementById('disconnmodal'); if (m) m.style.display = 'none'; toast('Reconnected — worker live, synced', 3000, 'ok'); }
  _modalShown = false;
}
// Server is up but doesn't have this notebook (empty registry after a restart). Ask it to
// re-open the file we remembered from the last good state — the empty registry yields the same
// (filename-stem) id, so our /n/<id> URL resolves again — then read the freshly-loaded state.
async function _reopenByPath() {
  let path = null;
  try { path = localStorage.getItem('slate:path:' + NB_ID); } catch (_) {}
  if (!path) return null;                          // never saw a good state — can't know the path
  try {
    const r = await fetch('/api/open', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path }) });
    if (!r.ok) return null;
    const st = await fetch(_apipath('/api/state'));
    return st.ok ? st.json() : null;
  } catch (_) { return null; }
}
// Back-compat alias used by api()'s catch.
const _showDisconnect = _onConnTrouble;
// Manual button: probe right now (don't wait for the next interval tick).
function reconnectNow() { _probe(); }

// Instant push: the server streams the version over SSE and bumps it only on
// external (file) changes, so the browser's own edits never trigger a re-render.
function connectLive() {
  if (_es) { try { _es.close(); } catch (_) {} }
  const es = _es = new EventSource(_apipath('/api/events'));
  es.onopen = () => { if (_connDown) _probe(); };   // SSE back → confirm via state + dismiss
  es.onerror = () => { if (es.readyState !== EventSource.OPEN) _onConnTrouble(); };   // dropped
  es.onmessage = async (e) => {
    if (e.data.startsWith('agent:')) { try { agentEvent(JSON.parse(e.data.slice(6))); } catch (_) {} return; }
    if (e.data.startsWith('refresh:')) { try { patchCells(JSON.parse(e.data.slice(8)).cells); } catch (_) {} return; }   // targeted: only the changed cells, inline
    if (e.data.startsWith('cellrun:')) { window.onCellRun && window.onCellRun(e.data.slice(8)); return; }   // a cell started running (live status)
    if (e.data.startsWith('celldone:')) { try { const c = JSON.parse(e.data.slice(9)); patchCells([c]); window.onCellDone && window.onCellDone(c); } catch (_) {} return; }   // a cell finished — patch + status
    if (e.data.startsWith('inspect:')) { try { const r = JSON.parse(e.data.slice(8)); window._slateInspect && window._slateInspect(r.reqid, r.cell); } catch (_) {} return; }   // slate.inspect: capture this cell for the agent
    if (e.data.startsWith('js:')) { try { const r = JSON.parse(e.data.slice(3)); window._slateEvalJs && window._slateEvalJs(r.reqid, r.code); } catch (_) {} return; }   // slate.eval_js: run agent JS in this tab
    if (e.data === 'refresh') { updateStates(await api('GET', '/api/state')); return; }   // (fallback) full pull
    if (e.data.startsWith('srcreload:')) {   // parent /src hot-reload (Revise): show the persistent banner
      const n = parseInt(e.data.slice(10), 10) || 0;
      updateStates(await api('GET', '/api/state'));   // reflect our guessed stale marks
      showSrcReload(n);
      return;
    }
    if (e.data.startsWith('srcerror:')) {    // a /src save didn't parse — Revise couldn't apply it
      showSrcError(e.data.slice(9));
      return;
    }
    const v = parseInt(e.data, 10);
    if (!isNaN(v) && v !== lastVersion) { lastVersion = v; renderAll(await api('GET', '/api/state')); }
    // Keep the history rail fresh while it's open (agent turns, external edits).
    if (document.getElementById('histpanel').classList.contains('open') && !histReplaying) loadHistory();
  };
}
