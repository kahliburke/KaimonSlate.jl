// This notebook's hub id, from the /n/<id> URL; all API/SSE paths are scoped to it.
const NB_ID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
const _apipath = p => p.replace(/^\/api\//, '/api/' + NB_ID + '/');

const editors = {};
const charts = {};            // cell id -> [echarts instances]
const tableState = {};        // cell id -> [{sort,filter,page,pageSize} per table] (view prefs, sticky)
const srcMap = {};            // cell id -> raw source (for markdown editing)
let nbState = null;           // latest notebook state (drives the controls palette)
let _hydrating = false;       // true while a standalone's env reconstructs (read-only preview)
// Min delay (ms) between live recomputes while dragging a control. Persisted.
let updateMs = Math.max(0, parseInt(localStorage.getItem('slateUpdateMs') ?? '200', 10) || 0);
let lastVersion = -1;

// Lightweight transient notification (bottom-right corner); stacks, auto-dismisses.
function toast(msg, ms = 4500, kind = '') {
  let host = document.getElementById('toasts');
  if (!host) { host = document.createElement('div'); host.id = 'toasts'; document.body.appendChild(host); }
  const t = document.createElement('div'); t.className = 'toast' + (kind ? ' ' + kind : ''); t.textContent = msg;
  host.appendChild(t);
  requestAnimationFrame(() => t.classList.add('show'));
  setTimeout(() => { t.classList.remove('show'); setTimeout(() => t.remove(), 300); }, ms);
}

const mdHtml = c => c.output || '<em class="phantom">empty markdown — double-click to edit</em>';
const srcEditInner = () => '<textarea></textarea><div class="mdhint">⇧⏎ commit · esc cancel</div>';
const srcEditHTML = () => `<div class="srcedit" style="display:none">${srcEditInner()}</div>`;

// Strip the interactive-only chrome from a chart spec for a clean, static, publication render.
// ECharts has no "publication mode" flag — what reads as on-screen controls are spec components:
// the toolbox icon row, brush selection handles, and the dataZoom *slider* bar. We blank those for
// the exported figure while preserving the data, axes, legend, and the current zoom window (so the
// printed range matches what's on screen). Shallow-clones — never mutates the live spec, so the
// on-screen chart keeps its controls.
function _pubSpec(spec) {
  const s = Object.assign({}, spec);
  s.animation = false;                                              // capture the settled state
  if (s.toolbox) s.toolbox = Object.assign({}, s.toolbox, { show: false });
  if (s.brush) s.brush = undefined;
  if (s.dataZoom != null)                                           // keep start/end range, drop the slider UI
    s.dataZoom = [].concat(s.dataZoom).map(d => Object.assign({}, d, { show: false }));
  return s;
}

// Capture a cell's (first) ECharts canvas as a PNG and stash it server-side, so the
// agent's slate_view — and future PDF export — get a uniform image for client-rendered
// charts, the same way CairoMakie figures come through. Debounced so animation settles
// and reactive ticks don't spam; raw fetch so it doesn't pulse the busy indicator.
const _snapPending = {};
function _snapCell(cellId, insts, spec) {
  clearTimeout(_snapPending[cellId]);
  _snapPending[cellId] = setTimeout(() => {
    const inst = insts[0]; if (!inst) return;
    let png = '', svg = '', svgDark = '';
    // PNG (dark theme) → matches the live UI for the agent's slate_view.
    try { png = (inst.getDataURL({ type: 'png', pixelRatio: 2, backgroundColor: '#0e1116' }) || '').split(',')[1] || ''; } catch (_) {}
    // Vector SVG for publication PDF: re-render the spec offscreen with the SVG renderer,
    // once for a light page (default theme, white bg) and once for a dark page (dark
    // theme, dark bg), so each PDF theme gets a chart that reads on its background. The spec
    // is run through _pubSpec first so the exported figure carries no interactive chrome.
    // Best-effort; the server prefers these over the raster PNG when present.
    const pub = _pubSpec(spec);
    const renderSvg = (themeName, bg) => {
      let off = null, div = null;
      try {
        const w = inst.getWidth() || 640, h = inst.getHeight() || 400;
        div = document.createElement('div');
        div.style.cssText = 'position:absolute;left:-99999px;top:0;width:' + w + 'px;height:' + h + 'px;';
        document.body.appendChild(div);
        off = echarts.init(div, themeName, { renderer: 'svg', width: w, height: h });
        off.setOption(Object.assign({ backgroundColor: bg }, pub));
        return off.renderToSVGString();
      } catch (_) { return ''; }
      // ALWAYS tear down the offscreen instance + div — without this, a throw in setOption/render
      // leaked an ECharts instance (live zrender) + a detached node on every failed snapshot.
      finally { if (off) { try { off.dispose(); } catch (_) {} } if (div) div.remove(); }
    };
    if (spec) { svg = renderSvg(null, '#ffffff'); svgDark = renderSvg('dark', '#12141c'); }
    if (png) fetch(_apipath('/api/snapshot'), { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cell: cellId, image: png, svg: svg || undefined, svgDark: svgDark || undefined }) }).catch(() => {});
  }, 700);
}

// Render/refresh a cell's ECharts. Instances persist across reactive updates, so
// data changes animate in place (setOption) instead of swapping an image.
function renderCharts(c) {
  const specs = c.echarts || [];
  const host = document.querySelector('#cell-' + c.id + ' .echarts');
  if (host) {                                   // code-cell echarts host
    if (!charts[c.id]) charts[c.id] = [];
    const insts = charts[c.id];
    while (host.children.length < specs.length) {
      const d = document.createElement('div'); d.className = 'echart'; host.appendChild(d);
      insts.push(echarts.init(d, 'dark'));
    }
    while (host.children.length > specs.length) { host.removeChild(host.lastChild); const inst = insts.pop(); if (inst) try { inst.dispose(); } catch (_) {} }
    specs.forEach((s, i) => { try { insts[i].setOption(s); } catch (e) {} });
    if (insts.length) _snapCell(c.id, insts, specs[0]);   // PNG (slate_view) + SVG (vector PDF) → server
  }
  // Inline `{{ echart(…) }}` placeholders in a markdown cell.
  document.querySelectorAll('#cell-' + c.id + ' .ichart').forEach(el => {
    const spec = specs[+el.dataset.i]; if (!spec) return;
    if (!el._inst) el._inst = echarts.init(el, 'dark');
    try { el._inst.setOption(spec); } catch (e) {}
  });
}
window.addEventListener('resize', () => Object.values(charts).flat().forEach(c => c.resize()));

// ── Interactive data tables (hand-rolled; no CDN dep) ────────────────────────
// A cell's `c.tables` is a list of {columns, rows, opts}; rows hold JSON-safe
// scalars (numbers stay numeric → numeric sort). Sort / filter / page are pure
// client state kept per (cell id, table index) in `tableState`, so they survive
// reactive recomputes — only the row data is re-filled when data changes.
function _cmp(a, b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1; if (b == null) return 1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}
// Columns are strings (eager) or {name,type,sortable,filterable} objects (paged).
const _colName = c => (typeof c === 'string' ? c : c.name);
function renderTables(c) {
  const specs = c.tables || [];
  const host = document.querySelector('#cell-' + c.id + ' .tables');
  if (host) {                                   // code-cell tables host
    if (!specs.length) { host.innerHTML = ''; delete tableState[c.id]; }
    else {
      const states = tableState[c.id] || (tableState[c.id] = []);
      states.length = specs.length;             // drop view-state for removed tables
      while (host.children.length > specs.length) host.removeChild(host.lastChild);
      specs.forEach((spec, i) => {
        if (!states[i]) states[i] = { sort: null, filter: '', page: 0, pageSize: spec.paged ? (spec.pageSize || 50) : 25 };
        let wrap = host.children[i];
        if (!wrap) { wrap = document.createElement('div'); wrap.className = 'slatetable'; host.appendChild(wrap); }
        drawTable(wrap, spec, states[i]);
      });
    }
  }
  // Inline `{{ slate_table(…) / df }}` placeholders in a markdown cell.
  document.querySelectorAll('#cell-' + c.id + ' .itable').forEach(el => {
    const spec = specs[+el.dataset.i]; if (!spec) return;
    el.classList.add('slatetable');
    el._st = el._st || { sort: null, filter: '', page: 0, pageSize: spec.paged ? (spec.pageSize || 50) : 25 };
    drawTable(el, spec, el._st);
  });
}
// Build the persistent shell once per column-signature; refresh fills the body.
function drawTable(wrap, spec, st) {
  const cols = spec.columns || [];
  const sig = (spec.paged ? 'p:' : 'e:') + cols.map(_colName).join('');
  if (wrap._sig !== sig) { _buildShell(wrap, cols, spec, st); wrap._sig = sig; }
  _refreshTable(wrap, spec, st);
}
function _buildShell(wrap, cols, spec, st) {
  wrap.innerHTML = '';
  const bar = document.createElement('div'); bar.className = 'st-bar';
  const fi = document.createElement('input');
  fi.type = 'text'; fi.className = 'st-filter';
  fi.placeholder = spec.paged ? 'search…' : 'filter…'; fi.value = st.filter;
  const doFilter = () => { st.filter = fi.value; st.page = 0; _refreshTable(wrap, spec, st); };
  fi.oninput = spec.paged ? debounce(doFilter, 250) : doFilter;   // paged hits the server → debounce
  const info = document.createElement('span'); info.className = 'st-info';
  bar.appendChild(fi); bar.appendChild(info); wrap.appendChild(bar);
  const tbl = document.createElement('table'); tbl.className = 'st-table';
  const thead = document.createElement('thead'); const htr = document.createElement('tr');
  const ths = cols.map((c, ci) => {
    const th = document.createElement('th'); th.dataset.label = _colName(c);
    const sortable = typeof c === 'string' || c.sortable !== false;
    if (sortable) th.onclick = () => {
      if (st.sort && st.sort.col === ci) st.sort.dir = st.sort.dir === 'asc' ? 'desc' : 'asc';
      else st.sort = { col: ci, dir: 'asc' };
      _refreshTable(wrap, spec, st);
    }; else th.style.cursor = 'default';
    htr.appendChild(th); return th;
  });
  thead.appendChild(htr); tbl.appendChild(thead);
  const tbody = document.createElement('tbody'); tbl.appendChild(tbody); wrap.appendChild(tbl);
  const pag = document.createElement('div'); pag.className = 'st-pag'; wrap.appendChild(pag);
  wrap._refs = { fi, info, ths, tbody, pag };
}
function _drawArrows(wrap, st) {
  wrap._refs.ths.forEach((th, ci) => {
    const arr = st.sort && st.sort.col === ci ? (st.sort.dir === 'desc' ? ' ▾' : ' ▴') : '';
    th.textContent = th.dataset.label + arr;
  });
}
// Dispatch: eager tables compute locally; paged tables fetch a page from the server.
function _refreshTable(wrap, spec, st) {
  if (spec.paged) return _refreshPaged(wrap, spec, st);
  const allRows = spec.rows || [];
  const f = st.filter.trim().toLowerCase();
  let rows = !f ? allRows
    : allRows.filter(r => r.some(v => v != null && String(v).toLowerCase().includes(f)));
  if (st.sort) {
    const col = st.sort.col, mul = st.sort.dir === 'desc' ? -1 : 1;
    rows = rows.slice().sort((a, b) => _cmp(a[col], b[col]) * mul);
  }
  const total = rows.length;
  const pages = Math.max(1, Math.ceil(total / st.pageSize));
  st.page = Math.min(Math.max(0, st.page), pages - 1);
  const start = st.page * st.pageSize;
  _fillTable(wrap, spec, st, rows.slice(start, start + st.pageSize), total, allRows.length);
}
// Server-paged: POST the request; a request token discards superseded responses.
function _refreshPaged(wrap, spec, st) {
  const token = (wrap._tok = (wrap._tok || 0) + 1);
  _drawArrows(wrap, st);                          // immediate feedback while the fetch is in flight
  const body = {
    table_id: spec.tableId, page: st.page + 1, page_size: st.pageSize,
    sort_col: st.sort ? st.sort.col + 1 : 0,
    sort_desc: !!(st.sort && st.sort.dir === 'desc'),
    search: st.filter.trim(),
  };
  api('POST', '/api/table-page', body).then(res => {
    if (token !== wrap._tok) return;              // a newer request already went out
    const total = res.total || 0;
    const pages = Math.max(1, Math.ceil(total / st.pageSize));
    if (st.page > pages - 1) { st.page = pages - 1; _refreshPaged(wrap, spec, st); return; }
    _fillTable(wrap, spec, st, res.rows || [], total, spec.opts ? spec.opts.nrows : total);
  }).catch(() => {});
}
// Shared render of one page into the shell (body rows, info line, pagination).
function _fillTable(wrap, spec, st, pageRows, total, baseCount) {
  const { info, tbody, pag } = wrap._refs;
  _drawArrows(wrap, st);
  const start = st.page * st.pageSize;
  tbody.innerHTML = '';
  pageRows.forEach(r => {
    const tr = document.createElement('tr');
    r.forEach(v => {
      const td = document.createElement('td');
      if (typeof v === 'number') td.className = 'num';
      td.textContent = v == null ? '' : v;
      td.title = td.textContent;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  let txt = `${total ? start + 1 : 0}–${start + pageRows.length} of ${total}`;
  if (baseCount != null && total !== baseCount) txt += ` (filtered from ${baseCount})`;
  if (spec.opts && spec.opts.truncated) txt += ` · capped at ${(spec.rows || []).length} of ${spec.opts.nrows}`;
  info.textContent = txt;
  const pages = Math.max(1, Math.ceil(total / st.pageSize));
  pag.innerHTML = '';
  if (pages > 1) {
    const mk = (label, to, disabled) => {
      const b = document.createElement('button'); b.textContent = label; b.disabled = disabled;
      b.onclick = () => { st.page = to; _refreshTable(wrap, spec, st); }; return b;
    };
    pag.appendChild(mk('‹ prev', st.page - 1, st.page <= 0));
    const lbl = document.createElement('span'); lbl.className = 'st-page';
    lbl.textContent = `page ${st.page + 1} / ${pages}`; pag.appendChild(lbl);
    pag.appendChild(mk('next ›', st.page + 1, st.page >= pages - 1));
  }
}

// Typeset any LaTeX ($…$ / $$…$$ / \(…\) / \[…\]) inside `el` with KaTeX. Safe to
// call before KaTeX has loaded (no-op) and re-call (auto-render skips done spans).
// CodeMirror source lives in <pre>/<textarea>, both in KaTeX's default ignore list,
// so editor `$` is never touched.
function typeset(el) {
  if (!el) return;
  // Output `text/latex` blocks render in DISPLAY mode so they match markdown
  // `$$…$$` sizing (a LaTeXString arrives as inline `$…$`, which KaTeX would
  // otherwise typeset cramped). Render them explicitly first; cache the raw TeX
  // on the node so re-typeset (every /state poll) stays idempotent.
  if (typeof katex !== 'undefined' && el.querySelectorAll) {
    const blocks = el.matches && el.matches('.disp.latex') ? [el] : [...el.querySelectorAll('.disp.latex')];
    blocks.forEach(d => {
      if (d.dataset.tex === undefined) d.dataset.tex = d.textContent;
      let t = d.dataset.tex.trim();
      if (t.startsWith('$$') && t.endsWith('$$')) t = t.slice(2, -2);
      else if (t.startsWith('$') && t.endsWith('$')) t = t.slice(1, -1);
      else if (t.startsWith('\\[') && t.endsWith('\\]')) t = t.slice(2, -2);
      else if (t.startsWith('\\(') && t.endsWith('\\)')) t = t.slice(2, -2);
      try { katex.render(t, d, { displayMode: true, throwOnError: false }); } catch (e) {}
    });
  }
  if (typeof renderMathInElement !== 'function') return;
  try {
    renderMathInElement(el, {
      delimiters: [
        { left: '$$', right: '$$', display: true },
        { left: '\\[', right: '\\]', display: true },
        { left: '$', right: '$', display: false },
        { left: '\\(', right: '\\)', display: false },
      ],
      throwOnError: false,
    });
  } catch (e) {}
}
// KaTeX may finish loading after the first render; typeset everything once it's in.
window.addEventListener('load', () => typeset(document.getElementById('nb')));
// Align the agent drawer's top with the first content cell (as positioned when scrolled
// to the top), so the drawer never covers the menu bar and lines up with the notebook.
// Measured off the real first cell — robust to topbar height, page padding, cell margins,
// font size and zoom. --topbar-h is the pre-measure fallback (see .agentpanel CSS).
function syncAgentTop() {
  const tb = document.querySelector('.topbar');
  if (tb) document.documentElement.style.setProperty('--topbar-h', tb.offsetHeight + 'px');
  // Document-flow top of the first cell (rect.top + scrollY) == its viewport position at
  // scroll 0, which is exactly the fixed drawer's `top`. Fall back to the cells container.
  const ref = document.querySelector('#nb .cell') || document.getElementById('nb');
  if (ref) {
    const top = Math.round(ref.getBoundingClientRect().top + window.scrollY);
    document.documentElement.style.setProperty('--agent-top', top + 'px');
  }
}
window.addEventListener('load', syncAgentTop);
window.addEventListener('resize', syncAgentTop);
syncAgentTop();

// Julia indexes source by UTF-8 *byte* offset (REPLCompletions), but CodeMirror
// works in UTF-16 char positions. Convert both ways so completion stays correct
// once the cell contains unicode (π, etc.) — otherwise the replace range drifts.
const _enc = new TextEncoder(), _dec = new TextDecoder();
const _byteLen = s => _enc.encode(s).length;
const _charFromByte = (code, b) => _dec.decode(_enc.encode(code).slice(0, b)).length;

// One-glyph icon per completion kind (mirrors the server's `_comp_kind`). The class
// `cmh-<kind>` colours it (see notebook.css). Unknown kinds fall back to a neutral dot.
const _KIND_ICON = { local: 'v', var: 'v', const: 'c', function: 'ƒ', method: 'ƒ', type: 'T',
  module: 'M', field: '.', kwarg: '=', keyword: 'K', latex: '\\', path: '/', key: '#', text: '·', bind: '⊞', str: '"' };
function _renderHint(elt, _data, cur) {
  const ic = document.createElement('span');
  ic.className = 'cmh-ic cmh-' + (cur.kind || 'text');
  ic.textContent = _KIND_ICON[cur.kind] || '·';
  const tx = document.createElement('span');
  tx.className = 'cmh-tx'; tx.textContent = cur.displayText || cur.text;
  elt.appendChild(ic); elt.appendChild(tx);
  if (cur.kind && !/^(text|var|local)$/.test(cur.kind)) {     // a faint kind label on the right
    const kd = document.createElement('span'); kd.className = 'cmh-kd'; kd.textContent = cur.kind;
    elt.appendChild(kd);
  }
}
// ── Signature placeholders ────────────────────────────────────────────────────
// A method row is a *signature* (e.g. after `damped_wave(`). Picking it (Enter) must NOT
// paste the signature string; instead it drops the positional params in as ghosted
// placeholders you type over, Tab cycling between them. They stay "background"-styled
// (`.cmh-ph`) until edited. State rides on `cm._ph` so view.js's Tab handler can advance.

// Split an argument list on TOP-LEVEL commas (so `x::Tuple{Int,Int}` stays one arg).
function _splitArgs(s) {
  const out = []; let depth = 0, buf = '';
  for (const c of s) {
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ',' && depth === 0) { out.push(buf); buf = ''; continue; }
    buf += c;
  }
  if (buf.trim()) out.push(buf);
  return out;
}
// Positional params (name + type, e.g. "n::Integer") from a signature like
// "damped_wave(n::Integer; freq, decay)". Type is kept so the placeholder shows it.
function _sigParams(sig) {
  const m = sig.match(/\(([\s\S]*)\)/); if (!m) return [];
  return _splitArgs(m[1].split(';')[0])             // positional part (before kwargs)
    .map(s => s.trim()).filter(s => s && s !== '...');
}
// Map one raw completion item to a CodeMirror hint entry.
function _toHintItem(it) {
  if (typeof it === 'string') return { text: it, displayText: it };
  if (it.kind === 'method')                          // signature row: Enter fills its params
    return { text: it.text, kind: 'method', displayText: it.text.split(' @ ')[0], render: _renderHint, hint: _pickSignature };
  if (it.kind === 'str')                             // string macro (`colorant"`): show name"…" + auto-close
    return { text: it.text, kind: 'str', displayText: it.text.replace(/"$/, '') + '"…"', render: _renderHint, hint: _insertStrMacro };
  return { text: it.text, kind: it.kind, render: _renderHint };
}
// Accept a string-macro completion: replace the typed prefix with `name""` and drop the cursor
// between the quotes (so `colora`→`colorant"⎸"`), instead of leaving a stray opening quote.
function _insertStrMacro(cm, data, completion) {
  _hideHintDoc();
  const name = completion.text;                      // e.g. 'colorant"'
  cm.replaceRange(name + '"', data.from, data.to);
  cm.setCursor({ line: data.from.line, ch: data.from.ch + name.length });   // between the two quotes
}
// True when the cursor sits in the keyword-argument region of the innermost call (past a
// top-level `;` inside the current unclosed `(`). REPLCompletions won't list kwargs there
// until you start typing one, so we synthesize them from the signature instead.
function _inKwargRegion(cm) {
  const s = cm.getRange({ line: cm.getCursor().line, ch: 0 }, cm.getCursor());
  let depth = 0;
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s[i];
    if (c === ')') depth++;
    else if (c === '(') { if (depth === 0) return false; depth--; }
    else if (c === ';' && depth === 0) return true;
  }
  return false;
}
// Kwarg picker entries parsed from a method signature's `; …` section. Picking inserts
// `name=` at the cursor (its `hint` overrides the popup's method-name replace range).
function _kwargItems(methodText) {
  const m = methodText.split(' @ ')[0].match(/;\s*([^)]*)\)/);
  if (!m) return [];
  return _splitArgs(m[1]).map(s => s.trim()).filter(Boolean).map(spec => {
    const name = spec.split(/[=:]/)[0].trim();
    return { text: name + '=', kind: 'kwarg', displayText: spec, render: _renderHint, hint: _insertKwarg };
  });
}
// Pick a kwarg: insert `name=` and, when the kwarg is typed, a ghosted value placeholder
// (its type) selected so you type the value over it. Untyped → just `name=`, cursor after.
function _insertKwarg(cm, _data, completion) {
  _hideHintDoc();
  const type = (completion.displayText || '').split('::')[1];
  const start = cm.getCursor();
  cm.replaceRange(completion.text + (type || ''), start);
  const afterName = { line: start.line, ch: start.ch + completion.text.length };
  if (!type) { cm.setCursor(afterName); return; }
  const to = { line: start.line, ch: afterName.ch + type.length };
  cm._ph = { stops: [cm.markText(afterName, to, { className: 'cmh-ph', inclusiveLeft: false, inclusiveRight: false })], names: [type], idx: -1 };
  _phArm(cm); _phGoto(cm, 0);
}
// The kwarg list for the call at the cursor: union the kwargs of every overload, deduped.
// Falls back to the signature rows when no kwargs are found.
function _kwargList(raw) {
  const seen = new Set(), out = [];
  for (const it of raw) {
    if (it && typeof it === 'object' && it.kind === 'method')
      for (const k of _kwargItems(it.text)) if (!seen.has(k.text)) { seen.add(k.text); out.push(k); }
  }
  return out.length ? out : raw.map(_toHintItem);
}
function _pickSignature(cm, _data, completion) {
  _hideHintDoc();
  const names = _sigParams(completion.text);
  const start = cm.getCursor();
  const rest = cm.getRange(start, { line: start.line, ch: (cm.getLine(start.line) || '').length });
  const close = /^\s*\)/.test(rest) ? '' : ')';    // add a close paren unless one's already there
  cm.replaceRange(names.join(', ') + close, start);
  const stops = [];
  let ch = start.ch;
  for (const n of names) {
    const to = { line: start.line, ch: ch + n.length };
    stops.push(cm.markText({ line: start.line, ch }, to, { className: 'cmh-ph', inclusiveLeft: false, inclusiveRight: false }));
    ch = to.ch + 2;                                 // step over ", "
  }
  if (!stops.length) return;                        // zero-arg call → just inserted `)`
  cm._ph = { stops, names, idx: -1 };
  _phArm(cm); _phGoto(cm, 0);
}
// Arm the ghost-clear handler: once a placeholder's text is edited, drop its styling.
function _phArm(cm) {
  if (cm._phClear) return;
  cm._phClear = () => {
    const ph = cm._ph; if (!ph) return;
    ph.stops.forEach((mk, i) => { const r = mk.find(); if (r && cm.getRange(r.from, r.to) !== ph.names[i]) mk.clear(); });
  };
  cm.on('change', cm._phClear);
}
// Select the next still-unfilled placeholder from `i` in direction `dir` (skipping any
// already-edited stop). Walking off the end (forward) tidies up; off the front stays put.
function _phGoto(cm, i, dir) {
  dir = dir || 1;
  const ph = cm._ph; if (!ph) return false;
  while (i >= 0 && i < ph.stops.length) {
    const r = ph.stops[i].find();
    if (r && cm.getRange(r.from, r.to) === ph.names[i]) { ph.idx = i; cm.setSelection(r.from, r.to); cm.focus(); return true; }
    i += dir;
  }
  if (dir > 0) _phEnd(cm);
  return false;
}
function _phEnd(cm) {
  const ph = cm._ph;
  if (ph && ph.stops.length) {                      // park the cursor just past the call's `)`
    const last = ph.stops[ph.stops.length - 1].find();
    if (last) cm.setCursor({ line: last.to.line, ch: last.to.ch + 1 });
  }
  if (cm._phClear) { cm.off('change', cm._phClear); cm._phClear = null; }
  cm._ph = null;
}

// Context-aware completion via the live session (Julia REPLCompletions). Includes
// LaTeX/emoji symbols — typing `\pi` and accepting inserts π. Items carry a `kind`
// (function/type/module/…) used for the icon, ranking, and the doc preview.
function juliaHint(cm, callback) {
  const code = cm.getValue();
  const pos = _byteLen(code.slice(0, cm.indexFromPos(cm.getCursor())));
  fetch(_apipath('/api/complete'), {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ code, pos })
  }).then(r => r.json()).then(d => {
    const raw = d.completions || [];
    const hasMethod = raw.some(it => it && typeof it === 'object' && it.kind === 'method');
    const list = (hasMethod && _inKwargRegion(cm)) ? _kwargList(raw) : raw.map(_toHintItem);
    const data = {
      list,
      from: cm.posFromIndex(_charFromByte(code, d.from)),
      to: cm.posFromIndex(_charFromByte(code, d.to))
    };
    CodeMirror.on(data, 'select', _onHintSelect);   // doc preview for the highlighted item
    CodeMirror.on(data, 'close', _hideHintDoc);
    CodeMirror.on(data, 'pick', _hideHintDoc);
    callback(data);
  }).catch(() => callback({ list: [], from: cm.getCursor(), to: cm.getCursor() }));
}
juliaHint.async = true;

// ── Completion doc preview ────────────────────────────────────────────────────
// A floating card beside the popup showing the highlighted symbol's docstring,
// fetched lazily from /api/help (same live lookup the docs palette uses) and cached.
// Skipped for kinds with nothing to look up (locals, keywords, fields, latex, paths).
let _hintDocEl = null, _hintDocTimer = null, _hintGen = 0, _hintDocWatch = null;
const _hintDocCache = {};
const _NO_DOC = { local: 1, var: 1, keyword: 1, kwarg: 1, latex: 1, path: 1, key: 1, field: 1, bind: 1 };
// Bumping the generation supersedes any in-flight async doc fetch — so a late /api/help reply
// can't re-show the card after the popup closed (stuck) or moved (ghost in the corner).
function _hideHintDoc() { _hintGen++; clearTimeout(_hintDocTimer); clearInterval(_hintDocWatch); _hintDocWatch = null; if (_hintDocEl) _hintDocEl.style.display = 'none'; }
// Force-close any open completion popup AND its doc card — the hard reset used by the
// outside-click / window-blur safety nets so neither can strand on screen.
function _closeAllHints() {
  try { Object.values(editors).forEach(cm => { const a = cm && cm.state && cm.state.completionActive; if (a) a.close(); }); } catch (_) {}
  _hideHintDoc();
}
// Clicking anywhere outside the popup/card, or the window losing focus, tears completion down.
document.addEventListener('mousedown', e => {
  if (e.target.closest && (e.target.closest('.CodeMirror-hints') || e.target.closest('.cmh-doc'))) return;
  _closeAllHints();
}, true);
window.addEventListener('blur', _closeAllHints);
function _onHintSelect(item, node) {
  _hintGen++; const gen = _hintGen;
  clearTimeout(_hintDocTimer);
  if (!item || !item.text || _NO_DOC[item.kind]) return _hideHintDoc();
  _hintDocTimer = setTimeout(() => _loadHintDoc(item, node, gen), 130);
}
function _loadHintDoc(item, node, gen) {
  if (gen !== _hintGen) return;                                          // superseded before the fetch even started
  const kind = item.kind;
  const name = kind === 'method' ? item.text.split('(')[0]                // method row → the function's docs
             : kind === 'str' ? '@' + item.text.replace(/"$/, '') + '_str'  // colorant" → @colorant_str docs
             : item.text;
  if (name in _hintDocCache) return _showHintDoc(_hintDocCache[name], kind, node, gen);
  api('GET', '/api/help?name=' + encodeURIComponent(name)).then(r => {
    const html = (r && r.docHtml) ? r.docHtml : '';
    _hintDocCache[name] = html; _showHintDoc(html, kind, node, gen);
  }).catch(() => {});
}
function _showHintDoc(html, kind, node, gen) {
  if (gen !== _hintGen) return;                       // a newer select/close happened — drop this stale show
  if (!node || !node.isConnected) return _hideHintDoc();   // popup gone → never strand a card in the corner
  if (!html) return _hideHintDoc();
  if (!_hintDocEl) { _hintDocEl = document.createElement('div'); _hintDocEl.className = 'cmh-doc'; document.body.appendChild(_hintDocEl); }
  _hintDocEl.innerHTML = '<div class="cmh-doc-k">' + (kind || '') + '</div>' + html;
  _hintDocEl.style.display = 'block';
  const ul = node && node.parentNode, r = (ul || node) && (ul || node).getBoundingClientRect();
  if (!r) return;
  const W = 360, M = 8, h = _hintDocEl.offsetHeight, vh = window.innerHeight;
  // keep the card fully on screen: clamp its bottom into the viewport, then its top.
  _hintDocEl.style.top = Math.max(M, Math.min(r.top, vh - M - h)) + 'px';
  _hintDocEl.style.left = (r.right + M + W > window.innerWidth ? Math.max(M, r.left - M - W) : r.right + M) + 'px';
  // Slave the card's lifetime to the popup: however the popup goes away (close event, blur,
  // click-away, DOM detach on re-render), drop the card the moment it's gone. This is the
  // backstop for the card getting "stuck" when no close/select event reaches us.
  clearInterval(_hintDocWatch);
  _hintDocWatch = setInterval(() => { if (!document.querySelector('.CodeMirror-hints')) _hideHintDoc(); }, 200);
}

// Pulse the kernel dot while a compute-triggering request is in flight. POSTs that
// don't run cells (chat, completion, rename, agent log) are excluded.
let _busy = 0;
const _noBusy = /\/(chat|agent-log|complete|cell-rename)/;
const setBusy = () => document.getElementById('wdot').classList.toggle('busy', _busy > 0);
async function api(method, path, body) {
  const track = method === 'POST' && !_noBusy.test(path);
  if (track) { _busy++; setBusy(); }
  try {
    const r = await fetch(_apipath(path), {
      method, headers: {'Content-Type': 'application/json'},
      body: body ? JSON.stringify(body) : undefined
    });
    return r.json();
  } catch (e) {
    _showDisconnect();          // network error → the server is unreachable; surface it (don't fail silently)
    throw e;
  } finally { if (track) { _busy--; setBusy(); } }
}
// While disconnected, in-flight api() calls reject (a cell mid-run, a poll, …). The modal already
// explains it, so swallow those rejections rather than spamming the console with red noise.
window.addEventListener('unhandledrejection', e => { if (typeof _connDown !== 'undefined' && _connDown) e.preventDefault(); });

