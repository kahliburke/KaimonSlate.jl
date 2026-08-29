// Notebook-level view of batch sweeps.
//
// A sweep runs AWAY from the notebook and outlives the cell that started it, so a card buried in
// one cell's output cannot answer the question a reader actually has: what is this notebook doing
// right now. That belongs in the topbar with the other run status.
//
// The sweep cards already poll their own channels, so this needs no second data path: each card
// reports what it just learned, and this aggregates. A card that is scrolled away, collapsed, or
// below the fold still reports, which is exactly when the pill earns its place.

(function () {
  const sweeps = new Map();     // key -> { key, cellId, status, ts }

  const pill = () => document.getElementById('sweeppill');
  const text = () => document.getElementById('sweeppilltext');
  const panel = () => document.getElementById('sweeppanel');

  const RUNNING = s => s === 'running' || s === 'pending';
  const BAD = s => s === 'blocked' || s === 'exhausted';

  function summary() {
    let done = 0, total = 0, failed = 0, running = 0, bad = 0, settled = 0;
    for (const e of sweeps.values()) {
      const s = e.status || {};
      done += s.done || 0; total += s.total || 0; failed += s.failed || 0;
      if (RUNNING(s.state)) running++;
      else if (BAD(s.state)) bad++;
      else settled++;
    }
    return { n: sweeps.size, done, total, failed, running, bad, settled };
  }

  function render() {
    const p = pill(), t = text();
    if (!p || !t) return;
    if (sweeps.size === 0) { p.style.display = 'none'; return; }
    const s = summary();
    p.style.display = '';
    // The pill says the one thing worth saying at a glance; the panel has the detail.
    p.classList.toggle('bad', s.bad > 0);
    p.classList.toggle('busy', s.running > 0);
    const pct = s.total ? Math.round(100 * s.done / s.total) : 100;
    let label;
    if (s.bad > 0)          label = `${s.bad} sweep${s.bad > 1 ? 's' : ''} stopped`;
    else if (s.running > 0) label = `${s.done}/${s.total} units · ${pct}%`;
    else                    label = `${s.n} sweep${s.n > 1 ? 's' : ''} done`;
    if (s.failed > 0) label += ` · ${s.failed} failed`;
    t.textContent = label;
    if (panel() && panel().classList.contains('open')) paintPanel();
  }

  function paintPanel() {
    const el = panel();
    if (!el) return;
    const rows = [...sweeps.values()].sort((a, b) => (a.cellId || '').localeCompare(b.cellId || ''));
    el.innerHTML = rows.map(e => {
      const s = e.status || {};
      const pct = s.total ? (100 * (s.done || 0) / s.total) : 0;
      const col = s.color || '#8b949e';
      const bits = [`${s.done || 0}/${s.total || 0}`];
      if (s.failed) bits.push(`<span style="color:#f85149">${s.failed} failed</span>`);
      if (s.rate > 0 && !s.settled) bits.push(`${Number(s.rate).toFixed(2)}/s`);
      return `<div class="swprow" data-cell="${e.cellId || ''}">
          <div class="swprow-top">
            <span class="swprow-dot" style="background:${col}"></span>
            <span class="swprow-label" style="color:${col}">${s.label || s.state || ''}</span>
            <span class="swprow-meta">${bits.join(' · ')}</span>
          </div>
          <div class="swprow-bar"><span style="width:${pct.toFixed(1)}%;background:${col}"></span></div>
          ${s.blocked ? `<div class="swprow-note">${s.blocked}</div>` : ''}
        </div>`;
    }).join('') || '<div class="swprow-note">no sweeps</div>';

    // Clicking a row scrolls to the cell that owns it — the pill's whole job is to get you back to
    // the thing it is telling you about.
    el.querySelectorAll('.swprow').forEach(r => {
      r.addEventListener('click', () => {
        const id = r.dataset.cell;
        const node = id && document.querySelector(`[data-id="${id}"], #cell-${id}`);
        if (node) { node.scrollIntoView({ behavior: 'smooth', block: 'center' }); close(); }
      });
    });
  }

  function close() { panel() && panel().classList.remove('open'); }

  window.slateSweeps = {
    // Called by each card on every poll. `status` is the payload the sweep's channel returned.
    report(key, cellId, status) {
      sweeps.set(key, { key, cellId, status, ts: Date.now() });
      render();
    },
    // A card removed from the DOM (cell deleted, notebook reloaded) stops counting.
    drop(key) { sweeps.delete(key); render(); },
    toggle(ev) {
      ev && ev.stopPropagation();
      const el = panel();
      if (!el) return;
      const open = el.classList.toggle('open');
      if (open) { paintPanel(); positionPanel(); }
    },
    all() { return [...sweeps.values()]; }
  };

  function positionPanel() {
    const p = pill(), el = panel();
    if (!p || !el) return;
    const r = p.getBoundingClientRect();
    el.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 360)) + 'px';
    el.style.top = (r.bottom + 6) + 'px';
  }

  document.addEventListener('click', e => {
    const el = panel();
    if (el && el.classList.contains('open') && !el.contains(e.target) &&
        e.target.id !== 'sweeppill' && !e.target.closest('#sweeppill')) close();
  });

  // Sweep away entries whose card has left the page, so a reloaded notebook does not keep
  // reporting sweeps nothing is watching.
  setInterval(() => {
    let changed = false;
    for (const [k, e] of sweeps) {
      if (!document.querySelector(`[data-sweep="sw-${k.slice(0, 12)}"]`)) {
        sweeps.delete(k); changed = true;
      }
    }
    if (changed) render();
  }, 5000);
})();
