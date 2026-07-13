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
  // A degraded/disconnected/starting worker carries a `note` explaining WHY — show it as a leading warning
  // chip so the popup says what's wrong even when telemetry is stale or absent (was a bare "(no log yet)").
  const warn = note ? '<span class="wchip wchip-warn">⚠ ' + _wpEsc(note) + '</span>' : '';
  let s; if (statsJson) { try { s = JSON.parse(statsJson); } catch (_) { s = null; } }
  if (!s) return warn;
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
  return warn + p.join('');
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
  // While the worker is still importing/precompiling its packages, show that progress on the pill face
  // instead of cpu·rss (which is meaningless mid-boot). `warm` is the worker's _WARM_STATUS —
  // "warming n/total · Pkg" during preload, then "ready · …" (which falls through to cpu·rss below).
  if (s.warm && s.warm.indexOf('warming') === 0) return '⏳ ' + s.warm;
  const p = [];
  if (s.cpu >= 1) p.push(Math.round(s.cpu) + '%');   // hide 0% on a resting worker — it's just noise (popup still shows it)
  if (s.rss > 0) p.push(_wpMB(s.rss));
  return p.join(' · ');
}

// Display label for a worker. "" = the main/local kernel; a region shows "name · host".
function _wpLabel(side, host) {
  if (!side) return host || 'local';
  return side + (host ? ' · ' + host : '');
}

// Region pills + the main worker's compact stat on the #runloc pill. Called from updateChrome on every state
// AND from the WS worker-list push. Two things keep the strip calm and scalable:
//  • DEBOUNCE — the push races the full-state render (each may carry a slightly different list); coalescing
//    to one paint per burst kills the flicker/pop the two used to cause.
//  • SALIENT + overflow — only workers that need attention (running / starting / degraded / disconnected)
//    stay inline; idle-healthy ones fold into a "+N ▾" menu, so the bar stays bounded for any number of regions.
let _wpPendingWs = [], _wpPaintTimer = null;
function renderWorkers(state) {
  const ws = (state && state.workers) || [];
  // Cheap, non-jarring bits run NOW (never debounced): drop live samples for vanished workers, and the main
  // worker's compact stat on the #runloc pill.
  const keep = new Set(['', ...ws.map(w => w.side || '')]);
  for (const k of Object.keys(_wpLive)) if (!keep.has(k)) delete _wpLive[k];
  // The strip (main worker + regions) is debounced — one paint per burst, from the LATEST list.
  _wpPendingWs = ws;
  if (_wpPaintTimer) return;
  _wpPaintTimer = setTimeout(() => { _wpPaintTimer = null; _wpPaintStrip(_wpPendingWs); }, 160);
}

// Severity rank — the most attention-worthy worker surfaces first; everything calmer folds away. The main is
// ranked like any other (no special-casing): 4 disconnected · 3 degraded · 2 starting · 1 running · 0 idle-ok.
function _wpSeverity(w) {
  const st = w.status || (w.connected ? 'ok' : 'connecting');
  if (st === 'disconnected') return 4;
  if (st === 'degraded') return 3;
  if (st === 'connecting') return 2;
  let s = null; try { s = JSON.parse(_wpLive[w.side || ''] || w.stats || 'null'); } catch (_) {}
  return (s && s.evals > 0) ? 1 : 0;
}

// The pill/row FACE — the compact status or stat, shared by the top pill and the dropdown rows.
function _wpFace(w) {
  const st = w.status || (w.connected ? 'ok' : 'connecting');
  if (st === 'degraded') return '⚠ ' + _wpUnwellShort(w.note);
  if (st === 'disconnected') return 'disconnected';
  const stat = _wpPillStat(_wpLive[w.side || ''] || w.stats);
  if (st === 'connecting') return stat || 'starting…';
  return stat;
}

// The bar is ONE pill: the single most-salient worker (ranked disconnected > degraded > starting > running >
// idle), with its health colour + live face + more info. It doubles as the dropdown trigger — click it to list
// ALL workers ranked; lingering/hovering then reveals the detail popup (see the handlers below).
function _wpPaintStrip(ws) {
  const box = document.getElementById('workerpills'); if (!box) return;
  if (!ws.length) { box.innerHTML = ''; return; }
  const ranked = ws.slice().sort((a, b) => _wpSeverity(b) - _wpSeverity(a));
  const top = ranked[0], side = top.side || '';
  const icon = (!side && !top.host) ? '💻' : '🖧';
  const st = top.status || (top.connected ? 'ok' : 'connecting');
  const cls = st === 'degraded' ? ' degraded' : (st === 'ok' ? '' : ' reconnecting');
  const face = _wpFace(top);
  const rows = ranked.map(w => {
    const f = _wpFace(w);
    return '<div class="wpill-menuitem" data-side="' + _wpEsc(w.side || '') + '">' + _wpOverflowDot(w) + ' ' +
      _wpEsc(_wpLabel(w.side || '', w.host)) + (f ? ' <span class="wpmi-face">' + _wpEsc(f) + '</span>' : '') + '</div>';
  }).join('');
  const caret = ranked.length > 1 ? '<span class="wpill-caret">▾</span>' : '';
  // Fixed single slot: the pill reserves a min-width so it doesn't jump as the top worker changes, and the
  // LABEL elides (CSS ellipsis) if a region name is long — icon/stat/caret stay put.
  box.innerHTML = '<span class="wpill wpill-top' + cls + '" data-toplist data-side="' + _wpEsc(side) +
    '" title="' + _wpEsc(_wpLabel(side, top.host) + (ranked.length > 1 ? ' — click for all ' + ranked.length + ' workers' : ' — click for details')) +
    '"><span class="wtopicon">' + icon + '</span><span class="wtoplabel">' + _wpEsc(_wpLabel(side, top.host)) + '</span>' +
    (face ? '<span class="wstat">' + _wpEsc(face) + '</span>' : '') + caret +
    '<div class="wpill-menu" hidden>' + rows + '</div></span>';
}

// Health dot for a dropdown row: 🟢 ok · 🟡 degraded · 🟠 connecting/disconnected.
function _wpOverflowDot(w) { const st = w.status || (w.connected ? 'ok' : 'connecting');
  return st === 'degraded' ? '🟡' : (st === 'ok' ? '🟢' : '🟠'); }

// Short reason for a degraded pill face — pull the "Ns" out of the note ("no liveness reply for 18s …").
function _wpUnwellShort(note) { const m = note && /(\d+)s/.exec(note); return m ? m[1] + 's no reply' : 'unresponsive'; }

// The worker/pill list pushed over the WS (region spawn-start/connect, and every liveness miss/recovery)
// → redraw the pills immediately, without waiting for the next full notebook state. If a popup is open for
// one of these workers, refresh its status/note chips too so the degraded countdown ticks live in the popup.
function onWorkersUpdate(ws) {
  try {
    ws = ws || [];
    renderWorkers({ workers: ws });
    if (_wpSide !== null) {
      const w = ws.find(x => (x.side || '') === _wpSide);
      if (w) { const el = document.getElementById('workerpop-stats'); if (el) el.innerHTML = _wpStatsChips(_wpLive[_wpSide] || w.stats, w.note); }
    }
  } catch (_) {}
}

// A worker telemetry sample pushed over the WS → update its pill face live (and the popup breakdown if
// that side's popup is open), WITHOUT waiting for the next notebook state. `side===""` is the main worker.
function onWorkerTelemetry(side, statsJson) {
  side = side || '';
  _wpLive[side] = statsJson;
  const box = document.getElementById('workerpills');
  const pill = box && box.querySelector('.wpill[data-side="' + (window.CSS && CSS.escape ? CSS.escape(side) : side) + '"]');
  // Only patch the face when the pill is showing its normal stat — leave a degraded/reconnecting pill's status
  // text alone (the debounced re-render owns that; a stray stale sample shouldn't overwrite "⚠ Ns no reply").
  if (pill && !pill.classList.contains('degraded') && !pill.classList.contains('reconnecting')) {
    const txt = _wpPillStat(statsJson);
    let el = pill.querySelector('.wstat');
    if (txt && !el) { el = document.createElement('span'); el.className = 'wstat'; pill.appendChild(document.createTextNode(' ')); pill.appendChild(el); }
    if (el) el.textContent = txt;
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
  _wpSide = null; _wpPinned = false;
  const bg = document.getElementById('workerpopbg'); if (bg) bg.classList.remove('show');
  _wpUpdatePin();
}
async function _wpRefresh() {
  const side = _wpSide;                                          // capture: the popup can switch while we await
  if (side === null) return;
  let r; try { r = await api('GET', '/api/worker-log?side=' + encodeURIComponent(side) + '&lines=500'); }
  catch (_) { return; }
  if (_wpSide !== side) return;                                  // switched to another region (or closed) mid-fetch → stale response, drop it
  const dot = !r.connected ? '🟠' : (r.status === 'degraded' ? '🟡' : '🟢');
  document.getElementById('workerpop-title').innerHTML = dot + ' ' + (r.side ? 'region' : 'main worker') +
    ' · ' + _wpEsc(_wpLabel(r.side, r.host)) + (r.port ? ' :' + r.port : '');
  // The run-location picker (formerly the #runloc caret) lives here now — only for the MAIN worker, since a
  // region's host is fixed by its registry def. "change ▾" opens the existing picker modal.
  const rl = document.getElementById('workerpop-runloc');
  if (rl) {
    if (!r.side) { rl.style.display = ''; rl.innerHTML = 'run location: <b>' + _wpEsc(r.host || 'local') +
      '</b> <button class="wrl-change" onclick="closeWorkerPop(); toggleRunLoc(event)">change ▾</button>'; }
    else { rl.style.display = 'none'; rl.innerHTML = ''; }
  }
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
window.onWorkersUpdate = onWorkersUpdate;

// The bar's single pill IS the dropdown trigger. Click → toggle the ranked list of ALL workers. HOVERING a
// row PREVIEWS that worker in the side panel — transient: it follows the mouse and hides when you leave.
// CLICKING a row (or the panel's 📌) PINS the panel so it stays up while you work elsewhere; 📌/× to unpin.
let _wpPinned = false, _wpShowT = null, _wpHideT = null;
function _wpMenuOpen() { return !!document.querySelector('#workerpills .wpill-menu:not([hidden])'); }
function _wpCloseMenu() { const m = document.querySelector('#workerpills .wpill-menu:not([hidden])'); if (m) m.hidden = true; if (_wpShowT) { clearTimeout(_wpShowT); _wpShowT = null; } }
function _wpKeepPanel() { if (_wpHideT) { clearTimeout(_wpHideT); _wpHideT = null; } }   // over a row/panel → don't hide
function _wpUpdatePin() { const p = document.getElementById('workerpop-pin'); if (p) { p.classList.toggle('pinned', _wpPinned); p.title = _wpPinned ? 'pinned — click to unpin' : 'click to pin this panel'; } }
function _wpShowPanel(side, pin) {
  if (_wpShowT) { clearTimeout(_wpShowT); _wpShowT = null; }
  _wpKeepPanel();
  if (pin) _wpPinned = true;
  openWorkerPop(side);
  _wpUpdatePin();
}
function _wpScheduleShow(side) {                 // hover → transient preview after a short delay
  _wpKeepPanel();
  if (_wpSide === side || _wpPinned) return;     // already shown / pinned elsewhere → leave it
  if (_wpShowT) clearTimeout(_wpShowT);
  _wpShowT = setTimeout(() => { _wpShowT = null; if (_wpMenuOpen()) _wpShowPanel(side, false); }, 320);
}
function _wpScheduleHide() {                      // left the whole area → hide an UNPINNED preview
  if (_wpPinned || _wpSide === null) return;
  if (_wpShowT) { clearTimeout(_wpShowT); _wpShowT = null; }
  if (_wpHideT) clearTimeout(_wpHideT);
  _wpHideT = setTimeout(() => { _wpHideT = null; if (!_wpPinned) closeWorkerPop(); }, 260);
}
function wpTogglePin() { _wpPinned = !_wpPinned; _wpUpdatePin(); if (!_wpPinned) _wpScheduleHide(); }
window.wpTogglePin = wpTogglePin;

document.addEventListener('click', e => {
  if (!e.target || !e.target.closest) return;
  const row = e.target.closest('#workerpills .wpill-menuitem[data-side]');
  if (row) { _wpCloseMenu(); _wpShowPanel(row.getAttribute('data-side'), true); return; }   // click a row → PIN it
  const top = e.target.closest('#workerpills .wpill-top');
  if (top) { const menu = top.querySelector('.wpill-menu'); if (menu) menu.hidden ? (menu.hidden = false) : _wpCloseMenu(); e.stopPropagation(); return; }
  if (e.target.closest('#workerpopbg')) return;                 // clicks inside the panel don't dismiss it
  if (_wpMenuOpen()) _wpCloseMenu();                            // click-away closes the dropdown…
  if (!_wpPinned && _wpSide !== null) closeWorkerPop();         // …and an UNPINNED preview; a pinned panel stays
});
// Hover a row → preview it; being over any row/the panel keeps the panel; leaving the whole area hides a preview.
document.addEventListener('mouseover', e => {
  if (!e.target || !e.target.closest) return;
  const row = e.target.closest('#workerpills .wpill-menuitem[data-side]');
  if (row || e.target.closest('#workerpopbg') || e.target.closest('#workerpills .wpill-top')) _wpKeepPanel();
  if (row && _wpMenuOpen()) _wpScheduleShow(row.getAttribute('data-side'));
});
document.addEventListener('mouseout', e => {
  const to = e.relatedTarget;
  const stillIn = to && to.closest && (to.closest('#workerpills') || to.closest('#workerpopbg'));
  if (!stillIn) _wpScheduleHide();
});
// Esc closes the panel + dropdown (no backdrop now — it's a non-covering side panel).
document.addEventListener('keydown', e => {
  const bg = document.getElementById('workerpopbg');
  if (e.key === 'Escape' && ((bg && bg.classList.contains('show')) || _wpMenuOpen())) {
    e.stopPropagation(); _wpCloseMenu(); closeWorkerPop();
  }
}, true);
