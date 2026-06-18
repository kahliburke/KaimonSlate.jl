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
function updateStaleBadge(state) {
  const n = ((state && state.cells) || []).filter(c => c.kind === 'code' && (c.state === 'stale' || c.state === 'edited')).length;
  const b = document.getElementById('runstale');
  if (b) { b.textContent = `▶ Run stale (${n})`; b.style.display = n ? '' : 'none'; }   // contextual: only when work is pending
}

