// ── Worker / region status pills + live log popup ─────────────────────────────────────────────────
// One pill per worker the notebook uses: the MAIN worker rides the existing #runloc pill, each ACTIVE
// region gets a pill in #workerpills. Clicking a pill body opens a popup with that worker's LOG (polled
// live while open) plus its diagnostics (process + host cpu/mem, from the 2s telemetry). The #runloc
// pill's ▾ caret still opens the run-location picker (change WHERE it runs); the body opens this popup.

// Everything shown about a worker (its identity, health, allocation and latest sample) is read from
// the page's model (model.js), which holds the hub's facts. The panel fetches only what the facts do
// not carry: the worker's log and where it came from (`_wpProv`).
let _wpSide = null;
const _wpProv = {};               // side → {origin, spawned} from the log route, for the open panel
let _wpRaw = [];                  // chronological raw log lines for the OPEN popup (snapshot + streamed), re-parsed on each change
let _wpWorkers = [];              // the model's workers for this notebook, as last painted
// The record the open panel draws: the worker's facts, and what the log route added about it.
const _wpCurrent = () => _wpSide === null ? null
  : Object.assign({ side: _wpSide }, _wpProv[_wpSide] || {}, window.slateModel.getWorker(_wpSide) || {});
const _WP_LOG_MAX = 2000;        // cap the client-side buffer so a chatty worker can't grow it unbounded
const _wpEsc = s => window.slateEscHtml(s);
// '' for absent/negative, so a chip is omitted rather than showing a meaningless zero.
const _wpBytes = v => (v == null || v < 0) ? '' : window.slateBytes(v, { compact: true });

// A telemetry sample (JSON string) → a few meter rows (HTML): CPU, memory and each GPU, each against
// what the worker can actually use (the job's limits where it has them, else the host's), then a line
// of the rest. Clicking it opens the telemetry view (telemetry.js) for the full picture over time.
// `note` (why the worker is unwell) leads, and shows even when there is no sample yet.
const _wpMeter = (label, frac, text, warn) => '<div class="wm-row"><span class="wm-k">' + label + '</span>' +
  '<span class="wm-bar' + (warn ? ' warn' : '') + '"><span style="width:' + (frac == null ? 0 : Math.round(Math.min(1, Math.max(0, frac)) * 100)) + '%"></span></span>' +
  '<span class="wm-v">' + text + '</span></div>';
function _wpStatsChips(statsJson, note) {
  const warn = note ? '<span class="wchip wchip-warn">⚠ ' + _wpEsc(note) + '</span>' : '';
  let s; if (statsJson) { try { s = JSON.parse(statsJson); } catch (_) { s = null; } }
  if (!s) return warn;
  const job = s.job || {}, host = s.host || {}, proc = s.proc || {};
  const rows = [];
  // CPU: this worker in cores, against what it may use (the job's allowance, else the host's cores).
  const cores = (host.cores && host.cores.length) || host.ncpu || 0, allow = job.cpus > 0 ? job.cpus : cores;
  if (s.cpu >= 0) rows.push(_wpMeter('CPU', allow ? (s.cpu / 100) / allow : s.cpu / 100,
    _wpEsc((s.cpu >= 100 ? (s.cpu / 100).toFixed(1) + ' cores' : Math.round(s.cpu) + '% of a core') + (s.sys_cpu >= 0 ? ' · host ' + Math.round(s.sys_cpu) + '%' + (cores ? ' of ' + cores : '') : ''))));
  // Memory: against the limit that would stop it.
  const lim = job.mem_max > 0 ? job.mem_max : s.sys_mem_total;
  const used = job.mem_max > 0 ? job.mem_cur : (host.mem_avail >= 0 ? s.sys_mem_total - host.mem_avail : s.sys_mem_total - s.sys_mem_free);
  if (lim > 0 && used >= 0) rows.push(_wpMeter('Memory', used / lim,
    _wpEsc(_wpBytes(used) + ' / ' + _wpBytes(lim) + (job.mem_max > 0 ? ' job limit' : ' host') + (s.rss > 0 ? ' · this worker ' + _wpBytes(s.rss) : '')),
    used / lim > 0.85));
  else if (s.rss > 0) rows.push(_wpMeter('Memory', null, _wpEsc('this worker ' + _wpBytes(s.rss))));
  for (const g of (s.gpus || [])) rows.push(_wpMeter('GPU ' + g.i, g.util >= 0 ? g.util / 100 : null,
    _wpEsc([g.util >= 0 ? g.util + '%' : null, g.mem_used >= 0 ? _wpBytes(g.mem_used) + ' / ' + _wpBytes(g.mem_total) : null,
            g.temp >= 0 ? g.temp + '°C' : null,
            g.power_w >= 0 ? Math.round(g.power_w) + (g.power_limit_w > 0 ? ' / ' + Math.round(g.power_limit_w) : '') + ' W' : null]
      .filter(Boolean).join(' · ')), g.mem_total > 0 && g.mem_used / g.mem_total > 0.9));
  const memo = s.memo_bytes ?? s.memo;
  const rest = [proc.alloc_rate >= 0 ? 'allocating ' + _wpBytes(proc.alloc_rate) + '/s' : null,
                memo >= 0 ? 'memo ' + _wpBytes(memo) : null, s.evals > 0 ? s.evals + ' running' : null,
                s.load1 >= 0 ? 'load ' + s.load1 : null].filter(Boolean);
  return warn + '<div class="wm" title="Open telemetry" onclick="wpOpenTelemetry()">' + rows.join('') +
    (rest.length ? '<div class="wm-rest">' + _wpEsc(rest.join(' · ')) + '</div>' : '') +
    '<div class="wm-open">Open telemetry ›</div></div>';
}
// The whole log of the worker the panel is showing, in the log viewer (logview.js): paged by byte
// range and searchable however large it is, with its colour kept.
window.wpOpenLog = function () {
  const side = _wpSide || '', nbid = (window.__slateState || {}).id;
  if (!nbid || !window.slateLogs) return;
  const w = (_wpWorkers || []).find(x => (x.side || '') === side) || {};
  window.slateLogs.openSource({
    key: 'worker:' + side, title: 'Worker log · ' + _wpLabel(side, w.host),
    call: (action, arg, opts) => fetch('/api/' + encodeURIComponent(nbid) + '/worker-log-io', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(Object.assign({}, opts, { side, action, arg })) }).then(r => r.json()) });
};

// The telemetry view for the worker the popup is showing.
// Host and port come from the live worker list: the popup's snapshot is the log route's answer, which
// for a region worker names neither.
window.wpOpenTelemetry = function () {
  const shown = _wpCurrent(); if (!shown || !(window.openWorkerTelemetry || window.openTelemetry)) return;
  const side = _wpSide;
  const r = Object.assign({}, shown, (_wpWorkers || []).find(w => (w.side || '') === side) || {});
  // The worker's bar (facts, restart, reap) rides along, as it does from the home page.
  (window.openWorkerTelemetry || window.openTelemetry)({ nb: (window.__slateState || {}).id, side,
    host: r.host && r.host !== 'local' ? r.host : '', port: r.port, label: _wpLabel(side, r.host) });
};

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
  for (const styled of lines) {
    // Structure first, colour second. The worker's streams are colour-enabled, so a `@warn` box line
    // now begins with an SGR sequence rather than `┌` — every test below has to run on the STRIPPED
    // text or the log stops parsing into records at all. Nothing is lost inside a record: the panel
    // already colours those by LEVEL, and Julia's own colours would only fight that. An unparsed
    // `plain` line keeps its styling, which is where the colour actually earns its place.
    const raw = window.slateAnsiText(styled);
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
    } else { cur = null; mode = null; if (raw.length) recs.push({ plain: styled }); }
  }
  return recs;
}
// Collapse consecutive IDENTICAL records into one with a ×N count — tames repetitive spam (e.g. a world-age
// warning firing every tick) without hiding anything. Only merges adjacent equal records, so ordering and
// distinct messages are untouched. Re-run on every render, so the count grows live as duplicates stream in.
// Keyed on the STRIPPED text: a plain record keeps its colour for rendering, and two repeats of the
// same line that a library happened to style differently are still the same line to a reader.
function _wpRecKey(r) {
  return r.plain !== undefined ? 'P\x00' + window.slateAnsiText(r.plain)
                               : 'R\x00' + r.head + '\x00' + r.cont.join('\x00');
}
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
  // A plain line is whatever the worker printed — Pkg output, `printstyled`, a bare println. It has no
  // level to colour by, so render its OWN colour.
  if (rec.plain !== undefined) return '<div class="wlog-rec wlog-plain">' + window.slateAnsiHtml(rec.plain) + badge + '</div>';
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
function _wpRenderLog() {
  const box = document.getElementById('workerpop-log'); if (!box) return;
  // Only ever says something about the LOG. The `note` used to be repeated here as the placeholder,
  // from before the warn chip existed — printing the same sentence twice, a few pixels apart.
  if (!_wpRaw.length) { box.textContent = '(no log yet)'; return; }
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
  if (s.rss > 0) p.push(_wpBytes(s.rss));
  // On a GPU job the GPUs' load is usually the number that matters: their mean, when busy.
  const gu = (s.gpus || []).filter(g => g.util >= 0).map(g => g.util);
  if (gu.length && Math.max(...gu) >= 1) p.push('gpu ' + Math.round(gu.reduce((a, b) => a + b, 0) / gu.length) + '%');
  return p.join(' · ');
}

// Display label for a worker. "" = the main/local kernel; a region shows "name · host".
function _wpLabel(side, host) {
  if (!side) return host || 'local';
  return side + (host ? ' · ' + host : '');
}

// The pill, the panel and its tabs, repainted whenever the model changes. Debounced, so a burst of
// changes paints once. Only workers that need attention (running / starting / degraded / disconnected)
// stay inline; idle-healthy ones fold into a "+N ▾" menu, so the bar stays bounded for any number of
// regions.
let _wpPendingWs = [], _wpPaintTimer = null;
function _wpOnModel() {
  _wpWorkers = window.slateModel.workerList();
  _wpPendingWs = _wpWorkers;
  if (_wpPaintTimer) return;
  _wpPaintTimer = setTimeout(() => {
    _wpPaintTimer = null; _wpPaintStrip(_wpPendingWs);
    if (_wpSide !== null) { _wpPaintTabs(); _wpPaintBringup(); _wpFollowRestart(); _wpDrawFacts(); }
    if (window._dagOnWorkers) window._dagOnWorkers(_wpWorkers);   // the DAG's region status dots
  }, 160);
}
window.slateModel.subscribe(_wpOnModel);
_wpOnModel();   // the facts may have landed before this script subscribed

// The open panel's worker was replaced (a restart puts the new one on another port): its log and
// where it came from are the new process's, so they are fetched again.
let _wpOpenPort = null;
const _wpPortOf = (side) => { const w = (_wpWorkers || []).find(x => (x.side || '') === side); return w ? w.port : null; };
function _wpFollowRestart() {
  if (_wpSide === null) return;
  const p = _wpPortOf(_wpSide);
  if (p == null) return;
  if (_wpOpenPort == null) { _wpOpenPort = p; return; }    // opened before the list named a port
  if (+p !== +_wpOpenPort) { _wpOpenPort = p; _wpRefresh(); }
}

// ── Bring-up ─────────────────────────────────────────────────────────────────────
// A worker being started (a cold local spawn, a remote provision, a region coming up) is narrated in
// ITS panel: the step it is on, precompile progress, and the build log, the elements prepare.js fills.
// The pill says which step it is on. `window.__slateBringup` (view.js) names the side being started.
const _wpBringingUp = (side) => { const b = window.__slateBringup; return !!b && (b.side || '') === side; };
function _wpBringupShort(side) { return _wpBringingUp(side) && window.slatePrepShort ? window.slatePrepShort() : ''; }
function _wpPaintBringup() {
  const old = document.getElementById('workerpop-bringup');
  const want = _wpSide !== null && _wpBringingUp(_wpSide);
  if (!want) { old && old.remove(); return; }
  if (!old) {
    const b = window.__slateBringup, el = document.createElement('div');
    el.id = 'workerpop-bringup'; el.className = 'workerpop-bringup';
    el.innerHTML = '<span class="hydspin"></span><div class="wpbody">' +
      '<div id="hydmsg" class="hydmsg">' + (b.kind === 'remote' ? 'Starting the worker on <b>' + _wpEsc(b.host || 'the remote host') + '</b>…' : 'Starting the worker…') + '</div>' +
      '<div id="hydprep" class="hydprep"></div>' +
      '<details id="hydraw" class="hydraw" style="display:none" ontoggle="window._prepRawToggle&&window._prepRawToggle()"><summary>build log <span id="hydrawlast" class="hydrawlast"></span></summary><pre id="hydrawpre"></pre></details></div>';
    const head = document.querySelector('#workerpopbg .workerpop-head');
    head && head.appendChild(el);
  }
  window.renderPrepare && window.renderPrepare();
}
window.wpBringupChanged = function () { _wpPaintBringup(); _wpPaintStrip(_wpPendingWs.length ? _wpPendingWs : _wpWorkers); };
window.wpPrepTick = function () {
  const b = window.__slateBringup; if (!b) return;
  const pill = document.querySelector('#workerpills .wpill-top[data-side="' + (window.CSS && CSS.escape ? CSS.escape(b.side || '') : (b.side || '')) + '"] .wstat');
  const t = window.slatePrepShort ? window.slatePrepShort() : '';
  if (pill && t && pill.textContent !== t) pill.textContent = t;
};

// Severity rank — the most attention-worthy worker surfaces first; everything calmer folds away. The main is
// ranked like any other (no special-casing): 4 disconnected · 3 degraded · 2 starting · 1 running · 0 idle-ok.
function _wpSeverity(w) {
  const st = window.slateModel.workerStatus(w);
  if (st === 'disconnected') return 4;
  if (st === 'degraded') return 3;
  if (st === 'connecting') return 2;
  let s = null; try { s = JSON.parse(w.stats || 'null'); } catch (_) {}
  return (s && s.evals > 0) ? 1 : 0;
}

// The pill/row FACE — the compact status or stat, shared by the top pill and the dropdown rows.
// The server sends a code for WHY a worker is not connected; the words are here. `note` is still a
// free-text line for the one case that is commentary rather than state — a bring-up in progress.
const _wpNoteText = (w) => window.slateModel.workerNote(w);

function _wpFace(w) {
  const st = window.slateModel.workerStatus(w);
  // A server-named state wins: "connecting" is a poor description of a region sitting in a
  // scheduler queue, and only the server knows which it is.
  if (w.face && st !== 'ok') return w.face;
  if (st === 'degraded') return '⚠ ' + _wpUnwellShort(_wpNoteText(w));
  if (st === 'disconnected') return 'disconnected';
  const stat = _wpPillStat(w.stats);
  if (st === 'connecting') return stat || _wpBringupShort(w.side || '') || 'starting…';
  return stat;
}

// The bar is ONE pill: the single most-salient worker (ranked disconnected > degraded > starting > running >
// idle), with its health colour + live face + more info. It doubles as the dropdown trigger — click it to list
// ALL workers ranked; lingering/hovering then reveals the detail popup (see the handlers below).
function _wpPaintStrip(ws) {
  const box = document.getElementById('workerpills'); if (!box) return;
  ws = ws || [];
  if (!ws.length) { box.innerHTML = ''; return; }
  const ranked = ws.slice().sort((a, b) => _wpSeverity(b) - _wpSeverity(a));
  const top = ranked[0], side = top.side || '';
  const icon = (!side && !top.host) ? '💻' : '🖧';
  const st = window.slateModel.workerStatus(top);
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
  // No `title`: hovering opens the list of workers, which would sit under the tooltip.
  const html = '<span class="wpill wpill-top' + cls + '" data-toplist data-side="' + _wpEsc(side) +
    '"><span class="wtopicon">' + icon + '</span><span class="wtoplabel">' + _wpEsc(_wpLabel(side, top.host)) + '</span>' +
    (face ? '<span class="wstat">' + _wpEsc(face) + '</span>' : '') + caret +
    '<div class="wpill-menu" hidden>' + rows + '</div></span>';
  // Repainted on every change, so the list of workers is kept open across a repaint while it is
  // showing, and a repaint that would draw the same thing touches nothing.
  if (box._wpHtml === html) return;
  const wasOpen = _wpMenuOpen();
  box.innerHTML = html; box._wpHtml = html;
  if (wasOpen) { const m = box.querySelector('.wpill-menu'); if (m) m.hidden = false; }
}

// Health dot for a dropdown row: 🟢 ok · 🟡 degraded · 🟠 connecting/disconnected.
function _wpOverflowDot(w) { const st = window.slateModel.workerStatus(w);
  return st === 'degraded' ? '🟡' : (st === 'ok' ? '🟢' : '🟠'); }

// Short reason for a degraded pill face — pull the "Ns" out of the note ("no liveness reply for 18s …").
function _wpUnwellShort(note) { const m = note && /(\d+)s/.exec(note); return m ? m[1] + 's no reply' : 'unresponsive'; }

// A worker telemetry sample pushed over the WS → into the model, and its pill face and the open
// panel's figures at once (a sample is not worth a full repaint). `side===""` is the main worker.
function onWorkerTelemetry(side, statsJson) {
  side = side || '';
  window.slateModel.applyTelemetry(side, statsJson);
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
  if (_wpSide === side) {                                        // popup for this side is open — refresh its figures
    const el = document.getElementById('workerpop-stats');
    if (el) el.innerHTML = _wpStatsChips(statsJson, _wpNoteText(_wpCurrent()));
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

// ── Tabs: one worker per tab, so reading logs across them is a click, not a re-navigation ─────────
// The dropdown that opens this panel is NAVIGATION; the tabs are COMPARISON — the question is almost
// always "main is fine, so which region is stalling?". They also buy peripheral awareness the
// dropdown can't: a red dot on a tab you are NOT reading.
//
// Ranked by severity and bounded the same way the topbar pill is: unwell workers always hold a
// visible tab, calm ones fold into `+N ▾`. Live dots come from the model, which already holds every
// worker, so only the LOG is per-tab work — fetched on switch, one buffer, so the line cap
// stays meaningful however many workers there are.
const _WP_TABS_MAX = 4;
function _wpPaintTabs() {
  const box = document.getElementById('workerpop-tabs'); if (!box) return;
  const ws = _wpWorkers || [];
  if (ws.length < 2) { box.innerHTML = ''; box.style.display = 'none'; return; }   // one worker → no tabs to pick
  box.style.display = '';
  const ranked = ws.slice().sort((a, b) => _wpSeverity(b) - _wpSeverity(a));
  // The open worker always holds a visible tab, whatever its severity — you are reading it.
  const shown = ranked.slice(0, _WP_TABS_MAX);
  if (!shown.some(w => (w.side || '') === _wpSide)) {
    const cur = ranked.find(w => (w.side || '') === _wpSide);
    cur && (shown[shown.length - 1] = cur);
  }
  const rest = ranked.filter(w => !shown.includes(w));
  const tab = w => {
    const side = w.side || '', lbl = _wpLabel(side, w.host);
    // A narrow tab ellipsizes the label, so carry the full name in the title - the tab is a picker,
    // and you should be able to read which worker it is even when the strip is crowded.
    return '<button class="wptab' + (side === _wpSide ? ' on' : '') + '" data-wptab="' + _wpEsc(side) +
      '" title="' + _wpEsc(lbl) + '">' + _wpOverflowDot(w) + ' ' + _wpEsc(lbl) + '</button>';
  };
  const more = rest.length ? '<span class="wptab-more"><button class="wptab wptab-morebtn">+' + rest.length +
    ' ▾</button><div class="wptab-menu" hidden>' +
    rest.map(w => '<div class="wptab-menuitem" data-wptab="' + _wpEsc(w.side || '') + '">' +
                  _wpOverflowDot(w) + ' ' + _wpEsc(_wpLabel(w.side || '', w.host)) + '</div>').join('') +
    '</div></span>' : '';
  box.innerHTML = shown.map(tab).join('') + more;
}

// WHERE and WHAT this worker is. Telemetry says how it is DOING; none of it answers "which host,
// over what, in which environment, and was it adopted warm" — the questions a worker that won't run
// at all raises. Only fields the server actually sent are shown, so a local worker stays short.
// Seconds as the coarsest unit that still reads exactly, for the worker chips.
function _wpDur(s) {
  s = Math.max(0, Math.round(s));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.round(s / 60) + 'm';
  if (s < 86400) return (s / 3600).toFixed(s % 3600 ? 1 : 0) + 'h';
  return (s / 86400).toFixed(s % 86400 ? 1 : 0) + 'd';
}

function _wpIdentChips(r) {
  const p = [];
  const row = (k, v) => p.push('<span class="widchip"><span class="widchip-k">' + k + '</span>' +
                               '<span class="widchip-v">' + _wpEsc(v) + '</span></span>');
  r.host && row('host', r.host);
  r.transport && row('via', r.transport);
  r.port && row('ports', [r.port, r.streamPort, r.dataPort].filter(Boolean).join(' · '));
  r.pid && row('pid', r.pid);
  r.origin && row('origin', r.origin);
  r.spawned && row('spawned', r.spawned);
  r.dataRoot && row('data', r.dataRoot);
  r.env && row('env', String(r.env).replace(/^.*\/(?=[^/]+\/[^/]+$)/, '…/'));
  // A scheduler region runs on borrowed time: the allocation's own end, and the idle timer that may
  // hand the node back sooner. Both are on the row because both end this worker. Derived from the
  // pushed instants at DRAW time, so the ticker below keeps them honest between pushes.
  // The server sends AGES, measured in its own clock; `_wpAt` is when they landed in ours. Every
  // instant here is therefore local, and a skewed hub or compute node cannot bend the display.
  const M = window.slateModel, left = M.walltimeLeft(r);
  if (left >= 0) row('walltime', _wpDur(left) + ' left');
  // A rate that has not been fitted yet is shown as unknown, not as zero: "0ppm" would claim these
  // clocks were measured and found not to drift.
  if (r.clockRttMs !== undefined) {
    const ppm = (r.clockDriftPpm === undefined || r.clockDriftPpm === null) ? '--' : r.clockDriftPpm + 'ppm';
    row('clock', '±' + r.clockRttMs + 'ms · ' + ppm);
  }
  if (+r.idleRelease > 0) {
    const idle = Math.max(0, M.idleFor(r));
    const left = +r.idleRelease - idle;
    row('idle', _wpDur(idle) + ' / ' + _wpDur(+r.idleRelease) +
                (left > 0 ? ' — releases in ' + _wpDur(left) : ' — releasing'));
  }
  return p.join('');
}


// The controls for THIS worker. Restart always keeps whatever the worker holds: a wedged process
// should not cost a node that was queued for.
//
// The second control is whichever one ENDS this worker, and that differs by what it is. Holding an
// allocation, that is releasing the node — offering a shutdown that kept the node would be a third
// button meaning "stop the process but keep paying", which restart already covers better, under a
// label that reads like the node goes back. With no allocation, stopping the process is the whole
// of it.
function _wpActions(r) {
  const M = window.slateModel, side = r.side || '';
  const b = (label, fn, cls) => '<button class="wpact' + (cls ? ' ' + cls : '') +
    '" onclick="' + fn + '">' + label + '</button>';
  const q = "'" + String(side).replace(/'/g, "\\'") + "'";
  // A queued request is withdrawn rather than released, so the label follows the allocation's state.
  const verb = M.releaseVerb(r) === 'Cancel' ? '⏏ Cancel request' : '⏏ Release node';
  return b('⟲ Restart', 'window.wpRestart(' + q + ')') +
         (M.isHeld(r) ? b(verb, 'window.wpRelease(' + q + ')', 'danger')
                      : b('■ Shut down', 'window.wpShutdown(' + q + ')', 'danger'));
}

const _wpConfirm = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls)
                                                         : Promise.resolve(window.confirm(msg)));
const _wpWhich = side => side ? 'the “' + side + '” worker' : 'the notebook’s worker';

window.wpRestart = async function (side) {
  if (!await _wpConfirm('Restart ' + _wpWhich(side) + '?\nIts namespace is cleared and the cells that ' +
                        'used it re-run. Any allocation it holds is kept.', 'Restart')) return;
  try { await window.api('POST', '/api/restart', { side }); closeWorkerPop(); } catch (_) {}
};
window.wpShutdown = async function (side) {
  if (!await _wpConfirm('Shut down ' + _wpWhich(side) + '?\nThe process is stopped and its results in ' +
                        'memory are lost. The next run starts a fresh one.', 'Shut down', 'danger')) return;
  try { await window.api('POST', '/api/worker-action', { side, action: 'shutdown' }); closeWorkerPop(); } catch (_) {}
};
window.wpRelease = async function (side) {
  if (!await _wpConfirm('Release the node held for `' + side + '`?\nIts workers are reaped and the node goes back to ' +
                        'the scheduler. The next run queues for another.', 'Release', 'danger')) return;
  try { await window.api('POST', '/api/worker-action', { side, action: 'release' }); closeWorkerPop(); } catch (_) {}
};

// Switch the panel to another worker: same panel, new subject. The log buffer is dropped (one buffer,
// re-fetched) while the tabs repaint at once so the click feels immediate.
function _wpSwitchTab(side) {
  if (side === _wpSide) return;
  _wpSide = side; _wpRaw = [];
  _wpOpenPort = _wpPortOf(side);
  _wpPaintBringup();
  const log = document.getElementById('workerpop-log'); if (log) log.textContent = 'loading…';
  const st = document.getElementById('workerpop-stats'); if (st) st.textContent = '';
  const id = document.getElementById('workerpop-ident'); if (id) id.innerHTML = '';
  _wpPaintTabs();
  _wpRefresh();
}

function openWorkerPop(side, ev, pin) {
  ev && ev.stopPropagation();   // opened from a click → don't let it bubble to the document close-on-outside-click handler
  _wpSide = side;
  _wpOpenPort = _wpPortOf(side);
  if (pin) _wpPinned = true;    // a deliberate click (e.g. a region card's Log) opens PINNED so it stays put
  const bg = document.getElementById('workerpopbg'); if (!bg) return;
  _wpRaw = [];
  document.getElementById('workerpop-log').textContent = 'loading…';
  document.getElementById('workerpop-stats').textContent = '';
  const idb = document.getElementById('workerpop-ident'); if (idb) idb.innerHTML = '';
  bg.classList.add('show');
  _wpUpdatePin();
  _wpPaintTabs();   // opens on the worker you clicked, with its siblings alongside
  _wpPaintBringup();
  _wpRefresh();   // ONE snapshot for history + title/status; live stats & new log lines then arrive via the WS push
}
function closeWorkerPop() {
  _wpSide = null; _wpPinned = false;
  _wpPaintBringup();
  const bg = document.getElementById('workerpopbg'); if (bg) bg.classList.remove('show');
  _wpUpdatePin();
}
async function _wpRefresh() {
  const side = _wpSide;                                          // capture: the popup can switch while we await
  if (side === null) return;
  let r; try { r = await api('GET', '/api/worker-log?side=' + encodeURIComponent(side) + '&lines=500'); }
  catch (_) { r = null; }
  if (_wpSide !== side) return;                                  // switched to another region (or closed) mid-fetch → stale response, drop it
  // An app REFUSES the worker-log route (a log can carry notebook data, and an app's visitor is not
  // its operator), so only the log is missing; everything else comes from the facts.
  const noLog = !r || typeof r !== 'object' || r.log === undefined;
  // What the route adds to the facts: where the process came from. The rest of its answer is the
  // same worker entry the facts carry, and is not used: the facts are the one copy.
  _wpProv[side] = noLog ? {} : { origin: r.origin, spawned: r.spawned };
  _wpDrawFacts();
  // Seed the chronological buffer from the snapshot; live lines then append via onWorkerLog. Parsed + rendered
  // newest-record-first so multi-line records stay right-way-up. Trailing blank line from the file is dropped.
  _wpRaw = (!noLog && r.log) ? r.log.split('\n').filter((l, i, a) => l.length || i < a.length - 1) : [];
  if (noLog) {
    const box = document.getElementById('workerpop-log');
    if (box) box.innerHTML = '<div class="wplog-none">Worker logs are an operator view, not a reader ' +
      'one — a log can carry the notebook\'s own data, so an app does not serve them here.<br>' +
      '<a href="/status" target="_blank" rel="noopener">/status</a> has them, one worker at a time.' +
      '</div>';
  } else {
    _wpRenderLog();
  }
}

// The open panel's title, picker, identity, actions and figures, from the model. Called when the panel
// opens, whenever the model changes, and every second while an allocation clock is showing.
function _wpDrawFacts() {
  const r = _wpCurrent(); if (!r) return;
  const dot = _wpOverflowDot(r);   // same rank as every other dot
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
  const idb = document.getElementById('workerpop-ident');
  if (idb) idb.innerHTML = _wpIdentChips(r);
  const ab = document.getElementById('workerpop-acts');
  if (ab) ab.innerHTML = _wpActions(r);
  const st = document.getElementById('workerpop-stats');
  if (st) st.innerHTML = _wpStatsChips(r.stats, _wpNoteText(r));
}

window.openWorkerPop = openWorkerPop;
window.closeWorkerPop = closeWorkerPop;
window.onWorkerTelemetry = onWorkerTelemetry;
window.onWorkerLog = onWorkerLog;

// The bar's single pill. HOVERING it (after the tooltip delay from Settings) opens the ranked list of ALL
// workers; leaving the pill, the list and the panel closes it. CLICKING the pill opens its worker's panel
// PINNED. Hovering a row PREVIEWS that worker in the side panel, which follows the mouse and hides when you
// leave; clicking a row (or the panel's 📌) PINS it so it stays up while you work elsewhere; 📌/× to unpin.
let _wpPinned = false, _wpShowT = null, _wpHideT = null, _wpMenuT = null;
let _wpMenuHeld = false;   // the pill was just clicked: no list until the pointer leaves it
function _wpHoverDelay() {
  const n = parseInt(localStorage.getItem('slateTipDelay'), 10);
  return Number.isFinite(n) && n >= 0 ? n : (window.slateTipDefaultDelay ? window.slateTipDefaultDelay() : 400);
}
function _wpScheduleMenu(top) {
  if (_wpMenuOpen() || _wpMenuT || _wpMenuHeld) return;
  _wpMenuT = setTimeout(() => { _wpMenuT = null; const m = top.querySelector('.wpill-menu'); if (m && top.isConnected) m.hidden = false; },
                        _wpHoverDelay());
}
function _wpMenuOpen() { return !!document.querySelector('#workerpills .wpill-menu:not([hidden])'); }
function _wpCloseMenu() {
  const m = document.querySelector('#workerpills .wpill-menu:not([hidden])'); if (m) m.hidden = true;
  if (_wpShowT) { clearTimeout(_wpShowT); _wpShowT = null; }
  if (_wpMenuT) { clearTimeout(_wpMenuT); _wpMenuT = null; }
}
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
function _wpScheduleHide() {                      // left the whole area → close the list, hide an UNPINNED preview
  if (_wpMenuT) { clearTimeout(_wpMenuT); _wpMenuT = null; }
  if (_wpMenuOpen()) {
    if (_wpHideT) clearTimeout(_wpHideT);
    _wpHideT = setTimeout(() => { _wpHideT = null; _wpCloseMenu(); if (!_wpPinned && _wpSide !== null) closeWorkerPop(); }, 260);
    return;
  }
  if (_wpPinned || _wpSide === null) return;
  if (_wpShowT) { clearTimeout(_wpShowT); _wpShowT = null; }
  if (_wpHideT) clearTimeout(_wpHideT);
  _wpHideT = setTimeout(() => { _wpHideT = null; if (!_wpPinned) closeWorkerPop(); }, 260);
}
function wpTogglePin() { _wpPinned = !_wpPinned; _wpUpdatePin(); if (!_wpPinned) _wpScheduleHide(); }
window.wpTogglePin = wpTogglePin;
function _wpCloseTabMenu() { const m = document.querySelector('#workerpop-tabs .wptab-menu:not([hidden])'); if (m) m.hidden = true; }

document.addEventListener('click', e => {
  if (!e.target || !e.target.closest) return;
  // A tab (or an overflow row) switches the panel's subject. Handled before the panel-is-clicked
  // guard below, and it PINS: you came here to read, not to have it vanish on the next mouseout.
  const tab = e.target.closest('#workerpop-tabs [data-wptab]');
  if (tab) {
    _wpCloseTabMenu(); _wpPinned = true; _wpUpdatePin();
    _wpSwitchTab(tab.getAttribute('data-wptab')); e.stopPropagation(); return;
  }
  const tmore = e.target.closest('#workerpop-tabs .wptab-morebtn');
  if (tmore) {
    const m = tmore.parentElement.querySelector('.wptab-menu');
    if (m) m.hidden ? (m.hidden = false) : (m.hidden = true);
    e.stopPropagation(); return;
  }
  _wpCloseTabMenu();
  const row = e.target.closest('#workerpills .wpill-menuitem[data-side]');
  if (row) { _wpCloseMenu(); _wpShowPanel(row.getAttribute('data-side'), true); return; }   // click a row → PIN it
  const top = e.target.closest('#workerpills .wpill-top');
  if (top) {                                                    // the pill → its worker's panel, pinned; again closes it
    const side = top.getAttribute('data-side') || '';
    _wpCloseMenu(); _wpMenuHeld = true;
    (_wpPinned && _wpSide === side) ? closeWorkerPop() : _wpShowPanel(side, true);
    e.stopPropagation(); return;
  }
  if (e.target.closest('#workerpopbg')) return;                 // clicks inside the panel don't dismiss it
  if (_wpMenuOpen()) _wpCloseMenu();                            // click-away closes the dropdown…
  if (!_wpPinned && _wpSide !== null) closeWorkerPop();         // …and an UNPINNED preview; a pinned panel stays
});
// Hover a row → preview it; being over any row/the panel keeps the panel; leaving the whole area hides a preview.
document.addEventListener('mouseover', e => {
  if (!e.target || !e.target.closest) return;
  const row = e.target.closest('#workerpills .wpill-menuitem[data-side]');
  const top = e.target.closest('#workerpills .wpill-top');
  if (row || top || e.target.closest('#workerpopbg')) _wpKeepPanel();
  if (top && !row) _wpScheduleMenu(top);
  if (row && _wpMenuOpen()) _wpScheduleShow(row.getAttribute('data-side'));
});
document.addEventListener('mouseout', e => {
  const to = e.relatedTarget;
  if (!(to && to.closest && to.closest('#workerpills .wpill-top'))) _wpMenuHeld = false;
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

// What counts from an instant (an allocation's walltime, its idle stretch, how long a worker has not
// answered) is redrawn every second: the facts change only when the system does, so nothing else
// would move these.
setInterval(() => {
  if (_wpWorkers.some(w => w.noteCode === 'no_reply')) _wpPaintStrip(_wpWorkers);
  const r = _wpCurrent();
  if (!r) return;
  if (!window.slateModel.isHeld(r) && r.noteCode !== 'no_reply') return;   // nothing counting
  const st = document.getElementById('workerpop-stats');
  if (st && r.noteCode === 'no_reply') st.innerHTML = _wpStatsChips(r.stats, _wpNoteText(r));
  const idb = document.getElementById('workerpop-ident');
  if (idb) idb.innerHTML = _wpIdentChips(r);
}, 1000);
