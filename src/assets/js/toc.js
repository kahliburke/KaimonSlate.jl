// Table of Contents — a navigable outline built from the markdown cells' headings. Toggle via the
// top-bar 📑 button, the ⌘⇧L palette entry, or the `o` command-mode key.
//
// FIRST fully-migrated island (Preact + signals, ESM — imported by app.js, no longer a classic
// <script>). The list is a component DERIVED from the `cells` signal in store.js, so it re-renders
// reactively on any edit with no manual renderTOC() plumbing. What stays imperative — because it
// owns no reactive rendering — is panel open/close, the layout-measuring scroll-spy, and the
// selected-cell nav-history; their entry points remain on `window` for the classic scripts (palette,
// keyboard, the editor keymap, inline onclick=) that still call them.
import { html, render } from 'htm/preact';
import { useEffect } from 'preact/hooks';
import { computed } from '@preact/signals';
import { cells } from './store.js';

// Every heading across the notebook, in document order — derived from the cell signal, so it stays
// current automatically. `hi` is the heading's index WITHIN its cell (source order); it lines up 1:1
// with the rendered <h1..h6> elements, so we can scroll to the right one even when a cell has several.
const headings = computed(() => {
  const out = [];
  for (const c of cells.value) {
    if (c.kind !== 'md' || typeof c.source !== 'string') continue;
    let inFence = false, hi = 0;
    for (const ln of c.source.split('\n')) {
      if (/^\s*(```|~~~)/.test(ln)) { inFence = !inFence; continue; }
      if (inFence) continue;
      const m = ln.match(/^(#{1,6})\s+(.+?)\s*#*$/);
      if (m) out.push({ level: m[1].length, text: m[2].trim(), cell: c.id, hi: hi++ });
    }
  }
  return out;
});

let _tocOpen = false;
window._tocOpen = false;

function _tocJump(cell, hi) {
  const el = document.getElementById('cell-' + cell);
  if (!el) return;
  const heads = el.querySelectorAll('.md h1, .md h2, .md h3, .md h4, .md h5, .md h6');
  const target = heads[hi] || el;
  if (typeof window.selectCell === 'function') window.selectCell(cell, false);
  const top = window.scrollY + target.getBoundingClientRect().top - 64;   // clear the sticky topbar
  window.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
  target.classList.add('toc-hit');                                        // briefly highlight the destination
  setTimeout(() => target.classList.remove('toc-hit'), 1400);
}

function TocList() {
  const hs = headings.value;                 // subscribe → re-render whenever a cell's markdown changes
  useEffect(() => { _tocSpy(); });           // after each render, refresh the scroll-spy highlight
  if (!hs.length) {
    return html`<div class="tocempty">No headings yet.<br/><span>Add markdown cells with <code>#</code> / <code>##</code> headings.</span></div>`;
  }
  const minLvl = Math.min(...hs.map(h => h.level));
  // Interpolation-only template = a fragment of rows (the codebase convention — see notebook.js;
  // this htm build has no `<>` shorthand, which would emit an empty-tag element).
  return html`${hs.map(h => {
    const d = h.level - minLvl;
    return html`<div class="tocitem lvl${d}" style=${'padding-left:' + (d * 14 + 12) + 'px'}
                     data-cell=${h.cell} data-hi=${h.hi} title=${h.text}
                     onClick=${() => _tocJump(h.cell, h.hi)}>${h.text}</div>`;
  })}`;
}

// Scroll-spy: highlight the section currently at the top of the viewport. Purely imperative — it reads
// the rendered layout (getBoundingClientRect) and toggles `.active` on the DOM the component rendered.
// The active class is re-applied by the render effect above, so edits don't lose it.
let _spyTick = 0;
function _tocSpy() {
  if (!_tocOpen) return;
  const items = document.querySelectorAll('#toclist .tocitem');
  let active = null, bestTop = -Infinity;
  for (const it of items) {
    const cellEl = document.getElementById('cell-' + it.dataset.cell);
    if (!cellEl) continue;
    const h = cellEl.querySelectorAll('.md h1,.md h2,.md h3,.md h4,.md h5,.md h6')[+it.dataset.hi];
    if (!h) continue;
    const top = h.getBoundingClientRect().top;
    if (top <= 90 && top > bestTop) { bestTop = top; active = it; }   // nearest heading above the fold
  }
  if (!active && items.length) active = items[0];   // scrolled above the first heading → first section
  for (const it of items) it.classList.toggle('active', it === active);
  if (active) active.scrollIntoView({ block: 'nearest' });
}
addEventListener('scroll', () => {
  if (_tocOpen && !_spyTick) _spyTick = requestAnimationFrame(() => { _spyTick = 0; _tocSpy(); });
}, { passive: true });

function toggleTOC() {
  _tocOpen = !_tocOpen;
  window._tocOpen = _tocOpen;
  const p = document.getElementById('tocpanel');
  if (p) p.classList.toggle('open', _tocOpen);
  document.body.classList.toggle('toc-open', _tocOpen);   // shift the notebook column right (no overlap)
  if (_tocOpen) _tocSpy();                  // list is already live (reactive) — just sync the highlight
}
function closeTOC() { if (_tocOpen) toggleTOC(); }
window.toggleTOC = toggleTOC;
window.closeTOC = closeTOC;
// Compat shim: classic notebook.js calls window.renderTOC() on edits. The list is reactive now, so
// this only needs to refresh the scroll-spy highlight.
window.renderTOC = () => { if (_tocOpen) _tocSpy(); };

// ── Selected-cell navigation history (⌘⇧← / ⌘⇧→ and the TOC ◀ ▶ buttons) ──────────
// A browser-style back/forward stack of the cells you've selected. selectCell() records here;
// back/forward move a pointer without re-recording (the _navLock guard). Stale ids (deleted cells)
// are skipped over. Unchanged by the migration — imperative state, exposed on window for classic
// callers (core.js selectCell, the editor keymap, the palette, the panel's inline onclick).
let _nav = [], _navPos = -1, _navLock = false;
window._navRecord = function (id) {
  if (_navLock || !id || _nav[_navPos] === id) return;
  _nav = _nav.slice(0, _navPos + 1);
  _nav.push(id); _navPos = _nav.length - 1;
  if (_nav.length > 200) { _nav.shift(); _navPos--; }
  _navSyncButtons();
};
function _navGo(dir) {
  const ids = (typeof window.cellIds === 'function') ? window.cellIds() : [];
  let p = _navPos + dir;
  while (p >= 0 && p < _nav.length && ids.length && !ids.includes(_nav[p])) p += dir;   // skip deleted cells
  if (p < 0 || p >= _nav.length) return;
  _navPos = p; _navLock = true;
  try { window.selectCell && window.selectCell(_nav[p], true); } finally { _navLock = false; }
  _navSyncButtons();
}
window.navBack = () => _navGo(-1);
window.navFwd = () => _navGo(1);
function _navSyncButtons() {
  const b = document.getElementById('tocback'), f = document.getElementById('tocfwd');
  if (b) b.disabled = _navPos <= 0;
  if (f) f.disabled = _navPos >= _nav.length - 1;
}

// Mount the reactive list into its container (the panel chrome — nav buttons, close — stays classic).
const _host = document.getElementById('toclist');
if (_host) render(html`<${TocList} />`, _host);
_navSyncButtons();
