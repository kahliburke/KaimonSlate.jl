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

  function renderPill() {
    const pill = document.getElementById('runpill'); if (!pill) return;
    if (active()) {
      let mx = 0; for (const t of running.values()) mx = Math.max(mx, now() - t);
      const n = Math.max(total, done + running.size);
      const k = Math.min(done + running.size, n);
      const frac = n ? Math.round((done / n) * 100) : 0;
      pill.className = 'runpill running';
      pill.innerHTML = `<span class="rspin"></span>Running ${k}/${n} · ${fmt(mx)}` +
        `<span class="runbar"><span style="width:${frac}%"></span></span>`;
      pill.style.display = '';
    } else if (errs) {
      pill.className = 'runpill err'; pill.style.display = '';
      pill.textContent = `⚠ ${errs} errored`;
    } else {
      pill.style.display = 'none'; pill.textContent = '';
    }
  }

  function renderTimers() {
    for (const [id, t] of running) {
      const b = document.querySelector(`.cell[data-cid="${id}"] .badge`);
      if (b) b.textContent = 'running ' + fmt(now() - t) + (id === activeCell() && prog.frac > 0 ? ' · ' + Math.round(prog.frac * 100) + '%' : '');
    }
  }

  // Floating "currently running" chip: which cell, how long, and its slate_progress bar + message.
  function renderChip() {
    const chip = document.getElementById('runchip'); if (!chip) return;
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
  window.onRunBatch = function (n) {
    clearTimeout(idleTimer);
    total = n; done = 0; errs = 0; erroredIds.length = 0; errCursor = 0;
    ensureTick(); renderPill();
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
    setLive(id, 'running');               // pulsing border via the store
    activity('run', id, '');
    ensureTick(); renderPill(); renderChip();
  };

  // A cell FINISHED (cell is its full cell_json — patchCells has already merged it).
  window.onCellDone = function (cell) {
    const id = cell.id, t = running.get(id);
    running.delete(id);
    done++;
    bars.clear();
    clearCellBar(id);                     // remove the per-cell progress bar(s)
    setLive(id, cell.state);              // clear the transient running → real state
    const errored = cell.state === 'errored';
    if (errored) { errs++; if (!erroredIds.includes(id)) erroredIds.push(id); }
    activity(errored ? 'err' : 'done', id, errored ? 'errored' : (t ? fmt(now() - t) : 'done'));
    prog = { frac: 0, msg: '' };
    renderPill(); renderChip();
    // Batch drained → end the streak shortly (a small delay absorbs the gap between sequential cells
    // and back-to-back batches, so the pill doesn't flicker). `errs` persists so the error pill stays.
    if (!active()) { clearTimeout(idleTimer); idleTimer = setTimeout(() => { total = 0; done = 0; renderPill(); }, 600); }
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
