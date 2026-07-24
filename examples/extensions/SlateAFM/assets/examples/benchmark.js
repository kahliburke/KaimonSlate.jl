// Sustained benchmark: the new BINARY channel vs the old BASE64-in-JSON path. For a chosen payload size,
// each mode round-trips to Julia back-to-back for a fixed DURATION, so we measure steady-state behaviour:
//   • throughput (MB/s, counting bytes up + down) and messages/s,
//   • latency distribution (mean / p50 / p95 / p99 / max) over hundreds of round-trips,
//   • total data transferred.
//   binary : model.send(content, cb, [buffer]) — raw bytes both ways (binary WS frames).
//   base64 : model.send({…, b64}, cb, [])       — bytes base64'd into the JSON call, decoded/re-encoded in
//            Julia, base64 back (what we'd do WITHOUT the uplink). Single-stream: one round-trip in flight.
export default {
  render({ model, el, signal }) {
    el.innerHTML = "";
    var wrap = document.createElement("div");
    wrap.style.cssText = "font:inherit;color:#e2e8f0;display:flex;flex-direction:column;gap:.6em;max-width:720px";

    // ── controls: payload size + per-mode duration ──
    var ctl = document.createElement("div");
    ctl.style.cssText = "display:flex;gap:1.2em;align-items:flex-end;flex-wrap:wrap";
    var SIZES = [{ label: "64 KB", n: 65536 }, { label: "256 KB", n: 262144 },
                 { label: "1 MB", n: 1048576 }, { label: "4 MB", n: 4194304 }];
    var size = SIZES[1].n;
    var sizeBar = document.createElement("div");
    sizeBar.style.cssText = "display:flex;flex-direction:column;gap:.25em";
    var sizeBtns = [];
    var sizeRow = document.createElement("div"); sizeRow.style.cssText = "display:flex;gap:.35em";
    SIZES.forEach(function (s, i) {
      var b = document.createElement("button");
      b.textContent = s.label;
      b.addEventListener("click", function () { size = s.n; paintSizes(); }, { signal });
      sizeBtns.push(b); sizeRow.appendChild(b);
    });
    sizeBar.append(labelled("payload", sizeRow));
    function paintSizes() {
      SIZES.forEach(function (s, i) {
        sizeBtns[i].style.cssText = "font:inherit;padding:.3em .7em;border-radius:8px;cursor:pointer;border:1px solid " +
          (s.n === size ? "#6366f1;background:#4338ca;color:#fff" : "#4a5568;background:#2d3748;color:#e2e8f0");
      });
    }
    paintSizes();

    var durInput = document.createElement("input");
    durInput.type = "number"; durInput.value = "4"; durInput.min = "1"; durInput.max = "20"; durInput.step = "1";
    durInput.style.cssText = "font:inherit;width:4em;padding:.3em .4em;border-radius:8px;border:1px solid #4a5568;background:#1e293b;color:#e2e8f0";
    var run = document.createElement("button");
    run.textContent = "Run sustained benchmark";
    run.style.cssText = "font:inherit;padding:.4em .9em;border-radius:8px;border:1px solid #4a5568;background:#2d3748;color:#e2e8f0;cursor:pointer";
    ctl.append(sizeBar, labelled("seconds / mode", durInput), run);

    var status = document.createElement("div");
    status.style.cssText = "font-size:.82em;color:#94a3b8;min-height:1.2em";
    var table = document.createElement("div");
    wrap.append(ctl, status, table);
    el.appendChild(wrap);

    function labelled(text, node) {
      var box = document.createElement("div");
      box.style.cssText = "display:flex;flex-direction:column;gap:.25em";
      var cap = document.createElement("span"); cap.textContent = text;
      cap.style.cssText = "font-size:.72em;color:#64748b";
      box.append(cap, node); return box;
    }

    // ── base64 <-> bytes (chunked) ──
    function b64FromU8(u8) { var s = "", CH = 0x8000; for (var i = 0; i < u8.length; i += CH) s += String.fromCharCode.apply(null, u8.subarray(i, i + CH)); return btoa(s); }
    function u8FromB64(b64) { var bin = atob(b64), u = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; }

    // Sequential request/reply: one in flight, single resolver correlates the reply.
    var resolveReply = null;
    model.on("msg:custom", function (content, buffers) { var r = resolveReply; resolveReply = null; if (r) r({ content: content, buffers: buffers }); });
    function send(content, buffers) { return new Promise(function (res) { resolveReply = res; model.send(content, undefined, buffers || []); }); }

    function makePayload(n) { var u = new Uint8Array(n); for (var i = 0; i < n; i++) u[i] = i & 255; return u; }
    async function binRound(u8) { var r = await send({ op: "bench", mode: "binary" }, [u8.buffer]); return r.buffers && r.buffers[0] && r.buffers[0].byteLength === u8.length; }
    async function b64Round(u8) { var r = await send({ op: "bench", mode: "base64", b64: b64FromU8(u8) }, []); return u8FromB64(r.content.b64).length === u8.length; }

    function stats(lat) {
      var s = lat.slice().sort(function (a, b) { return a - b; });
      var sum = 0; for (var i = 0; i < s.length; i++) sum += s[i];
      function p(q) { return s.length ? s[Math.min(s.length - 1, Math.floor(q / 100 * s.length))] : 0; }
      return { mean: s.length ? sum / s.length : 0, p50: p(50), p95: p(95), p99: p(99), max: s.length ? s[s.length - 1] : 0 };
    }

    // Run one mode back-to-back for `durationMs`, gathering latency + totals. `onTick` gets live progress.
    async function runMode(roundFn, u8, durationMs, onTick) {
      var lat = [], count = 0, bytes = 0, start = performance.now(), lastTick = start;
      while (performance.now() - start < durationMs) {
        var t0 = performance.now();
        await roundFn(u8);
        lat.push(performance.now() - t0);
        count++; bytes += 2 * u8.length;                 // up + down
        var now = performance.now();
        if (now - lastTick > 200) { lastTick = now; onTick(count, (now - start) / 1000); }
      }
      var dur = (performance.now() - start) / 1000;
      return { count: count, bytes: bytes, dur: dur, st: stats(lat) };
    }

    async function go() {
      run.disabled = true; table.innerHTML = "";
      var u8 = makePayload(size), durMs = Math.max(1, Math.min(20, +durInput.value || 4)) * 1000;
      var results = {};
      var modes = [{ key: "binary", fn: binRound }, { key: "base64", fn: b64Round }];
      for (var m = 0; m < modes.length; m++) {
        var mode = modes[m];
        await mode.fn(u8);   // warm-up
        status.textContent = "running " + mode.key + " @ " + fmtBytes(size) + "…";
        results[mode.key] = await runMode(mode.fn, u8, durMs, function (c, secs) {
          status.textContent = mode.key + " @ " + fmtBytes(size) + " — " + c + " round-trips in " + secs.toFixed(1) + "s";
          renderTable(results);
        });
        renderTable(results);
      }
      var totMB = ((results.binary.bytes + results.base64.bytes) / 1e6).toFixed(0);
      status.textContent = "done — " + fmtBytes(size) + " payload · " + totMB + " MB moved total · single-stream, median-of-run";
      run.disabled = false;
    }

    function fmtBytes(n) { return n >= 1048576 ? (n / 1048576) + " MB" : (n / 1024) + " KB"; }
    function tp(r) { return r ? ((r.bytes / 1e6) / r.dur).toFixed(0) : "…"; }        // MB/s (up+down)
    function mps(r) { return r ? (r.count / r.dur).toFixed(0) : "…"; }               // messages/s

    function renderTable(res) {
      var b = res.binary, x = res.base64;
      var rows = [
        ["round-trips", b && b.count, x && x.count, null],
        ["data moved (MB)", b && (b.bytes / 1e6).toFixed(0), x && (x.bytes / 1e6).toFixed(0), null],
        ["throughput (MB/s)", tp(b), tp(x), ratio(b, x, function (r) { return r.bytes / r.dur; })],
        ["messages / s", mps(b), mps(x), ratio(b, x, function (r) { return r.count / r.dur; })],
        ["latency mean (ms)", f2(b, "mean"), f2(x, "mean"), ratioLat(b, x, "mean")],
        ["latency p50 (ms)", f2(b, "p50"), f2(x, "p50"), ratioLat(b, x, "p50")],
        ["latency p95 (ms)", f2(b, "p95"), f2(x, "p95"), ratioLat(b, x, "p95")],
        ["latency p99 (ms)", f2(b, "p99"), f2(x, "p99"), ratioLat(b, x, "p99")],
        ["latency max (ms)", f2(b, "max"), f2(x, "max"), ratioLat(b, x, "max")],
      ];
      var html = '<table style="border-collapse:collapse;font-size:.82em;width:100%">' +
        '<thead><tr>' + ["metric", "binary", "base64", "advantage"].map(function (h, i) {
          return '<th style="text-align:' + (i ? "right" : "left") + ';padding:.3em .6em;border-bottom:1px solid #334155;color:#cbd5e1">' + h + '</th>';
        }).join("") + '</tr></thead><tbody>';
      rows.forEach(function (r) {
        html += '<tr>' +
          '<td style="text-align:left;padding:.25em .6em;border-bottom:1px solid #1e293b;color:#94a3b8">' + r[0] + '</td>' +
          '<td style="text-align:right;padding:.25em .6em;border-bottom:1px solid #1e293b;color:#93c5fd">' + (r[1] == null ? "…" : r[1]) + '</td>' +
          '<td style="text-align:right;padding:.25em .6em;border-bottom:1px solid #1e293b;color:#cbd5e1">' + (r[2] == null ? "…" : r[2]) + '</td>' +
          '<td style="text-align:right;padding:.25em .6em;border-bottom:1px solid #1e293b;color:#6ee7b7;font-weight:600">' + (r[3] == null ? "" : r[3]) + '</td>' +
          '</tr>';
      });
      table.innerHTML = html + '</tbody></table>';
    }
    function f2(r, k) { return r ? r.st[k].toFixed(2) : "…"; }
    function ratio(b, x, f) { return (b && x) ? (f(b) / f(x)).toFixed(1) + "× faster" : ""; }
    function ratioLat(b, x, k) { return (b && x && b.st[k]) ? (x.st[k] / b.st[k]).toFixed(1) + "× lower" : ""; }

    run.addEventListener("click", function () { go(); }, { signal });
  },
};
