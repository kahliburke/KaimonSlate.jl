// ── Worker / region status pill + bottom dock ─────────────────────────────────────────────────────
// The topbar pill shows the most attention-worthy worker; hovering it lists them all. Clicking the pill
// or a row opens the dock along the bottom of the page: every worker on the left, the selected one's
// controls and figures (from the 2s telemetry) in the middle, and its live log filling the rest.

// Everything shown about a worker (its identity, health, allocation and latest sample) is read from
// the page's model (model.js), which holds the hub's facts. The dock fetches only what the facts do
// not carry: the worker's log and where it came from (`_wpProv`).
let _wpSide = null;
const _wpProv = {};               // side → {origin, spawned} from the log route, for the open dock
let _wpTab = localStorage.getItem('slateWorkerDockTab') === 'log' ? 'log' : 'tel';   // the dock's open tab
let _wpWorkers = [];              // the model's workers for this notebook, as last painted
// The record the open dock draws: the worker's facts, and what the log route added about it.
const _wpCurrent = () => _wpSide === null ? null
  : Object.assign({ side: _wpSide }, _wpProv[_wpSide] || {}, window.slateModel.getWorker(_wpSide) || {});
const _wpEsc = s => window.slateEscHtml(s);
// '' for absent/negative, so a chip is omitted rather than showing a meaningless zero.
const _wpBytes = v => (v == null || v < 0) ? '' : window.slateBytes(v, { compact: true });

// A telemetry sample (JSON string) → a few meter rows (HTML): CPU, memory and each GPU, each against
// what the worker can actually use (the job's limits where it has them, else the host's), then a line
// of the rest. Clicking it opens the telemetry view (telemetry.js) for the full picture over time.
// `note` (why the worker is unwell) leads, and shows even when there is no sample yet.
// `peak`, when given, is the busiest moment in the sample's interval: a translucent band behind the bar.
const _wpPct = f => Math.round(Math.min(1, Math.max(0, f)) * 100);
const _wpMeter = (label, frac, text, warn, peak) => '<div class="wm-row"><span class="wm-k">' + label + '</span>' +
  '<span class="wm-bar' + (warn ? ' warn' : '') + '">' +
  (peak != null && frac != null && peak > frac ? '<span class="wm-peak" style="width:' + _wpPct(peak) + '%"></span>' : '') +
  '<span class="wm-fill" style="width:' + (frac == null ? 0 : _wpPct(frac)) + '%"></span></span>' +
  '<span class="wm-v">' + text + '</span></div>';
function _wpStatsChips(statsJson, note) {
  const warn = note ? '<span class="wchip wchip-warn">⚠ ' + _wpEsc(note) + '</span>' : '';
  let s; if (statsJson) { try { s = JSON.parse(statsJson); } catch (_) { s = null; } }
  if (!s) return warn;
  const r = window.slateModel.reading(s), proc = s.proc || {}, B = _wpBytes;
  const rows = [];
  // CPU: this worker, against what it may use (the job's allowance, else the host's cores).
  if (r.cpu != null) rows.push(_wpMeter('CPU', r.cpuFrac,
    _wpEsc(r.cpuText + (r.hostCpu != null ? ' · host ' + Math.round(r.hostCpu) + '%' + (r.hostCores ? ' of ' + r.hostCores : '') : ''))));
  // Memory: against the limit that would stop it.
  if (r.mem) rows.push(_wpMeter('Memory', r.memFrac,
    _wpEsc(B(r.mem.used) + ' / ' + B(r.mem.limit) + (r.mem.of === 'job' ? ' job limit' : ' host') + (r.rss ? ' · this worker ' + B(r.rss) : '')),
    r.memFrac > 0.85));
  else if (r.rss) rows.push(_wpMeter('Memory', null, _wpEsc('this worker ' + B(r.rss))));
  for (const g of r.gpus) rows.push(_wpMeter('GPU ' + g.i, g.util == null ? null : g.util / 100,
    _wpEsc([g.util != null ? g.util + '%' + (g.peak != null ? ' · peak ' + g.peak + '%' : '') : null,
            g.memUsed != null && g.memTotal ? B(g.memUsed) + ' / ' + B(g.memTotal) : null,
            g.temp != null ? g.temp + '°C' : null,
            g.power != null ? Math.round(g.power) + (g.powerLimit ? ' / ' + Math.round(g.powerLimit) : '') + ' W' : null]
      .filter(Boolean).join(' · ')), g.memTotal && g.memUsed / g.memTotal > 0.9,
    g.peak == null ? null : g.peak / 100));
  const memo = s.memo_bytes ?? s.memo;
  const rest = [proc.alloc_rate >= 0 ? 'allocating ' + _wpBytes(proc.alloc_rate) + '/s' : null,
                memo >= 0 ? 'memo ' + _wpBytes(memo) : null, s.evals > 0 ? s.evals + ' running' : null,
                s.load1 >= 0 ? 'load ' + s.load1 : null].filter(Boolean);
  return warn + '<div class="wm" title="Telemetry" onclick="wpOpenTelemetry()">' + rows.join('') +
    (rest.length ? '<div class="wm-rest">' + _wpEsc(rest.join(' · ')) + '</div>' : '') + '</div>';
}
// The Log tab: the log viewer (logview.js) on the worker the dock is showing, paged by byte range and
// searchable however large the log is, with its colour kept. One viewer of the dock's own, so a sweep's
// log open over the page is a different one.
let _wpLogView = null;
// One of the log viewer's reads of the worker on `side`: `logs`, `log_stat`, `log_slice` or `log_search`.
const _wpLogIO = (side, action, opts) => fetch('/api/' + encodeURIComponent((window.__slateState || {}).id) + '/worker-log-io', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(Object.assign({}, opts, { side, action, arg: '' })) }).then(r => r.json());
// Settles once the viewer has the log's newest window, so a caller can then move it.
function _wpShowLog() {
  const nbid = (window.__slateState || {}).id, box = document.getElementById('wdock-log');
  if (!nbid || !box || !window.slateLogs) return Promise.resolve();
  const refusedBox = box.querySelector('.wplog-none');
  if ((_wpProv[_wpSide] || {}).refused) {
    _wpLogView && _wpLogView.close();
    if (!refusedBox) box.insertAdjacentHTML('afterbegin', '<div class="wplog-none">Worker logs are an operator view, ' +
      'not a reader one — a log can carry the notebook\'s own data, so an app does not serve them here.<br>' +
      '<a href="/status" target="_blank" rel="noopener">/status</a> has them, one worker at a time.</div>');
    return Promise.resolve();
  }
  refusedBox && refusedBox.remove();
  if (!_wpLogView) _wpLogView = window.slateLogs.create(box);
  const side = _wpSide;
  return _wpLogView.openSource({ key: 'worker:' + side, title: 'Worker log',
                                 call: (action, arg, opts) => _wpLogIO(side, action, opts) }) || Promise.resolve();
}

// The Telemetry tab: the telemetry view (telemetry.js) drawn into the dock, following this notebook's
// worker on `side` through a restart. The dock's own figures already say who it is and what it can
// do, so the view comes without the bar it carries over the home page.
// Host and port come from the live worker list: the log route's answer names neither for a region.
function _wpShowTelemetry() {
  const box = document.getElementById('wdock-tel'), open = window.openTelemetry;
  if (!box || !open || _wpSide === null) return;
  const side = _wpSide, r = (_wpWorkers || []).find(w => (w.side || '') === side) || {};
  open({ nb: (window.__slateState || {}).id, side, mount: box,
         host: r.host && r.host !== 'local' ? r.host : '', port: r.port, label: _wpLabel(side, r.host) });
}
// The meters: the dock on that worker, at its telemetry.
window.wpOpenTelemetry = function (side) {
  _wpTab = 'tel';
  const dock = document.getElementById('workerdock');
  side = side === undefined ? (_wpSide || '') : side;
  (dock && dock.classList.contains('open') && side === _wpSide) ? _wpPaintTab() : openWorkerDock(side);
};
// The ☰ menu's Worker log: the dock on that worker, at its log.
window.wpOpenLog = function (side) {
  _wpTab = 'log';
  const dock = document.getElementById('workerdock');
  side = side === undefined ? (_wpSide || '') : side;
  (dock && dock.classList.contains('open') && side === _wpSide) ? _wpPaintTab() : openWorkerDock(side);
};
function _wpPaintTab() {
  try { localStorage.setItem('slateWorkerDockTab', _wpTab); } catch (_) {}
  document.querySelectorAll('#workerdock [data-wdtab]').forEach(b => b.classList.toggle('on', b.dataset.wdtab === _wpTab));
  const log = document.getElementById('wdock-log'), tel = document.getElementById('wdock-tel');
  log && log.classList.toggle('on', _wpTab === 'log');
  tel && tel.classList.toggle('on', _wpTab === 'tel');
  // Only the tab showing polls: the other one is closed, not hidden.
  if (_wpTab === 'log') { window.closeTelemetry && window.closeTelemetry(); return _wpShowLog(); }
  _wpLogView && _wpLogView.close(); _wpShowTelemetry();
  return Promise.resolve();
}

// A COMPACT at-a-glance stat for the pill face (cpu% · rss) — the full breakdown is in the dock.
function _wpPillStat(statsJson) {
  if (!statsJson) return '';
  let s; try { s = JSON.parse(statsJson); } catch (_) { return ''; }
  // While the worker is still importing/precompiling its packages, show that progress on the pill face
  // instead of cpu·rss (which is meaningless mid-boot). `warm` is the worker's _WARM_STATUS —
  // "warming n/total · Pkg" during preload, then "ready · …" (which falls through to cpu·rss below).
  if (s.warm && s.warm.indexOf('warming') === 0) return '⏳ ' + s.warm;
  const p = [];
  if (s.cpu >= 1) p.push(Math.round(s.cpu) + '%');   // hide 0% on a resting worker — it's just noise (the dock still shows it)
  if (s.rss > 0) p.push(_wpBytes(s.rss));
  // On a GPU job the GPUs' load is usually the number that matters: their mean, when busy.
  const r = window.slateModel.reading(s);
  if (r.gpus.some(g => g.util >= 1)) p.push('gpu ' + Math.round(r.gpuAvg) + '%');
  return p.join(' · ');
}

// Display label for a worker. "" = the main/local kernel; a region shows "name · host".
function _wpLabel(side, host) {
  if (!side) return host || 'local';
  return side + (host ? ' · ' + host : '');
}

// The pill, the dock and its list, repainted whenever the model changes. Debounced, so a burst of
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
    if (_wpSide !== null) { _wpPaintList(); _wpPaintBringup(); _wpFollowRestart(); _wpDrawFacts(); }
    if (window._dagOnWorkers) window._dagOnWorkers(_wpWorkers);   // the DAG's region status dots
  }, 160);
}
window.slateModel.subscribe(_wpOnModel);
_wpOnModel();   // the facts may have landed before this script subscribed

// The open dock's worker was replaced (a restart puts the new one on another port): its log and
// where it came from are the new process's, so they are fetched again.
let _wpOpenPort = null;
const _wpPortOf = (side) => { const w = (_wpWorkers || []).find(x => (x.side || '') === side); return w ? w.port : null; };
function _wpFollowRestart() {
  if (_wpSide === null) return;
  const p = _wpPortOf(_wpSide);
  if (p == null) return;
  if (_wpOpenPort == null) { _wpOpenPort = p; return; }    // opened before the list named a port
  if (+p !== +_wpOpenPort) { _wpOpenPort = p; _wpRefresh(); _wpPaintTab(); }
}

// ── Bring-up ─────────────────────────────────────────────────────────────────────
// A worker being started (a cold local spawn, a remote provision, a region coming up) is narrated in
// the dock while it shows that worker: the step it is on, precompile progress, and the build log, the
// elements prepare.js fills. The pill says which step it is on. `window.__slateBringup` (view.js)
// names the side being started.
const _wpBringingUp = (side) => { const b = window.__slateBringup; return !!b && (b.side || '') === side; };
function _wpBringupShort(side) { return _wpBringingUp(side) && window.slatePrepShort ? window.slatePrepShort() : ''; }
function _wpPaintBringup() {
  const old = document.getElementById('wdock-bringup');
  const want = _wpSide !== null && _wpBringingUp(_wpSide);
  if (!want) { old && old.remove(); return; }
  if (!old) {
    const b = window.__slateBringup, el = document.createElement('div');
    el.id = 'wdock-bringup'; el.className = 'wdock-bringup';
    el.innerHTML = '<span class="hydspin"></span><div class="wpbody">' +
      '<div id="hydmsg" class="hydmsg">' + (b.kind === 'remote' ? 'Starting the worker on <b>' + _wpEsc(b.host || 'the remote host') + '</b>…' : 'Starting the worker…') + '</div>' +
      '<div id="hydprep" class="hydprep"></div>' +
      '<details id="hydraw" class="hydraw" style="display:none" ontoggle="window._prepRawToggle&&window._prepRawToggle()"><summary>build log <span id="hydrawlast" class="hydrawlast"></span></summary><pre id="hydrawpre"></pre></details></div>';
    const title = document.getElementById('wdock-title');
    title && title.after(el);
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
// idle), with its health colour + live face. Hovering it lists ALL workers ranked; clicking it or a row
// opens the dock (see the handlers below).
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
  // Fixed single slot: the pill reserves a min-width so it doesn't jump as the top worker changes, and the
  // LABEL elides (CSS ellipsis) if a region name is long — icon/stat/caret stay put.
  // No `title`: hovering opens the list of workers, which would sit under the tooltip.
  const html = '<span class="wpill wpill-top' + cls + '" data-toplist data-side="' + _wpEsc(side) +
    '"><span class="wtopicon">' + icon + '</span><span class="wtoplabel">' + _wpEsc(_wpLabel(side, top.host)) + '</span>' +
    (face ? '<span class="wstat">' + _wpEsc(face) + '</span>' : '') +
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

// A worker log line pushed over the WS: the Log tab showing that side checks its file now rather than
// at its next poll, so the log keeps up with the worker.
function onWorkerLog(side, line) {
  if (_wpSide !== (side || '')) return;
  if (_wpTab === 'log' && _wpLogView) _wpLogView.refresh();
  _wpRecent.push(line);
  if (_wpRecent.length > _WP_RECENT_LINES) _wpRecent.splice(0, _wpRecent.length - _WP_RECENT_LINES);
  if (!_wpMsgsT) _wpMsgsT = setTimeout(() => { _wpMsgsT = null; _wpPaintMsgs(); }, 200);
}

// ── Recent messages ──────────────────────────────────────────────────────────────────────────
// The worker's last few log records, newest first, under its figures: what it last said, read at a
// glance without opening the log. Seeded from the log route's tail when the dock shows a worker,
// then kept up from the lines pushed over the WS. Only RECORDS count (a logger's `┌`/`[` head, or a
// core WARNING/ERROR print); a bare print is left to the Log tab. A record's fields follow its message,
// since "ran cell" says little without which cell.
const _WP_RECENT_LINES = 300, _WP_RECENT_SHOWN = 6;
let _wpRecent = [], _wpMsgsT = null;
// The clock follows the level (`Info 18:47:51:`); a log written before that has it in front.
const _WP_HEAD = /(?:^|\s)([┌\[])\s+(?:(\d\d:\d\d:\d\d)\s+)?(Debug|Info|Warning|Error)(?:\s+(\d\d:\d\d:\d\d)[.\d]*)?:\s*(.*)$/;
const _WP_FIELD = /^[│└]\s+([\w.]+)\s*=\s*(.*)$/;
const _WP_CORE = /^(WARNING|ERROR):\s*(.*)$/;
// `lines` are strings, or `{ t, o }` with the byte offset the line starts at, which a record keeps.
function _wpRecords(lines) {
  const recs = [];
  let open = null;                                  // a `┌` record still taking its `│`/`└` lines
  for (const ln of lines) {
    const styled = typeof ln === 'string' ? ln : ln.t, o = typeof ln === 'string' ? -1 : ln.o;
    const t = window.slateAnsiText(styled);
    let m;
    if ((m = _WP_HEAD.exec(t))) {
      const r = { ts: m[2] || m[4] || '', lvl: m[3], msg: m[5], fields: [], o };
      recs.push(r); open = m[1] === '┌' ? r : null;
    } else if (open && (t[0] === '│' || t[0] === '└')) {
      if ((m = _WP_FIELD.exec(t))) open.fields.push(m[1] + '=' + m[2]);
      if (t[0] === '└') open = null;
    } else if ((m = _WP_CORE.exec(t))) {
      recs.push({ ts: '', lvl: m[1] === 'ERROR' ? 'Error' : 'Warning', msg: m[2], fields: [], o }); open = null;
    } else open = null;
  }
  return recs;
}
const _wpRecKey = r => [r.ts, r.lvl, r.msg, ...r.fields].join('\x00');
// Each shown record with how many identical ones came after it, which is how its line is found again.
let _wpShown = [];
function _wpPaintMsgs() {
  const box = document.getElementById('wdock-msgs'); if (!box) return;
  const all = _wpRecords(_wpRecent), recs = all.slice(-_WP_RECENT_SHOWN).reverse();
  _wpShown = recs.map(r => { const k = _wpRecKey(r);
    return { k, fromEnd: all.slice(all.indexOf(r) + 1).filter(x => _wpRecKey(x) === k).length }; });
  _wpSetHtml(box, !recs.length ? '' : '<div class="wdm-h">Recent messages</div>' + recs.map((r, i) => {
    const f = r.fields.join(' · '), cls = r.lvl === 'Error' ? ' error' : r.lvl === 'Warning' ? ' warn' : '';
    return '<div class="wdm-row' + cls + '" data-wdmsg="' + i + '" title="' + _wpEsc((r.ts ? r.ts + ' ' : '') + r.lvl + ': ' + r.msg + (f ? '\n' + r.fields.join('\n') : '')) + '">' +
      '<span class="wdm-ts">' + _wpEsc(r.ts) + '</span><span class="wdm-msg">' + _wpEsc(r.msg) +
      (f ? '<span class="wdm-f">' + _wpEsc(f) + '</span>' : '') + '</span></div>';
  }).join(''));
}
// A recent message, clicked: the Log tab, at that record's line. The line is found in a fresh read of
// the log's tail, the bytes the viewer itself pages through, so the offset is the file's own; a record
// pushed over the WS carries none.
const _WP_SLICE = 1 << 18;
async function _wpOpenMsg(i) {
  const shown = _wpShown[i], side = _wpSide; if (!shown) return;
  _wpTab = 'log';
  const [, sl] = await Promise.all([_wpPaintTab(), _wpLogIO(side, 'log_slice', { offset: -_WP_SLICE, nbytes: _WP_SLICE }).catch(() => null)]);
  if (_wpSide !== side || !sl || !sl.text || !_wpLogView) return;
  const enc = new TextEncoder(), lines = [];
  let o = sl.from;
  for (const t of sl.text.split('\n')) { lines.push({ t, o }); o += enc.encode(t).length + 1; }
  const same = _wpRecords(lines).filter(r => _wpRecKey(r) === shown.k);
  const hit = same[same.length - 1 - shown.fromEnd];
  hit && hit.o >= 0 && _wpLogView.reveal(hit.o);
}

// ── The dock's worker list: every worker, so comparing their logs is a click ─────────────────────
// The question is usually "main is fine, so which region is stalling?", and the list answers it at a
// glance: each row carries its health dot and live face, ranked by severity. Only the LOG is
// per-worker work, fetched on switch into one buffer, so the line cap holds however many there are.
// A notebook with one worker has nothing to pick between, and the column is dropped.
function _wpPaintList() {
  const dock = document.getElementById('workerdock'), box = document.getElementById('wdock-list');
  if (!dock || !box) return;
  const ws = _wpWorkers || [];
  dock.classList.toggle('solo', ws.length < 2);
  const ranked = ws.slice().sort((a, b) => _wpSeverity(b) - _wpSeverity(a));
  _wpSetHtml(box, ranked.map(w => {
    const side = w.side || '', lbl = _wpLabel(side, w.host), f = _wpFace(w);
    return '<div class="wdock-row' + (side === _wpSide ? ' on' : '') + '" data-wdrow="' + _wpEsc(side) +
      '" title="' + _wpEsc(lbl) + '">' + _wpOverflowDot(w) + '<span class="wdr-label">' + _wpEsc(lbl) + '</span>' +
      (f ? '<span class="wdr-face">' + _wpEsc(f) + '</span>' : '') + '</div>';
  }).join(''));
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
  // A region with no process: starting one is the action, unless one is already on its way.
  if (side && r.state === 'none') {
    const starting = r.status === 'connecting';
    return (starting ? '' : b('▶ Start', 'window.wpStart(' + q + ')')) +
           (M.isHeld(r) ? b(verb, 'window.wpRelease(' + q + ')', 'danger') : '');
  }
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
  try { await window.api('POST', '/api/restart', { side }); } catch (_) {}
};
window.wpStart = async function (side) {
  try { await window.api('POST', '/api/worker-action', { side, action: 'start' }); } catch (_) {}
};
window.wpShutdown = async function (side) {
  if (!await _wpConfirm('Shut down ' + _wpWhich(side) + '?\nThe process is stopped and its results in ' +
                        'memory are lost. The next run starts a fresh one.', 'Shut down', 'danger')) return;
  try { await window.api('POST', '/api/worker-action', { side, action: 'shutdown' }); } catch (_) {}
};
window.wpRelease = async function (side) {
  if (!await _wpConfirm('Release the node held for `' + side + '`?\nIts workers are reaped and the node goes back to ' +
                        'the scheduler. The next run queues for another.', 'Release', 'danger')) return;
  try { await window.api('POST', '/api/worker-action', { side, action: 'release' }); } catch (_) {}
};

// Open the dock on `side`, or switch an open dock to it: same dock, new subject. The log buffer is
// dropped (one buffer, re-fetched) while the facts and the list repaint at once, so the click feels
// immediate; new log lines then arrive over the page's WebSocket, everything else through the model.
function openWorkerDock(side, ev) {
  ev && ev.stopPropagation();
  side = side || '';
  const dock = document.getElementById('workerdock'); if (!dock) return;
  const wasOpen = dock.classList.contains('open');
  if (wasOpen && side === _wpSide) return;
  _wpSide = side;
  _wpOpenPort = _wpPortOf(side);
  _wpRecent = []; _wpPaintMsgs();
  _wpDrawFacts();
  _wpPaintList();
  _wpPaintBringup();
  if (!wasOpen) { dock.classList.add('open'); document.body.classList.add('wdock-open'); }
  _wpPaintTab();
  _wpRefresh();
}
function closeWorkerDock() {
  _wpSide = null;
  _wpPaintBringup();
  _wpLogView && _wpLogView.close();
  window.closeTelemetry && window.closeTelemetry();
  const dock = document.getElementById('workerdock'); if (dock) dock.classList.remove('open', 'full');
  document.body.classList.remove('wdock-open');
  _wpPaintFull();
}
// Full screen: the dock covers the notebook under the topbar, for reading a log or the charts at size.
window.wpToggleFull = function () {
  const dock = document.getElementById('workerdock'); if (!dock) return;
  dock.classList.toggle('full'); _wpPaintFull();
};
function _wpPaintFull() {
  const dock = document.getElementById('workerdock'), b = document.getElementById('wdock-full'); if (!b) return;
  const full = !!dock && dock.classList.contains('full');
  b.classList.toggle('on', full); b.textContent = full ? '⤡' : '⤢';
  b.title = full ? 'Back to the bottom of the page' : 'Fill the window';
}
// The pill: opens the dock on its worker, and closes the dock when it is already showing that one.
function toggleWorkerDock(side, ev) {
  side = side || '';
  const dock = document.getElementById('workerdock');
  (dock && dock.classList.contains('open') && _wpSide === side) ? closeWorkerDock() : openWorkerDock(side, ev);
}

// The top edge: drag to resize, persisted. The page's reserved height follows through --wdockh.
// A wheel over the dock scrolls the dock, never the cells behind it.
(() => {
  const dock = document.getElementById('workerdock'); dock && window.slateOwnWheel(dock);
  const grip = document.getElementById('wdock-grip'); if (!grip) return;
  try { const h = localStorage.getItem('slateWorkerDockH'); if (h) document.body.style.setProperty('--wdockh', h); } catch (_) {}
  const move = e => {
    const dock = document.getElementById('workerdock');
    const below = window.innerHeight - dock.getBoundingClientRect().bottom;   // the DAG pane, when docked beneath
    const h = Math.max(140, Math.min(window.innerHeight * 0.8 - below, window.innerHeight - below - e.clientY));
    document.body.style.setProperty('--wdockh', h + 'px');
  };
  const up = () => {
    grip.classList.remove('on'); document.body.style.userSelect = '';
    document.removeEventListener('pointermove', move); document.removeEventListener('pointerup', up);
    try { localStorage.setItem('slateWorkerDockH', document.body.style.getPropertyValue('--wdockh')); } catch (_) {}
  };
  grip.addEventListener('pointerdown', e => {
    e.preventDefault(); grip.classList.add('on'); document.body.style.userSelect = 'none';
    document.addEventListener('pointermove', move); document.addEventListener('pointerup', up);
  });
})();
// Where the open dock's worker came from, which only the log route says, and the tail of its log
// for the recent messages. An app REFUSES that route (a
// log can carry notebook data, and an app's visitor is not its operator), and the Log tab says so.
async function _wpRefresh() {
  const side = _wpSide;                                          // capture: the dock can switch while we await
  if (side === null) return;
  let r; try { r = await api('GET', '/api/worker-log?side=' + encodeURIComponent(side) + '&lines=' + _WP_RECENT_LINES); }
  catch (_) { r = null; }
  if (_wpSide !== side) return;                                  // switched (or closed) mid-fetch → stale response, drop it
  const refused = !r || typeof r !== 'object' || r.log === undefined;
  const was = !!(_wpProv[side] || {}).refused;
  _wpProv[side] = refused ? { refused } : { origin: r.origin, spawned: r.spawned };
  _wpRecent = (!refused && r.log) ? r.log.split('\n') : [];
  _wpPaintMsgs();
  _wpDrawFacts();
  if (refused !== was && _wpTab === 'log') _wpShowLog();
}

// The dock's title, picker, identity, actions and figures, from the model. Called when the dock
// opens, whenever the model changes, and every second while an allocation clock is showing.
// Only touches what changed: this runs on every change to the model (each telemetry sample among
// them), and replacing a button under the pointer would swallow a click on it.
function _wpSetHtml(el, html) { if (el && el._wpHtml !== html) { el.innerHTML = html; el._wpHtml = html; } }
function _wpDrawFacts() {
  const r = _wpCurrent(); if (!r) return;
  const dot = _wpOverflowDot(r);   // same rank as every other dot
  _wpSetHtml(document.getElementById('wdock-title'), dot + ' ' + (r.side ? 'region' : 'main worker') +
    ' · ' + _wpEsc(_wpLabel(r.side, r.host)) + (r.port ? ' :' + r.port : ''));
  // The run-location picker, only for the MAIN worker: a region's host is fixed by its registry def.
  // "change ▾" opens the existing picker modal.
  const rl = document.getElementById('wdock-runloc');
  if (rl) {
    rl.style.display = r.side ? 'none' : '';
    _wpSetHtml(rl, r.side ? '' : 'run location: <b>' + _wpEsc(r.host || 'local') +
      '</b> <button class="wrl-change" onclick="toggleRunLoc(event)">change ▾</button>');
  }
  _wpSetHtml(document.getElementById('wdock-ident'), _wpIdentChips(r));
  _wpSetHtml(document.getElementById('wdock-acts'), _wpActions(r));
  // A region with no process has no figures of its own to show, whatever was last seen there.
  _wpSetHtml(document.getElementById('wdock-stats'), _wpStatsChips(r.state === 'none' ? null : r.stats, _wpNoteText(r)));
}

window.openWorkerDock = openWorkerDock;
window.closeWorkerDock = closeWorkerDock;
window.toggleWorkerDock = toggleWorkerDock;
window.onWorkerLog = onWorkerLog;

// The bar's single pill. HOVERING it (after the tooltip delay from Settings) opens the ranked list of
// ALL workers, and leaving the pill and the list closes it. CLICKING the pill opens the dock on its
// worker (again closes it); clicking a row opens the dock on that worker.
let _wpHideT = null, _wpMenuT = null;
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
  if (_wpMenuT) { clearTimeout(_wpMenuT); _wpMenuT = null; }
  if (_wpHideT) { clearTimeout(_wpHideT); _wpHideT = null; }
}
function _wpScheduleHide() {
  if (_wpMenuT) { clearTimeout(_wpMenuT); _wpMenuT = null; }
  if (!_wpMenuOpen()) return;
  if (_wpHideT) clearTimeout(_wpHideT);
  _wpHideT = setTimeout(() => { _wpHideT = null; _wpCloseMenu(); }, 260);
}

document.addEventListener('click', e => {
  if (!e.target || !e.target.closest) return;
  const drow = e.target.closest('#wdock-list [data-wdrow]');
  if (drow) { openWorkerDock(drow.getAttribute('data-wdrow')); return; }
  const msg = e.target.closest('#wdock-msgs [data-wdmsg]');
  if (msg) { _wpOpenMsg(+msg.dataset.wdmsg); return; }
  const dtab = e.target.closest('#workerdock [data-wdtab]');
  // The open tab again: the log keeps its place, the telemetry view (which a profiled run closes) reopens.
  if (dtab) { if (dtab.dataset.wdtab !== _wpTab || _wpTab === 'tel') { _wpTab = dtab.dataset.wdtab; _wpPaintTab(); } return; }
  const row = e.target.closest('#workerpills .wpill-menuitem[data-side]');
  if (row) { _wpCloseMenu(); openWorkerDock(row.getAttribute('data-side')); e.stopPropagation(); return; }
  const top = e.target.closest('#workerpills .wpill-top');
  if (top) {
    _wpCloseMenu(); _wpMenuHeld = true;
    toggleWorkerDock(top.getAttribute('data-side') || '');
    e.stopPropagation(); return;
  }
  if (_wpMenuOpen()) _wpCloseMenu();                            // click-away closes the list
});
document.addEventListener('mouseover', e => {
  if (!e.target || !e.target.closest) return;
  const inPills = e.target.closest('#workerpills');
  if (inPills && _wpHideT) { clearTimeout(_wpHideT); _wpHideT = null; }
  const top = e.target.closest('#workerpills .wpill-top');
  if (top && !e.target.closest('.wpill-menu')) _wpScheduleMenu(top);
});
document.addEventListener('mouseout', e => {
  const to = e.relatedTarget;
  if (!(to && to.closest && to.closest('#workerpills .wpill-top'))) _wpMenuHeld = false;
  if (!(to && to.closest && to.closest('#workerpills'))) _wpScheduleHide();
});
// Esc closes the list. The dock stays: it is part of the layout, and Esc belongs to the editor.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && _wpMenuOpen()) { e.stopPropagation(); _wpCloseMenu(); }
}, true);

// What counts from an instant (an allocation's walltime, its idle stretch, how long a worker has not
// answered) is redrawn every second: the facts change only when the system does, so nothing else
// would move these.
setInterval(() => {
  if (_wpWorkers.some(w => w.noteCode === 'no_reply')) _wpPaintStrip(_wpWorkers);
  const r = _wpCurrent();
  if (!r) return;
  if (!window.slateModel.isHeld(r) && r.noteCode !== 'no_reply') return;   // nothing counting
  const st = document.getElementById('wdock-stats');
  if (r.noteCode === 'no_reply') _wpSetHtml(st, _wpStatsChips(r.stats, _wpNoteText(r)));
  const idb = document.getElementById('wdock-ident');
  _wpSetHtml(idb, _wpIdentChips(r));
}, 1000);
