// "Preparing environment" banner — the structured counterpart to the raw `bringup:` line stream.
//
// A cold notebook open (deps not precompiled — Makie is the canonical case) used to read as a frozen
// "Running 0/N": the precompile happened invisibly under the first cell's output capture. The worker
// (local) and the provisioner (remote) now stream a structured status on `prepare:` — phase, k/N, the
// current package, elapsed — which this module renders INSIDE the hydrating banner (built by view.js
// updateChrome), with the raw Pkg output tucked into a collapsible "build log". Banner-only by design:
// the running cell keeps its normal spinner; this narrates the one-time cost up top so it never looks hung.
//
// Driven by two SSE events (wired in panels.js): `prepare:<json>` → onPrepare (structured), and the
// existing `bringup:<line>` → _prepPushRaw (raw detail). Re-rendered whenever the banner is rebuilt
// (view.js calls window.renderPrepare) and patched live between rebuilds.
(function () {
  let prep = null;           // latest parsed status {phase,k,n,pkg,installed,recent,secs,err,note}
  const raw = [];            // raw Pkg output lines (the collapsible build log), bounded
  const RAW_MAX = 300;

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

  // A structured status frame arrived.
  window.onPrepare = function (json) {
    try { prep = JSON.parse(json); } catch (_) { return; }
    renderPrepare();
  };

  // A raw bring-up line arrived (worker boot output / remote provision stream) → the build log.
  window._prepPushRaw = function (line) {
    const s = String(line || '').trim();
    if (!s) return;
    if (s.startsWith('@@SLATE_PREP')) return;   // control markers drive the structured banner — never show them raw
    raw.push(s);
    if (raw.length > RAW_MAX) raw.splice(0, raw.length - RAW_MAX);
    renderRaw();
  };

  // Hydration ended (or errored) → drop everything so a later open starts clean.
  window.clearPrepare = function () {
    prep = null; raw.length = 0;
  };

  function renderRaw() {
    const pre = document.getElementById('hydrawpre'), det = document.getElementById('hydraw');
    if (!pre || !det) return;
    if (!raw.length) { det.style.display = 'none'; return; }
    det.style.display = '';
    // Surface the latest raw line right on the collapsed summary — live activity at a glance without
    // expanding (dim, truncated). Hidden while open, where the full log below already shows it.
    const last = document.getElementById('hydrawlast');
    if (last) last.textContent = det.open ? '' : raw[raw.length - 1];
    // Keep the last ~120 lines in view — the build log is a debugging aid, not the headline.
    pre.textContent = raw.slice(-120).join('\n');
    if (det.open) pre.scrollTop = pre.scrollHeight;
  }

  // Fill #hydprep (the structured progress line) from `prep`. Called by view.js after it (re)builds the
  // banner, and by onPrepare between rebuilds. No-ops cleanly if the banner isn't up.
  function renderPrepare() {
    renderRaw();
    const box = document.getElementById('hydprep');
    if (!box) return;
    const active = prep && (prep.stage || (prep.phase && prep.phase !== ''));
    // The structured line IS the headline once we have status — hide the generic message so the banner
    // stays compact (one status line + the collapsed build log) instead of stacking a redundant sentence.
    const gm = document.getElementById('hydmsg');
    if (gm) gm.style.display = active ? 'none' : '';
    if (!active) { box.innerHTML = ''; return; }
    const secs = prep.secs > 0 ? ` · ${prep.secs}s` : '';
    let html = '';
    // ONE status line (mutually exclusive), kept compact. A progress BAR appears ONLY when there's a real
    // k/N to fill (precompile with a known total) — the banner spinner already signals "working", so an
    // indeterminate pulsing bar on the uncertain phases (resolve/install, boot stages) is just noise.
    if (prep.phase === 'precompile') {
      const n = prep.n | 0, k = prep.k | 0;
      const determinate = n > 0;
      const bar = determinate
        ? `<span class="hydbar"><span style="width:${Math.min(100, Math.round((k / n) * 100))}%"></span></span>`
        : '';
      const count = determinate ? `<b>${k}</b>/<b>${n}</b>` : `<b>${k}</b> done`;
      const pkg = prep.pkg ? ` · <span class="hydpkg">${esc(prep.pkg)}</span>` : '';
      html = `<div class="hydprepline">${bar}<span class="hydpreplabel">Precompiling ${count}${pkg}${secs}</span></div>`
        + `<div class="hydprepnote">One-time precompile — future opens are fast. You can keep editing.</div>`;
    } else if (prep.stage) {
      html = `<div class="hydprepline"><span class="hydpreplabel">${esc(prep.stage)}${secs}</span></div>`;
    } else if (prep.phase === 'resolve' || prep.phase === 'install') {
      const inst = prep.installed > 0 ? ` · ${prep.installed} installed` : '';
      html = `<div class="hydprepline"><span class="hydpreplabel">Resolving &amp; installing packages…${inst}${secs}</span></div>`;
    } else if (prep.phase === 'done') {
      html = `<div class="hydprepline done"><span class="hydprepmark">✓</span><span class="hydpreplabel">${esc(prep.note || 'Packages ready')}</span></div>`;
    } else if (prep.phase === 'error' || prep.err) {
      html = `<div class="hydprepline err"><span class="hydprepmark">⚠</span><span class="hydpreplabel">${esc(prep.note || 'Precompilation failed — see the build log')}</span></div>`;
    }
    box.innerHTML = html;
  }
  window.renderPrepare = renderPrepare;
  window._prepRawToggle = renderRaw;   // <details> open/close → refresh the inline last-line summary
})();
