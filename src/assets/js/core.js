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
window._cancelSnap = cellId => { clearTimeout(_snapPending[cellId]); delete _snapPending[cellId]; };
function _snapCell(cellId, insts, spec) {
  clearTimeout(_snapPending[cellId]);
  _snapPending[cellId] = setTimeout(() => {
    delete _snapPending[cellId];
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
        if (themeName === 'slate') _ensureSlateTheme();
        off = echarts.init(div, themeName, { renderer: 'svg', width: w, height: h });
        off.setOption(Object.assign({ backgroundColor: bg }, pub));
        return off.renderToSVGString();
      } catch (_) { return ''; }
      // ALWAYS tear down the offscreen instance + div — without this, a throw in setOption/render
      // leaked an ECharts instance (live zrender) + a detached node on every failed snapshot.
      finally { if (off) { try { off.dispose(); } catch (_) {} } if (div) div.remove(); }
    };
    if (spec) { svg = renderSvg(null, '#ffffff'); svgDark = renderSvg('slate', '#12141c'); }
    if (png) fetch(_apipath('/api/snapshot'), { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cell: cellId, image: png, svg: svg || undefined, svgDark: svgDark || undefined }) }).catch(() => {});
  }, 700);
}

// Geo maps: a spec may carry `registerMap` — {name, url} (or a list) declaring GeoJSON the chart
// needs (Slate serves a vendored world at /assets/maps/world.json). Each map is fetched + passed to
// echarts.registerMap ONCE per page (in-flight promise shared); setOption waits on it so a geo chart
// renders complete on first paint. The key is stripped before setOption (it isn't an ECharts option).
const _mapRegistry = {};                             // name → Promise (registration done/in flight)
function _ensureMaps(spec) {
  const reqs = spec && spec.registerMap ? [].concat(spec.registerMap) : [];
  return Promise.all(reqs.map(r => {
    if (!r || !r.name || !r.url || (echarts.getMap && echarts.getMap(r.name))) return Promise.resolve();
    if (!_mapRegistry[r.name])
      _mapRegistry[r.name] = fetch(r.url).then(x => x.json())
        .then(j => echarts.registerMap(r.name, j))
        .catch(() => { delete _mapRegistry[r.name]; });   // failed fetch → retry on a later render
    return _mapRegistry[r.name];
  }));
}
function _sansMaps(s) {
  if (!s || (!s.registerMap && !s.__size)) return s;
  const c = Object.assign({}, s); delete c.registerMap; delete c.__size; return c;
}
// Slate `height=`/`width=` chart kwargs ride as `__size` — apply to the chart's DIV (a number is
// px; any CSS length string passes through), then let the instance re-measure. No-op when unchanged.
function _applySize(el, inst, s) {
  const sz = (s && s.__size) || {};
  const css = v => v == null ? '' : (typeof v === 'number' ? v + 'px' : String(v));
  const h = css(sz.height), w = css(sz.width);
  let changed = false;
  if (el.style.height !== h) { el.style.height = h; changed = true; }
  if (el.style.width !== w) { el.style.width = w; changed = true; }
  if (changed && inst) try { inst.resize(); } catch (_) {}
}

// ── The shared "Slate look" ECharts theme ───────────────────────────────────────────────────
// Registered from the live CSS custom properties (the same brand palette the UI + Makie use — see
// slate_look.jl), so interactive charts match the notebook instead of ECharts' generic 'dark', and
// FOLLOW the active Slate theme. Built once, lazily (echarts must be loaded); rebuilt on a theme
// switch (window._onSlateThemeChange). Series colour cycle order mirrors slate_series_cycle() in Julia.
let _slateThemeReady = false;
function _slateThemeVar(cs, name, dflt) { const v = cs.getPropertyValue(name).trim(); return v || dflt; }
function _slateAxisTheme(line, label) {
  return { axisLine: { lineStyle: { color: line } }, axisTick: { lineStyle: { color: line } },
    axisLabel: { color: label }, splitLine: { lineStyle: { color: line, opacity: 0.4 } },
    splitArea: { areaStyle: { color: ['transparent', 'transparent'] } } };
}
function _slateEchartsTheme() {
  const cs = getComputedStyle(document.documentElement);
  const V = (n, d) => _slateThemeVar(cs, n, d);
  const text = V('--text', '#d4d8e8'), dim = V('--dim', '#6a7090'),
        border = V('--border', '#2a2e40'), bg2 = V('--bg2', '#141828');
  const cycle = [['--accent', '#569cd6'], ['--green', '#56d364'], ['--orange', '#ce9178'],
    ['--purple', '#c586c0'], ['--teal', '#4ec9b0'], ['--gold', '#ffd700'], ['--red', '#e57575']]
    .map(([n, d]) => V(n, d));
  const ax = _slateAxisTheme(border, dim);
  return {
    color: cycle, backgroundColor: 'transparent',
    textStyle: { color: text, fontFamily: 'inherit' },
    title: { textStyle: { color: text }, subtextStyle: { color: dim } },
    legend: { textStyle: { color: dim } },
    categoryAxis: ax, valueAxis: ax, logAxis: ax, timeAxis: ax,
    line: { symbolSize: 5 }, graph: { color: cycle },
    tooltip: { backgroundColor: bg2, borderColor: border, textStyle: { color: text } },
    visualMap: { textStyle: { color: dim } },
    timeline: { lineStyle: { color: dim }, label: { color: dim } },
    calendar: { splitLine: { lineStyle: { color: border } }, itemStyle: { borderColor: border } },
  };
}
function _ensureSlateTheme() {
  if (_slateThemeReady || typeof echarts === 'undefined') return;
  try { echarts.registerTheme('slate', _slateEchartsTheme()); _slateThemeReady = true; } catch (_) {}
}
// A Slate theme switch changed the CSS vars: rebuild the 'slate' theme and re-init every chart under
// it (ECharts snapshots a theme at init, so a restyle means dispose + re-create + re-setOption).
window._onSlateThemeChange = () => {
  try {
    _slateThemeReady = false; _ensureSlateTheme();
    Object.values(window.charts || {}).forEach(list => (list || []).forEach(i => { try { i.dispose(); } catch (_) {} }));
    window.charts = {};
    document.querySelectorAll('.echart, .ichart').forEach(e => { if (e._inst) { try { e._inst.dispose(); } catch (_) {} e._inst = null; } });
    ((window.__slateState || {}).cells || []).forEach(c => { try { renderCharts(c); } catch (_) {} });
  } catch (_) {}
};

// Render/refresh a cell's ECharts. Instances persist across reactive updates, so
// data changes animate in place (setOption) instead of swapping an image.
function renderCharts(c) {
  const specs = c.echarts || [];
  const host = document.querySelector('#cell-' + c.id + ' .echarts');
  if (host) {                                   // code-cell echarts host
    if (!charts[c.id]) charts[c.id] = [];
    // A Preact re-render OCCASIONALLY recreates the cell subtree (it usually preserves it):
    // the host div comes back empty while the persisted instances still point at DETACHED
    // divs — setOption then paints an off-document canvas (blank output, no error). Drop
    // any instance whose DOM is no longer inside THIS host, and any host child that lost
    // its instance, before reconciling counts.
    const insts = charts[c.id] = charts[c.id].filter(inst => {
      const dom = inst.getDom && inst.getDom();
      if (dom && host.contains(dom)) return true;
      try { inst.dispose(); } catch (_) {}
      return false;
    });
    Array.from(host.children).forEach(ch => {
      if (!insts.some(inst => inst.getDom() === ch)) host.removeChild(ch);
    });
    while (host.children.length < specs.length) {
      const d = document.createElement('div'); d.className = 'echart'; host.appendChild(d);
      _ensureSlateTheme(); insts.push(echarts.init(d, 'slate'));
    }
    while (host.children.length > specs.length) { host.removeChild(host.lastChild); const inst = insts.pop(); if (inst) try { inst.dispose(); } catch (_) {} }
    specs.forEach((s, i) => _applySize(host.children[i], insts[i], s));
    Promise.all(specs.map((s, i) => _ensureMaps(s).then(() => _geoSafeSetOption(insts[i], s))))
      .then(() => { if (insts.length) _snapCell(c.id, insts, _sansMaps(specs[0])); });
    _healSizesSoon(insts);
  }
  // Inline `{{ echart(…) }}` placeholders in a markdown cell.
  document.querySelectorAll('#cell-' + c.id + ' .ichart').forEach(el => {
    const spec = specs[+el.dataset.i]; if (!spec) return;
    if (!el._inst) { _ensureSlateTheme(); el._inst = echarts.init(el, 'slate'); }
    _applySize(el, el._inst, spec);
    _ensureMaps(spec).then(() => _geoSafeSetOption(el._inst, spec));
  });
}
// setOption that can't leave a DEAD geo bind. If a spec needs a registered map but a setOption ever
// ran before registration (fetch in flight, or a transient fetch failure), ECharts silently binds the
// series to a broken geo — the map later merges in but the points keep a full-canvas layout ("zoom
// disconnected from the scatter"). Heal: on the first render where the map IS registered, clear()
// once to force a fresh coordinate bind; after that never clear again (preserves the user's roam).
function _geoSafeSetOption(inst, s) {
  if (!inst) return;
  try {
    const reqs = s && s.registerMap ? [].concat(s.registerMap) : [];
    const ready = reqs.every(r => r && r.name && echarts.getMap && echarts.getMap(r.name));
    if (reqs.length && ready && !inst.__mapsReady) { inst.clear(); inst.__mapsReady = true; }
    inst.setOption(_sansMaps(s));
    // Canvas-size self-heal: if layout/CSS changed the div since init (fonts settling, panel
    // toggles), the internal canvas keeps the stale size and every component lays out against it.
    const dom = inst.getDom();
    if (dom && (dom.clientWidth !== inst.getWidth() || dom.clientHeight !== inst.getHeight()))
      inst.resize();
  } catch (e) {}
}
window.addEventListener('resize', () => Object.values(charts).flat().forEach(c => c.resize()));
// Late size heal: a chart initialized before its div finished layout has a 0×0 canvas, and
// the synchronous heal inside _geoSafeSetOption can't see the final size yet (clientWidth
// is still 0 in the same frame). Check again next frame and once more after layout settles.
function _healSizesSoon(insts) {
  const heal = () => insts.forEach(inst => {
    try {
      const dom = inst.getDom && inst.getDom();
      if (dom && dom.isConnected && (dom.clientWidth !== inst.getWidth() || dom.clientHeight !== inst.getHeight()))
        inst.resize();
    } catch (_) {}
  });
  requestAnimationFrame(heal);
  setTimeout(heal, 250);
}

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
// Columns are {name,type,align,format,sortable,filterable} objects (older specs may be bare strings).
const _colName = c => (typeof c === 'string' ? c : c.name);

// ── Cell formatter — the JS mirror of Julia `_format_cell` (src/format.jl) ────
// MUST match the Julia output; the golden fixture test/fixtures/format_cases.json is asserted from
// both sides. Rounding is hand-rolled (half-away-from-zero) to avoid `toFixed` divergence.
function _asNumber(v) {
  if (typeof v === 'number') return isFinite(v) ? v : null;
  if (typeof v === 'boolean') return null;
  if (typeof v === 'string') { const n = parseFloat(v); return isNaN(n) ? null : n; }
  return null;
}
function _roundDec(x, d) {                          // half-away-from-zero → plain decimal string
  const neg = x < 0;
  const u = Math.floor(Math.abs(x) * Math.pow(10, d) + 0.5);
  let s = String(u);
  if (d > 0) { while (s.length < d + 1) s = '0' + s; s = s.slice(0, s.length - d) + '.' + s.slice(s.length - d); }
  return (neg && u !== 0) ? '-' + s : s;
}
function _group3(dec) {
  const neg = dec[0] === '-', body = neg ? dec.slice(1) : dec;
  const dot = body.indexOf('.'), ip = dot < 0 ? body : body.slice(0, dot), rest = dot < 0 ? '' : body.slice(dot);
  let out = ''; const n = ip.length;
  for (let i = 0; i < n; i++) { if (i > 0 && (n - i) % 3 === 0) out += ','; out += ip[i]; }
  return (neg ? '-' : '') + out + rest;
}
const _maybeGroup = (dec, sep) => (sep ? _group3(dec) : dec);
function _sci(x, sig) {
  if (x === 0) return '0e0';
  const neg = x < 0, ax = Math.abs(x); let e = Math.floor(Math.log10(ax)); const m = ax / Math.pow(10, e);
  let ms = _roundDec(m, Math.max(sig - 1, 0));
  if (parseFloat(ms) >= 10) { e += 1; ms = _roundDec(m / 10, Math.max(sig - 1, 0)); }
  return (neg ? '-' : '') + ms + 'e' + String(e);
}
const _BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
function _bytes(x, d) {
  const neg = x < 0; let ax = Math.abs(x), i = 0;
  while (ax >= 1024 && i < _BYTE_UNITS.length - 1) { ax /= 1024; i++; }
  return (neg ? '-' : '') + _roundDec(ax, i === 0 ? 0 : d) + ' ' + _BYTE_UNITS[i];
}
// Clean default render for a raw value when a column has NO explicit format (mirrors Julia
// `_clean_default`): numbers via native String() (already trims `.0` and avoids sci for normal ranges).
function _cleanDefault(v) { return v == null ? '' : String(v); }
function fmtCell(value, fmt) {
  if (value == null) return '';
  if (!fmt) return _cleanDefault(value);
  const n = _asNumber(value);
  if (n === null) return String(value);            // non-numeric cell in a formatted column → raw
  const kind = fmt.kind || 'fixed';
  const digits = (fmt.digits != null) ? fmt.digits : null;
  const sep = !!fmt.sep, prefix = fmt.prefix || '', suffix = fmt.suffix || '';
  let body;
  if (kind === 'integer') body = _maybeGroup(_roundDec(n, 0), sep);
  else if (kind === 'percent') body = _roundDec(n * 100, digits == null ? 1 : digits) + '%';
  else if (kind === 'currency') body = _maybeGroup(_roundDec(n, digits == null ? 2 : digits), sep);
  else if (kind === 'scientific') body = _sci(n, digits == null ? 3 : digits);
  else if (kind === 'bytes') body = _bytes(n, digits == null ? 1 : digits);
  else body = _maybeGroup(_roundDec(n, digits == null ? 2 : digits), sep);   // fixed
  const neg = body[0] === '-';                      // sign sits OUTSIDE the prefix: -$1,234.50
  const core = neg ? body.slice(1) : body;
  return (neg ? '-' : '') + prefix + core + suffix;
}
// ── end cell formatter (marker for the Node parity test test/js/format_parity.mjs) ──
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
// `sel` (optional) turns on ROW SELECTION (TableSelect @bind): {value, onSelect(origIdx1)} — rows
// become clickable and the row at 1-based ORIGINAL index `value()` is highlighted. Sorting/filtering
// reorder the view, so each row carries its original index (into spec.rows), which is what's bound.
function drawTable(wrap, spec, st, sel) {
  wrap._sel = sel || null;
  // Keep the CURRENT spec on the element. The persistent sort/filter/viz handlers are built ONCE in
  // _buildShell (the shell isn't rebuilt while the column signature is unchanged), so they must read the
  // live spec here rather than one captured at build time — a reactively-growing table replaces spec.rows
  // (e.g. 1 → 15) without a shell rebuild, and a stale closure would sort/filter the original tiny spec.
  wrap._spec = spec;
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
  const doFilter = () => { st.filter = fi.value; st.page = 0; _refreshTable(wrap, wrap._spec, st); };
  fi.oninput = spec.paged ? debounce(doFilter, 250) : doFilter;   // paged hits the server → debounce
  const info = document.createElement('span'); info.className = 'st-info';
  bar.appendChild(fi); bar.appendChild(info);
  if (cols.some(c => c && c.viz)) {                          // in-cell viz present → a show/hide toggle
    const vb = document.createElement('button'); vb.className = 'st-viztoggle'; vb.title = 'toggle in-cell bars / heat';
    vb.textContent = st.vizOff ? '▢ viz' : '▤ viz';
    vb.onclick = () => { st.vizOff = !st.vizOff; vb.textContent = st.vizOff ? '▢ viz' : '▤ viz'; _refreshTable(wrap, wrap._spec, st); };
    bar.appendChild(vb);
  }
  wrap.appendChild(bar);
  const tbl = document.createElement('table'); tbl.className = 'st-table';
  const thead = document.createElement('thead'); const htr = document.createElement('tr');
  const ths = cols.map((c, ci) => {
    const th = document.createElement('th'); th.dataset.label = _colName(c);
    const sortable = typeof c === 'string' || c.sortable !== false;
    if (sortable) th.onclick = () => {
      if (st.sort && st.sort.col === ci) st.sort.dir = st.sort.dir === 'asc' ? 'desc' : 'asc';
      else st.sort = { col: ci, dir: 'asc' };
      _refreshTable(wrap, wrap._spec, st);
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
  // Carry each row's ORIGINAL index [row, i] through filter+sort so a selected row still maps back to
  // its position in spec.rows (the bound value) after the view is reordered.
  let idxd = allRows.map((r, i) => [r, i]);
  if (f) idxd = idxd.filter(([r]) => r.some(v => v != null && String(v).toLowerCase().includes(f)));
  if (st.sort) {
    const col = st.sort.col, mul = st.sort.dir === 'desc' ? -1 : 1;
    idxd = idxd.slice().sort((a, b) => _cmp(a[0][col], b[0][col]) * mul);
  }
  const total = idxd.length;
  const pages = Math.max(1, Math.ceil(total / st.pageSize));
  st.page = Math.min(Math.max(0, st.page), pages - 1);
  const start = st.page * st.pageSize;
  const page = idxd.slice(start, start + st.pageSize);
  _fillTable(wrap, spec, st, page.map(x => x[0]), total, allRows.length, page.map(x => x[1]));
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
// Shared render of one page into the shell (body rows, info line, pagination). `pageIdx` (optional,
// eager tables) is each page row's ORIGINAL index — used only in selection mode.
function _fillTable(wrap, spec, st, pageRows, total, baseCount, pageIdx) {
  const { info, tbody, pag } = wrap._refs;
  _drawArrows(wrap, st);
  const start = st.page * st.pageSize;
  const sel = wrap._sel;                                 // selection mode (TableSelect), else null
  const curSel = sel ? (sel.value() || 0) : 0;           // 1-based original index currently bound
  tbody.innerHTML = '';
  const cols = spec.columns || [];
  pageRows.forEach((r, k) => {
    const tr = document.createElement('tr');
    r.forEach((v, ci) => {
      const col = cols[ci] || {};
      const td = document.createElement('td');
      const numeric = col.type === 'int' || col.type === 'float' || (col.type == null && typeof v === 'number');
      const align = col.align || (numeric ? 'right' : 'left');   // ColumnDef.align (default from type)
      td.className = (numeric ? 'num ' : '') + 'align-' + align;
      td.textContent = col.format ? fmtCell(v, col.format) : _cleanDefault(v);
      td.title = td.textContent;
      if (col.viz && col.domain && !st.vizOff && typeof v === 'number') {   // in-cell bar/heat (toggleable), scaled over the domain
        const lo = col.domain[0], hi = col.domain[1], f = hi > lo ? Math.max(0, Math.min(1, (v - lo) / (hi - lo))) : 1;
        if (col.viz === 'bar') { const p = (f * 100).toFixed(1); td.style.background = 'linear-gradient(to right,rgba(88,166,255,.20) ' + p + '%,transparent ' + p + '%)'; }
        else if (col.viz === 'heat') td.style.background = 'rgba(88,166,255,' + (0.05 + 0.32 * f).toFixed(3) + ')';
      }
      tr.appendChild(td);
    });
    if (sel && pageIdx) {                                // clickable, highlightable selection row
      const oi = pageIdx[k] + 1;                         // 1-based original index = the bound value
      tr.dataset.row = oi;
      tr.classList.add('selrow');
      if (oi === curSel) tr.classList.add('on');
      tr.onclick = () => sel.onSelect(oi);
    }
    tbody.appendChild(tr);
  });
  let txt = `${total ? start + 1 : 0}–${start + pageRows.length} of ${total}`;
  if (baseCount != null && total !== baseCount) txt += ` (filtered from ${baseCount})`;
  if (spec.opts && spec.opts.truncated) txt += ` · capped at ${(spec.rows || []).length} of ${spec.opts.nrows}`;
  info.textContent = txt;
  const pages = Math.max(1, Math.ceil(total / st.pageSize));
  pag.innerHTML = '';
  if (pages > 1) {
    const go = to => { st.page = Math.max(0, Math.min(pages - 1, to)); _refreshTable(wrap, wrap._spec, st); };
    const mk = (label, to, disabled) => {
      const b = document.createElement('button'); b.textContent = label; b.disabled = disabled;
      b.onclick = () => go(to); return b;
    };
    pag.appendChild(mk('«', 0, st.page <= 0));                    // first
    pag.appendChild(mk('‹ prev', st.page - 1, st.page <= 0));
    const lbl = document.createElement('span'); lbl.className = 'st-page';
    lbl.textContent = `page ${st.page + 1} / ${pages}`; lbl.title = 'click to jump to a page';
    lbl.onclick = () => {                                          // click the label → a go-to input
      const inp = document.createElement('input'); inp.type = 'number'; inp.className = 'st-goto';
      inp.min = 1; inp.max = pages; inp.value = st.page + 1;
      lbl.replaceWith(inp); inp.focus(); inp.select();
      const commit = jump => { inp.onblur = null;
        if (jump) { const n = parseInt(inp.value, 10); if (!isNaN(n)) return go(n - 1); }   // go() clamps to [1, pages]
        _refreshTable(wrap, wrap._spec, st); };
      inp.onkeydown = e => { if (e.key === 'Enter') commit(true); else if (e.key === 'Escape') commit(false); };
      inp.onblur = () => commit(true);
    };
    pag.appendChild(lbl);
    pag.appendChild(mk('next ›', st.page + 1, st.page >= pages - 1));
    pag.appendChild(mk('»', pages - 1, st.page >= pages - 1));    // last
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
// ── Background hydration scheduler ──────────────────────────────────────────────
// A big notebook's per-cell setup (mounting CodeMirror editors, typesetting KaTeX) costs ~tens of
// ms each — doing it ALL in the first render batch freezes the tab for seconds before anything
// paints. Instead, that work is ENQUEUED here and drained in small time-budgeted chunks during
// idle time: the page paints immediately (static placeholders + server-rendered HTML) and stays
// responsive while editors/math fill in behind it. Work is keyed + de-duped (newest fn wins).
const _hydQ = new Map();
let _hydPumping = false;
const _ric = window.requestIdleCallback || (f => setTimeout(() => f({ timeRemaining: () => 10 }), 16));
function _pumpHyd(deadline) {
  const budget = 14, t0 = performance.now();        // ≤14ms/chunk keeps each task well under a frame
  for (const [k, fn] of _hydQ) {
    _hydQ.delete(k);
    try { fn(); } catch (_) {}
    const left = (deadline && deadline.timeRemaining) ? deadline.timeRemaining() : (budget - (performance.now() - t0));
    if (performance.now() - t0 > budget || left < 3) break;
  }
  if (_hydQ.size) _ric(_pumpHyd); else _hydPumping = false;
}
// Enqueue keyed work to run during idle time.
window.hydrateSoon = (key, fn) => { _hydQ.set(key, fn); if (!_hydPumping) { _hydPumping = true; _ric(_pumpHyd); } };
// Run a queued task NOW, jumping the idle queue — for a cell the user is about to interact with.
window.hydrateNow = key => { const fn = _hydQ.get(key); if (fn) { _hydQ.delete(key); try { fn(); } catch (_) {} return true; } return false; };
// Typeset KaTeX off the critical path (text paints first; math fills in a tick later).
window.typesetSoon = (el, key) => { if (el) window.hydrateSoon('ts:' + (key || ''), () => typeset(el)); };
// Typeset NOW when the element is in/near the viewport — so the math's height settles BEFORE paint
// and the cell doesn't jump (layout shift) when KaTeX renders. Off-screen elements defer to idle:
// their later typeset can't cause a *visible* shift, and they're done by the time you scroll there.
window.typesetVisible = (el, key) => {
  if (!el) return;
  const r = el.getBoundingClientRect();
  if (r.top < (window.innerHeight || 800) + 300 && r.bottom > -300) typeset(el);
  else window.typesetSoon(el, key);
};
// Jupyter-style scrolled output: a tall TEXT block (stdout / value repr / warnings) is clamped to a
// max height with an in-place scroll + an Expand/Collapse toggle, so a big-but-not-massive result
// doesn't shove the whole page down. Figures, tables, and errors are left at full height. Idempotent
// per render — measures at natural height, (re)adds or removes the toggle as the content changes.
window._clampOutputs = (root) => {
  if (!root) return;
  const MAX = 480;   // px — ~30em; matches the .clamped CSS
  root.querySelectorAll('.out, .val, .warn').forEach(b => {
    b.classList.remove('clamped');                       // measure at natural height
    const over = b.scrollHeight > MAX + 16;
    let btn = b.nextElementSibling;
    const hasBtn = btn && btn.classList && btn.classList.contains('outexpand');
    if (over) {
      if (!b.classList.contains('expanded')) b.classList.add('clamped');
      if (!hasBtn) {
        btn = document.createElement('button');
        btn.className = 'outexpand';
        btn.textContent = b.classList.contains('expanded') ? '⤡ Collapse' : '⤢ Expand';
        btn.onclick = () => {
          const ex = b.classList.toggle('expanded');
          b.classList.toggle('clamped', !ex);
          btn.textContent = ex ? '⤡ Collapse' : '⤢ Expand';
          if (!ex) {                                            // collapse → don't strand the viewport
            const head = b.closest('.cell') && b.closest('.cell').querySelector('.cellhead');
            const r = head && head.getBoundingClientRect();
            if (r && r.top < 56) window.scrollTo({ top: window.scrollY + r.top - 60 });   // header scrolled off → bring it back
            else btn.scrollIntoView({ block: 'nearest' });      // header still visible → just keep the toggle in view
          }
        };
        b.after(btn);
      }
    } else if (hasBtn) { btn.remove(); b.classList.remove('expanded'); }
  });
};
// Synchronously typeset every cell currently in/near the viewport — call right AFTER a programmatic
// scroll (e.g. position restore), before paint, so deferred math doesn't render late and shift.
window.typesetInView = () => {
  const h = window.innerHeight || 800;
  for (const el of document.querySelectorAll('.cell .md, .cell .output')) {
    const r = el.getBoundingClientRect();
    if (r.top < h + 300 && r.bottom > -300) try { typeset(el); } catch (_) {}
  }
};

// KaTeX may finish loading after the first render; typeset everything once it's in (off the
// critical path — a big notebook's math would otherwise be one long task on the load event).
window.addEventListener('load', () => window.typesetSoon(document.getElementById('nb'), '__all__'));
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

