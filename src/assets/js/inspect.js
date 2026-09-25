// Live cell-inspect capture. On an `inspect:` SSE event (the server's slate.inspect tool asking to
// SEE a rendered cell), grab the cell's cleaned DOM + this tab's console buffer + an html2canvas
// raster and POST them back, keyed by the request id. html2canvas is vendored and lazy-loaded ONLY
// here, so it stays off the boot path. Best-effort: any single failure still posts what we have.
let _h2cPromise = null;
function _loadHtml2Canvas() {
  if (window.html2canvas) return Promise.resolve(window.html2canvas);
  if (_h2cPromise) return _h2cPromise;
  _h2cPromise = new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = '/assets/vendor/html2canvas/html2canvas.min.js';
    s.onload = () => res(window.html2canvas);
    s.onerror = () => { _h2cPromise = null; rej(new Error('html2canvas failed to load')); };
    document.head.appendChild(s);
  });
  return _h2cPromise;
}
// The cell's rendered DOM minus noise the agent can't use: CodeMirror internals (huge, irrelevant to
// OUTPUT) and inline data URIs. Capped so a giant cell can't blow the payload.
function _cleanCellHtml(el) {
  const clone = el.cloneNode(true);
  // Drop per-cell chrome that's identical on every cell — pure noise for an inspect: the header
  // button row + state badge, and empty control-strip scaffolding.
  clone.querySelectorAll('.cellhead, .controls.empty, .coldrop').forEach(n => n.remove());
  clone.querySelectorAll('.cm-editor').forEach(n => n.replaceWith(document.createComment(' CodeMirror editor ')));
  clone.querySelectorAll('[src^="data:"]').forEach(n => n.setAttribute('src', '(inline data omitted)'));
  let html = clone.outerHTML || '';
  if (html.length > 20000) html = html.slice(0, 20000) + '\n<!-- …truncated… -->';
  return html;
}
// html2canvas parses colours itself and rejects the `color(srgb …)` form a browser computes for
// `color-mix()`, throwing on the first one it meets — which abandons the raster for the WHOLE cell,
// not just the element wearing it. The stylesheet uses `color-mix` freely, including on `.output
// .err` and `.output .warn`, so every cell that raised an error had no image for `slate.view` at
// all. Rewrite the computed value to `rgb()/rgba()` on html2canvas's own clone, where overriding
// inline styles costs the live page nothing.
const _SRGB_FN = /^color\(srgb\s+([\d.eE+-]+)\s+([\d.eE+-]+)\s+([\d.eE+-]+)(?:\s*\/\s*([\d.eE+-]+))?\s*\)$/;
const _COLOR_PROPS = ['backgroundColor', 'color', 'borderTopColor', 'borderRightColor',
                      'borderBottomColor', 'borderLeftColor', 'outlineColor', 'textDecorationColor'];
const _SANITIZE_CAP = 4000;   // a pathological cell walks its own DOM, not the agent's patience
function _plainColor(v) {
  const m = _SRGB_FN.exec(v || '');
  if (!m) return null;
  const ch = i => Math.round(Math.min(1, Math.max(0, parseFloat(m[i]) || 0)) * 255);
  const a = m[4] === undefined ? 1 : parseFloat(m[4]);
  return a >= 1 ? `rgb(${ch(1)}, ${ch(2)}, ${ch(3)})` : `rgba(${ch(1)}, ${ch(2)}, ${ch(3)}, ${a})`;
}
function _sanitizeColors(root) {
  if (!root) return;
  const els = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*'), 0, _SANITIZE_CAP));
  for (const el of els) {
    let cs; try { cs = getComputedStyle(el); } catch (_) { continue; }
    for (const p of _COLOR_PROPS) {
      const fixed = _plainColor(cs[p]);
      if (fixed) el.style[p] = fixed;
    }
  }
}
window._slateSanitizeColors = _sanitizeColors;

// Answer one inspect request: capture cell `cellId` and POST it back under `reqid`.
async function _slateInspect(reqid, cellId) {
  const out = { reqid, cell: cellId, html: '', console: (window.__diag || []).slice(-40), png: '' };
  try {
    const el = document.getElementById('cell-' + cellId);
    if (el) {
      try { out.html = _cleanCellHtml(el); } catch (_) {}
      // Only html2canvas a cell that has NO native figure. ECharts (canvas) and CairoMakie
      // (server-rendered <img>) are already captured at higher fidelity for slate.view via the
      // snapshot path — overwriting that store with a whole-cell screenshot is strictly worse.
      // So the raster only fills in for non-figure cells (markdown / tables / plain values).
      const hasNativeFig = !!el.querySelector('.echarts canvas, .echart canvas, .output img');
      // A cell-mounted CLIENT-CANVAS widget (the neuro/DAG canvas, …) can't be captured by html2canvas
      // — it can't read arbitrary canvas pixels, so the widget comes out black. Grab it DIRECTLY: a widget
      // may register a settled-render provider at window.__slateSnapshot[cellId] (force-renders its final
      // state, then returns base64 PNG); otherwise read the cell's own <canvas>. POSTed back under reqid
      // here (NOT the 20k-capped eval-result path), so a full-size PNG survives.
      try {
        const prov = window.__slateSnapshot && window.__slateSnapshot[cellId];
        if (typeof prov === 'function') out.png = prov() || '';
        else if (!hasNativeFig) { const cv = el.querySelector('.output canvas'); if (cv) out.png = (cv.toDataURL('image/png').split(',')[1]) || ''; }
      } catch (_) {}
      if (!out.png && !hasNativeFig) {
        try {
          const h2c = await _loadHtml2Canvas();
          const bg = (getComputedStyle(document.body).backgroundColor) || '#12141c';
          // Raster the rendered CONTENT (markdown / output / table), not the cell's button chrome —
          // so a markdown-layout inspect shows the math/text as laid out, nothing wasteful.
          const target = el.querySelector('.md, .output, .tables') || el;
          const canvas = await h2c(target, { backgroundColor: bg, scale: 1, logging: false, useCORS: true,
                                             onclone: (_doc, el) => { try { _sanitizeColors(el); } catch (_) {} } });
          out.png = (canvas.toDataURL('image/png').split(',')[1]) || '';
        } catch (_) {}
      }
    }
  } catch (_) {}
  try { await api('POST', '/api/inspect-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateInspect = _slateInspect;

// Rasterise SEVERAL cells for one request (`inspectmany:`), for a PDF export that needs a picture
// of every HTML-output cell. Each raster is posted store-only as it is made — one body per cell
// keeps each small, and the server is waiting on the single reply at the end, so the whole batch
// costs one round-trip instead of one per cell. A cell that fails is skipped rather than aborting
// the batch: a missing picture degrades that one cell, a thrown batch loses every picture.
async function _slateInspectMany(reqid, cellIds, theme) {
  // Rasterise UNDER the export's palette rather than the reader's. The picture is of the live page,
  // so a light PDF would otherwise embed dark cards on white paper. Applied to html2canvas's clone
  // (`onclone` hands us the cloned document), so the page itself never changes and nobody watching
  // the export sees it flicker. `midnight` is the bare default and carries no attribute.
  const dressClone = doc => {
    if (!theme || !doc || !doc.documentElement) return;
    if (theme === 'midnight') delete doc.documentElement.dataset.slateTheme;
    else doc.documentElement.dataset.slateTheme = theme;
  };
  let captured = 0;
  for (const cellId of (cellIds || [])) {
    try {
      const el = document.getElementById('cell-' + cellId);
      if (!el) continue;
      if (el.querySelector('.echarts canvas, .echart canvas, .output img')) continue;  // native figure already captured
      let png = '';
      const prov = window.__slateSnapshot && window.__slateSnapshot[cellId];
      if (typeof prov === 'function') png = prov() || '';
      if (!png) {
        const h2c = await _loadHtml2Canvas();
        const target = el.querySelector('.md, .output, .tables') || el;
        // Transparent, so the PDF page shows through instead of each picture carrying a rectangle
        // of the live page's background — which matches neither a light nor a dark page exactly.
        const canvas = await h2c(target, { backgroundColor: null, scale: 1, logging: false, useCORS: true,
          onclone: (doc, e) => { try { dressClone(doc); _sanitizeColors(e); } catch (_) {} } });
        png = (canvas.toDataURL('image/png').split(',')[1]) || '';
      }
      if (!png) continue;
      await api('POST', '/api/inspect-result', { reqid: '', cell: cellId, png });   // store-only
      captured++;
    } catch (_) { /* this cell has no picture; the rest still do */ }
  }
  try { await api('POST', '/api/inspect-result', { reqid, captured }); } catch (_) {}
}
window._slateInspectMany = _slateInspectMany;

// slate.eval_js: run agent-supplied JS in THIS tab and POST the result back, keyed by reqid. Indirect
// eval `(0, eval)` runs in global scope so page globals (nbState, charts, exportPdf, renderCharts, …)
// are reachable; a returned Promise is awaited so `await`-style snippets work. Result is JSON-stringified
// defensively (functions/DOM nodes/circular refs collapsed, size-capped) so it always serializes back.
function _evalSafeJson(v) {
  try {
    const seen = new WeakSet();
    const s = JSON.stringify(v, (_k, val) => {
      if (typeof val === 'number' && !isFinite(val)) return val.toString();   // NaN / ±Infinity (not valid JSON)
      if (typeof val === 'bigint') return val.toString() + 'n';
      if (typeof val === 'function') return '[function]';
      if (typeof val === 'undefined') return '[undefined]';
      if (val instanceof Element) return '[<' + val.tagName.toLowerCase() + (val.id ? ' #' + val.id : '') + '>]';
      if (val && typeof val === 'object') {
        if (seen.has(val)) return '[circular]';
        seen.add(val);
        if (val instanceof Set) return [...val];                  // Set → array of values
        if (val instanceof Map) return Object.fromEntries(val);   // Map → object of entries
      }
      return val;
    });
    if (s === undefined) return String(v);                       // undefined / function at top level
    return s.length > 20000 ? s.slice(0, 20000) + '\n…(truncated)' : s;
  } catch (_) { return String(v); }
}
async function _slateEvalJs(reqid, code) {
  const out = { reqid, ok: false, result: 'null', error: '' };
  // Track the action in the chat panel so the user sees what's being run in their tab.
  const logm = (typeof logAgentAction === 'function') ? logAgentAction('🧩 eval JS', code) : null;
  try {
    let v = (0, eval)(code);                                     // indirect eval → global scope
    if (v && typeof v.then === 'function') v = await v;          // await a returned Promise
    out.ok = true; out.result = _evalSafeJson(v);
  } catch (e) { out.error = String((e && e.stack) || e); }
  if (logm) {
    logm.done = true;
    if (!out.ok) logm.text = '⚠ eval JS (error)';
    logm.result = out.ok ? out.result : out.error;   // surface the returned value / error in the panel
    logm.resultErr = !out.ok;
    if (typeof renderAgentMsgs === 'function') renderAgentMsgs();
  }
  try { await api('POST', '/api/eval-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateEvalJs = _slateEvalJs;

// ── Component figure capture for print (PDF/Typst export) ─────────────────────
// A `slate_render` component only exists as a mounted DOM subtree, so a server-side export has
// nothing to embed unless the browser hands it a picture. Answers a `compfig:` SSE request with
// one figure, keyed by (cell, slot) — `slot` indexes the cell's `.disp.slatecomp` mounts in
// document order, which is how a markdown cell with several fences addresses each one.
//
// Vector wherever possible: an SVG embeds into Typst as real paths and text, a raster does not.
// Order is therefore: the component's own `exportFigure` (it knows how to render itself for
// print — see registerComponent, slate-widget.js), then the mount's own lone <svg>, then
// html2canvas as the format-agnostic floor.

// Serialise a live <svg> as a standalone document. Width/height are dropped in favour of the
// viewBox: a mount is laid out with `width: 100%`, which means nothing to a file, while the
// viewBox carries the true aspect and lets the page size it.
function _standaloneSvg(svg) {
  const c = svg.cloneNode(true);
  c.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
  c.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');
  const vb = c.getAttribute('viewBox');
  if (vb) { c.removeAttribute('width'); c.removeAttribute('height'); }
  return c.outerHTML;
}
// Is this palette's page colour dark? Passed to `exportFigure` so a component can pick a light or
// dark rendering for the EXPORT theme, which need not be the one the live page is showing.
function _paletteIsDark(vars) {
  const s = ((vars && vars['--bg']) || '').trim();
  let m, r, g, b;
  if ((m = s.match(/^#([0-9a-f]{3})$/i))) [r, g, b] = [0, 1, 2].map(i => parseInt(m[1][i] + m[1][i], 16));
  else if ((m = s.match(/^#([0-9a-f]{6})$/i))) [r, g, b] = [0, 2, 4].map(i => parseInt(m[1].slice(i, i + 2), 16));
  else if ((m = s.match(/^rgba?\(([^)]+)\)$/i))) [r, g, b] = m[1].split(',').map(Number);
  else return true;                                   // unreadable → dark, which is Slate's default
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
}
async function _slateComponentFig(reqid, cellId, slot, theme) {
  const out = { reqid, ok: false, svg: '', png: '', err: '' };
  try {
    const cell = document.getElementById('cell-' + cellId);
    const host = cell ? cell.querySelectorAll('.disp.slatecomp')[slot | 0] : null;
    if (!host) throw new Error('no component mount at slot ' + slot);
    const el = host.querySelector('.slatecomponent');
    const kind = (el && el.dataset.component) || '';
    let props = {};
    try { props = (JSON.parse(host.querySelector('script.slatecomponent-desc').textContent) || {}).props || {}; } catch (_) {}
    const impl = (window.slateWidgets || {})[kind];
    if (el && impl && typeof impl.exportFigure === 'function') {
      const vars = (typeof _themeVarsFor === 'function') ? _themeVarsFor(theme) : {};
      const r = await impl.exportFigure(el, { params: props, kind, theme, vars, dark: _paletteIsDark(vars) });
      if (r && r.svg) out.svg = String(r.svg);
      else if (r && r.png) out.png = String(r.png);
    }
    if (!out.svg && !out.png && el) {
      // No hook, or it declined. A mount holding exactly ONE <svg> IS the figure — the common shape
      // for a diagram/chart component, and vector for free. Several (or none) is an arbitrary layout
      // that only a rasteriser can flatten.
      const svgs = el.querySelectorAll('svg');
      if (svgs.length === 1) out.svg = _standaloneSvg(svgs[0]);
      else {
        const h2c = await _loadHtml2Canvas();
        const bg = (getComputedStyle(document.body).backgroundColor) || '#12141c';
        const canvas = await h2c(el, { backgroundColor: bg, scale: 2, logging: false, useCORS: true });
        out.png = (canvas.toDataURL('image/png').split(',')[1]) || '';
      }
    }
    out.ok = !!(out.svg || out.png);
  } catch (e) { out.err = String((e && e.message) || e); }
  try { await api('POST', '/api/compfig-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateComponentFig = _slateComponentFig;

// Warm html2canvas at idle so the FIRST inspect doesn't blow its server-side timeout on a cold
// load (CDN fetch + parse). Kept off the boot path — fires ~2s after load, best-effort.
//
// Skipped on an app: rendered-DOM inspection is something an AGENT asks for, and an app has no
// agent — so this would be a third-party CDN request on every load, made on behalf of a feature
// that can't be invoked. It also breaks the deployment story an app is supposed to have: a lab
// machine may have no route off its own network, and this is the one thing on the page that
// reaches outside it.
if (!(window.__SLATE_APP__ && window.__SLATE_APP__.on)) {
  setTimeout(() => { _loadHtml2Canvas().catch(() => {}); }, 2000);
}
