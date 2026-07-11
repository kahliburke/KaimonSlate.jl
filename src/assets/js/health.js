// Watchdog health — the browser-visible surface of the hub's 5s stall/runaway watchdog
// (server: _watchdog_scan!). Polls GET /api/health, shows a topbar BADGE when something is wrong
// (amber = warning, red = critical), and a click-out PANEL listing each alert with a contextual
// RECOVERY action: "Stop run" (/api/cancel — graceful interrupt) for a stuck cell, "Restart worker"
// (/api/restart — nukes the namespace) for a runaway/unreachable kernel. Self-contained: injects its
// own styles, no-ops if its topbar anchor is missing, and pauses polling while the tab is hidden.
(function () {
  const POLL_MS = 4000;
  let timer = null, open = false, inflight = false;
  let last = { status: 'ok', alerts: [] };

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

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const fmtAge = (s) => (s = +s || 0, s < 60 ? Math.round(s) + 's' : Math.round(s / 60) + 'm');
  const badge = () => document.getElementById('healthbadge');
  const panel = () => document.getElementById('healthpanel');
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
  window.__healthCancel = async function () {
    try { await api('POST', '/api/cancel'); poll(); } catch (_) {}
  };
  // side omitted / "local" → restart the MAIN kernel (clears the namespace). A region name → restart
  // JUST that region worker (its cells re-run on a fresh worker; main + other regions stay up).
  window.__healthRestart = async function (side) {
    const region = side && side !== 'local';
    const msg = region
      ? ('Restart the “' + side + '” region worker?\n\nIts cells re-run on a fresh worker; the main kernel and other regions stay up.')
      : 'Restart the worker?\n\nThis clears the namespace — every value recomputes on the next run. Use it when a kernel is wedged (runaway / unreachable) and a graceful stop can\'t reach it.';
    if (!confirm(msg)) return;
    try { await api('POST', '/api/restart', region ? { side: side } : undefined); poll(); } catch (_) {}
  };
  window.__healthToggle = function () {
    open = !open; const p = panel(); if (p) { p.classList.toggle('open', open); if (open) renderPanel(); }
  };

  function alertRow(al) {
    const k = KIND[al.kind] || { sev: 'warn', icon: '•', label: al.kind };
    const isCell = al.scope === 'cell';
    const target = isCell ? ('cell ' + al.target) : (esc(al.target) + ' kernel');
    const act = isCell
      ? `<button class="hpact" onclick="event.stopPropagation();window.__healthCancel()">Stop run</button>`
      : `<button class="hpact danger" onclick="event.stopPropagation();window.__healthRestart('${esc(al.target)}')">Restart ${al.target === 'local' ? 'worker' : esc(al.target)}</button>`;
    return `<div class="hprow ${k.sev}"${isCell ? ` data-cid="${esc(al.target)}"` : ''}>` +
      `<span class="hpico">${k.icon}</span>` +
      `<span class="hpmain"><b>${esc(k.label)}</b> · ${target}` +
      `<span class="hpdetail">${esc(al.detail)} · ${fmtAge(al.age)}</span></span>` +
      `${act}</div>`;
  }

  function renderBadge() {
    const b = badge(); if (!b) return;
    const a = last.alerts || [];
    const alerting = a.length && last.status !== 'ok';
    if (!alerting && !last.src_stale) {                    // nothing to show
      b.style.display = 'none';
      if (open) { open = false; const p = panel(); if (p) p.classList.remove('open'); }
      return;
    }
    if (alerting) {                                        // a watchdog alert wins the badge; ↻ if also stale
      const crit = last.status === 'critical';
      b.className = 'healthbadge ' + (crit ? 'crit' : 'warn');
      b.innerHTML = (crit ? '⛔' : '⚠') + ' ' + a.length + (last.src_stale ? ' ↻' : '');
    } else {                                               // only "server source changed" — a passive info nudge
      b.className = 'healthbadge info';
      b.innerHTML = '↻ restart to apply';
    }
    b.style.display = 'inline-flex';
  }

  function renderPanel() {
    const p = panel(); if (!p) return;
    const a = last.alerts || [];
    // "server source changed" is a PASSIVE nudge — no action button, because the fix is a manual
    // restart of the Slate server (hot-reloading it in place is fragile; Revise handles function edits).
    const stale = last.src_stale
      ? `<div class="hprow warn"><span class="hpico">↻</span><span class="hpmain">` +
        `<b>server source changed</b> since it started<span class="hpdetail">Revise applies function ` +
        `edits live — RESTART the Slate server to pick up struct / new-tool changes</span></span></div>`
      : '';
    p.innerHTML = `<div class="hphdr"><b>Watchdog health</b>` +
      `<span class="hpclose" onclick="window.__healthToggle()">✕</span></div>` +
      stale +
      (a.length ? a.map(alertRow).join('') : (stale ? '' : `<div class="hpok">✓ all clear</div>`));
  }

  async function poll() {
    if (inflight || document.hidden) return;
    inflight = true;
    try {
      const r = await api('GET', '/api/health');
      last = (r && Array.isArray(r.alerts)) ? r : { status: 'ok', alerts: [] };
      renderBadge();
      if (open) renderPanel();
    } catch (_) {
      // network blip → leave the last known state up rather than flapping the badge off
    } finally { inflight = false; }
  }

  // Panel click on a cell-scoped alert → jump to that cell (buttons stopPropagation above).
  document.addEventListener('click', (e) => {
    const row = e.target.closest && e.target.closest('.hprow[data-cid]');
    if (row && row.dataset.cid) jumpTo(row.dataset.cid);
  });

  document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
  function start() { if (timer) return; poll(); timer = setInterval(poll, POLL_MS); }
  start();
})();
