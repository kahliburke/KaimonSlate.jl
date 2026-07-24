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
  const progressCbs = new Map();          // correlation id → onProgress(frame) (a call with live progress)
  let _reconnT = null;
  function scheduleReconnect() {
    if (_reconnT) return;
    _reconnT = setTimeout(() => { _reconnT = null; connect().catch(() => {}); }, RECONNECT_MS);
  }

  // Decode a binary numeric frame (SlateExtensionsBase.encode_binary_frame) and route it to the channel's
  // slateOnStream handler as {…meta, d: TypedArray} — no JSON, no parse of the array (the whole point).
  // Layout: [u8 ver=1][u16 chanLen][chan][u16 metaLen][metaJSON][u8 dtype][u8 rank][rank×u32 dims][raw LE bytes].
  const _TYPED = [Float32Array, Float64Array, Int32Array, Int16Array, Uint8Array];   // keep in sync with core.js _SLATE_TYPED
  const _td = new TextDecoder();
  function _dispatchBinary(buf) {
    try {
      const dv = new DataView(buf); let o = 0;
      if (dv.getUint8(o) !== 1) return; o += 1;
      const cl = dv.getUint16(o, true); o += 2;
      const channel = _td.decode(new Uint8Array(buf, o, cl)); o += cl;
      const ml = dv.getUint16(o, true); o += 2;
      let meta = {}; if (ml) { try { meta = JSON.parse(_td.decode(new Uint8Array(buf, o, ml))); } catch (_) {} } o += ml;
      const dtype = dv.getUint8(o); o += 1;
      const rank = dv.getUint8(o); o += 1;
      const dims = []; for (let i = 0; i < rank; i++) { dims.push(dv.getUint32(o, true)); o += 4; }
      const Ctor = _TYPED[dtype]; if (!Ctor) return;
      meta.d = new Ctor(new Uint8Array(buf, o).slice().buffer);   // copy the payload → element-aligned buffer
      meta.dims = dims;
      window.onCellStream && window.onCellStream(channel, meta);
    } catch (_) {}
  }

  function connect() {
    if (ready) return ready;
    ready = new Promise((resolve, reject) => {
      let sock;
      try { sock = new WebSocket(WS_URL); } catch (e) { ready = null; scheduleReconnect(); reject(e); return; }
      ws = sock;
      sock.binaryType = 'arraybuffer';                      // receive binary numeric frames as ArrayBuffer
      sock.onopen = () => resolve(sock);
      sock.onmessage = (ev) => {
        if (ev.data instanceof ArrayBuffer) { _dispatchBinary(ev.data); return; }   // binary numeric frame
        let m; try { m = JSON.parse(ev.data); } catch (_) { return; }
        if (m.t === 'emit') {                                 // slate_emit push → the slateOnStream registry
          if (m.channel === '__slate_call_progress') {        // framework progress → THIS call's onProgress (by id)
            const d = m.data, cb = d && progressCbs.get(d.id);
            if (cb) { try { cb(d.data); } catch (_) {} }
            return;
          }
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
        progressCbs.clear();                                  // no more progress can arrive on a dead socket
        scheduleReconnect();                                  // the socket must stay live for the emit stream
      };
      sock.onclose = drop;
      sock.onerror = () => { try { sock.close(); } catch (_) {} };   // → onclose → drop → reconnect
    });
    return ready;
  }

  // Encode ONE browser→server binary buffer as a self-describing frame — the SAME layout the server→browser
  // numeric stream uses (see `_dispatchBinary` / SlateExtensionsBase.encode_binary_frame), so both directions
  // share one wire format. `channel` carries the correlating call id; `meta` is the tiny {i,n} header; the
  // payload is raw bytes (dtype UInt8, rank 1). The server reads it with plain byte reads + JSON for meta.
  // Layout: [u8 ver=1][u16 chanLen][chan][u16 metaLen][metaJSON][u8 dtype][u8 rank][rank×u32 dims][bytes].
  const _te = new TextEncoder();
  function _encodeU8Frame(channel, meta, u8) {
    const chB = _te.encode(String(channel)), metaB = _te.encode(JSON.stringify(meta));
    const buf = new ArrayBuffer(1 + 2 + chB.length + 2 + metaB.length + 1 + 1 + 4 + u8.length);
    const dv = new DataView(buf); let o = 0;
    dv.setUint8(o, 1); o += 1;
    dv.setUint16(o, chB.length, true); o += 2; new Uint8Array(buf, o, chB.length).set(chB); o += chB.length;
    dv.setUint16(o, metaB.length, true); o += 2; new Uint8Array(buf, o, metaB.length).set(metaB); o += metaB.length;
    dv.setUint8(o, 4); o += 1;   // dtype: UInt8 (keep in sync with _TYPED / _bin_dtype)
    dv.setUint8(o, 1); o += 1;   // rank 1
    dv.setUint32(o, u8.length, true); o += 4;
    new Uint8Array(buf, o, u8.length).set(u8);
    return buf;
  }
  function _asU8(b) {
    return (b instanceof ArrayBuffer) ? new Uint8Array(b)
         : ArrayBuffer.isView(b) ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength)
         : new Uint8Array(b);
  }

  // Call a Julia `slate_on` handler and await its (JSON-serializable) result. Rejects on a throwing
  // handler, an unregistered channel, a timeout, or a dropped socket (just call again — it reconnects).
  // `onProgress` (optional): called with each progress frame a 2-arg Julia handler streams via its
  // `progress(...)` closure during this call — correlated by the call id, framework-side (no token). The
  // final result is still the resolved value. Progress frames after the reply/timeout are ignored.
  // `buffers` (optional): an array of ArrayBuffer/TypedArray sent as native binary WS frames (correlated by
  // call id) BEFORE the JSON call — the server decodes them and hands the handler `args.__slate_buffers`
  // (a `Vector{Vector{UInt8}}`). No base64: real binary on the same socket the numeric stream already uses.
  window.slateCall = async function (channel, args, onProgress, buffers) {
    if (!NB_ID) throw new Error('slateCall: no notebook id in the page URL');
    await connect();
    const id = 'c' + (++seq);
    if (typeof onProgress === 'function') progressCbs.set(id, onProgress);
    const done = () => progressCbs.delete(id);
    const p = new Promise((resolve, reject) => {
      const to = setTimeout(() => {
        if (pending.has(id)) { pending.delete(id); done(); reject(new Error('slateCall timed out: ' + channel)); }
      }, CALL_TIMEOUT_MS);
      pending.set(id, { resolve: (v) => { clearTimeout(to); done(); resolve(v); },
                        reject:  (e) => { clearTimeout(to); done(); reject(e); } });
    });
    const nbuf = buffers && buffers.length ? buffers.length : 0;
    try {
      // Buffer frames FIRST — the socket preserves order, so the server has them buffered by the time the
      // JSON call (carrying `nbuf`) arrives and dispatches.
      for (let i = 0; i < nbuf; i++) ws.send(_encodeU8Frame(id, { i, n: nbuf }, _asU8(buffers[i])));
      ws.send(JSON.stringify({ id, channel: String(channel), args: args === undefined ? null : args, nbuf }));
    } catch (e) { const q = pending.get(id); if (q) { pending.delete(id); done(); q.reject(e); } }
    return p;
  };

  if (NB_ID) connect().catch(() => {});   // eager: the server pushes slate_emit frames onto this socket
})();
