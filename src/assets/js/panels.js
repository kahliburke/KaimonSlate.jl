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

// Instant push: the server streams the version over SSE and bumps it only on
// external (file) changes, so the browser's own edits never trigger a re-render.
function connectLive() {
  const es = new EventSource(_apipath('/api/events'));
  es.onmessage = async (e) => {
    if (e.data.startsWith('agent:')) { try { agentEvent(JSON.parse(e.data.slice(6))); } catch (_) {} return; }
    if (e.data === 'refresh') { updateStates(await api('GET', '/api/state')); return; }   // async live update — patch in place
    if (e.data.startsWith('srcreload:')) {   // parent /src hot-reload (Revise) → cells marked stale
      const n = parseInt(e.data.slice(10), 10) || 0;
      updateStates(await api('GET', '/api/state'));
      toast(`🔁 Source reloaded — ${n} cell${n === 1 ? '' : 's'} now stale. ⌘↵ to run.`);
      return;
    }
    if (e.data.startsWith('srcerror:')) {    // a /src save didn't parse — Revise couldn't apply it
      toast('⚠ Source not reloaded — ' + e.data.slice(9), 7000, 'err');
      return;
    }
    const v = parseInt(e.data, 10);
    if (!isNaN(v) && v !== lastVersion) { lastVersion = v; renderAll(await api('GET', '/api/state')); }
    // Keep the history rail fresh while it's open (agent turns, external edits).
    if (document.getElementById('histpanel').classList.contains('open') && !histReplaying) loadHistory();
  };
  // EventSource auto-reconnects on error.
}
