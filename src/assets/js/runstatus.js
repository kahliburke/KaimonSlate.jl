// Live run status — driven by the SSE `runbatch:` / `cellrun:` / `celldone:` events (wired in
// panels.js). The server announces a run's size up front (`runbatch:N`) and then streams each cell
// as it starts/finishes, so we can show WHAT is happening:
//   • each running cell gets the store's transient `running` state (pulsing border) + a ticking timer;
//   • a topbar pill reads a STABLE "k / N" with a progress bar through the whole run;
//   • every run/finish/error lands in the Activity log (a debugging feed).
// All best-effort and self-contained: if an element is missing it no-ops.
(function () {
  const running = new Map();     // cellId -> start time (performance.now)
  let total = 0, done = 0, restored = 0;   // the CURRENT run batch (set by runbatch:, counts up via celldone; `restored` = cache hits this streak)
  let tick = null, idleTimer = null, _convergeT = null;
  // Progress, per running cell: its bars (one per @withprogress scope / slate_progress id) and its
  // latest reading, which drives the chip. Per cell so parallel cells don't share one set of bars.
  const bars = new Map();              // cellId -> Map(bar id -> {frac,msg})
  const lastProg = new Map();          // cellId -> {frac,msg}
  const startRev = new Map();          // cellId -> the cell's rev when it started (see onRunState)
  let errCursor = 0;                   // jump-through index for the error pill (mod the LIVE errored set)
  // Reveal delay (PER CELL): don't show run-status until SOME cell has been running > REVEAL_MS. Each
  // cell schedules its own timer on start and cancels it on finish — so a fast cell never flashes, and
  // SUSTAINED fast churn (a playhead bind driving a cell at ~10 Hz) never accumulates into a reveal the
  // way a streak-global timer would. A genuinely slow cell still trips its timer and reveals.
  let revealed = false;
  const cellReveal = new Map();        // cellId → pending reveal timer
  const REVEAL_MS = 140;
  // A multi-cell batch (startup / run-all) reveals the run-status IMMEDIATELY. A burst of fast
  // memo-restores would otherwise finish before any per-cell reveal timer trips, so the pill snaps
  // straight to "done" and you never see the restore/parallel work happening. A lone reactive cell
  // (a @bind at ~10 Hz) stays deferred so it never flashes — hence a threshold, not 1.
  const BATCH_REVEAL_MIN = 3;

  // The cell currently executing (the most recently started) — runs are sequential.
  const activeCell = () => { let last = null; for (const id of running.keys()) last = id; return last; };
  // Scroll to + select a cell (clicking a run-status indicator should take you there).
  const jumpTo = (id) => { try { window.selectCell && window.selectCell(id, true); } catch (_) {} };
  // The notebook's CURRENT errored cells, read from the authoritative state model (`window.__slateState`,
  // which `_publishState` sets and `patchCells` mutates in place — so it's correct SYNCHRONOUSLY, with no
  // race against Preact's async re-render). Deriving the error pill from this — rather than a sticky
  // streak counter that only reset on the next run — means the pill clears the moment the offending cell
  // is fixed (state flips off `errored`) or removed (it leaves the list), which an accumulator never saw.
  const liveErroredIds = () => (((window.__slateState || {}).cells) || [])
    .filter((c) => c.state === 'errored').map((c) => c.id);

  const now = () => performance.now();
  const fmt = (ms) => window.slateDuration(ms);
  const esc = s => window.slateEscHtml(s);
  const setLive = (id, s) => { try { window.slateStore && window.slateStore.setLiveState(id, s); } catch (_) {} };

  // A batch is "active" while there are cells left to run (or any cell is still executing). Pill
  // visibility tracks the BATCH, not `running.size`, so it doesn't flicker between sequential cells.
  const active = () => (total > 0 && done < total) || running.size > 0;
  window._runActive = active;   // the "Run stale" badge hides itself while a run is in flight

  function ensureTick() {
    if (tick) return;
    tick = setInterval(() => {
      if (!active()) { clearInterval(tick); tick = null; }
      sweepCellOutput(); restoreCellBars();
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
    const rs = document.getElementById('runstale'); if (rs) rs.style.display = 'none';   // pill covers status during a run
    for (const id of running.keys()) { setLive(id, 'running'); activity('run', id, ''); }   // catch up deferred starts
    ensureTick(); renderPill(); renderChip(); renderTimers();
  }

  function renderPill() {
    const pill = document.getElementById('runpill'); if (!pill) return;
    if (active()) {
      if (!revealed) return;              // mid-run but not yet revealed → leave the pill as-is
      let mx = 0; for (const t of running.values()) mx = Math.max(mx, now() - t);
      const n = Math.max(total, done + running.size);
      const k = Math.min(done + running.size, n);
      const frac = n ? Math.round((done / n) * 100) : 0;
      // Surface the two things a plain "k/N" hides: how many cells run AT ONCE (parallel batch) and how
      // many landed straight from the durable cache (restore vs recompute) — so a fast, cache-heavy
      // startup reads as "120 restored", not a glitch to "done".
      const par = running.size > 1 ? ` · ⇉ ${running.size} parallel` : '';
      const rest = restored > 0 ? ` · ♻ ${restored} restored` : '';
      pill.className = 'runpill running';
      pill.innerHTML = `<span class="rring" style="--rp:${frac}"></span>Running ${k}/${n}${par}${rest} · ${fmt(mx)}`;
      pill.style.display = '';
    } else {
      // At rest: reflect the notebook's CURRENT error state, DERIVED from live cell states — so the
      // pill clears the instant the offending cell is fixed or removed. Runs even when not `revealed`
      // (a delete/fix never revealed a run), so `window.renderRunPill` can refresh it on any edit.
      const nerr = liveErroredIds().length;
      if (nerr) { pill.className = 'runpill err'; pill.style.display = ''; pill.textContent = `⚠ ${nerr} errored`; }
      else { pill.style.display = 'none'; pill.textContent = ''; }
    }
  }
  window.renderRunPill = renderPill;   // topbar chrome calls this after a delete / state pull, so a resolved error clears

  // Tick the live elapsed time INTO THE TIME SLOT (.cdur), not the state badge — so there's one time
  // display that counts up during the run and settles to the worker's final duration on celldone (the
  // header re-renders only on state changes, so between them this owns .cdur). The badge stays the
  // state word ("running"); progress % rides the floating chip. Formatted by `slateDuration`, as the
  // final duration is.
  function renderTimers() {
    if (!revealed) return;
    for (const [id, t] of running) {
      const d = document.querySelector(`.cell[data-cid="${id}"] .cdur`);
      if (d) d.textContent = fmt(now() - t);
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
    // The chip focuses the most-recently-started cell, but during a parallel batch several run at once
    // (each also gets its own pulsing border + timer). Note the siblings so the chip doesn't read as
    // "one cell running" when it's really N.
    const extra = running.size - 1;
    const idText = extra > 0 ? `${id}  +${extra} more` : id;
    if (idEl && idEl.textContent !== idText) idEl.textContent = idText;
    const prog = lastProg.get(id) || { frac: 0, msg: '' };
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
    const cb = bars.get(id);
    if (!cb || cb.size === 0) { box && box.remove(); return; }
    if (!box) { box = document.createElement('div'); box.className = 'cellprog'; cell.insertBefore(box, cell.firstChild); }
    let html = '';
    for (const b of cb.values()) {
      const pct = b.frac > 0 ? Math.round(b.frac * 100) : 0;
      html += `<div class="cellprogrow"><div class="cellprogtrack"><span style="width:${pct}%"></span></div>` +
        `<span class="cellprogmsg">${esc(b.msg || '')}${b.frac > 0 ? (b.msg ? ' · ' : '') + pct + '%' : ''}</span></div>`;
    }
    box.innerHTML = html;
  }
  // The bars live in the cell's DOM, which a page still rendering may not have yet and a re-render of
  // the cell replaces. Redraw any running cell's bars whose box is missing.
  function restoreCellBars() {
    for (const [id, cb] of bars) {
      if (!cb.size || !running.has(id)) continue;
      const cell = document.querySelector(`.cell[data-cid="${id}"]`);
      if (cell && !cell.querySelector(':scope > .cellprog')) renderCellBars(id);
    }
  }
  function clearCellBar(id) {
    const cell = id && document.querySelector(`.cell[data-cid="${id}"]`);
    const bar = cell && cell.querySelector(':scope > .cellprog');
    if (bar) bar.remove();
  }

  // Live OUTPUT from a running cell (`cellout:` frames — see capture.jl's streaming watchdog). The
  // text is already cooked Julia-side, so a progress bar arrives as one settled line that changes
  // rather than a cascade; all that's left here is turning its colour into spans.
  //
  // It goes in a `.outlive` block at the top of the cell's output, and notebook.css hides the
  // previous run's output underneath it (`.output:has(> .outlive)`): the streaming text IS this
  // run's output, and showing both at once leaves the reader unsure which is current. Removing the
  // block is therefore the whole of the cleanup — which is why it keys off the block's presence
  // rather than a class that would have to be taken off again.
  window.onCellOutput = function (p) {
    p = p || {};
    // Only a cell we believe is RUNNING may show live output. The sampler is stopped by flag rather
    // than joined, so a frame can be in flight when the cell finishes — and applying that one after
    // `celldone:` would re-create the block and hide the real result for good.
    if (!p.cid || !running.has(p.cid)) return;
    const cell = document.querySelector(`.cell[data-cid="${p.cid}"]`);
    const host = cell && cell.querySelector(':scope > .output');
    if (!host) return;
    reveal();                             // a cell producing output is doing real work — show the chrome
    let live = host.querySelector(':scope > .outlive');
    if (!live) {
      live = document.createElement('div');
      live.className = 'outlive';
      host.insertBefore(live, host.firstChild);
    }
    const ansi = window.slateAnsiHtml;
    live.innerHTML = (p.out ? '<div class="out"><pre>' + ansi(p.out) + '</pre></div>' : '') +
                     (p.err ? '<div class="warn"><pre>' + ansi(p.err) + '</pre></div>' : '');
  };
  function clearCellOutput(id) {
    const cell = id && document.querySelector(`.cell[data-cid="${id}"]`);
    const host = cell && cell.querySelector(':scope > .output');
    if (!host) return;
    const live = host.querySelector(':scope > .outlive');
    if (live) live.remove();
  }
  // Drop any live block whose cell is no longer running. `onCellDone` is the normal path, but a run
  // can end without one — a lost worker, a WebSocket reconnect that missed the frame — and a block
  // left behind goes on hiding the cell's real output indefinitely. Swept from the status tick,
  // which is already running for exactly as long as anything can be producing frames.
  function sweepCellOutput() {
    document.querySelectorAll('.cell > .output > .outlive').forEach((live) => {
      const cell = live.closest('.cell');
      if (!cell || !running.has(cell.getAttribute('data-cid'))) live.remove();
    });
  }

  // A running cell reported progress: {cid, frac, msg, id, done}. `done` ends a scope → drop its bar;
  // otherwise upsert the bar for `id`. Progress for a cell that isn't running (a task that outlived
  // its cell) has nothing to draw on.
  window.onCellProgress = function (p) {
    p = p || {};
    const cid = p.cid || activeCell();
    if (!cid || !running.has(cid)) return;
    reveal();                             // a cell reporting progress is doing real work — show it now
    let cb = bars.get(cid);
    if (!cb) bars.set(cid, cb = new Map());
    const id = p.id || '', frac = typeof p.frac === 'number' ? p.frac : 0;
    if (p.done) cb.delete(id);
    else cb.set(id, { frac, msg: p.msg || '' });
    lastProg.set(cid, { frac, msg: p.msg || '' });
    renderChip(); renderTimers(); renderCellBars(cid);
  };

  // Click the floating chip → scroll to + select the currently-running cell.
  window.onChipClick = function () { const id = activeCell(); if (id) jumpTo(id); };

  // Stop the run. Prefer a GRACEFUL interrupt: /cancel interrupts the worker's running cells but keeps
  // the namespace (and every finished result) — the server falls back to a full worker restart on its
  // own when there's nothing to gracefully interrupt. No confirm: stopping a run is cheap and reversible
  // (re-run the cells), unlike restartWorker's namespace-nuking restart.
  window.cancelRun = async function () {
    try { renderAll(await api('POST', '/api/cancel')); } catch (_) {}
  };

  // The server announced a run of N cells. Reset the batch counters (a fresh streak) and show the pill.
  // The server reports PENDING cells (stale + running); N = what we've finished + what's pending, so
  // the pill grows as cells are queued mid-run. Only a FRESH streak (none active) resets the counters.
  window.onRunBatch = function (n, fresh) {
    clearTimeout(idleTimer);
    // Reset on a NEW run, or when nothing is in flight. The idle check alone was the whole story,
    // and it never fires for a notebook that streams: a dashboard pushing a reactive value every
    // few steps keeps `active()` true for minutes, so `done` never cleared and the pill counted
    // every cell of every cascade as if they belonged to one run — "Running 386/394" in a notebook
    // with 36 cells. The server now says which announcements start a run.
    if (fresh || !active()) { done = 0; restored = 0; errCursor = 0; }
    total = done + n;
    // A real batch (startup / run-all) shows from the FIRST cell so a fast restore/parallel burst is
    // visible instead of snapping to "done"; a lone reactive cell stays deferred (BATCH_REVEAL_MIN).
    if (n >= BATCH_REVEAL_MIN) reveal();
    if (revealed) renderPill();           // refresh k/N (reveal() renders too; a mid-run re-emit lands here)
  };

  // Pill click: while running, open the activity feed to watch; once a run has errored, step through
  // the errored cells (each click jumps to the next, scrolling it into view).
  window.onPillClick = function () {
    const eids = liveErroredIds();
    if (!active() && eids.length) { jumpTo(eids[errCursor % eids.length]); errCursor++; return; }
    window.toggleAct && window.toggleAct();
  };

  // A cell STARTED running: {id, rev}. A region cell is announced twice (while its worker comes up,
  // then to run); the first is when it started, so a second announcement keeps the clock and bars.
  window.onCellRun = function (r) {
    const id = r.id;
    clearTimeout(idleTimer);
    if (typeof r.rev === 'number') startRev.set(id, r.rev);
    if (running.has(id)) return;
    if (total === 0) total = 1;           // a one-off run with no batch announcement → degrade gracefully
    running.set(id, now());
    bars.delete(id); lastProg.delete(id); // fresh run → no bars from the previous one
    clearCellBar(id);                     // drop any stale per-cell bar from a previous run
    clearCellOutput(id);                  // and any live-output block left by the previous run
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
    const wasRestored = cell.memo === 'restored';   // came straight from the durable cache (no recompute)
    if (wasRestored) restored++;
    bars.delete(id); lastProg.delete(id); startRev.delete(id);
    clearCellBar(id);                     // remove the per-cell progress bar(s)
    clearCellOutput(id);                  // the real output has patched in — drop the live preview
    const errored = cell.state === 'errored';
    if (errored && !revealed) reveal();   // always surface errors (the pill's count is derived at render, not accumulated)
    if (revealed) {
      setLive(id, cell.state);            // clear the transient running → real state
      activity(errored ? 'err' : 'done', id, errored ? 'errored' : (wasRestored ? '♻ restored' : (t ? fmt(now() - t) : 'done')));
      renderChip();
    }
    // ALWAYS refresh the pill, even for a run too fast to ever `reveal()` — a quick fix of a
    // previously-errored cell (e.g. edit → instant success) must clear the error pill immediately,
    // not leave it stuck showing the old error until something else happens to call renderPill().
    renderPill();
    // Batch drained → end the streak shortly (a small delay absorbs the gap between sequential cells
    // and back-to-back batches, so the pill doesn't flicker). The error pill is derived from live cell
    // state at render, so it survives the streak end and clears itself once the errors are resolved.
    if (!active()) {
      clearTimeout(idleTimer);
      if (revealed) {
        // The counters wait out the gap so a cascade's next wave continues the same k/N, but the reveal
        // ends now: a run starting in that window goes through its own reveal delay. A reactive cell
        // refreshing at ~10 Hz never leaves a 600 ms gap, so a reveal held across it marked every
        // 30 ms re-run "running" for as long as the cell kept updating.
        revealed = false;
        idleTimer = setTimeout(() => { total = 0; done = 0; restored = 0; renderPill(); }, 600);
        // Converge the topbar after a VISIBLE run: `celldone` patches update each cell, but the worker
        // dot and the "Run stale" count only recompute on a full state pull — and a parallel/initial
        // run's final pull can be raced. One pull here settles the dot, the stale count, and any state
        // the patches missed. (Fast reactive churn never `reveal()`s, so it doesn't trigger this.)
        clearTimeout(_convergeT);
        _convergeT = setTimeout(() => {
          try { window.updateStates && api('GET', '/api/state').then(function (s) { updateStates(s); }).catch(function () {}); } catch (_) {}
        }, 250);
      } else { clearAllReveals(); total = 0; done = 0; restored = 0; }   // nothing was ever shown → reset silently
    }
  };

  // Pick up the run from a FULL state (page load, reconnect, a mutating request's reply). The event
  // stream only reports runs that start while the page is listening, so a page loaded mid-run learns
  // of the running cells here: when each started (the hub's clock, measured against its `now`) and the
  // bars it shows. A state can be older than events already applied (a request answered just before a
  // cell started), so a cell is only taken as finished when the state's rev for it is at least the rev
  // it started at.
  window.onRunState = function (state) {
    const cells = (state && state.cells) || [];
    const hubNow = typeof state.now === 'number' ? state.now : null;
    const seen = new Set();
    let adopted = false;
    for (const c of cells) {
      seen.add(c.id);
      if (c.state === 'running') {
        if (running.has(c.id)) continue;
        const ago = hubNow !== null && typeof c.runStartedAt === 'number' ? Math.max(0, (hubNow - c.runStartedAt) * 1000) : 0;
        running.set(c.id, now() - ago);
        if (typeof c.rev === 'number') startRev.set(c.id, c.rev);
        const cb = new Map(), ps = c.progress || [];
        for (const b of ps) cb.set(b.id || '', { frac: b.frac || 0, msg: b.msg || '' });
        bars.set(c.id, cb);
        if (ps.length) lastProg.set(c.id, { frac: ps[ps.length - 1].frac || 0, msg: ps[ps.length - 1].msg || '' });
        adopted = true;
      } else if (running.has(c.id)) {
        const r0 = startRev.get(c.id);
        if (typeof c.rev !== 'number' || r0 === undefined || c.rev >= r0) window.onCellDone(c);
      }
    }
    // A running cell missing from the document was deleted mid-run. Not while hydrating: the cells
    // are then the stored preview, which need not list a cell added since it was saved.
    if (!state.hydrating) for (const id of [...running.keys()]) if (!seen.has(id)) window.onCellDone({ id, state: 'fresh' });
    if (!adopted) return;
    clearTimeout(idleTimer);
    total = Math.max(total, done + running.size);
    reveal();                             // these cells have been running for a while already
    for (const id of running.keys()) { setLive(id, 'running'); renderCellBars(id); }
    ensureTick(); renderPill(); renderChip(); renderTimers();
  };
  // On reconnect: the hub may have restarted and taken its rev counter back to zero, and start revs
  // from the old process would then outrank every state it sends (see `resetCellRevs`, view.js).
  window.slateRunForgetRevs = function () { startRev.clear(); };
  // The boot fetch normally resolves after this file loads; if it didn't, pick its state up now.
  if (window.__slateState) window.onRunState(window.__slateState);

  // ── Activity log: a timestamped feed, kept to a bounded ring. ──────────────────────────────────
  function activity(kind, id, detail) {
    const box = document.getElementById('actlog'); if (!box) return;
    const icon = kind === 'run' ? '▶' : kind === 'err' ? '✗' : kind === 'done' ? '✓' : '·';
    const ts = new Date().toLocaleTimeString();
    // Newest lands on top; a view at the top stays pinned there. Whether it is at the top is kept
    // from scroll events: reading `scrollTop` here, after the page has changed, would force a
    // layout of the whole page for every line (a run logs one per cell).
    if (box.__pinned === undefined) {
      box.__pinned = true;
      box.addEventListener('scroll', () => { box.__pinned = box.scrollTop < 30; }, { passive: true });
    }
    const line = document.createElement('div');
    line.className = 'actline act-' + kind;
    line.innerHTML = `<span class="actts">${ts}</span><span class="acticon">${icon}</span>` +
      `<span class="actid" data-cid="${esc(id)}" title="jump to cell">${esc(id)}</span><span class="actdetail">${esc(detail)}</span>`;
    box.insertBefore(line, box.firstChild);      // prepend → newest at top (reverse-chronological)
    while (box.children.length > 600) box.removeChild(box.lastChild);   // trim the OLDEST (bottom)
    if (box.__pinned && !box.__pinPending) {
      box.__pinPending = true;
      requestAnimationFrame(() => { box.__pinPending = false; if (box.__pinned) box.scrollTop = 0; });
    }
  }
  window.slateActivity = activity;   // so other modules can log to the same feed

  window.toggleAct = function () {
    const p = document.getElementById('actpanel'); if (p) p.classList.toggle('open');
  };

  // A PDF/Typst export needs a live browser round-trip to render a chart as vector SVG (see
  // `_warm_chart_svgs!`, export_typst.jl) — genuinely slower than the old eager-render design
  // for a chart-heavy notebook, so surface it: log each cell to the activity feed and pop the
  // panel open (once per export burst, not on every event) so it's not a silent multi-second
  // pause with no feedback.
  let _exportPanelOpenT = 0;
  window.onExportProgress = function (cellId) {
    activity('run', cellId, 'rendering for export…');
    const now = performance.now();
    if (now - _exportPanelOpenT > 3000) {   // once per burst — don't fight a user who closed it
      const p = document.getElementById('actpanel'); if (p) p.classList.add('open');
    }
    _exportPanelOpenT = now;
  };

  // Click a cell id in the activity feed → jump to that cell.
  const _actlog = document.getElementById('actlog');
  if (_actlog) _actlog.addEventListener('click', (e) => {
    const a = e.target.closest('.actid'); if (a && a.dataset.cid) jumpTo(a.dataset.cid);
  });
})();
