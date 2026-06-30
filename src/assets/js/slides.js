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

  function _mountSlide(i, dir) {
    _unmount();
    const stage = document.getElementById('deckstage');
    const slide = document.createElement('div');
    slide.className = 'deck-slide' + (D.showCode ? ' show-code' : '');
    const sld = D.slides[i] || { ids: [] };
    for (const id of sld.ids) {
      const el = document.getElementById('cell-' + id);
      if (!el) continue;
      D.restore.push({ el, parent: el.parentNode, next: el.nextSibling });   // remember home for exit
      slide.appendChild(el);
    }
    stage.appendChild(slide);
    // Transition: start offset/transparent, then release on the next frame.
    const cls = D.slides.length <= 1 ? '' : _transClass(dir);
    if (cls) { slide.classList.add(cls); requestAnimationFrame(() => requestAnimationFrame(() => slide.classList.remove(cls))); }
    _typesetSlide(slide);
    _fit();
    _syncHud();
  }
  function _unmount() {
    for (const r of D.restore) {
      if (r.parent && r.parent.isConnected) r.parent.insertBefore(r.el, r.next && r.next.isConnected ? r.next : null);
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
  function _typesetSlide(slide) {
    if (window.typeset) try { window.typeset(slide); } catch (e) {}
    // ECharts canvases were laid out at notebook width — resize to the slide.
    requestAnimationFrame(() => {
      for (const r of D.restore) {
        const inst = window.charts && window.charts[r.el.id.replace(/^cell-/, '')];
        if (Array.isArray(inst)) inst.forEach(ch => { try { ch.resize(); } catch (e) {} });
      }
    });
  }
  // Auto-fit: scale the slide so it fits the stage, down to a 0.5× floor (then scroll).
  function _fit() {
    const stage = document.getElementById('deckstage');
    const slide = stage && stage.firstElementChild;
    if (!slide) return;
    slide.style.transform = 'none';
    const vw = stage.clientWidth, vh = stage.clientHeight;
    const sw = slide.scrollWidth, sh = slide.scrollHeight;
    let k = Math.min(vw / sw, vh / sh, 1);
    k = Math.max(k, 0.5);
    slide.style.transform = 'scale(' + k + ')';
    slide.classList.toggle('overflow', sh * k > vh + 1);
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
    if (s) { s.classList.toggle('show-code', D.showCode); _fit(); }
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
  addEventListener('resize', () => { if (D.open) _fit(); });

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
