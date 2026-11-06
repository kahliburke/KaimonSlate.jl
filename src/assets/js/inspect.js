// Live cell-inspect capture. On an `inspect:` SSE event (the server's slate.inspect tool asking to
// SEE a rendered cell), grab the cell's cleaned DOM + this tab's console buffer + a raster and POST
// them back, keyed by the request id. Rasters come from modern-screenshot, which copies the element
// with its computed styles and the web fonts it uses into an SVG <foreignObject> and has the browser
// draw that, so the picture is the browser's own rendering (KaTeX's stretched SVG delimiters
// included). It is vendored and lazy-loaded ONLY here, so it stays off the boot path. Best-effort:
// any single failure still posts what we have.
let _shotPromise = null;
function _loadScreenshot() {
  if (window.modernScreenshot) return Promise.resolve(window.modernScreenshot);
  if (_shotPromise) return _shotPromise;
  _shotPromise = new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = '/assets/vendor/modern-screenshot/index.js';
    s.onload = () => window.modernScreenshot ? res(window.modernScreenshot)
                                              : (_shotPromise = null, rej(new Error('modern-screenshot did not load')));
    s.onerror = () => { _shotPromise = null; rej(new Error('modern-screenshot failed to load')); };
    document.head.appendChild(s);
  });
  return _shotPromise;
}
// `el` as base64 PNG (no data-URL prefix). `backgroundColor: null` leaves the background transparent.
// A media load is bounded well inside the server's wait, so one slow image costs that image only.
async function _rasterize(el, { backgroundColor = null, scale = 1 } = {}) {
  const shot = await _loadScreenshot();
  const url = await shot.domToPng(el, { backgroundColor, scale, timeout: 3000 });
  return (url && url.split(',')[1]) || '';
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
// The part of a cell worth a picture: its rendered CONTENT (markdown / output / table), not the
// cell's button chrome.
const _captureTarget = el => el.querySelector('.md, .output, .tables') || el;

// The page as it would look under Slate palette `theme`, for capturing cells in a theme the reader
// is not looking at. The document is copied into a same-origin iframe kept off-screen and the theme
// set on the copy, so the live page never changes and nobody watching sees it flicker. Returns
// `{ find(cellId), dispose() }`, or `null` when `theme` is already the live one. `find` gives the
// copy's capture target for a cell, or `null` when the copy can't stand in for it (a canvas or an
// embedded frame, whose content a DOM copy doesn't carry), so the caller captures the live cell.
const _COPY_FRAME = 'data-slate-capture-copy';
async function _themedPage(theme) {
  const live = document.documentElement.dataset.slateTheme || 'midnight';
  if (!theme || theme === live) return null;
  const frame = document.createElement('iframe');
  const w = document.documentElement.clientWidth;
  frame.setAttribute(_COPY_FRAME, '');
  frame.setAttribute('aria-hidden', 'true');
  frame.tabIndex = -1;
  frame.style.cssText = `position:fixed;top:0;left:${-w - 64}px;width:${w}px;height:${window.innerHeight}px;` +
                        'border:0;pointer-events:none;';
  document.body.appendChild(frame);
  const dispose = () => frame.remove();
  try {
    const doc = frame.contentDocument;
    const root = doc.importNode(document.documentElement, true);
    root.querySelectorAll(`script, [${_COPY_FRAME}]`).forEach(n => n.remove());
    // a copied frame would load its page again (and run it): the copy only needs its box
    root.querySelectorAll('iframe').forEach(f => { f.removeAttribute('src'); f.removeAttribute('srcdoc'); });
    // the page's own <style> elements may hold rules added through the CSSOM, which a copy of the
    // element doesn't carry: copy their rules as text
    const liveStyles = document.querySelectorAll('style'), copyStyles = root.querySelectorAll('style');
    liveStyles.forEach((st, i) => {
      try { if (copyStyles[i] && st.sheet) copyStyles[i].textContent = Array.from(st.sheet.cssRules, r => r.cssText).join('\n'); } catch (_) {}
    });
    if (theme === 'midnight') delete root.dataset.slateTheme;
    else root.dataset.slateTheme = theme;
    doc.replaceChild(root, doc.documentElement);
    try {   // constructed stylesheets (CodeMirror's, for one) are not elements at all
      const W = frame.contentWindow;
      doc.adoptedStyleSheets = (document.adoptedStyleSheets || []).map(sh => {
        const c = new W.CSSStyleSheet();
        c.replaceSync(Array.from(sh.cssRules, r => r.cssText).join('\n'));
        return c;
      });
    } catch (_) {}
    // linked stylesheets load again in the copy (from cache); wait for them, then for the fonts the
    // laid-out copy asks for, so line breaks and math sizes match the page
    await Promise.all(Array.from(doc.querySelectorAll('link[rel~="stylesheet"]'), l =>
      l.sheet ? null : new Promise(r => { l.onload = l.onerror = r; setTimeout(r, 3000); })));
    void doc.body.offsetHeight;
    await Promise.race([doc.fonts.ready, new Promise(r => setTimeout(r, 3000))]);
    const find = cellId => {
      const live = document.getElementById('cell-' + cellId);
      const copy = doc.getElementById('cell-' + cellId);
      if (!live || !copy || live.querySelector('canvas, iframe')) return null;
      return _captureTarget(copy);
    };
    return { find, dispose };
  } catch (e) { dispose(); throw e; }
}

// Answer one inspect request: capture cell `cellId` and POST it back under `reqid`.
async function _slateInspect(reqid, cellId) {
  const out = { reqid, cell: cellId, html: '', console: (window.__diag || []).slice(-40), png: '' };
  try { window.hydrateAll && window.hydrateAll('ts:'); } catch (_) {}   // math still queued is typeset first
  try {
    const el = document.getElementById('cell-' + cellId);
    if (el) {
      try { out.html = _cleanCellHtml(el); } catch (_) {}
      // Only rasterise a cell that has NO native figure. ECharts (canvas) and CairoMakie
      // (server-rendered <img>) are already captured at higher fidelity for slate.view via the
      // snapshot path — overwriting that store with a whole-cell screenshot is strictly worse.
      // So the raster only fills in for non-figure cells (markdown / tables / plain values).
      const hasNativeFig = !!el.querySelector('.echarts canvas, .echart canvas, .output img');
      // A cell-mounted CLIENT-CANVAS widget is better captured DIRECTLY than through a DOM raster: a widget
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
          const bg = (getComputedStyle(document.body).backgroundColor) || '#12141c';
          out.png = await _rasterize(_captureTarget(el), { backgroundColor: bg });
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
  // so a light PDF would otherwise embed dark cards on white paper. A cell is captured from a themed
  // copy of the page (`_themedPage`), made once, when the first cell needs a raster.
  let copy;   // undefined: not made yet; null: the live page is already in `theme`
  let captured = 0;
  try { window.hydrateAll && window.hydrateAll('ts:'); } catch (_) {}   // math still queued is typeset first
  try {
    for (const cellId of (cellIds || [])) {
      try {
        const el = document.getElementById('cell-' + cellId);
        if (!el) continue;
        if (el.querySelector('.echarts canvas, .echart canvas, .output img')) continue;  // native figure already captured
        let png = '';
        const prov = window.__slateSnapshot && window.__slateSnapshot[cellId];
        if (typeof prov === 'function') png = prov() || '';
        if (!png) {
          if (copy === undefined) { try { copy = await _themedPage(theme); } catch (_) { copy = null; } }
          const target = (copy && copy.find(cellId)) || _captureTarget(el);
          // Transparent, so the PDF page shows through instead of each picture carrying a rectangle
          // of the live page's background — which matches neither a light nor a dark page exactly.
          png = await _rasterize(target, { backgroundColor: null });
        }
        if (!png) continue;
        await api('POST', '/api/inspect-result', { reqid: '', cell: cellId, png });   // store-only
        captured++;
      } catch (_) { /* this cell has no picture; the rest still do */ }
    }
  } finally {
    if (copy) copy.dispose();
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
// a DOM raster as the format-agnostic floor.

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
        const bg = (getComputedStyle(document.body).backgroundColor) || '#12141c';
        out.png = await _rasterize(el, { backgroundColor: bg, scale: 2 });
      }
    }
    out.ok = !!(out.svg || out.png);
  } catch (e) { out.err = String((e && e.message) || e); }
  try { await api('POST', '/api/compfig-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateComponentFig = _slateComponentFig;

// Warm the capture library at idle so the FIRST inspect doesn't blow its server-side timeout on a
// cold load. Kept off the boot path — fires ~2s after load, best-effort.
//
// Skipped on an app: rendered-DOM inspection is something an AGENT asks for, and an app has no
// agent — so this would be a request on every load, made on behalf of a feature that can't be
// invoked. It also breaks the deployment story an app is supposed to have: a lab machine may have
// no route off its own network, and the vendored file may have to come from the CDN.
if (!(window.__SLATE_APP__ && window.__SLATE_APP__.on)) {
  setTimeout(() => { _loadScreenshot().catch(() => {}); }, 2000);
}
