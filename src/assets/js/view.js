// Inner markup for one bound control. `bindId` is the *defining* bind cell's id
// (the /api/bind POST target); `b` is its spec ({name,widget,params,value}). Used
// by both the standalone @bind cell and any cell's control strip — wherever a
// widget renders, changing it drives recompute the same way.
const _esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const _showVal = v => Array.isArray(v) ? v.join(', ') : v;
// Order-independent key for a control's value — used by the stale-echo guard so an in-flight
// server echo (which may reorder a multi-select) can't reset a control the user just changed.
const _valKey = v => Array.isArray(v) ? JSON.stringify([...v].map(String).sort()) : String(v);
// The text shown in a widget's value mirror (`.wval`). A toggle with on/off labels shows the
// active state's word; a button shows its click count; everything else shows the raw value. Reads
// the on/off text from the input's data- attributes so the local + server-sync paths agree.
function _ctrlValLabel(el, v) {
  const w = el.dataset.widget;
  if (w === 'button') return '×' + v;
  if (w === 'toggle' && (el.dataset.on != null || el.dataset.off != null))
    return v ? (el.dataset.on != null ? el.dataset.on : 'on') : (el.dataset.off != null ? el.dataset.off : 'off');
  return _showVal(v);
}

// ── Custom widget registry (extension point) ─────────────────────────────────
// Third-party packages register a widget KIND's front-end here, so a widget can
// live ENTIRELY OUTSIDE core. Core emits a generic empty container for any kind it
// doesn't recognise (see controlMarkup) and delegates the live behaviour to the
// registered impl:
//   slateRegisterWidget('mathfield', {
//     wire(el, api) { /* build DOM inside el; on change, api.push(value) */ },
//     sync(el, value, params) { /* reflect a server-pushed value (optional) */ },
//     destroy(el) { /* free resources before el is discarded (optional) */ },
//   });
// `api` = { push, schedule, flush, value, name, bindId, params, mirror }. `value` is the current
// value at wire time (build from it; `sync` delivers later reactive updates). `push`/`flush` send
// the value immediately; `schedule` is throttled/coalesced (same policy as built-ins). `destroy` is
// called before a rebuild orphans the element, so a widget holding resources can clean up.
window.slateWidgets = window.slateWidgets || {};
window.slateRegisterWidget = function (kind, impl) {
  const im = impl || {};
  window.slateWidgets[String(kind)] = im;
  // Registration can land AFTER the control mounted (e.g. an async import): wire any instances
  // already in the DOM that haven't been wired yet, THEN push their current value so an
  // async-registered widget restores its state immediately (the mount-time sync already ran with
  // no impl to receive it).
  document.querySelectorAll('[data-bind][data-widget="' + String(kind) + '"]').forEach(el => {
    try {
      if (!el._customWired) wireControl(el);
      if (im.sync) { const bs = _bindSpec(el.dataset.bind, el.dataset.name); if (bs) im.sync(el, bs.value, bs.params || {}); }
    } catch (e) { console.error(e); }
  });
};
// Tear down any custom widgets under `root` before their DOM is discarded (a bind/control-strip
// rebuild). Mirrors the inline-echart dispose before an innerHTML swap — a plugin holding resources
// (a math field, global listeners, observers) gets a `destroy(el)` call to clean up. No-op for a
// widget with no destroy impl, or one that never wired.
window.teardownCustomWidgets = function (root) {
  if (!root) return;
  root.querySelectorAll('.customwidget[data-bind]').forEach(el => {
    if (!el._customWired) return;
    const impl = window.slateWidgets[el.dataset.widget];
    if (impl && impl.destroy) { try { impl.destroy(el); } catch (e) { console.error(e); } }
  });
};

function controlMarkup(bindId, b) {
  const p = b.params || {}, w = b.widget;
  const a = `data-bind="${bindId}" data-name="${b.name}" data-widget="${w}"`;
  // Options are {value,label} (a bare value normalizes to value===label). The browser carries the
  // stringified VALUE in each option's `value` attr; the LABEL is what's shown (rich for radio).
  const opts = (p.options || []).map(o => (o && typeof o === 'object') ? o : { value: o, label: String(o) });
  const _selV = String(b.value);
  let ctrl = '', wval = `<span class="wval">${_esc(_showVal(b.value))}</span>`;
  if (w === 'slider')
    ctrl = `<input type="range" min="${p.min}" max="${p.max}" step="${p.step}" value="${b.value}" ${a}/>`;
  else if (w === 'number')
    ctrl = `<input type="number" value="${b.value}" ${p.min != null ? `min="${p.min}"` : ''} ${p.max != null ? `max="${p.max}"` : ''} ${a}/>`;
  else if (w === 'checkbox' || w === 'toggle') {
    // A toggle with on/off labels carries them as data- attributes (so the value mirror can show
    // the active word) and seeds its `.wval` with the current state's label.
    const da = (w === 'toggle' && (p.on != null || p.off != null))
      ? ` data-on="${_esc(p.on != null ? p.on : 'on')}" data-off="${_esc(p.off != null ? p.off : 'off')}"` : '';
    ctrl = `<input type="checkbox" class="${w}" ${b.value ? 'checked' : ''} ${a}${da}/>`;
    if (da) wval = `<span class="wval">${_esc(b.value ? (p.on != null ? p.on : 'on') : (p.off != null ? p.off : 'off'))}</span>`;
  }
  else if (w === 'text')
    ctrl = `<input type="text" value="${_esc(b.value)}" ${a}/>`;
  else if (w === 'textarea')
    ctrl = `<textarea rows="${p.rows || 3}" ${a}>${_esc(b.value)}</textarea>`;
  else if (w === 'color')
    ctrl = `<input type="color" value="${_esc(b.value)}" ${a}/>`;
  else if (w === 'date')
    ctrl = `<input type="date" value="${_esc(b.value)}" ${a}/>`;
  else if (w === 'time')
    ctrl = `<input type="time" value="${_esc(b.value)}" ${a}/>`;
  else if (w === 'select')
    ctrl = `<select ${a}>` + opts.map(o => `<option value="${_esc(o.value)}" ${String(o.value) === _selV ? 'selected' : ''}>${_esc(o.label)}</option>`).join('') + '</select>';
  else if (w === 'multiselect') {                    // inline scrollable listbox — click a row to toggle (no ⌘/Shift, no popup)
    const sv = (b.value || []).map(String);
    ctrl = `<div class="mslist" ${a} tabindex="0" role="listbox" aria-multiselectable="true">` + opts.map(o => {
      const on = sv.includes(String(o.value));
      return `<div class="msopt${on ? ' on' : ''}" data-value="${_esc(o.value)}" role="option" aria-selected="${on}"><span class="optlbl">${_esc(o.label)}</span></div>`;
    }).join('') + '</div>';
  }
  else if (w === 'multicheck') {                     // checkbox list (small sets; click to toggle — no modifiers); rich labels
    const sv = (b.value || []).map(String);
    ctrl = `<span class="checkgroup" ${a}>` + opts.map(o =>
      `<label><input type="checkbox" value="${_esc(o.value)}" ${sv.includes(String(o.value)) ? 'checked' : ''}/>` +
      `<span class="optlbl">${_esc(o.label)}</span></label>`).join('') + '</span>';
  }
  else if (w === 'radio')                            // labels rendered (KaTeX) — see _typesetControls
    ctrl = `<span class="radiogroup" ${a}>` + opts.map(o =>
      `<label><input type="radio" name="r-${bindId}-${b.name}" value="${_esc(o.value)}" ${String(o.value) === _selV ? 'checked' : ''}/>` +
      `<span class="optlbl">${_esc(o.label)}</span></label>`).join('') + '</span>';
  else if (w === 'button')                           // self-labeled — no name span, no value chrome
    return `<button type="button" class="actionbtn" data-count="${b.value}" ${a}>${_esc(p.label || 'Click')}</button>`;
  else if (w === 'playhead')                          // driven by the animation player — read-only frame readout
    ctrl = `<span class="playhead-ro" ${a} title="driven by the animation player">▶ frame</span>`;
  else if (w === 'tableselect') {                     // clickable data table → binds the clicked row (a NamedTuple)
    // Rendered by the shared interactive table renderer (sort/filter/paginate) in wireControl via
    // drawTable — same widget as a normal table display, with row selection layered on. Seed the
    // current selection so the highlight is right on the first paint.
    ctrl = `<div class="tablesel slatetable selectable" ${a} data-selrow="${parseInt(b.value, 10) || 0}"></div>`;
    wval = '';                                        // the highlighted row IS the value indicator
  }
  else {                                              // any non-builtin kind → a registered custom widget
    ctrl = `<span class="customwidget" ${a}></span>`; // empty container; its wire() builds + wires the DOM
    wval = '';
  }
  const nm = p.label != null ? p.label : b.name;   // a widget's `label=` overrides the displayed var name
  return `<span class="wname" title="${_esc(b.name)}">${_esc(nm)}</span>${ctrl}${wval}`;
}

// One row inside a bind/group cell: the live widget, or — when its control is
// surfaced in a strip — a slim chip (the variable stays live). Three cases:
//  • not surfaced            → the live widget here.
//  • surfaced in THIS cell   → nothing; the live widget renders in this cell's own
//                              control strip below (showing a chip too would dupe it).
//  • surfaced elsewhere      → a chip that jumps to the host strip on click.
const bindRow = (cellId, b) => {
  if (!b.hosted) return `<div class="widget">${controlMarkup(cellId, b)}</div>`;
  const others = (b.hostedby || []).filter(h => h !== cellId);
  if (!others.length) return '';                  // surfaced only in this cell's own strip
  const where = others.map(h => '‘' + h + '’').join(', ');
  return `<div class="hostedph" style="cursor:pointer" onclick="selectCell('${others[0]}', true)"` +
    ` title="surfaced in ${where} — click to jump">⊞ <span class="wname">${b.name}</span>` +
    `<span class="hint">— surfaced in ${where}</span></div>`;
};

// The body of a bind/group cell: one row per bound variable it defines.
const bindsInner = c => (c.binds || []).map(b => bindRow(c.id, b)).join('');
const bindsHTML = c => `<div class="binds">${bindsInner(c)}</div>`;

const hasBinds = c => c.binds && c.binds.length;

// The control strip for a code cell: each surfaced bound control, wired to its
// own defining bind cell. Rendered OUTSIDE `.output` so value-only updates
// (which replace `.output`) never tear down a widget mid-drag. Always present
// (even empty) so any code cell is a drop target for the palette. Each control
// carries a drag grip (move/reorder) and a ✕ (un-host).
function controlStripInner(c) {
  const cols = c.controls || [];                 // array of columns; each column an array of specs
  const ctrl = s => `<div class="control" data-cname="${s.name}">` +
    `<span class="cgrip" draggable="true" data-name="${s.name}" title="drag to move / reorder">⠿</span>` +
    controlMarkup(s.id, s) +
    `<button class="cdel" data-name="${s.name}" title="remove from strip">✕</button></div>`;
  // Interleave thin column-drop zones (revealed while dragging) so a control can
  // be dropped *between* columns to create a new one. `data-colindex` is the
  // insertion index into the columns array.
  const dz = i => `<div class="coldrop" data-colindex="${i}"></div>`;
  let inner = dz(0);
  cols.forEach((col, i) => { inner += `<div class="ccol" data-colindex="${i}">${col.map(ctrl).join('')}</div>` + dz(i + 1); });
  return inner;
}
const _ctrlEmpty = c => (c.controls || []).length ? '' : ' empty';
function controlStrip(c) {
  return `<div class="controls${_ctrlEmpty(c)}" data-cell="${c.id}">${controlStripInner(c)}</div>`;
}

// The notebook's DEFAULT worker location, where UNTAGGED cells run — from the whole-notebook placement
// (state.runLocation, same field the run-loc pill uses). '' host ⇒ local main kernel. A host that hosts a
// declared region reads as that region's NAME (so the home shows '🖧 gpu', not the raw host); any other
// host shows itself. Returned as {key, name, local} — `key` normalises so a home region and a matching
// cell tag count as ONE location.
function _notebookHome() {
  const loc = (window.__slateState || {}).runLocation || '';
  const host = loc ? loc.split(',')[0] : '';
  if (!host) return { key: 'local', name: '', local: true };
  const regs = (typeof nbState !== 'undefined' && nbState && nbState.regions) || [];
  const r = regs.find(x => x.host === host);
  return r ? { key: 'r:' + r.name, name: r.name, local: false } : { key: 'h:' + host, name: host, local: false };
}
// A cell's effective run location as {key, name, local}, or null when it has none to show. A region tag
// (any cell may carry one — the 🏷 Run-on picker offers it for markdown too) wins; otherwise a CODE cell
// inherits the notebook's default worker (home). An untagged MARKDOWN cell doesn't execute anywhere, so
// it has no location (null) — no home badge on static prose.
function _cellRunLoc(c) {
  const rg = cellAssignedRegion(c);
  if (rg) return { key: 'r:' + rg, name: rg, local: false };
  if (c.kind === 'md') return null;
  return _notebookHome();
}
// The distinct set of run-locations across the notebook's cells. More than one member ⇒ the notebook
// SPANS multiple places, so each cell header names where it runs; a single location is just the home
// (redundant → hidden).
function _cellRegionSet() {
  const cs = (window.__slateState || {}).cells || [];
  const s = new Set();
  for (const c of cs) { const l = _cellRunLoc(c); if (l) s.add(l.key); }
  return s;
}
// The region chip for a cell header — shown on every cell that HAS a run location, once the notebook
// spans >1 location: a coloured 🖧 <name> for cells on a region/remote host (colour matches the DAG
// region overlay), a subdued 💻 local for main-kernel cells. Untagged code cells reflect the notebook's
// default worker (so a remotely-placed notebook reads the home region, not "local"); untagged markdown
// shows nothing. Clicking opens the 🏷 Run-on picker.
function cellRegionChip(c) {
  if (_cellRegionSet().size < 2) return '';
  const loc = _cellRunLoc(c);
  if (!loc) return '';
  if (loc.local) return `<span class="cregion local" onclick="openTagEditor('${c.id}', event)" title="runs on the main kernel (this notebook’s home) — click to change">💻 local</span>`;
  const hue = (typeof _dagRegionHue === 'function' && _dagRegionHue(loc.name)) || '#8a90a8';
  return `<span class="cregion" style="color:${hue};border-color:${hue}" onclick="openTagEditor('${c.id}', event)" title="runs on ‘${_esc(loc.name)}’ — click to change">🖧 ${_esc(loc.name)}</span>`;
}

// One compact header line per cell: run + id (left), then duration, hover-revealed
// actions, and the state badge (right). Replaces the old two-row bar+head.
// Durable-cache badge for a code cell (mirrors the DAG's cache indicator). `c.memo` is the verdict
// and `c.memoWhy` the reason (see cell_json / `_memo_status`): restored/stored come from a run,
// handle/uncacheable explain why a stage WON'T persist — the signal a pipeline author wants at a
// glance. Absent (cacheable-but-cheap / not-yet-run / markdown) ⇒ no badge.
// Single source of truth for the durable-cache glyphs — shared by the cell badge (_memoBadge) and the
// DAG stats card (dag.js `window._memoGlyph`). Change a glyph here and both surfaces update together.
function _memoGlyph(state) {
  return ({ restored: '♻', stored: '⛁', handle: '⚡', uncacheable: '👻' })[state] || '';
}
function _memoBadge(c) {
  const meta = {
    restored:    ['ok',   'restored from the durable cache — no recompute'],
    stored:      ['ok',   'cached — computed this run, then persisted to the durable store'],
    handle:      ['warn', 'live handle — not cached'],
    uncacheable: ['warn', 'not cached'],
  }[c.memo];
  if (!meta) return '';
  const [cls, base] = meta;
  const tip = c.memoWhy ? base + ' — ' + c.memoWhy : base;
  return `<span class="memobadge ${cls} memo-${c.memo}" title="${_esc(tip)}">${_memoGlyph(c.memo)}</span>`;
}
function cellHeaderInner(c) {
  const isCode = c.kind === 'code' && !hasBinds(c);
  const other = c.kind === 'md' ? 'code' : 'md';
  const editSrc = (c.kind === 'md' || hasBinds(c))
    ? `<button onclick="toggleSource('${c.id}','${c.kind === 'md' ? 'markdown' : 'julia'}')" title="edit source">&lt;/&gt;</button>` : '';
  const run = isCode ? `<button class="run" data-run="${c.id}" onclick="runCell('${c.id}', true)" title="run this cell (always re-evaluates; ⇧⏎ runs only if changed)">▶</button>` : '';
  const bu = surfaceableNames(c);
  const _present = new Set([].concat(...((c.controls || []).map(col => col.map(s => s.name)))));
  const _someOn = bu.some(n => _present.has(n));
  const autoctl = bu.length
    ? `<button class="autoctl${_someOn ? ' on' : ''}" onclick="openControlPicker('${c.id}', event)" title="pick which @bind controls to surface on this cell (${bu.join(', ')})">🎛</button>` : '';
  return '<span class="drag" draggable="true" title="drag to reorder">⠿</span>' +
    `<button class="collapse" onclick="toggleCollapse('${c.id}')" title="collapse / expand">${c.collapsed ? '▸' : '▾'}</button>` + run +
    `<span class="cid" title="double-click to rename">${c.id}</span>` +
    cellRegionChip(c) +
    (c.dupdefs && c.dupdefs.length
      ? `<span class="dupwarn" onclick="window.dupInfo(event,'${c.id}')" title="defined in more than one cell — click for details">⚠ ${c.dupdefs.map(_esc).join(', ')}</span>` : '') +
    (c.backrefs && c.backrefs.length
      ? `<span class="dupwarn" onclick="window.backrefInfo(event,'${c.id}')" title="used above its definition — click for details">⤵️ ${c.backrefs.map(_esc).join(', ')}</span>` : '') +
    ((() => {   // `needs=` entries that resolve to no EARLIER CODE cell → the manual edge is inert
      if (!c.needs || !c.needs.length) return '';
      const cs = (window.__slateState || {}).cells || [];
      const idx = id => cs.findIndex(x => x.id === id);
      const me = idx(c.id);
      const bad = c.needs.filter(n => { const j = idx(n); return j < 0 || j >= me || cs[j].kind !== 'code'; });
      return bad.length
        ? `<span class="dupwarn" title="needs= names no earlier code cell (deleted, moved below, or markdown) — this manual edge is inert">🔗⚠ ${bad.map(_esc).join(', ')}</span>` : '';
    })()) +
    '<span class="hspace"></span>' +
    '<span class="cellacts">' +
      `<button class="askai" onclick="askCell('${c.id}')" title="ask the AI about this cell">✨</button>` +
      (c.kind === 'code' ? `<button onclick="toggleDeps('${c.id}')" title="focus: show only this cell's dependency chain (Esc to exit)">🔗</button>` : '') + autoctl +
      (isCode ? `<button class="trace${c.trace ? ' on' : ''}" onclick="toggleTrace('${c.id}')" title="${c.trace ? 'open the trace inspector' : 'trace this cell — inspect each value in a popup'}">🔍</button>` : '') +
      (isCode ? `<button class="hidecode${c.codeHidden ? ' on' : ''}" onclick="toggleHideCode('${c.id}')" title="${c.codeHidden ? 'show code' : 'hide code — show only the output'}">${c.codeHidden ? '🙈' : '👁'}</button>` : '') +
      `<button class="tagbtn${(c.tags && c.tags.length) ? ' on' : ''}" onclick="openTagEditor('${c.id}', event)" title="cell tags${(c.tags && c.tags.length) ? ': ' + c.tags.join(', ') : ''}">🏷</button>` +
      editSrc +
      `<button onclick="moveCell('${c.id}','up')" title="move up">↑</button>` +
      `<button onclick="moveCell('${c.id}','down')" title="move down">↓</button>` +
      `<button onclick="toggleType('${c.id}','${other}')" title="to ${other}">${c.kind === 'md' ? '{·}' : 'M↓'}</button>` +
      `<button class="addbtn" onclick="addCell('${c.id}','code')" oncontextmenu="addMenu(event,'${c.id}');return false" title="add below · right-click for type">＋</button>` +
      `<button class="del" onclick="delCell('${c.id}')" title="delete cell">🗑</button>` +
    '</span>' +
    // Run-info cluster, right-aligned and contiguous (buttons sit to its left): run time (reserved
    // width) · cache verdict (fixed slot) · state badge (fixed width) — so nothing floats mid-header.
    `<span class="cdur">${c.duration != null ? c.duration + ' ms' : ''}</span>` +
    `<span class="memoslot">${_memoBadge(c)}</span>` +
    `<span class="badge">${c.state}</span>`;
}
function cellHeader(c) { return '<div class="cellhead">' + cellHeaderInner(c) + '</div>'; }

// (cellEl + mountEditor removed — the Preact <Notebook>/<Cell>/<Editor> in notebook.js now
//  build the cell DOM and own the CodeMirror lifecycle. cellHeaderInner/bindsInner/controlStrip/
//  srcEditInner/wireCodeEditor are the shared pieces it reuses; see the window expose below.)

function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

// Wire one widget input → its defining bind cell. `data-bind` is the bind cell
// id (POST target); `data-widget` its type. The value mirror (`.wval`) is found
// relative to the input, so strip and standalone widgets never collide on ids.
//
// Send policy while dragging: rate-limit to one recompute per `updateMs`, AND
// coalesce in-flight (never queue a backlog — hold only the latest value while a
// recompute runs). Releasing the control (`change`) flushes the final value
// immediately, so the end state is always correct regardless of the rate limit.
function wireControl(el) {
  const id = el.dataset.bind, name = el.dataset.name, widget = el.dataset.widget;
  let inflight = false, pending = null, lastSent = 0, timer = null;
  const fire = v => {
    lastSent = performance.now(); inflight = true; pending = null;
    clearTimeout(timer); timer = null;
    // A `ui_theme` bind doubles as the Slate theme switch: swap the client CSS + ECharts here, and let
    // the POST below flow the value through the dependency graph so a `use_slate_theme!(theme=ui_theme)`
    // cell re-runs and the SERVER-rendered (Makie) figures re-theme too. setSlateTheme no-ops on an
    // unknown value, so this is inert for every other bind.
    if (name === 'ui_theme' && window.setSlateTheme) { try { window.setSlateTheme(v); } catch (_) {} }
    api('POST', '/api/bind/' + id, { name, value: v })
      .then(updateStates)
      .finally(() => { inflight = false; if (pending !== null) schedule(pending); });
  };
  const schedule = v => {                       // throttled, coalescing
    pending = v;
    if (inflight) return;
    const wait = Math.max(0, updateMs - (performance.now() - lastSent));
    if (wait <= 0) fire(v);
    else if (!timer) timer = setTimeout(() => fire(pending), wait);
  };
  const flush = v => { inflight ? (pending = v) : fire(v); };   // release → send now
  const mirror = v => { const w = el.closest('.widget, .control'); const m = w && w.querySelector('.wval');
    if (m) m.textContent = _ctrlValLabel(el, v); };
  // Mark the control as just-touched so background refreshes (async live updates)
  // don't yank its value out from under the user mid-interaction.
  const touch = () => { el._touched = performance.now(); };
  el.addEventListener('pointerdown', touch);
  el.addEventListener('focus', touch, true);
  // Custom (third-party) widget: it owns its element's DOM + events, so it NEVER takes the built-in
  // input wiring below — not even before its impl registers. An async import can register AFTER the
  // control mounted; the empty container then just waits for slateRegisterWidget to re-wire it. This
  // early return is what stops a stale built-in `oninput` (from a fallthrough) later firing on the
  // plugin's own inner inputs and pushing a garbage value.
  if (el.classList.contains('customwidget')) {
    const _reg = window.slateWidgets && window.slateWidgets[widget];
    if (_reg && _reg.wire && !el._customWired) {
      el._customWired = true;
      const bs = _bindSpec(id, name), params = (bs && bs.params) || {};
      // `value` is the control's current value at wire time, so a widget can build itself correctly on
      // the first call without waiting for a `sync` (which still delivers later reactive updates).
      _reg.wire(el, { push: flush, schedule, flush, name, bindId: id, params, value: bs ? bs.value : undefined, mirror });
    }
    return;                                          // the plugin owns this element (or it's awaiting registration)
  }
  if (widget === 'button') {                       // action button → increments a counter
    el.onclick = () => { touch(); const n = (parseInt(el.dataset.count, 10) || 0) + 1; el.dataset.count = n; mirror(n); flush(n); };
    return;
  }
  const readVal = () => {
    if (widget === 'checkbox' || widget === 'toggle') return el.checked;
    if (widget === 'slider' || widget === 'number') return parseFloat(el.value);
    if (widget === 'multiselect') return [...el.querySelectorAll('.msopt.on')].map(o => o.dataset.value);
    if (widget === 'multicheck') return [...el.querySelectorAll('input[type=checkbox]:checked')].map(i => i.value);
    if (widget === 'radio') { const c = el.querySelector('input:checked'); return c ? c.value : null; }
    if (widget === 'tableselect') return parseInt(el.dataset.selrow, 10) || 0;
    return el.value;
  };
  if (widget === 'tableselect') {                    // interactive table (sort/filter/page) + row selection
    const bs = _bindSpec(el.dataset.bind, el.dataset.name), pp = (bs && bs.params) || {};
    const spec = { columns: pp.columns || [], rows: pp.rows || [], opts: pp.opts || {} };
    const st = el._st || (el._st = { sort: null, filter: '', page: 0, pageSize: 25 });
    drawTable(el, spec, st, {
      value: () => parseInt(el.dataset.selrow, 10) || 0,
      onSelect: oi => {
        touch(); el.dataset.selrow = oi;
        el.querySelectorAll('tr.selrow.on').forEach(t => t.classList.remove('on'));
        const tr = el.querySelector('tr.selrow[data-row="' + oi + '"]'); if (tr) tr.classList.add('on');
        el._dirty = _valKey(oi); flush(oi);
      },
    });
    return;                                          // drawTable owns the DOM + events
  }
  if (widget === 'multiselect') {                    // custom listbox: click a row to toggle; Shift-click a range
    el.addEventListener('mousedown', e => { if (e.shiftKey) e.preventDefault(); });   // don't start a text selection
    const setOpt = (o, on) => { o.classList.toggle('on', on); o.setAttribute('aria-selected', on); };
    el.addEventListener('click', e => {
      const opt = e.target.closest('.msopt'); if (!opt || !el.contains(opt)) return;
      touch();
      const opts = [...el.querySelectorAll('.msopt')], idx = opts.indexOf(opt);
      if (e.shiftKey && el._anchor != null && el._anchor < opts.length) {
        const on = el._anchorOn !== false;            // extend the range to the anchor's state (default: select)
        const lo = Math.min(el._anchor, idx), hi = Math.max(el._anchor, idx);
        for (let i = lo; i <= hi; i++) setOpt(opts[i], on);
      } else {
        const on = !opt.classList.contains('on'); setOpt(opt, on);
        el._anchor = idx; el._anchorOn = on;          // remember the anchor + its new state for the next Shift-click
      }
      const v = readVal(); el._dirty = _valKey(v); mirror(v); flush(v);
    });
    return;                                          // no input/change events on a div listbox
  }
  el.oninput  = () => { touch(); const v = readVal(); el._dirty = _valKey(v); mirror(v); schedule(v); };
  el.onchange = () => { touch(); const v = readVal(); el._dirty = _valKey(v); mirror(v); flush(v); };
}

// The live bind spec ({name,widget,params,value,…}) for a control, found via its defining cell —
// used by widgets (TableSelect) that need their full params (the table data) when wiring behavior.
function _bindSpec(bindId, name) {
  const c = _cellById(bindId); if (!c) return null;
  return (c.binds || []).find(b => b.name === name) || null;
}
// Wire every bound widget in a cell — its own @bind widget and/or control strip.
function mountControls(c) {
  const cell = document.getElementById('cell-' + c.id);
  if (!cell) return;
  cell.querySelectorAll('[data-bind]').forEach(wireControl);
  cell.querySelectorAll('.radiogroup, .checkgroup, .mslist').forEach(typeset);   // render rich ($math$) option labels
}

// Source editing for non-code cells (markdown + @bind widgets): reveal a raw
// source editor; ⇧⏎ commits (re-parsing/re-rendering the cell), esc cancels.
const _disp = cell => cell.querySelector('.md') || cell.querySelector('.binds');

// The `</>` button toggles a md/bind cell between its rendered form and raw
// source. Opening when rendered; when already editing, commit if the source
// changed (don't lose work) or just cancel back to rendered if it didn't.
function toggleSource(id, mode) {
  const cell = document.getElementById('cell-' + id); if (!cell) return;
  const sed = cell.querySelector('.srcedit');
  if (sed && sed.style.display !== 'none') {
    (editors[id] && edText(id) !== (srcMap[id] || '')) ? commitSource(id) : cancelSource(id);
  } else {
    editSource(id, mode);
  }
}

function editSource(id, mode) {
  const cell = document.getElementById('cell-' + id);
  if (!cell) return;
  const d = _disp(cell); if (d) d.style.display = 'none';
  const sed = cell.querySelector('.srcedit'); sed.style.display = '';
  if (!editors[id]) {
    const ta = sed.querySelector('textarea'); if (ta) ta.style.display = 'none';   // CM6 mounts a sibling editor
    window.mkEditor(sed, {
      doc: srcMap[id] || '', cellId: id, markdown: mode === 'markdown',
      onDoc: () => { if (edText(id) !== (srcMap[id] || '')) { setState(id, 'edited'); window._backupSoon && window._backupSoon(); } },
      onFocus: () => setEditing(id, true), onBlur: () => setEditing(id, false),
      keys: [
        { key: 'Shift-Enter', run: () => commitSource(id) },
        { key: 'Escape', run: () => cancelSource(id) },
        { key: 'Shift-Mod-Enter', run: () => commitAndAddBelow(id) },
        { key: 'Shift-Ctrl-Enter', run: () => commitAndAddBelow(id) },
        { key: 'Shift-Mod--', run: () => splitCell(id) }, { key: 'Shift-Ctrl--', run: () => splitCell(id) },
      ],
    });
    // Pending unsaved-edit restore for a markdown / @bind cell (its editor opens on demand).
    const pend = window._pendingRestore && window._pendingRestore[id];
    if (pend != null) { window.edSetText(id, pend); setState(id, 'edited'); delete window._pendingRestore[id]; }
  }
  window.edFocus(id);
}
async function commitSource(id) {
  const src = editors[id] ? edText(id) : srcMap[id];
  if (editors[id]) { try { editors[id].destroy(); } catch (_) {} delete editors[id]; }
  srcMap[id] = src;
  // Restore the rendered view ourselves (like cancelSource): Preact now PRESERVES the cell's
  // DOM nodes across re-render, so the display:none editSource set on `.md`/`.binds` (and the
  // display:'' on `.srcedit`) would otherwise persist — leaving the raw source editor showing
  // instead of the freshly rendered cell. (The old wipe-and-rebuild renderAll made this moot.)
  const cell = document.getElementById('cell-' + id);
  if (cell) {
    const sed = cell.querySelector('.srcedit'); if (sed) sed.style.display = 'none';
    const d = _disp(cell); if (d) d.style.display = '';
  }
  renderAll(await api('POST', '/api/cell/' + id, { source: src }));   // re-render in its new form
}
function cancelSource(id) {
  const cm = editors[id]; if (cm) { try { cm.destroy(); } catch (_) {} delete editors[id]; }
  const cell = document.getElementById('cell-' + id); if (!cell) return;
  cell.querySelector('.srcedit').style.display = 'none';
  const d = _disp(cell); if (d) d.style.display = '';
}

// Notebook rendering is owned by the Preact <Notebook> (notebook.js), driven by the signals
// store. renderAll/updateStates now just publish the state + refresh the chrome; the component
// diffs cells by id (so editors survive structural ops) and does per-cell output processing in
// effects. The old full-wipe rebuild and the in-place patch collapse into one publish.
function renderAll(state)    { _publishState(state); window.loadScratch && window.loadScratch(state && state.scratch); }
function updateStates(state) { _publishState(state); window.loadScratch && window.loadScratch(state && state.scratch); }
// Targeted live refresh (SSE `refresh:` event): merge ONLY the changed cells into nbState and
// patch THOSE cells imperatively — charts `setOption`, tables refill, output swap, control values
// — with NO full-state GET and NO all-cells re-render. nbState.cells is mutated in place so the
// signal identity is unchanged (Preact doesn't re-render); a structural change (kind / bind-ness)
// falls back to a full publish.
function patchCells(cells) {
  if (!cells || !cells.length || !nbState) return;
  const list = nbState.cells || [];
  const idx = {}; list.forEach((c, i) => idx[c.id] = i);
  let structural = false;
  cells.forEach(nc => {
    const i = idx[nc.id];
    if (i == null) { structural = true; return; }
    const old = list[i];
    if (old.kind !== nc.kind || hasBinds(old) !== hasBinds(nc)) structural = true;
    list[i] = nc;
  });
  if (structural) { _publishState({ ...nbState, cells: list.slice() }); return; }
  cells.forEach(nc => {
    // Keep a CLEAN editor in lockstep with the saved source. This path advances srcMap but does NO
    // Preact re-render, so an untouched editor would be left showing the OLD source while its
    // baseline jumped ahead — then the next full render (notebook.js) reads the advanced srcMap as
    // `_prevSrc`, sees editor ≠ baseline, and pops a phantom "a change just landed while you were
    // editing" conflict for a cell you never touched. Mirror notebook.js: fast-forward only when
    // there are no local edits; a genuine divergence is left for the reconcile flow.
    const _eqw = (a, b) => (a || '').replace(/\s+$/, '') === (b || '').replace(/\s+$/, '');
    const _prevSrc = srcMap[nc.id];
    srcMap[nc.id] = nc.source;
    if (editors[nc.id]) {
      const _mine = edText(nc.id);
      if (_eqw(_mine, _prevSrc) && !_eqw(_mine, nc.source)) edSetText(nc.id, nc.source);
    }
    // A cell you're actively editing is YOURS until you resolve: if its editor still diverges from the
    // incoming source (a live conflict), freeze its source/output/charts — don't let the external run
    // replace what you're looking at. Same rule as notebook.js; the reconcile flow re-applies on accept.
    const _conflicted = editors[nc.id] && !_eqw(edText(nc.id), nc.source);
    const cell = document.getElementById('cell-' + nc.id);
    if (cell) {
      cell.className = cell.className.replace(/\bstate-\S+/, 'state-' + (_conflicted ? 'edited' : nc.state));
      const badge = cell.querySelector('.badge'); if (badge) badge.textContent = _conflicted ? 'edited' : nc.state;
      if (!_conflicted) {
        if (nc.kind === 'md') { const md = cell.querySelector('.md'); if (md) { _swapOutput(md, mdHtml(nc)); typeset(md); } }
        else { const out = cell.querySelector('.output'); if (out) { _swapOutput(out, nc.output); typeset(out); } }
      }
    }
    if (!_conflicted) { renderCharts(nc); renderTables(nc); syncControlValues({ cells: [nc] }); }
  });
  window.onCellsPatched && window.onCellsPatched(cells);       // states/durations moved (DAG panel)
  window.renderRunPill && window.renderRunPill();              // a cell just changed state → refresh the error pill
}
// `cellpre:` — an agent add/edit, shown BEFORE its eval finishes. Upsert by id: replace an
// existing cell in place (edit → the new source renders now), or splice a new one at `index`
// (add → the cell appears stale instead of being invisible until the run ends). The live
// `cellrun:`/`celldone:` events then patch it as the eval progresses. Idempotent / safe if the
// post-eval full-state pull arrives later (it just supersedes this).
function onCellPre(index, cell) {
  if (!nbState || !cell) return;
  const cells = (nbState.cells || []).slice();
  const at = cells.findIndex(c => c.id === cell.id);
  if (at >= 0) cells[at] = cell;                                          // edit: replace in place
  else cells.splice(Math.max(0, Math.min(index | 0, cells.length)), 0, cell);   // add: insert at index
  _publishState({ ...nbState, cells });
}
window.onCellPre = onCellPre;

// Shared warning-chip popup: renders `html` in the dupinfo card under the clicked chip, wires
// `.dupinfo-jump` links to cell navigation, and dismisses on outside-click / Escape.
function _chipPopup(ev, html) {
  const old = document.getElementById('dupinfo'); if (old) old.remove();
  const pop = document.createElement('div');
  pop.id = 'dupinfo'; pop.className = 'dupinfo';
  pop.innerHTML = html;
  document.body.appendChild(pop);
  const r = ev.target.getBoundingClientRect();
  pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - pop.offsetWidth - 12)) + 'px';
  pop.style.top = (r.bottom + 6) + 'px';
  pop.addEventListener('click', e => {
    const a = e.target.closest('.dupinfo-jump');
    if (a) { try { selectCell(a.dataset.cid, true); } catch (_) {} pop.remove(); }
  });
  setTimeout(() => {
    const close = e => { if (!pop.contains(e.target)) cleanup(); };
    const esc = e => { if (e.key === 'Escape') cleanup(); };
    const cleanup = () => { pop.remove(); document.removeEventListener('mousedown', close); document.removeEventListener('keydown', esc); };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', esc);
  }, 0);
}

// Click the ⚠ multidef chip → a popup listing each colliding name and the cells that define it
// (click a cell id to jump there). Dismissed on outside-click / Escape.
function dupInfo(ev, cellId) {
  ev.stopPropagation();
  const st = window.__slateState || {};
  const c = (st.cells || []).find(x => x.id === cellId);
  const mc = st.multidefCells || {};
  if (!c || !(c.dupdefs && c.dupdefs.length)) return;
  const rows = c.dupdefs.map(name =>
    `<div class="dupinfo-row"><code>${_esc(name)}</code> — defined in ` +
    (mc[name] || []).map(id => `<a class="dupinfo-jump${id === cellId ? ' self' : ''}" data-cid="${_esc(id)}">${_esc(id)}</a>`).join(', ') +
    '</div>').join('');
  _chipPopup(ev, '<div class="dupinfo-h">Defined in multiple cells</div>' + rows +
    '<div class="dupinfo-foot">One shared namespace — the last cell to run wins. Rename to avoid surprises.</div>');
}
window.dupInfo = dupInfo;

// Click the ⤵️ backref chip → a popup naming each variable this cell uses ABOVE where it's defined.
// Document order is execution order, so the read silently sees a missing (first run) or previous-run
// value, and editing the definer never recomputes this cell. Click the definer id to jump to it.
function backrefInfo(ev, cellId) {
  ev.stopPropagation();
  const st = window.__slateState || {};
  const c = (st.cells || []).find(x => x.id === cellId);
  const bc = st.backrefCells || {};
  if (!c || !(c.backrefs && c.backrefs.length)) return;
  const rows = c.backrefs.map(name => {
    const w = (bc[name] || [])[1];
    return `<div class="dupinfo-row"><code>${_esc(name)}</code> — defined below in ` +
      (w ? `<a class="dupinfo-jump" data-cid="${_esc(w)}">${_esc(w)}</a>` : '?') + '</div>';
  }).join('');
  _chipPopup(ev, '<div class="dupinfo-h">Used above its definition</div>' + rows +
    '<div class="dupinfo-foot">Document order is execution order — move this cell below the definition, or the definition up.</div>');
}
window.backrefInfo = backrefInfo;

function _publishState(state) {
  nbState = state;
  // Remember this notebook's file path so a reconnect after a server restart can ask the server
  // to re-open it by path (the in-memory registry is empty after a restart — see panels.js _probe).
  if (state && state.path) { try { localStorage.setItem('slate:path:' + NB_ID, state.path); } catch (_) {} }
  window.__slateState = state;                  // latest state, always — so the store (a deferred
                                                // module) can seed from it even if it loads AFTER
                                                // this first ran (the boot reload() is async).
  if (selectedId && !(state.cells || []).some(c => c.id === selectedId)) selectedId = null;   // dropped/renamed
  window.slateStore && window.slateStore.applyState(state);   // → Preact re-renders #nb reactively
  window.onNbState && window.onNbState(state);                // graph-shaped consumers (DAG panel)
  updateChrome(state);
}
// Live remote bring-up detail — the latest streamed instantiate/precompile line, shown under the
// hydrating banner. updateChrome re-renders the banner from this; `onBringup` patches it live between
// renders; it's cleared when hydration ends.
let _bringupLine = '';
window.onBringup = function (line) {
  _bringupLine = String(line || '');
  const step = document.getElementById('hydstep');   // banner already up → update in place, no full re-render
  if (step) step.textContent = _bringupLine;
};
// Topbar/banner bits that live outside #nb (title, worker dot, vscode link, hydrating banner).
function updateChrome(state) {
  document.getElementById('title').textContent = state.title || 'Notebook';
  document.title = (state.title ? state.title + ' · ' : '') + 'Kaimon Slate';   // browser tab
  const w = state.worker || {}, dot = document.getElementById('wdot');
  if (dot) {
    // Worker dot semantics: green = healthy (worker connected — incl. while a run streams — OR a
    // markdown-only notebook, which has nothing to run and so is trivially healthy), blue = in-process
    // kernel OR the gate worker still BOOTING (hydrating), red = a genuine disconnect of a RUNNABLE
    // notebook only. So a not-yet-connected gate worker shows a "starting" blue pulse during hydration,
    // and an md-only notebook shows green (not the alarming red) — the tooltip says there's no worker.
    const hasCode = (state.cells || []).some(c => c.kind === 'code');
    const cls = w.kind === 'inproc' ? 'inproc'
              : w.connected ? 'up'
              : state.hydrating ? 'inproc busy'
              : hasCode ? 'down'          // a genuine disconnect of a runnable notebook
              : 'up';                     // md-only: nothing to run → healthy (green), never red
    dot.className = 'wdot ' + cls + (_busy > 0 ? ' busy' : '');
    dot.title = !hasCode && !w.connected ? 'markdown only — nothing to run'
              : w.kind === 'gate'
              ? ('worker :' + w.port + (w.connected ? ' · connected' : (state.hydrating ? ' · starting…' : ' · disconnected')))
              : 'in-process kernel';
  }
  window.renderRunLoc && window.renderRunLoc(state);   // toolbar run-location pill (session/notebook/global)
  window.renderWorkers && window.renderWorkers(state); // per-region worker pills next to it (click → log/status popup)
  window.renderRunPill && window.renderRunPill();      // error pill reads live state → clears when a cell is fixed/removed
  if (state.path) document.getElementById('vscode').href = 'vscode://file' + state.path;
  const hb = document.getElementById('hydbanner');
  _hydrating = !!state.hydrating;              // gate mutating actions while the env reconstructs
  if (state.hydrating) {
    hb.className = 'hydbanner'; hb.style.display = 'flex';
    hb.innerHTML = '<span class="hydspin"></span><span class="hydmsg">' + (
      state.hydratingKind === 'remote'
        ? ('Starting the worker on <b>' + (state.hydratingHost || 'the remote host') + '</b> — provisioning &amp; connecting' +
           ' (a first run installs Julia deps and can take a few minutes)…')
      : state.hydratingKind === 'run'
        ? 'Running the notebook — cells appear as they finish; editing unlocks when the run completes…'
        : 'Reconstructing environment &amp; instantiating packages — showing a saved preview; cells go live when it’s ready…')
      // live detail: the remote worker's streamed instantiate/precompile line (fed by `bringup:` events)
      + '</span><span id="hydstep" class="hydstep">' + (_bringupLine ? _esc(_bringupLine) : '') + '</span>';
    document.body.classList.add('hydrating');
  } else if (state.hydrateError) {
    hb.className = 'hydbanner err'; hb.style.display = 'flex';
    hb.textContent = '⚠ ' + state.hydrateError;   // worker bring-up / env reconstruction failed (message is self-contained)
    document.body.classList.remove('hydrating'); _bringupLine = '';
  } else {
    hb.style.display = 'none'; document.body.classList.remove('hydrating'); _bringupLine = '';
  }
  updateStaleBadge(state);
  // Agent chat needs Kaimon's agent service — a standalone hub (slate --own / serve_notebook)
  // doesn't have it. Disable the button up front instead of letting the first turn error out.
  const ab = document.getElementById('agentbtn');
  if (ab) {
    const avail = state.agentAvailable !== false;   // absent (older server) → assume available
    ab.disabled = !avail;
    ab.title = avail ? 'agent chat'
                     : 'agent chat needs Kaimon — this hub is running standalone. Start Kaimon and open the notebook from its hub.';
  }
  // Undo/Redo menu items announce the next action ("↶ Undo cut 3 cells") and disable when empty.
  const ub = document.getElementById('undobtn');
  if (ub) { ub.textContent = '↶ Undo' + (state.undoLabel ? ' ' + state.undoLabel : ''); ub.disabled = !state.undoLabel; }
  const rb = document.getElementById('redobtn');
  if (rb) { rb.textContent = '↷ Redo' + (state.redoLabel ? ' ' + state.redoLabel : ''); rb.disabled = !state.redoLabel; }
}

// ── Controls palette ─────────────────────────────────────────────────────────
// A side drawer listing every @bind declared across the notebook, where each is
// hosted (surfaced in a cell's control strip), and its live value. Read-only here;
// drag-to-host is wired in a later pass.
function paletteChips() {
  const cells = (nbState && nbState.cells) || [];
  const hosts = {};                                    // var name → [host cell ids] (a control may be in several)
  cells.forEach(h => (h.controls || []).flat().forEach(s => { (hosts[s.name] ||= []).push(h.id); }));
  const chips = [];
  cells.forEach(c => (c.binds || []).forEach(b =>
    chips.push({ name: b.name, widget: b.widget, value: b.value, def: c.id, hosts: hosts[b.name] || [] })));
  return chips;
}
function togglePalette() { document.getElementById('palette').classList.toggle('open'); }
function renderPalette() {
  const list = document.getElementById('palette-list'); if (!list) return;
  const chips = paletteChips();
  document.getElementById('palette-count').textContent = chips.length ? chips.length + ' declared' : '';
  if (!chips.length) { list.innerHTML = '<div class="phint">No <code>@bind</code> controls declared yet.</div>'; return; }
  list.innerHTML = chips.map(c => {
    const host = c.hosts.length ? '→ ' + c.hosts.join(', ') : '';
    return `<div class="chip${c.hosts.length ? ' hosted' : ''}" draggable="true" data-pname="${c.name}" data-def="${c.def}"` +
      ` title="drag into a cell to surface it · click to jump to ‘${c.def}’${c.hosts.length ? ' · surfaced in ' + c.hosts.map(h => '‘' + h + '’').join(', ') : ''}">` +
      `<span class="cname">${c.name}</span><span class="ctype">${c.widget}</span>` +
      `<span class="cright">${host ? `<span class="chost">${host}</span>` : ''}` +
      `<span class="pval" data-pname="${c.name}">${c.value}</span></span></div>`;
  }).join('');
}
function updatePaletteValues(state) {
  state.cells.forEach(c => (c.binds || []).forEach(b => {
    const v = document.querySelector('#palette-list .pval[data-pname="' + b.name + '"]');
    if (v) v.textContent = b.value;
  }));
}

// Keep every widget bound to a variable in lockstep (a control may be surfaced in
// multiple cells). Skips the element being actively dragged so we never fight it.
const _sameList = (a, b) => a.length === b.length && a.every((x, i) => String(x) === String(b[i]));

function syncControlValues(state) {
  const val = {}, par = {};
  state.cells.forEach(c => {
    (c.binds || []).forEach(b => { val[b.name] = b.value; par[b.name] = b.params || {}; });
    (c.controls || []).flat().forEach(s => { val[s.name] = s.value; par[s.name] = s.params || {}; });   // controls is columns-of-specs
  });
  const now = performance.now();
  document.querySelectorAll('#nb [data-bind][data-name]').forEach(el => {
    // Don't fight live interaction: skip the focused/contained element, and any
    // control touched in the last 1.2s (covers a drag that isn't the activeElement).
    if (el === document.activeElement || el.contains(document.activeElement)) return;
    if (el._touched && now - el._touched < 1200) return;
    const v = val[el.dataset.name]; if (v === undefined) return;
    const w = el.dataset.widget;
    // Stale-echo guard: while a local change is in flight, ONLY the echo that matches the user's
    // last-sent value clears the mark — an older echo (e.g. the prior multi-select state) is
    // ignored, so it can't snap a just-changed control back (and an empty selection sticks).
    if (el._dirty != null) { if (_valKey(v) === el._dirty) el._dirty = null; else return; }
    // Keep the widget's RANGE/options in sync, not just its value — a dynamic widget
    // (e.g. `Slider(1:hi)`) re-reports new params when `hi` changes. Apply range
    // BEFORE the value so the browser doesn't clamp against the stale bounds.
    const p = par[el.dataset.name] || {};
    if (w === 'slider') {
      if (p.min != null) el.min = p.min;
      if (p.max != null) el.max = p.max;
      if (p.step != null) el.step = p.step;
    } else if (w === 'number') {
      p.min != null ? (el.min = p.min) : el.removeAttribute('min');
      p.max != null ? (el.max = p.max) : el.removeAttribute('max');
    } else if (w === 'select' && Array.isArray(p.options)) {
      // Dynamic options: rebuild the <option> list only if it changed (the value-set
      // below re-applies the selection). Avoids tearing the menu down every sync.
      const o2 = p.options.map(o => (o && typeof o === 'object') ? o : { value: o, label: String(o) });
      const cur = [...el.options].map(o => o.value), want = o2.map(o => String(o.value));
      if (!_sameList(cur, want)) el.innerHTML = o2.map(o => `<option value="${_esc(o.value)}">${_esc(o.label)}</option>`).join('');
    } else if (w === 'multiselect' && Array.isArray(p.options)) {
      const o2 = p.options.map(o => (o && typeof o === 'object') ? o : { value: o, label: String(o) });
      const cur = [...el.querySelectorAll('.msopt')].map(o => o.dataset.value), want = o2.map(o => String(o.value));
      if (!_sameList(cur, want)) {
        el.innerHTML = o2.map(o => `<div class="msopt" data-value="${_esc(o.value)}" role="option"><span class="optlbl">${_esc(o.label)}</span></div>`).join('');
        typeset(el);
      }
    } else if ((w === 'radio' || w === 'multicheck') && Array.isArray(p.options)) {
      // Radio + checkbox-list MultiCheckBox share a label-per-input layout; rebuild only on change.
      const o2 = p.options.map(o => (o && typeof o === 'object') ? o : { value: o, label: String(o) });
      const type = w === 'radio' ? 'radio' : 'checkbox';
      const cur = [...el.querySelectorAll('input')].map(i => i.value), want = o2.map(o => String(o.value));
      if (!_sameList(cur, want)) {
        const nm = w === 'radio' ? ` name="r-${el.dataset.bind}-${el.dataset.name}"` : '';
        el.innerHTML = o2.map(o =>
          `<label><input type="${type}"${nm} value="${_esc(o.value)}"/><span class="optlbl">${_esc(o.label)}</span></label>`).join('');
        typeset(el);                                 // re-render rich labels after a dynamic rebuild
      }
    }
    const _q = s => (typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(s) : s.replace(/["\\]/g, '\\$&');
    if (w === 'checkbox' || w === 'toggle') el.checked = !!v;
    else if (w === 'multiselect') { const sv = (Array.isArray(v) ? v : []).map(String); el.querySelectorAll('.msopt').forEach(o => { const on = sv.includes(o.dataset.value); o.classList.toggle('on', on); o.setAttribute('aria-selected', on); }); }
    else if (w === 'multicheck') { const sv = (Array.isArray(v) ? v : []).map(String); el.querySelectorAll('input[type=checkbox]').forEach(i => { i.checked = sv.includes(i.value); }); }
    else if (w === 'radio') { const c = el.querySelector('input[value="' + _q(String(v)) + '"]'); if (c) c.checked = true; }
    else if (w === 'tableselect') { const sel = parseInt(v, 10) || 0; el.dataset.selrow = sel; el.querySelectorAll('tr.selrow').forEach(tr => tr.classList.toggle('on', (parseInt(tr.dataset.row, 10) || 0) === sel)); }
    else if (w === 'button') el.dataset.count = v;
    else if (window.slateWidgets && window.slateWidgets[w] && window.slateWidgets[w].sync) window.slateWidgets[w].sync(el, v, p);
    else el.value = String(v);
    const wrap = el.closest('.widget, .control'); const m = wrap && wrap.querySelector('.wval');
    if (m) m.textContent = _ctrlValLabel(el, v);
  });
}

// Instant local feedback (running/edited) before the server round-trips: routed through the
// store so Preact owns the cell's className + badge (an imperative className here would fight
// Preact and stick — the pulsing-bracket bug). Cleared when the authoritative state arrives.
function setState(id, s) { window.slateStore && window.slateStore.setLiveState(id, s); }

// Replace a cell's output, reserving its current height until the new content
// (notably a base64 <img>, which has no size until it decodes) lays out. Without
// this the output collapses to ~0 height mid-swap; Safari then clamps scrollTop to
// the now-shorter page and the figure scrolls out of view (the P2 scroll bug).
function _swapOutput(out, html) {
  out.style.minHeight = out.offsetHeight + 'px';
  out.innerHTML = html;
  runScripts(out);   // <script> set via innerHTML is inert — re-create so figures boot
  const imgs = out.querySelectorAll('img');
  const release = () => { out.style.minHeight = ''; };
  if (!imgs.length) { requestAnimationFrame(release); return; }
  let n = imgs.length;
  const done = () => { if (--n <= 0) release(); };
  imgs.forEach(im => im.complete ? done() : (im.onload = im.onerror = done));
}

// A <script> assigned via innerHTML is parsed but never executed. Rich output
// (notably a WGLMakie/Bonito figure: a module bundle <script src> that defines
// `Bonito`, then an inline module that calls `Bonito.init_session(…)`) only boots
// if those scripts actually run. Re-create each as a live element so the browser
// executes it; await external/`src` scripts so the bundle finishes (and `Bonito`
// is defined) before the inline init module that depends on it runs. (Inline
// scripts execute on insert and aren't awaited — inline module `load` is unreliable.)
async function runScripts(root) {
  if (!root) return;
  for (const old of Array.from(root.querySelectorAll('script'))) {
    const s = document.createElement('script');
    for (const a of old.attributes) s.setAttribute(a.name, a.value);
    if (old.textContent) s.textContent = old.textContent;
    const loaded = s.src ? new Promise(res => { s.onload = s.onerror = res; }) : null;
    old.replaceWith(s);
    if (loaded) await loaded;
  }
}

// Expose the `const` helpers the Preact modules (notebook.js) need: ES modules can't see a
// classic script's lexical `const` globals — only `var`/`function` globals become window
// properties. So ONLY the consts go here (the functions are already on window). `editors`/
// `charts`/`srcMap` are shared by reference, so the module's mutations stay in sync. (All of
// these are defined in core.js or earlier in view.js, so they exist when this runs.)
Object.assign(window, { editors, charts, srcMap, mdHtml, srcEditHTML, srcEditInner, bindsInner, hasBinds });

