// A Julia-DRIVEN widget: a rotating 3D molecule that Julia assembles by streaming atom geometry over the
// binary `msg:custom` channel. It holds no molecule of its own — it just renders whatever atoms/bonds Julia
// pushes. Messages (via afm_emit): {op:"reset"}, {op:"atoms", els:[…]} + a Float32 xyz buffer (n×3),
// {op:"bonds"} + an Int32 index-pair buffer. Buffers arrive as real ArrayBuffers (no base64).
export default {
  render({ model, el, signal }) {
    const H = model.get("height") || 440;
    el.innerHTML = "";
    const wrap = document.createElement("div");
    wrap.style.cssText = "font:inherit;color:#e2e8f0;display:flex;flex-direction:column;gap:.4em";
    const canvas = document.createElement("canvas");
    canvas.style.cssText = "width:100%;height:" + H + "px;border:1px solid #1e293b;border-radius:8px;" +
      "background:radial-gradient(circle at 50% 38%,#0b1220,#05070d)";
    const status = document.createElement("div");
    status.style.cssText = "font-size:.8em;color:#94a3b8";
    status.textContent = "waiting for atoms from Julia — click ⚛ Assemble";
    wrap.append(canvas, status);
    el.appendChild(wrap);
    const ctx = canvas.getContext("2d");

    // Size the drawing buffer to the element ONCE per layout change (via ResizeObserver), not every frame —
    // a per-frame resize churns while the cell's layout settles (the "shrink on load" wobble). Account for
    // devicePixelRatio so the render stays crisp on HiDPI; draw in CSS-pixel coordinates.
    let vW = 1, vH = H;
    function resize() {
      const dpr = window.devicePixelRatio || 1;
      vW = Math.max(1, canvas.clientWidth); vH = H;
      canvas.width = Math.round(vW * dpr); canvas.height = Math.round(vH * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    resize();
    const ro = new ResizeObserver(resize); ro.observe(canvas);

    let atoms = [], els = [], bonds = [];
    const PAL = ["#fb923c", "#38bdf8", "#a78bfa", "#f472b6", "#facc15"];   // element-code → colour

    model.on("msg:custom", (content, buffers) => {
      const op = content && content.op;
      if (op === "reset") { atoms = []; els = []; bonds = []; status.textContent = "assembling…"; }
      else if (op === "atoms" && buffers && buffers[0]) {
        const f = new Float32Array(buffers[0]);                 // raw Float32 xyz, straight off the wire
        for (let i = 0; i + 2 < f.length; i += 3) atoms.push([f[i], f[i + 1], f[i + 2]]);
        (content.els || []).forEach((e) => els.push(e | 0));
        status.textContent = atoms.length + " atoms";
      } else if (op === "bonds" && buffers && buffers[0]) {
        const b = new Int32Array(buffers[0]); bonds = [];
        for (let i = 0; i + 1 < b.length; i += 2) bonds.push([b[i], b[i + 1]]);
        status.textContent = atoms.length + " atoms · " + bonds.length + " bonds";
      }
    });

    let ay = 0, raf = 0, running = true;
    function frame() {
      if (!running) return;
      const W = Math.max(1, canvas.clientWidth);
      if (canvas.width !== W) canvas.width = W;
      if (canvas.height !== H) canvas.height = H;
      ctx.clearRect(0, 0, W, H);
      ay += 0.012;
      if (atoms.length) {
        let cx = 0, cy = 0, cz = 0;
        for (const p of atoms) { cx += p[0]; cy += p[1]; cz += p[2]; }
        cx /= atoms.length; cy /= atoms.length; cz /= atoms.length;
        let maxr = 1e-3;
        for (const p of atoms) maxr = Math.max(maxr, Math.hypot(p[0] - cx, p[1] - cy, p[2] - cz));
        const scale = Math.min(W, H) * 0.42 / maxr, ax = 0.45, d = 4 * maxr;
        const proj = atoms.map((p) => {
          const x = p[0] - cx, y0 = p[1] - cy, z0 = p[2] - cz;
          const X = x * Math.cos(ay) - z0 * Math.sin(ay);
          const Z = x * Math.sin(ay) + z0 * Math.cos(ay);
          const Y = y0 * Math.cos(ax) - Z * Math.sin(ax);
          const Z2 = y0 * Math.sin(ax) + Z * Math.cos(ax);
          const f = d / (d + Z2);
          return { sx: W / 2 + X * scale * f, sy: H / 2 - Y * scale * f, f };
        });
        ctx.lineWidth = 2; ctx.strokeStyle = "rgba(148,163,184,0.45)";
        for (const [i, j] of bonds) {
          if (i < proj.length && j < proj.length) {
            ctx.beginPath(); ctx.moveTo(proj[i].sx, proj[i].sy); ctx.lineTo(proj[j].sx, proj[j].sy); ctx.stroke();
          }
        }
        const order = proj.map((_, i) => i).sort((a, b) => proj[a].f - proj[b].f);   // far → near (painter's)
        for (const i of order) {
          const p = proj[i], r = Math.max(2.5, 8 * p.f), col = PAL[els[i] % PAL.length] || "#94a3b8";
          const g = ctx.createRadialGradient(p.sx - r * 0.3, p.sy - r * 0.3, r * 0.15, p.sx, p.sy, r);
          g.addColorStop(0, "#ffffff"); g.addColorStop(0.3, col); g.addColorStop(1, col);
          ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.sx, p.sy, r, 0, 7); ctx.fill();
        }
      }
      raf = requestAnimationFrame(frame);
    }
    frame();
    const stop = () => { running = false; if (raf) cancelAnimationFrame(raf); };
    signal.addEventListener("abort", stop);
    return stop;
  },
};
