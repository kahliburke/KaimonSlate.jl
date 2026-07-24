// Binary-buffer round-trip demo. Proves BOTH message directions carry real bytes:
//   • JS → Julia: `model.send(content, cb, [ArrayBuffer])` — the host base64s the buffer into the
//     slateCall payload; Julia base64-decodes it to a `Vector{UInt8}` for the `afm_on_msg` handler.
//   • Julia → JS: `model.on("msg:custom", (content, buffers))` — the buffers arrive as real ArrayBuffers
//     over Slate's binary stream. The Julia handler echoes the bytes back (reversed) so the transform is
//     visible.
export default {
  render({ model, el, signal }) {
    el.innerHTML = "";
    const wrap = document.createElement("div");
    wrap.style.cssText = "font:inherit;color:#e2e8f0;display:flex;flex-direction:column;gap:.5em";
    const btn = document.createElement("button");
    btn.style.cssText =
      "font:inherit;padding:.4em .8em;border-radius:8px;border:1px solid #4a5568;" +
      "background:#2d3748;color:#e2e8f0;cursor:pointer;align-self:flex-start";
    const sent = document.createElement("pre");
    const got = document.createElement("pre");
    sent.style.cssText = got.style.cssText = "margin:0";
    got.style.color = "#9ae6b4";
    got.textContent = "reply → (click to send)";
    wrap.append(btn, sent, got);
    el.appendChild(wrap);

    let n = 0;
    const draw = () => { btn.textContent = "send Uint8Array →"; };
    btn.addEventListener("click", () => {
      const bytes = new Uint8Array([10, 20, 30, 40].map((x) => x + n));
      n++;
      sent.textContent = "sent  content={op:'echo'} bytes=[" + Array.from(bytes).join(",") + "]";
      model.send({ op: "echo" }, undefined, [bytes.buffer]);   // JS → Julia, with a binary buffer
    }, { signal });

    model.on("msg:custom", (content, buffers) => {             // Julia → JS reply, with a binary buffer
      const b = buffers && buffers[0];
      const arr = b ? Array.from(new Uint8Array(b)) : [];
      got.textContent = "reply content=" + JSON.stringify(content) + " bytes=[" + arr.join(",") + "]";
    });
    draw();
  },
};
