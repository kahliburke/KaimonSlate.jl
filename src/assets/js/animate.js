// Slate animation player — a precomputed frame stack played back entirely in the browser.
// See ANIMATION_PIPELINE_DESIGN.md. The cell JSON carries a small manifest (per animation) with a
// `framesUrl` (gzip'd UInt8 stack, browser-gunzipped on fetch) + `lutUrl` (256×RGBA colormap).
// Rendering is GPU-first: the stack is one WebGL2 R8 TEXTURE_2D_ARRAY, colormapped + bilinearly and
// temporally interpolated + dithered in a fragment shader. Playback runs off a wall clock with
// frame-drop (never accumulates lag); nothing touches Julia during playback.
(function () {
  'use strict';

  const players = (window._animPlayers = window._animPlayers || {});   // cellId -> [SlatePlayer]

  // ── Reconcile players for a cell against its manifests (mirrors renderCharts) ────────────────
  window.renderAnimation = function renderAnimation(c) {
    const host = document.querySelector('#cell-' + c.id + ' .anim');
    if (!host) return;
    const specs = c.animations || [];
    let insts = players[c.id] || (players[c.id] = []);
    while (host.children.length > specs.length) {                 // dispose extras
      host.removeChild(host.lastChild);
      const p = insts.pop(); p && p.dispose();
    }
    while (host.children.length < specs.length) {                 // mount new
      const box = document.createElement('div');
      box.className = 'animplayer';
      host.appendChild(box);
      insts.push(new SlatePlayer(box));
    }
    specs.forEach((s, i) => insts[i].setManifest(s));
  };

  const VERT = `#version 300 es
  in vec2 p; out vec2 uv;
  void main(){ uv = vec2((p.x+1.0)*0.5, (1.0-(p.y+1.0)*0.5)); gl_Position = vec4(p,0.0,1.0); }`;

  // Fragment: sample two adjacent layers, mix by the fractional frame (temporal lerp), add a small
  // ordered dither, then look the scalar up in the colormap LUT.
  const FRAG = `#version 300 es
  precision highp float; precision highp sampler2DArray;
  in vec2 uv; out vec4 outColor;
  uniform sampler2DArray frames; uniform sampler2D lut;
  uniform float layer; uniform int n; uniform float dither;
  const mat4 bayer = mat4(
     0.0, 8.0, 2.0,10.0, 12.0, 4.0,14.0, 6.0,
     3.0,11.0, 1.0, 9.0, 15.0, 7.0,13.0, 5.0) / 16.0;
  void main(){
    float f0 = floor(layer);
    float f1 = min(f0 + 1.0, float(n - 1));
    float fr = layer - f0;
    float v0 = texture(frames, vec3(uv, f0)).r;
    float v1 = texture(frames, vec3(uv, f1)).r;
    float v = mix(v0, v1, fr);
    if (dither > 0.5) {
      int bx = int(mod(gl_FragCoord.x, 4.0)); int by = int(mod(gl_FragCoord.y, 4.0));
      v += (bayer[bx][by] - 0.5) / 255.0;
    }
    v = clamp(v, 0.0, 1.0);
    outColor = texture(lut, vec2(v, 0.5));
  }`;

  function compile(gl, type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { console.warn('anim shader:', gl.getShaderInfoLog(s)); }
    return s;
  }

  class SlatePlayer {
    constructor(box) {
      this.box = box;
      this.manifest = null; this.key = '';
      this.frames = null; this.lut = null;          // Uint8Array stack + 256*4 LUT
      this.N = 0; this.H = 0; this.W = 0;
      this.fps = 30; this.times = null;
      this.playing = false; this.loop = true; this.speed = 1;
      this.t0 = 0; this.layer = 0;                   // wall-clock anchor + current fractional frame
      this.visible = false; this.raf = 0; this.fetching = false;
      this._buildDom();
      // Lazy: fetch the stack only when the player scrolls into view; pause when it leaves.
      this.io = new IntersectionObserver((es) => {
        const vis = es.some(e => e.isIntersecting);
        this.visible = vis;
        if (vis) { this._ensureData(); if (this._wantAutoplay) this.play(); }
        else this._stopLoop();
      }, { rootMargin: '400px 0px' });
      this.io.observe(this.box);
      document.addEventListener('visibilitychange', this._onVis = () => {
        if (document.hidden) this._stopLoop(); else if (this.playing) this._startLoop();
      });
    }

    _buildDom() {
      const b = this.box;
      b.innerHTML =
        '<div class="anim-stage"><canvas class="anim-canvas"></canvas>' +
        '<canvas class="anim-cbar" title="colorbar"></canvas></div>' +
        '<div class="anim-axes"></div>' +
        '<div class="anim-bar">' +
          '<button class="anim-play" title="Play/Pause (space)">▶</button>' +
          '<input class="anim-scrub" type="range" min="0" max="0" step="1" value="0">' +
          '<span class="anim-time">0 / 0</span>' +
          '<select class="anim-speed" title="Speed">' +
            '<option value="0.25">0.25×</option><option value="0.5">0.5×</option>' +
            '<option value="1" selected>1×</option><option value="2">2×</option><option value="4">4×</option>' +
          '</select>' +
          '<button class="anim-loop anim-on" title="Loop">↻</button>' +
        '</div>';
      this.canvas = b.querySelector('.anim-canvas');
      this.cbar = b.querySelector('.anim-cbar');
      this.axes = b.querySelector('.anim-axes');
      this.elPlay = b.querySelector('.anim-play');
      this.elScrub = b.querySelector('.anim-scrub');
      this.elTime = b.querySelector('.anim-time');
      this.elSpeed = b.querySelector('.anim-speed');
      this.elLoop = b.querySelector('.anim-loop');
      this.elPlay.onclick = () => this.toggle();
      this.elScrub.oninput = () => { this.pause(); this.layer = +this.elScrub.value; this._draw(); this._tick(); };
      this.elSpeed.onchange = () => { this.speed = +this.elSpeed.value; this.t0 = 0; };
      this.elLoop.onclick = () => { this.loop = !this.loop; this.elLoop.classList.toggle('anim-on', this.loop); };
      // Keyboard transport when focused within the player.
      b.tabIndex = 0;
      b.onkeydown = (e) => {
        if (e.key === ' ') { e.preventDefault(); this.toggle(); }
        else if (e.key === 'ArrowRight') { e.preventDefault(); this.step(e.shiftKey ? 10 : 1); }
        else if (e.key === 'ArrowLeft') { e.preventDefault(); this.step(e.shiftKey ? -10 : -1); }
      };
    }

    setManifest(m) {
      const key = (m && m.framesUrl) || '';
      if (key === this.key) return;                  // same animation — keep playing
      this.key = key; this.manifest = m;
      this.N = (m.shape && m.shape[0]) || 0;
      this.H = (m.shape && m.shape[1]) || 0;
      this.W = (m.shape && m.shape[2]) || 0;
      this.fps = m.fps || 30;
      this.times = (m.times && m.times.length === this.N) ? m.times : null;
      this.loop = !(m.controls && m.controls.loop === false);
      this.elLoop.classList.toggle('anim-on', this.loop);
      this._wantAutoplay = !!(m.controls && m.controls.autoplay) &&
        !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      this.dither = !(m.dither === false);
      this.frames = null; this.lut = null; this.tex = null;     // force reload
      this.elScrub.max = String(Math.max(0, this.N - 1));
      this.layer = 0;
      this._renderAxes();
      if (this.visible) this._ensureData();
    }

    async _ensureData() {
      if (this.frames || this.fetching || !this.key) return;
      this.fetching = true;
      this.box.classList.add('anim-loading');
      try {
        const [fb, lb] = await Promise.all([
          fetch(this._url(this.manifest.framesUrl)).then(r => r.arrayBuffer()),
          fetch(this._url(this.manifest.lutUrl)).then(r => r.arrayBuffer()),
        ]);
        this.frames = new Uint8Array(fb);
        this.lut = new Uint8Array(lb);
        this._initGL();
        this._draw();
        if (this._wantAutoplay) this.play();
      } catch (e) { console.warn('anim fetch failed', e); }
      finally { this.fetching = false; this.box.classList.remove('anim-loading'); }
    }

    _url(u) { return (window.apiBase ? window.apiBase : '') + u; }   // base-URL safe (matches blob URLs)

    // ── WebGL2 setup (falls back to a 2-D canvas renderer) ────────────────────────────────────
    _initGL() {
      const gl = this.canvas.getContext('webgl2', { antialias: false, premultipliedAlpha: false });
      if (!gl) { this.gl = null; this._initLUT2D(); return; }
      this.gl = gl;
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
      gl.bindAttribLocation(prog, 0, 'p'); gl.linkProgram(prog);
      this.prog = prog; gl.useProgram(prog);
      const quad = new Float32Array([-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1]);
      const vbo = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
      gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      // Frame stack → R8 2D array texture (LINEAR for free bilinear spatial interpolation).
      const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D_ARRAY, tex);
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      gl.texImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.R8, this.W, this.H, this.N, 0, gl.RED, gl.UNSIGNED_BYTE, this.frames);
      this.tex = tex;
      // LUT → 256×1 RGBA texture.
      const lt = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, lt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 256, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, this.lut);
      this.lutTex = lt;
      gl.uniform1i(gl.getUniformLocation(prog, 'frames'), 0);
      gl.uniform1i(gl.getUniformLocation(prog, 'lut'), 1);
      gl.uniform1i(gl.getUniformLocation(prog, 'n'), this.N);
      gl.uniform1f(gl.getUniformLocation(prog, 'dither'), this.dither ? 1 : 0);
      this.uLayer = gl.getUniformLocation(prog, 'layer');
      this._sizeCanvas();
      this._drawCbar();
    }

    _initLUT2D() {  // CPU fallback: precompute an ImageData per draw (nearest frame, no temporal lerp)
      this.ctx2d = this.canvas.getContext('2d');
      this.canvas.width = this.W; this.canvas.height = this.H;
      this._img = this.ctx2d.createImageData(this.W, this.H);
      this._sizeCanvas(); this._drawCbar();
    }

    _sizeCanvas() {
      // Honor the data aspect ratio (fixes squished heatmaps); back the canvas at on-screen size ×dpr
      // so the GPU upscales the texture smoothly (LINEAR) rather than scaling a tiny bitmap.
      const cssW = Math.max(80, this.box.clientWidth || 320);
      const cssH = Math.round(cssW * this.H / Math.max(1, this.W));
      this.canvas.style.width = cssW + 'px'; this.canvas.style.height = cssH + 'px';
      if (this.gl) {
        const dpr = Math.min(2, window.devicePixelRatio || 1);
        this.canvas.width = Math.round(cssW * dpr); this.canvas.height = Math.round(cssH * dpr);
        this.gl.viewport(0, 0, this.canvas.width, this.canvas.height);
      }
    }

    _drawCbar() {
      const c = this.cbar, n = 128; c.width = 14; c.height = n;
      const ctx = c.getContext('2d'); const img = ctx.createImageData(14, n);
      for (let y = 0; y < n; y++) {
        const v = 1 - y / (n - 1); const idx = Math.min(255, Math.max(0, Math.round(v * 255)));
        const r = this.lut[idx*4], g = this.lut[idx*4+1], b = this.lut[idx*4+2];
        for (let x = 0; x < 14; x++) { const o = (y*14+x)*4; img.data[o]=r; img.data[o+1]=g; img.data[o+2]=b; img.data[o+3]=255; }
      }
      ctx.putImageData(img, 0, 0);
    }

    _renderAxes() {
      const ax = this.manifest && this.manifest.axes; if (!ax) { this.axes.textContent = ''; return; }
      const fmt = (v) => (Math.abs(v) >= 1000 || (v !== 0 && Math.abs(v) < 0.01)) ? v.toExponential(1) : (+v.toFixed(3));
      const rng = (a) => (a && a.length) ? (fmt(a[0]) + ' … ' + fmt(a[a.length-1])) : '';
      const parts = [];
      if (ax.title) parts.push('<b>' + ax.title + '</b>');
      if (ax.x && ax.x.length) parts.push('x: ' + rng(ax.x));
      if (ax.y && ax.y.length) parts.push('y: ' + rng(ax.y));
      const cl = this.manifest.clim;
      if (cl && cl.range) parts.push('clim: ' + fmt(cl.range[0]) + ' … ' + fmt(cl.range[1]));
      this.axes.innerHTML = parts.join('<span class="anim-sep">·</span>');
    }

    // ── Playback (presentation clock + frame-drop) ────────────────────────────────────────────
    _durationS() {
      if (this.times) return Math.max(1e-3, this.times[this.N-1] - this.times[0]);
      return this.N / Math.max(1e-6, this.fps);
    }
    _layerAt(elapsedS) {                       // elapsed (already speed-scaled) → fractional frame
      if (this.times) {
        const t = this.times[0] + elapsedS;
        let i = 0; while (i < this.N - 1 && this.times[i + 1] <= t) i++;
        if (i >= this.N - 1) return this.N - 1;
        const span = this.times[i+1] - this.times[i] || 1e-6;
        return i + (t - this.times[i]) / span;
      }
      return elapsedS * this.fps;
    }

    play() { if (this.playing || this.N <= 1) return; this.playing = true; this.elPlay.textContent = '⏸'; this.t0 = 0; this._startLoop(); }
    pause() { this.playing = false; this.elPlay.textContent = '▶'; this._stopLoop(); }
    toggle() { this.playing ? this.pause() : this.play(); }
    step(d) { this.pause(); this.layer = Math.max(0, Math.min(this.N - 1, Math.round(this.layer + d))); this._draw(); this._tick(); }

    _startLoop() { if (this.raf || !this.visible) return; this.raf = requestAnimationFrame((ts) => this._frame(ts)); }
    _stopLoop() { if (this.raf) cancelAnimationFrame(this.raf); this.raf = 0; }

    _frame(ts) {
      this.raf = 0;
      if (!this.playing || !this.visible) return;
      if (!this.t0) this.t0 = ts - (this.layer / Math.max(1e-6, this.fps)) * 1000 / this.speed;
      const elapsed = (ts - this.t0) / 1000 * this.speed;        // wall-clock → frame-drop is automatic
      let layer = this._layerAt(elapsed);
      if (layer >= this.N - 1) {
        if (this.loop) { this.t0 = ts; layer = 0; } else { layer = this.N - 1; this.layer = layer; this._draw(); this._tick(); return this.pause(); }
      }
      this.layer = layer; this._draw(); this._tick();
      this._startLoop();
    }

    _tick() {
      this.elScrub.value = String(Math.round(this.layer));
      const cur = Math.round(this.layer);
      const tcur = this.times ? this.times[cur] : cur / this.fps;
      this.elTime.textContent = cur + ' / ' + (this.N - 1) + '  ·  ' + tcur.toFixed(2) + 's';
    }

    _draw() {
      if (!this.frames) return;
      if (this.gl) {
        const gl = this.gl;
        gl.useProgram(this.prog);
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D_ARRAY, this.tex);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this.lutTex);
        gl.uniform1f(this.uLayer, this.layer);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      } else if (this.ctx2d) {
        const f = Math.round(this.layer), base = f * this.H * this.W, d = this._img.data;
        for (let i = 0, p = base; i < this.H * this.W; i++, p++) {
          const idx = this.frames[p] * 4, o = i * 4;
          d[o] = this.lut[idx]; d[o+1] = this.lut[idx+1]; d[o+2] = this.lut[idx+2]; d[o+3] = 255;
        }
        this.ctx2d.putImageData(this._img, 0, 0);
      }
    }

    dispose() {
      this._stopLoop();
      try { this.io.disconnect(); } catch (_) {}
      document.removeEventListener('visibilitychange', this._onVis);
      if (this.gl) { const gl = this.gl; try { gl.deleteTexture(this.tex); gl.deleteTexture(this.lutTex); gl.deleteProgram(this.prog); } catch (_) {} }
      this.box.innerHTML = '';
    }
  }

  // Re-fit canvases on resize (debounced).
  let rt = 0;
  window.addEventListener('resize', () => {
    clearTimeout(rt);
    rt = setTimeout(() => { Object.values(players).flat().forEach(p => { try { p._sizeCanvas(); p._draw(); } catch (_) {} }); }, 120);
  });
})();
