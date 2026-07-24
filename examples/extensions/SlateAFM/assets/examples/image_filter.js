// Binary-buffer SHOWCASE: an image round-trips to Julia for real processing. The widget draws a
// procedural image on a canvas, ships its raw RGBA pixels (a ~130 KB Uint8Array) to Julia via
// `model.send(content, cb, [buffer])`, Julia applies an image filter and returns the processed pixels over
// the binary WebSocket, and the widget paints the result. Both directions carry real bytes — no base64.
export default {
  render({ model, el, signal }) {
    var w = model.get("w") || 180, h = model.get("h") || 180;
    el.innerHTML = "";
    var wrap = document.createElement("div");
    wrap.style.cssText = "font:inherit;color:#e2e8f0;display:flex;flex-direction:column;gap:.6em";

    function mkCanvas(label) {
      var box = document.createElement("div");
      box.style.cssText = "display:flex;flex-direction:column;gap:.25em";
      var cap = document.createElement("span");
      cap.textContent = label; cap.style.cssText = "font-size:.78em;color:#94a3b8";
      var cv = document.createElement("canvas");
      cv.width = w; cv.height = h;
      cv.style.cssText = "border:1px solid #334155;border-radius:6px;image-rendering:pixelated;width:" +
        w + "px;height:" + h + "px";
      box.append(cap, cv);
      return { box: box, cv: cv };
    }
    var row = document.createElement("div");
    row.style.cssText = "display:flex;gap:1em;align-items:flex-start;flex-wrap:wrap";
    var src = mkCanvas("input — drawn in the browser");
    var dst = mkCanvas("output — processed in Julia");
    row.append(src.box, dst.box);

    var bar = document.createElement("div");
    bar.style.cssText = "display:flex;gap:.4em;align-items:center;flex-wrap:wrap";
    var status = document.createElement("span");
    status.style.cssText = "font-size:.78em;color:#94a3b8;margin-left:.4em";
    status.textContent = "pick a filter →";
    ["invert", "grayscale", "edges", "threshold"].forEach(function (name) {
      var b = document.createElement("button");
      b.textContent = name;
      b.style.cssText = "font:inherit;padding:.35em .7em;border-radius:8px;border:1px solid #4a5568;" +
        "background:#2d3748;color:#e2e8f0;cursor:pointer";
      b.addEventListener("click", function () { process(name); }, { signal });
      bar.appendChild(b);
    });
    bar.appendChild(status);
    wrap.append(row, bar);
    el.appendChild(wrap);

    // Draw the procedural source image — a gradient plus a few shapes so edges/threshold are obvious.
    var sctx = src.cv.getContext("2d");
    var g = sctx.createLinearGradient(0, 0, w, h);
    g.addColorStop(0, "#1e3a8a"); g.addColorStop(1, "#7c3aed");
    sctx.fillStyle = g; sctx.fillRect(0, 0, w, h);
    sctx.fillStyle = "#f59e0b"; sctx.beginPath(); sctx.arc(w * 0.35, h * 0.42, w * 0.18, 0, 7); sctx.fill();
    sctx.fillStyle = "#10b981"; sctx.fillRect(w * 0.54, h * 0.5, w * 0.34, h * 0.34);
    sctx.strokeStyle = "#f8fafc"; sctx.lineWidth = Math.max(2, w * 0.02);
    sctx.beginPath(); sctx.moveTo(w * 0.08, h * 0.9); sctx.lineTo(w * 0.92, h * 0.12); sctx.stroke();
    sctx.fillStyle = "#f8fafc"; sctx.font = "bold " + Math.round(h * 0.17) + "px sans-serif";
    sctx.fillText("Jl", w * 0.06, h * 0.3);
    var dctx = dst.cv.getContext("2d");

    var pending = null;
    function process(name) {
      var img = sctx.getImageData(0, 0, w, h);   // RGBA Uint8ClampedArray, length w*h*4
      pending = { name: name, t0: performance.now() };
      status.textContent = name + ": sending " + img.data.byteLength.toLocaleString() + " bytes → Julia…";
      model.send({ op: "filter", name: name, w: w, h: h }, undefined, [img.data.buffer]);
    }

    model.on("msg:custom", function (content, buffers) {
      var b = buffers && buffers[0];
      if (!b) return;
      var bytes = new Uint8ClampedArray(b);      // real ArrayBuffer back over the binary WS
      dctx.putImageData(new ImageData(bytes, w, h), 0, 0);
      var dt = pending ? (performance.now() - pending.t0).toFixed(0) : "?";
      status.textContent = ((content && content.name) || "done") + ": " + bytes.byteLength.toLocaleString() +
        " bytes back in " + dt + " ms round-trip";
      pending = null;
    });
  },
};
