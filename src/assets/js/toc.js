// Table of Contents — a navigable outline built from the markdown cells' headings. Toggle via the
// top-bar 📑 button, the ⌘K palette ("Table of contents"), or the `o` command-mode key. Headings are
// parsed from each markdown cell's source (ATX `#`…`######`, fenced code skipped); clicking an entry
// scrolls to that exact heading. Indentation by level reads as a section/subsection tree.
let _tocOpen = false;
const _tocEsc = s => String(s).replace(/[&<>"]/g, x => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[x]));

// Every heading across the notebook, in document order. `hi` is the heading's index WITHIN its cell
// (source order) — it lines up 1:1 with the rendered <h1..h6> elements, so we can scroll to the right
// one even when a cell has several.
function _tocHeadings() {
  const out = [];
  for (const c of ((typeof nbState !== 'undefined' && nbState && nbState.cells) || [])) {
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
}

function _tocJump(cell, hi) {
  const el = document.getElementById('cell-' + cell);
  if (!el) return;
  const heads = el.querySelectorAll('.md h1, .md h2, .md h3, .md h4, .md h5, .md h6');
  const target = heads[hi] || el;
  if (typeof selectCell === 'function') selectCell(cell, false);
  const top = window.scrollY + target.getBoundingClientRect().top - 64;   // clear the sticky topbar
  window.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
  // briefly highlight the destination heading
  target.classList.add('toc-hit');
  setTimeout(() => target.classList.remove('toc-hit'), 1400);
}

function renderTOC() {
  const body = document.getElementById('toclist'); if (!body) return;
  const hs = _tocHeadings();
  if (!hs.length) { body.innerHTML = '<div class="tocempty">No headings yet.<br><span>Add markdown cells with <code>#</code> / <code>##</code> headings.</span></div>'; return; }
  const minLvl = Math.min(...hs.map(h => h.level));
  body.innerHTML = hs.map(h => {
    const d = h.level - minLvl;
    return `<div class="tocitem lvl${d}" style="padding-left:${d * 14 + 12}px" data-cell="${_tocEsc(h.cell)}" data-hi="${h.hi}" title="${_tocEsc(h.text)}">${_tocEsc(h.text)}</div>`;
  }).join('');
}
window.renderTOC = renderTOC;

function toggleTOC() {
  _tocOpen = !_tocOpen;
  window._tocOpen = _tocOpen;
  const p = document.getElementById('tocpanel');
  if (p) p.classList.toggle('open', _tocOpen);
  if (_tocOpen) renderTOC();
}
function closeTOC() { if (_tocOpen) toggleTOC(); }
window.toggleTOC = toggleTOC;
window.closeTOC = closeTOC;

document.addEventListener('DOMContentLoaded', () => {
  const list = document.getElementById('toclist');
  if (list) list.addEventListener('click', e => {
    const it = e.target.closest('.tocitem');
    if (it) _tocJump(it.dataset.cell, +it.dataset.hi);
  });
  _navSyncButtons();
});

// ── Selected-cell navigation history (⌘⇧← / ⌘⇧→ and the TOC ◀ ▶ buttons) ──────────
// A browser-style back/forward stack of the cells you've selected. selectCell() records here;
// back/forward move a pointer without re-recording (the _navLock guard). Stale ids (deleted cells)
// are skipped over.
let _nav = [], _navPos = -1, _navLock = false;
window._navRecord = function (id) {
  if (_navLock || !id || _nav[_navPos] === id) return;
  _nav = _nav.slice(0, _navPos + 1);
  _nav.push(id); _navPos = _nav.length - 1;
  if (_nav.length > 200) { _nav.shift(); _navPos--; }
  _navSyncButtons();
};
function _navGo(dir) {
  const ids = (typeof cellIds === 'function') ? cellIds() : [];
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
