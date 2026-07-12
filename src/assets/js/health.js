// Watchdog health — the browser-visible surface of the hub's 5s stall/runaway watchdog
// (server: _watchdog_scan!). Polls GET /api/health, shows a topbar BADGE when something is wrong
// (amber = warning, red = critical), and a click-out PANEL listing each alert with a contextual
// RECOVERY action: "Stop run" (/api/cancel — graceful interrupt) for a stuck cell, "Restart worker"
// (/api/restart — nukes the namespace) for a runaway/unreachable kernel.
//
// MIGRATED to Preact/ESM (imported by app.js). The health payload is a signal; the panel is a
// component derived from it, so a poll just assigns the signal and the UI follows — no manual
// renderBadge()/renderPanel() calls. The topbar badge is a single pre-existing element whose OWN
// class/text change, so it's driven by an effect() rather than a component (same split as the TOC's
// scroll-spy). `window.__healthToggle` stays for the badge's inline onclick.
import { html, render } from 'htm/preact';
import { signal, effect } from '@preact/signals';

const POLL_MS = 4000;
const health = signal({ status: 'ok', alerts: [], src_stale: false });   // latest /api/health payload
const panelOpen = signal(false);
let timer = null, inflight = false;

// Per-alert presentation: severity drives colour, icon + label read at a glance. Keys match the
// server's alert `kind`s; an unknown kind degrades to a neutral warning dot.
const KIND = {
  'slow':        { sev: 'warn', icon: '◔', label: 'slow' },
  'stalled':     { sev: 'crit', icon: '⏳', label: 'stalled' },
  'runaway-cpu': { sev: 'warn', icon: '🔥', label: 'cpu runaway' },
  'runaway-mem': { sev: 'crit', icon: '🧠', label: 'memory runaway' },
  'gc-thrash':   { sev: 'warn', icon: '♻', label: 'gc thrash' },
  'unreachable': { sev: 'crit', icon: '📡', label: 'unreachable' },
};
const fmtAge = (s) => (s = +s || 0, s < 60 ? Math.round(s) + 's' : Math.round(s / 60) + 'm');
const jumpTo = (id) => { try { window.selectCell && window.selectCell(id, true); } catch (_) {} };

// ── styles (injected once, so notebook.css stays untouched) ─────────────────────────────────
const style = document.createElement('style');
style.textContent = `
  .healthbadge{display:none;align-items:center;gap:4px;font-size:.72rem;font-weight:600;
    padding:2px 8px;border-radius:9px;cursor:pointer;user-select:none;white-space:nowrap;}
  .healthbadge.warn{color:#e8a13f;background:rgba(232,161,63,.14);border:1px solid rgba(232,161,63,.3);}
  .healthbadge.crit{color:#e5636e;background:rgba(229,99,110,.15);border:1px solid rgba(229,99,110,.35);
    animation:healthpulse 1.6s ease-in-out infinite;}
  .healthbadge.info{color:#7cc0ff;background:rgba(124,192,255,.12);border:1px solid rgba(124,192,255,.3);}
  @keyframes healthpulse{0%,100%{opacity:1}50%{opacity:.55}}
  .healthpanel{display:none;position:fixed;top:44px;right:12px;z-index:60;width:340px;max-width:92vw;
    background:#141828;border:1px solid #2a2e40;border-radius:11px;padding:8px;
    box-shadow:0 10px 34px rgba(0,0,0,.5);}
  .healthpanel.open{display:block;}
  .hphdr{display:flex;align-items:center;justify-content:space-between;padding:2px 6px 8px;
    color:#cdd3e6;font-size:.82rem;}
  .hpclose{cursor:pointer;color:#8a90a8;font-size:.9rem;}
  .hpok{color:#6a7090;font-size:.78rem;padding:6px 6px 8px;}
  .hprow{display:grid;grid-template-columns:auto minmax(0,1fr) auto;align-items:center;gap:9px;
    padding:7px 6px;border-top:1px solid rgba(42,46,64,.6);}
  .hprow:first-of-type{border-top:none;}
  .hprow.crit .hpico{color:#e5636e;} .hprow.warn .hpico{color:#e8a13f;}
  .hpico{font-size:.95rem;}
  .hpmain{min-width:0;color:#d4d8e8;font-size:.76rem;line-height:1.3;}
  .hpmain b{font-weight:600;}
  .hprow[data-cid]{cursor:pointer;} .hprow[data-cid]:hover{background:rgba(124,192,255,.06);}
  .hpdetail{display:block;color:#8a90a8;font-size:.7rem;font-family:Menlo,monospace;}
  .hpact{flex:0 0 auto;font-size:.7rem;padding:3px 9px;border-radius:7px;cursor:pointer;
    background:#1c2136;color:#c6ccdd;border:1px solid #2f3550;white-space:nowrap;}
  .hpact:hover{background:#242a44;}
  .hpact.danger{color:#e5636e;border-color:rgba(229,99,110,.4);}
  .hpact.danger:hover{background:rgba(229,99,110,.12);}`;
document.head.appendChild(style);

// ── recovery actions ────────────────────────────────────────────────────────────────────────
async function cancelRun() {
  try { await window.api('POST', '/api/cancel'); poll(); } catch (_) {}
}
// side omitted / "local" → restart the MAIN kernel (clears the namespace). A region name → restart
// JUST that region worker (its cells re-run on a fresh worker; main + other regions stay up).
async function restartWorker(side) {
  const region = side && side !== 'local';
  const msg = region
    ? ('Restart the “' + side + '” region worker?\n\nIts cells re-run on a fresh worker; the main kernel and other regions stay up.')
    : 'Restart the worker?\n\nThis clears the namespace — every value recomputes on the next run. Use it when a kernel is wedged (runaway / unreachable) and a graceful stop can\'t reach it.';
  if (!confirm(msg)) return;
  try { await window.api('POST', '/api/restart', region ? { side } : undefined); poll(); } catch (_) {}
}
function toggle() { panelOpen.value = !panelOpen.value; }
window.__healthToggle = toggle;          // the badge's inline onclick calls this
window.__healthCancel = cancelRun;       // kept exposed for compat (no current external caller)
window.__healthRestart = restartWorker;

// ── badge (single pre-existing element — drive its own class/text from the signal) ────────────
effect(() => {
  const b = document.getElementById('healthbadge'); if (!b) return;
  const h = health.value, a = h.alerts || [];
  const alerting = a.length && h.status !== 'ok';
  if (!alerting && !h.src_stale) {                       // nothing to show
    b.style.display = 'none';
    if (panelOpen.peek()) panelOpen.value = false;       // peek: don't subscribe the badge to panel state
    return;
  }
  if (alerting) {                                        // a watchdog alert wins the badge; ↻ if also stale
    const crit = h.status === 'critical';
    b.className = 'healthbadge ' + (crit ? 'crit' : 'warn');
    b.textContent = (crit ? '⛔' : '⚠') + ' ' + a.length + (h.src_stale ? ' ↻' : '');
  } else {                                               // only "server source changed" — a passive info nudge
    b.className = 'healthbadge info';
    b.textContent = '↻ restart to apply';
  }
  b.style.display = 'inline-flex';
});

// ── panel (reactive component) ────────────────────────────────────────────────────────────────
function AlertRow({ al }) {
  const k = KIND[al.kind] || { sev: 'warn', icon: '•', label: al.kind };
  const isCell = al.scope === 'cell';
  const target = isCell ? ('cell ' + al.target) : (al.target + ' kernel');
  const act = isCell
    ? html`<button class="hpact" onClick=${(e) => { e.stopPropagation(); cancelRun(); }}>Stop run</button>`
    : html`<button class="hpact danger" onClick=${(e) => { e.stopPropagation(); restartWorker(al.target); }}>Restart ${al.target === 'local' ? 'worker' : al.target}</button>`;
  return html`<div class="hprow ${k.sev}" data-cid=${isCell ? al.target : null}
                   onClick=${isCell ? () => jumpTo(al.target) : null}>
    <span class="hpico">${k.icon}</span>
    <span class="hpmain"><b>${k.label}</b> · ${target}<span class="hpdetail">${al.detail} · ${fmtAge(al.age)}</span></span>
    ${act}</div>`;
}

function Panel() {
  const h = health.value, a = h.alerts || [];
  // "server source changed" is a PASSIVE nudge — no action button, because the fix is a manual restart
  // of the Slate server (hot-reloading it in place is fragile; Revise handles function edits).
  const stale = h.src_stale ? html`<div class="hprow warn">
    <span class="hpico">↻</span>
    <span class="hpmain"><b>server source changed</b> since it started<span class="hpdetail">Revise applies function edits live — RESTART the Slate server to pick up struct / new-tool changes</span></span>
  </div>` : null;
  return html`
    <div class="hphdr"><b>Watchdog health</b><span class="hpclose" onClick=${toggle}>✕</span></div>
    ${stale}
    ${a.length ? a.map((al) => html`<${AlertRow} al=${al} />`) : (stale ? null : html`<div class="hpok">✓ all clear</div>`)}`;
}

const _panelHost = document.getElementById('healthpanel');
if (_panelHost) render(html`<${Panel} />`, _panelHost);
effect(() => { const p = document.getElementById('healthpanel'); if (p) p.classList.toggle('open', panelOpen.value); });

// ── poll loop (imperative; assigns the signal, UI follows) ────────────────────────────────────
async function poll() {
  if (inflight || document.hidden) return;
  inflight = true;
  try {
    const r = await window.api('GET', '/api/health');
    health.value = (r && Array.isArray(r.alerts)) ? r : { status: 'ok', alerts: [] };
  } catch (_) {
    // network blip → leave the last known state up rather than flapping the badge off
  } finally { inflight = false; }
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
function start() { if (timer) return; poll(); timer = setInterval(poll, POLL_MS); }
start();
