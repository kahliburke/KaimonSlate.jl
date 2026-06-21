// Inner markup for one bound control. `bindId` is the *defining* bind cell's id
// (the /api/bind POST target); `b` is its spec ({name,widget,params,value}). Used
// by both the standalone @bind cell and any cell's control strip — wherever a
// widget renders, changing it drives recompute the same way.
const _esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const _showVal = v => Array.isArray(v) ? v.join(', ') : v;

function controlMarkup(bindId, b) {
  const p = b.params || {}, w = b.widget;
  const a = `data-bind="${bindId}" data-name="${b.name}" data-widget="${w}"`;
  const opts = (p.options || []);
  let ctrl = '', wval = `<span class="wval">${_esc(_showVal(b.value))}</span>`;
  if (w === 'slider')
    ctrl = `<input type="range" min="${p.min}" max="${p.max}" step="${p.step}" value="${b.value}" ${a}/>`;
  else if (w === 'number')
    ctrl = `<input type="number" value="${b.value}" ${p.min != null ? `min="${p.min}"` : ''} ${p.max != null ? `max="${p.max}"` : ''} ${a}/>`;
  else if (w === 'checkbox' || w === 'toggle')
    ctrl = `<input type="checkbox" class="${w}" ${b.value ? 'checked' : ''} ${a}/>`;
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
    ctrl = `<select ${a}>` + opts.map(o => `<option ${o == b.value ? 'selected' : ''}>${_esc(o)}</option>`).join('') + '</select>';
  else if (w === 'multiselect')
    ctrl = `<select multiple ${a}>` +
      opts.map(o => `<option ${(b.value || []).includes(o) ? 'selected' : ''}>${_esc(o)}</option>`).join('') + '</select>';
  else if (w === 'radio')
    ctrl = `<span class="radiogroup" ${a}>` + opts.map((o, i) =>
      `<label><input type="radio" name="r-${bindId}-${b.name}" value="${_esc(o)}" ${o == b.value ? 'checked' : ''}/>${_esc(o)}</label>`).join('') + '</span>';
  else if (w === 'button') {
    ctrl = `<button type="button" class="actionbtn" data-count="${b.value}" ${a}>${_esc(p.label || 'Click')}</button>`;
    wval = `<span class="wval">×${b.value}</span>`;       // show the click count
  }
  return `<span class="wname">${b.name}</span>${ctrl}${wval}`;
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

// One compact header line per cell: run + id (left), then duration, hover-revealed
// actions, and the state badge (right). Replaces the old two-row bar+head.
function cellHeaderInner(c) {
  const isCode = c.kind === 'code' && !hasBinds(c);
  const other = c.kind === 'md' ? 'code' : 'md';
  const editSrc = (c.kind === 'md' || hasBinds(c))
    ? `<button onclick="toggleSource('${c.id}','${c.kind === 'md' ? 'markdown' : 'julia'}')" title="edit source">&lt;/&gt;</button>` : '';
  const run = isCode ? `<button class="run" data-run="${c.id}" onclick="runCell('${c.id}')" title="run (⇧⏎)">▶</button>` : '';
  const bu = transBinduses(c);
  const _present = new Set([].concat(...((c.controls || []).map(col => col.map(s => s.name)))));
  const _someOn = bu.some(n => _present.has(n));
  const autoctl = bu.length
    ? `<button class="autoctl${_someOn ? ' on' : ''}" onclick="openControlPicker('${c.id}', event)" title="pick which @bind controls to surface on this cell (${bu.join(', ')})">🎛</button>` : '';
  return '<span class="drag" draggable="true" title="drag to reorder">⠿</span>' +
    `<button class="collapse" onclick="toggleCollapse('${c.id}')" title="collapse / expand">${c.collapsed ? '▸' : '▾'}</button>` + run +
    `<span class="cid" title="double-click to rename">${c.id}</span>` +
    '<span class="hspace"></span>' +
    `<span class="cdur">${c.duration != null ? c.duration + ' ms' : ''}</span>` +
    '<span class="cellacts">' +
      `<button class="askai" onclick="askCell('${c.id}')" title="ask the AI about this cell">✨</button>` +
      (c.kind === 'code' ? `<button onclick="toggleDeps('${c.id}')" title="focus: show only this cell's dependency chain (Esc to exit)">🔗</button>` : '') + autoctl +
      (isCode ? `<button class="hidecode${c.codeHidden ? ' on' : ''}" onclick="toggleHideCode('${c.id}')" title="${c.codeHidden ? 'show code' : 'hide code — show only the output'}">${c.codeHidden ? '🙈' : '👁'}</button>` : '') +
      editSrc +
      `<button onclick="moveCell('${c.id}','up')" title="move up">↑</button>` +
      `<button onclick="moveCell('${c.id}','down')" title="move down">↓</button>` +
      `<button onclick="toggleType('${c.id}','${other}')" title="to ${other}">${c.kind === 'md' ? '{·}' : 'M↓'}</button>` +
      `<button class="addbtn" onclick="addCell('${c.id}','code')" oncontextmenu="addMenu(event,'${c.id}');return false" title="add below · right-click for type">＋</button>` +
      `<button class="del" onclick="delCell('${c.id}')" title="delete cell">🗑</button>` +
    '</span>' +
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
    if (m) m.textContent = widget === 'button' ? '×' + v : _showVal(v); };
  // Mark the control as just-touched so background refreshes (async live updates)
  // don't yank its value out from under the user mid-interaction.
  const touch = () => { el._touched = performance.now(); };
  el.addEventListener('pointerdown', touch);
  el.addEventListener('focus', touch, true);
  if (widget === 'button') {                       // action button → increments a counter
    el.onclick = () => { touch(); const n = (parseInt(el.dataset.count, 10) || 0) + 1; el.dataset.count = n; mirror(n); flush(n); };
    return;
  }
  const readVal = () => {
    if (widget === 'checkbox' || widget === 'toggle') return el.checked;
    if (widget === 'slider' || widget === 'number') return parseFloat(el.value);
    if (widget === 'multiselect') return [...el.selectedOptions].map(o => o.value);
    if (widget === 'radio') { const c = el.querySelector('input:checked'); return c ? c.value : null; }
    return el.value;
  };
  el.oninput  = () => { touch(); const v = readVal(); mirror(v); schedule(v); };
  el.onchange = () => { touch(); const v = readVal(); mirror(v); flush(v); };
}

// Wire every bound widget in a cell — its own @bind widget and/or control strip.
function mountControls(c) {
  const cell = document.getElementById('cell-' + c.id);
  if (cell) cell.querySelectorAll('[data-bind]').forEach(wireControl);
}

// Wire a freshly-created CodeMirror for code cell `c`: edit tracking, completion + signature
// keys, as-you-type. Shared by the vanilla mount and the Preact <Editor> component, so the
// editor behaves identically however it was created. `ed` already holds the source.
function wireCodeEditor(ed, c) {
  if (ed.getValue() !== c.source) ed.setValue(c.source);
  let primed = false;
  ed.on('change', () => { if (primed) setState(c.id, 'edited'); });
  setTimeout(() => primed = true, 0);
  const complete = cm => cm.showHint({ hint: juliaHint, completeSingle: false });
  const tabComplete = cm => {                  // cycle signature params · complete (word/dot, or arg position) · else indent
    if (cm._ph) { _phGoto(cm, cm._ph.idx + 1); return; }   // signature placeholder mode owns Tab
    if (cm.somethingSelected()) return CodeMirror.Pass;
    const cur = cm.getCursor(), line0 = cm.getRange({ line: cur.line, ch: 0 }, cur), before = line0.slice(-1);
    const inCall = (line0.match(/\(/g) || []).length > (line0.match(/\)/g) || []).length;
    if (/[\w.]/.test(before) || (inCall && /[(,;\s]/.test(before))) complete(cm);   // arg/kwarg position → signatures
    else return CodeMirror.Pass;
  };
  // As-you-type: open the popup once ≥2 identifier chars are typed (it then self-updates).
  // Skip inside strings/comments. Field access (`.`) fires immediately, below.
  const autoComplete = debounce(cm => {
    if (cm.state.completionActive || cm._ph) return;   // not while filling signature placeholders
    const cur = cm.getCursor(), tok = cm.getTokenAt(cur);
    if (tok.type === 'comment' || tok.type === 'string') return;
    if (!/[A-Za-z_][\w!]$/.test(cm.getRange({ line: cur.line, ch: 0 }, cur))) return;
    complete(cm);
  }, 140);
  const shiftTab = cm => { if (cm._ph) { _phGoto(cm, cm._ph.idx - 1, -1); return; } return CodeMirror.Pass; };
  ed.setOption('extraKeys', { 'Shift-Enter': () => runCell(c.id), 'Tab': tabComplete, 'Shift-Tab': shiftTab,
                              'Esc': () => { if (ed._ph) _phEnd(ed); else ed.getInputField().blur(); },
                              'Ctrl-Space': complete, 'Shift-Cmd-Enter': () => runAndAddBelow(c.id), 'Shift-Ctrl-Enter': () => runAndAddBelow(c.id),
                              'Shift-Ctrl--': () => splitCell(c.id, ed), 'Shift-Cmd--': () => splitCell(c.id, ed) });
  ed.on('inputRead', (cm, ev) => {             // auto on field access, debounced as-you-type otherwise
    if (cm._ph) return;                        // filling placeholders — don't pop completions over the cursor
    const t = ev.text[0] || '';
    if (t === '.') complete(cm);
    else if (/[A-Za-z_]/.test(t)) autoComplete(cm);
  });
  ed.on('focus', () => setEditing(c.id, true));    // edit-mode indicator
  ed.on('blur', () => setEditing(c.id, false));
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
    const cm = editors[id];
    (cm && cm.getValue() !== (srcMap[id] || '')) ? commitSource(id) : cancelSource(id);
  } else {
    editSource(id, mode);
  }
}

function editSource(id, mode) {
  const cell = document.getElementById('cell-' + id);
  if (!cell) return;
  const d = _disp(cell); if (d) d.style.display = 'none';
  cell.querySelector('.srcedit').style.display = '';
  if (!editors[id]) {
    const ta = cell.querySelector('.srcedit textarea');
    const cm = CodeMirror.fromTextArea(ta, {
      mode, theme: 'material-darker', lineNumbers: false,
      viewportMargin: Infinity, lineWrapping: mode === 'markdown'
    });
    cm.setValue(srcMap[id] || '');
    cm.setOption('extraKeys', { 'Shift-Enter': () => commitSource(id), 'Esc': () => cancelSource(id),
                                'Shift-Cmd-Enter': () => commitAndAddBelow(id), 'Shift-Ctrl-Enter': () => commitAndAddBelow(id) });
    cm.on('focus', () => setEditing(id, true));
    cm.on('blur', () => setEditing(id, false));
    editors[id] = cm;
  }
  editors[id].refresh(); editors[id].focus();
}
async function commitSource(id) {
  const cm = editors[id], src = cm ? cm.getValue() : srcMap[id];
  if (cm) { cm.toTextArea(); delete editors[id]; }
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
  const cm = editors[id]; if (cm) { cm.toTextArea(); delete editors[id]; }
  const cell = document.getElementById('cell-' + id); if (!cell) return;
  cell.querySelector('.srcedit').style.display = 'none';
  const d = _disp(cell); if (d) d.style.display = '';
}

// Notebook rendering is owned by the Preact <Notebook> (notebook.js), driven by the signals
// store. renderAll/updateStates now just publish the state + refresh the chrome; the component
// diffs cells by id (so editors survive structural ops) and does per-cell output processing in
// effects. The old full-wipe rebuild and the in-place patch collapse into one publish.
function renderAll(state)    { _publishState(state); }
function updateStates(state) { _publishState(state); }
function _publishState(state) {
  nbState = state;
  window.__slateState = state;                  // latest state, always — so the store (a deferred
                                                // module) can seed from it even if it loads AFTER
                                                // this first ran (the boot reload() is async).
  _depFocus = null;
  if (selectedId && !(state.cells || []).some(c => c.id === selectedId)) selectedId = null;   // dropped/renamed
  window.slateStore && window.slateStore.applyState(state);   // → Preact re-renders #nb reactively
  updateChrome(state);
}
// Topbar/banner bits that live outside #nb (title, worker dot, vscode link, hydrating banner).
function updateChrome(state) {
  document.getElementById('title').textContent = state.title || 'Notebook';
  document.title = (state.title ? state.title + ' · ' : '') + 'Kaimon Slate';   // browser tab
  const w = state.worker || {}, dot = document.getElementById('wdot');
  if (dot) {
    dot.className = 'wdot ' + (w.kind === 'inproc' ? 'inproc' : (w.connected ? 'up' : 'down')) + (_busy > 0 ? ' busy' : '');
    dot.title = w.kind === 'gate' ? ('worker :' + w.port + (w.connected ? ' · connected' : ' · disconnected')) : 'in-process kernel';
  }
  if (state.path) document.getElementById('vscode').href = 'vscode://file' + state.path;
  const hb = document.getElementById('hydbanner');
  _hydrating = !!state.hydrating;              // gate mutating actions while the env reconstructs
  if (state.hydrating) {
    hb.className = 'hydbanner'; hb.style.display = 'flex';
    hb.innerHTML = '<span class="hydspin"></span>Reconstructing environment &amp; instantiating packages — showing a saved preview; cells go live when it’s ready…';
    document.body.classList.add('hydrating');
  } else if (state.hydrateError) {
    hb.className = 'hydbanner err'; hb.style.display = 'flex';
    hb.textContent = '⚠ Environment reconstruction failed: ' + state.hydrateError;
    document.body.classList.remove('hydrating');
  } else {
    hb.style.display = 'none'; document.body.classList.remove('hydrating');
  }
  updateStaleBadge(state);
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
    } else if ((w === 'select' || w === 'multiselect') && Array.isArray(p.options)) {
      // Dynamic options: rebuild the <option> list only if it changed (the value-set
      // below re-applies the selection). Avoids tearing the menu down every sync.
      const cur = [...el.options].map(o => o.value);
      if (!_sameList(cur, p.options)) el.innerHTML = p.options.map(o => `<option>${_esc(o)}</option>`).join('');
    } else if (w === 'radio' && Array.isArray(p.options)) {
      const cur = [...el.querySelectorAll('input[type=radio]')].map(i => i.value);
      if (!_sameList(cur, p.options)) {
        const nm = 'r-' + el.dataset.bind + '-' + el.dataset.name;
        el.innerHTML = p.options.map(o =>
          `<label><input type="radio" name="${nm}" value="${_esc(o)}"/>${_esc(o)}</label>`).join('');
      }
    }
    if (w === 'checkbox' || w === 'toggle') el.checked = !!v;
    else if (w === 'multiselect') [...el.options].forEach(o => { o.selected = Array.isArray(v) && v.includes(o.value); });
    else if (w === 'radio') { const c = el.querySelector('input[value="' + v + '"]'); if (c) c.checked = true; }
    else if (w === 'button') el.dataset.count = v;
    else el.value = v;
    const wrap = el.closest('.widget, .control'); const m = wrap && wrap.querySelector('.wval');
    if (m) m.textContent = w === 'button' ? '×' + v : _showVal(v);
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

