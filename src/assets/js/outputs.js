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

function updateStaleBadge(state) {
  const n = ((state && state.cells) || []).filter(c => c.kind === 'code' && (c.state === 'stale' || c.state === 'edited')).length;
  const b = document.getElementById('runstale');
  // Contextual: only when work is pending AND no run is in flight — during a run the pill shows the
  // status, and "Run stale" would be a no-op you shouldn't click, so hide it until the run settles.
  const running = typeof window._runActive === 'function' && window._runActive();
  if (b) { b.textContent = `▶ Run stale (${n})`; b.style.display = (n && !running) ? '' : 'none'; }
}

