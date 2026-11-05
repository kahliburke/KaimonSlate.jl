// ── Image zoom ──────────────────────────────────────────────────────────────────
// Zoom and pan for image outputs (`.disp.img`: a CairoMakie PNG or SVG, or any other image/* display).
// Clicking a figure makes it active, as with a chart under the scroll-zoom gate (settings.js): the
// wheel then zooms around the cursor, a drag pans, and a double-click toggles between fit and a close
// look. An inactive figure leaves the wheel to the page. The corner button opens the image in a
// full-window view with the same controls.
//
// Self-contained, styles included, so a static export inlines this file unchanged. `slateImageView(src)`
// opens the full-window view for any image source.
(function () {
  if (window.slateImageView) return;

  const MAX = 16;                                   // times the fitted size
  const STEP = 1.5;                                 // a button or key press
  const CLOSE = 3;                                  // where a double-click on a fitted image goes

  const css = `
.izframe{position:relative;display:inline-block;width:fit-content;max-width:100%;overflow:hidden;line-height:0;
  vertical-align:top;border-radius:4px;outline:none;touch-action:none}
.izframe>img{transform-origin:0 0;cursor:zoom-in;user-select:none;-webkit-user-drag:none}
.izframe:focus-within{box-shadow:0 0 0 2px var(--accent,#7aa2f7)}
.izframe.izzoomed>img{cursor:grab}
.izframe.izdrag>img{cursor:grabbing}
.izbtn{position:absolute;display:flex;align-items:center;justify-content:center;height:24px;min-width:24px;padding:0 6px;
  border:0;border-radius:5px;background:#000a;color:#fff;font:12px/1 system-ui,sans-serif;cursor:pointer;
  opacity:0;transition:opacity .2s}
.izbtn:hover{background:#000d}
/* the buttons fade in only while the pointer is over the figure (or a keyboard has focused one of them) */
.izframe:hover .izbtn,.izbtn:focus-visible{opacity:1}
.izexp{top:6px;right:6px}
.izpct{bottom:6px;left:6px;cursor:default}
.izframe:not(.izzoomed) .izpct{display:none}
.izview{position:fixed;inset:0;z-index:2000;display:flex;align-items:center;justify-content:center;
  background:#000d;outline:none}
.izview .izframe{box-shadow:0 8px 40px #000a;max-width:none}
.izview .izframe:focus-within{box-shadow:0 8px 40px #000a}
.izview .izframe>img{max-width:96vw;max-height:90vh;display:block;cursor:zoom-in}
.izview .izframe.izzoomed>img{cursor:grab}
.izview .izframe.izdrag>img{cursor:grabbing}
.izbar{position:fixed;top:12px;right:14px;display:flex;gap:6px;z-index:2001}
.izbar button{height:30px;min-width:30px;padding:0 10px;border:0;border-radius:6px;background:#fff2;color:#fff;
  font:13px/1 system-ui,sans-serif;cursor:pointer}
.izbar button:hover{background:#fff4}
.izbar .izlvl{min-width:62px}
`;
  const style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);

  // The settings' "Chart scroll-zoom" strength where the page has it; 0 turns wheel zoom off.
  const wheelFactor = () => (typeof window.scrollZoomFactor === 'function' ? window.scrollZoomFactor() : 0.28);

  // One zoomable frame: a box the size of the fitted image, clipping the scaled image. A gated frame
  // takes the wheel only while it holds focus; the full-window view's always does.
  function Zoom(frame, img, onChange, gated = true) {
    let s = 1, tx = 0, ty = 0;
    const size = () => [frame.clientWidth, frame.clientHeight];
    function apply() {
      const [w, h] = size();
      s = Math.min(MAX, Math.max(1, s));
      tx = Math.min(0, Math.max(w - w * s, tx));
      ty = Math.min(0, Math.max(h - h * s, ty));
      img.style.transform = s === 1 ? '' : `translate(${tx}px,${ty}px) scale(${s})`;
      frame.classList.toggle('izzoomed', s > 1);
      onChange && onChange(s);
    }
    // Scale by `k` keeping the point (px, py) of the frame where it is.
    function zoomAt(k, px, py) {
      const ns = Math.min(MAX, Math.max(1, s * k));
      tx = px - (px - tx) * (ns / s);
      ty = py - (py - ty) * (ns / s);
      s = ns;
      apply();
    }
    const center = k => { const [w, h] = size(); zoomAt(k, w / 2, h / 2); };
    const reset = () => { s = 1; tx = 0; ty = 0; apply(); };
    const local = e => { const r = frame.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };

    frame.addEventListener('wheel', e => {
      if (gated && !frame.matches(':focus-within')) return;  // inactive: the page scrolls
      const f = gated ? wheelFactor() : (wheelFactor() || 0.28);
      if (f <= 0) return;
      e.preventDefault(); e.stopPropagation();
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
      const [px, py] = local(e);
      zoomAt(Math.exp(-e.deltaY * unit * f * 0.01), px, py);
    }, { passive: false });

    // Drag pans a zoomed image. A press that does not move is a click, which the caller may want.
    let drag = null;
    img.draggable = false;
    img.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      frame.focus({ preventScroll: true });
      if (s === 1) return;
      drag = { id: e.pointerId, x: e.clientX, y: e.clientY, tx, ty, moved: false };
      img.setPointerCapture(e.pointerId);
      frame.classList.add('izdrag');
      e.preventDefault();
    });
    img.addEventListener('pointermove', e => {
      if (!drag || e.pointerId !== drag.id) return;
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true;
      tx = drag.tx + dx; ty = drag.ty + dy;
      apply();
    });
    const end = e => {
      if (!drag || e.pointerId !== drag.id) return;
      frame.classList.remove('izdrag');
      frame._izDragged = drag.moved;
      drag = null;
    };
    img.addEventListener('pointerup', end);
    img.addEventListener('pointercancel', end);
    img.addEventListener('dblclick', e => {
      e.preventDefault();
      if (s > 1) return reset();
      const [px, py] = local(e);
      zoomAt(CLOSE, px, py);
    });
    // Moving on from the figure ends the look: its ring and its zoom go. A press elsewhere is not
    // always a focus change — the notebook's own handlers can keep focus where it was — so a press
    // outside counts as leaving (see the listener below), and so does focus moving on by keyboard.
    // Switching to another window is not leaving: the figure has focus again on return.
    if (gated) {
      frame._izLeave = () => {
        reset();
        if (frame.contains(document.activeElement)) document.activeElement.blur();
      };
      frame.addEventListener('focusout', () => setTimeout(() => {
        if (s > 1 && document.hasFocus() && !frame.contains(document.activeElement)) reset();
      }, 0));
    }
    // A resize changes the fitted size the offsets are measured against.
    if (window.ResizeObserver) new ResizeObserver(() => s > 1 && apply()).observe(frame);
    return { zoomIn: () => center(STEP), zoomOut: () => center(1 / STEP), reset,
             to: k => center(k / s), scale: () => s };
  }

  const pct = s => Math.round(s * 100) + '%';

  // Give an output image its frame, corner button and zoom on first contact.
  function wire(img) {
    if (img._iz || !img.closest('.disp.img') || img.closest('.izview, .scout')) return;   // a scratch thumbnail opens the view on click
    const frame = document.createElement('span');
    frame.className = 'izframe';
    frame.tabIndex = -1;
    // The frame takes the image's place in the layout: block or inline, centred or not, as it was.
    const cs = getComputedStyle(img);
    const ml = parseFloat(cs.marginLeft) || 0, mr = parseFloat(cs.marginRight) || 0;
    frame.style.display = cs.display === 'block' ? 'block' : 'inline-block';
    if (cs.display === 'block' && ml > 0 && Math.abs(ml - mr) < 1) frame.style.marginInline = 'auto';
    // The image's width cap moves to the frame, which sizes to its content: left on the image, a cap
    // the frame cannot see would make the frame the full column and the image sit at its left edge.
    frame.style.maxWidth = cs.maxWidth === 'none' ? '100%' : cs.maxWidth;
    img.style.maxWidth = '100%';
    img.style.margin = '0';
    img.parentNode.insertBefore(frame, img);
    frame.appendChild(img);
    const exp = document.createElement('button');
    exp.className = 'izbtn izexp'; exp.type = 'button'; exp.title = 'Open full size'; exp.textContent = '⤢';
    exp.addEventListener('click', e => {
      e.stopPropagation();
      open(img.currentSrc || img.src, img.alt, img.hasAttribute('data-vector') || undefined);
    });
    const lvl = document.createElement('span');
    lvl.className = 'izbtn izpct';
    frame.append(exp, lvl);
    img._iz = Zoom(frame, img, s => { lvl.textContent = pct(s); });
  }
  document.addEventListener('pointerover', e => {
    const img = e.target && e.target.closest ? e.target.closest('.disp.img img') : null;
    img && wire(img);
  }, true);
  // A press outside an active or zoomed figure leaves it. Capture phase, so a handler that stops the
  // event further down cannot keep the figure active. The full-window view is not "outside".
  document.addEventListener('pointerdown', e => {
    const t = e.target;
    if (t && t.closest && t.closest('.izview')) return;
    for (const f of document.querySelectorAll('.izframe.izzoomed, .izframe:focus-within')) {
      if (f._izLeave && !f.contains(t)) f._izLeave();
    }
  }, true);

  // ── Full-window view ──
  let view = null, vz = null;
  function close() {
    if (!view) return;
    view._cleanup && view._cleanup();
    const back = view._back;
    view.remove(); view = null; vz = null;
    back && back.focus && back.focus({ preventScroll: true });
  }
  // `vector` (default: an SVG data URL) fits the image to the window, scaling up as well as down;
  // a raster opens at its natural size, capped to the window.
  function open(src, alt, vector = /^data:image\/svg\+xml/.test(src)) {
    close();
    view = document.createElement('div');
    view.className = 'izview';
    view.tabIndex = -1;
    view.setAttribute('role', 'dialog');
    view.setAttribute('aria-label', 'Image');
    view.setAttribute('data-slate-keys', '');            // the notebook's command keys stay out (keymap.js)
    view._back = document.activeElement;
    view.innerHTML = '<span class="izframe" tabindex="-1"><img alt=""></span>' +
      '<div class="izbar"><button type="button" data-a="out" title="Zoom out (−)">−</button>' +
      '<button type="button" class="izlvl" data-a="fit" title="Fit (0)">100%</button>' +
      '<button type="button" data-a="in" title="Zoom in (+)">+</button>' +
      '<button type="button" data-a="one" title="Actual pixels (1)">1:1</button>' +
      '<button type="button" data-a="close" title="Close (Esc)">✕</button></div>';
    const frame = view.querySelector('.izframe'), img = frame.querySelector('img');
    const lvl = view.querySelector('.izlvl');
    img.alt = alt || '';
    img.src = src;
    if (vector) {
      const fit = () => {
        const w = img.naturalWidth, h = img.naturalHeight;
        if (!w || !h) return;
        img.style.width = Math.floor(w * Math.min(innerWidth * 0.96 / w, innerHeight * 0.9 / h)) + 'px';
      };
      img.complete ? fit() : img.addEventListener('load', fit, { once: true });
      window.addEventListener('resize', fit);
      view._cleanup = () => window.removeEventListener('resize', fit);
    }
    document.body.appendChild(view);
    vz = Zoom(frame, img, s => { lvl.textContent = pct(s); }, false);
    // The view is always active: a wheel anywhere on it zooms the image.
    view.addEventListener('wheel', e => {
      if (frame.contains(e.target)) return;
      e.preventDefault();
      frame.dispatchEvent(new WheelEvent('wheel', e));
    }, { passive: false });
    const actualPixels = () => img.naturalWidth && img.clientWidth && vz.to(img.naturalWidth / img.clientWidth);
    view.querySelector('.izbar').addEventListener('click', e => {
      const a = e.target.closest('button'); if (!a) return;
      e.stopPropagation();
      ({ out: vz.zoomOut, in: vz.zoomIn, fit: vz.reset, one: actualPixels, close })[a.dataset.a]();
    });
    // A click on the backdrop closes; one on the image does not, nor the end of a drag.
    view.addEventListener('click', e => {
      if (frame._izDragged) { frame._izDragged = false; return; }
      if (!frame.contains(e.target)) close();
    });
    view.addEventListener('keydown', e => {
      const k = e.key;
      const act = k === 'Escape' ? close : (k === '+' || k === '=') ? vz.zoomIn : k === '-' ? vz.zoomOut :
                  k === '0' ? vz.reset : k === '1' ? actualPixels : null;
      if (!act) return;
      e.preventDefault(); e.stopPropagation();
      act();
    });
    frame.focus({ preventScroll: true });
  }
  window.slateImageView = open;
})();
