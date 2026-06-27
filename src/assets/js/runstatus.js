// Live run status — driven by the SSE `cellrun:` / `celldone:` events (wired in panels.js). The
// server now streams each cell as it starts and finishes a run, so we can show WHAT is happening:
//   • each running cell gets the store's transient `running` state (pulsing border) + a ticking
//     elapsed timer on its badge;
//   • a topbar pill summarises the run ("⟳ Running 3/10 · 4.2s", or "⚠ 2 errored");
//   • every run/finish/error is appended to the Activity log (a debugging feed).
// All best-effort and self-contained: if an element is missing it no-ops.
(function () {
  const running = new Map();     // cellId -> start time (performance.now)
  let total = 0, done = 0, errs = 0;   // counters for the CURRENT run streak (reset when idle)
  let tick = null;

  const now = () => performance.now();
  const fmt = (ms) => ms < 1000 ? Math.round(ms) + 'ms' : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + 's';
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const setLive = (id, s) => { try { window.slateStore && window.slateStore.setLiveState(id, s); } catch (_) {} };

  function ensureTick() {
    if (tick) return;
    tick = setInterval(() => {
      if (!running.size) { clearInterval(tick); tick = null; }
      renderPill(); renderTimers();
    }, 150);
  }

  function renderPill() {
    const pill = document.getElementById('runpill'); if (!pill) return;
    if (running.size) {
      let mx = 0; for (const t of running.values()) mx = Math.max(mx, now() - t);
      pill.className = 'runpill running'; pill.style.display = '';
      const frac = total ? Math.round((done / total) * 100) : 0;
      pill.innerHTML = `<span class="rspin"></span>Running ${done + 1}/${total || (done + running.size)} · ${fmt(mx)}` +
        `<span class="runbar"><span style="width:${frac}%"></span></span>`;
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

  // A cell STARTED running.
  window.onCellRun = function (id) {
    if (!running.size && !done) { total = 0; errs = 0; }   // fresh streak after idle
    running.set(id, now());
    total = Math.max(total, done + running.size);
    setLive(id, 'running');                                // pulsing border via the store
    activity('run', id, '');
    ensureTick();
    renderPill();
  };

  // A cell FINISHED (cell is its full cell_json — patchCells has already merged it).
  window.onCellDone = function (cell) {
    const id = cell.id, t = running.get(id);
    running.delete(id);
    done++;
    setLive(id, cell.state);                               // clear the transient running → real state
    const errored = cell.state === 'errored';
    if (errored) errs++;
    activity(errored ? 'err' : 'done', id, errored ? 'errored' : (t ? fmt(now() - t) : 'done'));
    if (!running.size) { done = 0; total = 0; }            // streak drained → reset counters (errs stays for the pill)
    renderPill();
  };

  // ── Activity log: a timestamped feed of run/finish/error (and anything else that calls
  //    window.slateActivity), kept to a bounded ring so it never grows unbounded. ──────────
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
  // Exposed so other modules (structural ops, agent, errors) can log to the same feed.
  window.slateActivity = activity;

  window.toggleAct = function () {
    const p = document.getElementById('actpanel'); if (!p) return;
    p.classList.toggle('open');
  };
})();
