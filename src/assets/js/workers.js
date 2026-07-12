// ── Worker / region status pills + live log popup ─────────────────────────────────────────────────
// One pill per worker the notebook uses: the MAIN worker rides the existing #runloc pill, each ACTIVE
// region gets a pill in #workerpills. Clicking a pill body opens a popup with that worker's LOG (polled
// live while open) plus its diagnostics (process + host cpu/mem, from the 2s telemetry). The #runloc
// pill's ▾ caret still opens the run-location picker (change WHERE it runs); the body opens this popup.

let _wpSide = null;
// side → freshest telemetry JSON string, PUSHED over the page WebSocket (window.onWorkerTelemetry). Fresher
// than state.workers[].stats (which only refreshes on a notebook version-bump), so the pills read it first.
const _wpLive = {};
let _wpRaw = [];                  // chronological raw log lines for the OPEN popup (snapshot + streamed), re-parsed on each change
const _WP_LOG_MAX = 2000;        // cap the client-side buffer so a chatty worker can't grow it unbounded
const _wpEsc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const _wpMB = v => (v == null || v < 0) ? '' : (v / 2 ** 20 >= 1024 ? (v / 2 ** 30).toFixed(1) + 'GB' : Math.round(v / 2 ** 20) + 'MB');

// A telemetry sample (JSON string) → the full breakdown as wrapping labelled chips (HTML). No truncation:
// every metric stays visible on its own chip, wrapping to a new row as needed. `note` shows when there's no
// sample yet (e.g. an in-process kernel or a just-spawned worker).
function _wpStatsChips(statsJson, note) {
  let s; if (statsJson) { try { s = JSON.parse(statsJson); } catch (_) { s = null; } }
  if (!s) return note ? '<span class="wchip wchip-note">' + _wpEsc(note) + '</span>' : '';
  // `w` = reserved value width (ch) sized to the metric's max, so a chip's width stays fixed as the number
  // changes each tick (paired with tabular-nums in CSS) — the row no longer jitters on every update.
  const chip = (k, v, w) => '<span class="wchip"><span class="wchip-k">' + k + '</span>' +
    '<span class="wchip-v" style="min-width:' + w + 'ch">' + _wpEsc(v) + '</span></span>';
  const p = [];
  if (s.cpu >= 0) p.push(chip('cpu', s.cpu + '%', 5));
  if (s.rss > 0) p.push(chip('rss', _wpMB(s.rss), 5));
  if (s.evals > 0) p.push(chip('running', s.evals, 2));
  if (s.gc_ms > 0) p.push(chip('gc', s.gc_ms + 'ms', 6));
  if (s.memo >= 0) p.push(chip('memo', _wpMB(s.memo), 5));
  if (s.sys_cpu >= 0) p.push(chip('host cpu', s.sys_cpu + '%', 5));
  if (s.load1 >= 0) p.push(chip('load', s.load1, 5));
  if (s.sys_mem_total > 0) p.push(chip('host mem', _wpMB(s.sys_mem_total - s.sys_mem_free) + ' / ' + _wpMB(s.sys_mem_total), 13));
  return p.join('');
}

// ── Worker-log prettifier ─────────────────────────────────────────────────────────────────────────────
// The worker's timestamp ConsoleLogger renders each record across MULTIPLE physical lines with box-drawing
// prefixes (┌ head · │ continuation · └ last). Parse those back into logical RECORDS so a multi-line @info
// reads top-to-bottom even though records are shown newest-first, and so we can colour by level and dim the
// `@ Module file:line` location. Plain prints (no box char) become their own single-line records.
// A raw Julia `WARNING:`/`ERROR:` core print (no box chars) spans several lines — a hint/`!!!`/`@ location`
// tail. Group that whole block into ONE record so it reads as a unit AND so identical repeats collapse
// (the world-age depwarn spam fires the same block every tick). Continuation = an indented line or a known
// hint prefix; the next `WARNING:`/`┌`/plain line ends the block.
const _WARN_CONT = /^(\s|To make this|Hint:|!!!|Stacktrace|caused by|@ |\[\d)/;
function _wpParseRecords(lines) {
  const recs = [];
  let cur = null, mode = null;                             // mode: 'box' (┌│└) | 'warn' (WARNING/ERROR block) | null
  for (const raw of lines) {
    const c0 = raw.charAt(0);
    if (c0 === '┌') { cur = { head: raw.slice(1).trim(), cont: [] }; mode = 'box'; recs.push(cur); }
    else if (mode === 'box' && (c0 === '│' || c0 === '└') && cur) {
      const body = raw.slice(1).trim(); if (body) cur.cont.push(body);
      if (c0 === '└') { cur = null; mode = null; }         // record closed
    } else if (/^(WARNING|ERROR):/.test(raw)) {
      const m = raw.match(/^(WARNING|ERROR):\s*([\s\S]*)$/);
      cur = { head: (m[1] === 'ERROR' ? 'Error' : 'Warning') + ': ' + m[2], cont: [] }; mode = 'warn'; recs.push(cur);
    } else if (mode === 'warn' && cur && _WARN_CONT.test(raw)) {
      const body = raw.trim(); if (body) cur.cont.push(body);
    } else { cur = null; mode = null; if (raw.length) recs.push({ plain: raw }); }
  }
  return recs;
}
// Collapse consecutive IDENTICAL records into one with a ×N count — tames repetitive spam (e.g. a world-age
// warning firing every tick) without hiding anything. Only merges adjacent equal records, so ordering and
// distinct messages are untouched. Re-run on every render, so the count grows live as duplicates stream in.
function _wpRecKey(r) { return r.plain !== undefined ? 'P\x00' + r.plain : 'R\x00' + r.head + '\x00' + r.cont.join('\x00'); }
function _wpCollapse(recs) {
  const out = [];
  for (const r of recs) {
    const prev = out[out.length - 1];
    if (prev && _wpRecKey(prev) === _wpRecKey(r)) prev.count = (prev.count || 1) + 1;
    else { r.count = 1; out.push(r); }
  }
  return out;
}
const _WLVL = { Info: 'info', Warning: 'warn', Error: 'error', Debug: 'debug' };
function _wpFmtRecord(rec) {
  const badge = rec.count > 1 ? '<span class="wlog-x">×' + rec.count + '</span>' : '';
  if (rec.plain !== undefined) return '<div class="wlog-rec wlog-plain">' + _wpEsc(rec.plain) + badge + '</div>';
  let h = rec.head, ts = '';
  const mt = h.match(/^(\d{2}:\d{2}:\d{2})\s+/); if (mt) { ts = mt[1]; h = h.slice(mt[0].length); }
  let lvl = '', msg = h;
  const ml = h.match(/^(Info|Warning|Error|Debug):\s*([\s\S]*)$/); if (ml) { lvl = ml[1]; msg = ml[2]; }
  const cont = rec.cont.map(c => {
    const loc = c.match(/^@\s+([\s\S]*)$/);
    return loc ? '<div class="wlog-loc">@ ' + _wpEsc(loc[1]) + '</div>'
               : '<div class="wlog-cont">' + _wpEsc(c) + '</div>';
  }).join('');
  return '<div class="wlog-rec wlog-' + (_WLVL[lvl] || 'info') + '">' +
    (ts ? '<span class="wlog-ts">' + ts + '</span>' : '') +
    (lvl ? '<span class="wlog-lvl">' + lvl + '</span>' : '') +
    '<span class="wlog-msg">' + _wpEsc(msg) + '</span>' + badge + cont + '</div>';
}
// Re-render the open popup's log from `_wpRaw` (chronological): parse → records → newest-first.
function _wpRenderLog(note) {
  const box = document.getElementById('workerpop-log'); if (!box) return;
  if (!_wpRaw.length) { box.textContent = note ? '(' + note + ')' : '(no log yet)'; return; }
  const atTop = box.scrollTop < 30;
  box.innerHTML = _wpCollapse(_wpParseRecords(_wpRaw)).reverse().map(_wpFmtRecord).join('');
  if (atTop) box.scrollTop = 0;                                 // stay pinned to the newest unless scrolled down
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

// Display label for a worker. "" = the main/local kernel; a region shows "name · host".
function _wpLabel(side, host) {
  if (!side) return host || 'local';
  return side + (host ? ' · ' + host : '');
}

// Region pills + the main worker's compact stat on the #runloc pill. Called from updateChrome on every state.
function renderWorkers(state) {
  const ws = (state && state.workers) || [];
  // Drop live samples for workers no longer present (a reaped region), so a restarted one can't show a
  // stale number for a frame; keep '' (main) and every current side.
  const keep = new Set(['', ...ws.map(w => w.side || '')]);
  for (const k of Object.keys(_wpLive)) if (!keep.has(k)) delete _wpLive[k];
  const rls = document.getElementById('runlocstat');            // main worker's stat rides the #runloc pill
  if (rls) { const main = ws.find(w => !w.side); rls.textContent = _wpPillStat(_wpLive[''] || (main && main.stats)); }
  const box = document.getElementById('workerpills'); if (!box) return;
  box.innerHTML = ws.filter(w => w.side).map(w => {
    const label = _wpLabel(w.side, w.host);
    const stat = _wpPillStat(_wpLive[w.side] || w.stats);
    // No inline onclick — a side name with a quote would break the attribute (`JSON.stringify` emits ")
    // and truncate the handler. Opened via delegation off `data-side` (see the listener below) instead.
    return '<span class="wpill' + (w.connected ? '' : ' reconnecting') + '" data-side="' + _wpEsc(w.side) +
      '" title="region ‘' + _wpEsc(label) +
      '’ — click for its live log &amp; status">🖧 ' + _wpEsc(label) +
      (stat ? ' <span class="wstat">' + _wpEsc(stat) + '</span>' : '') + (w.connected ? '' : ' · …') + '</span>';
  }).join('');
}

// A worker telemetry sample pushed over the WS → update its pill face live (and the popup breakdown if
// that side's popup is open), WITHOUT waiting for the next notebook state. `side===""` is the main worker.
function onWorkerTelemetry(side, statsJson) {
  side = side || '';
  _wpLive[side] = statsJson;
  if (!side) {
    const rls = document.getElementById('runlocstat'); if (rls) rls.textContent = _wpPillStat(statsJson);
  } else {
    const box = document.getElementById('workerpills');
    const pill = box && box.querySelector('.wpill[data-side="' + (window.CSS && CSS.escape ? CSS.escape(side) : side) + '"]');
    if (pill) {
      const txt = _wpPillStat(statsJson);
      let el = pill.querySelector('.wstat');
      if (txt && !el) { el = document.createElement('span'); el.className = 'wstat'; pill.appendChild(document.createTextNode(' ')); pill.appendChild(el); }
      if (el) el.textContent = txt;
    }
  }
  if (_wpSide === side) {                                        // popup for this side is open — refresh its stat chips
    const el = document.getElementById('workerpop-stats'); if (el) el.innerHTML = _wpStatsChips(statsJson);
  }
}

// A worker log line pushed over the WS → prepend it to the open popup for that side (newest-first, matching
// the snapshot render). Ignored unless that side's popup is showing; the log file keeps the full history.
function onWorkerLog(side, line) {
  side = side || '';
  if (_wpSide !== side) return;                                 // only the open popup's side; the log file keeps history
  _wpRaw.push(line);
  if (_wpRaw.length > _WP_LOG_MAX) _wpRaw.splice(0, _wpRaw.length - _WP_LOG_MAX);
  _wpRenderLog();
}

function openWorkerPop(side, ev) {
  ev && ev.stopPropagation();
  _wpSide = side;
  const bg = document.getElementById('workerpopbg'); if (!bg) return;
  _wpRaw = [];
  document.getElementById('workerpop-log').textContent = 'loading…';
  document.getElementById('workerpop-stats').textContent = '';
  bg.classList.add('show');
  _wpRefresh();   // ONE snapshot for history + title/status; live stats & new log lines then arrive via the WS push
}
function closeWorkerPop() {
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
  document.getElementById('workerpop-stats').innerHTML = _wpStatsChips(r.stats, r.note);
  // Seed the chronological buffer from the snapshot; live lines then append via onWorkerLog. Parsed + rendered
  // newest-record-first so multi-line records stay right-way-up. Trailing blank line from the file is dropped.
  _wpRaw = r.log ? r.log.split('\n').filter((l, i, a) => l.length || i < a.length - 1) : [];
  _wpRenderLog(r.note);
}

window.renderWorkers = renderWorkers;
window.openWorkerPop = openWorkerPop;
window.closeWorkerPop = closeWorkerPop;
window.onWorkerTelemetry = onWorkerTelemetry;
window.onWorkerLog = onWorkerLog;

// Region pills open their popup via delegation off the stable `data-side` attribute (no inline handler —
// see renderWorkers). The main worker rides the #runloc pill's own onclick.
document.addEventListener('click', e => {
  const pill = e.target && e.target.closest ? e.target.closest('#workerpills .wpill[data-side]') : null;
  if (pill) openWorkerPop(pill.getAttribute('data-side'), e);
});
// Backdrop click / Esc close (mirrors the run-location modal).
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'workerpopbg') closeWorkerPop(); });
document.addEventListener('keydown', e => {
  const bg = document.getElementById('workerpopbg');
  if (e.key === 'Escape' && bg && bg.classList.contains('show')) { e.stopPropagation(); closeWorkerPop(); }
}, true);
