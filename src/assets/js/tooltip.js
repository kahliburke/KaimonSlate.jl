// A styled tooltip that stands in for the browser's native `title`. The native one waits out a
// delay the page cannot shorten, restarts that delay on the smallest pointer movement, and shows
// nothing at all when the target is a few pixels wide inside a strip that only fades in on hover,
// which describes every button in a cell header. The first time the pointer reaches an element
// carrying a `title`, this reads the text, moves it to `data-tip` so the native tooltip stops
// competing, mirrors it to `aria-label` for screen readers, and shows one shared popover after a
// short, fixed delay.
//
// The listeners are delegated from `document`, so a single wiring covers every `title` on the page,
// including the ones Preact renders after load, with nothing to attach per button.

(() => {
  const SHOW_DELAY = 180;    // ms the pointer rests on a fresh target before the tip appears
  const WARM_DELAY = 40;     // ms once a tip was just visible, so a neighboring control reads fast
  const WARM_WINDOW = 400;   // ms after a tip hides during which the next one counts as a neighbor
  const GAP = 8;             // px between the control and the tip
  const MARGIN = 6;          // px kept clear of every viewport edge
  const MAX_WIDTH = 320;     // px, the widest the tip grows before its text wraps

  let tip = null;            // the shared popover, created on first use
  let showTimer = 0;
  let armedFor = null;       // the element a pending timer belongs to
  let current = null;        // the element the visible tip belongs to
  let lastHidden = 0;        // when the tip last went away, for the warm path

  const el = () => {
    if (tip) return tip;
    tip = document.createElement('div');
    tip.className = 'uitip';
    tip.setAttribute('role', 'tooltip');
    document.body.appendChild(tip);
    return tip;
  };

  // Take a native `title` out of the element and keep the words in `data-tip`. An element whose
  // `title` changes later (the trace button rewords itself when tracing turns on) is promoted
  // again on the next hover, so the newest text wins. Returns the text to show, or an empty string.
  const tipText = (node) => {
    const t = node.getAttribute('title');
    if (t != null && t !== '') {
      node.setAttribute('data-tip', t);
      if (!node.getAttribute('aria-label')) node.setAttribute('aria-label', t);
      node.removeAttribute('title');
    }
    return node.getAttribute('data-tip') || '';
  };

  const place = (node) => {
    const t = el();
    t.style.maxWidth = Math.min(MAX_WIDTH, window.innerWidth - 2 * MARGIN) + 'px';
    const r = node.getBoundingClientRect();
    const w = t.offsetWidth, h = t.offsetHeight;
    let top = r.bottom + GAP;
    if (top + h + MARGIN > window.innerHeight) top = r.top - GAP - h;   // flip above when it would spill
    top = Math.max(MARGIN, Math.min(top, window.innerHeight - h - MARGIN));
    let left = r.left + r.width / 2 - w / 2;
    left = Math.max(MARGIN, Math.min(left, window.innerWidth - w - MARGIN));
    t.style.top = Math.round(top) + 'px';
    t.style.left = Math.round(left) + 'px';
  };

  const show = (node, text) => {
    const t = el();
    t.textContent = text;
    place(node);           // position while still transparent, so the fade has nowhere to jump from
    t.classList.add('on');
    current = node;
    armedFor = null;
  };

  const hide = () => {
    if (showTimer) { clearTimeout(showTimer); showTimer = 0; }
    armedFor = null;
    if (current || (tip && tip.classList.contains('on'))) lastHidden = performance.now();
    current = null;
    if (tip) tip.classList.remove('on');
  };

  // One handler drives both arming and dismissal: entering a titled control arms the timer, and
  // entering anything else (a gap, a panel, the page) clears it. The tip never receives events of
  // its own, because it is `pointer-events:none`.
  document.addEventListener('mouseover', (e) => {
    let start = e.target;
    if (!(start instanceof Element)) start = start && start.parentElement;
    const node = start && start.closest('[title],[data-tip]');
    if (!node) { hide(); return; }
    if (node === current || node === armedFor) return;
    const text = tipText(node);
    if (!text) { hide(); return; }
    if (showTimer) clearTimeout(showTimer);
    armedFor = node;
    // A tip already up, or one just dismissed, means the reader is moving among controls: show the
    // next one at once rather than making them wait out the cold delay over each button.
    const warm = current !== null || performance.now() - lastHidden < WARM_WINDOW;
    showTimer = setTimeout(() => { showTimer = 0; show(node, text); }, warm ? WARM_DELAY : SHOW_DELAY);
  });

  // A tip pinned to a control that scrolls away, is clicked, or loses the window goes stale, so
  // drop it on any of these rather than let it linger over the wrong place.
  document.addEventListener('mouseleave', hide);
  addEventListener('scroll', hide, true);
  addEventListener('mousedown', hide, true);
  addEventListener('keydown', hide, true);
  addEventListener('wheel', hide, { capture: true, passive: true });
  addEventListener('resize', hide);
  addEventListener('blur', hide);
})();
