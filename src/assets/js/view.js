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

// One compact header line per cell: run + id (left), then duration, hover-revealed
// actions, and the state badge (right). Replaces the old two-row bar+head.
function cellHeaderInner(c) {
  const isCode = c.kind === 'code' && !hasBinds(c);
  const other = c.kind === 'md' ? 'code' : 'md';
  const editSrc = (c.kind === 'md' || hasBinds(c))
    ? `<button onclick="toggleSource('${c.id}','${c.kind === 'md' ? 'markdown' : 'julia'}')" title="edit source">&lt;/&gt;</button>` : '';
  const run = isCode ? `<button class="run" data-run="${c.id}" onclick="runCell('${c.id}')" title="run (⇧⏎)">▶</button>` : '';
  const bu = surfaceableNames(c);
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
      (isCode ? `<button class="trace${c.trace ? ' on' : ''}" onclick="toggleTrace('${c.id}')" title="${c.trace ? 'open the trace inspector' : 'trace this cell — inspect each value in a popup'}">🔍</button>` : '') +
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
    if (m) m.textContent = _ctrlValLabel(el, v); };
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
    if (widget === 'multiselect') return [...el.querySelectorAll('.msopt.on')].map(o => o.dataset.value);
    if (widget === 'multicheck') return [...el.querySelectorAll('input[type=checkbox]:checked')].map(i => i.value);
    if (widget === 'radio') { const c = el.querySelector('input:checked'); return c ? c.value : null; }
    return el.value;
  };
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

// Wire every bound widget in a cell — its own @bind widget and/or control strip.
function mountControls(c) {
  const cell = document.getElementById('cell-' + c.id);
  if (!cell) return;
  cell.querySelectorAll('[data-bind]').forEach(wireControl);
  cell.querySelectorAll('.radiogroup, .checkgroup, .mslist').forEach(typeset);   // render rich ($math$) option labels
}

// Wire a freshly-created CodeMirror for code cell `c`: edit tracking, completion + signature
// keys, as-you-type. Shared by the vanilla mount and the Preact <Editor> component, so the
// editor behaves identically however it was created. `ed` already holds the source.
// Completion behaviour (Tab/Ctrl-Space/as-you-type/signatures) shared by BOTH the always-on
// code editor AND the toggle-source editor used by @bind cells — so a bind cell's `</>` source
// editor completes too (it lost completion after eval otherwise). Wires the as-you-type popup on
// `ed` and returns the completion extraKeys for the caller to merge with its own (Enter/Esc).
// Complete Julia keywords — typing one of these in full is a finished token, not a prefix to
// complete (e.g. `end` closing a block), so the as-you-type popup is suppressed on an exact match.
const _JL_KEYWORDS = new Set(['baremodule', 'begin', 'break', 'catch', 'const', 'continue', 'do',
  'else', 'elseif', 'end', 'export', 'false', 'finally', 'for', 'function', 'global', 'if', 'import',
  'in', 'isa', 'let', 'local', 'macro', 'module', 'mutable', 'primitive', 'quote', 'return', 'struct',
  'true', 'try', 'type', 'using', 'where', 'while', 'abstract']);

function _wireCompletion(ed) {
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
  // Skip inside strings/comments, and skip when the word just typed is a complete Julia KEYWORD
  // (`end`, `function`, `for`, …) — closing a block shouldn't pop a completion list.
  const autoComplete = debounce(cm => {
    if (cm.state.completionActive || cm._ph) return;   // not while filling signature placeholders
    if (!cm.hasFocus()) return;                        // blurred during the debounce — don't pop a stranded widget
    const cur = cm.getCursor(), tok = cm.getTokenAt(cur);
    if (tok.type === 'comment' || tok.type === 'string') return;
    const before = cm.getRange({ line: cur.line, ch: 0 }, cur);
    if (!/[A-Za-z_][\w!]$/.test(before)) return;
    const word = (before.match(/[A-Za-z_][\w!]*$/) || [''])[0];
    if (_JL_KEYWORDS.has(word)) return;                // a finished keyword → no popup
    complete(cm);
  }, 140);
  const shiftTab = cm => { if (cm._ph) { _phGoto(cm, cm._ph.idx - 1, -1); return; } return CodeMirror.Pass; };
  ed.on('inputRead', (cm, ev) => {             // auto on field access, debounced as-you-type otherwise
    if (cm._ph) return;                        // filling placeholders — don't pop completions over the cursor
    const t = ev.text[0] || '';
    if (t === '.') complete(cm);
    else if (/[A-Za-z_]/.test(t)) autoComplete(cm);
  });
  return { complete, keys: { 'Tab': tabComplete, 'Shift-Tab': shiftTab } };
}
// Toggle Julia line comments (#) over the selected lines — bound to Cmd-/ and Ctrl-/. Comments at
// each line's own indent; uncomments only when EVERY non-blank line in the range is already a
// comment (so a partly-commented block comments the rest rather than toggling inconsistently).
function _toggleComment(cm) {
  const start = cm.getCursor('from').line, end = cm.getCursor('to').line;
  let anyContent = false, allCommented = true;
  for (let l = start; l <= end; l++) {
    const s = cm.getLine(l); if (s.trim() === '') continue;
    anyContent = true; if (!/^\s*#/.test(s)) allCommented = false;
  }
  if (!anyContent) return;
  cm.operation(() => {
    for (let l = start; l <= end; l++) {
      const s = cm.getLine(l); if (s.trim() === '') continue;
      if (allCommented) {
        const m = s.match(/^(\s*)#\s?/);
        if (m) cm.replaceRange(m[1], { line: l, ch: 0 }, { line: l, ch: m[0].length });
      } else {
        cm.replaceRange('# ', { line: l, ch: s.match(/^\s*/)[0].length });
      }
    }
  });
}

function wireCodeEditor(ed, c) {
  if (ed.getValue() !== c.source) ed.setValue(c.source);
  let primed = false;
  ed.on('change', () => { if (primed) { setState(c.id, 'edited'); window._backupSoon && window._backupSoon(); } });
  setTimeout(() => primed = true, 0);
  const { complete, keys } = _wireCompletion(ed);
  ed.setOption('extraKeys', Object.assign({}, keys, {
    'Shift-Enter': () => runCell(c.id),
    'Esc': () => { if (ed._ph) _phEnd(ed); else ed.getInputField().blur(); },
    'Ctrl-Space': complete, 'Shift-Cmd-Enter': () => runAndAddBelow(c.id), 'Shift-Ctrl-Enter': () => runAndAddBelow(c.id),
    'Cmd-/': _toggleComment, 'Ctrl-/': _toggleComment,
    'Shift-Ctrl--': () => splitCell(c.id, ed), 'Shift-Cmd--': () => splitCell(c.id, ed) }));
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
function renderAll(state)    { _publishState(state); }
function updateStates(state) { _publishState(state); }
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
    srcMap[nc.id] = nc.source;
    const cell = document.getElementById('cell-' + nc.id);
    if (cell) {
      cell.className = cell.className.replace(/\bstate-\S+/, 'state-' + nc.state);
      const badge = cell.querySelector('.badge'); if (badge) badge.textContent = nc.state;
      if (nc.kind === 'md') { const md = cell.querySelector('.md'); if (md) { _swapOutput(md, mdHtml(nc)); typeset(md); } }
      else { const out = cell.querySelector('.output'); if (out) { _swapOutput(out, nc.output); typeset(out); } }
    }
    renderCharts(nc); renderTables(nc); syncControlValues({ cells: [nc] });
  });
}
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
    else if (w === 'button') el.dataset.count = v;
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

