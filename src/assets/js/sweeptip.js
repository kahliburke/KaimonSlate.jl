// The panel a sweep's unit grid shows under the pointer, and the click that opens a tile's log.
//
// A tile used to carry a `title`, which is one line of text the browser renders on its own schedule
// and nobody can select. What a reader wants off a tile is the parameter point, how long it took,
// where it ran, and — when it is red — the error, which is a panel.
//
// The grid's colours and its chunk map ride the poll, because both are O(chunks). The per-unit
// detail is O(units), so it is FETCHED for the tile being pointed at rather than broadcast for all
// six hundred of them. That also means the panel's numbers come from the same read the tile's colour
// came from, instead of a second one taken a moment later.
(function () {
  const esc = s => window.slateEscHtml(s);
  const TILE_BUDGET = 600;              // must match `_TILE_BUDGET` in sweep.jl
  const OPEN_MS = 90;                   // a pointer crossing the grid should not flash panels
  const st = new WeakMap();             // card root → { ch, status, cache }

  // A measured duration, not the card's ETA: that one rounds to "~2m" because it is a guess about
  // the future, and this is a number the unit reported.
  function ran(ms) {
    if (!(ms > 0)) return '';
    if (ms < 1000) return Math.round(ms) + ' ms';
    if (ms < 60000) return (ms / 1000).toFixed(ms < 10000 ? 2 : 1) + ' s';
    const s = Math.round(ms / 1000);
    return Math.floor(s / 60) + 'm ' + String(s % 60).padStart(2, '0') + 's';
  }

  // Unix SECONDS, as the reader's own wall clock. Bare, because the panel is read beside a tile that
  // is minutes old at most; the date belongs on the card, which says when the sweep ran.
  const clock = t => t > 0 ? new Date(t * 1000).toLocaleTimeString() : '';

  const bytes = b => b > 0 ? window.slateBytes(b) : '';

  // The one definition of how units map onto tiles lives in `_tile_spans`; this is it, in JS. The two
  // MUST agree — the grid is patched by index, so a different binning here would describe the wrong
  // units — so it is written as the same two lines rather than inferred from the tile count.
  function span(i, n) {
    const per = Math.max(1, Math.ceil(n / TILE_BUDGET));
    return { lo: i * per + 1, hi: Math.min((i + 1) * per, n) };
  }

  // Which chunk holds these units. A tile can straddle two when the binning does not divide the
  // chunking, and then the first is the one named: the click has to open ONE log, and a tile's units
  // are consecutive, so the first chunk is where its earliest unit is.
  const chunkOf = (status, lo, hi) =>
    (status.chunks || []).find(c => c[1] <= hi && c[2] >= lo) || null;

  const CH_STATE = { running: 'running', pending: 'queued', blocked: 'blocked',
                     exhausted: 'gave up', done: 'done', missing: '' };

  // ── The panel ──────────────────────────────────────────────────────────────────────────────
  let el = null, tok = 0, openTimer = 0;

  function panel() {
    if (!el) {
      el = document.createElement('div');
      el.className = 'swtip';
      document.body.appendChild(el);
    }
    return el;
  }

  function hide() {
    clearTimeout(openTimer); openTimer = 0; tok++;
    if (el) el.classList.remove('show');
  }

  // Anchored to the TILE, not the pointer: a panel that follows the cursor inside a five-pixel tile
  // jitters, and the reader is looking at the tile. Placed by `slatePlaceAt` (tooltip.js), which
  // every hovering surface shares — this had its own copy, and the two disagreed about when to flip.
  // Shown before measuring and made visible after, since a `display:none` panel has no size.
  function place(tile) {
    const p = panel();
    p.style.visibility = 'hidden'; p.classList.add('show');
    window.slatePlaceAt(p, tile, { gap: 6, align: 'start' });
    p.style.visibility = '';
  }

  // ── What it says ───────────────────────────────────────────────────────────────────────────
  // Before the fetch lands: the range, the scheduler's answer and the chunk, all of which the page
  // already holds. A panel that waited for the round trip would appear late and empty on a cluster.
  function skeleton(status, i, n) {
    const { lo, hi } = span(i, n), c = chunkOf(status, lo, hi);
    const ring = (status.rings || '')[i] || '.';
    const sched = ring === 'r' ? 'running' : ring === 'q' ? 'queued' :
                  ring === 'x' ? 'stopped' : '';
    return { lo, hi, c, ring, head:
      `<div class="swtip-h"><b>${lo === hi ? 'unit ' + lo : 'units ' + lo + '–' + hi}</b>` +
      (sched ? `<span class="swtip-chip ${ring === 'r' ? 'run' : 'pend'}">${sched}</span>` : '') +
      `</div>` };
  }

  function body(d, ring) {
    const us = d.units || [];
    if (!us.length) return `<div class="swtip-dim">nothing landed here yet</div>`;
    const ok = us.filter(u => u.status === 'ok').length;
    const bad = us.filter(u => u.status === 'error');
    let h = '';
    if (us.length === 1) {
      const u = us[0];
      h += `<div class="swtip-p">${esc(u.params)}</div>`;
      const bits = [ran(u.ms), u.node && 'on ' + u.node, clock(u.at), bytes(u.bytes)]
        .filter(Boolean);
      if (bits.length) h += `<div class="swtip-f">${esc(bits.join(' · '))}</div>`;
      // What the SCHEDULER says is already on the chip, so the body must not contradict it: "not
      // run" under a RUNNING chip reads as a disagreement when the two are describing different
      // things — the chunk is on a node, and this unit inside it has not reported yet.
      if (!u.status) {
        const why = ring === 'r' ? 'no result yet' : ring === 'q' ? '' : 'not run';
        if (why) h += `<div class="swtip-dim">${why}</div>`;
      }
    } else {
      const pend = us.length - ok - bad.length;
      h += `<div class="swtip-f">${ok} ok · ${bad.length} failed · ${pend} pending</div>`;
      const t = us.reduce((a, u) => a + (u.ms || 0), 0);
      if (t > 0) h += `<div class="swtip-f">${esc(ran(t / (ok + bad.length)))} each` +
                      `${us[0].node ? ' · on ' + esc(us[0].node) : ''}</div>`;
    }
    // The failures themselves, which is why anyone points at a red tile. Capped, because a binned
    // tile can hold a great many and the panel is not the failure list on the card.
    for (const u of bad.slice(0, 3)) {
      h += `<div class="swtip-err">${us.length > 1 ? `<i>unit ${u.i}</i>` : ''}` +
           `${esc(u.err || 'failed')}</div>`;
    }
    if (bad.length > 3) h += `<div class="swtip-dim">and ${bad.length - 3} more</div>`;
    return h;
  }

  function foot(c) {
    if (!c) return '';
    const state = CH_STATE[c[3]] !== undefined ? CH_STATE[c[3]] : c[3];
    return `<div class="swtip-foot">chunk ${esc(String(c[0]).slice(0, 10))}` +
           `${state ? ' · ' + esc(state) : ''}<span>click to open its log</span></div>`;
  }

  // ── Hover ──────────────────────────────────────────────────────────────────────────────────
  function enter(root, tile) {
    const s = st.get(root);
    if (!s || !s.status) return;
    const i = Number(tile.dataset.i), n = s.status.total || 0;
    if (!(i >= 0) || !n) return;
    const sk = skeleton(s.status, i, n);
    const my = ++tok;
    const paint = d => {
      if (my !== tok) return;                    // the pointer moved on while this was in flight
      panel().innerHTML = sk.head + (d ? body(d, sk.ring) : `<div class="swtip-dim">reading…</div>`) +
                          foot(sk.c);
      place(tile);
    };
    // A tile's detail is only stale once its colour moves, and the colour comes from the same read.
    // So a re-hover costs nothing, and a tile that changed is re-read the next time it is pointed at.
    const hit = s.cache.get(i);
    if (hit && hit.color === s.status.tiles[i]) { paint(hit.data); return; }
    paint(null);
    window.slateCall(s.ch, { action: 'tile', i: i }).then(d => {
      s.cache.set(i, { color: s.status.tiles[i], data: d });
      paint(d);
    }).catch(() => {});
  }

  // A click opens the log of the chunk that ran these units, which is the next question after "why
  // did this fail". The viewer reads any sweep in the notebook, so it is handed the key and channel
  // this card reports under.
  function click(root, tile) {
    const s = st.get(root);
    if (!s || !s.status || !window.slateLogs) return;
    const i = Number(tile.dataset.i), n = s.status.total || 0;
    const { lo, hi } = span(i, n), c = chunkOf(s.status, lo, hi);
    hide();
    window.slateLogs.open(s.key, s.ch, c ? { chunk: c[0] } : undefined);
  }

  // Called from the card on every paint: the status is replaced, the listeners are wired once.
  function attach(root, key, ch, status) {
    let s = st.get(root);
    if (!s) { s = { cache: new Map() }; st.set(root, s); }
    s.key = key; s.ch = ch; s.status = status;
    const g = root.querySelector('[data-sw="grid"]');
    if (!g || g.dataset.swtip) return;
    g.dataset.swtip = '1';
    g.addEventListener('mouseover', e => {
      const t = e.target.closest('[data-i]');
      if (!t || !g.contains(t)) return;
      clearTimeout(openTimer);
      openTimer = setTimeout(() => enter(root, t), OPEN_MS);
    });
    g.addEventListener('mouseleave', hide);
    g.addEventListener('click', e => {
      const t = e.target.closest('[data-i]');
      if (t && g.contains(t)) click(root, t);
    });
    // The panel is fixed to the viewport, so anything that moves the grid underneath it leaves it
    // pointing at a tile that is no longer there.
    window.addEventListener('scroll', hide, { passive: true, capture: true });
  }

  window.slateSweepTip = { attach, _test: { ran, span, chunkOf, body, foot, clock } };
})();
