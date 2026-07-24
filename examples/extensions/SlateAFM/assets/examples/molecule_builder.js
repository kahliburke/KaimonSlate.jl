// A Julia-DRIVEN molecule widget: a rotating 3D molecule that Julia assembles by streaming atom geometry
// over the binary `msg:custom` channel. It holds no molecule of its own — it renders whatever atoms/bonds
// Julia pushes. Messages (via afm_emit): {op:"reset"}, {op:"atoms", els:[…]} + a Float32 xyz buffer (n×3),
// {op:"bonds"} + an Int32 index-pair buffer. Buffers arrive as real ArrayBuffers (no base64).
//
// Rendering aims for a "real molecule" look: CPK-ish coloured spheres (radius + colour per element code),
// split-colour stick bonds, depth fog + perspective, continuous tumble.
export default {
  render({ model, el, signal }) {
    const H = model.get("height") || 440;
    el.innerHTML = "";
    const wrap = document.createElement("div");
    wrap.style.cssText = "font:inherit;color:#e2e8f0;display:flex;flex-direction:column;gap:.4em";
    const canvas = document.createElement("canvas");
    canvas.style.cssText = "width:100%;height:" + H + "px;border:1px solid #1e293b;border-radius:8px;" +
      "background:radial-gradient(circle at 50% 36%,#0c1526,#04060c)";
    const status = document.createElement("div");
    status.style.cssText = "font-size:.8em;color:#94a3b8";
    status.textContent = "waiting for atoms from Julia — click ⚛ Assemble";
    wrap.append(canvas, status);
    el.appendChild(wrap);
    const ctx = canvas.getContext("2d");

    // Element code → {colour (rgb), radius}. 0 = phosphate backbone; 1–4 = the four DNA bases (A/T/G/C).
    const BG = [4, 6, 12];
    const ELEM = {
      0: { c: [227, 179, 65], r: 1.25 },   // P — backbone (tan/orange)
      1: { c: [63, 185, 80], r: 0.95 },    // A — green
      2: { c: [248, 81, 73], r: 0.95 },    // T — red
      3: { c: [88, 166, 255], r: 0.95 },   // G — blue
      4: { c: [210, 168, 255], r: 0.95 },  // C — purple
    };
    const elem = (code) => ELEM[code] || { c: [148, 163, 184], r: 0.9 };

    let atoms = [], els = [], bonds = [];
    model.on("msg:custom", (content, buffers) => {
      const op = content && content.op;
      if (op === "reset") { atoms = []; els = []; bonds = []; status.textContent = "assembling…"; }
      else if (op === "atoms" && buffers && buffers[0]) {
        const f = new Float32Array(buffers[0]);
        for (let i = 0; i + 2 < f.length; i += 3) atoms.push([f[i], f[i + 1], f[i + 2]]);
        (content.els || []).forEach((e) => els.push(e | 0));
        status.textContent = atoms.length + " atoms";
      } else if (op === "bonds" && buffers && buffers[0]) {
        const b = new Int32Array(buffers[0]); bonds = [];
        for (let i = 0; i + 1 < b.length; i += 2) bonds.push([b[i], b[i + 1]]);
        status.textContent = atoms.length + " atoms · " + bonds.length + " bonds";
      }
    });

    // Size the drawing buffer to the element once per layout change (HiDPI-aware); draw in CSS pixels.
    let vW = 1, vH = H;
    function resize() {
      const dpr = window.devicePixelRatio || 1;
      vW = Math.max(1, canvas.clientWidth); vH = H;
      canvas.width = Math.round(vW * dpr); canvas.height = Math.round(vH * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    resize();
    const ro = new ResizeObserver(resize); ro.observe(canvas);

    const mix = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
    const rgb = (c) => "rgb(" + (c[0] | 0) + "," + (c[1] | 0) + "," + (c[2] | 0) + ")";

    let ay = 0, raf = 0, running = true;
    function frame() {
      if (!running) return;
      const W = vW, Ht = vH;
      ctx.clearRect(0, 0, W, Ht);
      ay += 0.011;
      if (atoms.length) {
        let cx = 0, cy = 0, cz = 0;
        for (const p of atoms) { cx += p[0]; cy += p[1]; cz += p[2]; }
        cx /= atoms.length; cy /= atoms.length; cz /= atoms.length;
        let maxr = 1e-3;
        for (const p of atoms) maxr = Math.max(maxr, Math.hypot(p[0] - cx, p[1] - cy, p[2] - cz));
        const scale = Math.min(W, Ht) * 0.40 / maxr, ax = 0.42, d = 4 * maxr;

        let zmin = 1e9, zmax = -1e9;
        const proj = atoms.map((p) => {
          const x = p[0] - cx, y0 = p[1] - cy, z0 = p[2] - cz;
          const X = x * Math.cos(ay) - z0 * Math.sin(ay);
          const Z = x * Math.sin(ay) + z0 * Math.cos(ay);
          const Y = y0 * Math.cos(ax) - Z * Math.sin(ax);
          const Z2 = y0 * Math.sin(ax) + Z * Math.cos(ax);
          const f = d / (d + Z2);
          if (Z2 < zmin) zmin = Z2; if (Z2 > zmax) zmax = Z2;
          return { sx: W / 2 + X * scale * f, sy: Ht / 2 - Y * scale * f, f, z: Z2 };
        });
        const near = (i) => (zmax > zmin ? 1 - (proj[i].z - zmin) / (zmax - zmin) : 1);   // 1 = front
        const fog = (i, c) => mix(BG, c, 0.35 + 0.65 * near(i));                          // fade far atoms

        // Split-colour stick bonds (each half tinted by its atom), depth-scaled width, behind the atoms.
        ctx.lineCap = "round";
        for (const [i, j] of bonds) {
          if (i >= proj.length || j >= proj.length) continue;
          const a = proj[i], b = proj[j], mxp = (a.sx + b.sx) / 2, myp = (a.sy + b.sy) / 2;
          ctx.lineWidth = Math.max(1.4, 3.4 * ((a.f + b.f) / 2));
          ctx.strokeStyle = rgb(fog(i, elem(els[i]).c));
          ctx.beginPath(); ctx.moveTo(a.sx, a.sy); ctx.lineTo(mxp, myp); ctx.stroke();
          ctx.strokeStyle = rgb(fog(j, elem(els[j]).c));
          ctx.beginPath(); ctx.moveTo(mxp, myp); ctx.lineTo(b.sx, b.sy); ctx.stroke();
        }

        // Atoms: shaded spheres (highlight → colour → dark rim), depth-sorted far→near, fogged by depth.
        const order = proj.map((_, i) => i).sort((a, b) => proj[a].f - proj[b].f);
        for (const i of order) {
          const p = proj[i], e = elem(els[i]);
          const base = fog(i, e.c), rad = Math.max(2.2, e.r * scale * 0.16 * p.f);
          const g = ctx.createRadialGradient(p.sx - rad * 0.35, p.sy - rad * 0.35, rad * 0.1, p.sx, p.sy, rad);
          g.addColorStop(0, rgb(mix(base, [255, 255, 255], 0.75)));
          g.addColorStop(0.45, rgb(base));
          g.addColorStop(1, rgb(mix(base, [0, 0, 0], 0.45)));
          ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.sx, p.sy, rad, 0, 7); ctx.fill();
        }
      }
      raf = requestAnimationFrame(frame);
    }
    frame();
    const stop = () => { running = false; if (raf) cancelAnimationFrame(raf); try { ro.disconnect(); } catch (e) {} };
    signal.addEventListener("abort", stop);
    return stop;
  },
};
