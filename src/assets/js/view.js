// Inner markup for one bound control. `bindId` is the *defining* bind cell's id
// (the /api/bind POST target); `b` is its spec ({name,widget,params,value}). Used
// by both the standalone @bind cell and any cell's control strip — wherever a
// widget renders, changing it drives recompute the same way.
const _esc = s => window.slateEscHtml(s);
// Is this page an APP? Read from the bootstrap object the server injects into <head>, NOT from
// `body.app` — that class is added by appmode.js on DOMContentLoaded, while a state can render
// before then. Anything here that asks "am I an app?" before that moment would get `false` and act
// like an authoring page (see the `<title>` it used to overwrite in updateChrome).
const _APPMODE = !!(window.__SLATE_APP__ && window.__SLATE_APP__.on);
const _showVal = v => Array.isArray(v) ? v.join(', ') : v;
// Order-independent key for a control's value — used by the stale-echo guard so an in-flight
// server echo (which may reorder a multi-select) can't reset a control the user just changed.
const _valKey = v => Array.isArray(v) ? JSON.stringify([...v].map(String).sort()) : String(v);
// Normalize a widget option: a bare value becomes {value, label:String(value)}; an object passes through.
const _normOpt = o => (o && typeof o === 'object') ? o : { value: o, label: String(o) };
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
  // Same for return-value component OUTPUTS (`slate_render`): a `.slatecomponent` placeholder rendered
  // before this kind registered now gets wired (wireOutputComponent re-reads its descriptor + matches kind).
  document.querySelectorAll('.slatecomponent').forEach(el => {
    try { if (!el._customWired) wireOutputComponent(el); } catch (e) { console.error(e); }
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

// Package-declared front-end scripts (`nbState.frontendScripts` = [{id, js, esm, kind}], from the worker's
// SlateExtensionsBase manifest — `register_component!`/`register_widget!` in a module `__init__`). Inject each
// ONCE (deduped by id across the session), with no boot cell. Three shapes:
//   • kind set  → a COMPONENT module: import its `export default` from a blob URL and register it under the
//                 (namespaced) kind via the widget SDK. The author's JS never names the kind.
//   • esm only  → a self-registering ES module (e.g. an editor extension that imports + calls a global).
//   • classic   → a self-registering `<script>` (calls `window.slateRegisterWidget(...)`).
// A re-declaration keeps the same id → not re-run here (the registry replaces on the Julia side; a reload
// re-runs from a clean page). Already-mounted controls are re-wired by slateRegisterWidget itself.
// ES module specifiers the page can resolve (`nbState.moduleImports` = {specifier: url}) — a package's
// `provide_import!` merged under the notebook's `@use`. The served <head> carries whatever was known
// when the page was served, but a package declares its imports when it LOADS — after that. So the
// first `using SomeExtension` on a fresh page would leave its specifiers unresolvable, and its
// component module would fail to import them, until a reload.
//
// The HTML spec allows MULTIPLE import maps: they merge, and one appended later applies to any
// specifier not already resolved. That's exactly this case — every entry we add here is a specifier
// nothing has imported yet — so the map can be extended at runtime the same way a front-end script
// is injected at runtime. An inline import map takes effect synchronously on insertion, so the
// module scripts appended right after this call already resolve against it.
//
// Only ADDING is possible: a specifier already in the document keeps its URL (the spec ignores a
// redefinition, and something may already have resolved it), so a package that CHANGES a URL it
// previously declared needs a reload. A browser supporting only one import map ignores the append
// and behaves as before — the entries are in the served <head> on the next load either way.
window._slateImports = null;                    // specifiers the document already declares; seeded on first use
function applyPackageImports(state) {
  const want = (state && state.moduleImports) || null;
  if (!want) return;
  if (!window._slateImports) {
    window._slateImports = new Set();
    document.querySelectorAll('script[type="importmap"]').forEach(s => {
      try { Object.keys((JSON.parse(s.textContent) || {}).imports || {}).forEach(k => window._slateImports.add(k)); }
      catch (e) { console.error('unparseable import map on the page', e); }
    });
  }
  const add = {};
  for (const spec of Object.keys(want)) if (!window._slateImports.has(spec)) add[spec] = want[spec];
  if (!Object.keys(add).length) return;
  try {
    const s = document.createElement('script');
    s.type = 'importmap';
    s.textContent = JSON.stringify({ imports: add });
    document.head.appendChild(s);
    Object.keys(add).forEach(k => window._slateImports.add(k));
  } catch (e) { console.error('import map append failed', e); }
}

window._slateFEInjected = window._slateFEInjected || new Set();
function injectFrontendScripts(state) {
  const list = (state && state.frontendScripts) || [];
  for (const fe of list) {
    if (!fe || !fe.id || !fe.js || window._slateFEInjected.has(fe.id)) continue;
    window._slateFEInjected.add(fe.id);
    try {
      const s = document.createElement('script');
      s.dataset.slateFe = fe.id;
      if (fe.kind) {
        const url = URL.createObjectURL(new Blob([fe.js], { type: 'text/javascript' }));  // module import honors the importmap
        s.type = 'module';
        // The whole namespace, not just the default export: a module's optional `exportFigure` (print
        // rendering — see registerComponent in slate-widget.js) rides along without a second import.
        s.textContent =
          'import C, * as M from ' + JSON.stringify(url) + ';\n' +
          'import { registerComponent } from "@slate/widget";\n' +
          'registerComponent(' + JSON.stringify(fe.kind) + ', C, M);';
      } else {
        if (fe.esm) s.type = 'module';
        s.textContent = fe.js;
      }
      document.head.appendChild(s);
    } catch (e) { console.error('frontend script inject failed (' + fe.id + ')', e); }
  }
}

function controlMarkup(bindId, b) {
  const p = b.params || {}, w = b.widget;
  const a = `data-bind="${bindId}" data-name="${b.name}" data-widget="${w}"`;
  // Options are {value,label} (a bare value normalizes to value===label). The browser carries the
  // stringified VALUE in each option's `value` attr; the LABEL is what's shown (rich for radio).
  const opts = (p.options || []).map(o => _normOpt(o));
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
// The distinct set of run-locations across the notebook's cells.
function _cellRegionSet() {
  const cs = (window.__slateState || {}).cells || [];
  const s = new Set();
  for (const c of cs) { const l = _cellRunLoc(c); if (l) s.add(l.key); }
  return s;
}
// The region chip for a cell header — a coloured 🖧 <name> for cells on a region/remote host (colour
// matches the DAG region overlay), a subdued 💻 local for main-kernel cells. Untagged code cells
// reflect the notebook's default worker (so a remotely-placed notebook reads the home region, not
// "local"); untagged markdown shows nothing. Clicking opens the 🏷 Run-on picker.
//
// The chip is hidden only when the notebook runs entirely on the MAIN KERNEL — the one case where it
// would say the same redundant thing on every cell. A notebook that runs entirely on one region is
// not that case: where the work happens is then the most surprising thing about it, and suppressing
// the chip leaves nothing on screen saying it left this machine.
// The server sends a CODE for why a cell is waiting; the words are here. An unknown code shows as
// itself rather than as nothing, so a new one is visible instead of silently blank.
const BLOCKED_TEXT = { queued: 'queued', not_signed_in: 'not signed in' };
function blockedText(c) {
  const code = (c && c.blocked) || '';
  return BLOCKED_TEXT[code] || code.replace(/_/g, ' ');
}

function cellRegionChip(c) {
  const set = _cellRegionSet();
  const blocked = !!(c && c.state === 'blocked' && c.blocked);
  if (!blocked && set.size < 2 && set.has('local')) return '';
  const loc = _cellRunLoc(c);
  if (!loc) return '';
  // A cell WAITING wears the same chip in the same place, recoloured, with the status after the
  // name. Where it runs and whether it is running are one fact about one cell; splitting them into
  // two pills at opposite ends of the header made the reader hunt for the half that matters.
  if (blocked) {
    const w = _blockedWaited(c);
    // `data-bkey` is what the header patch compares against, so a chip that is already correct is
    // left ALONE. Replacing it needlessly destroys the node between mousedown and mouseup, which
    // swallows the click — the chip is also a button.
    return `<span class="cregion blocked" data-bkey="${_esc(_blockedKey(c))}"` +
      ` data-at="${+(c.blockedAt) || 0}" data-reg="${_esc(loc.name || '')}"` +
      ` onmouseenter="window.blockInfo(this,'${c.id}')" onmouseleave="window.blockInfoHide()"` +
      ` onmousedown="window.openRegionPanel('${c.id}', event)">${loc.local ? '💻' : '🖧'} ${_esc(loc.name || 'local')}` +
      ` <span class="cregst">${_esc(blockedText(c))}${w ? ` <span class="blockwait">${w}</span>` : ''}</span></span>`;
  }
  // `onmousedown`, not `onclick`: clicking a header selects the cell, which re-renders it and
  // replaces this node before mouseup — so the click event is never delivered here and the first
  // click appears to do nothing. Opening on mousedown runs before the node can be taken away.
  if (loc.local) return `<span class="cregion local" onmousedown="window.openRegionPanel('${c.id}', event)" title="runs on the main kernel (this notebook’s home) — click to change">💻 local</span>`;
  // A cell's chip says where it runs; whether that place is REACHABLE is the other half of the same
  // fact, and the topbar pill was carrying it alone. A chip that reads the same when the worker is
  // gone as when it is healthy makes you look somewhere else to find out.
  const hue = (typeof _dagRegionHue === 'function' && _dagRegionHue(loc.name)) || '#8a90a8';
  const cls = _regChipStatus(loc.name);
  return `<span class="cregion${cls.cls}" data-reg="${_esc(loc.name)}"` +
    (cls.cls ? '' : ` style="color:${hue};border-color:${hue}"`) +
    ` onmousedown="window.openRegionPanel('${c.id}', event)"` +
    ` title="${_esc(cls.title || ('runs on ‘' + loc.name + '’ — click for the region'))}">🖧 ${_esc(loc.name)}` +
    (cls.word ? ` <span class="cregst">${_esc(cls.word)}</span>` : '') + '</span>';
}

// How a region's worker is doing, for the chip. Read from the shared model, so the chip, the topbar
// pill and the worker popup cannot disagree about the same worker.
//
// `none` means the model has not heard about this region yet (a first render before the worker list
// arrives), which is NOT the same as trouble — it stays a plain chip rather than flashing an alarm
// on every page load.
function _regChipStatus(name) {
  const M = window.slateModel, w = M.getWorker(name);
  const st = M.workerStatus(w);
  if (!w || st === 'ok' || st === 'none') return { cls: '', word: '', title: '' };
  // The server names the wait when it knows it ("queued" for a scheduler region, "no worker" for one
  // nothing has started). Otherwise the status word is the honest short answer.
  const word = w.face || st;
  return {
    cls: st === 'degraded' ? ' degraded' : ' unwell',
    word: word,
    title: 'runs on ‘' + name + '’ — ' + (w.note || word) + ' (click for the region)',
  };
}

// Repaint the chips when the worker list changes, without re-rendering every cell. The pills already
// update on that push; the chips are the same fact in a different place and were only catching up on
// the next full state render.
window.refreshRegionChips = function () {
  document.querySelectorAll('#nb .cregion[data-reg]:not(.blocked)').forEach(el => {
    const name = el.getAttribute('data-reg') || '';
    const s = _regChipStatus(name);
    el.classList.toggle('degraded', s.cls === ' degraded');
    el.classList.toggle('unwell', s.cls === ' unwell');
    if (s.cls) el.removeAttribute('style');
    else if (!el.getAttribute('style')) {
      const hue = (typeof _dagRegionHue === 'function' && _dagRegionHue(name)) || '#8a90a8';
      el.setAttribute('style', `color:${hue};border-color:${hue}`);
    }
    if (s.title) el.title = s.title;
    let st = el.querySelector('.cregst');
    if (!s.word) { st && st.remove(); return; }
    if (!st) { st = document.createElement('span'); st.className = 'cregst'; el.appendChild(document.createTextNode(' ')); el.appendChild(st); }
    if (st.textContent !== s.word) st.textContent = s.word;
  });
};

// ── Cell kinds ────────────────────────────────────────────────────────────────────────────────
// The ONE description of what a cell can be — read by the kind switcher in every cell header, and
// by the insert menu in the gaps between cells. Two lists would drift, and a kind whose glyph means
// one thing in the header and another in the add menu is worse than no glyph at all.
window.CELL_KINDS = [
  { k: 'code',  glyph: '{·}',   name: 'Code',
    desc: 'Julia that runs and produces a value. Reruns when what it reads changes.' },
  { k: 'md',    glyph: 'M↓',    name: 'Markdown',
    desc: 'Prose, headings and maths. `{{ … }}` interpolates live values.' },
  { k: 'web',   glyph: '</>',   name: 'Web',
    desc: 'HTML, CSS and JS panes. The cell owns its output and can call back into Julia.' },
  { k: 'tool',  glyph: '⌁',     name: 'Tool call',
    desc: 'A call OUT of the notebook. Never runs on open — it has effects in the world.' },
  { k: 'sweep', glyph: '🛰',    name: 'Batch sweep',
    desc: 'A parameter grid fanned out to a cluster. Resumable, watchable, never blocks.' },
];
window.kindOf = k => window.CELL_KINDS.find(x => x.k === k) || window.CELL_KINDS[0];

// The cell's current kind, as a button. Names itself rather than offering the alternatives, so the
// header answers "what is this?" at rest and only costs a click when you want to change it.
function kindButton(c) {
  const cur = window.kindOf(c.kind);
  return `<button class="kindbtn" onclick="openKindPicker('${c.id}', event)"
    title="cell type: ${_esc(cur.name)} — click to change">${_esc(cur.glyph)}</button>`;
}

// One row per kind: a large glyph, the name, and what the kind is FOR. The description is the point
// — five one-character glyphs are indistinguishable, and the difference between a tool call and a
// sweep is a sentence, not a picture.
window.kindRow = (x, current, dataKind) =>
  `<button class="kindrow${current ? ' on' : ''}"${dataKind ? ` data-kind="${x.k}"` : ''}>
     <span class="kindrow-glyph">${_esc(x.glyph)}</span>
     <span class="kindrow-text"><span class="kindrow-name">${_esc(x.name)}${current ? ' <em>· current</em>' : ''}</span>
       <span class="kindrow-desc">${_esc(x.desc)}</span></span>
   </button>`;

// Keep a floating panel on screen: anchored under an element, or at a point (the add menu opens at
// the cursor). Clamped both ways so a picker opened near an edge is never half off it.
window.placePop = function (pop, anchor, x, y) {
  const vw = window.innerWidth, vh = window.innerHeight, EDGE = 8, GAP = 6;
  const r = anchor ? anchor.getBoundingClientRect()
                   : { left: x, right: x, top: y, bottom: y };
  const h = pop.offsetHeight, w = pop.offsetWidth;
  const top = (h <= vh - r.bottom - GAP - EDGE) ? r.bottom + GAP
            : (h <= r.top - GAP - EDGE)         ? r.top - GAP - h
            : Math.max(EDGE, vh - EDGE - h);
  pop.style.top = Math.round(Math.max(EDGE, Math.min(top, vh - EDGE - h))) + 'px';
  pop.style.left = Math.round(Math.max(EDGE, Math.min(r.left, vw - EDGE - w))) + 'px';
};

window.openKindPicker = function (id, ev) {
  ev && ev.stopPropagation();
  const c = ((window.__slateState || {}).cells || []).find(x => x.id === id);
  if (!c) return;
  let pop = document.getElementById('kindpop');
  if (!pop) {
    pop = document.createElement('div');
    pop.id = 'kindpop';
    pop.className = 'kindpop';
    document.body.appendChild(pop);
    document.addEventListener('mousedown', e => {
      if (!e.target.closest('#kindpop') && !e.target.closest('.kindbtn')) closeKindPicker();
    });
    document.addEventListener('keydown', e => { if (e.key === 'Escape') closeKindPicker(); });
  }
  if (pop.classList.contains('show') && pop.dataset.cell === id) return closeKindPicker();
  pop.dataset.cell = id;
  pop.innerHTML = '<div class="kindpop-head">Cell type</div>' +
    window.CELL_KINDS.map(x => window.kindRow(x, x.k === c.kind, x.k)).join('');
  pop.querySelectorAll('[data-kind]').forEach(b => {
    b.onclick = () => {
      closeKindPicker();
      if (b.dataset.kind !== c.kind) window.toggleType(id, b.dataset.kind);
    };
  });
  pop.classList.add('show');
  window.placePop(pop, ev && ev.target.closest('button'));
};
function closeKindPicker() {
  const p = document.getElementById('kindpop');
  if (p) p.classList.remove('show');
}

// A sweep cell's compute target, named in its header — the sibling of `cellRegionChip`, and for the
// same reason: WHERE a cell's work happens is not a setting you go looking for, it is something you
// need to see while reading. A chip rather than an icon because the answer is a NAME; an icon would
// mean clicking every sweep cell to find out where it goes.
//
// Unconfigured reads as an invitation, not an error: a sweep cell with no target is the normal state
// of a cell you just added, and "set a cluster" says what to do about it.
function cellClusterChip(c) {
  if (c.kind !== 'sweep') return '';
  const tags = c.tags || [];
  const get = k => { const t = tags.find(x => x.startsWith(k + '=')); return t ? t.slice(k.length + 1) : ''; };
  const name = get('cluster');
  if (!name) {
    return `<span class="cregion cluster unset" onclick="openSweepConfig('${c.id}', event)"
      title="this sweep has no compute target — click to pick one">＋ set cluster</span>`;
  }
  const defs = (window.__slateState || {}).clusters || [];
  const def = defs.find(x => x.name === name);
  // Overrides are shown, not hidden behind the chip: a cell running at a different walltime or on a
  // different partition from its cluster is exactly the cell whose header should say so.
  const over = ['partition', 'walltime', 'cpus', 'mem', 'gpus', 'nodes', 'chunk']
    .map(k => get(k)).filter(Boolean);
  const label = _esc(name) + (over.length ? ' · ' + _esc(over.join(' · ')) : '');
  const missing = !def;
  const tip = missing
    ? `no cluster named ‘${name}’ is defined in this notebook — click to fix`
    : `runs on ‘${name}’` + (over.length ? ` (overridden here: ${over.join(', ')})` : '') +
      ' — click to change';
  return `<span class="cregion cluster${missing ? ' missing' : ''}${over.length ? ' over' : ''}"
    onclick="openSweepConfig('${c.id}', event)" title="${_esc(tip)}">${label}</span>`;
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
// Interim stored-render badge: this cell's output is the last SAVED render (a figure/table/rich
// output from a prior session), shown AT FULL FIDELITY while the live env boots and the cell
// recomputes — so the notebook springs to life on open instead of showing blanks. `c.previewStale`
// means the cell's source changed since the snapshot (so the figure may be out of date). The badge
// clears the instant the live `celldone:` replaces the cell.
function _previewBadge(c) {
  if (!c.preview) return '';
  const stale = c.previewStale;
  const tip = stale
    ? 'stored render — the cell’s source changed since this was saved, so it may be out of date; recomputing…'
    : 'stored render — the last saved figure, shown while this cell recomputes';
  return `<span class="previewbadge${stale ? ' stale' : ''}" title="${_esc(tip)}">🖼 ${stale ? 'stored · stale' : 'stored'}</span>`;
}
// `locked` cell tag: frozen against upstream/reload churn, only a manual ▶ moves it — shown next to
// the memo badge since it's the same "what determines this cell's cached state" question at a glance.
function _lockBadge(c) {
  if (!c.tags || !c.tags.includes('locked')) return '';
  return `<span class="lockbadge" title="locked — frozen against upstream changes and reload; only ▶ re-runs it (its memo is kept)">🔒</span>`;
}
// Cell-effects badge: this cell DECLARED an effect to Slate via the code→Slate channel (`slate_effect` /
// a package's registrar). `c.effects` is [{kind,names,stmt}] (see cell_json). e.g. an `:everywhere` op
// registration Slate re-establishes on every region worker. Compact glyph + the registered names; the
// hover lists every declaration and the statement that made it — a "what did this cell do to Slate" peek.
// Declarations that are Slate talking to ITSELF are not a "what did this cell do" fact and do not
// earn a badge. `value_identity` is a sweep telling the hub what its results currently are, so a
// reader's memo key moves when they land; it named a mechanism nobody can act on, on every sweep
// cell. `everywhere` stays, because a package registering an op on every region worker is something
// the reader's notebook genuinely does.
const _EFFECT_SILENT = ['value_identity'];

function _effectBadge(c) {
  const eff = (c.effects || []).filter(e => !_EFFECT_SILENT.includes(e.kind));
  if (!eff.length) return '';
  const names = [...new Set([].concat(...eff.map(e => e.names || [])))];
  const everywhere = eff.some(e => e.kind === 'everywhere');
  const label = everywhere ? 'everywhere' : (eff[0].kind || 'effect');
  const shown = names.length ? ' · ' + names.join(', ') : '';
  const tip = 'declares to Slate:\n' + eff.map(e =>
    '• ' + (e.kind === 'everywhere' ? 'everywhere' : e.kind) +
    ((e.names && e.names.length) ? ' · ' + e.names.join(', ') : '') +
    (e.stmt ? '\n    ' + e.stmt : '')).join('\n');
  return `<span class="effectbadge" title="${_esc(tip)}">⚙ ${_esc(label + shown)}</span>`;
}
function cellHeaderInner(c) {
  const isCode = (c.kind === 'code' || c.kind === 'web' || c.kind === 'tool' || c.kind === 'sweep') && !hasBinds(c);   // web/tool/sweep cells run too (▶)
  // ✎ edit source — on EVERY cell. md/@bind hide their source behind a rendered view, so it reveals the
  // source overlay; code/web edit inline, so it just focuses the editor (see editCellSource). NOT </> —
  // that's the "convert to web cell" glyph below, and both show on a @bind cell, so a shared icon would
  // read as the same action.
  const editSrc = `<button onclick="editCellSource('${c.id}','${c.kind}')" title="edit source">✎</button>`;
  const run = isCode ? `<button class="run" data-run="${c.id}" onclick="runCell('${c.id}', true)" title="run this cell (always re-evaluates; ⇧⏎ runs only if changed)">▶</button>` : '';
  const bu = surfaceableNames(c);
  const _present = new Set([].concat(...((c.controls || []).map(col => col.map(s => s.name)))));
  const _someOn = bu.some(n => _present.has(n));
  const autoctl = bu.length
    ? `<button class="autoctl${_someOn ? ' on' : ''}" onclick="openControlPicker('${c.id}', event)" title="pick which @bind controls to surface on this cell (${bu.join(', ')})">🎛</button>` : '';
  // Extension-contributed toolbar buttons (slateRegisterCellAction). Each visible action becomes a
  // <button> in the action strip; the handler is looked up by id at click time (_slateRunCellAction).
  const cellActions = (window._slateCellActions || [])
    .filter(a => { try { return a.show ? !!a.show(c) : true; } catch (e) { return false; } })
    .map(a => `<button class="cellact cellact-${_esc(a.id)}" onclick="_slateRunCellAction('${_esc(a.id)}','${c.id}',event)" title="${_esc(a.title || '')}">${a.icon || '•'}</button>`)
    .join('');
  return '<span class="drag" draggable="true" title="drag to reorder">⠿</span>' +
    `<button class="collapse" onclick="toggleCollapse('${c.id}')" title="collapse / expand">${c.collapsed ? '▸' : '▾'}</button>` + run +
    `<span class="cid" title="double-click to rename">${c.id}</span>` +
    // Mode marker. Always emitted, shown by CSS only while the cell carries `.editing`, so it costs
    // no plumbing through the header's innerHTML and can never disagree with the ring.
    '<span class="editchip" title="edit mode — keys go to the editor; Esc returns to command mode">✎ edit</span>' +
    cellRegionChip(c) +
    cellClusterChip(c) +
    _lockBadge(c) +
    _effectBadge(c) +
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
      // A sweep's SPEC — where it runs and under what limits — is configuration, not code. It gets
      // its own control rather than living in the free-form tag box, because walltime and partition
      // are what you change while a job is queued or after it was killed.
      `<button class="tagbtn${(c.tags && c.tags.length) ? ' on' : ''}" onclick="openTagEditor('${c.id}', event)" title="cell tags${(c.tags && c.tags.length) ? ': ' + c.tags.join(', ') : ''}">🏷</button>` +
      editSrc +
      `<button onclick="moveCell('${c.id}','up')" title="move up">↑</button>` +
      `<button onclick="moveCell('${c.id}','down')" title="move down">↓</button>` +
      // Kind switch: ONE button naming what this cell IS, opening a picker of what it could be.
      // It used to emit a glyph button per OTHER kind, which was fine at two kinds and unreadable at
      // five — four cryptic marks per cell, and no way to tell `⌁` from `🛰` without clicking one.
      kindButton(c) +
      cellActions +
      `<button class="del" onclick="delCell('${c.id}')" title="delete cell">🗑</button>` +
    '</span>' +
    // Run-info cluster, right-aligned and contiguous (buttons sit to its left): run time (reserved
    // width) · cache verdict (fixed slot) · state badge (fixed width) — so nothing floats mid-header.
    `<span class="cdur">${c.duration != null ? c.duration + ' ms' : ''}</span>` +
    `<span class="previewslot">${_previewBadge(c)}</span>` +
    `<span class="memoslot">${_memoBadge(c)}</span>` +
    `<span class="badge">${c.state}</span>`;
}
// A cell that cannot run YET says so in its header, not in its output. The output area keeps
// whatever the last run produced — a cell waiting on a cluster node has not lost the value it had,
// and painting it red says it has.
//
// The elapsed time is rendered from `blockedAt` by a ticker (below) rather than pushed: a queue wait
// is minutes to hours, and streaming a per-second update for every waiting cell would be traffic
// spent on a clock the page can read itself.
function _blockedWaited(c) {
  const at = +(c && c.blockedAt) || 0;
  if (!at) return '';
  const s = Math.max(0, Math.round(Date.now() / 1000 - at));
  return s < 60 ? s + 's' : s < 3600 ? Math.round(s / 60) + 'm' : (s / 3600).toFixed(1) + 'h';
}
// Everything about a chip that is NOT the ticking elapsed time (which the ticker rewrites in place).
// Two chips with the same key are the same chip, so the header patch can leave one alone.
function _blockedKey(c) {
  if (!c || c.state !== 'blocked' || !c.blocked) return '';
  const l = _cellRunLoc(c);
  return [c.blocked, +(c.blockedAt) || 0, (l && l.key) || ''].join('\x1f');
}
// One timer for the page, not one per cell: it only rewrites the elapsed text, and stops costing
// anything when nothing is waiting.
setInterval(() => {
  document.querySelectorAll('.cregion.blocked[data-at]').forEach(el => {
    const w = _blockedWaited({ blockedAt: +el.dataset.at });
    const slot = el.querySelector('.blockwait');
    if (slot && w && slot.textContent !== w) slot.textContent = w;
  });
}, 5000);

// ── The detail behind a waiting chip ──────────────────────────────────────────────────────────
// A panel rather than a `title`: the browser's tooltip cannot be styled, cannot hold a table, takes
// a second to appear and goes away while you read it. What a person wants here is a small report —
// when it was asked for, how long it has waited, and whether the cluster has anything free — and
// none of that fits a tooltip.
let _blkPanel = null, _blkTimer = 0, _blkFor = '';
const _blkLoad = new Map();     // region → {at, data} — a hover is a round trip to a login node
function _blkFmtQ(q) {
  const bits = [`${q.cpus_free}/${q.cpus_total} cpus free`];
  if (q.nodes_total > 0) bits.push(`${q.nodes_free}/${q.nodes_total} nodes`);
  if (q.down > 0) bits.push(`${q.down} down`);
  if (q.queued > 0) bits.push(`${q.queued} job${q.queued === 1 ? '' : 's'} queued`);
  return `<div class="blkq"><span class="blkqn">${_esc(q.name)}</span>${_esc(bits.join(' · '))}</div>`;
}
// The region's host, which the chip does not show — the chip names the REGION, and on a cluster the
// two differ (`pbsnode` is asked for on `slate-pbs`).
function _blkRegHost(reg) {
  const regs = (typeof nbState !== 'undefined' && nbState && nbState.regions) || [];
  const r = regs.find(x => x.name === reg);
  return (r && r.host) || '';
}
// Only what the chip has not already said. The chip reads "🖧 pbsnode · queued 2m", so repeating the
// status and the region name at the top of the panel spends the first line saying nothing.
function _blkRender(c, reg, load) {
  const at = +(c.blockedAt) || 0;
  const when = at ? new Date(at * 1000).toLocaleTimeString() : '';
  // `ask` and `eta` ride the same round trip as the capacity, so they appear when it does.
  const rows = [], host = _blkRegHost(reg);
  const ask = (load && load.ask) || '', eta = (load && load.rows && load.rows.length && load.rows[0].eta) || '';
  if (host) rows.push(`<div class="blkrow"><span>Host</span><div>${_esc(host)}</div></div>`);
  if (ask) rows.push(`<div class="blkrow"><span>Asked for</span><div>${_esc(ask)}</div></div>`);
  if (at) rows.push(`<div class="blkrow"><span>Requested</span><div>${_esc(when)} · ${_esc(_blockedWaited(c))} ago</div></div>`);
  if (eta) rows.push(`<div class="blkrow"><span>Starts</span><div>~${_esc(eta)}</div></div>`);
  const qs = load && load.rows;
  if (load === undefined) rows.push('<div class="blkrow blkdim"><span>Cluster</span><div>asking…</div></div>');
  else if (load === null) rows.push('<div class="blkrow blkdim"><span>Cluster</span><div>no answer</div></div>');
  else if (!qs || !qs.length) rows.push('<div class="blkrow blkdim"><span>Cluster</span><div>nothing reported</div></div>');
  else rows.push('<div class="blkrow blkq1"><span>Cluster</span><div>' + qs.map(_blkFmtQ).join('') + '</div></div>');
  return rows.join('');
}
window.blockInfo = function (el, id) {
  clearTimeout(_blkTimer);
  const c = ((window.__slateState || {}).cells || []).find(x => x.id === id);
  if (!c) return;
  const reg = el.dataset.reg || '';
  if (!_blkPanel) { _blkPanel = document.createElement('div'); _blkPanel.className = 'blkpanel'; document.body.appendChild(_blkPanel); }
  _blkFor = id;
  const cached = _blkLoad.get(reg);
  const fresh = cached && (Date.now() - cached.at < 15000);
  _blkPanel.innerHTML = _blkRender(c, reg, fresh ? cached.data : undefined);
  const r = el.getBoundingClientRect();
  _blkPanel.style.left = Math.round(Math.min(r.left, window.innerWidth - 340)) + 'px';
  _blkPanel.style.top = Math.round(r.bottom + 6) + 'px';
  _blkPanel.classList.add('on');
  if (!reg || fresh) return;
  fetch('/api/region-load?region=' + encodeURIComponent(reg))
    .then(r => r.json())
    .then(j => {
      const data = { ask: (j && j.ask) || '', rows: (j && j.ok && j.queues) || [] };
      _blkLoad.set(reg, { at: Date.now(), data });
      if (_blkFor === id && _blkPanel && _blkPanel.classList.contains('on')) _blkPanel.innerHTML = _blkRender(c, reg, data);
    })
    .catch(() => { if (_blkFor === id && _blkPanel) _blkPanel.innerHTML = _blkRender(c, reg, null); });
};
// A short grace period, so moving the pointer across the chip's own border doesn't flicker it.
window.blockInfoHide = function () {
  clearTimeout(_blkTimer);
  _blkTimer = setTimeout(_blkOff, 180);
};
function _blkOff() {
  clearTimeout(_blkTimer);
  if (_blkPanel) _blkPanel.classList.remove('on');
  _blkFor = '';
}
// Close it NOW, with no grace period, when the thing it describes stops existing. A chip that is
// removed or replaced never fires `mouseleave`, so the ordinary hide never runs and the panel is
// left on screen with no way to dismiss it. That happens on the most ordinary transition there is:
// the node is granted, the cell stops waiting, and the chip is rebuilt underneath the pointer.
window.blockInfoDrop = function (id) { if (!id || _blkFor === id) _blkOff(); };
// The panel is position:fixed and anchored to where the chip was, so a scroll would slide it away
// from its chip and leave it floating over unrelated cells.
addEventListener('scroll', () => { if (_blkFor) _blkOff(); }, { passive: true, capture: true });
// Last line of defence: whatever else happens, a panel whose cell is no longer waiting goes away.
setInterval(() => {
  if (!_blkFor) return;
  const c = ((window.__slateState || {}).cells || []).find(x => x.id === _blkFor);
  if (!c || c.state !== 'blocked') _blkOff();
}, 2000);
// ── The region panel (click on a cell's region chip) ──────────────────────────────────────────
// Clicking the chip used to open the generic tag editor, which answers "what tags does this cell
// carry" when the question the chip raises is "what is this region and what is it doing". This
// panel answers that one: the host behind the region name, what it asks the scheduler for, the
// allocation it holds, and how busy the cluster is. Plus the one control that belongs on a cell,
// which is where the cell runs. Worker actions stay in Remotes, where the roster is.
let _regPanel = null, _regFor = '';
function _regRow(label, value) {
  return value ? `<div class="blkrow"><span>${_esc(label)}</span><div>${_esc(value)}</div></div>` : '';
}
// `held` is the server's answer, not this panel's guess. `ok` only ever meant "the scheduler could be
// asked", and reading it as "there is an allocation" is what left a Release button on a row saying
// `none` after the node had already gone back.
function _regAlloc(a, reg) {
  const M = window.slateModel;
  if (a === undefined) return '<div class="blkrow blkdim"><span>Allocation</span><div>asking…</div></div>';
  if (!a || !a.ok) return '<div class="blkrow blkdim"><span>Allocation</span><div>unavailable</div></div>';
  if (!M.isHeld(a)) return '<div class="blkrow blkdim"><span>Allocation</span><div>none held</div></div>';
  const bits = [a.state || '', a.node || '', a.id ? '#' + a.id : '', a.timeleft ? a.timeleft + ' left' : ''];
  // Releasing belongs next to the allocation it names. It bills for the time it is HELD, so the
  // control has to be where you read that you are holding one, not one page away in Remotes.
  return '<div class="blkrow"><span>Allocation</span><div>' + _esc(bits.filter(Boolean).join(' · ')) +
         ' <button class="regprel" onclick="window.releaseRegionAlloc(\'' + _esc(reg) + '\')">' +
         _esc(M.releaseVerb(a)) + '</button></div></div>';
}
// Give the node back now. Confirmed, because anything running on it dies with it.
window.releaseRegionAlloc = async function (reg) {
  const ok = window.confirmDark ? await window.confirmDark(
    'Release the node held for `' + reg + '`?\nIts workers are reaped and anything running on them stops.',
    'Release', 'danger') : window.confirm('Release the node held for ' + reg + '?');
  if (!ok) return;
  try {
    await fetch('/api/allocation/release', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                             body: JSON.stringify({ region: reg }) });
    window.slateModel.refreshAllocation(reg);   // and every other view reading it follows
  } catch (_) {}
  if (typeof closeRegionPanel === 'function') closeRegionPanel();
};
// Where this cell runs, changeable here. The rest of the tag surface stays on the 🏷 button; a
// region is the one tag with a reason to be edited from the header.
function _regPicker(c, reg) {
  const regs = (typeof nbState !== 'undefined' && nbState && nbState.regions) || [];
  const opts = ['', ...regs.map(r => r.name)];
  const sel = opts.map(n =>
    `<option value="${_esc(n)}"${n === reg ? ' selected' : ''}>${n ? _esc(n) : 'local (main kernel)'}</option>`).join('');
  return `<div class="blkrow"><span>Runs on</span><div>` +
         `<select class="regpick" onchange="window.setCellRegion('${c.id}', this.value)">${sel}</select></div></div>`;
}
// The region's definition as the notebook knows it, or null for the main kernel.
function _regDef(reg) {
  const regs = (typeof nbState !== 'undefined' && nbState && nbState.regions) || [];
  return regs.find(x => x.name === reg) || null;
}
const _regIsCluster = reg => { const r = _regDef(reg); return !!(r && r.scheduler && r.scheduler !== 'none'); };
// ONE panel for every kind of run location. The rows a cluster needs (what it asks the scheduler
// for, the allocation it holds, how busy the queue is) are meaningless on an ordinary host and
// absent there; everything else is the same panel.
function _regRender(c, reg, load, alloc) {
  const r = _regDef(reg);
  let h = `<div class="regphead">${reg ? '🖧 ' + _esc(reg) : '💻 local'}</div>`;
  if (!reg) {
    h += _regRow('Kernel', 'this notebook’s own worker, on this machine');
  } else {
    h += _regRow('Host', _blkRegHost(reg));
    h += _regRow('Transport', r && r.transport);
    h += _regRow('Data root', r && r.root);
    h += _regRow('Preload', r && r.preload);
    if (!r || !r.defined) h += _regRow('Note', 'this cell names a region that is not defined');
    else if (_regIsCluster(reg)) {
      h += _regRow('Scheduler', r.scheduler);
      h += _regRow('Asked for', (load && load.ask) || '');
      h += _regAlloc(alloc, reg);
      const qs = load && load.rows;
      if (load === undefined) h += '<div class="blkrow blkdim"><span>Cluster</span><div>asking…</div></div>';
      else if (!qs || !qs.length) h += '<div class="blkrow blkdim"><span>Cluster</span><div>nothing reported</div></div>';
      else h += '<div class="blkrow blkq1"><span>Cluster</span><div>' + qs.map(_blkFmtQ).join('') + '</div></div>';
    } else {
      h += _regRow('Warm workers', String((r.warm | 0) || 0));
    }
  }
  h += _regPicker(c, reg);
  h += `<div class="regpfoot"><a href="/#remotes">Manage regions and workers in Remotes</a></div>`;
  return h;
}
window.setCellRegion = function (id, name) {
  const keep = (typeof _curTags === 'function' ? _curTags(id) : []).filter(t => !t.startsWith('region='));
  if (typeof setTags === 'function') setTags(id, name ? [...keep, 'region=' + name] : keep);
  _regClose();
};
function _regClose() { if (_regPanel) _regPanel.classList.remove('on'); _regFor = ''; }
window.openRegionPanel = function (id, ev) {
  // Stopping here also keeps the click from selecting the cell, which is what was re-rendering the
  // header out from under the pointer.
  if (ev) ev.stopPropagation();
  if (_regFor === id) { _regClose(); return; }        // clicking the same chip again puts it away
  const c = ((window.__slateState || {}).cells || []).find(x => x.id === id);
  if (!c) return;
  const loc = _cellRunLoc(c);
  if (!loc) return;                       // untagged markdown executes nowhere
  const reg = loc.local ? '' : loc.name;  // '' is the main kernel, which the panel describes too
  if (!_regPanel) { _regPanel = document.createElement('div'); _regPanel.className = 'regpanel'; document.body.appendChild(_regPanel); }
  _regFor = id;
  const cached = reg ? _blkLoad.get(reg) : null, fresh = cached && (Date.now() - cached.at < 15000);
  _regPanel.innerHTML = _regRender(c, reg, fresh ? cached.data : undefined, undefined);
  const anchor = (ev && ev.currentTarget) || document.querySelector(`#cell-${id} .cregion`);
  const r = anchor.getBoundingClientRect();
  _regPanel.classList.add('on');
  const w = _regPanel.offsetWidth, hh = _regPanel.offsetHeight;
  _regPanel.style.left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8)) + 'px';
  _regPanel.style.top = Math.min(r.bottom + 6, window.innerHeight - hh - 8) + 'px';
  // Only a scheduler region has an allocation or a queue to report, and each answer costs a command
  // on its login node — so an ordinary host and the main kernel ask for nothing.
  if (!_regIsCluster(reg)) return;
  const paint = (l, a) => { if (_regFor === id) _regPanel.innerHTML = _regRender(c, reg, l, a); };
  let L = fresh ? cached.data : undefined, A;
  if (!fresh) fetch('/api/region-load?region=' + encodeURIComponent(reg)).then(r => r.json())
    .then(j => { L = { ask: (j && j.ask) || '', rows: (j && j.ok && j.queues) || [] };
                 _blkLoad.set(reg, { at: Date.now(), data: L }); paint(L, A); })
    .catch(() => paint(null, A));
  // Through the shared cache, so releasing from the Remotes roster invalidates what this panel would
  // otherwise still be holding. Forced: opening the panel is the moment you want the current answer,
  // and this is also the call that reconciles the hub against the scheduler.
  window.slateModel.refreshAllocation(reg).then(j => { A = j; paint(L, A); })
    .catch(() => { A = null; paint(L, A); });
};
addEventListener('mousedown', e => {
  if (!_regFor) return;
  if (!e.target.closest('.regpanel') && !e.target.closest('.cregion')) _regClose();
});
addEventListener('keydown', e => { if (e.key === 'Escape' && _regFor) _regClose(); });

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
      .then(applyAck)
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
// Mount return-value component OUTPUTS: a `slate_render` descriptor {v, component, props} is emitted as a
// `.slatecomponent` placeholder plus a sibling JSON `<script class="slatecomponent-desc">`. Look the
// component up in the widget registry and wire it with the props + a DISPLAY ctx (call/stream, no bind
// value). Distinct from a @bind control — an output component has no `data-bind`. Idempotent per element;
// an as-yet-unregistered component just waits for `slateRegisterWidget` to re-scan (see above).
function wireOutputComponent(el) {
  if (el._customWired) return;
  const scr = el.parentNode && el.parentNode.querySelector('script.slatecomponent-desc');
  if (!scr) return;
  let desc; try { desc = JSON.parse(scr.textContent); } catch (e) { return; }
  const kind = desc && desc.component;
  const reg = kind && window.slateWidgets && window.slateWidgets[kind];
  el.dataset.component = kind || '';
  if (!reg || !reg.wire) return;                       // await registration
  el._customWired = true;
  reg.wire(el, {
    params: (desc && desc.props) || {},
    value: undefined,                                  // a returned value has no bound state
    display: true,
    call: (ch, payload, onProgress) => window.slateCall(String(ch), payload, onProgress),
  });
}
function mountOutputComponents(root) {
  (root || document).querySelectorAll('.slatecomponent').forEach(wireOutputComponent);
}

// Wire every bound widget in a cell — its own @bind widget and/or control strip.
function mountControls(c) {
  const cell = document.getElementById('cell-' + c.id);
  if (!cell) return;
  cell.querySelectorAll('[data-bind]').forEach(wireControl);
  cell.querySelectorAll('.radiogroup, .checkgroup, .mslist').forEach(typeset);   // render rich ($math$) option labels
  mountOutputComponents(cell);                                                   // return-value component outputs
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

// The ✎ "edit source" header button, for ANY cell kind. md / @bind cells render OUTPUT by default and
// keep their source in a hidden `.srcedit` overlay → toggle it. code / web cells show their editor
// inline (no overlay) → just focus it, un-hiding the code first if it was hidden via 🙈.
function editCellSource(id, kind) {
  const cell = document.getElementById('cell-' + id); if (!cell) return;
  if (cell.querySelector('.srcedit')) { toggleSource(id, kind === 'md' ? 'markdown' : 'julia'); return; }
  if (cell.classList.contains('codehidden')) toggleHideCode(id);   // reveal hidden code before focusing
  if (window.ensureEditor) window.ensureEditor(id);                // mount if it hasn't lazily yet
  if (window.edFocus) window.edFocus(id);
}

function editSource(id, mode) {
  const cell = document.getElementById('cell-' + id);
  if (!cell) return;
  const d = _disp(cell); if (d) d.style.display = 'none';
  const sed = cell.querySelector('.srcedit'); sed.style.display = '';
  // A prior cell re-render (a live widget/output refresh — e.g. a Mol* viewer streaming frames) can swap
  // out the .srcedit DOM, detaching the CM6 editor while `editors[id]` still points at it. The first
  // editSource would then reveal the raw, empty, unstyled <textarea> instead of remounting. Drop a stale
  // (detached) editor so the block below remounts it against the current .srcedit.
  if (editors[id] && editors[id].dom && !sed.contains(editors[id].dom)) {
    try { editors[id].destroy(); } catch (_) {}
    delete editors[id];
  }
  if (!editors[id]) {
    const ta = sed.querySelector('textarea'); if (ta) ta.style.display = 'none';   // CM6 mounts a sibling editor
    window.mkEditor(sed, {
      doc: srcMap[id] || '', cellId: id, markdown: mode === 'markdown',
      onDoc: () => { if (!window.slateStore.srcEq(edText(id), srcMap[id] || '')) { setState(id, 'edited'); window._backupSoon && window._backupSoon(); }
                     else window.slateStore.clearEdited(id); },
      onFocus: () => setEditing(id, true), onBlur: () => setEditing(id, false),
      keys: [
        { key: 'Shift-Enter', run: () => commitSource(id) },
        // NO Escape binding here: Escape means the same thing in every editor — leave edit mode,
        // keep the text. (It used to cancelSource, which destroyed the editor and dropped whatever
        // you had typed.) The overlay stays open in command mode; a second Escape collapses it back
        // to rendered via toggleSource, which commits a changed source rather than discarding it.
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
  setEditing(id, false);   // destroying a focused editor fires no blur — leave edit mode explicitly
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
  applyAck(await api('POST', '/api/cell/' + id, { source: src }));   // a receipt now; the push re-renders it
}
function cancelSource(id) {
  setEditing(id, false);   // destroying a focused editor fires no blur — leave edit mode explicitly
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
// Payload recency, per cell. The same cell reaches the browser over TWO transports — the live
// `celldone:`/`refresh:` push and the full state every mutating request answers with — and until each
// payload carried a `rev` the client could only apply whichever arrived last: a redundant re-render
// at best (a second chart animation), an older payload overwriting a newer one at worst. `rev` is
// monotonic per SERVER PROCESS, so "not newer than what I already applied" is always the right test.
//
// Reset on (re)connect: the server may have restarted and taken its counter back to zero with it, and
// a client still holding old highwater marks would then ignore everything it sends.
// Testing and SPENDING a stamp are deliberately separate. A payload can arrive for a cell whose
// element isn't mounted yet, and consuming the stamp there would mark it applied when nothing was
// drawn — leaving that cell blank until its next change. A stamp is spent only where the payload
// actually reaches the DOM.
const _cellRev = {};
function revIsNew(c) {
  if (!c || typeof c.rev !== 'number') return true;   // a server without revs, or a synthetic payload
  const seen = _cellRev[c.id];
  return seen === undefined || c.rev > seen;
}
function revMark(c) { if (c && typeof c.rev === 'number') _cellRev[c.id] = c.rev; }

// Does this cell render anything a reader would see? Drives `.cell-blank`, which the reading view
// collapses so a pure definition cell leaves no gap mid-document. Replaces a `:has()` chain in the
// stylesheet: same question, asked once per cell when its contents change, rather than by the browser
// against every cell on every style recalc.
//
// Answered from the CELL, not from its DOM. A chart paints asynchronously — ECharts sizes itself after
// the render that created its container — so asking the DOM says "nothing here", collapses the cell,
// and a display:none container can never lay out: the chart then never appears at all. The payload
// already knows a chart is coming. (`:has()` got away with it by being live; a class is not.)
//
// A surfaced control does not count: `b.hosted` means the live widget renders in another cell and
// this one shows only a chip. A WORKBOOK cell is never blank — its editor is what the reader came for.
function markBlank(el, c) {
  if (!el || !el.classList) return;
  const has = sel => !!el.querySelector(sel);
  const blank = c
    ? !(el.classList.contains('workbook')
        || c.kind === 'md'
        || /<\w/.test(c.output || '')
        || (c.echarts || []).length
        || (c.tables || []).length
        || (c.animations || []).length
        || (c.controls || []).flat().length
        || (c.binds || []).some(b => !b.hosted))
    // No payload in hand (a caller that only has the element): fall back to the DOM, which is right
    // for everything already painted.
    : !(el.classList.contains('workbook') || has('.md') || has('.output *') || has('.tables *')
        || has('.echarts *') || has('.controls:not(.empty)') || has('.binds > :not(.hostedph)'));
  el.classList.toggle('cell-blank', blank);
}
window.slateMarkBlank = markBlank;
function resetCellRevs() { for (const k in _cellRev) delete _cellRev[k]; }
window.slateRevIsNew = revIsNew;
window.slateRevMark = revMark;
window.slateResetCellRevs = resetCellRevs;

// The receipt from a control change. The response no longer carries the notebook — the live push
// does that — so this is the write's confirmation plus where every cell stood when it answered.
//
// The one thing the old full-state reply gave us for free was cover for a DROPPED push: `celldone`
// is best-effort, and a lost frame simply didn't matter when the response re-sent everything. It
// matters now, so we check: a moment after the ack, any cell whose revision we were told about but
// never applied means a push went missing, and we pull `/state` once to catch up.
//
// The grace period is not a guess about the network — it's the run itself. A control change kicks an
// evaluation, so the revisions in the ack are mid-flight by construction and the pushes that settle
// them arrive over the following moments. Checking immediately would fetch on every interaction and
// give back exactly the payload we just stopped sending.
let _gapTimer = null;
function applyAck(ack) {
  // No `revs` means this was not a receipt: a refusal (a workbook 403 carries an error body) or a
  // transport failure. Nothing to apply either way. There is no full-state fallback because there is
  // no version skew to absorb — the page's scripts are served by the process answering it.
  if (!ack || !ack.revs) return;
  clearTimeout(_gapTimer);
  _gapTimer = setTimeout(async () => {
    // Only cells we have a baseline for. `revIsNew` answers true for a cell never seen, and a
    // revision is stamped only where a payload actually reached the DOM — so most of a freshly
    // loaded document has no stamp, and treating that as evidence of a lost push made every receipt
    // pull the whole document back down. Never stamp here to close that gap: doing it before a cell
    // renders marks it applied when nothing was drawn, and the cell stays blank until it next
    // changes (see `revIsNew`).
    const missing = Object.keys(ack.revs).some(id => _cellRev[id] !== undefined && ack.revs[id] > _cellRev[id]);
    if (!missing) return;
    try { updateStates(await api('GET', '/api/state')); } catch (_) {}   // a push was lost — resync once
  }, 2000);
}
window.slateApplyAck = applyAck;

function patchCells(cells) {
  if (!cells || !cells.length || !nbState) return;
  cells = cells.filter(revIsNew);           // drop anything not newer than what's already applied
  if (!cells.length) return;
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
    // store.js is a module, so it lands after this classic script — fall back until it does. Same
    // comparison, not a second opinion: two divergent copies of this were the whitespace bug.
    const _store = window.slateStore || {};
    const _eqw = _store.srcEq || ((a, b) => (a || '').replace(/\s+$/, '') === (b || '').replace(/\s+$/, ''));
    const _prevSrc = srcMap[nc.id];
    srcMap[nc.id] = nc.source;
    if (editors[nc.id]) {
      const _mine = edText(nc.id);
      if (_eqw(_mine, _prevSrc) && !_eqw(_mine, nc.source)) edSetText(nc.id, nc.source);
    }
    // A cell you're actively editing is YOURS until you resolve: if YOUR unapplied typing still
    // diverges from the incoming source (a live conflict), freeze its source/output/charts — don't
    // let the external run replace what you're looking at. Same rule as notebook.js; the reconcile
    // flow re-applies on accept. An editor merely left open over an agent's edit is NOT a conflict.
    const _conflicted = !!(_store.isDirty && _store.isDirty(nc.id, nc.source));
    const cell = document.getElementById('cell-' + nc.id);
    if (cell) {
      cell.className = cell.className.replace(/\bstate-\S+/, 'state-' + (_conflicted ? 'edited' : nc.state));
      const badge = cell.querySelector('.badge'); if (badge) badge.textContent = _conflicted ? 'edited' : nc.state;
      if (!_conflicted) {
        if (nc.kind === 'md') { const md = cell.querySelector('.md'); if (md) _swapOutput(md, mdHtml(nc), '', () => typeset(md)); }
        else { const out = cell.querySelector('.output'); if (out) _swapOutput(out, nc.output, nc.live, () => typeset(out)); }
      }
    }
    // Every consumer of the payload, not just the ones that existed when this was written:
    // ANIMATIONS were missing, so an `animate(…)` cell patched through here had its stamp spent
    // with the player never mounted — and the Preact effect then skipped it as stale forever. The
    // symptom was an animation that vanished on any edit and came back only on a page reload.
    let _landed = true;
    if (!_conflicted) {
      renderCharts(nc);
      if (!renderTables(nc)) _landed = false;
      if (window.renderAnimation && !window.renderAnimation(nc)) _landed = false;
      syncControlValuesSoon(nc);
    }
    // Spend the stamp only now, only if the cell was actually on the page, and only if everything
    // that had work to do managed it — see `revIsNew`.
    //
    // Not for a CONFLICTED cell either: every write above was skipped for it, so nothing was drawn,
    // and stamping anyway records a payload as applied that never reached the DOM. The reconcile
    // flow's "use the incoming change" re-applies through `patchCells` (restore.js), which
    // `revIsNew` would then reject as stale — leaving the cell showing your old text with no way
    // back.
    //
    // `markBlank` is about how the cell LOOKS, not about the payload, so a render that could not
    // mount its host does not hold it back.
    if (cell && !_conflicted) {
      if (_landed) revMark(nc);
      markBlank(cell, nc);
    }
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
  // A notebook that declares regions will ship this project to one of them on its first run there.
  // If that is large and nobody has said what should stay behind, offer to prune it now — before
  // the transfer is paid for. Checked HERE because this is where the regions become known; it
  // self-limits to one check and opens the graph pane itself when it has something to say.
  window.slateTransferGuard && window.slateTransferGuard();
  if (selectedId && !(state.cells || []).some(c => c.id === selectedId)) selectedId = null;   // dropped/renamed
  applyPackageImports(state);                   // module specifiers those scripts resolve — strictly before them
  injectFrontendScripts(state);                 // package-declared widget/editor scripts (before the re-render)
  window.slateStore && window.slateStore.applyState(state);   // → Preact re-renders #nb reactively
  window.onNbState && window.onNbState(state);                // graph-shaped consumers (DAG panel)
  updateChrome(state);
}
// Raw worker-boot / remote-provision output → the hydrating banner's collapsible "build log" (prepare.js).
// The structured headline (phase, precompile k/N, current package) rides the separate `prepare:` stream;
// this keeps the raw Pkg lines available a click away without dumping resolver churn as the headline.
window.onBringup = function (line) {
  window._prepPushRaw && window._prepPushRaw(line);
};
// Topbar/banner bits that live outside #nb (title, worker dot, vscode link, hydrating banner).
function updateChrome(state) {
  document.getElementById('title').textContent = state.title || 'Notebook';
  // `state.title` is the notebook's FILENAME — an authoring fact ("app.standalone"), and the right
  // thing for a tab you have six of. A deployed app is named by its document, which the server
  // already substituted into <title>; don't overwrite that with the file it happens to live in.
  // (And appmode.js seeds the app BAR from `document.title`, so clobbering it here put the filename
  // at the top of the page as well as in the tab.)
  if (!_APPMODE) {
    document.title = (state.title ? state.title + ' · ' : '') + 'Kaimon Slate';   // browser tab
  }
  const w = state.worker || {}, dot = document.getElementById('wdot');
  if (dot) {
    // Worker dot semantics: green = healthy (worker connected — incl. while a run streams — OR a
    // markdown-only notebook, which has nothing to run and so is trivially healthy), blue = in-process
    // kernel OR the gate worker still BOOTING (hydrating), red = a genuine disconnect of a RUNNABLE
    // notebook only. So a not-yet-connected gate worker shows a "starting" blue pulse during hydration,
    // and an md-only notebook shows green (not the alarming red) — the tooltip says there's no worker.
    const hasCode = (state.cells || []).some(c => c.kind === 'code');
    const cls = state.inactive ? 'inproc'    // dormant BY DESIGN — a calm (blue) dot, never the alarming red
              : w.kind === 'inproc' ? 'inproc'
              : w.connected ? 'up'
              : state.hydrating ? 'inproc busy'
              : hasCode ? 'down'          // a genuine disconnect of a runnable notebook
              : 'up';                     // md-only: nothing to run → healthy (green), never red
    dot.className = 'wdot ' + cls + (_busy > 0 ? ' busy' : '');
    dot.title = state.inactive ? 'inactive — no worker running; click the pill to launch'
              : !hasCode && !w.connected ? 'markdown only — nothing to run'
              : w.kind === 'gate'
              ? ('worker :' + w.port + (w.connected ? ' · connected' : (state.hydrating ? ' · starting…' : ' · disconnected')))
              : 'in-process kernel';
  }
  window.renderRunLoc && window.renderRunLoc(state);   // toolbar run-location pill (session/notebook/global)
  window.renderWorkers && window.renderWorkers(state); // per-region worker pills next to it (click → log/status popup)
  window.renderRunPill && window.renderRunPill();      // error pill reads live state → clears when a cell is fixed/removed
  if (state.path) document.getElementById('vscode').href = 'vscode://file' + state.path;
  const hb = document.getElementById('hydbanner');
  // "run" (the plain initial autorun) gets NO banner — cells are fully interactive and each shows
  // its own running/stale state, exactly like any later manual run; a special top banner just for
  // the FIRST run would be an arbitrary inconsistency now that it's not gating anything. "boot"
  // (cold local worker spawn), "remote" (worker provisioning), and "env" (bundle reconstruction)
  // have no per-cell equivalent — there's no worker yet to show per-cell progress against — so
  // those keep a status banner, narrated live by the same `bringup:` stream in all three cases.
  // An app hides the code cells, so the per-cell running state the "run" case relies on below is
  // invisible to its reader — a cold start reads as a page of headings that does nothing for
  // minutes. There, and only there, the plain autorun gets a banner too.
  const _isApp = _APPMODE;
  if (state.hydrating && (_isApp || state.hydratingKind !== 'run')) {
    hb.className = 'hydbanner'; hb.style.display = 'flex';
    // Short headline per kind — shown only until structured status arrives, then prepare.js hides it so the
    // banner stays compact (the #hydprep line becomes the headline). Specifics (precompile k/N, current
    // package, elapsed) ride #hydprep; raw Pkg output tucks into the collapsed build log.
    // An app's reader is a domain expert, not a Julia user: "worker", "environment" and
    // "reconstructing" name Slate's internals and mean nothing to them. Same states, said plainly.
    const msg = _isApp
        ? (state.hydratingKind === 'run' ? 'Computing…' : 'Starting up — this can take a few minutes the first time…')
      : state.hydratingKind === 'remote'
        ? ('Starting the worker on <b>' + _esc(state.hydratingHost || 'the remote host') + '</b>…')
      : state.hydratingKind === 'boot'
        ? 'Starting the worker…'
        : 'Reconstructing environment…';
    hb.innerHTML = '<span class="hydspin"></span><div class="hydbody">'
      + '<div id="hydmsg" class="hydmsg">' + msg + '</div>'
      + '<div id="hydprep" class="hydprep"></div>'
      + '<details id="hydraw" class="hydraw" style="display:none" ontoggle="window._prepRawToggle&&window._prepRawToggle()"><summary>build log <span id="hydrawlast" class="hydrawlast"></span></summary><pre id="hydrawpre"></pre></details>'
      + '</div>';
    window.renderPrepare && window.renderPrepare();   // fill #hydprep / build log from the current prepare state
    // Only the "env" case (a standalone bundle's frozen preview) substitutes real cells with a
    // static, non-live render — that's the one case where clicking in is genuinely meaningless
    // (your edit would target a snapshot, not the real notebook). "boot"/"remote" already show
    // the real cells, just not-yet-computed — those stay fully interactive.
    // "run" reaches here only in an app, and its cells are the real, live ones — never a snapshot.
    document.body.classList.toggle('hyd-preview',
      state.hydratingKind !== 'remote' && state.hydratingKind !== 'boot' && state.hydratingKind !== 'run');
  } else if (state.hydrateError) {
    hb.className = 'hydbanner err'; hb.style.display = 'flex';
    hb.textContent = '⚠ ' + state.hydrateError;   // worker bring-up / env reconstruction failed (message is self-contained)
    document.body.classList.remove('hyd-preview'); window.clearPrepare && window.clearPrepare();
  } else {
    hb.style.display = 'none'; document.body.classList.remove('hyd-preview'); window.clearPrepare && window.clearPrepare();
  }
  updateStaleBadge(state);
  // Agent chat needs Kaimon's agent service — a standalone hub (slate --own / serve_notebook)
  // doesn't have it. Disable the button up front instead of letting the first turn error out.
  const ab = document.getElementById('agentbtn');
  if (ab) {
    const avail = !!state.agentAvailable;   // `state_json` always carries it
    ab.disabled = !avail;
    ab.title = avail ? 'agent chat'
                     : 'agent chat needs Kaimon — this hub is running standalone. Start Kaimon and open the notebook from its hub.';
  }
  // Undo/Redo menu items announce the next action ("↶ Undo cut 3 cells") and disable when empty.
  const ub = document.getElementById('undobtn');
  if (ub) { ub.textContent = '↶ Undo' + (state.undoLabel ? ' ' + state.undoLabel : ''); ub.disabled = !state.undoLabel; }
  const rb = document.getElementById('redobtn');
  if (rb) { rb.textContent = '↷ Redo' + (state.redoLabel ? ' ' + state.redoLabel : ''); rb.disabled = !state.redoLabel; }
  _sharedDocNotice(state);
}
// A notebook copied on this machine keeps the original's `docid`, so the two share one document:
// the same history, chat transcript and preview. That's the intended meaning of a docid (publish
// matches on it too), but it should never be a surprise — say so once, and offer the split.
// The server only reports this for a genuine copy: a notebook you were SENT has no local store to
// share, and two checkouts of one repo are filtered out, so neither says anything here.
let _sharedShown = false;
function _sharedDocNotice(state) {
  const others = state.sharedWith || [];
  const btn = document.getElementById('forkdocbtn');
  if (btn) btn.style.display = others.length ? '' : 'none';   // only offered when there IS a copy
  if (!others.length || _sharedShown) return;
  _sharedShown = true;                          // once per page, not once per state push
  _sharedDocDialog(state);
}
// Name the source, then offer the two things worth doing about it. Dismissal is a real answer
// recorded on the server against this path, not a toast that scrolls away — the other copy is
// asked the same question independently.
async function _sharedDocDialog(state) {
  const others = state.sharedWith || [];
  const from = state.sharedFrom;
  const where = from ? `copied from\n\n    ${from}` :
                       `shared with\n\n    ${others.join('\n    ')}`;
  const msg = `This notebook is one document in two places — it was ${where}\n\n` +
    `They share one history, chat transcript and preview, because they carry the same document id. ` +
    `Editing either writes to the same store.`;
  const choice = await dlg(msg, [
    { label: 'Keep sharing', value: 'keep' },
    { label: "Don't ask again", value: 'quiet' },
    { label: 'Open the other', value: 'open' },
    { label: 'Split from copy…', value: 'fork', cls: 'primary' },
  ]);
  if (choice === 'quiet') { await api('POST', '/api/share-quiet', {}); toast('Kept shared.', 3000); }
  else if (choice === 'open') _openOther(from || others[0]);
  else if (choice === 'fork') forkDoc();
}
// Serve the other copy and open it in a tab. `/api/open` is a HUB route, not a notebook-scoped
// one, so it can't go through api() — that injects this notebook's id into the path.
async function _openOther(path) {
  try {
    const r = await fetch('/api/open', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                         body: JSON.stringify({ path }) });
    const d = await r.json();
    if (d && d.url) window.open(d.url, '_blank'); else await alertDark('Could not open ' + path);
  } catch (_) { await alertDark('Could not open ' + path); }
}
// Give this notebook a fresh identity, copying the stores across so both sides keep their lineage.
async function forkDoc() {
  if (!await confirmDark('Split this notebook into its own document?\n\n' +
      'It gets a new id, and its history, chat and preview are COPIED — the other copy keeps ' +
      'everything too. Publishing treats them as separate documents from here on.', 'Split')) return;
  const r = await api('POST', '/api/fork-doc', {});
  if (r && r.ok) toast('Split — this notebook now has its own history.', 5000);
}
window.forkDoc = forkDoc;

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

// Keep every widget bound to a variable in lockstep (a control may be surfaced in
// multiple cells). Skips the element being actively dragged so we never fight it.
const _sameList = (a, b) => a.length === b.length && a.every((x, i) => String(x) === String(b[i]));

// Per-cell callers go through this, not `syncControlValues` directly. Each sync walks EVERY control
// in the notebook — it has to, because a control can be surfaced into a cell other than the one that
// declared it, so the walk cannot be scoped to the owner's subtree — and calling it once per cell
// therefore costs cells × controls, which is the dominant render cost on a document with many
// controls. Coalescing into a single pass per frame keeps the same end state (the last value for
// each name wins either way) for one walk instead of one per cell.
let _svcFrame = null, _svcCells = [];
function syncControlValuesSoon(cell) {
  _svcCells.push(cell);
  if (_svcFrame) return;
  _svcFrame = requestAnimationFrame(() => {
    _svcFrame = null;
    const cells = _svcCells; _svcCells = [];
    syncControlValues({ cells });
  });
}
window.syncControlValuesSoon = syncControlValuesSoon;

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
      const o2 = p.options.map(o => _normOpt(o));
      const cur = [...el.options].map(o => o.value), want = o2.map(o => String(o.value));
      if (!_sameList(cur, want)) el.innerHTML = o2.map(o => `<option value="${_esc(o.value)}">${_esc(o.label)}</option>`).join('');
    } else if (w === 'multiselect' && Array.isArray(p.options)) {
      const o2 = p.options.map(o => _normOpt(o));
      const cur = [...el.querySelectorAll('.msopt')].map(o => o.dataset.value), want = o2.map(o => String(o.value));
      if (!_sameList(cur, want)) {
        el.innerHTML = o2.map(o => `<div class="msopt" data-value="${_esc(o.value)}" role="option"><span class="optlbl">${_esc(o.label)}</span></div>`).join('');
        typeset(el);
      }
    } else if ((w === 'radio' || w === 'multicheck') && Array.isArray(p.options)) {
      // Radio + checkbox-list MultiCheckBox share a label-per-input layout; rebuild only on change.
      const o2 = p.options.map(o => _normOpt(o));
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

// Replace a cell's output, reserving its current height until the new content lays out. Without
// this the output collapses to ~0 height mid-swap; Safari then clamps scrollTop to the now-shorter
// page and the figure scrolls out of view (the P2 scroll bug).
// `live` is the cell's session-boundness marker ('render' | 'placeholder' | '') — see `_live_output_placeholder`.
// `after` is the caller's post-swap work (typesetting, clamping) on the NEW content. It is a
// callback rather than the next statement because a figure swap finishes asynchronously below.
function _swapOutput(out, html, live, after) {
  const finish = () => { if (after) after(); };
  // A SESSION-BOUND output the page has already booted outranks the placeholder that stands in for it.
  // The placeholder is right for a fresh page (the stored HTML belongs to a dead session), but it rides
  // in every full-state payload — and every mutating API call answers with full state — so without this
  // the next run of ANY cell blanks a working live output back to "connecting…", permanently: nothing
  // re-renders it until the next SSE connect. Keep the mounted one (and its `__slateOut`, so the matching
  // `celldone` re-render stays a no-op). Extension-agnostic: no markup is inspected, only the flag.
  if (live === 'placeholder' && out.__slateLive) return finish();
  // A single run swaps the output TWICE — the `celldone:` push (patchCells) AND the run's HTTP-response
  // render (the Preact <Cell> effect) both carry the SAME output. Re-running its <script> twice re-boots a
  // figure needlessly and, for a side-effecting web-cell fragment, fires its effect twice (a double
  // `alert`, a double append). Skip a swap whose output already matches what's mounted: identical output
  // never needs to re-render or re-run. A genuinely new output (or a real change on re-run) still swaps.
  if (out.__slateOut === html) return finish();
  out.__slateOut = html;
  out.__slateLive = live === 'render';

  // Parse off-DOM first. Assigning `out.innerHTML` tears the previous figure out immediately and
  // puts up an <img> that has nothing to paint until its bytes arrive and decode, so every
  // re-render shows a hole for at least one frame — the flicker you see dragging a slider that
  // drives a plot. A detached div still belongs to this document, so its images fetch and decode
  // there while the old figure is untouched on screen; the swap is then one frame from one picture
  // to the next. (A <template> will not do: its contents are inert and never fetch anything.)
  const stage = document.createElement('div');
  stage.innerHTML = html;
  const imgs = Array.from(stage.querySelectorAll('img')).filter(im => im.src);

  // Two figure renders can be in flight at once (a fast slider outruns a decode). Only the latest may
  // land — an older one committing afterwards would put a superseded plot back on the page.
  const seq = (out.__slateSwapSeq = (out.__slateSwapSeq || 0) + 1);
  const commit = () => {
    if (out.__slateSwapSeq !== seq) return;
    out.style.minHeight = out.offsetHeight + 'px';
    out.replaceChildren(...Array.from(stage.childNodes));
    runScripts(out);   // a <script> from parsed HTML is inert — re-create so figures boot
    mountOutputComponents(out);   // mount any `slate_render` component OUTPUTS in the freshly-swapped output
    const mounted = out.querySelectorAll('img');
    const release = () => { out.style.minHeight = ''; };
    if (!mounted.length) requestAnimationFrame(release);
    else {
      let n = mounted.length;
      const one = () => { if (--n <= 0) release(); };
      mounted.forEach(im => im.complete ? one() : (im.onload = im.onerror = one));
    }
    finish();
  };
  if (!imgs.length) return commit();   // text, markdown, tables: nothing to wait for

  // A broken image is not what this guards: a 404 rejects fast and commits right away. It guards a
  // fetch that stalls, where the alternative to waiting is showing the reader a hole. Holding the
  // previous figure is the better answer for as long as it stays plausible, hence a whole second.
  let committed = false;
  const go = () => { if (committed) return; committed = true; clearTimeout(deadline); commit(); };
  const deadline = setTimeout(go, 1000);
  Promise.all(imgs.map(im => im.decode ? im.decode().catch(() => {})
                                       : new Promise(r => { im.onload = im.onerror = r; }))).then(go);
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
    const parent = old.parentNode;
    try {
      old.replaceWith(s);   // an inline script runs on insert — a SYNTAX error throws HERE, synchronously
    } catch (e) {
      // A parse error is the one failure a fragment's own `catch` can't reach (the code never runs). It
      // used to throw out through patchCells' render loop (breaking other cells in the batch); instead
      // surface it ONTO the cell, tied to this output, and keep rendering.
      console.error(e);
      try {
        const b = document.createElement('pre'); b.className = 'web-err';
        b.textContent = '⚠ ' + ((e && e.message) || e);
        (parent || root).appendChild(b);
      } catch (_) {}
      continue;
    }
    if (loaded) await loaded;
  }
}

// Expose the `const` helpers the Preact modules (notebook.js) need: ES modules can't see a
// classic script's lexical `const` globals — only `var`/`function` globals become window
// properties. So ONLY the consts go here (the functions are already on window). `editors`/
// `charts`/`srcMap` are shared by reference, so the module's mutations stay in sync. (All of
// these are defined in core.js or earlier in view.js, so they exist when this runs.)
Object.assign(window, { editors, charts, srcMap, mdHtml, srcEditInner, bindsInner, hasBinds });

