// ── Worker / region status pills + live log popup ─────────────────────────────────────────────────
// One pill per worker the notebook uses: the MAIN worker rides the existing #runloc pill, each ACTIVE
// region gets a pill in #workerpills. Clicking a pill body opens a popup with that worker's LOG (polled
// live while open) plus its diagnostics (process + host cpu/mem, from the 2s telemetry). The #runloc
// pill's ▾ caret still opens the run-location picker (change WHERE it runs); the body opens this popup.

let _wpSide = null, _wpTimer = null;
const _wpEsc = s => String(s == null ? '' : s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
const _wpMB = v => (v == null || v < 0) ? '' : (v / 2 ** 20 >= 1024 ? (v / 2 ** 30).toFixed(1) + 'GB' : Math.round(v / 2 ** 20) + 'MB');

// A telemetry sample (JSON string) → "cpu 12% · rss 450MB · 2 running · host-cpu 380% · load 4.2 · host-mem 6.1/16GB".
function _wpStats(statsJson) {
  if (!statsJson) return '';
  let s; try { s = JSON.parse(statsJson); } catch (_) { return ''; }
  const p = [];
  if (s.cpu >= 0) p.push('cpu ' + s.cpu + '%');
  if (s.rss > 0) p.push('rss ' + _wpMB(s.rss));
  if (s.evals > 0) p.push(s.evals + ' running');
  if (s.sys_cpu >= 0) p.push('host-cpu ' + s.sys_cpu + '%');
  if (s.load1 >= 0) p.push('load ' + s.load1);
  if (s.sys_mem_total > 0) p.push('host-mem ' + _wpMB(s.sys_mem_total - s.sys_mem_free) + '/' + _wpMB(s.sys_mem_total));
  return p.join('  ·  ');
}

// A COMPACT at-a-glance stat for the pill face (cpu% · rss) — the full breakdown is in the popup.
function _wpPillStat(statsJson) {
  if (!statsJson) return '';
  let s; try { s = JSON.parse(statsJson); } catch (_) { return ''; }
  const p = [];
  if (s.cpu >= 0) p.push(Math.round(s.cpu) + '%');
  if (s.rss > 0) p.push(_wpMB(s.rss));
  return p.join(' · ');
}

// Display label for a worker. `"default"` is the UNNAMED region's internal name — don't surface it (it
// reads like "the default worker"); show its host instead. A NAMED region shows "name · host".
function _wpLabel(side, host) {
  if (!side) return host || 'local';
  if (side === 'default') return host || 'region';
  return side + (host ? ' · ' + host : '');
}

// Region pills + the main worker's compact stat on the #runloc pill. Called from updateChrome on every state.
function renderWorkers(state) {
  const ws = (state && state.workers) || [];
  const rls = document.getElementById('runlocstat');            // main worker's stat rides the #runloc pill
  if (rls) { const main = ws.find(w => !w.side); rls.textContent = main ? _wpPillStat(main.stats) : ''; }
  const box = document.getElementById('workerpills'); if (!box) return;
  box.innerHTML = ws.filter(w => w.side).map(w => {
    const label = _wpLabel(w.side, w.host);
    const stat = _wpPillStat(w.stats);
    return '<span class="wpill' + (w.connected ? '' : ' reconnecting') + '" onclick="openWorkerPop(' +
      JSON.stringify(w.side) + ', event)" title="region ‘' + _wpEsc(label) +
      '’ — click for its live log &amp; status">🖧 ' + _wpEsc(label) +
      (stat ? ' <span class="wstat">' + _wpEsc(stat) + '</span>' : '') + (w.connected ? '' : ' · …') + '</span>';
  }).join('');
}

function openWorkerPop(side, ev) {
  ev && ev.stopPropagation();
  _wpSide = side;
  const bg = document.getElementById('workerpopbg'); if (!bg) return;
  document.getElementById('workerpop-log').textContent = 'loading…';
  document.getElementById('workerpop-stats').textContent = '';
  bg.classList.add('show');
  _wpRefresh();
  if (_wpTimer) clearInterval(_wpTimer);
  _wpTimer = setInterval(_wpRefresh, 1200);   // live tail while the popup is open
}
function closeWorkerPop() {
  if (_wpTimer) { clearInterval(_wpTimer); _wpTimer = null; }
  _wpSide = null;
  const bg = document.getElementById('workerpopbg'); if (bg) bg.classList.remove('show');
}
async function _wpRefresh() {
  if (_wpSide === null) return;
  let r; try { r = await api('GET', '/api/worker-log?side=' + encodeURIComponent(_wpSide) + '&lines=500'); }
  catch (_) { return; }
  if (_wpSide === null) return;                                  // closed while fetching
  const dot = r.connected ? '🟢' : '🟡';
  document.getElementById('workerpop-title').innerHTML = dot + ' ' + (r.side ? 'region' : 'main worker') +
    ' · ' + _wpEsc(_wpLabel(r.side, r.host)) + (r.port ? ' :' + r.port : '');
  document.getElementById('workerpop-stats').textContent = _wpStats(r.stats) || (r.note || '');
  const pre = document.getElementById('workerpop-log');
  const atTop = pre.scrollTop < 30;
  // NEWEST FIRST (reverse-chronological) — the latest lines are what you came to see. Same for local + remote.
  pre.textContent = r.log ? r.log.split('\n').reverse().join('\n') : (r.note ? '(' + r.note + ')' : '(no log yet)');
  if (atTop) pre.scrollTop = 0;                                 // keep pinned to the newest unless scrolled down
}

window.renderWorkers = renderWorkers;
window.openWorkerPop = openWorkerPop;
window.closeWorkerPop = closeWorkerPop;

// Backdrop click / Esc close (mirrors the run-location modal).
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'workerpopbg') closeWorkerPop(); });
document.addEventListener('keydown', e => {
  const bg = document.getElementById('workerpopbg');
  if (e.key === 'Escape' && bg && bg.classList.contains('show')) { e.stopPropagation(); closeWorkerPop(); }
}, true);
