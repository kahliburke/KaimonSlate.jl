// Browser diagnostics capture. Installed FIRST (before any other script) so it catches early
// errors — failed resource loads, uncaught exceptions, unhandled rejections, console.error —
// into a small ring buffer that's pushed to the server (POST /api/<id>/diag). The `slate.diag`
// MCP tool reads the latest push, so the console can be checked from an agent without a
// headless browser: just have the notebook open and reload. Push-based — reflects this tab.
(function () {
  var NBID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
  if (!NBID) return;
  // A per-page-load id so the server can tell a fresh reload from a stale prior session.
  var session = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6);
  var buf = [], timer = null;
  window.__diag = buf;

  function send() {
    timer = null;
    try {
      fetch('/api/' + NBID + '/diag', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, keepalive: true,
        body: JSON.stringify({ session: session, ts: new Date().toISOString(), url: location.href, entries: buf }),
      });
    } catch (e) { /* best-effort */ }
  }
  function flush() { if (!timer) timer = setTimeout(send, 400); }   // debounce bursts
  function push(kind, text) {
    buf.push({ kind: kind, text: String(text).slice(0, 1200), t: new Date().toISOString() });
    if (buf.length > 100) buf.shift();
    flush();
  }

  // Resource load failures (img/script/link with a src/href) come through as a non-window
  // target on the capture-phase error event; real exceptions have message/filename.
  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && (t.src || t.href)) push('resource', (t.tagName || '?') + ' failed to load: ' + (t.src || t.href));
    else push('error', (e.message || 'error') + (e.filename ? ' @ ' + e.filename + ':' + (e.lineno || 0) : ''));
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    push('rejection', (r && (r.stack || r.message)) || String(r) || 'unhandled rejection');
  });
  var _ce = console.error;
  console.error = function () {
    try { push('console.error', Array.prototype.map.call(arguments, String).join(' ')); } catch (x) {}
    return _ce.apply(console, arguments);
  };

  // Establish the session on load even with zero errors, so slate.diag can report "clean".
  if (document.readyState === 'complete') setTimeout(send, 300);
  else window.addEventListener('load', function () { setTimeout(send, 300); });
})();
