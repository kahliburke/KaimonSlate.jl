// Live run status — driven by the SSE `runbatch:` / `cellrun:` / `celldone:` events (wired in
// panels.js). The server announces a run's size up front (`runbatch:N`) and then streams each cell
// as it starts/finishes, so we can show WHAT is happening:
//   • each running cell gets the store's transient `running` state (pulsing border) + a ticking timer;
//   • a topbar pill reads a STABLE "k / N" with a progress bar through the whole run;
//   • every run/finish/error lands in the Activity log (a debugging feed).
// All best-effort and self-contained: if an element is missing it no-ops.
(function () {
  const running = new Map();     // cellId -> start time (performance.now)
  let total = 0, done = 0, errs = 0;   // the CURRENT run batch (set by runbatch:, counts up via celldone)
  let tick = null, idleTimer = null;
  const bars = new Map();              // bar id -> {frac,msg}  (one per @withprogress scope / slate_progress id)
  let prog = { frac: 0, msg: '' };     // the latest update (drives the chip + badge %)
  const erroredIds = [];               // cells that errored this streak (for the pill to jump through)
  let errCursor = 0;
  // Reveal delay (PER CELL): don't show run-status until SOME cell has been running > REVEAL_MS. Each
  // cell schedules its own timer on start and cancels it on finish — so a fast cell never flashes, and
  // SUSTAINED fast churn (a playhead bind driving a cell at ~10 Hz) never accumulates into a reveal the
  // way a streak-global timer would. A genuinely slow cell still trips its timer and reveals.
  let revealed = false;
  const cellReveal = new Map();        // cellId → pending reveal timer
  const REVEAL_MS = 140;

  // The cell currently executing (the most recently started) — runs are sequential.
  const activeCell = () => { let last = null; for (const id of running.keys()) last = id; return last; };
  // Scroll to + select a cell (clicking a run-status indicator should take you there).
  const jumpTo = (id) => { try { window.selectCell && window.selectCell(id, true); } catch (_) {} };

  const now = () => performance.now();
  const fmt = (ms) => ms < 1000 ? Math.round(ms) + 'ms' : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + 's';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const setLive = (id, s) => { try { window.slateStore && window.slateStore.setLiveState(id, s); } catch (_) {} };

  // A batch is "active" while there are cells left to run (or any cell is still executing). Pill
  // visibility tracks the BATCH, not `running.size`, so it doesn't flicker between sequential cells.
  const active = () => (total > 0 && done < total) || running.size > 0;

  function ensureTick() {
    if (tick) return;
    tick = setInterval(() => {
      if (!active()) { clearInterval(tick); tick = null; }
      renderPill(); renderTimers(); renderChip();
    }, 150);
  }

  // Schedule a per-cell reveal: if THIS cell is still running after REVEAL_MS, show the run-status.
  function scheduleCellReveal(id) {
    if (revealed || cellReveal.has(id)) return;
    cellReveal.set(id, setTimeout(() => { cellReveal.delete(id); if (running.has(id)) reveal(); }, REVEAL_MS));
  }
  function clearCellReveal(id) { const t = cellReveal.get(id); if (t) { clearTimeout(t); cellReveal.delete(id); } }
  function clearAllReveals() { for (const t of cellReveal.values()) clearTimeout(t); cellReveal.clear(); }
  function reveal() {
    if (revealed) return; revealed = true; clearAllReveals();
    for (const id of running.keys()) { setLive(id, 'running'); activity('run', id, ''); }   // catch up deferred starts
    ensureTick(); renderPill(); renderChip(); renderTimers();
  }

  function renderPill() {
    if (!revealed) return;
    const pill = document.getElementById('runpill'); if (!pill) return;
    if (active()) {
      let mx = 0; for (const t of running.values()) mx = Math.max(mx, now() - t);
      const n = Math.max(total, done + running.size);
      const k = Math.min(done + running.size, n);
      const frac = n ? Math.round((done / n) * 100) : 0;
      pill.className = 'runpill running';
      pill.innerHTML = `<span class="rring" style="--rp:${frac}"></span>Running ${k}/${n} · ${fmt(mx)}`;
      pill.style.display = '';
    } else if (errs) {
      pill.className = 'runpill err'; pill.style.display = '';
      pill.textContent = `⚠ ${errs} errored`;
    } else {
      pill.style.display = 'none'; pill.textContent = '';
    }
  }

  function renderTimers() {
    if (!revealed) return;
    for (const [id, t] of running) {
      const b = document.querySelector(`.cell[data-cid="${id}"] .badge`);
      if (b) b.textContent = 'running ' + fmt(now() - t) + (id === activeCell() && prog.frac > 0 ? ' · ' + Math.round(prog.frac * 100) + '%' : '');
    }
  }

  // Floating "currently running" chip: which cell, how long, and its slate_progress bar + message.
  function renderChip() {
    const chip = document.getElementById('runchip'); if (!chip) return;
    if (!revealed) { chip.style.display = 'none'; return; }
    const id = activeCell();
    if (!id) { chip.style.display = 'none'; return; }
    const t = running.get(id), el = t ? fmt(now() - t) : '';
    // Update STABLE child elements via textContent — never rebuild the text with innerHTML, or the
    // 150ms tick would destroy/recreate the id mid-click and swallow clicks on it (the rest of the
    // chip clicked fine because those elements are stable).
    const idEl = document.getElementById('runchipid'), meta = document.getElementById('runchipmeta'),
      fill = document.getElementById('runchipfill');
    if (idEl && idEl.textContent !== id) idEl.textContent = id;
    if (meta) meta.textContent = ` · ${el}` + (prog.msg ? ` · ${prog.msg}` : '');
    if (fill) { fill.style.width = (prog.frac > 0 ? Math.round(prog.frac * 100) : 0) + '%'; fill.style.opacity = prog.frac > 0 ? '1' : '0'; }
    chip.style.display = 'flex';
  }

  // Progress bars ON the running cell itself — one ROW per active bar id (so nested
  // `@withprogress` scopes / parallel tasks each get their own). Injected directly into the cell
  // DOM (like renderTimers' badge update); removed in clearCellBar on finish / next run.
  function renderCellBars(id) {
    const cell = id && document.querySelector(`.cell[data-cid="${id}"]`);
    if (!cell) return;
    let box = cell.querySelector(':scope > .cellprog');
    if (bars.size === 0) { box && box.remove(); return; }
    if (!box) { box = document.createElement('div'); box.className = 'cellprog'; cell.insertBefore(box, cell.firstChild); }
    let html = '';
    for (const b of bars.values()) {
      const pct = b.frac > 0 ? Math.round(b.frac * 100) : 0;
      html += `<div class="cellprogrow"><div class="cellprogtrack"><span style="width:${pct}%"></span></div>` +
        `<span class="cellprogmsg">${esc(b.msg || '')}${b.frac > 0 ? (b.msg ? ' · ' : '') + pct + '%' : ''}</span></div>`;
    }
    box.innerHTML = html;
  }
  function clearCellBar(id) {
    const cell = id && document.querySelector(`.cell[data-cid="${id}"]`);
    const bar = cell && cell.querySelector(':scope > .cellprog');
    if (bar) bar.remove();
  }

  // A running cell reported progress: {frac, msg, id, done}. `done` ends a scope → drop its bar;
  // otherwise upsert the bar for `id`. `prog` tracks the latest update for the chip/badge.
  window.onCellProgress = function (p) {
    reveal();                             // a cell reporting progress is doing real work — show it now
    p = p || {};
    const id = p.id || '';
    if (p.done) bars.delete(id);
    else bars.set(id, { frac: typeof p.frac === 'number' ? p.frac : 0, msg: p.msg || '' });
    prog = { frac: typeof p.frac === 'number' ? p.frac : 0, msg: p.msg || '' };
    renderChip(); renderTimers(); renderCellBars(activeCell());
  };

  // Click the floating chip → scroll to + select the currently-running cell.
  window.onChipClick = function () { const id = activeCell(); if (id) jumpTo(id); };

  // Stop the run. The only worker-level halt is a restart (kills the namespace); restartWorker()
  // runs its own confirm + loading flow, so just delegate to it.
  window.cancelRun = function () {
    try { if (typeof restartWorker === 'function') restartWorker(); } catch (_) {}
  };

  // The server announced a run of N cells. Reset the batch counters (a fresh streak) and show the pill.
  // The server reports PENDING cells (stale + running); N = what we've finished + what's pending, so
  // the pill grows as cells are queued mid-run. Only a FRESH streak (none active) resets the counters.
  window.onRunBatch = function (n) {
    clearTimeout(idleTimer);
    if (!active()) { done = 0; errs = 0; erroredIds.length = 0; errCursor = 0; }
    total = done + n;
    if (revealed) renderPill();           // reveal is per-cell now (onCellRun); just refresh the count
  };

  // Pill click: while running, open the activity feed to watch; once a run has errored, step through
  // the errored cells (each click jumps to the next, scrolling it into view).
  window.onPillClick = function () {
    if (!active() && erroredIds.length) { jumpTo(erroredIds[errCursor % erroredIds.length]); errCursor++; return; }
    window.toggleAct && window.toggleAct();
  };

  // A cell STARTED running.
  window.onCellRun = function (id) {
    clearTimeout(idleTimer);
    if (total === 0) total = 1;           // a one-off run with no batch announcement → degrade gracefully
    running.set(id, now());
    prog = { frac: 0, msg: '' };          // fresh cell → reset any prior progress
    bars.clear();                         // a run is sequential → start each cell's bars fresh
    clearCellBar(id);                     // drop any stale per-cell bar from a previous run
    if (revealed) {                       // already showing → mark + log immediately
      setLive(id, 'running'); activity('run', id, '');
      ensureTick(); renderPill(); renderChip();
    } else scheduleCellReveal(id);        // else defer; THIS cell cancels its reveal if it finishes fast
  };

  // A cell FINISHED (cell is its full cell_json — patchCells has already merged it).
  window.onCellDone = function (cell) {
    const id = cell.id, t = running.get(id);
    running.delete(id);
    clearCellReveal(id);                  // a finished cell cancels its own pending reveal (fast → no flash)
    done++;
    bars.clear();
    clearCellBar(id);                     // remove the per-cell progress bar(s)
    const errored = cell.state === 'errored';
    if (errored) { errs++; if (!erroredIds.includes(id)) erroredIds.push(id); if (!revealed) reveal(); }  // always surface errors
    if (revealed) {
      setLive(id, cell.state);            // clear the transient running → real state
      activity(errored ? 'err' : 'done', id, errored ? 'errored' : (t ? fmt(now() - t) : 'done'));
      prog = { frac: 0, msg: '' };
      renderPill(); renderChip();
    }
    // Batch drained → end the streak shortly (a small delay absorbs the gap between sequential cells
    // and back-to-back batches, so the pill doesn't flicker). `errs` persists so the error pill stays.
    if (!active()) {
      clearTimeout(idleTimer);
      if (revealed) idleTimer = setTimeout(() => { total = 0; done = 0; revealed = false; renderPill(); }, 600);
      else { clearAllReveals(); total = 0; done = 0; }   // nothing was ever shown → reset silently
    }
  };

  // ── Activity log: a timestamped feed, kept to a bounded ring. ──────────────────────────────────
  function activity(kind, id, detail) {
    const box = document.getElementById('actlog'); if (!box) return;
    const icon = kind === 'run' ? '▶' : kind === 'err' ? '✗' : kind === 'done' ? '✓' : '·';
    const ts = new Date().toLocaleTimeString();
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 30;
    const line = document.createElement('div');
    line.className = 'actline act-' + kind;
    line.innerHTML = `<span class="actts">${ts}</span><span class="acticon">${icon}</span>` +
      `<span class="actid" data-cid="${esc(id)}" title="jump to cell">${esc(id)}</span><span class="actdetail">${esc(detail)}</span>`;
    box.appendChild(line);
    while (box.children.length > 600) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  }
  window.slateActivity = activity;   // so other modules can log to the same feed

  window.toggleAct = function () {
    const p = document.getElementById('actpanel'); if (p) p.classList.toggle('open');
  };

  // Click a cell id in the activity feed → jump to that cell.
  const _actlog = document.getElementById('actlog');
  if (_actlog) _actlog.addEventListener('click', (e) => {
    const a = e.target.closest('.actid'); if (a && a.dataset.cid) jumpTo(a.dataset.cid);
  });
})();
