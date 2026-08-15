// This notebook's hub id, from the /n/<id> URL; all API/SSE paths are scoped to it.
const NB_ID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
const _apipath = p => p.replace(/^\/api\//, '/api/' + NB_ID + '/');

// Is this page an APP (server_app.jl)? Read from the bootstrap object the server injects into
// <head>, so it is true from the very first script — `body.app` is only added on DOMContentLoaded
// and is therefore useless to anything that can run earlier.
//
// An app's server refuses the authoring API, so any BACKGROUND caller that keeps polling one of
// those routes doesn't just fail — it fails repeatedly, filling a reader's console with 403s and
// making a working app look broken to anyone who opens dev tools. The fix belongs at the callers:
// they should not be asking for authoring facilities on a page that has none.
const SLATE_IS_APP = !!(window.__SLATE_APP__ && window.__SLATE_APP__.on);

const editors = {};
const charts = {};            // cell id -> [echarts instances]
const tableState = {};        // cell id -> [{sort,filter,page,pageSize} per table] (view prefs, sticky)
const srcMap = {};            // cell id -> raw source (for markdown editing)
let nbState = null;           // latest notebook state (drives the controls palette)
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
  // The snapshot exists for the AGENT's slate_view and for PDF export — neither of which an app
  // has. Skipping saves a repeated 403 on every settle AND the `getDataURL` that precedes it,
  // which rasterises the whole chart at 2× before we'd have thrown the result away.
  if (SLATE_IS_APP) return;
  clearTimeout(_snapPending[cellId]);
  _snapPending[cellId] = setTimeout(() => {
    delete _snapPending[cellId];
    const inst = insts[0]; if (!inst) return;
    let png = '';
    // PNG (dark theme) → matches the live UI for the agent's slate_view, AND is the PDF-export
    // fallback for this cell. We used to ALSO eagerly re-render the spec offscreen as vector SVG
    // (twice — light + dark theme) on every settle, "just in case" a PDF export happened later.
    // For a large chart (a downsampled matrix heatmap can be tens of thousands of points) that's
    // an expensive SVG DOM tree built repeatedly for an export that may never happen — real
    // memory cost paid on every update, not just when exporting. `_figure_for_export`
    // (export_typst.jl) already falls back cleanly to this PNG when no SVG snapshot exists, so
    // dropping the eager SVG render costs nothing but export-time vector crispness for ECharts
    // figures specifically (Makie figures already export true vector PDF separately).
    // Match the live theme's page colour (not a hardcoded dark) so the PNG fallback reads correctly
    // on a light export too; charts declare a transparent bg, so without an explicit fill they'd come
    // through with none.
    const _bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim() || '#0e1116';
    try { png = (inst.getDataURL({ type: 'png', pixelRatio: 2, backgroundColor: _bg }) || '').split(',')[1] || ''; } catch (_) {}
    if (png) fetch(_apipath('/api/snapshot'), { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cell: cellId, image: png }) }).catch(() => {});
  }, 700);
}

// ON-DEMAND vector SVG for one cell, called via `request_live_eval` (server_snapshots.jl) only
// when a PDF/Typst export actually needs it — the replacement for the eager per-settle render
// `_snapCell` used to do. Re-renders the spec offscreen (same technique as before, just invoked
// rarely instead of on every chart update) and disposes immediately; nothing is retained after
// this returns. `themeName` is the Slate palette to render in (e.g. "midnight"/"daylight"/"nord")
// — read straight from its stylesheet rule, so the export theme is honored REGARDLESS of the theme
// the live UI is currently showing. Returns an SVG string, or '' if the cell has no live chart.
window._renderChartSvg = function (cellId, themeName) {
  const cells = ((window.__slateState || window.nbState || {}).cells) || [];
  const cell = cells.find(c => c.id === cellId);
  const spec = cell && cell.echarts && cell.echarts[0];
  if (!spec) return '';
  const inst = (window.charts && window.charts[cellId] && window.charts[cellId][0]) || null;
  const w = (inst && inst.getWidth()) || (spec.__size && spec.__size.width) || 640;
  const h = (inst && inst.getHeight()) || (spec.__size && spec.__size.height) || 400;
  const pub = _pubSpec(spec);
  const vars = _themeVarsFor(themeName);
  const bg = vars['--bg'] || '#ffffff';                          // the target palette's page colour
  let off = null, div = null;
  try {
    div = document.createElement('div');
    div.style.cssText = 'position:absolute;left:-99999px;top:0;width:' + w + 'px;height:' + h + 'px;';
    document.body.appendChild(div);
    echarts.registerTheme('__export', _slateEchartsThemeFrom((n, d) => vars[n] || d));
    off = echarts.init(div, '__export', { renderer: 'svg', width: w, height: h });
    off.setOption(Object.assign({ backgroundColor: bg }, pub));
    return off.renderToSVGString();
  } catch (_) { return ''; }
  finally { if (off) { try { off.dispose(); } catch (_) {} } if (div) div.remove(); }
};

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
// Strip the keys that ride ALONG on a spec but are not ECharts options — sizing, script prereqs, map
// registrations, and the per-series `@replay` mark. ECharts carries an unknown key into its option
// model rather than rejecting it, so they come off at the one place every setOption goes through.
function _sansMaps(s) {
  if (!s) return s;
  const marked = Array.isArray(s.series) && s.series.some(x => x && (x.__replay || x.__valuefmt));
  if (!s.registerMap && !s.__size && !s.requireScripts && !s.__valuefmt && !s.__select && !marked) return s;
  const c = Object.assign({}, s);
  delete c.registerMap; delete c.__size; delete c.requireScripts; delete c.__select;
  // Shallow-copy only the series that carry a mark — the DATA arrays are shared, not cloned, so this
  // stays cheap on a spec holding a few thousand points.
  if (marked) c.series = s.series.map(x => {
    if (!x || (!x.__replay && !x.__valuefmt)) return x;
    const y = Object.assign({}, x);
    delete y.__replay;
    if (y.__valuefmt) {
      // Per-series formatting lives on the series' own tooltip, which is what lets one chart mix
      // units — a percentage series beside a currency one.
      y.tooltip = Object.assign({}, y.tooltip, { valueFormatter: _valueFormatter(y.__valuefmt) });
      delete y.__valuefmt;
    }
    return y;
  });
  if (c.__valuefmt) {
    c.tooltip = Object.assign({}, c.tooltip, { valueFormatter: _valueFormatter(c.__valuefmt) });
    delete c.__valuefmt;
  }
  return c;
}

// `valuefmt` — the DATA half of tooltip number formatting (see echarts_dsl.jl `_valuefmt_wire`).
// ECharts wants a FUNCTION here, and a Slate spec is JSON with no reviver, so the spec crosses as
// a format object and becomes a function at the one place every setOption goes through. It reuses
// `fmtCell`, the same renderer the tables use, so a number is formatted identically whether it
// appears in a table cell or a chart tooltip. Guarded: an unformattable value falls back to its
// plain string rather than rendering "undefined" or throwing inside ECharts' tooltip path — a
// throw there wedges the axisPointer rather than failing visibly.
function _valueFormatter(fmt) {
  return function (v) {
    if (v == null || v === '') return '—';
    try { return fmtCell(v, fmt); } catch (_) { return String(v); }
  };
}

// Package-vendored front-end libraries (SlateExtensionsBase `provide_assets!`): a spec may carry
// `requireScripts` — a URL (or list of them) for JS that must load before the chart renders. The
// motivating case is echarts-gl, which registers the `globe`/`surface`/`bar3D`/`scatter3D` series
// types onto the global `echarts`; a 3D chart that `setOption`s before it loads blanks on an unknown
// series type and won't self-heal. Each URL is loaded via a <script> tag ONCE per page (in-flight
// promise shared, ordered `async=false` so dependents see their deps), and setOption waits on it — the
// exact `registerMap` discipline, generalised to any echarts extension. The key is stripped before
// setOption (not an ECharts option); a static export rewrites the URL to a page-local sibling
// (server_export.jl) so the frozen copy loads offline. A failed load resolves (doesn't reject) so one
// missing lib can't wedge every chart's render — the chart just paints without it.
const _scriptRegistry = {};                          // url → Promise (load done / in flight)
function _loadScript(url) {
  if (_scriptRegistry[url]) return _scriptRegistry[url];
  _scriptRegistry[url] = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = url; s.async = false;                    // preserve load order (echarts-gl needs echarts first)
    s.onload = () => resolve();
    s.onerror = () => { delete _scriptRegistry[url]; reject(new Error('failed to load ' + url)); };
    document.head.appendChild(s);
  });
  return _scriptRegistry[url];
}
function _ensureScripts(spec) {
  const reqs = spec && spec.requireScripts ? [].concat(spec.requireScripts) : [];
  return Promise.all(reqs.map(u => u ? _loadScript(u).catch(() => {}) : Promise.resolve()));
}
// Everything a chart's render must await before setOption: registered geo maps AND loaded libraries.
const _ensurePrereqs = spec => Promise.all([_ensureMaps(spec), _ensureScripts(spec)]);

// Generated assets (`save_asset`): a cell's `assets` specs — {path, url, mime} — populate a page-wide
// path→asset registry so `Slate.asset(path)` resolves what a widget/chart references. Live, each asset
// is fetched from its blob `url`; the SAME `Slate.asset` runs in a static export (mirrored there in
// server_export.jl `_EXPORT_ASSET_JS`), where an inlined asset carries `data` instead — one contract in
// the notebook, a standalone file, and a hosted site.
window.Slate = window.Slate || {};
window.__slateAssets = window.__slateAssets || {};
function _registerAssets(c) {
  (c && c.assets || []).forEach(a => { if (a && a.path) window.__slateAssets[a.path] = a; });   // whole spec
}
// A packed numeric asset (`save_asset` of an array) → an ndarray-lite: the TypedArray plus its shape and
// COLUMN-MAJOR layout (Julia's), with cheap `.col(k)` (a contiguous column) and `.at(i,j)` accessors —
// so a widget slices an eigenbasis column without a strided gather. `_slateTyped` mirrors `_asset_dtype`.
function _slateTyped(dtype, buf) {
  return dtype === 'f32' ? new Float32Array(buf) : dtype === 'f64' ? new Float64Array(buf) :
    dtype === 'i32' ? new Int32Array(buf) : dtype === 'i16' ? new Int16Array(buf) : new Uint8Array(buf);
}
function _slateNdarray(a, buf) {
  const data = _slateTyped(a.dtype, buf), rows = (a.shape && a.shape[0]) || data.length;
  return {
    data, dtype: a.dtype, shape: a.shape || [data.length], order: a.order || 'col', rows,
    col(k) { return this.data.subarray(k * this.rows, (k + 1) * this.rows); },   // col-major → contiguous
    at(i, j) { return this.data[j * this.rows + i]; },
  };
}
// Resolve a path from the registry, falling back to a scan of the current notebook state — so
// `Slate.asset` is ready no matter the render order (a widget can't race its own asset's registration).
// A static export has no `__slateState`; there the registry is pre-populated, so this is just the lookup.
function _lookupAsset(path) {
  if (!window.__slateAssets[path]) ((window.__slateState || {}).cells || []).forEach(_registerAssets);
  return window.__slateAssets[path];
}
window.Slate.asset = function (path) {
  const a = _lookupAsset(path);
  if (!a) return Promise.reject(new Error('Slate.asset: unknown asset ' + path));
  let get;
  if (a.data !== undefined) {                       // inlined (static export)
    const b = atob(a.data), n = b.length, u = new Uint8Array(n);
    for (let i = 0; i < n; i++) u[i] = b.charCodeAt(i);
    get = Promise.resolve(u.buffer);
  } else { get = fetch(a.url).then(r => r.arrayBuffer()); }   // served blob (live / published)
  return get.then(buf => {
    if (a.dtype) return _slateNdarray(a, buf);      // packed numeric array → ndarray-lite
    const m = a.mime || '';
    if (m.indexOf('json') >= 0) return JSON.parse(new TextDecoder().decode(buf));
    if (m.indexOf('text/') === 0) return new TextDecoder().decode(buf);
    return buf;                                     // other binary → ArrayBuffer
  });
};
// Inspect an asset's format WITHOUT loading it: `{path, kind, mime, dtype, shape, order}` (or null if
// unknown) — so a widget can branch on `ndarray`/`json`/`text`/`binary` and read a matrix's shape first.
window.Slate.assetInfo = function (path) {
  const a = _lookupAsset(path);
  if (!a) return null;
  const m = a.mime || '';
  const kind = a.dtype ? 'ndarray' : m.indexOf('json') >= 0 ? 'json' : m.indexOf('text/') === 0 ? 'text' : 'binary';
  return { path, kind, mime: a.mime, name: a.name, bytes: a.bytes, sha: a.sha, cell: a.cell,
           created: a.created, dtype: a.dtype || null, shape: a.shape || null, order: a.order || null };
};
// Every asset path currently known to the page (registry + a state scan). Handy for discovery/debugging.
window.Slate.assetPaths = function () {
  ((window.__slateState || {}).cells || []).forEach(_registerAssets);
  return Object.keys(window.__slateAssets);
};
// Save a generated asset to the reader's disk. The whole point of a `download_button` is that the
// reader ends the session with a FILE — the result of what they just computed — so this resolves
// the asset the same way `Slate.asset` does and hands it to the browser's download machinery.
// Works identically live (the asset is a served blob URL) and in a static export (it's inlined
// base64), because both shapes come out of the same registry.
window.Slate.download = function (path, filename) {
  const a = _lookupAsset(path);
  if (!a) { console.error('Slate.download: unknown asset ' + path); return; }
  const name = filename || a.name || String(path).split('/').pop();
  let href = a.url, revoke = null;
  if (a.data !== undefined) {                        // inlined (static export) → a Blob URL
    const b = atob(a.data), n = b.length, u = new Uint8Array(n);
    for (let i = 0; i < n; i++) u[i] = b.charCodeAt(i);
    href = URL.createObjectURL(new Blob([u], { type: a.mime || 'application/octet-stream' }));
    revoke = href;
  }
  const el = document.createElement('a');
  el.href = href; el.download = name; el.style.display = 'none';
  document.body.appendChild(el); el.click(); el.remove();
  // Give the download a moment to start before releasing the object URL — revoking synchronously
  // races the browser and yields an empty file.
  if (revoke) setTimeout(() => URL.revokeObjectURL(revoke), 30000);
};
// Delegated: a `download_button(...)` output renders a plain anchor carrying its asset path, so it
// survives any re-render and needs no per-instance wiring.
document.addEventListener('click', function (e) {
  const el = e.target && e.target.closest ? e.target.closest('[data-slate-download]') : null;
  if (!el) return;
  e.preventDefault();
  window.Slate.download(el.getAttribute('data-slate-download'), el.getAttribute('download') || '');
});

// True inside a LIVE notebook (served at /n/<id> with a Julia kernel + WebSocket), false in a static
// export / published page. Server-backed widgets branch on this to pick a live vs offline data path.
// Mirrored (as a constant `false`) in the static-export Slate shim, so it's always defined.
window.Slate.isLive = function () { return /^\/n\/[^\/]+/.test(location.pathname); };

// ── `@replay`: a control driving shipped data, with no kernel ────────────────────────────────────
// Everything about a replayed control EXCEPT the one call that puts a slice on screen. That last step
// is the only part that is renderer-specific (`Plotly.restyle` for SlatePlotly, `setOption` for an
// echart), so it is passed in and nothing else is duplicated per renderer.
//
// Mirrored in server_export.jl for the same reason `Slate.asset`/`Slate.isLive` are: a static page
// cannot load core.js. One contract in a live notebook, a standalone file, and a hosted site.
//
// LIVE this does nothing at all — moving a `@bind` re-runs the cell in Julia and a fresh figure
// arrives, so taking over would fight the kernel and serve stale columns. It engages only where there
// is no kernel to ask, which is exactly what `isLive()` reports.
window.Slate.replay = {
  // The control that owns a bound variable. Slate marks a rendered control with `data-name`; the
  // actual input may be that node or sit inside it.
  //
  // Scanned rather than `querySelector`'d on the name, for two reasons. A bound name is arbitrary
  // Julia — `σ` is already in use — and building a selector out of it means escaping it correctly.
  // More importantly ONE name can mark several nodes (a live cell shows three for a single slider,
  // and only the middle one holds the input), so first-match would return a host with no control and
  // the wiring would fail silently. Take the first host that actually yields an input.
  control: function (name) {
    const hosts = document.querySelectorAll('[data-name]');
    for (let i = 0; i < hosts.length; i++) {
      const h = hosts[i];
      if (h.getAttribute('data-name') !== String(name)) continue;
      const inp = (h.matches && h.matches('input,select')) ? h : h.querySelector('input,select');
      if (inp) return inp;
    }
    return null;
  },
  // Which column a control's current value selects. Matched NUMERICALLY where both sides are numbers —
  // a DOM control reports "8" as a string and Julia may have written 8.0, so comparing text would miss.
  // Falls back to string equality for categorical domains.
  index: function (domain, raw) {
    const n = Number(raw);
    if (!Number.isNaN(n)) { for (let i = 0; i < domain.length; i++) if (Number(domain[i]) === n) return i; }
    for (let j = 0; j < domain.length; j++) if (String(domain[j]) === String(raw)) return j;
    return -1;
  },
  // Slices are stacked along the LAST dimension and the buffer is column-major, so the slice for one
  // control value is a contiguous run — a view, never a gather, however large the data.
  //
  // A 1-D slice (a series) goes straight through. A 2-D slice (a heatmap `z`) has to become rows, and
  // column-major means element (r,c) sits at c*rows + r — so this transposes on the way out rather
  // than shipping a second, row-major copy.
  slice: function (packed, sweep, i) {
    const shp = (sweep.slice && sweep.slice.length) ? sweep.slice : [packed.data.length];
    const n = shp.reduce((a, b) => a * b, 1);
    const flat = packed.data.subarray(i * n, (i + 1) * n);
    if (shp.length <= 1) return Array.from(flat);
    if (shp.length === 2) {
      const rows = shp[0], cols = shp[1], out = new Array(rows);
      for (let y = 0; y < rows; y++) {
        const row = new Array(cols);
        for (let x = 0; x < cols; x++) row[x] = flat[x * rows + y];
        out[y] = row;
      }
      return out;
    }
    return Array.from(flat);        // rank ≥ 3 has no direct chart field; hand back the flat run
  },
  // `marks` each carry at least `{id, control}`; `apply(slice, mark)` is the renderer's one step.
  wire: function (marks, apply) {
    if (window.Slate.isLive()) return;
    (marks || []).forEach(function (m) {
      // A mark names a SWEEP, not an asset: what shipped — and at what resolution — is the export's
      // decision, published in this table. A mark with no entry simply never wires, so a figure whose
      // sweep was skipped leaves its control visibly disabled instead of failing at the first drag.
      const sweep = (window.__slateReplays || {})[m.id];
      if (!sweep) return;
      const input = window.Slate.replay.control(m.control);
      if (!input) return;
      const loaded = window.Slate.asset(sweep.asset);
      const readout = input.parentElement && input.parentElement.querySelector('.exp-ctl-val');
      const run = function () {
        const i = window.Slate.replay.index(sweep.domain || [], input.value);
        if (i < 0) return;
        if (readout) readout.textContent = input.value;
        loaded.then(packed => apply(window.Slate.replay.slice(packed, sweep, i), m))
              .catch(e => console.error('replay failed', e));
      };
      // `input` fires continuously while a slider is dragged; the data is already in memory, so
      // redrawing per event is cheap and gives the same feel as the live kernel path at its best.
      input.addEventListener('input', run);
      input.addEventListener('change', run);
      // The export renders every control DISABLED, because one that moves without changing anything
      // reads as a broken page. Enabling here — and only here — means a control is live exactly when
      // data for it actually rode along, with no coordination between the two sides.
      loaded.then(function () { input.disabled = false; input.removeAttribute('title'); })
            .catch(function () { /* data missing → the control stays inert, which is the truth */ });
    });
  }
};
// Resolve an `@asset` FILE (e.g. a web-cell JS module) to a loadable URL: live → the notebook's served
// `/n/<id>/asset/<path>` route; a static export overrides this to a data:/sibling URL from the inlined
// registry, so `import(Slate.assetUrl("webassets/foo.js"))` works both live and offline.
window.Slate.assetUrl = function (path) { return location.pathname + "/asset/" + path; };
// The runtime a web cell's `@web(...)` <script> calls: `Slate.runFragment(document.currentScript, fn)`.
// It hands the fragment its own `root` (the cell's output element, captured from the running script) and
// an `echo(...)` that prints a line into the cell (a `.weblog` block) plus the console; runs `fn(root,
// echo)`; and renders any thrown/rejected error ONTO the cell (a `.web-err` block) so a broken fragment
// shows why instead of going blank. Living here — normal JS — is why the macro emits one line, not a
// blob; `root` scoping means no `getElementById` and no cross-cell id clashes. Mirrored in the static
// export so a fragment behaves the same offline.
window.Slate.runFragment = function (scriptEl, fn) {
  const root = scriptEl && scriptEl.parentElement;
  const echo = function () {
    let g = root && root.querySelector('.weblog');
    if (root && !g) { g = document.createElement('pre'); g.className = 'weblog'; root.appendChild(g); }
    const line = Array.prototype.map.call(arguments, a =>
      typeof a === 'string' ? a : (() => { try { return JSON.stringify(a); } catch (_) { return String(a); } })()
    ).join(' ');
    if (g) g.textContent += line + '\n';
    try { console.log.apply(console, arguments); } catch (_) {}
  };
  Promise.resolve().then(() => fn(root, echo)).catch(function (e) {
    console.error(e);
    try {
      const b = document.createElement('pre'); b.className = 'web-err';
      b.textContent = '⚠ ' + ((e && e.stack) || e);
      (root || document.body).appendChild(b);
    } catch (_) {}
  });
};
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
function _slateAxisTheme(line, label, name) {
  // Font sizes lifted off ECharts' small defaults (12px) toward the Makie Slate theme, so an ECharts
  // figure and a Makie figure read at the same scale (see slate_look.jl). Tick labels in the dim tone,
  // axis names (titles) in the brighter text tone.
  return { axisLine: { lineStyle: { color: line } }, axisTick: { lineStyle: { color: line } },
    axisLabel: { color: label, fontSize: 14 }, nameTextStyle: { color: name, fontSize: 15 },
    splitLine: { lineStyle: { color: line, opacity: 0.4 } },
    splitArea: { areaStyle: { color: ['transparent', 'transparent'] } } };
}
// Sequential ramp for heatmap / calendar visualMaps — the SAME viridis Makie uses by default, so a
// heatmap reads identically whether it's an interactive ECharts figure or a rendered Makie one.
const _SLATE_VIRIDIS = ['#440154', '#472d7b', '#3b528b', '#2c728e', '#21918c',
  '#28ae80', '#5ec962', '#addc30', '#fde725'];
// Tooltip numbers, rounded. A Float64 straight out of Julia hovers as `14.11601595225456`, which is
// noise rather than precision — six significant figures is what a reader can actually use. It lives
// in the THEME rather than in the DSL because it is a DEFAULT: an author who sets their own
// `tooltip.valueFormatter` still overrides it, and it applies to every chart without being restated.
// (It cannot be set from Julia at all — `valueFormatter` is a function, and the option crosses as JSON.)
function _slateNum(v) {
  if (typeof v !== 'number' || !isFinite(v)) return v;
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v);
  const a = Math.abs(v);
  // Outside the range where fixed notation stays readable, exponential says more in less space.
  if (a < 1e-4 || a >= 1e15) return v.toExponential(3);
  // `parseFloat` drops the trailing zeros `toPrecision` pads with — 2.5 should not read as "2.50000".
  return String(parseFloat(v.toPrecision(6)));
}
// A datum is a scalar on a value axis, or a tuple: `[x, y]` for a line, `[x, y, v]` for a heatmap.
const _slateValueFormatter = v => Array.isArray(v) ? v.map(_slateNum).join(', ') : _slateNum(v);

// Build the Slate ECharts theme from a var-getter `V(name, default)` — decoupled from WHERE the
// palette comes from, so the live theme (computed styles) and an export render in an arbitrary
// named palette (its stylesheet rule) share one builder.
function _slateEchartsThemeFrom(V, fam) {
  const text = V('--text', '#d4d8e8'), dim = V('--dim', '#6a7090'),
        border = V('--border', '#2a2e40'), bg2 = V('--bg2', '#141828');
  const cycle = [['--accent', '#569cd6'], ['--green', '#56d364'], ['--orange', '#ce9178'],
    ['--purple', '#c586c0'], ['--teal', '#4ec9b0'], ['--gold', '#ffd700'], ['--red', '#e57575']]
    .map(([n, d]) => V(n, d));
  const ax = _slateAxisTheme(border, dim, text);
  // The canvas renderer sets `ctx.font = fontSize + 'px ' + fontFamily`; the CSS keyword 'inherit' is
  // NOT a valid canvas font-family, so the whole assignment is rejected and EVERY fontSize silently
  // reverts to the canvas default (color still applies — it's set via fillStyle, not the font string).
  // Resolve to a real stack so per-chart fontSize overrides actually take effect.
  const family = fam || 'system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';
  return {
    color: cycle, backgroundColor: 'transparent',
    textStyle: { color: text, fontFamily: family, fontSize: 14 },
    title: { left: 'center', textStyle: { color: text, fontSize: 19, fontWeight: 'bold' }, subtextStyle: { color: dim, fontSize: 12 } },
    legend: { textStyle: { color: dim, fontSize: 14 } },
    categoryAxis: ax, valueAxis: ax, logAxis: ax, timeAxis: ax,
    line: { symbolSize: 5 }, graph: { color: cycle },
    tooltip: { backgroundColor: bg2, borderColor: border, textStyle: { color: text },
               valueFormatter: _slateValueFormatter },
    visualMap: { textStyle: { color: dim }, inRange: { color: _SLATE_VIRIDIS } },
    timeline: { lineStyle: { color: dim }, label: { color: dim } },
    calendar: { splitLine: { lineStyle: { color: border } }, itemStyle: { borderColor: border } },
  };
}
// The live-theme ECharts theme (registered as 'slate') — reads the currently-applied CSS vars.
function _slateEchartsTheme() {
  const cs = getComputedStyle(document.documentElement);
  // The document's real computed font stack — a valid canvas font-family that still matches the page.
  const fam = (getComputedStyle(document.body || document.documentElement).fontFamily || '').trim();
  return _slateEchartsThemeFrom((n, d) => _slateThemeVar(cs, n, d), fam || undefined);
}
// Read ONE Slate palette's CSS custom properties straight from its stylesheet rule (":root" for
// midnight, `html[data-slate-theme="<name>"]` otherwise), merged over :root so a block that omits a
// var still resolves. This lets an export render a chart in ANY theme WITHOUT applying it to the live
// UI — the palette is the single source of truth (notebook.css, golden-tested against SLATE_PALETTES).
function _themeVarsFor(name) {
  const read = wanted => {
    for (const ss of document.styleSheets) {
      let rules; try { rules = ss.cssRules; } catch (_) { continue; }   // cross-origin sheet → skip
      for (const r of rules || []) {
        if (r.selectorText !== wanted || !r.style) continue;
        const o = {};
        for (const p of r.style) if (p[0] === '-' && p[1] === '-') o[p] = r.style.getPropertyValue(p).trim();
        return o;
      }
    }
    return {};
  };
  const base = read(':root');
  return (!name || name === 'midnight') ? base
    : Object.assign(base, read('html[data-slate-theme="' + name + '"]'));
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
    // Inline `{{ echart }}` instances are still owned here, so they are disposed and re-rendered
    // directly. A code cell's charts are owned by the Preact host (`chartRuntime.onGen` below), which
    // re-creates them by bumping a generation the component's effect depends on — disposing them from
    // underneath it would leave the component holding a dead instance.
    document.querySelectorAll('.ichart').forEach(e => { if (e._inst) { try { e._inst.dispose(); } catch (_) {} e._inst = null; } });
    window.chartRuntime.gen++;
    if (window.chartRuntime.onGen) window.chartRuntime.onGen();
    ((window.__slateState || {}).cells || []).forEach(c => { try { renderCharts(c); } catch (_) {} });
  } catch (_) {}
};

// ── The imperative half of a code cell's charts ──────────────────────────────────────────────────
// Preact owns the container and the LIFECYCLE (see `EChartHost` in notebook.js); everything that
// actually touches ECharts stays here, where the rest of the chart knowledge already lives. The
// boundary is deliberate and one-way: Preact never renders INSIDE a `.echart` div — zrender owns that
// subtree — and this never creates or removes one.
//
// It replaces a hand-rolled reconciler: the old code filtered instances whose DOM had detached,
// swept orphaned children, then matched child count to spec count with two while-loops — all of it
// defending against the Preact re-render happening above it. Keyed children make that whole class of
// bug unrepresentable.
window.chartRuntime = {
  gen: 0,             // bumped on a theme switch; the component re-inits against it
  onGen: null,        // set by the Preact layer to a signal bump
  // A package-vendored lib (echarts-gl via `requireScripts`) must load BEFORE `echarts.init`: an
  // instance created before echarts-gl registers its 3D views paints blank and throws on resize.
  scripts(spec) { return spec && spec.requireScripts ? _ensureScripts(spec) : Promise.resolve(); },
  init(el) { _ensureSlateTheme(); const inst = echarts.init(el, 'slate'); el.__inst = inst; return inst; },
  apply(el, inst, spec) {
    _applySize(el, inst, spec);
    return _ensurePrereqs(spec)
      .then(() => _geoSafeSetOption(inst, spec))
      .then(() => _wireEchartReplay(inst, spec))
      .then(() => _wireEchartSelect(inst, spec));
  },
  dispose(el, inst) { try { inst.dispose(); } catch (_) {} if (el) el.__inst = null; },
  // `window.charts` is read all over (slides fitting, the SVG snapshot, inspect, the resize listener),
  // so it stays the public registry — rebuilt DENSE from DOM order rather than index-assigned, which
  // keeps it hole-free for the `.forEach`/`.flat()` consumers however mounts interleave.
  sync(cellId, host) {
    const list = Array.from(host.querySelectorAll(':scope > .echart')).map(d => d.__inst).filter(Boolean);
    if (list.length) window.charts[cellId] = list; else delete window.charts[cellId];
    return list;
  },
  settled(cellId, insts, spec0) {
    if (insts.length) _snapCell(cellId, insts, _sansMaps(spec0));
    _healSizesSoon(insts);
  }
};

// Register a cell's assets and refresh any INLINE `{{ echart(…) }}` charts in a markdown cell.
//
// A code cell's charts are NOT handled here any more — `EChartHost` (notebook.js) owns those, so that
// creating and destroying a chart div is Preact's keyed diff rather than a reconciler hand-written to
// survive one. What is left is the inline case, where the placeholder is authored inside rendered
// markdown and has no component around it.
function renderCharts(c) {
  _registerAssets(c);                               // publish this cell's save_asset blobs → Slate.asset
  const specs = c.echarts || [];
  // A code cell's chart DIVS belong to Preact (`EChartHost` in notebook.js) — but this function is
  // also called from the IMPERATIVE patch path (view.js `patchCells`), which updates a cell without
  // rendering the Preact tree at all. That is the path a slider drag takes: without this, a chart only
  // caught up on release, when the next full render happened to land.
  //
  // Re-applying the option to instances that ALREADY exist is safe from either side, because it
  // creates and destroys nothing — the ownership split is unchanged. A change in the NUMBER of charts
  // is still Preact's to make, and arrives with the render that follows.
  const host = document.querySelector('#cell-' + c.id + ' .echarts');
  if (host) {
    Array.from(host.querySelectorAll(':scope > .echart')).forEach((el, i) => {
      if (el.__inst && specs[i]) window.chartRuntime.apply(el, el.__inst, specs[i]);
    });
  }
  document.querySelectorAll('#cell-' + c.id + ' .ichart').forEach(el => {
    const spec = specs[+el.dataset.i]; if (!spec) return;
    // The GL-lib deferral that applied to the whole cell now applies per placeholder — same rule,
    // narrower scope: init only after `requireScripts` has loaded.
    window.chartRuntime.scripts(spec).then(() => {
      if (!el._inst) { _ensureSlateTheme(); el._inst = echarts.init(el, 'slate'); }
      _applySize(el, el._inst, spec);
      return _ensurePrereqs(spec)
        .then(() => _geoSafeSetOption(el._inst, spec))
        .then(() => _wireEchartReplay(el._inst, spec));
    });
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
// ── `@replay` in an ECharts figure ──────────────────────────────────────────────────────────────
// `Slate.replay.wire` owns everything except the call that puts a slice on screen. What is left here
// is the only ECharts-specific part: the DSL ZIPS, so a line series is `[[x,y],…]` and a heatmap is
// `[[x,y,v],…]`, and the mark (echarts_dsl.jl `_mark_replay!`) names which COMPONENT of each drawn
// entry the shipped array feeds. Rewriting that one slot in the entries ALREADY DRAWN reuses their
// coordinates, so the zip layout is expressed once, in Julia, and never restated here.
//
// A rank-2 slice arrives as ROWS, and a heatmap triple carries its own `[xIndex, yIndex]`, so it is
// indexed by those rather than by position — correct however the entries end up ordered.
function _replayEntries(cur, m, slice) {
  if (m.comp === null || m.comp === undefined) return slice;
  if (m.rank === 2) return cur.map(p => { const q = p.slice(); q[m.comp] = slice[p[1]][p[0]]; return q; });
  return cur.map((p, i) => { const q = p.slice(); q[m.comp] = slice[i]; return q; });
}

// ── `select`: drag on a chart to set a `@bind` range ──────────────────────────────────────────
// The DSL's `select = :name` (echarts_dsl.jl `_apply_select!`) marks a spec with `__select`. Here
// that becomes a live link in BOTH directions, with the bind as the single source of truth:
//
//   chart → bind : a finished brush POSTs the swept range to the SAME endpoint the widget's own
//                  thumb posts to, so the widget, the reactive graph and the `.jl` all update
//                  through the one path that already exists;
//   bind → chart : every re-render reflects the bind's CURRENT value back onto the brush, so
//                  moving the slider moves the brush.
//
// The chart holds no selection state of its own — which is what makes the two agree by
// construction instead of by two copies being nudged into step.

// The cell that DECLARES a bind, from the notebook state. That mapping already exists there, so
// the Julia side only has to name the variable.
function _bindOwner(name) {
  const cells = ((window.__slateState || window.nbState || {}).cells) || [];
  for (const c of cells) {
    for (const b of (c.binds || [])) if (b && b.name === name) return { cell: c.id, value: b.value };
  }
  return null;
}

function _wireEchartSelect(inst, spec) {
  const sel = spec && spec.__select;
  if (!inst || !sel || !sel.name) return;
  const owner = _bindOwner(sel.name);
  if (!owner) return;                               // the bind isn't declared (yet) — nothing to link
  const cur = Array.isArray(owner.value) && owner.value.length === 2
    ? [Math.min(owner.value[0], owner.value[1]), Math.max(owner.value[0], owner.value[1])] : null;

  if (!inst.__selectWired) {
    inst.__selectWired = true;
    // Permanently armed, so the reader just drags — no brush tool to pick up first.
    try { inst.dispatchAction({ type: 'takeGlobalCursor', key: 'brush', brushOption: { brushType: 'lineX', brushMode: 'single' } }); } catch (_) {}
    // A `brushEnd` counts as a GESTURE only if a pointer went down on this chart first.
    //
    // The alternative — flag the programmatic reflect below and clear it on a timer — looked
    // equivalent and is not: `dispatchAction` can fire `brushEnd` after the current tick, by which
    // point the flag is clear, so the reflect is read as a drag and POSTs a value back. That is
    // not merely a redundant write. On a fresh page or a just-restarted worker it can land BEFORE
    // the `@bind` cell has run in the new namespace, and a value arriving for an unknown name
    // makes `_do_set_bind` fabricate a `"?"` placeholder widget (widgets.jl). Until that cell runs
    // again the control has no registered kind, so nothing coerces or wraps its value — a
    // RangeSlider silently starts handing cells a raw array instead of `(lo, hi)`.
    // Keying on a real pointer removes the timing question entirely.
    try {
      inst.getDom().addEventListener('pointerdown', function () { inst.__selectUser = true; }, true);
    } catch (_) {}
    inst.on('brushEnd', function (p) {
      if (!inst.__selectUser) return;               // programmatic reflect, not a drag
      inst.__selectUser = false;
      const a = (p.areas || [])[0], r = a && a.coordRange;
      if (!r || r.length !== 2) return;
      const lo = Math.min(r[0], r[1]), hi = Math.max(r[0], r[1]);
      if (!(hi > lo)) return;                       // a click, not a sweep
      const own = _bindOwner(sel.name);
      if (!own) return;
      api('POST', '/api/bind/' + own.cell, { name: sel.name, value: [lo, hi] })
        .then(updateStates).catch(() => {});
    });
  }
  // Reflect the bind onto the brush, so moving the slider moves the brush. Never counts as a
  // gesture (no pointer went down), so it cannot echo back.
  if (cur) {
    try {
      inst.dispatchAction({ type: 'brush', areas: [{ brushType: 'lineX', xAxisIndex: 0, coordRange: cur }] });
    } catch (_) {}
  }
}

function _wireEchartReplay(inst, spec) {
  if (!inst || inst.__replayWired) return;         // renders repeat; listeners must not accumulate
  const marks = ((spec && spec.series) || [])
    .map((s, i) => (s && s.__replay) ? Object.assign({ series: i, base: s.data || [] }, s.__replay) : null)
    .filter(Boolean);
  if (!marks.length) return;
  inst.__replayWired = true;
  window.Slate.replay.wire(marks, function (slice, m) {
    // series merge by INDEX, so naming only the changed one leaves the reader's zoom, roam and legend
    // state untouched through every step of a drag. A full replace would not.
    const arr = [];
    for (let k = 0; k < m.series; k++) arr.push({});
    arr.push({ data: _replayEntries(m.base, m, slice) });
    const patch = { series: arr };
    // A heatmap's colour scale was fitted to whichever slice drew first; leaving it pinned would clip
    // every other one. Refit it to what is actually on screen.
    if (m.rank === 2 && spec.visualMap) {
      let lo = Infinity, hi = -Infinity;
      slice.forEach(row => row.forEach(v => { if (v < lo) lo = v; if (v > hi) hi = v; }));
      if (isFinite(lo) && isFinite(hi)) patch.visualMap = { min: lo, max: hi };
    }
    inst.setOption(patch);
  });
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
// `_clean_default`): integers as-is; other numbers rounded to `_DEFAULT_SIGDIGITS` significant
// figures (trailing zeros stripped), scientific notation outside a normal display range. A column
// that needs full precision opts in via an explicit format spec.
const _DEFAULT_SIGDIGITS = 6;
function _stripTrailingZeros(s) {
  if (s.indexOf('.') < 0) return s;
  s = s.replace(/0+$/, '');
  return s.endsWith('.') ? s.slice(0, -1) : s;
}
function _cleanDefault(v) {
  if (v == null) return '';
  if (typeof v !== 'number' || !isFinite(v)) return String(v);
  if (v === Math.round(v) && Math.abs(v) < 1e15) return String(Math.round(v));
  const av = Math.abs(v);
  if (av >= 1e15 || av < 1e-4) {
    const s = _sci(v, _DEFAULT_SIGDIGITS);
    const idx = s.indexOf('e');
    return _stripTrailingZeros(s.slice(0, idx)) + s.slice(idx);
  }
  const e = Math.floor(Math.log10(av));
  const d = Math.max(_DEFAULT_SIGDIGITS - 1 - e, 0);
  return _stripTrailingZeros(_roundDec(v, d));
}
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
  const tbody = document.createElement('tbody'); tbl.appendChild(tbody);
  // Scroll wrapper: a wide table pans horizontally instead of squeezing/clipping its
  // columns. Only the table scrolls — the filter bar and pagination stay put.
  const scroll = document.createElement('div'); scroll.className = 'st-scroll';
  scroll.appendChild(tbl); wrap.appendChild(scroll);
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

