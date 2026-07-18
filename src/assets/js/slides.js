// Presentation / slideshow mode — turn the notebook into an interactive slide deck.
//
// Slides are segmented from the live `nbState.cells` with the SAME rules as the Julia
// `_slide_segments` (export_typst.jl): a markdown heading at depth ≤ `slideLevel` starts a
// slide, a `slide`-tagged cell starts one explicitly, a `notes`-tagged cell becomes speaker
// notes for its slide, and `collapsed` cells are skipped. (The PDF deck additionally splits a
// markdown cell on a `---` rule; the live deck keeps whole cells together so their real
// ECharts/@bind/editor nodes can be re-parented intact — split a cell if you want the break.)
//
// The deck is a fullscreen overlay. To keep everything LIVE (charts animate, @bind widgets
// work, cells stay reactive) the current slide's actual `#cell-<id>` DOM nodes are MOVED into
// the slide stage and moved back on exit — never cloned. A separate presenter window
// (`?present=1`) mirrors the position over a BroadcastChannel and shows notes + a timer.

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
  function buildSlides() {
    const cells = (typeof nbState !== 'undefined' && nbState && nbState.cells) || [];
    const level = (nbState && nbState.slideLevel) || 2;
    const slides = [];
    let cur = { ids: [], notes: [] };
    const flush = () => { if (cur.ids.length || cur.notes.length) { slides.push(cur); cur = { ids: [], notes: [] }; } };
    for (const c of cells) {
      if (c.collapsed) continue;
      if (c.notes) { cur.notes.push(c.id); continue; }
      const d = c.kind === 'md' ? _firstHeadingDepth(c.source) : null;
      const starts = c.slide || (d != null && d <= level);
      if (starts) flush();
      cur.ids.push(c.id);
    }
    flush();
    return slides;
  }
  function _slideTitle(slide) {
    const cells = (nbState && nbState.cells) || [];
    for (const id of slide.ids) {
      const c = cells.find(x => x.id === id);
      if (c && c.kind === 'md') { const m = (c.source || '').match(/^\s*#{1,6}\s+(.+?)\s*#*$/m); if (m) return m[1].trim(); }
    }
    return null;
  }

  // ── Shared deck state ───────────────────────────────────────────────────────
  const D = { open: false, idx: 0, slides: [], restore: [], showCode: false, fs: false };
  const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('slate-deck-' + NBID) : null;
  let _muteBroadcast = false;

  // ════════════════════════════════════════════════════════════════════════════
  //  Audience deck (the presenting tab)
  // ════════════════════════════════════════════════════════════════════════════
  function _buildDeckDom() {
    if (document.getElementById('deck')) return;
    const deck = document.createElement('div');
    deck.id = 'deck'; deck.className = 'deck'; deck.style.display = 'none';
    deck.innerHTML =
      '<div class="deck-stage" id="deckstage"></div>' +
      '<button class="deck-edge deck-prev" title="previous (←)" onclick="slidePrev()">‹</button>' +
      '<button class="deck-edge deck-next" title="next (→)" onclick="slideNext()">›</button>' +
      '<div class="deck-hud">' +
        '<span class="deck-progress" id="deckpos"></span>' +
        '<button title="toggle code (c)" onclick="slideToggleCode()">&lt;/&gt;</button>' +
        '<button title="presenter view (s)" onclick="openPresenter()">🪞</button>' +
        '<button title="fullscreen (f)" onclick="slideFullscreen()">⛶</button>' +
        '<button title="exit (Esc)" onclick="exitPresent()">✕</button>' +
      '</div>';
    document.body.appendChild(deck);
  }

  // Mirror of notebook.js `_cellColumn`: a `column=N` tag (N≥2) rows a cell beside its predecessor.
  function _slideCellColumn(c) {
    for (const t of (c && c.tags) || []) { const m = /^column=(\d+)$/.exec(t); if (m) return Math.max(1, parseInt(m[1], 10) || 1); }
    return 1;
  }
  function _mountSlide(i, dir) {
    _unmount();
    const stage = document.getElementById('deckstage');
    const slide = document.createElement('div');
    slide.className = 'deck-slide' + (D.showCode ? ' show-code' : '');
    const sld = D.slides[i] || { ids: [] };
    // `column=N` cells live inside a `.cell-row` flex wrapper in the notebook (see notebook.js). Moving
    // the bare cell nodes would drop that wrapper and stack them — so rebuild the row grouping here,
    // recreating `.cell-row` wrappers in the slide. The live cells still move (never clone); each one's
    // real home (its original `.cell-row` in #nb) is remembered for restore.
    const cells = (nbState && nbState.cells) || [];
    let row = null;   // the current open `.cell-row`, or null when at top level
    for (const id of sld.ids) {
      const el = document.getElementById('cell-' + id);
      if (!el) continue;
      const c = cells.find(x => x.id === id);
      const col = c ? _slideCellColumn(c) : 1;
      D.restore.push({ el, parent: el.parentNode, next: el.nextSibling });   // remember home for exit
      if (col >= 2 && row) { row.appendChild(el); continue; }                // extra column → into open row
      // A default-column cell may still anchor a row if the NEXT slide cell is column≥2.
      const j = sld.ids.indexOf(id);
      const nextC = cells.find(x => x.id === sld.ids[j + 1]);
      if (nextC && _slideCellColumn(nextC) >= 2) {
        row = document.createElement('div'); row.className = 'cell-row';
        row.appendChild(el); slide.appendChild(row);
      } else { row = null; slide.appendChild(el); }
    }
    _applySplit(slide);
    stage.appendChild(slide);
    // Transition: start offset/transparent, then release on the next frame.
    const cls = D.slides.length <= 1 ? '' : _transClass(dir);
    if (cls) { slide.classList.add(cls); requestAnimationFrame(() => requestAnimationFrame(() => slide.classList.remove(cls))); }
    _typesetSlide(slide);
    _fit();
    _syncHud();
    // Second pass once laid out: decide which splits actually FIT side-by-side (a cell whose code is
    // taller than the slide reads better stacked), box-fit charts, and re-fit the slide to real heights.
    requestAnimationFrame(() => _relayout(slide));
  }
  function _relayout(slide) {
    slide = slide || document.querySelector('#deckstage .deck-slide');
    if (!slide) return;
    _reviewSplitFit(slide);
    _fitCharts();
    _fit();
  }
  // Code-left / output-right for present mode: given the limited vertical space, a plain (non-column)
  // code cell that HAS output lays its editor beside its output instead of stacking. Tag those cells
  // `slide-split`; the CSS only splits them when code is actually shown (`.show-code`). Column-declared
  // cells (inside a `.cell-row`) already own their horizontal layout, so they're left alone. This is the
  // FIRST pass (pre-layout) so the widened width is right on first paint; `_reviewSplitFit` then measures.
  function _applySplit(slide) {
    let any = false;
    for (const el of slide.querySelectorAll(':scope > .cell.code, :scope > .cell.bind')) {
      let hasOut = false;
      el.querySelectorAll(':scope > .output, :scope > .tables, :scope > .echarts, :scope > .anim')
        .forEach(n => { if (n.childNodes.length) hasOut = true; });
      el.classList.toggle('slide-split', hasOut);
      any = any || hasOut;
    }
    // A split slide wants the wide screen: the default narrow slide would just wrap the code into a tall
    // column and then scale the whole slide down, defeating the point. Flag it so the CSS widens it.
    slide.classList.toggle('has-split', any);
  }
  // Second pass (post-layout): only KEEP a split where the code fits side-by-side. Re-tag from output
  // first (so a cell can re-split if the window grew), then unsplit any whose code column — measured at
  // the split width + present font — is taller than the slide can show; those read better stacked.
  function _reviewSplitFit(slide) {
    _applySplit(slide);
    const stage = document.getElementById('deckstage');
    const maxH = stage ? Math.max(200, stage.clientHeight - 48) : 900;
    for (const el of slide.querySelectorAll(':scope > .cell.slide-split')) {
      const src = el.querySelector(':scope > .srchost, :scope > .srcedit');
      if (D.showCode && src && src.scrollHeight > maxH) el.classList.remove('slide-split');
    }
    slide.classList.toggle('has-split', !!slide.querySelector(':scope > .cell.slide-split'));
  }
  function _unmount() {
    // Restore in REVERSE so each cell's `next` sibling is already home before we place it — that keeps
    // the anchor a real child of `parent` (preserving original order) instead of forcing an append.
    for (let i = D.restore.length - 1; i >= 0; i--) {
      const r = D.restore[i];
      // Only use `next` as the insert anchor if it's STILL a child of `parent`; a non-child reference
      // node makes insertBefore throw (the bug when sibling cells shared a slide).
      const anchor = r.next && r.next.parentNode === r.parent ? r.next : null;
      r.el.classList.remove('slide-split');   // shed present-only layout tag before it goes home
      _restoreCellCharts(r.el);                // undo present-only chart box-fit → notebook sizing
      if (r.parent && r.parent.isConnected) r.parent.insertBefore(r.el, anchor);
      else { const nb = document.getElementById('nb'); nb && nb.appendChild(r.el); }
    }
    D.restore = [];
    const stage = document.getElementById('deckstage');
    if (stage) stage.innerHTML = '';
  }
  function _transClass(dir) {
    const t = (nbState && nbState.slideTransition) || 'fade';
    if (t === 'none' || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return '';
    if (t === 'slide') return dir < 0 ? 'enter-prev' : 'enter-next';
    return 'enter-fade';
  }
  function _cellCharts(el) {
    return (window.charts && window.charts[el.id.replace(/^cell-/, '')]) || [];
  }
  // ECharts carry an explicit pixel size (core.js `_applySize`), so a bare `.resize()` keeps their fixed
  // height. For NON-split cells that's fine — the slide-level scale in `_fit` handles overflow. For a
  // slide-split cell the chart sits in a narrow output column, where a fixed square would overflow, so we
  // box-fit it: shrink to the column width AND the available slide height, preserving aspect (never
  // upscaling past its natural size). The natural + original inline sizes are captured ONCE per chart so
  // toggling code off restores the notebook sizing exactly.
  function _fitCharts() {
    const stage = document.getElementById('deckstage');
    const maxH = stage ? Math.max(160, stage.clientHeight - 48) : 600;
    for (const r of D.restore) {
      const split = r.el.classList.contains('slide-split');
      const host = split ? r.el.querySelector(':scope > .echarts') : null;
      for (const inst of _cellCharts(r.el)) {
        const dom = inst.getDom && inst.getDom(); if (!dom) continue;
        if (dom.dataset.natW == null) {                 // capture natural size before we ever constrain it
          const w = inst.getWidth(), h = inst.getHeight();
          if (w && h) { dom.dataset.natW = w; dom.dataset.natH = h; dom.dataset.origW = dom.style.width; dom.dataset.origH = dom.style.height; }
        }
        if (split && D.showCode && host && dom.dataset.natW != null) {
          const natW = +dom.dataset.natW, natH = +dom.dataset.natH;
          const availW = host.clientWidth || natW;
          const k = Math.min(availW / natW, maxH / natH, 1);
          const w = Math.round(natW * k), h = Math.round(natH * k);
          dom.style.width = w + 'px'; dom.style.height = h + 'px';
          try { inst.resize({ width: w, height: h }); } catch (e) {}
        } else if (dom.dataset.natW != null) {          // full-width slide (or code hidden) → notebook sizing
          dom.style.width = dom.dataset.origW || ''; dom.style.height = dom.dataset.origH || '';
          try { inst.resize(); } catch (e) {}
        } else { try { inst.resize(); } catch (e) {} }
      }
    }
  }
  // Drop the present-only chart sizing so a cell returns to its notebook layout on exit.
  function _restoreCellCharts(el) {
    for (const inst of _cellCharts(el)) {
      const dom = inst.getDom && inst.getDom(); if (!dom || dom.dataset.natW == null) continue;
      dom.style.width = dom.dataset.origW || ''; dom.style.height = dom.dataset.origH || '';
      delete dom.dataset.natW; delete dom.dataset.natH; delete dom.dataset.origW; delete dom.dataset.origH;
      try { inst.resize(); } catch (e) {}
    }
  }
  function _typesetSlide(slide) {
    if (window.typeset) try { window.typeset(slide); } catch (e) {}
  }
  // Auto-fit: scale a slide to fit the stage when it reasonably can; otherwise keep the text at a
  // readable size (fit width only) and let the stage scroll vertically. `transform: scale()` shrinks
  // the slide visually but NOT its layout box, so in scroll mode we pull the following extent up with a
  // negative margin (= the height the scale reclaimed) — the stage's scroll area then matches what's
  // visible, and centring-vs-top alignment is handed to the stage via the `.scrolling` class.
  // A slide that fits with only a gentle shrink just scales; once it would need to shrink past this,
  // shrinking makes the content too small to read from a distance — so keep it at a readable size and
  // scroll vertically instead. (Raised from a low floor: users would rather scroll than squint.)
  const _FIT_FLOOR = 0.85;
  function _fit() {
    const stage = document.getElementById('deckstage');
    const slide = stage && stage.firstElementChild;
    if (!slide) return;
    slide.classList.remove('overflow');
    slide.style.transform = 'none';
    slide.style.marginBottom = '';
    const vw = stage.clientWidth, vh = stage.clientHeight;
    const sw = slide.scrollWidth, sh = slide.scrollHeight;
    const fit = Math.min(vw / sw, vh / sh, 1);
    const scroll = fit < _FIT_FLOOR;                 // can't fit legibly → scroll
    const k = scroll ? Math.min(vw / sw, 1) : fit;   // scroll mode fits width only, keeps text readable
    slide.style.transformOrigin = scroll ? 'top center' : 'center center';
    slide.style.transform = 'scale(' + k + ')';
    if (scroll) slide.style.marginBottom = (-sh * (1 - k)) + 'px';  // collapse layout box to visual height
    slide.classList.toggle('overflow', scroll);
    stage.classList.toggle('scrolling', scroll);
  }
  function _syncHud() {
    const pos = document.getElementById('deckpos');
    if (pos) pos.textContent = (D.idx + 1) + ' / ' + D.slides.length;
  }

  function _go(i, dir, fromBC) {
    if (!D.open) return;
    i = Math.max(0, Math.min(i, D.slides.length - 1));
    if (i === D.idx && D.restore.length) return;
    dir = dir != null ? dir : (i > D.idx ? 1 : -1);
    D.idx = i;
    _mountSlide(i, dir);
    if (!fromBC) _broadcast();
  }
  function slideNext() { _go(D.idx + 1, 1); }
  function slidePrev() { _go(D.idx - 1, -1); }

  function enterPresent(at) {
    if (D.open) return;
    if (typeof nbState === 'undefined' || !nbState || !nbState.cells) return;
    _buildDeckDom();
    D.slides = buildSlides();
    if (!D.slides.length) { window.alertDark ? alertDark('No slides yet — add markdown headings (## …) or tag a cell `slide`.') : alert('No slides.'); return; }
    D.open = true; D.idx = Math.max(0, Math.min(at || 0, D.slides.length - 1));
    document.body.classList.add('presenting');
    document.getElementById('deck').style.display = '';
    _mountSlide(D.idx, 1);
    _broadcast();
  }
  function exitPresent() {
    if (!D.open) return;
    _unmount();
    D.open = false;
    document.body.classList.remove('presenting');
    const deck = document.getElementById('deck'); if (deck) deck.style.display = 'none';
    if (D.fs && document.exitFullscreen) { try { document.exitFullscreen(); } catch (e) {} D.fs = false; }
    // Repaint the notebook cleanly (the moved nodes are home; re-typeset math/charts).
    if (window.typesetSoon) try { typesetSoon(document.getElementById('nb'), '__all__'); } catch (e) {}
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
    if (!bc || _muteBroadcast) return;
    bc.postMessage({ type: 'goto', idx: D.idx, total: D.slides.length, from: IS_PRESENTER ? 'presenter' : 'deck' });
  }
  if (bc) bc.onmessage = ev => {
    const m = ev.data || {};
    if (m.type === 'hello') { _broadcast(); return; }            // a new window asked for the current position
    if (m.type === 'goto') {
      if (IS_PRESENTER) { P.idx = m.idx; P.total = m.total; _renderPresenter(); }
      else if (D.open && m.idx !== D.idx) { _muteBroadcast = true; _go(m.idx, null, true); _muteBroadcast = false; }
    }
  };
  function openPresenter() {
    const w = window.open(location.pathname + '?present=1', 'slate-presenter-' + NBID, 'width=1100,height=720');
    if (w) w.focus();
  }

  // ── Keyboard (active only while the deck or presenter is up) ─────────────────
  document.addEventListener('keydown', e => {
    if (IS_PRESENTER) { _presenterKey(e); return; }
    if (!D.open) {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === 'P' || e.key === 'p')) { e.preventDefault(); enterPresent(); }
      return;
    }
    const tag = (e.target && e.target.tagName) || '';
    if (/INPUT|TEXTAREA/.test(tag) || (e.target && e.target.isContentEditable)) return;  // let editors type
    switch (e.key) {
      case 'ArrowRight': case 'PageDown': case ' ': e.preventDefault(); slideNext(); break;
      case 'ArrowLeft': case 'PageUp': e.preventDefault(); slidePrev(); break;
      case 'Home': e.preventDefault(); _go(0, -1); break;
      case 'End': e.preventDefault(); _go(D.slides.length - 1, 1); break;
      case 'Escape': e.preventDefault(); exitPresent(); break;
      case 'f': case 'F': slideFullscreen(); break;
      case 'c': case 'C': slideToggleCode(); break;
      case 's': case 'S': openPresenter(); break;
    }
  }, true);
  addEventListener('resize', () => { if (D.open) _relayout(); });

  // ════════════════════════════════════════════════════════════════════════════
  //  Presenter window (?present=1) — mirrors position, shows notes + next + timer
  // ════════════════════════════════════════════════════════════════════════════
  const P = { idx: 0, total: 0, started: Date.now() };
  function _presenterKey(e) {
    if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ') { e.preventDefault(); _presenterGo(1); }
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); _presenterGo(-1); }
  }
  function _presenterGo(d) { P.idx = Math.max(0, Math.min(P.idx + d, P.total - 1)); _renderPresenter(); _broadcast(); }
  function _slidePreviewHtml(slide) {
    if (!slide) return '<div class="pv-empty">—</div>';
    let h = '';
    for (const id of slide.ids) {
      const el = document.getElementById('cell-' + id);
      if (el) { const c = el.cloneNode(true); c.removeAttribute('id'); h += c.outerHTML; }
    }
    return h || '<div class="pv-empty">—</div>';
  }
  function _notesHtml(slide) {
    const cells = (nbState && nbState.cells) || [];
    let h = '';
    for (const id of (slide ? slide.notes : [])) {
      const c = cells.find(x => x.id === id);
      if (c && c.output) h += '<div class="pn-note">' + c.output + '</div>';
    }
    return h || '<div class="pv-empty">No notes for this slide.</div>';
  }
  function _renderPresenter() {
    const root = document.getElementById('presenter'); if (!root) return;
    const slides = buildSlides();
    P.total = slides.length;
    const cur = slides[P.idx], nxt = slides[P.idx + 1];
    root.querySelector('.pp-cur').innerHTML = _slidePreviewHtml(cur);
    root.querySelector('.pp-next').innerHTML = _slidePreviewHtml(nxt);
    root.querySelector('.pp-notes').innerHTML = _notesHtml(cur);
    root.querySelector('.pp-pos').textContent = (P.idx + 1) + ' / ' + P.total;
    const t = slides[P.idx + 1] ? (_slideTitle(slides[P.idx + 1]) || 'next') : 'end';
    root.querySelector('.pp-nexttitle').textContent = '→ ' + t;
    if (window.typeset) try { window.typeset(root); } catch (e) {}
  }
  function _buildPresenterDom() {
    document.body.classList.add('is-presenter');
    const root = document.createElement('div');
    root.id = 'presenter';
    root.innerHTML =
      '<div class="pp-main">' +
        '<div class="pp-stage pp-cur"></div>' +
        '<div class="pp-side">' +
          '<div class="pp-clock"><span class="pp-elapsed">00:00</span><span class="pp-wall"></span></div>' +
          '<div class="pp-nexthd"><span class="pp-nexttitle">→ next</span><span class="pp-pos"></span></div>' +
          '<div class="pp-stage pp-next"></div>' +
          '<div class="pp-noteshd">Speaker notes</div>' +
          '<div class="pp-notes"></div>' +
          '<div class="pp-nav"><button onclick="__presPrev()">‹ prev</button><button onclick="__presNext()">next ›</button></div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(root);
    window.__presPrev = () => _presenterGo(-1);
    window.__presNext = () => _presenterGo(1);
    const two = n => (n < 10 ? '0' : '') + n;
    setInterval(() => {
      const s = Math.floor((Date.now() - P.started) / 1000);
      const el = root.querySelector('.pp-elapsed'); if (el) el.textContent = two(Math.floor(s / 60)) + ':' + two(s % 60);
      const d = new Date(), w = root.querySelector('.pp-wall'); if (w) w.textContent = two(d.getHours()) + ':' + two(d.getMinutes());
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
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && document.body.classList.contains('zen')) toggleZen(false);
  });
  window.toggleZen = toggleZen;
  window.exitZen = () => toggleZen(false);

  // Exports onto the shared global scope (classic scripts) for inline handlers + palette/keys.
  window.enterPresent = enterPresent;
  window.exitPresent = exitPresent;
  window.slideNext = slideNext;
  window.slidePrev = slidePrev;
  window.slideToggleCode = slideToggleCode;
  window.slideFullscreen = slideFullscreen;
  window.openPresenter = openPresenter;
  window._deckOpen = () => D.open;
})();
