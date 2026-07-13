// The page's reverse-direction channel to Julia, over ONE persistent WebSocket:
//   • JS→Julia CALLS  — window.slateCall("channel", args) → Promise (reply correlated by id)
//   • Julia→JS STREAM — slate_emit("channel", value) is pushed here as {t:"emit",channel,data} and
//                       dispatched to slateOnStream handlers. (Moved off SSE, which coalesces under
//                       backpressure — right for idempotent cell patches, but it dropped stream frames
//                       where each one matters.)
// The socket connects EAGERLY on load (so the server can push emits) and auto-reconnects on drop. SSE
// still carries the idempotent cell patches. NB_ID + the ws(s):// scheme mirror core.js's _apipath.
(function () {
  const NB_ID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
  const WS_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/' + NB_ID + '/ws';
  const CALL_TIMEOUT_MS = 35000;          // just above the server's 30s handler timeout — a lost reply won't hang forever
  const RECONNECT_MS = 1000;
  let ws = null, ready = null;            // `ready` resolves when the socket is OPEN; null when there's no live socket
  let seq = 0;
  const pending = new Map();              // correlation id → { resolve, reject }
  let _reconnT = null;
  function scheduleReconnect() {
    if (_reconnT) return;
    _reconnT = setTimeout(() => { _reconnT = null; connect().catch(() => {}); }, RECONNECT_MS);
  }

  function connect() {
    if (ready) return ready;
    ready = new Promise((resolve, reject) => {
      let sock;
      try { sock = new WebSocket(WS_URL); } catch (e) { ready = null; scheduleReconnect(); reject(e); return; }
      ws = sock;
      sock.onopen = () => resolve(sock);
      sock.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch (_) { return; }
        if (m.t === 'emit') {                                 // slate_emit push → the slateOnStream registry
          try { window.onCellStream && window.onCellStream(m.channel, m.data); } catch (_) {}
          return;
        }
        if (m.t === 'dropped') {                              // explicit overflow signal (client fell behind)
          try { console.warn('slate stream: dropped ' + m.n + ' frame(s) — client behind'); } catch (_) {}
          return;
        }
        if (m.t === 'health') {                               // watchdog status push (replaces the GET /api/health poll)
          try { window.onSlateHealth && window.onSlateHealth(m.data); } catch (_) {}
          return;
        }
        if (m.t === 'telemetry') {                            // per-worker telemetry push (replaces the pill/popup stat poll)
          try { window.onWorkerTelemetry && window.onWorkerTelemetry(m.side, m.stats); } catch (_) {}
          return;
        }
        if (m.t === 'log') {                                  // worker log line push (live tail into an open popup)
          try { window.onWorkerLog && window.onWorkerLog(m.side, m.line); } catch (_) {}
          return;
        }
        if (m.t === 'workers') {                              // worker/pill list push (region spawn start/connect)
          try { window.onWorkersUpdate && window.onWorkersUpdate(m.data); } catch (_) {}
          return;
        }
        const p = pending.get(m.id); if (!p) return;          // else: a call reply
        pending.delete(m.id);
        m.ok ? p.resolve(m.value) : p.reject(new Error(m.error || 'slateCall failed'));
      };
      const drop = () => {
        if (ws === sock) { ws = null; ready = null; }
        for (const [, p] of pending) p.reject(new Error('slateCall: socket closed'));   // fail in-flight
        pending.clear();
        scheduleReconnect();                                  // the socket must stay live for the emit stream
      };
      sock.onclose = drop;
      sock.onerror = () => { try { sock.close(); } catch (_) {} };   // → onclose → drop → reconnect
    });
    return ready;
  }

  // Call a Julia `slate_on` handler and await its (JSON-serializable) result. Rejects on a throwing
  // handler, an unregistered channel, a timeout, or a dropped socket (just call again — it reconnects).
  window.slateCall = async function (channel, args) {
    if (!NB_ID) throw new Error('slateCall: no notebook id in the page URL');
    await connect();
    const id = 'c' + (++seq);
    const p = new Promise((resolve, reject) => {
      const to = setTimeout(() => {
        if (pending.has(id)) { pending.delete(id); reject(new Error('slateCall timed out: ' + channel)); }
      }, CALL_TIMEOUT_MS);
      pending.set(id, { resolve: (v) => { clearTimeout(to); resolve(v); },
                        reject:  (e) => { clearTimeout(to); reject(e); } });
    });
    try { ws.send(JSON.stringify({ id, channel: String(channel), args: args === undefined ? null : args })); }
    catch (e) { const q = pending.get(id); if (q) { pending.delete(id); q.reject(e); } }
    return p;
  };

  if (NB_ID) connect().catch(() => {});   // eager: the server pushes slate_emit frames onto this socket
})();
