// ── Worker / region status pills + live log popup ─────────────────────────────────────────────────
// One pill per worker the notebook uses: the MAIN worker rides the existing #runloc pill, each ACTIVE
// region gets a pill in #workerpills. Clicking a pill body opens a popup with that worker's LOG (polled
// live while open) plus its diagnostics (process + host cpu/mem, from the 2s telemetry). The #runloc
// pill's ▾ caret still opens the run-location picker (change WHERE it runs); the body opens this popup.

let _wpSide = null;
let _wpShown = null;   // the row the open popup is drawn from, for the clock tick below
// side → freshest telemetry JSON string, PUSHED over the page WebSocket (window.onWorkerTelemetry). Fresher
// than state.workers[].stats (which only refreshes on a notebook version-bump), so the pills read it first.
const _wpLive = {};
// side → the freshest status NOTE ("why this worker is unwell"). Kept separately from the telemetry
// because the two arrive on different pushes: a stats sample says nothing about health, so the note
// has to survive one rather than be re-derived from it.
const _wpNote = {};
let _wpRaw = [];                  // chronological raw log lines for the OPEN popup (snapshot + streamed), re-parsed on each change
let _wpWorkers = [];              // latest worker list — the popup's tab strip, kept in step with the pills
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
  // Both paths into the pills come through here — the full notebook state and the pushed list — so
  // this is where the model is fed. Everything downstream reads it rather than this array.
  window.slateModel.applyWorkers(ws);
  // Cheap, non-jarring bits run NOW (never debounced): drop live samples for vanished workers, and the main
  // worker's compact stat on the #runloc pill.
  const keep = new Set(['', ...ws.map(w => w.side || '')]);
  for (const k of Object.keys(_wpLive)) if (!keep.has(k)) delete _wpLive[k];
  // The strip (main worker + regions) is debounced — one paint per burst, from the LATEST list.
  _wpPendingWs = ws;
  _wpWorkers = ws;                 // the popup's tab strip reads the same list
  if (_wpPaintTimer) return;
  _wpPaintTimer = setTimeout(() => {
    _wpPaintTimer = null; _wpPaintStrip(_wpPendingWs);
    _wpSide === null || _wpPaintTabs();   // a worker appearing/leaving changes the open popup's tabs
  }, 160);
}

// Severity rank — the most attention-worthy worker surfaces first; everything calmer folds away. The main is
// ranked like any other (no special-casing): 4 disconnected · 3 degraded · 2 starting · 1 running · 0 idle-ok.
function _wpSeverity(w) {
  const st = window.slateModel.workerStatus(w);
  if (st === 'disconnected') return 4;
  if (st === 'degraded') return 3;
  if (st === 'connecting') return 2;
  let s = null; try { s = JSON.parse(_wpLive[w.side || ''] || w.stats || 'null'); } catch (_) {}
  return (s && s.evals > 0) ? 1 : 0;
}

// The pill/row FACE — the compact status or stat, shared by the top pill and the dropdown rows.
// The server sends a code for WHY a worker is not connected; the words are here. `note` is still a
// free-text line for the one case that is commentary rather than state — a bring-up in progress.
function _wpNoteText(w) {
  if (!w) return '';
  switch (w.noteCode) {
    case 'allocation_ended':
      return 'the allocation on ' + (w.noteHost || 'the compute node') + ' ended — the next run requests a new node';
    case 'not_signed_in':
      return 'not signed in to ' + (w.noteHost || 'the host') + ' — use the padlock at the top of the page';
    case 'unresponsive':
      return 'worker stopped responding — press ▶ or re-run to reconnect';
    default:
      return w.note || '';
  }
}

function _wpFace(w) {
  const st = window.slateModel.workerStatus(w);
  // A server-named state wins: "connecting" is a poor description of a region sitting in a
  // scheduler queue, and only the server knows which it is.
  if (w.face && st !== 'ok') return w.face;
  if (st === 'degraded') return '⚠ ' + _wpUnwellShort(_wpNoteText(w));
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
  box.innerHTML = '<span class="wpill wpill-top' + cls + '" data-toplist data-side="' + _wpEsc(side) +
    '" title="' + _wpEsc(_wpLabel(side, top.host) + (ranked.length > 1 ? ' — click for all ' + ranked.length + ' workers' : ' — click for details')) +
    '"><span class="wtopicon">' + icon + '</span><span class="wtoplabel">' + _wpEsc(_wpLabel(side, top.host)) + '</span>' +
    (face ? '<span class="wstat">' + _wpEsc(face) + '</span>' : '') + caret +
    '<div class="wpill-menu" hidden>' + rows + '</div></span>';
}

// Health dot for a dropdown row: 🟢 ok · 🟡 degraded · 🟠 connecting/disconnected.
function _wpOverflowDot(w) { const st = window.slateModel.workerStatus(w);
  return st === 'degraded' ? '🟡' : (st === 'ok' ? '🟢' : '🟠'); }

// Short reason for a degraded pill face — pull the "Ns" out of the note ("no liveness reply for 18s …").
function _wpUnwellShort(note) { const m = note && /(\d+)s/.exec(note); return m ? m[1] + 's no reply' : 'unresponsive'; }

// The worker/pill list pushed over the WS (region spawn-start/connect, and every liveness miss/recovery)
// → redraw the pills immediately, without waiting for the next full notebook state. If a popup is open for
// one of these workers, refresh its status/note chips too so the degraded countdown ticks live in the popup.
function onWorkersUpdate(ws) {
  try {
    ws = ws || [];
    renderWorkers({ workers: ws });       // feeds the model on the way through
    // The cell chips carry the same worker fact as the pills, so they follow the same push rather
    // than waiting for the next full state render.
    window.refreshRegionChips && window.refreshRegionChips();
    if (_wpSide !== null) {
      const w = ws.find(x => (x.side || '') === _wpSide);
      if (w) {
        _wpNote[_wpSide] = _wpNoteText(w);
        const el = document.getElementById('workerpop-stats'); if (el) el.innerHTML = _wpStatsChips(_wpLive[_wpSide] || w.stats, _wpNoteText(w));
      }
    }
    // Live aliveness for the DAG region containers: hand the freshest list to the pane so its
    // header status dots (and any open region card) track liveness drops/recoveries at once.
    if (window._dagOnWorkers) window._dagOnWorkers(ws);
  } catch (_) {}
}

// A worker telemetry sample pushed over the WS → update its pill face live (and the popup breakdown if
// that side's popup is open), WITHOUT waiting for the next notebook state. `side===""` is the main worker.
function onWorkerTelemetry(side, statsJson, alloc) {
  side = side || '';
  _wpLive[side] = statsJson;
  // The allocation clocks ride this frame. They used to be dropped in wscall.js, so the popup's
  // walltime and idle rows came from the one-shot fetch that opened it and then stood still.
  window.slateModel.applyTelemetry(side, statsJson, alloc);
  if (_wpSide === side && _wpShown && alloc) {
    for (const k of ['scheduler', 'held', 'allocState', 'walltimeLeft',
                     'idleRelease', 'idleWarn', 'idleFor']) delete _wpShown[k];
    Object.assign(_wpShown, alloc);
    _wpShown._at = Date.now();          // these ages are as of NOW, so the tick counts from here
    const ib = document.getElementById('workerpop-ident'); if (ib) ib.innerHTML = _wpIdentChips(_wpShown);
    const ab = document.getElementById('workerpop-acts');  if (ab) ab.innerHTML = _wpActions(_wpShown);
  }
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
    // Carry the note through: a telemetry tick is not news about the worker's HEALTH, and rendering
    // the chips without it made the reason the popup was opened for vanish on the next sample.
    const el = document.getElementById('workerpop-stats');
    if (el) el.innerHTML = _wpStatsChips(statsJson, _wpNote[side] || '');
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
// visible tab, calm ones fold into `+N ▾`. Live dots come from `_wpLive`, which already streams for
// every worker, so only the LOG is per-tab work — fetched on switch, one buffer, so the line cap
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
    const side = w.side || '';
    return '<button class="wptab' + (side === _wpSide ? ' on' : '') + '" data-wptab="' + _wpEsc(side) + '">' +
      _wpOverflowDot(w) + ' ' + _wpEsc(_wpLabel(side, w.host)) + '</button>';
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
  const since = (Date.now() - (+r._at || Date.now())) / 1000;
  if (+r.walltimeLeft >= 0) row('walltime', _wpDur(+r.walltimeLeft - since) + ' left');
  // A rate that has not been fitted yet is shown as unknown, not as zero: "0ppm" would claim these
  // clocks were measured and found not to drift.
  if (r.clockSamples) {
    const ppm = (r.clockDriftPpm === undefined || r.clockDriftPpm === null) ? '--' : r.clockDriftPpm + 'ppm';
    row('clock', '±' + r.clockRttMs + 'ms · ' + ppm);
  }
  if (+r.idleRelease > 0) {
    const idle = (+r.idleFor || 0) + since;
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
  const log = document.getElementById('workerpop-log'); if (log) log.textContent = 'loading…';
  const st = document.getElementById('workerpop-stats'); if (st) st.textContent = '';
  const id = document.getElementById('workerpop-ident'); if (id) id.innerHTML = '';
  _wpPaintTabs();
  _wpRefresh();
}

function openWorkerPop(side, ev, pin) {
  ev && ev.stopPropagation();   // opened from a click → don't let it bubble to the document close-on-outside-click handler
  _wpSide = side;
  if (pin) _wpPinned = true;    // a deliberate click (e.g. a region card's Log) opens PINNED so it stays put
  const bg = document.getElementById('workerpopbg'); if (!bg) return;
  _wpRaw = [];
  document.getElementById('workerpop-log').textContent = 'loading…';
  document.getElementById('workerpop-stats').textContent = '';
  const idb = document.getElementById('workerpop-ident'); if (idb) idb.innerHTML = '';
  bg.classList.add('show');
  _wpUpdatePin();
  _wpPaintTabs();   // opens on the worker you clicked, with its siblings alongside
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
  catch (_) { r = null; }
  if (_wpSide !== side) return;                                  // switched to another region (or closed) mid-fetch → stale response, drop it
  // An app REFUSES the worker-log route (a log can carry notebook data, and an app's visitor is not
  // its operator), so the panel has to stand on what /state already gave us: identity and telemetry
  // are there, and only the log is missing. Saying where it lives beats a pane stuck on "loading…".
  if (!r || typeof r !== 'object' || r.log === undefined) {
    const w = (_wpWorkers || []).find(x => (x.side || '') === side);
    r = Object.assign({ side: side }, w || {}, { log: "" , _noLog: true });
  }
  const dot = _wpOverflowDot(r);   // same rank as every other dot: degraded outranks a live wire
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
  _wpNote[side] = _wpNoteText(r);
  r._at = Date.now();          // anchor the server's ages in this machine's clock
  _wpShown = r;
  const idb = document.getElementById('workerpop-ident');
  if (idb) idb.innerHTML = _wpIdentChips(r);
  const ab = document.getElementById('workerpop-acts');
  if (ab) ab.innerHTML = _wpActions(r);
  document.getElementById('workerpop-stats').innerHTML = _wpStatsChips(r.stats, _wpNoteText(r));
  // Seed the chronological buffer from the snapshot; live lines then append via onWorkerLog. Parsed + rendered
  // newest-record-first so multi-line records stay right-way-up. Trailing blank line from the file is dropped.
  _wpRaw = r.log ? r.log.split('\n').filter((l, i, a) => l.length || i < a.length - 1) : [];
  if (r._noLog) {
    const box = document.getElementById('workerpop-log');
    if (box) box.innerHTML = '<div class="wplog-none">Worker logs are an operator view, not a reader ' +
      'one — a log can carry the notebook\'s own data, so an app does not serve them here.<br>' +
      '<a href="/status" target="_blank" rel="noopener">/status</a> has them, one worker at a time.' +
      '</div>';
  } else {
    _wpRenderLog();
  }
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

// The allocation clocks tick between pushes: redraw them every second while a popup is open so a
// walltime does not sit still until the next sample arrives.
setInterval(() => {
  if (_wpSide === null || !_wpShown) return;
  if (!window.slateModel.isHeld(_wpShown)) return;   // nothing held, nothing counting down
  const idb = document.getElementById('workerpop-ident');
  if (idb) idb.innerHTML = _wpIdentChips(_wpShown);
}, 1000);
