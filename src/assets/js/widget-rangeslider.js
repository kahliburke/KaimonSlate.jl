// ── RangeSlider: a slider with two thumbs ────────────────────────────────────────────────────────
//
// HTML has no two-thumb range input, so this is two `<input type=range>` stacked on one track with
// a highlighted span between them. That construction is deliberate over drawing thumbs by hand:
// each thumb stays a real range input, so it is focusable, arrow-key steppable, and announced by a
// screen reader as the slider it is — none of which a div with pointer handlers gets for free.
//
// Registered through the public `slateRegisterWidget` seam, like FileUpload: it has a composite UI
// and a readout, which is more than view.js's one-<input> built-in chain is for.

(function () {
  const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  // Decimals to show, derived from the step — a step of 0.05 wants two, a step of 10 wants none.
  function precision(step) {
    const s = String(step);
    const dot = s.indexOf('.');
    return dot < 0 ? 0 : Math.min(4, s.length - dot - 1);
  }

  window.slateRegisterWidget('rangeslider', {
    wire(el, api) {
      const p = api.params || {};
      const min = Number(p.min != null ? p.min : 0);
      const max = Number(p.max != null ? p.max : 100);
      const step = Number(p.step != null ? p.step : 1) || 1;
      const dp = precision(step);
      const v0 = Array.isArray(api.value) && api.value.length === 2 ? api.value : [min, max];

      el.innerHTML =
        `<span class="rsbox">
           <span class="rstrack"><span class="rsfill"></span></span>
           <input class="rsin rslo" type="range" min="${min}" max="${max}" step="${step}" value="${v0[0]}"
                  aria-label="lower bound"/>
           <input class="rsin rshi" type="range" min="${min}" max="${max}" step="${step}" value="${v0[1]}"
                  aria-label="upper bound"/>
         </span><span class="rsval"></span>`;

      const loEl = el.querySelector('.rslo'), hiEl = el.querySelector('.rshi');
      const fill = el.querySelector('.rsfill'), out = el.querySelector('.rsval');

      const read = () => {
        // Whichever thumb the reader dragged, the PAIR is sorted before it leaves here — so the
        // two ends can be dragged past each other without the value ever being inverted. The
        // thumbs swap roles instead of the interval going negative, which is what the gesture
        // means and what a hard stop at the other thumb would prevent.
        const a = Number(loEl.value), b = Number(hiEl.value);
        return a <= b ? [a, b] : [b, a];
      };

      const paint = () => {
        const [a, b] = read();
        const span = (max - min) || 1;
        fill.style.left = ((a - min) / span * 100) + '%';
        fill.style.right = (100 - (b - min) / span * 100) + '%';
        out.textContent = a.toFixed(dp) + ' – ' + b.toFixed(dp);
        // The thumb nearer the pointer must be the one on top, or the pair sticks once both are
        // at the same end of the track and the lower input covers the upper one.
        const mid = (min + max) / 2;
        loEl.style.zIndex = a > mid ? 4 : 3;
        hiEl.style.zIndex = a > mid ? 3 : 4;
      };

      // Dragging streams through the throttled `schedule` (one recompute per updateMs, coalesced);
      // releasing flushes the final value. Same policy as the built-in slider, so a range that
      // drives an expensive cell behaves the way readers already expect a slider to.
      const live = () => { paint(); api.schedule(read()); };
      const done = () => { paint(); api.flush(read()); };
      for (const inp of [loEl, hiEl]) {
        inp.addEventListener('input', live);
        inp.addEventListener('change', done);
      }
      el._rsPaint = paint;
      el._rsSet = v => {
        if (!Array.isArray(v) || v.length !== 2) return;
        loEl.value = v[0]; hiEl.value = v[1]; paint();
      };
      paint();
    },

    sync(el, value) { el._rsSet && el._rsSet(value); },
  });
})();
