
// ── Drag-to-host: arrange controls into cells' strips ─────────────────────────
// Update one or more cells' `controls=` lists (the caller sends each affected
// cell's *full desired* list). `hostControl` moves a control to a cell at an
// index (removing it from any prior host); `unhostControl` removes it everywhere.
const _cellById = id => ((nbState && nbState.cells) || []).find(c => c.id === id);
// A cell's control layout as columns of names (deep copy, safe to mutate).
const columnsOf = id => { const c = _cellById(id); return ((c && c.controls) || []).map(col => col.map(s => s.name)); };

// Place `name` into cell `targetId` per a drop `target` ({newCol, colIndex,
// rowIndex}). A control may live in multiple cells: from the palette (`fromCell`
// null) it *copies*; dragging an existing grip (`fromCell` set) *moves* it. Within
// a cell a name stays unique (so dropping where it already is reorders/re-columns).
// Server drops any empty columns left behind, so we don't prune here.
async function hostControl(name, targetId, target, fromCell) {
  const map = {};
  if (fromCell && fromCell !== targetId) map[fromCell] = columnsOf(fromCell).map(c => c.filter(n => n !== name));
  const orig = columnsOf(targetId);
  let row = target.rowIndex;                          // correct for self-removal shift within the target column
  if (!target.newCol) {
    const r0 = (orig[target.colIndex] || []).indexOf(name);
    if (r0 !== -1 && r0 < (row ?? Infinity)) row = (row ?? (orig[target.colIndex] || []).length) - 1;
  }
  const cols = orig.map(c => c.filter(n => n !== name));   // remove dragged occurrence(s) in target
  if (target.newCol) {
    cols.splice(target.colIndex == null ? cols.length : target.colIndex, 0, [name]);
  } else {
    const col = cols[target.colIndex] || (cols[target.colIndex] = []);
    col.splice(row == null || row > col.length ? col.length : row, 0, name);
  }
  map[targetId] = cols;
  renderAll(await api('POST', '/api/controls', { map }));
}
// Remove just this instance (the control in cell `cellId`); other hosts remain.
async function unhostControl(name, cellId) {
  if (!cellId) return;
  renderAll(await api('POST', '/api/controls', { map: { [cellId]: columnsOf(cellId).map(c => c.filter(n => n !== name)) } }));
}
// The header 🎛 button opens a picker (checkbox list) of the @bind controls that AFFECT this
// cell — `transBinduses`: the cell's direct binduses plus those of every cell in its upstream
// dependency cone (so a downstream plot can host a control whose value reaches it indirectly).
// Check/uncheck to surface/hide each in the cell's control strip; All / None for the whole set.
function openControlPicker(id, ev) {
  if (ev) ev.stopPropagation();
  const c = _cellById(id), { aff, other } = pickerNames(c);   // affecting (own + read) first, then every other @bind
  if (!aff.length && !other.length) return;
  const present = new Set([].concat(...columnsOf(id)));
  const pop = document.getElementById('ctlpop');
  pop.dataset.cell = id;
  const row = n => `<label class="ctlrow"><input type="checkbox" data-n="${_escc(n)}"${present.has(n) ? ' checked' : ''}>` +
                   `<span>${_escc(n)}</span></label>`;
  pop.innerHTML =
    '<div class="ctlhead">Controls<span class="ctlquick">' +
      '<button data-all="1">All</button><button data-all="0">None</button></span></div>' +
    aff.map(row).join('') +
    (other.length ? '<div class="ctlsub">other controls</div>' + other.map(row).join('') : '');
  pop.querySelectorAll('input[type=checkbox]').forEach(cb => cb.onchange = applyControlPicker);
  pop.querySelectorAll('.ctlquick button').forEach(b => b.onclick = () => {
    pop.querySelectorAll('input[type=checkbox]').forEach(cb => cb.checked = b.dataset.all === '1');
    applyControlPicker();
  });
  // Anchor below-right of the 🎛 button (clamped to the viewport).
  const r = (ev && ev.currentTarget ? ev.currentTarget : document.querySelector(`#cell-${id} .autoctl`)).getBoundingClientRect();
  pop.classList.add('show');
  const w = pop.offsetWidth, h = pop.offsetHeight;
  pop.style.left = Math.max(8, Math.min(r.right - w, window.innerWidth - w - 8)) + 'px';
  pop.style.top = Math.min(r.bottom + 5, window.innerHeight - h - 8) + 'px';
}
// Build the cell's control columns from the picker's checked set: drop unchecked *affecting*
// names, keep any other (manually-placed) controls, append newly-checked ones as a new column.
// #ctlpop lives outside #nb, so it survives renderAll and stays open for multiple toggles.
async function applyControlPicker() {
  const pop = document.getElementById('ctlpop'), id = pop.dataset.cell;
  const sel = new Set([...pop.querySelectorAll('input[type=checkbox]:checked')].map(cb => cb.dataset.n));
  const bu = new Set(pickerNames(_cellById(id)).all);   // every name the picker offered is removable when unchecked
  let cols = columnsOf(id).map(col => col.filter(n => sel.has(n) || !bu.has(n))).filter(col => col.length);
  const present = new Set([].concat(...cols));
  const toAdd = [...sel].filter(n => !present.has(n));
  if (toAdd.length) cols.push(toAdd);
  renderAll(await api('POST', '/api/controls', { map: { [id]: cols } }));
}
function hideControlPicker() { document.getElementById('ctlpop').classList.remove('show'); }

// ── Cell tag editor (🏷) ────────────────────────────────────────────────────────────────────────
// The `#%%` header isn't editable in the browser, so tags are set here: known behaviour tags as
// checkboxes + free-form custom tags as chips. Each change POSTs the full tag set to /api/tags/<id>.
// #tagpop lives outside #nb so it survives renderAll and stays open across edits.
// Behaviour tags, grouped and scoped to the cell kinds they actually do something on (a code cell
// never offers `title`; an md cell never offers `resource`). [group, tag, description, kinds].
const TAG_DEFS = [
  ['Caching & execution', 'cache',    'always persist — restore until an input changes', ['code']],
  ['Caching & execution', 'nocache',  'never cache (impure / side-effecting)', ['code']],
  ['Caching & execution', 'resource', 'external handle (DB / file) — re-inits each run, but keeps everything downstream cacheable', ['code']],
  ['Caching & execution', 'trace',    'inspect every value (re-runs the cell)', ['code']],
  ['Display',  'collapsed', 'fold the whole cell', ['code', 'md']],
  ['Display',  'hidecode',  'hide the editor — show output only', ['code']],
  ['Document', 'title',       'the document title (front matter)', ['md']],
  ['Document', 'abstract',    'the document abstract / summary', ['md']],
  ['Document', 'caption',     'figure caption for the output above', ['md']],
  ['Document', 'bibliography','render the reference list here', ['md']],
  ['Site',     'home',     "this notebook is the published site's front page", ['md']],
  ['Site',     'docindex', 'where the document listing is injected', ['md']],
  ['Slides',   'slide', 'start a new slide here', ['code', 'md']],
  ['Slides',   'notes', 'speaker notes (presenter-only)', ['code', 'md']],
];
function _curTags(id) { const c = _cellById(id); return (c && c.tags) ? c.tags.slice() : []; }
function _tagKind(id) { const c = _cellById(id); return (c && c.kind === 'md') ? 'md' : 'code'; }
function _knownTagSet() { return new Set(TAG_DEFS.map(d => d[1])); }

function renderTagPop(pop, id) {
  const tags = new Set(_curTags(id)), known = _knownTagSet(), kind = _tagKind(id);
  // Region tags (`remote` / `region=…`) are owned by the "Run on" radio above, and `needs=` edges by
  // the DAG — don't also show them as free-form chips (applyTagChecks preserves them either way).
  const custom = _curTags(id).filter(t => !known.has(t) && t !== 'remote'
                 && !t.startsWith('region=') && !t.startsWith('needs='));
  const row = (n, desc) =>
    `<label class="ctlrow tagrow"><input type="checkbox" data-tag="${n}"${tags.has(n) ? ' checked' : ''}>` +
    `<span><span class="tagname">${n}</span><span class="tagdesc">${_escc(desc)}</span></span></label>`;
  // Group the kind-relevant tags under their section subheads, in definition order.
  let groups = '', lastGroup = null;
  for (const [group, tag, desc, kinds] of TAG_DEFS) {
    if (!kinds.includes(kind)) continue;
    if (group !== lastGroup) { groups += `<div class="ctlsub">${group}</div>`; lastGroup = group; }
    groups += row(tag, desc);
  }
  pop.innerHTML =
    runOnSectionHtml(id) +
    groups +
    '<div class="ctlsub">Custom</div>' +
    '<div class="tagchips">' +
      (custom.length ? custom.map(t => `<span class="tagchip">${_escc(t)}<button data-del="${_escc(t)}" title="remove">×</button></span>`).join('')
                     : '<span class="tagnone">none</span>') +
    '</div>' +
    '<div class="tagadd"><input type="text" class="taginput" placeholder="add custom tag…" maxlength="40"><button class="tagaddbtn">add</button></div>';
  wireRunOnSection(pop, id);
  pop.querySelectorAll('input[data-tag]').forEach(cb => cb.onchange = () => applyTagChecks(id));
  pop.querySelectorAll('.tagchip button').forEach(b => b.onclick = () => setTags(id, _curTags(id).filter(x => x !== b.dataset.del)));
  const inp = pop.querySelector('.taginput'), add = pop.querySelector('.tagaddbtn');
  const doAdd = () => { const v = inp.value.trim(); if (v) setTags(id, [...new Set([..._curTags(id), v])]); };
  add.onclick = doAdd;
  inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); doAdd(); } };
}
function applyTagChecks(id) {
  const pop = document.getElementById('tagpop');
  const boxes = [...pop.querySelectorAll('input[data-tag]')];
  const shown = new Set(boxes.map(cb => cb.dataset.tag));       // tags with a checkbox right now (kind-scoped)
  const checked = boxes.filter(cb => cb.checked).map(cb => cb.dataset.tag);
  // Preserve everything NOT currently shown — custom chips, region/needs, and any known tag hidden
  // by the cell-kind filter — so toggling a visible box never silently drops an off-screen tag.
  const preserved = _curTags(id).filter(t => !shown.has(t));
  setTags(id, [...new Set([...checked, ...preserved])]);
}
async function setTags(id, tags) {
  renderAll(await api('POST', '/api/tags/' + id, { tags }));
  const pop = document.getElementById('tagpop');
  if (pop.dataset.cell === id && pop.classList.contains('show')) renderTagPop(pop, id);   // refresh from new state
}
function openTagEditor(id, ev) {
  if (ev) ev.stopPropagation();
  const pop = document.getElementById('tagpop');
  pop.dataset.cell = id;
  renderTagPop(pop, id);
  const anchor = (ev && ev.currentTarget) ? ev.currentTarget : document.querySelector(`#cell-${id} .tagbtn`);
  const r = anchor.getBoundingClientRect();
  pop.classList.add('show');
  const w = pop.offsetWidth, h = pop.offsetHeight;
  pop.style.left = Math.max(8, Math.min(r.right - w, window.innerWidth - w - 8)) + 'px';
  pop.style.top = Math.min(r.bottom + 5, window.innerHeight - h - 8) + 'px';
}
function hideTagEditor() { document.getElementById('tagpop').classList.remove('show'); }
document.addEventListener('mousedown', e => {
  if (!e.target.closest('#tagpop') && !e.target.closest('.tagbtn')) hideTagEditor();
});
// Fold / unfold a cell. Persisted in the .jl (header `collapsed` token) so it travels with the
// notebook; the server returns fresh state and renderAll reflects it.
// Flip a behavior flag (collapsed / hidecode / trace / …) on one or many cells via the unified
// /api/cell-flag route — one persist / one history entry. `cells` omitted ⇒ every applicable cell.
const _setCellFlag = (flag, value, cells) =>
  api('POST', '/api/cell-flag', cells ? { flag, value, cells } : { flag, value });

async function toggleCollapse(id) {
  const c = _cellById(id);
  renderAll(await _setCellFlag('collapsed', !(c && c.collapsed), [id]));
}
// Hide / show a code cell's editor (output stays visible). Persisted in the .jl (`hidecode` token).
async function toggleHideCode(id) {
  const c = _cellById(id);
  renderAll(await _setCellFlag('hidecode', !(c && c.codeHidden), [id]));
}
// 🔍 value tracing for a code cell. Persisted in the .jl (`trace` token). The cell keeps its
// NORMAL output; the trace rows show in the inspector popup. If already tracing, clicking just
// (re)opens the popup; otherwise it turns tracing on (server re-runs, collecting rows) and opens
// it. Turn it off from the popup's "Stop tracing" button (stopTraceModal).
async function toggleTrace(id) {
  const c = _cellById(id);
  if (c && c.trace) { if (typeof openTraceModal === 'function') openTraceModal(id); return; }
  renderAll(await _setCellFlag('trace', true, [id]));
  if (typeof openTraceModal === 'function')
    requestAnimationFrame(() => requestAnimationFrame(() => openTraceModal(id)));
}
// Does this code cell render a plot? An ECharts spec, or a figure (img/svg/canvas) in its output.
function _cellHasPlot(c) {
  if (!c || c.kind !== 'code') return false;
  if (Array.isArray(c.echarts) && c.echarts.length) return true;
  const el = document.getElementById('cell-' + c.id), out = el && el.querySelector('.output');
  return !!(out && out.querySelector('img, svg, canvas'));
}
// Bulk hide/show the code of every PLOT cell at once (command palette) — one call, one history entry.
async function hideAllPlotCode(hidden) {
  const cells = ((nbState && nbState.cells) || []).filter(_cellHasPlot).map(c => c.id);
  renderAll(await _setCellFlag('hidecode', hidden, cells));
}
// Bulk hide/show the code of EVERY code cell at once (command palette) — one call, one history entry.
async function hideAllCode(hidden) {
  renderAll(await _setCellFlag('hidecode', hidden));
}
// Insertion row within a column element, by cursor y (before the first control
// whose midpoint is below the cursor; else at the end).
function rowInCol(col, y) {
  const items = [...col.querySelectorAll('.control')];
  for (let j = 0; j < items.length; j++) {
    const r = items[j].getBoundingClientRect();
    if (y < r.top + r.height / 2) return j;
  }
  return items.length;
}
// Resolve the drop element under the cursor to a layout target. A `.coldrop` →
// new column at its index; a `.ccol` → into that column at a row; otherwise append
// a new column at the end.
function dropTargetFor(el, cell, y) {
  const dz = el.closest('.coldrop');
  if (dz) return { newCol: true, colIndex: +dz.dataset.colindex };
  const col = el.closest('.ccol');
  if (col) return { newCol: false, colIndex: +col.dataset.colindex, rowIndex: rowInCol(col, y) };
  return { newCol: true, colIndex: columnsOf(cell.dataset.cid).length };
}

// Drag-to-reorder cells (⠿ handle) AND drag-to-host controls (palette chip / strip
// grip) share these handlers. `dragId` = a cell being reordered; `ctrlDrag` = a
// control name being hosted. Only ⠿/grip/chip are draggable, so editor text and
// sliders stay interactive.
// ctrlDrag = { name, fromCell } — fromCell null when sourced from the palette
// (copy), or the cell id when dragging an existing strip control's grip (move).
let dragId = null, dropTarget = null, ctrlDrag = null;
const nbEl = document.getElementById('nb');
// A single purple insertion line, floated in the gap where the cell will land.
let dropline = null;
function _dropline() {
  if (!dropline) { dropline = document.createElement('div'); dropline.className = 'dropline'; }
  if (!dropline.isConnected) nbEl.appendChild(dropline);   // renderAll wipes #nb — re-attach
  return dropline;
}
function clearDrop() { if (dropline) dropline.style.display = 'none'; }
function clearCtrlDrop() { nbEl.querySelectorAll('.cdrop, .cdup').forEach(x => x.classList.remove('cdrop', 'cdup')); }
function startControlDrag(e, name, fromCell) {
  ctrlDrag = { name, fromCell: fromCell || null };
  e.dataTransfer.effectAllowed = 'copyMove';   // allow either dropEffect, so duplicate (move) drops aren't rejected
  try { e.dataTransfer.setData('text/plain', name); } catch (_) {}
  // Reveal drop-zones on the NEXT tick: toggling `cdnd` now reflows the strip the
  // grip lives in, and a source element that moves during `dragstart` makes Chrome
  // abort the drag. Deferring lets the drag lock in first.
  setTimeout(() => { if (ctrlDrag) document.body.classList.add('cdnd'); }, 0);
}
nbEl.addEventListener('dragstart', e => {
  const grip = e.target.closest('.cgrip');
  if (grip) { startControlDrag(e, grip.dataset.name, grip.closest('.cell').dataset.cid); return; }  // existing → move
  const h = e.target.closest('.drag');
  if (!h) { e.preventDefault(); return; }
  dragId = h.closest('.cell').dataset.cid;
  e.dataTransfer.effectAllowed = 'move';
  // Open a droppable gap below the last cell so "drag past everything → drop at the very end" lands
  // (the area below #nb is otherwise outside the drop target). Deferred a tick like the control-drag
  // class above, so the reflow can't make Chrome cancel the drag.
  setTimeout(() => { if (dragId) document.body.classList.add('celldnd'); }, 0);
});
nbEl.addEventListener('dragover', e => {
  if (ctrlDrag) {                                  // hosting a control
    clearCtrlDrop();
    const cell = e.target.closest('.cell.code');
    if (!cell) return;
    e.preventDefault();
    // If this cell already hosts the control, dropping just repositions it (no
    // duplicate) — flag the existing instance so that's visible, and signal "move".
    const dup = cell.querySelector('.control[data-cname="' + ctrlDrag.name + '"]');
    e.dataTransfer.dropEffect = (ctrlDrag.fromCell || dup) ? 'move' : 'copy';
    if (dup) dup.classList.add('cdup');
    const dz = e.target.closest('.coldrop'), col = e.target.closest('.ccol');
    if (dz) dz.classList.add('cdrop');
    else if (col) col.classList.add('cdrop');
    else { const last = cell.querySelector('.controls .coldrop:last-child'); if (last) last.classList.add('cdrop'); }
    return;
  }
  e.preventDefault();                              // reordering a cell
  if (!dragId) { clearDrop(); dropTarget = null; return; }
  // Pick the insertion point by cursor Y across all cells, so releasing in the
  // gap (right on the drop line) still lands — not only when over a cell.
  let target = null, before = true;
  for (const c of nbEl.querySelectorAll('.cell')) {
    if (c.dataset.cid === dragId) continue;
    const r = c.getBoundingClientRect();
    if (e.clientY < r.top + r.height / 2) { target = c; before = true; break; }
    target = c; before = false;                    // past this cell's midpoint → after it
  }
  if (!target) { clearDrop(); dropTarget = null; return; }
  const dl = _dropline();                                  // float the line mid-gap, above or below the target
  dl.style.top = ((before ? target.offsetTop - 7 : target.offsetTop + target.offsetHeight + 7) - 1) + 'px';
  dl.style.display = 'block';
  dropTarget = { id: target.dataset.cid, before };
});
nbEl.addEventListener('drop', e => {
  e.preventDefault();
  if (ctrlDrag) {
    const cell = e.target.closest('.cell.code'), { name, fromCell } = ctrlDrag, el = e.target;
    ctrlDrag = null; document.body.classList.remove('cdnd'); clearCtrlDrop();
    if (cell) hostControl(name, cell.dataset.cid, dropTargetFor(el, cell, e.clientY), fromCell);
    return;
  }
  clearDrop();
  const dt = dropTarget, id = dragId;
  dragId = dropTarget = null;
  if (dt && id) moveCellRel(id, dt.id, dt.before);
});
nbEl.addEventListener('dragend', () => { clearDrop(); clearCtrlDrop(); dragId = dropTarget = ctrlDrag = null; document.body.classList.remove('cdnd'); document.body.classList.remove('celldnd'); });
// ✕ on a strip control → remove this instance (other hosts, if any, remain).
nbEl.addEventListener('click', e => {
  const del = e.target.closest('.cdel');
  if (del) { e.stopPropagation(); unhostControl(del.dataset.name, del.closest('.cell').dataset.cid); }
});

// ⌘Z / ⌘⇧Z notebook undo/redo — but defer to CodeMirror's text undo when an editor is focused.
document.addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && (e.key === 'z' || e.key === 'Z')) {
    if (document.activeElement && document.activeElement.closest('.cm-editor')) return;
    e.preventDefault();
    e.shiftKey ? redoNb() : undoNb();
  }
});

// (Live-update debounce now lives in the Settings modal — see openSettings.)

// Palette chips: click → jump to defining cell; drag → host into a cell's strip.
const paletteList = document.getElementById('palette-list');
paletteList.onclick = e => {
  const ch = e.target.closest('.chip'); if (!ch) return;
  const el = document.getElementById('cell-' + ch.dataset.def);
  if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); editSource(ch.dataset.def, 'julia'); }
};
paletteList.addEventListener('dragstart', e => {
  const chip = e.target.closest('.chip'); if (!chip) return;
  startControlDrag(e, chip.dataset.pname);
});
// Drag a control out of a strip and drop it on the palette to remove that instance.
paletteList.addEventListener('dragover', e => { if (ctrlDrag && ctrlDrag.fromCell) { e.preventDefault(); paletteList.classList.add('premove'); } });
paletteList.addEventListener('dragleave', e => { if (!paletteList.contains(e.relatedTarget)) paletteList.classList.remove('premove'); });
paletteList.addEventListener('drop', e => {
  if (!ctrlDrag || !ctrlDrag.fromCell) return;
  e.preventDefault();
  const { name, fromCell } = ctrlDrag;
  ctrlDrag = null; document.body.classList.remove('cdnd'); paletteList.classList.remove('premove'); clearCtrlDrop();
  unhostControl(name, fromCell);
});
// A control drag can end outside the notebook (e.g. palette-sourced) — clear here.
document.addEventListener('dragend', () => {
  if (ctrlDrag !== null) { ctrlDrag = null; document.body.classList.remove('cdnd'); clearCtrlDrop(); }
});

if (localStorage.getItem('slateFullWidth') === '1') document.body.classList.add('fullwidth');
if (localStorage.getItem('slateWrapOutput') === '1') document.body.classList.add('wrap-output');   // opt-in: wrap wide output

// Persist & restore scroll position + selected cell per notebook, so a reload lands you back where
// you were instead of snapping to the top. Keyed on the notebook's path.
const _posKey = () => 'slatePos:' + location.pathname;
let _posT = 0;
// Anchor to the cell sitting at the top of the viewport + its pixel offset — robust to layout
// differences between save and restore (lazy editors / async images), unlike a raw scrollY.
function _topAnchor() {
  let best = null, bestTop = -Infinity;
  for (const el of document.querySelectorAll('.cell')) {
    const t = el.getBoundingClientRect().top;
    if (t <= 8 && t > bestTop) { best = el; bestTop = t; }   // last cell whose top is at/above the fold
  }
  if (!best) { best = document.querySelector('.cell'); bestTop = best ? best.getBoundingClientRect().top : 0; }
  return best ? { id: best.dataset.cid, off: Math.round(bestTop) } : null;
}
function _savePos() {
  try { localStorage.setItem(_posKey(), JSON.stringify({ y: Math.round(window.scrollY), sel: window.selectedId || null, anchor: _topAnchor() })); } catch (_) {}
}
addEventListener('scroll', () => { clearTimeout(_posT); _posT = setTimeout(_savePos, 200); }, { passive: true });
addEventListener('pagehide', _savePos);                                                       // fires on reload/unload
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') _savePos(); });
function _restorePos() {
  let p; try { p = JSON.parse(localStorage.getItem(_posKey()) || 'null'); } catch (_) { return; }
  if (!p) return;
  if (p.sel && typeof selectCell === 'function' && cellIds().includes(p.sel)) selectCell(p.sel, false);   // select, don't scroll
  const apply = () => {
    if (p.anchor && p.anchor.id) {
      const el = document.getElementById('cell-' + p.anchor.id);
      if (el) { window.scrollTo(0, Math.max(0, window.scrollY + el.getBoundingClientRect().top - (p.anchor.off || 0))); return; }
    }
    if (typeof p.y === 'number') window.scrollTo(0, p.y);
  };
  // Scroll, then typeset the now-visible cells synchronously (before paint) so their deferred math
  // doesn't render late and shift, then re-apply to correct for the height the math added.
  apply(); window.typesetInView && window.typesetInView(); apply();
  setTimeout(() => { window.typesetInView && window.typesetInView(); apply(); }, 350);   // settle async content
}

// Restore position once the first render has laid the cells out (two frames: applyState → Preact commit).
reload().then(() => requestAnimationFrame(() => requestAnimationFrame(_restorePos)));
// Replay the buffered agent conversation first, then start live SSE — so a live
// event can't be wiped by the replay's clear.
loadAgentLog().finally(connectLive);

