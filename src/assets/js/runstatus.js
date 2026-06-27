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
      renderPill(); renderTimers();
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
      if (b) b.textContent = 'running ' + fmt(now() - t);
    }
  }

  // The server announced a run of N cells. Reset the batch counters (a fresh streak) and show the pill.
  window.onRunBatch = function (n) {
    clearTimeout(idleTimer);
    total = n; done = 0; errs = 0;
    ensureTick(); renderPill();
  };

  // A cell STARTED running.
  window.onCellRun = function (id) {
    clearTimeout(idleTimer);
    if (total === 0) total = 1;           // a one-off run with no batch announcement → degrade gracefully
    running.set(id, now());
    setLive(id, 'running');               // pulsing border via the store
    activity('run', id, '');
    ensureTick(); renderPill();
  };

  // A cell FINISHED (cell is its full cell_json — patchCells has already merged it).
  window.onCellDone = function (cell) {
    const id = cell.id, t = running.get(id);
    running.delete(id);
    done++;
    setLive(id, cell.state);              // clear the transient running → real state
    const errored = cell.state === 'errored';
    if (errored) errs++;
    activity(errored ? 'err' : 'done', id, errored ? 'errored' : (t ? fmt(now() - t) : 'done'));
    renderPill();
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
      `<span class="actid">${esc(id)}</span><span class="actdetail">${esc(detail)}</span>`;
    box.appendChild(line);
    while (box.children.length > 600) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  }
  window.slateActivity = activity;   // so other modules can log to the same feed

  window.toggleAct = function () {
    const p = document.getElementById('actpanel'); if (p) p.classList.toggle('open');
  };
})();
