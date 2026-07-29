// ── Slate UI theme ──────────────────────────────────────────────────────────────
// Registry for the Settings → Theme dropdown. Each name (except "midnight", the bare default)
// has a matching `html[data-slate-theme="<name>"]` palette block in notebook.css. `dark` is
// advisory metadata. Keep this list in sync with those CSS blocks.
const SLATE_UI_THEMES = [
  { name: 'midnight', label: 'Midnight (default)', dark: true },
  { name: 'graphite', label: 'Graphite', dark: true },
  { name: 'nord', label: 'Nord', dark: true },
  { name: 'dracula', label: 'Dracula', dark: true },
  { name: 'solarized-dark', label: 'Solarized Dark', dark: true },
  { name: 'daylight', label: 'Daylight', dark: false },
  { name: 'solarized-light', label: 'Solarized Light', dark: false },
];
const _SLATE_THEME_NAMES = new Set(SLATE_UI_THEMES.map(t => t.name));
function curSlateTheme() {
  const n = localStorage.getItem('slateTheme');
  return (n && _SLATE_THEME_NAMES.has(n)) ? n : 'midnight';
}
function setSlateTheme(name) {
  if (!_SLATE_THEME_NAMES.has(name)) return;
  localStorage.setItem('slateTheme', name);
  if (name === 'midnight') delete document.documentElement.dataset.slateTheme;
  else document.documentElement.dataset.slateTheme = name;
  // Charts read their palette from the CSS vars this just swapped — restyle them to match.
  try { window._onSlateThemeChange && window._onSlateThemeChange(); } catch (_) {}
}

// ── Figure display width ────────────────────────────────────────────────────────
// Max display width (px) for rendered figures/images, exposed as a CSS var (`--fig-max`) on
// <body>. Full-page-width mode drops the page's max-width so tables/charts/code can breathe —
// but a raster plot then scales to the WHOLE window and turns huge/tall. This caps it. Default
// 980 = the normal reading column (a no-op outside full-width); floored so it can't go tiny.
const _FIG_MAX_DEFAULT = 980, _FIG_MAX_MIN = 480;
function _figMax() { const n = parseInt(localStorage.getItem('slateFigMax'), 10); return (n && n >= _FIG_MAX_MIN) ? n : _FIG_MAX_DEFAULT; }
function setFigMax(px) {
  const v = Math.max(_FIG_MAX_MIN, parseInt(px, 10) || _FIG_MAX_DEFAULT);
  localStorage.setItem('slateFigMax', v);
  document.body.style.setProperty('--fig-max', v + 'px');
}
function applyFigMax() { document.body.style.setProperty('--fig-max', _figMax() + 'px'); }
applyFigMax();   // apply the saved cap at load (before the first figure renders)

// ── Notebook column (page/cell) width ──────────────────────────────────────────
// Width of the notebook column — cells and text — as a CSS var (`--page-max`) on the `.page`
// container. The "Full page width" toggle still overrides to the whole window (body.fullwidth);
// this sets the constrained column width otherwise. Default 980 = the historical column.
const _PAGE_MAX_DEFAULT = 980, _PAGE_MAX_MIN = 720;
function _pageMax() { const n = parseInt(localStorage.getItem('slatePageMax'), 10); return (n && n >= _PAGE_MAX_MIN) ? n : _PAGE_MAX_DEFAULT; }
function setPageMax(px) {
  const v = Math.max(_PAGE_MAX_MIN, parseInt(px, 10) || _PAGE_MAX_DEFAULT);
  localStorage.setItem('slatePageMax', v);
  document.body.style.setProperty('--page-max', v + 'px');
}
function applyPageMax() { document.body.style.setProperty('--page-max', _pageMax() + 'px'); }
applyPageMax();   // apply the saved column width at load

// ── Chart scroll-zoom gate ──────────────────────────────────────────────────────
// An interactive chart zooms on the mouse/trackpad wheel, which hijacks page scrolling — scroll down,
// your pointer crosses a chart, and suddenly you're zooming instead of scrolling. Worse than the hijack
// is the FIGHT: nothing stops the page scrolling while the chart zooms, so the plot slides under a
// cursor the zoom is anchored to, and one continuous trackpad flick reads as the view jittering in and
// out rather than as a zoom at all. So we only let the wheel reach a chart when it's ACTIVE (has focus —
// click into it; its border lights up), and we scale the wheel delta by the "Chart scroll-zoom" setting
// (0 = never zoom on scroll → the wheel always scrolls the page). ONE delegated capturing listener
// covers every chart, present or future — including one drawn by a package that knows nothing about
// this file.
const _ZOOM_DEFAULT = 28;   // percent — a gentle default tuned for the Mac trackpad
function scrollZoomFactor() { const n = parseInt(localStorage.getItem('slateScrollZoom'), 10); return (Number.isFinite(n) && n >= 0 ? n : _ZOOM_DEFAULT) / 100; }
window.scrollZoomFactor = scrollZoomFactor;

// What counts as a chart. Core's own ECharts hosts are named here because core creates them; everything
// else opts in by carrying `data-slate-zoomable`, which is the entire contract an extension has to meet
// — no registration call, so no load-order race and nothing to re-run in a static export.
const _ZOOMABLE = '.echart, .ichart, [data-slate-zoomable]';

// Where the wheel must actually LAND. A charting library listens on its own inner surface, not on the
// container we matched: ECharts on the canvas zrender owns, Plotly on the `.nsewdrag` rect covering the
// axes. A container names its surface in the attribute's value; failing that the first canvas/svg, and
// failing that the container itself, which is right for anything listening at its own root.
function zoomTarget(card, e) {
  const sel = card.getAttribute && card.getAttribute('data-slate-zoomable');
  if (sel) {
    // The surface UNDER THE CURSOR beats the first one in the container: a figure with subplots has one
    // drag surface per panel, and zooming whichever happens to come first in the DOM is not what the
    // reader pointed at. Falling back to the first still covers a wheel over a title or legend.
    const under = e.target && e.target.closest ? e.target.closest(sel) : null;
    if (under && card.contains(under)) return under;
    const first = card.querySelector(sel);
    if (first) return first;
  }
  return card.querySelector('canvas, svg') || card;
}

// A chart must be able to HOLD focus for `:focus-within` to mean anything, and clicking one has to give
// it that focus. Neither is safe to leave to the container: Plotly's drag layer calls preventDefault on
// mousedown, which suppresses the browser's own click-to-focus, and a bare <div> host isn't focusable to
// begin with. Doing it here means opting into the gate stays a one-attribute job.
document.addEventListener('pointerdown', function (e) {
  const card = e.target && e.target.closest ? e.target.closest(_ZOOMABLE) : null;
  if (!card || card.contains(document.activeElement)) return;
  if (!card.hasAttribute('tabindex')) card.tabIndex = -1;
  card.focus({ preventScroll: true });        // activating a chart must never scroll the page to it
}, true);

// A trackpad emits wheel events far faster than any of these libraries can redraw — a single flick is a
// long burst, and forwarding it one-for-one asks for a full relayout per event. So deltas ACCUMULATE and
// are dispatched once per animation frame. Zoom is multiplicative in the delta, so one event carrying the
// frame's summed delta lands in the same place the burst would have; what's dropped is only the redraws
// nobody could see. `deltaMode` and the target are part of the pending batch's identity — a burst that
// switches either is flushed first rather than summed across incompatible units or surfaces.
let _wheelPending = null, _wheelRaf = 0;
function _flushWheel() {
  _wheelRaf = 0;
  const p = _wheelPending;
  if (!p) return;
  _wheelPending = null;
  const ev = new WheelEvent('wheel', { deltaX: p.dx, deltaY: p.dy, deltaMode: p.mode,
                                       clientX: p.x, clientY: p.y,
                                       // Carried through because libraries read them: a trackpad pinch
                                       // arrives as a ctrl-wheel, and shift-wheel pans rather than zooms.
                                       ctrlKey: p.ctrl, shiftKey: p.shift,
                                       altKey: p.alt, metaKey: p.meta,
                                       bubbles: true, cancelable: true });
  ev.__slateZoom = true;
  p.target.dispatchEvent(ev);
}

document.addEventListener('wheel', function (e) {
  if (e.__slateZoom) return;                                             // our own re-dispatched (scaled) event
  const card = e.target && e.target.closest ? e.target.closest(_ZOOMABLE) : null;
  if (!card) return;                                                     // not over a chart — leave it alone
  const f = scrollZoomFactor();
  if (f <= 0 || !card.matches(':focus-within')) { e.stopPropagation(); return; }  // off / inactive → page scrolls
  // preventDefault is what stops the page scrolling UNDERNEATH the zoom — without it the two move
  // together and the anchor point drifts every event, which is the jitter this gate exists to kill.
  e.stopPropagation(); e.preventDefault();
  const target = zoomTarget(card, e);
  if (_wheelPending && (_wheelPending.target !== target || _wheelPending.mode !== e.deltaMode)) _flushWheel();
  // The cursor and modifiers take the LATEST value: the zoom anchors where the pointer is now, not where
  // the burst started.
  _wheelPending = { target: target, mode: e.deltaMode,
                    dx: (_wheelPending ? _wheelPending.dx : 0) + e.deltaX * f,
                    dy: (_wheelPending ? _wheelPending.dy : 0) + e.deltaY * f,
                    x: e.clientX, y: e.clientY,
                    ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey };
  if (!_wheelRaf) _wheelRaf = requestAnimationFrame(_flushWheel);
}, { capture: true, passive: false });

// ── Settings modal ────────────────────────────────────────────────────────────
function openSettings() {
  const deb = document.getElementById('setdeb'), v = document.getElementById('setdebv');
  deb.value = updateMs; v.textContent = updateMs;
  deb.oninput = () => { updateMs = parseInt(deb.value, 10) || 0; v.textContent = updateMs; localStorage.setItem('slateUpdateMs', updateMs); };
  // Autocomplete: typing delay before the popup auto-opens (applies to newly opened editors), and what
  // Tab does when the popup is open (applies live). Defaults: 250ms, Accept (the standard convention).
  const cd = document.getElementById('setcompdelay'), cdv = document.getElementById('setcompdelayv');
  if (cd) {
    const _cur = () => { const n = parseInt(localStorage.getItem('slateCompleteDelay'), 10); return Number.isFinite(n) ? n : 250; };
    cd.value = _cur(); cdv.textContent = _cur();
    // Live across every open editor via setCompleteDelay (reconfigures the autocompletion compartment).
    cd.oninput = () => { cdv.textContent = cd.value; window.setCompleteDelay ? window.setCompleteDelay(cd.value) : localStorage.setItem('slateCompleteDelay', cd.value); };
  }
  const ct = document.getElementById('setcomptab');
  if (ct) {
    ct.value = localStorage.getItem('slateCompleteTab') || 'accept';
    ct.onchange = () => localStorage.setItem('slateCompleteTab', ct.value);
  }
  const wide = document.getElementById('setwide');
  // Notebook column width (live via --page-max); disabled while Full page width overrides it.
  const page = document.getElementById('setpage'), pagev = document.getElementById('setpagev');
  const _syncPage = () => { if (page) page.disabled = wide.checked; };
  wide.checked = document.body.classList.contains('fullwidth');
  wide.onchange = () => { document.body.classList.toggle('fullwidth', wide.checked); localStorage.setItem('slateFullWidth', wide.checked ? '1' : '0'); _syncPage(); };
  if (page) {
    page.value = _pageMax(); pagev.textContent = _pageMax(); _syncPage();
    page.oninput = () => { pagev.textContent = page.value; setPageMax(page.value); };
  }
  // Figure display-width cap (live via the --fig-max CSS var; most visible in full-page-width mode).
  const fig = document.getElementById('setfig'), figv = document.getElementById('setfigv');
  if (fig) {
    fig.value = _figMax(); figv.textContent = _figMax();
    fig.oninput = () => { figv.textContent = fig.value; setFigMax(fig.value); };
  }
  // Chart scroll-zoom sensitivity (0 = off). Read live by the scroll-zoom gate above — no re-render needed.
  const zm = document.getElementById('setzoom'), zmv = document.getElementById('setzoomv');
  if (zm) {
    const _z = () => { const n = parseInt(localStorage.getItem('slateScrollZoom'), 10); return Number.isFinite(n) ? n : _ZOOM_DEFAULT; };
    zm.value = _z(); zmv.textContent = _z();
    zm.oninput = () => { zmv.textContent = zm.value; localStorage.setItem('slateScrollZoom', zm.value); };
  }
  // Wrap wide text output (default off → matrices/wide tables scroll horizontally instead of wrapping).
  const wrap = document.getElementById('setwrap');
  if (wrap) {
    wrap.checked = document.body.classList.contains('wrap-output');
    wrap.onchange = () => { document.body.classList.toggle('wrap-output', wrap.checked); localStorage.setItem('slateWrapOutput', wrap.checked ? '1' : '0'); };
  }
  // Soft-wrap long lines in the CODE editor (markdown editors always wrap). Live across all editors.
  const wraped = document.getElementById('setwraped');
  if (wraped) {
    wraped.checked = localStorage.getItem('slateWrapEditor') === '1';
    wraped.onchange = () => { window.setEditorWrap && window.setEditorWrap(wraped.checked); };
  }
  // Per-notebook settings (hot-reload, parallel, threads, slides, bibstyle, agent-model override)
  // now live in the "🎚 Notebook config" panel (config.js) — a single view with effective value +
  // source badge + clear-override, instead of being scattered here.
  // Overall Slate UI theme — applied by toggling html[data-slate-theme] (palette in notebook.css),
  // persisted as `slateTheme`, and re-applied at load by the inline head script (no flash).
  const th = document.getElementById('settheme');
  th.innerHTML = SLATE_UI_THEMES.map(t => `<option value="${t.name}">${t.label}</option>`).join('');
  th.value = curSlateTheme();
  th.onchange = () => setSlateTheme(th.value);
  // Editor syntax theme — options come from the cm6 theme registry (window._syntaxThemes), so adding
  // a theme in entry.js surfaces here automatically. Live-applied across all editors (tokens + chrome)
  // via window.setSyntaxTheme (editor.js).
  const syn = document.getElementById('setsyntax');
  if (syn) {
    const themes = window._syntaxThemes || [{ name: 'dark-plus', label: 'Dark+ (default)' }];
    syn.innerHTML = themes.map(t => `<option value="${t.name}">${t.label}</option>`).join('');
    syn.value = localStorage.getItem('slateSyntaxTheme') || 'dark-plus';
    syn.onchange = () => { window.setSyntaxTheme && window.setSyntaxTheme(syn.value); };
  }
  const mdl = document.getElementById('setmodel'), mhint = document.getElementById('setmodelhint');
  // Model and permission both bind only at spawn — changing either reaps the running
  // agent (chat-kill keeps the transcript) so the next turn respawns on the new setting.
  const reapAgent = async () => { mhint.style.display = ''; try { await api('POST', '/api/chat-kill', {}); } catch (_) {} setWorking(false); };
  // Confirm if a turn is in flight (the reap interrupts it), persist, reap, and drop a
  // visible note in the chat. Reverts the <select> if the user backs out mid-turn.
  const _selText = sel => sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : sel.value;
  // Persist a setting `value` (labelled for the chat note), confirming/aborting if a turn is
  // in flight, then reap so the next message respawns on it. `revert` restores the prior UI.
  const commitSetting = async (key, value, label, verb, noun, revert) => {
    if (agentWorking && !await confirmDark('A turn is in progress — ' + verb + ' and stop it?', 'Switch & stop', 'danger')) {
      revert && revert();
      return;
    }
    localStorage.setItem(key, value);
    await reapAgent();
    _agentNote('⚙ ' + noun + ' → ' + label + ' · applies to your next message');
  };
  const switchSetting = (sel, key, verb, noun) =>
    commitSetting(key, sel.value, _selText(sel), verb, noun, () => { sel.value = localStorage.getItem(key) || ''; });
  // ── Agent model, with a free-text "Custom…" escape hatch ──────────────────────
  // The stored model is the exact string sent per turn (server → `claude --model`). A preset
  // (opus/haiku/local) is picked from the dropdown; anything else (an exact id/version like
  // `claude-opus-4-8`) is a custom value: the dropdown shows "Custom…" and the text input holds it.
  const crow = document.getElementById('setmodelcustomrow');
  const cinp = document.getElementById('setmodelcustom');
  const _isPreset = v => [...mdl.options].some(o => o.value === v && o.value !== '__custom__');
  const reflectModel = () => {                 // point the UI at the saved model (preset vs custom)
    const saved = agentModel();
    if (saved && !_isPreset(saved)) { mdl.value = '__custom__'; cinp.value = saved; crow.style.display = ''; }
    else { mdl.value = saved; crow.style.display = 'none'; }
  };
  const commitCustom = () => {
    const v = cinp.value.trim();
    if (!v || v === agentModel()) return;      // empty or unchanged → nothing to do
    commitSetting('slateAgentModel', v, 'custom · ' + v, 'switch the model', 'model', reflectModel);
  };
  reflectModel();
  mdl.onchange = () => {
    if (mdl.value === '__custom__') { crow.style.display = ''; cinp.focus(); return; }  // commit on input blur/⏎
    crow.style.display = 'none';
    switchSetting(mdl, 'slateAgentModel', 'switch the model', 'model');
  };
  cinp.onchange = commitCustom;                // fires on Enter / blur
  cinp.onkeydown = e => { if (e.key === 'Enter') cinp.blur(); };
  // Append locally-served models (Ollama, and vmlx — the MLX server for Apple Silicon).
  // Both need their server running + Kaimon's OllamaBackend, and are routed by prefix.
  // Rebuilt each open so the list stays fresh and never duplicates.
  const addLocalModels = (route, prefix, label) => {
    [...mdl.querySelectorAll('option[value^="' + prefix + ':"]')].forEach(o => o.remove());
    return api('GET', route).then(r => {
      (r && r.models || []).forEach(name => {
        const o = document.createElement('option');
        o.value = prefix + ':' + name; o.textContent = label + ' · ' + name + ' (local)'; mdl.appendChild(o);
      });
      reflectModel();   // re-apply: the saved choice may be one of these local models (else custom)
    }).catch(() => {});
  };
  addLocalModels('/api/ollama-models', 'ollama', 'Ollama');
  addLocalModels('/api/vmlx-models', 'vmlx', 'vmlx');
  const perm = document.getElementById('setperm');
  perm.value = agentPerm();
  perm.onchange = () => switchSetting(perm, 'slateAgentPerm', 'change permissions', 'permissions');
  // Global execution settings (default run location, transfer chunk size, carry budget) live on
  // the front page's Remotes dialog (index.html) — not in per-notebook settings. The notebook's
  // OWN run location is the toolbar "Running on" picker (runloc.js).
  document.getElementById('setbg').classList.add('show');
}
// Your GLOBAL agent-model default ('' = server default = sonnet).
function agentModel() { return localStorage.getItem('slateAgentModel') || ''; }
// Your GLOBAL permission preset ('' = lab default).
function agentPerm() { return localStorage.getItem('slateAgentPerm') || ''; }
// Per-notebook agent-permission memory. Kept LOCAL (localStorage keyed by notebook id) and never
// written to the .jl — a `bypass` preset must never ride a shared notebook. Empty → follow global.
function _nbId() { return (typeof nbState !== 'undefined' && nbState && nbState.id) || ''; }
function nbAgentPermKey() { return 'slatePerm:' + _nbId(); }
function nbAgentPerm() { return localStorage.getItem(nbAgentPermKey()) || ''; }
// EFFECTIVE values sent with each chat turn: per-notebook override wins, else the global default.
// Model override travels in the .jl (state_json → nbState.agentModel); permission is local-only.
function effectiveAgentModel() { return (typeof nbState !== 'undefined' && nbState && nbState.agentModel) || agentModel(); }
function effectiveAgentPerm() { return nbAgentPerm() || agentPerm(); }
function closeSettings() { document.getElementById('setbg').classList.remove('show'); }
document.getElementById('setbg').addEventListener('mousedown', e => { if (e.target.id === 'setbg') closeSettings(); });
// Esc dismisses the settings modal (capture phase + stopPropagation so command-mode keys don't also fire).
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && document.getElementById('setbg').classList.contains('show')) { e.stopPropagation(); closeSettings(); }
}, true);

