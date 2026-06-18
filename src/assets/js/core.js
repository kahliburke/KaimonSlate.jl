// This notebook's hub id, from the /n/<id> URL; all API/SSE paths are scoped to it.
const NB_ID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
const _apipath = p => p.replace(/^\/api\//, '/api/' + NB_ID + '/');

const editors = {};
const charts = {};            // cell id -> [echarts instances]
const tableState = {};        // cell id -> [{sort,filter,page,pageSize} per table] (view prefs, sticky)
const srcMap = {};            // cell id -> raw source (for markdown editing)
const outMap = {};            // cell id -> last injected output HTML (skip redundant re-swaps)
const mdMap = {};             // cell id -> last injected markdown HTML (skip redundant re-renders)
let nbState = null;           // latest notebook state (drives the controls palette)
let _hydrating = false;       // true while a standalone's env reconstructs (read-only preview)
// Min delay (ms) between live recomputes while dragging a control. Persisted.
let updateMs = Math.max(0, parseInt(localStorage.getItem('slateUpdateMs') ?? '200', 10) || 0);
let lastVersion = -1;

const mdHtml = c => c.output || '<em class="phantom">empty markdown — double-click to edit</em>';
const srcEditHTML = () => '<div class="srcedit" style="display:none"><textarea></textarea>' +
  '<div class="mdhint">⇧⏎ commit · esc cancel</div></div>';

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
    // theme, dark bg), so each PDF theme gets a chart that reads on its background.
    // Best-effort; the server prefers these over the raster PNG when present.
    const renderSvg = (themeName, bg) => {
      try {
        const w = inst.getWidth() || 640, h = inst.getHeight() || 400;
        const div = document.createElement('div');
        div.style.cssText = 'position:absolute;left:-99999px;top:0;width:' + w + 'px;height:' + h + 'px;';
        document.body.appendChild(div);
        const off = echarts.init(div, themeName, { renderer: 'svg', width: w, height: h });
        off.setOption(Object.assign({ animation: false, backgroundColor: bg }, spec));
        const out = off.renderToSVGString();
        off.dispose(); div.remove();
        return out;
      } catch (_) { return ''; }
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
    while (host.children.length > specs.length) { host.removeChild(host.lastChild); insts.pop().dispose(); }
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

// Context-aware completion via the live session (Julia REPLCompletions). Includes
// LaTeX/emoji symbols — typing `\pi` and accepting inserts π.
function juliaHint(cm, callback) {
  const code = cm.getValue();
  const pos = _byteLen(code.slice(0, cm.indexFromPos(cm.getCursor())));
  fetch(_apipath('/api/complete'), {
    method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ code, pos })
  }).then(r => r.json()).then(d => {
    callback({
      list: d.completions || [],
      from: cm.posFromIndex(_charFromByte(code, d.from)),
      to: cm.posFromIndex(_charFromByte(code, d.to))
    });
  }).catch(() => callback({ list: [], from: cm.getCursor(), to: cm.getCursor() }));
}
juliaHint.async = true;

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
  } finally { if (track) { _busy--; setBusy(); } }
}

