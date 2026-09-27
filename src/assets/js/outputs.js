// ── Collapsible long outputs + stale-count badge ──────────────────────────────
function collapseOutputs(root) {
  (root || document).querySelectorAll('.cell .output').forEach(out => {
    const nx = out.nextElementSibling;
    if (nx && nx.classList.contains('outmore')) nx.remove();
    out.classList.remove('clip');
    // Figures (plots) show in full — only clip tall *text* dumps (long arrays, dataframe
    // prints), which are the ones that actually benefit from a "show more" fold.
    const isFigure = !!out.querySelector('img, svg, canvas');
    if (!isFigure && out.scrollHeight > 480) {          // tall text output → clip + reveal toggle
      out.classList.add('clip');
      const btn = document.createElement('button'); btn.className = 'outmore'; btn.textContent = '⌄ show more';
      btn.onclick = () => { const c = out.classList.toggle('clip'); btn.textContent = c ? '⌄ show more' : '⌃ show less'; };
      out.after(btn);
    }
  });
}
// Documenter @ref cross-refs in rendered docstrings (e.g. a cell's `@doc name` output) are emitted as
// <span class="docref" data-name="sym"> (see capture.jl _fix_at_refs) — inert markup with no href. In
// the LIVE notebook a click opens the docs dock for that symbol; a static export has no handler, so the
// span is just plain text. One delegated listener on #nb covers all cells across re-renders.
(function wireDocRefs() {
  const nb = document.getElementById('nb');
  if (!nb) return;
  nb.addEventListener('click', e => {
    const d = e.target.closest('.docref');
    if (d && d.dataset.name && typeof openDocsFor === 'function') { e.preventDefault(); openDocsFor(d.dataset.name); }
  });
})();

// Links between notebooks, written the way a docs page would: `[text](other.jl)` or `other.jl#heading`,
// relative to this notebook, and `#heading` within it. A `.jl` link opens that notebook in the hub; a
// fragment scrolls to the heading whose slug matches (lowercase, non-alphanumeric runs as `-`, the
// same rule DocumenterSlate uses for the anchors it gives notebook headings). The raw attribute is
// read, not `a.href`, which the browser has already resolved against this page's URL.
function _slateHeadingSlug(s) {
  return String(s).trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-+|-+$/g, '');
}
function _slateScrollToHeading(slug) {
  if (!slug) return false;
  const want = decodeURIComponent(slug).toLowerCase();
  const h = [...document.querySelectorAll('#nb h1, #nb h2, #nb h3, #nb h4, #nb h5, #nb h6')]
    .find(el => _slateHeadingSlug(el.textContent) === want);
  if (h) h.scrollIntoView({ behavior: 'smooth', block: 'start' });
  return !!h;
}
(function wireNotebookLinks() {
  const nb = document.getElementById('nb');
  if (!nb) return;
  nb.addEventListener('click', async e => {
    const a = e.target.closest('a[href]');
    if (!a || e.metaKey || e.ctrlKey || e.shiftKey) return;
    const href = a.getAttribute('href') || '';
    if (href.startsWith('#')) {
      if (_slateScrollToHeading(href.slice(1))) e.preventDefault();
      return;
    }
    const [target, frag] = href.split('#', 2);
    if (!/\.jl$/i.test(target) || /^([a-z][a-z0-9+.-]*:|\/)/i.test(target)) return;
    e.preventDefault();
    try {
      const r = await fetch(_apipath('/api/open-link'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ href }) });
      if (!r.ok) throw new Error(await r.text());
      const j = await r.json();
      location.href = j.url + (frag ? '#' + frag : '');
    } catch (err) { console.error('slate: could not open ' + href, err); }
  });
  // Arriving at `…#heading`: the cells render after load, so watch for the heading to appear.
  const want = location.hash.slice(1);
  if (want && !_slateScrollToHeading(want)) {
    const mo = new MutationObserver(() => { if (_slateScrollToHeading(want)) mo.disconnect(); });
    mo.observe(nb, { childList: true, subtree: true });
    setTimeout(() => mo.disconnect(), 20000);
  }
})();

function updateStaleBadge(state) {
  const n = ((state && state.cells) || []).filter(c => c.kind === 'code' && (c.state === 'stale' || c.state === 'edited')).length;
  const b = document.getElementById('runstale');
  // Contextual: only when work is pending AND no run is in flight — during a run the pill shows the
  // status, and "Run stale" would be a no-op you shouldn't click, so hide it until the run settles.
  const running = typeof window._runActive === 'function' && window._runActive();
  if (b) { b.textContent = `▶ Run stale (${n})`; b.style.display = (n && !running) ? '' : 'none'; }
}

