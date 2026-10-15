// Presentation mode — the notebook as a slide deck.
//
// Slides are segmented from the live `nbState.cells` with the SAME rules as the Julia
// `_slide_segments` (export_typst.jl): a markdown heading at depth ≤ `slideLevel` starts a slide, a
// `slide`-tagged cell starts one explicitly, a `notes`-tagged cell becomes speaker notes for its
// slide, and `collapsed` cells are skipped.
//
// To keep everything LIVE (charts animate, @bind widgets work, cells stay reactive) the current
// slide's actual `#cell-<id>` DOM nodes are MOVED onto a fixed-aspect canvas and moved back on exit —
// never cloned. The canvas is sized to the window and every length on it is a multiple of `--u`
// (one 1920th of its width for 16:9), so a slide lays out the same at any size and stays crisp.
//
// Slide configuration rides on cell tags (the first cell that sets a key wins):
//   layout=title|section|center|cover   bg=<preset|colour|gradient|image|video>   bgdim=0.5
//   transition=fade|slide|zoom|rise|none   auto=<seconds>   class=<css class>
// A cell tagged `step` (or `step=N`) is itself a build step.
//
// Builds: a slide has a step counter 0…S. Inside markdown, `::: step` blocks, `::: incremental`
// lists and `. . .` pauses each take a step; `step=N` on a block or cell orders it explicitly. A
// `@bind k SlideSteps(n)` on the slide follows the same counter, so a figure can build from
// computed state. Moving forward walks the steps, then the slides.
//
// A presenter window (`?present=1`) follows the position over a BroadcastChannel and shows previews
// of the current position and the next click, notes, a timer and rehearsal pacing; it drives the deck
// by sending it `nav` requests. It is a notebook page of its own, so its previews are built from its
// own up-to-date cells (charts as snapshots), with no second connection to the hub per preview.

(function () {
  const NBID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
  const IS_PRESENTER = new URLSearchParams(location.search).get('present') === '1';

  // ── Segmentation (mirrors export_typst.jl `_first_heading_depth` / `_slide_segments`) ──
  function _firstHeadingDepth(src) {
    if (typeof src !== 'string') return null;
    let inFence = false;
    for (const ln of src.split('\n')) {
      if (/^\s*(```|~~~)/.test(ln)) { inFence = !inFence; continue; }
      if (inFence) continue;
      const m = ln.match(/^(#{1,6})\s+\S/);
      if (m) return m[1].length;
    }
    return null;
  }
  // A cell's `key=value` tags as an object; a bare tag maps to `true`.
  function _tagMap(c) {
    const m = {};
    for (const t of (c && c.tags) || []) {
      const i = t.indexOf('=');
      if (i > 0) m[t.slice(0, i)] = t.slice(i + 1); else m[t] = true;
    }
    return m;
  }
  const _SLIDE_KEYS = ['layout', 'bg', 'bgdim', 'transition', 'auto', 'class'];
  function buildSlides() {
    const cells = (typeof nbState !== 'undefined' && nbState && nbState.cells) || [];
    const level = (nbState && nbState.slideLevel) || 2;
    const slides = [];
    let cur = { ids: [], notes: [], cfg: {} };
    const flush = () => { if (cur.ids.length || cur.notes.length) { slides.push(cur); cur = { ids: [], notes: [], cfg: {} }; } };
    for (const c of cells) {
      if (c.collapsed) continue;
      if (c.notes) { cur.notes.push(c.id); continue; }
      const d = c.kind === 'md' ? _firstHeadingDepth(c.source) : null;
      const starts = c.slide || (d != null && d <= level);
      if (starts) flush();
      cur.ids.push(c.id);
      const tm = _tagMap(c);
      for (const k of _SLIDE_KEYS) if (tm[k] != null && cur.cfg[k] == null) cur.cfg[k] = tm[k];
    }
    flush();
    return slides;
  }
  function _slideTitle(slide) {
    const cells = (nbState && nbState.cells) || [];
    for (const id of (slide ? slide.ids : [])) {
      const c = cells.find(x => x.id === id);
      if (c && c.kind === 'md') { const m = (c.source || '').match(/^\s*#{1,6}\s+(.+?)\s*#*$/m); if (m) return m[1].trim(); }
    }
    return null;
  }
  function _canvasSize() {
    return ((nbState && nbState.slideRatio) || '16:9') === '4:3' ? [1440, 1080] : [1920, 1080];
  }

  // ── Shared deck state ───────────────────────────────────────────────────────
  const D = {
    open: false, idx: 0, step: 0, total: 0, slides: [], restore: [], showCode: false, fs: false,
    items: [], reactive: [], auto: null, autoplay: false, paused: false, laser: false, draw: false,
    goto: '', mo: null, swapPending: false, vt: null, queue: [],
  };
  const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('slate-deck-' + NBID) : null;

  function _emit(type) {
    const detail = { type, idx: D.idx, step: D.step, steps: D.total, title: _slideTitle(D.slides[D.idx]) };
    try { window.dispatchEvent(new CustomEvent('slate-deck', { detail })); } catch (e) {}
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  Audience deck (the presenting tab)
  // ════════════════════════════════════════════════════════════════════════════
  function _buildDeckDom() {
    if (document.getElementById('deck')) return;
    const deck = document.createElement('div');
    deck.id = 'deck'; deck.className = 'deck'; deck.style.display = 'none';
    deck.innerHTML =
      '<div class="deck-stage" id="deckstage"></div>' +
      '<canvas class="deck-ink" id="deckink"></canvas>' +
      '<div class="deck-laser" id="decklaser"></div>' +
      '<div class="deck-black" id="deckblack"></div>' +
      '<div class="deck-goto" id="deckgoto"></div>' +
      '<div class="deck-help" id="deckhelp"></div>' +
      '<button class="deck-edge deck-prev" title="previous (←)" onclick="slidePrev()">‹</button>' +
      '<button class="deck-edge deck-next" title="next (→)" onclick="slideNext()">›</button>' +
      '<div class="deck-hud">' +
        '<span class="deck-progress" id="deckpos"></span>' +
        '<button title="toggle code (c)" onclick="slideToggleCode()">&lt;/&gt;</button>' +
        '<button title="laser pointer (l)" onclick="deckLaser()">◉</button>' +
        '<button title="draw on the slide (d · x clears)" onclick="deckDraw()">✎</button>' +
        '<button title="autoplay (a)" onclick="deckAutoplay()">⏵</button>' +
        '<button title="record (r)" onclick="window.deckRecordToggle && deckRecordToggle()">⏺</button>' +
        '<button title="camera bubble (v)" onclick="window.deckCameraToggle && deckCameraToggle()">◎</button>' +
        '<button title="presenter view (s)" onclick="openPresenter()">🪞</button>' +
        '<button title="fullscreen (f)" onclick="slideFullscreen()">⛶</button>' +
        '<button title="keys (?)" onclick="deckHelp()">?</button>' +
        '<button title="exit (Esc)" onclick="exitPresent()">✕</button>' +
      '</div>';
    document.body.appendChild(deck);
    _wireLaser(deck);
    _wireInk(deck);
  }

  // Mirror of notebook.js `_cellColumn`: a `column=N` tag (N≥2) rows a cell beside its predecessor.
  function _slideCellColumn(c) {
    for (const t of (c && c.tags) || []) { const m = /^column=(\d+)$/.exec(t); if (m) return Math.max(1, parseInt(m[1], 10) || 1); }
    return 1;
  }

  // ── Backgrounds ─────────────────────────────────────────────────────────────
  const _BG_PRESETS = ['aurora', 'nebula', 'midnight', 'ember', 'ocean', 'paper', 'slate'];
  function _mediaUrl(v) {
    if (/^(https?:|data:|blob:|\/)/.test(v)) return v;
    return (window.Slate && Slate.assetUrl) ? Slate.assetUrl(v) : v;
  }
  function _paintBg(bgEl, slide, cfg) {
    const v = cfg.bg;
    bgEl.innerHTML = ''; bgEl.className = 'slide-bg'; bgEl.style.background = '';
    slide.classList.remove('bg-media', 'bg-preset', 'has-bg');
    if (!v || v === true) return;
    slide.classList.add('has-bg');
    if (_BG_PRESETS.includes(v)) { bgEl.classList.add('bg-' + v); slide.classList.add('bg-preset', 'bgp-' + v); }
    else if (/\.(mp4|m4v|webm|mov|ogv)(\?.*)?$/i.test(v)) {
      const vid = document.createElement('video');
      vid.src = _mediaUrl(v); vid.muted = true; vid.loop = true; vid.playsInline = true; vid.autoplay = true;
      vid.className = 'slide-bg-media'; bgEl.appendChild(vid); slide.classList.add('bg-media');
    } else if (/\.(png|jpe?g|gif|webp|avif|svg)(\?.*)?$/i.test(v)) {
      const img = document.createElement('img');
      img.src = _mediaUrl(v); img.alt = ''; img.className = 'slide-bg-media';
      bgEl.appendChild(img); slide.classList.add('bg-media');
    } else bgEl.style.background = v;      // a colour or a (space-free) gradient
    const dim = parseFloat(cfg.bgdim);
    if (dim > 0) { const s = document.createElement('div'); s.className = 'slide-bg-dim'; s.style.opacity = Math.min(dim, 1); bgEl.appendChild(s); }
  }

  // The deck style gives every slide without its own `bg` a background; content slides get it dimmed
  // so text and figures stay readable, while title and section slides show it at full strength.
  function _deckStyle() { const s = nbState && nbState.deckStyle; return s && _BG_PRESETS.includes(s) ? s : ''; }
  function _effCfg(cfg, i) {
    const st = _deckStyle();
    if (cfg.bg || !st) return cfg;
    const lay = cfg.layout;
    const strong = lay === 'title' || lay === 'section' || i === 0;
    return Object.assign({}, cfg, { bg: st, bgdim: cfg.bgdim || (strong || st === 'paper' ? 0 : 0.45) });
  }

  // ── Mount / unmount ─────────────────────────────────────────────────────────
  // A slide element for slide `i`: canvas, background, body holding `nodes` (cell elements, live or
  // cloned) in their column rows, and the slide number. Cells tagged `step` are marked as build items.
  function _buildSlide(i, nodes) {
    const sld = D.slides[i] || { ids: [], cfg: {} };
    const cfg = _effCfg(sld.cfg || {}, i);
    const slide = document.createElement('div');
    slide.className = 'deck-slide' + (D.showCode ? ' show-code' : '') + (cfg.class && cfg.class !== true ? ' ' + cfg.class : '');
    slide.dataset.layout = (cfg.layout && cfg.layout !== true) ? cfg.layout : 'default';
    const bg = document.createElement('div');
    _paintBg(bg, slide, cfg);
    const body = document.createElement('div'); body.className = 'slide-body';
    const num = document.createElement('div'); num.className = 'slide-num'; num.textContent = String(i + 1);
    slide.append(bg, body, num);
    // `column=N` cells live inside a `.cell-row` flex wrapper in the notebook (see notebook.js). Moving
    // the bare cell nodes would drop that wrapper and stack them, so the rows are rebuilt here.
    const cells = (nbState && nbState.cells) || [];
    let row = null;
    nodes.forEach(({ id, el }, j) => {
      const c = cells.find(x => x.id === id);
      const tm = _tagMap(c);
      if (tm.step) { el.classList.add('step', 'deck-cellstep'); if (tm.step !== true) el.dataset.step = tm.step; }
      const col = c ? _slideCellColumn(c) : 1;
      if (col >= 2 && row) { row.appendChild(el); return; }
      const nextC = nodes[j + 1] && cells.find(x => x.id === nodes[j + 1].id);
      if (nextC && _slideCellColumn(nextC) >= 2) {
        row = document.createElement('div'); row.className = 'cell-row';
        row.appendChild(el); body.appendChild(row);
      } else { row = null; body.appendChild(el); }
    });
    _applySplit(slide);
    return slide;
  }
  // Mount slide `i` on the deck. The live cells move (never clone); each one's home is remembered.
  function _mountSlide(i) {
    _unmount();
    const stage = document.getElementById('deckstage');
    const sld = D.slides[i] || { ids: [], cfg: {} };
    const nodes = [];
    for (const id of sld.ids) {
      const el = document.getElementById('cell-' + id);
      if (!el) continue;
      D.restore.push({ el, slot: el.parentNode });
      nodes.push({ id, el });
    }
    const slide = _buildSlide(i, nodes);
    stage.appendChild(slide);
    _typesetSlide(slide);
    _collectSteps(slide, sld);
    _fit();
    _watch(slide);
    requestAnimationFrame(() => _relayout(slide));
  }
  function _unmount() {
    if (D.mo) { D.mo.disconnect(); D.mo = null; }
    _clearAuto();
    _inkClear();
    const stage = document.getElementById('deckstage');
    const old = stage && stage.querySelector('.deck-slide');
    if (old) old.querySelectorAll('video, audio').forEach(m => { m._deckPlayed = false; try { m.pause(); } catch (e) {} });
    for (const r of D.restore) {
      r.el.classList.remove('slide-split', 'step', 'deck-cellstep', 'on', 'current');
      delete r.el.dataset.step;
      r.el.style.removeProperty('view-transition-name');
      r.el.querySelectorAll('[style*="view-transition-name"]').forEach(n => n.style.removeProperty('view-transition-name'));
      r.el.querySelectorAll('.deck-ctl-hidden').forEach(n => n.classList.remove('deck-ctl-hidden'));
      _restoreCellCharts(r.el);
      if (r.slot.isConnected) r.slot.appendChild(r.el);
      else r.el.remove();                      // its cell is gone (see `_deckSettle`)
    }
    D.restore = [];
    D.items = []; D.reactive = [];
    if (stage) stage.innerHTML = '';
  }
  // A cell re-rendered while on the slide (a reactive step redraws its markdown, a chart replaces its
  // output) comes back without the step classes; re-collect so the build state holds.
  function _watch(slide) {
    const body = slide.querySelector('.slide-body');
    let pending = false;
    D.mo = new MutationObserver(() => {
      if (pending) return;
      pending = true;
      requestAnimationFrame(() => {
        pending = false;
        if (!D.open || !slide.isConnected) return;
        _collectSteps(slide, D.slides[D.idx], true);
            _relayout(slide);
      });
    });
    D.mo.observe(body, { childList: true, subtree: true });
  }
  // notebook.js calls this when a `MemoCell` unmounts. A slide cell whose `.cellslot` left #nb was
  // deleted, or preact mounted it again in a new slot. After the render, put the new node in the old
  // one's place on the slide, or take the deleted cell off the slide.
  let _settling = false;
  function _deckSettle() {
    if (!D.open || _settling) return;
    _settling = true;
    queueMicrotask(() => {
      _settling = false;
      const nb = document.getElementById('nb');
      let changed = false;
      D.restore = D.restore.filter(r => {
        if (r.slot.isConnected) return true;
        changed = true;
        const el = nb && nb.querySelector('#' + CSS.escape(r.el.id));
        if (!el) { r.el.remove(); return false; }
        r.slot = el.parentNode;
        r.el.replaceWith(el);
        r.el = el;
        return true;
      });
      if (changed) requestAnimationFrame(() => _relayout());
    });
  }

  // ── Builds ──────────────────────────────────────────────────────────────────
  // Every build item on the slide, in document order, each with the step it appears on. Items without
  // an explicit `step=N` take the next number; a pause's group shares one.
  function _scanSteps(body, sld, sentOf) {
    // `. . .` → everything after the marker, among its siblings, is one group.
    body.querySelectorAll('.pause').forEach((m, k) => {
      const g = 'p' + k + '-' + Math.random().toString(36).slice(2, 7);
      for (let n = m.nextElementSibling; n; n = n.nextElementSibling) {
        if (n.classList.contains('pause')) break;
        n.classList.add('step'); n.dataset.stepGroup = g;
      }
    });
    // `::: derive` — a sequence of equations shown one at a time in one place; each after the first is
    // a step, and stepping turns the current equation into the next (see `_applyStep`).
    body.querySelectorAll('.derive').forEach(dv => {
      [...dv.children].forEach((eq, k) => { eq.classList.add('derive-eq'); if (k > 0) eq.classList.add('step'); });
    });
    body.querySelectorAll('.incremental').forEach(inc => {
      const fx = [...inc.classList].filter(x => x !== 'incremental');
      const lists = inc.querySelectorAll(':scope > ul > li, :scope > ol > li');
      const kids = lists.length ? lists : inc.children;
      for (const li of kids) { li.classList.add('step', ...fx); }
    });
    const items = [];
    let c = 0;
    const groups = {};
    for (const el of body.querySelectorAll('.step')) {
      let explicit = parseInt(el.dataset.step || el.getAttribute('step') || '', 10);
      if (!(explicit > 0)) for (const c of el.classList) if (c.startsWith('stepat-')) explicit = parseInt(c.slice(7), 10);
      let idx;
      if (el.dataset.stepGroup && groups[el.dataset.stepGroup] != null) idx = groups[el.dataset.stepGroup];
      else if (explicit > 0) idx = explicit;
      else idx = ++c;
      if (el.dataset.stepGroup) groups[el.dataset.stepGroup] = idx;
      items.push({ el, idx });
    }
    // `SlideSteps` controls on this slide: hidden here, driven by the counter.
    const reactive = [];
    const cells = (nbState && nbState.cells) || [];
    for (const id of (sld ? sld.ids : [])) {
      const cell = cells.find(x => x.id === id);
      for (const b of (cell && cell.binds) || []) {
        const p = b.params || {};
        if (!p.slidesteps) continue;
        reactive.push({ name: b.name, n: parseInt(p.max, 10) || 0, sent: sentOf ? sentOf(b.name) : null });
      }
    }
    for (const ctl of body.querySelectorAll('[data-name]')) {
      if (!reactive.some(r => r.name === ctl.dataset.name)) continue;
      const box = ctl.closest('.control, .widget, .bindrow') || ctl;
      box.classList.add('deck-ctl-hidden');
    }
    body.querySelectorAll('.cell').forEach(cel => {
      const binds = cel.querySelector(':scope > .binds');
      const onlyHidden = binds && binds.querySelector('.deck-ctl-hidden') &&
        ![...binds.querySelectorAll('[data-name]')].some(x => !x.closest('.deck-ctl-hidden'));
      cel.classList.toggle('deck-bindonly', !!onlyHidden && !_hasVisibleOutput(cel));
    });
    return { items, reactive, total: Math.max(0, ...items.map(x => x.idx), ...reactive.map(r => r.n)) };
  }
  function _collectSteps(slide, sld, keepStep) {
    const r = _scanSteps(slide.querySelector('.slide-body'), sld, keepStep ? _reactiveSent : null);
    D.items = r.items; D.reactive = r.reactive; D.total = r.total;
    _applyStep(keepStep ? Math.min(D.step, D.total) : D.step, true);
  }
  function _reactiveSent(name) { const r = D.reactive.find(x => x.name === name); return r ? r.sent : null; }
  // One request in flight per bound value, and the latest value always goes last: clicking through a
  // build faster than the figure recomputes must land on the step the presenter stopped at, and
  // overlapping requests can be applied out of order.
  const _inflight = new Map();   // name → { busy, want }
  function _sendReactive(r, v) {
    if (r.sent === v || !window.slateSetBind) return;
    r.sent = v;
    let q = _inflight.get(r.name);
    if (!q) { q = { busy: false, want: null }; _inflight.set(r.name, q); }
    if (q.busy) { q.want = v; return; }
    const send = val => {
      q.busy = true;
      Promise.resolve(slateSetBind(r.name, val)).catch(() => {}).finally(() => {
        q.busy = false;
        if (q.want !== null && q.want !== val) { const nv = q.want; q.want = null; send(nv); }
        else q.want = null;
      });
    };
    send(v);
  }
  function _hasVisibleOutput(cel) {
    for (const sel of [':scope > .output', ':scope > .echarts', ':scope > .tables', ':scope > .md', ':scope > .anim'])
      for (const n of cel.querySelectorAll(sel)) if (n.childNodes.length && n.textContent.trim() + n.querySelectorAll('canvas,img,svg,video').length) return true;
    return false;
  }
  function _stepClasses(s) {
    for (const it of D.items) {
      it.el.classList.toggle('on', it.idx <= s);
      it.el.classList.toggle('current', it.idx === s);
    }
    for (const dv of _derives()) { const eq = _deriveTarget(dv, s); for (const c of dv.children) c.classList.toggle('derive-cur', c === eq); }
  }
  function _derives() {
    const slide = document.querySelector('#deckstage .deck-slide');
    return slide ? [...slide.querySelectorAll('.slide-body .derive')] : [];
  }
  // The equation a derive block shows at step `s`: the last one whose step has come.
  function _deriveTarget(dv, s) {
    let cur = dv.children[0];
    for (const c of dv.children) {
      const it = D.items.find(x => x.el === c);
      if (c === dv.children[0] || (it && it.idx <= s)) cur = c;
    }
    return cur;
  }
  // Terms of one equation, keyed by name and occurrence, so the second ω of one equation pairs with the
  // second ω of the next.
  function _termKeys(root) {
    const out = new Map(), seen = {};
    for (const t of root.querySelectorAll('.katex .term')) {
      const n = window.slateTermName ? slateTermName(t) : null; if (!n) continue;
      const k = (seen[n] = (seen[n] || 0) + 1);
      out.set('t:' + n + '#' + k, t);
    }
    return out;
  }
  function _applyStep(s, quiet) {
    s = Math.max(0, Math.min(s, D.total));
    // A derive block that changes equation on this step transforms in place: terms both equations name
    // glide to their new places, the rest crossfades.
    const moving = [];
    for (const dv of _derives()) {
      const from = _deriveTarget(dv, D.step), to = _deriveTarget(dv, s);
      if (from !== to) moving.push([from, to]);
    }
    D.step = s;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (!quiet && moving.length && document.startViewTransition && !reduce && !D.swapPending) {
      const pairs = [];
      for (const [from, to] of moving) {
        const a = _termKeys(from), b = _termKeys(to);
        for (const [k, el] of a) if (b.has(k)) pairs.push([k, el, b.get(k)]);
      }
      pairs.forEach(([k, el]) => { el.style.viewTransitionName = 'dt-' + _hash(k); });
      const root = document.documentElement;
      root.dataset.deckTrans = 'derive';
      D.swapPending = true;
      const vt = D.vt = document.startViewTransition(() => {
        D.swapPending = false; D.vt = null;
        pairs.forEach(([, el]) => el.style.removeProperty('view-transition-name'));
        _stepClasses(s);
        pairs.forEach(([k, , el]) => { el.style.viewTransitionName = 'dt-' + _hash(k); });
        if (D.queue.length) setTimeout(_drain, 0);
      });
      vt.ready.catch(() => {}); vt.updateCallbackDone.catch(() => {});
      vt.finished.catch(() => {}).finally(() => {
        delete root.dataset.deckTrans;
        pairs.forEach(([, , el]) => el.style.removeProperty('view-transition-name'));
      });
    } else _stepClasses(s);
    for (const r of D.reactive) _sendReactive(r, Math.min(s, r.n));
    _playVisibleMedia();
    _syncHud();
    if (_trackPos()) _scheduleAuto();
    if (!quiet) { _emit('step'); _broadcast(); }
  }
  function _playVisibleMedia() {
    const slide = document.querySelector('#deckstage .deck-slide');
    if (!slide) return;
    for (const m of slide.querySelectorAll('.slide-body [data-autoplay]')) {
      const hidden = m.closest('.step:not(.on)');
      if (hidden) { if (!m.paused) m.pause(); continue; }
      if (m.paused && !m._deckPlayed) { m._deckPlayed = true; m.currentTime = 0; m.play().catch(() => {}); }
    }
  }

  // ── Code split (code left, output right, while code is shown) ───────────────
  function _applySplit(slide) {
    let any = false;
    for (const el of slide.querySelectorAll('.slide-body > .cell.code, .slide-body > .cell.bind')) {
      let hasOut = false;
      el.querySelectorAll(':scope > .output, :scope > .tables, :scope > .echarts, :scope > .anim')
        .forEach(n => { if (n.childNodes.length) hasOut = true; });
      el.classList.toggle('slide-split', hasOut);
      any = any || hasOut;
    }
    slide.classList.toggle('has-split', any);
  }

  // ── Fit ─────────────────────────────────────────────────────────────────────
  function _cellCharts(el) {
    return (window.charts && window.charts[el.id.replace(/^cell-/, '')]) || [];
  }
  // A chart's natural size is its size in the notebook, recorded while the notebook is on screen: once
  // presenting, the notebook is hidden and a chart measured there has no real width. A chart first
  // seen on a slide (a cell re-ran while it was up) takes its size there, unless that is degenerate.
  const _natural = new WeakMap();   // chart instance → [w, h]
  // The notebook's own inline sizing of a chart element, saved before the deck first changes it. Keyed
  // by element: a cell that re-runs may draw a new chart into the same element.
  const _origStyle = new WeakMap(); // chart element → [inline width, inline height]
  function _recordNatural(inst) {
    const w = inst.getWidth(), h = inst.getHeight();
    _natural.set(inst, (w >= 240 && h >= 120) ? [w, h] : [900, 450]);
  }
  function _slideCharts() {
    const out = [];
    for (const r of D.restore) for (const inst of _cellCharts(r.el)) {
      const dom = inst.getDom && inst.getDom(); if (!dom || !dom.isConnected) continue;
      if (!_natural.has(inst)) _recordNatural(inst);
      const [natW, natH] = _natural.get(inst);
      out.push({ inst, dom, natW, natH });
    }
    return out;
  }
  function _sizeChart(c, w, h) {
    w = Math.max(80, Math.round(w)); h = Math.max(60, Math.round(h));
    if (!_origStyle.has(c.dom)) _origStyle.set(c.dom, [c.dom.style.width, c.dom.style.height]);
    if (c.dom.style.width === w + 'px' && c.dom.style.height === h + 'px') return;
    c.dom.style.width = w + 'px'; c.dom.style.height = h + 'px';
    try { c.inst.resize({ width: w, height: h }); } catch (e) {}
  }
  // Size the canvas to the stage, then fit the content to the canvas: charts take the width they are
  // given (keeping their aspect), and give up height first when the slide overflows; text shrinks
  // only after that, and below a legible floor the body scrolls instead.
  function _fit() {
    const stage = document.getElementById('deckstage');
    const slide = stage && stage.querySelector('.deck-slide');
    if (!slide) return;
    _sizeCanvas(slide, stage.clientWidth, stage.clientHeight);
    const body = slide.querySelector('.slide-body');
    body.style.setProperty('--shrink', 1);
    body.classList.remove('scroll');
    const charts = _slideCharts();
    const availH = body.clientHeight;
    for (const c of charts) {
      const host = c.dom.parentElement;
      const hw = (host && host.clientWidth) || c.natW;
      const k = Math.min(hw / c.natW, (availH * 0.82) / c.natH);
      _sizeChart(c, c.natW * k, c.natH * k);
    }
    let over = body.scrollHeight - body.clientHeight;
    if (over > 1 && charts.length) {
      const tot = charts.reduce((a, c) => a + c.dom.clientHeight, 0);
      const k = Math.max(0.5, 1 - over / Math.max(1, tot));
      for (const c of charts) _sizeChart(c, c.dom.clientWidth * k, c.dom.clientHeight * k);
      over = body.scrollHeight - body.clientHeight;
    }
    if (over > 1 && _shrinkText(body)) body.classList.add('scroll');
  }
  function _sizeCanvas(slide, vw, vh) {
    const [W, H] = _canvasSize();
    const s = Math.min(vw / W, vh / H);
    slide.style.width = Math.round(W * s) + 'px';
    slide.style.height = Math.round(H * s) + 'px';
    slide.style.setProperty('--u', s + 'px');
  }
  // Scale the body text down until it fits, to a legible floor. True when it still overflows.
  function _shrinkText(body) {
    let shrink = 1, over = body.scrollHeight - body.clientHeight;
    for (let pass = 0; pass < 3 && over > 1; pass++) {
      shrink = Math.max(0.62, shrink * body.clientHeight / body.scrollHeight);
      body.style.setProperty('--shrink', shrink);
      over = body.scrollHeight - body.clientHeight;
      if (shrink <= 0.62) break;
    }
    return over > 1;
  }
  function _relayout(slide) {
    slide = slide || document.querySelector('#deckstage .deck-slide');
    if (!slide) return;
    _reviewSplitFit(slide);
    _fit();
  }
  function _reviewSplitFit(slide) {
    _applySplit(slide);
    const body = slide.querySelector('.slide-body');
    const maxH = body ? body.clientHeight : 900;
    for (const el of slide.querySelectorAll('.slide-body > .cell.slide-split')) {
      const src = el.querySelector(':scope > .srchost, :scope > .srcedit');
      if (D.showCode && src && src.scrollHeight > maxH) el.classList.remove('slide-split');
    }
    slide.classList.toggle('has-split', !!slide.querySelector('.slide-body > .cell.slide-split'));
  }
  // Put a chart back to its notebook sizing. Its home is hidden while presenting, so it is measured
  // again only once the notebook is back on screen (`exitPresent`).
  function _restoreCellCharts(el) {
    for (const inst of _cellCharts(el)) {
      const dom = inst.getDom && inst.getDom(), orig = dom && _origStyle.get(dom); if (!orig) continue;
      dom.style.width = orig[0]; dom.style.height = orig[1];
      _origStyle.delete(dom);
      if (!D.open) try { inst.resize({ width: 'auto', height: 'auto' }); } catch (e) {}
    }
  }
  function _typesetSlide(slide) {
    if (window.typeset) try { window.typeset(slide); } catch (e) {}
  }
  function _syncHud() {
    const pos = document.getElementById('deckpos');
    if (pos) pos.textContent = (D.idx + 1) + ' / ' + D.slides.length + (D.total ? '  ·  ' + D.step + '/' + D.total : '');
  }

  // ── Transitions ─────────────────────────────────────────────────────────────
  // The View Transitions API animates between the outgoing and incoming slide. An element present on
  // both (a heading with the same text, an image with the same source, or anything marked
  // `::: {.morph name=x}` / tagged `morph=x`) is given one shared name, so it moves and resizes into
  // its new place while the rest of the slide transitions around it.
  function _transKind(i) {
    const cfg = (D.slides[i] && D.slides[i].cfg) || {};
    const t = (cfg.transition && cfg.transition !== true) ? cfg.transition : ((nbState && nbState.slideTransition) || 'fade');
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return 'none';
    return t;
  }
  function _hash(s) { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0; return (h >>> 0).toString(36); }
  function _morphKeys(root) {
    const out = new Map(), dup = new Set();
    const put = (k, el) => { if (out.has(k)) dup.add(k); else out.set(k, el); };
    root.querySelectorAll('h1, h2, h3').forEach(h => { const t = h.textContent.trim(); if (t) put('h:' + t, h); });
    root.querySelectorAll('img').forEach(im => { if (im.getAttribute('src')) put('i:' + im.getAttribute('src'), im); });
    root.querySelectorAll('.morph[name], [data-morph]').forEach(el => put('m:' + (el.getAttribute('name') || el.dataset.morph), el));
    for (const [k, el] of _termKeys(root)) put(k, el);
    for (const k of dup) out.delete(k);
    return out;
  }
  function _cellMorphKeys(ids) {
    const all = new Map(), dup = new Set();
    const cells = (nbState && nbState.cells) || [];
    for (const id of ids) {
      const el = document.getElementById('cell-' + id); if (!el) continue;
      const c = cells.find(x => x.id === id), tm = _tagMap(c);
      if (tm.morph && tm.morph !== true) { const k = 'm:' + tm.morph; all.has(k) ? dup.add(k) : all.set(k, el); }
      for (const [k, v] of _morphKeys(el)) all.has(k) ? dup.add(k) : all.set(k, v);
    }
    for (const k of dup) all.delete(k);
    return all;
  }
  // A view transition swaps the slide a frame or two after it starts, so until then the deck's position
  // is still the outgoing slide's. Navigation that arrives in that window is held, the transition is
  // cut short, and the held moves replay against the slide that is actually up.
  function _held(fn) {
    if (!D.swapPending) return false;
    D.queue.push(fn);
    try { D.vt && D.vt.skipTransition(); } catch (e) {}
    return true;
  }
  function _drain() {
    const q = D.queue.splice(0);
    for (const f of q) f();
  }
  function _go(i, dir, atEnd, fromRemote) {
    if (!D.open) return;
    if (_held(() => _go(i, dir, atEnd, fromRemote))) return;
    const ov = document.getElementById('deckoverview'); if (ov) ov.remove();
    i = Math.max(0, Math.min(i, D.slides.length - 1));
    if (i === D.idx && D.restore.length) return;
    dir = dir != null ? dir : (i > D.idx ? 1 : -1);
    const kind = _transKind(dir > 0 ? i : D.idx);
    // Announced from inside the swap: with a view transition the swap runs after this function
    // returns, and listeners must hear the slide that is actually up.
    const carry = _chartCarry(D.idx, i);
    const swap = () => {
      D.swapPending = false; D.vt = null;
      D.idx = i; D.step = 0;
      _mountSlide(i);
      _applyCarry(carry);
      if (atEnd) _applyStep(D.total, true);
      _emit('slide');
      if (!fromRemote) _broadcast();
      if (D.queue.length) setTimeout(_drain, 0);
    };
    const stage = document.getElementById('deckstage');
    const oldSlide = stage && stage.querySelector('.deck-slide');
    if (!oldSlide || kind === 'none' || !document.startViewTransition) {
      swap();
      _fallbackEnter(kind, dir);
    } else {
      const oldKeys = new Map([..._cellMorphKeys(D.slides[D.idx].ids)].filter(([, el]) => oldSlide.contains(el)));
      const newKeys = _cellMorphKeys(D.slides[i].ids);
      const shared = [...oldKeys.keys()].filter(k => newKeys.has(k));
      shared.forEach(k => { oldKeys.get(k).style.viewTransitionName = 'dm-' + _hash(k); });
      const root = document.documentElement;
      root.dataset.deckTrans = kind; root.dataset.deckDir = dir > 0 ? 'next' : 'prev';
      D.swapPending = true;
      const vt = D.vt = document.startViewTransition(() => {
        oldKeys.forEach(el => el.style.removeProperty('view-transition-name'));
        swap();
        shared.forEach(k => { const el = newKeys.get(k); if (el) el.style.viewTransitionName = 'dm-' + _hash(k); });
      });
      // Skipping (above, or by a newer transition) rejects these; that is expected, not an error.
      vt.ready.catch(() => {}); vt.updateCallbackDone.catch(() => {});
      vt.finished.catch(() => {}).finally(() => {
        delete root.dataset.deckTrans; delete root.dataset.deckDir;
        newKeys.forEach(el => el.style.removeProperty('view-transition-name'));
      });
    }
  }
  // Data morph. Chart cells on consecutive slides tagged with the same `morph=name` are one figure
  // changing form: the incoming chart is first drawn with the outgoing chart's option, then given its own
  // with ECharts' universal transition, so marks travel to their new places (points gathering into bars,
  // a line becoming columns). Marks pair up by series `id`, or across series by `groupId` on data items.
  function _chartCarry(from, to) {
    const cells = (nbState && nbState.cells) || [];
    const keyOf = id => { const t = _tagMap(cells.find(x => x.id === id)).morph; return t && t !== true ? t : null; };
    const want = new Map();
    for (const id of (D.slides[to] || { ids: [] }).ids) { const k = keyOf(id); if (k) want.set(k, id); }
    const out = [];
    for (const id of (D.slides[from] || { ids: [] }).ids) {
      const k = keyOf(id), dest = k && want.get(k);
      const opt = dest && _specOf((window.charts && window.charts[id] || [])[0]);
      if (opt) out.push({ dest, opt });
    }
    return out;
  }
  // The option the page last applied to a chart (core.js `_geoSafeSetOption` keeps it as JSON). The
  // instance's own `getOption()` is its internal model, which cannot be handed back to `setOption`.
  function _specOf(inst) {
    if (!inst || !inst.__slateOptSig) return null;
    try { return JSON.parse(inst.__slateOptSig); } catch (e) { return null; }
  }
  function _withMorph(opt, anim) {
    const o = Object.assign({}, opt, { animation: anim, animationDurationUpdate: 1100, animationEasingUpdate: 'cubicInOut' });
    o.series = (opt.series || []).map(x => Object.assign({}, x, { universalTransition: { enabled: true, divideShape: 'split' } }));
    return o;
  }
  function _applyCarry(carry) {
    for (const { dest, opt } of carry) {
      const inst = (window.charts && window.charts[dest] || [])[0];
      if (!inst) continue;
      const own = _specOf(inst); if (!own) continue;
      try {
        inst.setOption(_withMorph(opt, false), { notMerge: true });
        requestAnimationFrame(() => { try { inst.setOption(_withMorph(own, true), { notMerge: true }); } catch (e) {} });
      } catch (e) {}
    }
  }
  function _fallbackEnter(kind, dir) {
    const slide = document.querySelector('#deckstage .deck-slide');
    if (!slide || kind === 'none' || D.slides.length <= 1) return;
    const cls = kind === 'slide' ? (dir < 0 ? 'enter-prev' : 'enter-next') : kind === 'zoom' ? 'enter-zoom' : 'enter-fade';
    slide.classList.add(cls);
    requestAnimationFrame(() => requestAnimationFrame(() => slide.classList.remove(cls)));
  }
  function slideNext() {
    if (_held(slideNext)) return;
    if (D.step < D.total) _applyStep(D.step + 1);
    else if (D.idx < D.slides.length - 1) _go(D.idx + 1, 1);
  }
  function slidePrev() {
    if (_held(slidePrev)) return;
    if (D.step > 0) _applyStep(D.step - 1);
    else if (D.idx > 0) _go(D.idx - 1, -1, true);
  }

  function _slideJump(d) { if (!_held(() => _slideJump(d))) _go(D.idx + d, d); }

  // ── Timing ──────────────────────────────────────────────────────────────────
  // `auto=N` advances that slide (each step, then on to the next slide) every N seconds. Autoplay (a)
  // does the same for every slide, at the slide's own `auto` or the deck default.
  const _AUTO_DEFAULT = 8;
  function _clearAuto() { if (D.auto) { clearTimeout(D.auto); D.auto = null; } _autoBar(0); }
  function _scheduleAuto() {
    _clearAuto();
    if (!D.open || D.paused || D.rehearse) return;
    const cfg = (D.slides[D.idx] && D.slides[D.idx].cfg) || {};
    let secs = parseFloat(cfg.auto);
    if (D.autoplay) {
      const t = _timings()[_posKey()];
      secs = t > 0 ? t : secs > 0 ? secs : (parseFloat(nbState && nbState.slideAuto) || _AUTO_DEFAULT);
    }
    if (!(secs > 0)) return;
    if (D.step >= D.total && D.idx >= D.slides.length - 1) return;
    _autoBar(secs);
    D.auto = setTimeout(() => { D.auto = null; slideNext(); }, secs * 1000);
  }
  function _autoBar(secs) {
    const slide = document.querySelector('#deckstage .deck-slide');
    let bar = slide && slide.querySelector('.slide-autobar');
    if (!secs) { if (bar) bar.remove(); return; }
    if (!slide) return;
    if (bar) bar.remove();
    bar = document.createElement('div'); bar.className = 'slide-autobar';
    bar.style.animationDuration = secs + 's';
    slide.appendChild(bar);
  }
  function deckAutoplay() {
    D.autoplay = !D.autoplay; D.paused = false;
    _flash(D.autoplay ? 'autoplay on' : 'autoplay off');
    _scheduleAuto();
  }
  function _togglePause() {
    D.paused = !D.paused;
    _flash(D.paused ? 'paused' : 'resumed');
    _scheduleAuto();
  }

  // ── Rehearsal ───────────────────────────────────────────────────────────────
  // A position is keyed by its slide's first cell id and the step, so timings survive slides being
  // added or reordered elsewhere in the notebook. Rehearsing (t) times every position as you click
  // through; stopping saves them to the notebook, where autoplay and the presenter's pacing read them.
  function _slideKey(i) { const sl = D.slides[i]; return sl && sl.ids.length ? sl.ids[0] : 's' + i; }
  function _posKey() { return _slideKey(D.idx) + ':' + D.step; }
  function _parseTimings(str) {
    const out = {};
    for (const part of String(str || '').split(',')) {
      const m = /^([A-Za-z0-9_]+:\d+)=(\d+(?:\.\d+)?)$/.exec(part.trim());
      if (m) out[m[1]] = parseFloat(m[2]);
    }
    return out;
  }
  function _timings() { return _parseTimings(nbState && nbState.slideTimings); }
  function _trackPos() {
    const k = _posKey(), now = performance.now();
    if (k === D.posKey) return false;
    if (D.rehearse && D.posKey) D.rehearse[D.posKey] = Math.round((now - D.posT) / 100) / 10;
    D.posKey = k; D.posT = now;
    return true;
  }
  function deckRehearse() {
    if (!D.rehearse) {
      D.rehearse = {}; D.posKey = null; _trackPos();
      _clearAuto();
      _flash('rehearsing: timing every step');
    } else {
      const now = performance.now();         // close the position on screen
      if (D.posKey) D.rehearse[D.posKey] = Math.round((now - D.posT) / 100) / 10;
      D.posT = now;
      const t = Object.assign(_timings(), D.rehearse);
      D.rehearse = null;
      const str = Object.entries(t).map(([k, v]) => k + '=' + v).join(',');
      fetch('/api/' + encodeURIComponent(NBID) + '/slideconfig', { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ timings: str }) })
        .then(r => r.ok ? r.json() : null)
        .then(st => { if (st && st.meta) nbState.slideTimings = st.meta.slideTimings; else nbState.slideTimings = str;
                      _flash('timings saved'); _broadcast(); })
        .catch(() => _flash('could not save timings'));
      _scheduleAuto();
    }
    _broadcast();
  }

  // ── Pointer, ink, blackout, go-to, help ─────────────────────────────────────
  function _wireLaser(deck) {
    const dot = deck.querySelector('#decklaser');
    deck.addEventListener('pointermove', e => {
      if (!D.laser) return;
      dot.style.transform = 'translate(' + e.clientX + 'px,' + e.clientY + 'px)';
    });
  }
  function deckLaser() {
    D.laser = !D.laser;
    if (D.laser && D.draw) deckDraw();
    document.getElementById('deck').classList.toggle('laser-on', D.laser);
  }
  let _ink = null;
  function _wireInk(deck) {
    const cv = deck.querySelector('#deckink');
    const ctx = cv.getContext('2d');
    let drawing = false, last = null;
    const size = () => {
      const r = window.devicePixelRatio || 1;
      cv.width = innerWidth * r; cv.height = innerHeight * r;
      ctx.setTransform(r, 0, 0, r, 0, 0);
    };
    size(); addEventListener('resize', size);
    cv.addEventListener('pointerdown', e => { drawing = true; last = [e.clientX, e.clientY]; cv.setPointerCapture(e.pointerId); });
    cv.addEventListener('pointermove', e => {
      if (!drawing) return;
      ctx.strokeStyle = getComputedStyle(deck).getPropertyValue('--deck-ink').trim() || '#ff4d6d';
      ctx.lineWidth = 4; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ctx.beginPath(); ctx.moveTo(last[0], last[1]); ctx.lineTo(e.clientX, e.clientY); ctx.stroke();
      last = [e.clientX, e.clientY];
    });
    cv.addEventListener('pointerup', () => { drawing = false; });
    _ink = { cv, ctx };
  }
  function _inkClear() { if (_ink) _ink.ctx.clearRect(0, 0, _ink.cv.width, _ink.cv.height); }
  function deckDraw() {
    D.draw = !D.draw;
    if (D.draw && D.laser) deckLaser();
    document.getElementById('deck').classList.toggle('draw-on', D.draw);
  }
  function _blackout() { document.getElementById('deck').classList.toggle('black-on'); }
  let _flashT = null;
  function _flash(msg) {
    const g = document.getElementById('deckgoto'); if (!g) return;
    g.textContent = msg; g.classList.add('on');
    clearTimeout(_flashT); _flashT = setTimeout(() => g.classList.remove('on'), 1100);
  }
  const _HELP = [
    ['→  space', 'next step / slide'], ['←', 'previous'], ['⇧→  ⇧←', 'next / previous slide'],
    ['Home  End', 'first / last slide'], ['3 ⏎', 'go to slide 3'], ['a', 'autoplay'], ['p', 'pause timing'],
    ['?', 'this list'], ['b', 'black screen'], ['l', 'laser pointer'], ['d', 'draw · x clears'], ['c', 'show code'],
    ['o', 'overview'], ['t', 'rehearse timings'], ['r', 'record'], ['v', 'camera bubble'],
    ['s', 'presenter window'], ['f', 'fullscreen'], ['Esc', 'exit'],
  ];
  // Every slide as a card (number, title, first line), on its own background. Click or type a number
  // to jump; o or Esc closes.
  function deckOverview() {
    const deck = document.getElementById('deck');
    let ov = document.getElementById('deckoverview');
    if (ov) { ov.remove(); return; }
    ov = document.createElement('div'); ov.id = 'deckoverview'; ov.className = 'deck-overview';
    const cells = (nbState && nbState.cells) || [];
    const grid = document.createElement('div'); grid.className = 'deck-ov-grid';
    D.slides.forEach((sl, i) => {
      const card = document.createElement('button');
      card.className = 'deck-ov-card' + (i === D.idx ? ' on' : '');
      const bg = document.createElement('div');
      const probe = document.createElement('div');
      _paintBg(bg, probe, _effCfg(sl.cfg || {}, i));
      card.className += ' ' + probe.className;
      let sub = '';
      for (const id of sl.ids) {
        const c = cells.find(x => x.id === id); if (!c || c.kind !== 'md') continue;
        const line = (c.source || '').split('\n').map(l => l.trim()).find(l => l && !/^(#|:::|\. \. \.|[-*+] |!\[)/.test(l));
        if (line) { sub = line.replace(/[*_`]/g, ''); break; }
      }
      card.innerHTML = '<span class="n">' + (i + 1) + '</span><b></b><span class="s"></span>';
      card.prepend(bg);
      card.querySelector('b').textContent = _slideTitle(sl) || '';
      card.querySelector('.s').textContent = sub.slice(0, 90);
      card.onclick = () => { ov.remove(); _go(i, null, false); };
      grid.appendChild(card);
    });
    ov.appendChild(grid);
    deck.appendChild(ov);
    const cur = grid.children[D.idx]; if (cur) cur.scrollIntoView({ block: 'center' });
  }
  function deckHelp() {
    const h = document.getElementById('deckhelp');
    if (!h.innerHTML) {
      h.innerHTML = '<div class="deck-help-card">' +
        _HELP.map(([k, v]) => '<div><kbd>' + k + '</kbd><span>' + v + '</span></div>').join('') + '</div>';
      h.addEventListener('click', e => { if (e.target === h) h.classList.remove('on'); });
    }
    h.classList.toggle('on');
  }

  // ── Enter / exit ────────────────────────────────────────────────────────────
  function enterPresent(at) {
    if (D.open) return;
    if (typeof nbState === 'undefined' || !nbState || !nbState.cells) return;
    _buildDeckDom();
    D.slides = buildSlides();
    if (!D.slides.length) { window.alertDark ? alertDark('No slides yet — add markdown headings (## …) or tag a cell `slide`.') : alert('No slides.'); return; }
    D.open = true; D.idx = Math.max(0, Math.min(at || 0, D.slides.length - 1)); D.step = 0; D.posKey = null;
    Object.values(window.charts || {}).flat().forEach(inst => { if (inst.getDom && inst.getDom().offsetWidth) _recordNatural(inst); });
    document.body.classList.add('presenting');
    const deck = document.getElementById('deck');
    deck.style.display = '';
    deck.dataset.style = _deckStyle();
    _mountSlide(D.idx);
    _emit('enter');
    _broadcast();
  }
  // Present from the slide that holds the selected cell.
  function enterPresentHere() {
    const slides = buildSlides();
    const sel = document.querySelector('#nb .cell.selected');
    const id = sel ? sel.id.replace(/^cell-/, '') : null;
    const at = id ? Math.max(0, slides.findIndex(s => s.ids.includes(id) || s.notes.includes(id))) : 0;
    enterPresent(at);
  }
  function exitPresent() {
    if (!D.open) return;
    if (D.rehearse) deckRehearse();
    D.queue = []; D.swapPending = false; D.vt = null;
    _emit('exit');
    _unmount();
    D.open = false; D.autoplay = false; D.paused = false;
    if (D.laser) deckLaser();
    if (D.draw) deckDraw();
    document.body.classList.remove('presenting');
    const deck = document.getElementById('deck');
    if (deck) { deck.style.display = 'none'; deck.classList.remove('black-on'); }
    if (D.fs && document.exitFullscreen) { try { document.exitFullscreen(); } catch (e) {} D.fs = false; }
    if (window.typesetSoon) try { typesetSoon(document.getElementById('nb'), '__all__'); } catch (e) {}
    // `auto`, not a bare resize(): a chart the deck sized explicitly keeps that size until told to
    // measure its container again.
    requestAnimationFrame(() => Object.values(window.charts || {}).flat().forEach(inst => {
      try { inst.resize({ width: 'auto', height: 'auto' }); } catch (e) {}
    }));
  }
  function slideToggleCode() {
    D.showCode = !D.showCode;
    const s = document.querySelector('#deckstage .deck-slide');
    if (s) { s.classList.toggle('show-code', D.showCode); _relayout(s); }
  }
  function slideFullscreen() {
    const deck = document.getElementById('deck');
    if (!document.fullscreenElement) { deck.requestFullscreen && deck.requestFullscreen(); D.fs = true; }
    else { document.exitFullscreen && document.exitFullscreen(); D.fs = false; }
  }

  // ── BroadcastChannel sync (audience ⇄ presenter) ────────────────────────────
  function _broadcast() {
    if (!bc || IS_PRESENTER || !D.open) return;
    bc.postMessage({ type: 'goto', idx: D.idx, step: D.step, steps: D.total, total: D.slides.length,
                     rehearse: !!D.rehearse, autoplay: D.autoplay, from: 'deck' });
  }
  if (bc) bc.addEventListener('message', ev => {
    const m = ev.data || {};
    if (IS_PRESENTER) {
      if (m.type === 'goto') {
        Object.assign(P, { idx: m.idx, step: m.step, steps: m.steps, total: m.total, rehearse: m.rehearse, autoplay: m.autoplay });
        _renderPresenter();
      }
      return;
    }
    if (m.type === 'hello') { _broadcast(); return; }
    if (!D.open) return;
    if (m.type === 'nav') {
      if (m.dir > 0) slideNext(); else if (m.dir < 0) slidePrev();
      else if (m.idx != null) _go(m.idx, null, false);
    } else if (m.type === 'rehearse') deckRehearse();
    else if (m.type === 'autoplay') deckAutoplay();
  });
  function openPresenter() {
    const w = window.open(location.pathname + '?present=1', 'slate-presenter-' + NBID, 'width=1180,height=760');
    if (w) w.focus();
  }

  // ── Keyboard (active only while the deck or presenter is up) ─────────────────
  // Deck navigation is not in the keymap: these keys mean something only while the deck is on screen,
  // where it owns the whole window. What ENTERS the deck is the `view.present` command, so that chord
  // is configurable like every other.
  document.addEventListener('keydown', e => {
    if (IS_PRESENTER) { _presenterKey(e); return; }
    if (!D.open) return;
    const tag = (e.target && e.target.tagName) || '';
    if (/INPUT|TEXTAREA/.test(tag) || (e.target && e.target.isContentEditable)) {   // let editors type
      if (e.key === 'Escape' && tag === 'INPUT') { const t = e.target; setTimeout(() => { if (document.activeElement === t) t.blur(); }); }
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (['Shift', 'Control', 'Alt', 'Meta', 'CapsLock'].includes(e.key)) return;
    // A held key auto-repeats; for a toggle that flips it on and off many times a second. Only the
    // navigation keys repeat, which is how holding → pages through.
    if (e.repeat && !['ArrowRight', 'ArrowLeft', 'ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', ' '].includes(e.key)) { e.preventDefault(); return; }
    if (/^[0-9]$/.test(e.key)) { D.goto += e.key; _flash('go to ' + D.goto); e.preventDefault(); return; }
    if (e.key === 'Enter' && D.goto) { const n = parseInt(D.goto, 10); D.goto = ''; if (n > 0) _go(n - 1, null, false); e.preventDefault(); return; }
    D.goto = '';
    const help = document.getElementById('deckhelp');
    if (help && help.classList.contains('on') && e.key !== '?') { help.classList.remove('on'); if (e.key === 'Escape') { e.preventDefault(); return; } }
    switch (e.key) {
      case 'ArrowRight': case 'PageDown': case ' ': case 'ArrowDown':
        e.preventDefault(); if (e.shiftKey) _slideJump(1); else slideNext(); break;
      case 'ArrowLeft': case 'PageUp': case 'ArrowUp':
        e.preventDefault(); if (e.shiftKey) _slideJump(-1); else slidePrev(); break;
      case 'Home': e.preventDefault(); _go(0, -1); break;
      case 'End': e.preventDefault(); _go(D.slides.length - 1, 1); break;
      case 'Escape':
        e.preventDefault();
        if (document.getElementById('deckoverview')) deckOverview();
        else if (D.draw) deckDraw(); else if (D.laser) deckLaser(); else exitPresent();
        break;
      case 'o': case 'O': deckOverview(); break;
      case 't': case 'T': deckRehearse(); break;
      case 'f': case 'F': slideFullscreen(); break;
      case 'c': case 'C': slideToggleCode(); break;
      case 's': case 'S': openPresenter(); break;
      case 'a': case 'A': deckAutoplay(); break;
      case 'p': case 'P': _togglePause(); break;
      case 'b': case 'B': case '.': _blackout(); break;
      case 'l': case 'L': deckLaser(); break;
      case 'd': case 'D': deckDraw(); break;
      case 'x': case 'X': _inkClear(); break;
      case 'r': case 'R': if (window.deckRecordToggle) deckRecordToggle(); break;
      case 'v': case 'V': if (window.deckCameraToggle) deckCameraToggle(); break;
      case '?': deckHelp(); break;
    }
  }, true);
  addEventListener('resize', () => { if (D.open) _relayout(); });

  // ════════════════════════════════════════════════════════════════════════════
  //  Presenter window (?present=1) — live previews, notes, timer, pacing
  // ════════════════════════════════════════════════════════════════════════════
  const P = { idx: 0, step: 0, steps: 0, total: 0, started: Date.now(), rehearse: false, autoplay: false };
  function _presenterKey(e) {
    if (['ArrowRight', 'PageDown', ' ', 'ArrowDown'].includes(e.key)) { e.preventDefault(); _presenterNav(1); }
    else if (['ArrowLeft', 'PageUp', 'ArrowUp'].includes(e.key)) { e.preventDefault(); _presenterNav(-1); }
  }
  function _presenterNav(dir) { if (bc) bc.postMessage({ type: 'nav', dir }); }
  function _notesHtml(slide) {
    const cells = (nbState && nbState.cells) || [];
    let h = '';
    for (const id of (slide ? slide.notes : [])) {
      const c = cells.find(x => x.id === id);
      if (c && c.output) h += '<div class="pn-note">' + c.output + '</div>';
    }
    return h || '<div class="pv-empty">No notes for this slide.</div>';
  }
  const _mmss = secs => { const a = Math.abs(Math.round(secs)); return (secs < 0 ? '-' : '') + Math.floor(a / 60) + ':' + String(a % 60).padStart(2, '0'); };
  // Where the rehearsal says the talk should be by now: the time of every position before this one.
  function _pace(slides) {
    const t = _parseTimings(nbState && nbState.slideTimings);
    const keys = Object.keys(t);
    if (!keys.length) return null;
    const order = {}; slides.forEach((sl, i) => { if (sl.ids.length) order[sl.ids[0]] = i; });
    let before = 0, total = 0;
    for (const k of keys) {
      const [sid, st] = k.split(':'); const i = order[sid];
      if (i == null) continue;
      total += t[k];
      if (i < P.idx || (i === P.idx && +st < P.step)) before += t[k];
    }
    return { before, total };
  }
  function _renderPresenter() {
    const root = document.getElementById('presenter'); if (!root) return;
    const slides = buildSlides();
    P.total = slides.length;
    const cur = slides[P.idx];
    root.querySelector('.pp-notes').innerHTML = _notesHtml(cur);
    root.querySelector('.pp-pos').textContent = (P.idx + 1) + ' / ' + P.total;
    const st = root.querySelector('.pp-steps');
    st.innerHTML = P.steps ? Array.from({ length: P.steps }, (_, k) => '<i class="' + (k < P.step ? 'on' : '') + '"></i>').join('') : '';
    const t = P.step < P.steps ? 'step ' + (P.step + 1) + ' of ' + P.steps
            : slides[P.idx + 1] ? (_slideTitle(slides[P.idx + 1]) || 'next slide') : 'end';
    root.querySelector('.pp-nexttitle').textContent = '→ ' + t;
    _renderPreviews();
    root.querySelector('.pp-rehearse').classList.toggle('on', !!P.rehearse);
    root.querySelector('.pp-autoplay').classList.toggle('on', !!P.autoplay);
    _renderPace();
    if (window.typeset) try { window.typeset(root.querySelector('.pp-notes')); } catch (e) {}
  }
  // A cell as it looks now, for a preview: a deep copy with each chart replaced by a snapshot of its
  // canvas, since a copied chart is an empty box. Media are kept from loading or playing.
  function _snapshotCell(el) {
    const insts = _cellCharts(el);
    insts.forEach((inst, k) => { const d = inst.getDom && inst.getDom(); if (d) d.dataset.snap = k; });
    const c = el.cloneNode(true);
    c.removeAttribute('id');
    insts.forEach((inst, k) => {
      const d = inst.getDom && inst.getDom(); if (!d) return;
      delete d.dataset.snap;
      const t = c.querySelector('[data-snap="' + k + '"]'); if (!t) return;
      t.removeAttribute('data-snap'); t.classList.add('snap');
      let url = ''; try { url = inst.getDataURL({ pixelRatio: 1.5 }); } catch (e) {}
      t.innerHTML = url ? '<img alt="" src="' + url + '">' : '';
    });
    c.querySelectorAll('video, audio').forEach(m => { m.removeAttribute('data-autoplay'); m.autoplay = false; m.preload = 'metadata'; });
    return c;
  }
  // Slide `i` at step `step`, drawn into `host` the way the deck draws it.
  function _previewInto(host, i, step) {
    host.innerHTML = '';
    if (i >= D.slides.length) { host.innerHTML = '<div class="pv-end">end of deck</div>'; return; }
    const sld = D.slides[i];
    const nodes = sld.ids.map(id => document.getElementById('cell-' + id)).filter(Boolean)
      .map(el => ({ id: el.id.replace(/^cell-/, ''), el: _snapshotCell(el) }));
    const slide = _buildSlide(i, nodes);
    slide.classList.add('deck-preview');
    host.appendChild(slide);
    _sizeCanvas(slide, host.clientWidth, host.clientHeight);
    const { items } = _scanSteps(slide.querySelector('.slide-body'), sld, null);
    for (const it of items) { it.el.classList.toggle('on', it.idx <= step); it.el.classList.toggle('current', it.idx === step); }
    for (const dv of slide.querySelectorAll('.derive')) {
      let cur = dv.children[0];
      for (const c of dv.children) { const it = items.find(x => x.el === c); if (it && it.idx <= step) cur = c; }
      for (const c of dv.children) c.classList.toggle('derive-cur', c === cur);
    }
    _shrinkText(slide.querySelector('.slide-body'));
  }
  function _renderPreviews() {
    const root = document.getElementById('presenter'); if (!root) return;
    D.slides = buildSlides();
    _previewInto(root.querySelector('.pp-cur'), P.idx, P.step);
    const nx = P.step < P.steps ? [P.idx, P.step + 1] : [P.idx + 1, 0];
    _previewInto(root.querySelector('.pp-next'), nx[0], nx[1]);
  }
  // Redraw the previews when the notebook changes under them (a cell re-ran, an output arrived). A
  // chart animates into its new state, so draw again once it has settled.
  function _watchNotebook() {
    const nb = document.getElementById('nb'); if (!nb) return;
    let t1 = null, t2 = null;
    new MutationObserver(muts => {
      if (muts.every(m => m.target.closest && m.target.closest('#presenter'))) return;
      clearTimeout(t1); clearTimeout(t2);
      t1 = setTimeout(_renderPreviews, 250);
      t2 = setTimeout(_renderPreviews, 1400);
    }).observe(nb, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
    addEventListener('resize', () => _renderPreviews());
  }
  function _renderPace() {
    const root = document.getElementById('presenter'); if (!root) return;
    const el = root.querySelector('.pp-pace');
    const p = _pace(buildSlides());
    if (!p || P.rehearse) { el.textContent = P.rehearse ? 'rehearsing' : ''; el.className = 'pp-pace'; return; }
    const d = (Date.now() - P.started) / 1000 - p.before;
    el.textContent = 'plan ' + _mmss(p.total) + ' · ' + (Math.abs(d) < 15 ? 'on pace' : _mmss(Math.abs(d)) + (d > 0 ? ' behind' : ' ahead'));
    el.className = 'pp-pace ' + (d > 60 ? 'behind' : d < -60 ? 'ahead' : '');
  }
  function _buildPresenterDom() {
    document.body.classList.add('is-presenter');
    const root = document.createElement('div');
    root.id = 'presenter';
    root.innerHTML =
      '<div class="pp-main">' +
        '<div class="pp-left">' +
          '<div class="pp-frame pp-cur"></div>' +
          '<div class="pp-steps"></div>' +
        '</div>' +
        '<div class="pp-side">' +
          '<div class="pp-clock"><span class="pp-elapsed">00:00</span><button class="pp-reset" title="restart the timer">↺</button><span class="pp-wall"></span></div>' +
          '<div class="pp-pace"></div>' +
          '<div class="pp-nexthd"><span class="pp-nexttitle">→ next</span><span class="pp-pos"></span></div>' +
          '<div class="pp-frame pp-next"></div>' +
          '<div class="pp-noteshd">Speaker notes</div>' +
          '<div class="pp-notes"></div>' +
          '<div class="pp-tools"><button class="pp-rehearse" title="time every step as you rehearse">⏱ rehearse</button>' +
            '<button class="pp-autoplay" title="advance on the rehearsed timings">⏵ autoplay</button></div>' +
          '<div class="pp-nav"><button onclick="__presPrev()">‹ prev</button><button onclick="__presNext()">next ›</button></div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(root);
    window.__presPrev = () => _presenterNav(-1);
    window.__presNext = () => _presenterNav(1);
    root.querySelector('.pp-reset').onclick = () => { P.started = Date.now(); _renderPace(); };
    root.querySelector('.pp-rehearse').onclick = () => { if (!P.rehearse) P.started = Date.now(); bc && bc.postMessage({ type: 'rehearse' }); };
    root.querySelector('.pp-autoplay').onclick = () => bc && bc.postMessage({ type: 'autoplay' });
    const two = n => (n < 10 ? '0' : '') + n;
    setInterval(() => {
      const s = Math.floor((Date.now() - P.started) / 1000);
      const el = root.querySelector('.pp-elapsed'); if (el) el.textContent = two(Math.floor(s / 60)) + ':' + two(s % 60);
      const d = new Date(), w = root.querySelector('.pp-wall'); if (w) w.textContent = two(d.getHours()) + ':' + two(d.getMinutes());
      _renderPace();
    }, 1000);
  }

  // ── Bootstrap ────────────────────────────────────────────────────────────────
  function _waitForCells(cb, tries) {
    tries = tries || 0;
    if (typeof nbState !== 'undefined' && nbState && nbState.cells && document.querySelector('#nb .cell')) cb();
    else if (tries < 100) setTimeout(() => _waitForCells(cb, tries + 1), 100);
  }
  if (IS_PRESENTER) {
    document.addEventListener('DOMContentLoaded', () => _waitForCells(() => {
      _buildPresenterDom();
      _renderPresenter();
      _watchNotebook();
      if (bc) bc.postMessage({ type: 'hello' });   // ask the audience tab for its current position
    }));
  }
  // Zen / reading mode — toggle `body.zen` (CSS hides code + chrome, leaving markdown + rendered
  // output). Unlike Present (a slide deck), zen is the same scrollable page, just distraction-free.
  // Esc or the floating ✕ exits.
  // Subtle cross-fade: `display:none` chrome can't animate, so fade the notebook down, swap the mode
  // under cover of the dip, then fade back up — the chrome appears/vanishes without a jarring pop.
  let _zenAnim = null;
  function toggleZen(on) {
    const want = (on === undefined) ? !document.body.classList.contains('zen') : !!on;
    if (want === document.body.classList.contains('zen')) return;
    const nb = document.getElementById('nb');
    if (!nb) { document.body.classList.toggle('zen', want); return; }
    clearTimeout(_zenAnim);
    nb.classList.add('zen-fading');                    // → opacity 0 (CSS transition)
    _zenAnim = setTimeout(() => {
      document.body.classList.toggle('zen', want);     // swap while invisible (reflow hidden)
      requestAnimationFrame(() => nb.classList.remove('zen-fading'));   // → fade back up
    }, 180);
  }
  // …except in an APP, which wears `zen` to reuse the reading view but has no authoring mode to
  // return to: dropping it there uncovers the topbar, the add-cell affordances and the cell chrome
  // of a document the server will refuse to change. Same reason `body.app .zenexit` is hidden — this
  // is the keyboard half of that. Escape still propagates, so dismissing a panel or a completion
  // popup keeps working.
  // Same rule as the dep-focus view: an Escape that belongs to a cell editor or a control is not a
  // request to leave zen — it leaves that layer first, and the next press leaves zen.
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || (window.slateKeymap && window.slateKeymap.ownsKeyEvent(e))) return;
    if (document.body.classList.contains('zen') && !document.body.classList.contains('app')) toggleZen(false);
  });
  window.toggleZen = toggleZen;
  window.exitZen = () => toggleZen(false);

  // Exports onto the shared global scope (classic scripts) for inline handlers + palette/keys.
  window.enterPresent = enterPresent;
  window.enterPresentHere = enterPresentHere;
  window.exitPresent = exitPresent;
  window.slideNext = slideNext;
  window.slidePrev = slidePrev;
  window.slideToggleCode = slideToggleCode;
  window.slideFullscreen = slideFullscreen;
  window.openPresenter = openPresenter;
  window.deckLaser = deckLaser;
  window.deckDraw = deckDraw;
  window.deckAutoplay = deckAutoplay;
  window.deckHelp = deckHelp;
  window.deckOverview = deckOverview;
  window.deckRehearse = deckRehearse;
  window._deckSettle = _deckSettle;
  window._deckOpen = () => D.open;
  window._deckPos = () => ({ idx: D.idx, step: D.step, title: _slideTitle(D.slides[D.idx]) });
})();
