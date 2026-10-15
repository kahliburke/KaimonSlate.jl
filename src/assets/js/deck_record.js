// Presentation recording — capture this tab (the deck) plus a microphone into a video file.
//
// `getDisplayMedia` with `preferCurrentTab` records exactly what the audience sees, including live
// charts and the optional webcam bubble, which is why the bubble lives INSIDE the deck rather than
// being composited afterwards. Tab audio and the microphone are mixed into one track with WebAudio.
// MediaRecorder emits a chunk every few seconds and each one is POSTed to the hub in order
// (server_recording.jl), so a long talk never accumulates in browser memory and a crash keeps
// everything recorded up to the last chunk.
//
// Chapters come from the deck: slides.js dispatches a `slate-deck` CustomEvent on window with
// `detail = {type: 'slide'|'step'|'enter'|'exit', idx, step, title}`. Each is stamped with the
// time since recording began; on stop they are uploaded as a WebVTT chapter track and a JSON
// timing file beside the video.
//
// The capture cannot exclude part of its own tab, so the in-tab indicator is deliberately small.
// The presenter window (`?present=1`, never captured) gets the full indicator and a stop button
// over the deck's BroadcastChannel.

(function () {
  const NBID = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
  const IS_PRESENTER = new URLSearchParams(location.search).get('present') === '1';
  const API = p => '/api/' + encodeURIComponent(NBID) + '/recording' + p;
  const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('slate-deck-' + NBID) : null;
  const CHUNK_MS = 4000;

  const R = {
    on: false, starting: false, rid: null, file: '', rec: null, tracks: [], ctx: null,
    t0: 0, marks: [], queue: Promise.resolve(), lost: 0, tick: null, level: 0, analyser: null,
    cam: null, camStream: null,
  };

  function _note(msg, kind) { if (window.toast) toast(msg, 6000, kind || ''); else console.log(msg); }

  // Overlays must sit inside the fullscreen element or they are not painted at all.
  function _host() {
    const deck = document.getElementById('deck');
    if (document.fullscreenElement) return document.fullscreenElement;
    if (deck && deck.style.display !== 'none') return deck;
    return document.body;
  }

  function _injectStyle() {
    if (document.getElementById('deck-record-style')) return;
    const st = document.createElement('style');
    st.id = 'deck-record-style';
    st.textContent = `
      .deck-rec-pill { position: fixed; top: 10px; left: 12px; z-index: 10050; display: flex; align-items: center;
        gap: 6px; padding: 3px 8px; border-radius: 999px; font: 600 11px/1.4 var(--ui-font, system-ui);
        background: rgba(0,0,0,.35); color: #fff; opacity: .55; pointer-events: none; }
      .deck-rec-pill .dot { width: 8px; height: 8px; border-radius: 50%; background: #e5484d;
        animation: deck-rec-pulse 1.6s ease-in-out infinite; }
      .deck-rec-pill .lvl { width: 28px; height: 4px; border-radius: 2px; background: rgba(255,255,255,.2); overflow: hidden; }
      .deck-rec-pill .lvl > i { display: block; height: 100%; width: 0; background: #46a758; }
      @keyframes deck-rec-pulse { 50% { opacity: .35; } }
      .deck-rec-count { position: fixed; inset: 0; z-index: 10060; display: grid; place-items: center;
        background: rgba(0,0,0,.45); color: #fff; font: 700 22vh/1 var(--ui-font, system-ui); }
      .deck-cam { position: fixed; right: 28px; bottom: 28px; z-index: 10040; width: 200px; height: 200px;
        border-radius: 50%; object-fit: cover; transform: scaleX(-1); cursor: grab; touch-action: none;
        box-shadow: 0 6px 24px rgba(0,0,0,.45); border: 3px solid rgba(255,255,255,.85); }
      .deck-cam.big { width: 320px; height: 320px; }
      .deck-cam.dragging { cursor: grabbing; }
      body.is-presenter .deck-rec-pill { opacity: 1; pointer-events: auto; top: auto; bottom: 12px; left: 12px;
        background: #2a1215; border: 1px solid #e5484d; font-size: 13px; padding: 6px 10px; }
      body.is-presenter .deck-rec-pill button { margin-left: 6px; font: inherit; color: #fff; background: #e5484d;
        border: 0; border-radius: 6px; padding: 2px 8px; cursor: pointer; }`;
    document.head.appendChild(st);
  }

  // ── Recorder ────────────────────────────────────────────────────────────────
  function _pickMime() {
    const MR = window.MediaRecorder;
    for (const m of ['video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp9,opus',
                     'video/webm;codecs=vp8,opus', 'video/webm']) {
      if (MR && MR.isTypeSupported(m)) return m;
    }
    return '';
  }

  async function _countdown(n) {
    const el = document.createElement('div');
    el.className = 'deck-rec-count';
    _host().appendChild(el);
    for (let i = n; i > 0; i--) { el.textContent = i; await new Promise(r => setTimeout(r, 800)); }
    el.remove();
    // Two frames so the overlay is gone from the composited tab before the first captured frame.
    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  }

  function _mixAudio(display, mic) {
    const ctx = new AudioContext();
    const dest = ctx.createMediaStreamDestination();
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 512;
    for (const s of [display, mic]) {
      if (s && s.getAudioTracks().length) ctx.createMediaStreamSource(s).connect(dest);
    }
    if (mic && mic.getAudioTracks().length) ctx.createMediaStreamSource(mic).connect(analyser);
    R.ctx = ctx; R.analyser = analyser;
    return dest.stream.getAudioTracks();
  }

  // One POST per chunk, chained so they arrive in order. A failed chunk is retried a few times;
  // giving up on it would leave a hole in the file, so that is reported rather than hidden.
  function _upload(blob) {
    R.queue = R.queue.then(async () => {
      const rid = R.rid;
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          const r = await fetch(API('/' + rid + '/chunk'), { method: 'POST', body: blob,
                                                            headers: { 'Content-Type': 'application/octet-stream' } });
          if (r.ok) return;
          if (r.status === 404) break;           // the hub no longer knows this recording
        } catch (e) {}
        await new Promise(r => setTimeout(r, 500 * (attempt + 1)));
      }
      R.lost++;
      _note('Recording: a chunk could not be saved — the video will have a gap.', 'err');
    });
  }

  async function start() {
    if (R.on || R.starting) return;
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia || !window.MediaRecorder) {
      _note('This browser cannot record a tab.', 'err'); return;
    }
    R.starting = true;
    let display = null, mic = null;
    try {
      // Display capture first: it needs the click's user activation, which an earlier await could spend.
      display = await navigator.mediaDevices.getDisplayMedia({
        video: { displaySurface: 'browser', frameRate: 30 },
        audio: { suppressLocalAudioPlayback: false },
        preferCurrentTab: true, selfBrowserSurface: 'include', surfaceSwitching: 'exclude',
      });
    } catch (e) {
      R.starting = false;
      if (e && e.name !== 'NotAllowedError') _note('Recording could not start: ' + e.message, 'err');
      return;
    }
    try {
      mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    } catch (e) {
      _note('No microphone — recording without narration.');
    }
    const mime = _pickMime();
    let info;
    try {
      const r = await fetch(API('/start'), { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                            body: JSON.stringify({ mime }) });
      if (!r.ok) throw new Error('hub refused (' + r.status + ')');
      info = await r.json();
    } catch (e) {
      for (const s of [display, mic]) if (s) s.getTracks().forEach(t => t.stop());
      R.starting = false;
      _note('Recording could not start: ' + e.message, 'err'); return;
    }

    const tracks = [...display.getVideoTracks(), ..._mixAudio(display, mic)];
    const rec = new MediaRecorder(new MediaStream(tracks), Object.assign(
      { videoBitsPerSecond: 8e6, audioBitsPerSecond: 160e3 }, mime ? { mimeType: mime } : {}));
    rec.ondataavailable = ev => { if (ev.data && ev.data.size) _upload(ev.data); };
    rec.onstop = _finish;
    // The browser's own "Stop sharing" button ends the video track; treat it as stop.
    display.getVideoTracks()[0].addEventListener('ended', () => stop());

    Object.assign(R, { rid: info.id, file: info.file, rec, tracks: [display, mic].filter(Boolean),
                       marks: [], lost: 0, queue: Promise.resolve() });
    await _countdown(3);
    if (display.getVideoTracks()[0].readyState === 'ended') {   // sharing was stopped during the countdown
      for (const s of R.tracks) s.getTracks().forEach(t => t.stop());
      if (R.ctx) try { R.ctx.close(); } catch (e) {}
      R.starting = false;
      fetch(API('/' + R.rid + '/finish'), { method: 'POST', body: '{}' }).catch(() => {});
      return;
    }
    R.t0 = performance.now();
    R.on = true; R.starting = false;
    const pos = window._deckPos ? window._deckPos() : null;
    if (pos) _mark(Object.assign({ type: 'slide' }, pos));
    rec.start(CHUNK_MS);
    document.body.classList.add('deck-recording');
    _showPill();
    _announce();
  }

  function stop() {
    if (!R.on) return;
    R.on = false;
    try { if (R.rec.state !== 'inactive') R.rec.stop(); } catch (e) { _finish(); }
  }

  async function _finish() {
    const dur = performance.now() - R.t0;
    for (const s of R.tracks) s.getTracks().forEach(t => t.stop());
    if (R.ctx) try { R.ctx.close(); } catch (e) {}
    R.tracks = []; R.ctx = null; R.analyser = null;
    clearInterval(R.tick); R.tick = null;
    document.body.classList.remove('deck-recording');
    const pill = document.getElementById('deckrec'); if (pill) pill.remove();
    _announce();
    await R.queue;                                    // every chunk is on disk before we close the file
    try {
      const r = await fetch(API('/' + R.rid + '/finish'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chapters_vtt: _vtt(dur), timings: { duration_ms: Math.round(dur), marks: R.marks } }),
      });
      const out = r.ok ? await r.json() : null;
      if (!out) throw new Error('hub refused (' + r.status + ')');
      _note('Recording saved: ' + (out.converting ? out.converting + ' (converting…)' : R.file) +
            (R.lost ? ' — ' + R.lost + ' chunk(s) missing' : ''), R.lost ? 'err' : '');
    } catch (e) {
      _note('Recording finished but its chapters were not saved: ' + e.message, 'err');
    }
    R.rid = null;
  }

  // ── Chapters ────────────────────────────────────────────────────────────────
  function _mark(d) {
    if (!R.on) return;
    R.marks.push({ t_ms: Math.round(performance.now() - R.t0), type: d.type, idx: d.idx, step: d.step,
                   title: d.title || null });
  }
  window.addEventListener('slate-deck', ev => _mark(ev.detail || {}));

  function _ts(ms) {
    ms = Math.max(0, Math.round(ms));
    const p = (n, w) => String(n).padStart(w, '0');
    return p(Math.floor(ms / 3600000), 2) + ':' + p(Math.floor(ms / 60000) % 60, 2) + ':' +
           p(Math.floor(ms / 1000) % 60, 2) + '.' + p(ms % 1000, 3);
  }
  // One cue per slide visit; builds within a slide stay in the JSON timings, not the chapter list.
  function _vtt(dur) {
    const visits = [];
    for (const m of R.marks) {
      if (m.type !== 'slide' && m.type !== 'enter') continue;
      if (visits.length && visits[visits.length - 1].idx === m.idx) continue;
      visits.push(m);
    }
    let s = 'WEBVTT\n\n';
    visits.forEach((m, i) => {
      const end = i + 1 < visits.length ? visits[i + 1].t_ms : dur;
      if (end <= m.t_ms) return;
      const label = (m.idx != null ? (m.idx + 1) + '. ' : '') + (m.title || 'Slide');
      s += (i + 1) + '\n' + _ts(m.t_ms) + ' --> ' + _ts(end) + '\n' + label.replace(/\n/g, ' ') + '\n\n';
    });
    return s;
  }

  // ── Indicator (in-tab: subtle; presenter window: full, with stop) ───────────
  function _fmt(ms) { const s = Math.floor(ms / 1000); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
  function _showPill() {
    _injectStyle();
    let pill = document.getElementById('deckrec');
    if (!pill) {
      pill = document.createElement('div'); pill.id = 'deckrec'; pill.className = 'deck-rec-pill';
      pill.innerHTML = '<span class="dot"></span><span class="t">0:00</span><span class="lvl"><i></i></span>';
    }
    _host().appendChild(pill);
    const buf = new Uint8Array(256);
    R.tick = setInterval(() => {
      const t = pill.querySelector('.t'); if (t) t.textContent = _fmt(performance.now() - R.t0);
      if (R.analyser) {
        R.analyser.getByteTimeDomainData(buf);
        let peak = 0; for (const v of buf) peak = Math.max(peak, Math.abs(v - 128));
        R.level = Math.min(1, peak / 64);
        const bar = pill.querySelector('.lvl > i'); if (bar) bar.style.width = Math.round(R.level * 100) + '%';
      }
      _announce();
    }, 250);
  }

  function _announce() {
    if (!bc || IS_PRESENTER) return;
    bc.postMessage({ type: 'rec', on: R.on, elapsed: R.on ? performance.now() - R.t0 : 0, level: R.level });
  }

  // Presenter side: mirror the deck's recording state; Stop asks the deck tab to stop.
  function _presenterPill(m) {
    _injectStyle();
    let pill = document.getElementById('deckrec');
    if (!m.on) { if (pill) pill.remove(); return; }
    if (!pill) {
      pill = document.createElement('div'); pill.id = 'deckrec'; pill.className = 'deck-rec-pill';
      pill.innerHTML = '<span class="dot"></span><span>REC</span><span class="t"></span><span class="lvl"><i></i></span>' +
                       '<button title="stop recording">■ Stop</button>';
      pill.querySelector('button').onclick = () => bc && bc.postMessage({ type: 'rec-stop' });
      document.body.appendChild(pill);
    }
    pill.querySelector('.t').textContent = _fmt(m.elapsed || 0);
    pill.querySelector('.lvl > i').style.width = Math.round((m.level || 0) * 100) + '%';
  }

  if (bc) bc.addEventListener('message', ev => {
    const m = ev.data || {};
    if (IS_PRESENTER) { if (m.type === 'rec') _presenterPill(m); return; }
    if (m.type === 'rec-stop') stop();
    else if (m.type === 'hello') _announce();
  });

  // ── Webcam bubble ───────────────────────────────────────────────────────────
  // Re-parent the bubble and the indicator when the deck opens, closes, or goes fullscreen.
  function _placeCam() {
    const h = _host();
    if (R.cam && R.cam.parentNode !== h) h.appendChild(R.cam);
    const pill = !IS_PRESENTER && document.getElementById('deckrec');
    if (pill && pill.parentNode !== h) h.appendChild(pill);
  }
  function _dragCam(v) {
    let sx = 0, sy = 0, ox = 0, oy = 0;
    v.addEventListener('pointerdown', e => {
      const r = v.getBoundingClientRect();
      sx = e.clientX; sy = e.clientY; ox = r.left; oy = r.top;
      v.setPointerCapture(e.pointerId); v.classList.add('dragging');
    });
    v.addEventListener('pointermove', e => {
      if (!v.classList.contains('dragging')) return;
      v.style.left = (ox + e.clientX - sx) + 'px'; v.style.top = (oy + e.clientY - sy) + 'px';
      v.style.right = 'auto'; v.style.bottom = 'auto';
    });
    v.addEventListener('pointerup', e => { v.classList.remove('dragging'); v.releasePointerCapture(e.pointerId); });
    v.addEventListener('dblclick', () => v.classList.toggle('big'));
  }
  async function cameraToggle() {
    if (R.cam) {
      R.camStream.getTracks().forEach(t => t.stop());
      R.cam.remove(); R.cam = null; R.camStream = null; return;
    }
    try {
      R.camStream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 640, facingMode: 'user' } });
    } catch (e) { _note('Camera unavailable: ' + e.message, 'err'); return; }
    _injectStyle();
    const v = document.createElement('video');
    v.className = 'deck-cam'; v.autoplay = true; v.muted = true; v.playsInline = true;
    v.srcObject = R.camStream;
    _dragCam(v);
    R.cam = v;
    _placeCam();
  }
  document.addEventListener('fullscreenchange', _placeCam);
  window.addEventListener('slate-deck', ev => {
    const t = ev.detail && ev.detail.type;
    if (t === 'enter' || t === 'exit') requestAnimationFrame(_placeCam);
  });

  window.addEventListener('beforeunload', e => { if (R.on) { e.preventDefault(); e.returnValue = ''; } });

  window.deckRecordToggle = () => (R.on ? stop() : start());
  window.deckCameraToggle = cameraToggle;
  window.deckRecording = () => R.on;
})();
