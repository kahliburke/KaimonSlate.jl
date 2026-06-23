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
  clone.querySelectorAll('.CodeMirror').forEach(n => n.replaceWith(document.createComment(' CodeMirror editor ')));
  clone.querySelectorAll('[src^="data:"]').forEach(n => n.setAttribute('src', '(inline data omitted)'));
  let html = clone.outerHTML || '';
  if (html.length > 20000) html = html.slice(0, 20000) + '\n<!-- …truncated… -->';
  return html;
}
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
      if (!hasNativeFig) {
        try {
          const h2c = await _loadHtml2Canvas();
          const bg = (getComputedStyle(document.body).backgroundColor) || '#12141c';
          // Raster the rendered CONTENT (markdown / output / table), not the cell's button chrome —
          // so a markdown-layout inspect shows the math/text as laid out, nothing wasteful.
          const target = el.querySelector('.md, .output, .tables') || el;
          const canvas = await h2c(target, { backgroundColor: bg, scale: 1, logging: false, useCORS: true });
          out.png = (canvas.toDataURL('image/png').split(',')[1]) || '';
        } catch (_) {}
      }
    }
  } catch (_) {}
  try { await api('POST', '/api/inspect-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateInspect = _slateInspect;

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
  if (logm) { logm.done = true; if (!out.ok) logm.text = '⚠ eval JS (error)'; if (typeof renderAgentMsgs === 'function') renderAgentMsgs(); }
  try { await api('POST', '/api/eval-result', out); } catch (_) {}   // api() → _apipath injects NB_ID
}
window._slateEvalJs = _slateEvalJs;
// Warm html2canvas at idle so the FIRST inspect doesn't blow its server-side timeout on a cold
// load (CDN fetch + parse). Kept off the boot path — fires ~2s after load, best-effort.
setTimeout(() => { _loadHtml2Canvas().catch(() => {}); }, 2000);
