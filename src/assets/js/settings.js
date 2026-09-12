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

// ── Chart renderer ──────────────────────────────────────────────────────────────
// How interactive charts rasterise. This is a READER setting, not a document one — see `_rendererFor`
// in core.js: a browser whose canvas path is broken draws every chart as a blank rectangle, and the
// person hitting that is usually not the author and often cannot edit the notebook at all. "Auto"
// defers to the chart's own `renderer=` kwarg, which defaults to canvas.
const SLATE_RENDERERS = [
  { name: '', label: 'Auto' },
  { name: 'canvas', label: 'Canvas' },
  { name: 'svg', label: 'SVG' },
];
function curChartRenderer() {
  const v = localStorage.getItem('slateRenderer');
  return (v === 'canvas' || v === 'svg') ? v : '';
}
function setChartRenderer(v) {
  if (v === 'canvas' || v === 'svg') localStorage.setItem('slateRenderer', v);
  else localStorage.removeItem('slateRenderer');
  // ECharts fixes the renderer at init, so switching means rebuilding every instance.
  try { window._reinitCharts && window._reinitCharts(); } catch (_) {}
}
window.setChartRenderer = setChartRenderer;

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

// ── Reader-facing display settings ────────────────────────────────────────────
// The subset of Settings that shapes what a READER sees rather than how an author works: theme,
// how wide the column and figures run, whether the wheel zooms a chart, whether wide output wraps.
// Two views offer it — the authoring Settings modal and app mode's display popover — so the
// bindings live HERE, once, parameterised by element id. Adding a reader setting means adding it
// in this function and nowhere else; the two views cannot drift, and neither can invent its own
// idea of a default or a storage key.
//
// `ids` maps a setting to the elements that drive it: `{theme, wide, page, pagev, fig, figv,
// zoom, zoomv, wrap}`. A missing id is simply skipped, so a view can offer a subset.
function bindDisplaySettings(ids) {
  const el = k => (ids[k] ? document.getElementById(ids[k]) : null);
  const th = el('theme');
  if (th) {
    th.innerHTML = SLATE_UI_THEMES.map(t => `<option value="${t.name}">${t.label}</option>`).join('');
    th.value = curSlateTheme();
    th.onchange = () => setSlateTheme(th.value);
  }
  const rend = el('renderer');
  if (rend) {
    rend.innerHTML = SLATE_RENDERERS.map(r => `<option value="${r.name}">${r.label}</option>`).join('');
    rend.value = curChartRenderer();
    rend.onchange = () => setChartRenderer(rend.value);
  }
  // Full page width overrides the column width, so the two are wired together: the column slider
  // is disabled (not hidden) while full width is on, which shows the reader why it stopped working.
  const wide = el('wide'), page = el('page'), pagev = el('pagev');
  const syncPage = () => { if (page && wide) page.disabled = wide.checked; };
  if (wide) {
    wide.checked = document.body.classList.contains('fullwidth');
    wide.onchange = () => {
      document.body.classList.toggle('fullwidth', wide.checked);
      localStorage.setItem('slateFullWidth', wide.checked ? '1' : '0');
      syncPage();
    };
  }
  // Each range is live: the setters apply through CSS vars, so nothing re-renders — which matters
  // when the thing being resized is a chart in the middle of a long computation.
  const range = (input, out, get, set) => {
    if (!input) return;
    input.value = get(); if (out) out.textContent = get();
    input.oninput = () => { if (out) out.textContent = input.value; set(input.value); };
  };
  range(page, pagev, _pageMax, setPageMax); syncPage();
  range(el('fig'), el('figv'), _figMax, setFigMax);
  range(el('zoom'), el('zoomv'),
        () => { const n = parseInt(localStorage.getItem('slateScrollZoom'), 10); return Number.isFinite(n) ? n : _ZOOM_DEFAULT; },
        v => localStorage.setItem('slateScrollZoom', v));
  const wrap = el('wrap');
  if (wrap) {
    wrap.checked = document.body.classList.contains('wrap-output');
    wrap.onchange = () => {
      document.body.classList.toggle('wrap-output', wrap.checked);
      localStorage.setItem('slateWrapOutput', wrap.checked ? '1' : '0');
    };
  }
  // ── Editor settings ────────────────────────────────────────────────────────────────────────
  // Optional: only bound when the caller passes the ids, so the authoring Settings modal (which has
  // its own, richer Editing tab) is unaffected. Every setter here already applies LIVE across open
  // editors, so a reader changing keymap mid-exercise doesn't lose what they typed.
  const km = el('keymap');
  if (km && window.editorKeymapModes) {
    const modes = ['default', ...window.editorKeymapModes()];
    const label = m => m === 'default' ? 'Default' : m[0].toUpperCase() + m.slice(1);
    km.innerHTML = modes.map(m => `<option value="${m}">${label(m)}</option>`).join('');
    km.value = window.editorKeymapMode ? window.editorKeymapMode() : 'default';
    km.onchange = () => window.setEditorKeymap && window.setEditorKeymap(km.value);
  }
  const syn = el('syntax');
  if (syn && window.setSyntaxTheme) {
    const themes = window._syntaxThemes || [{ name: 'dark-plus', label: 'Dark+ (default)' }];
    syn.innerHTML = themes.map(x => `<option value="${x.name}">${x.label || x.name}</option>`).join('');
    syn.value = localStorage.getItem('slateSyntaxTheme') || 'dark-plus';
    syn.onchange = () => window.setSyntaxTheme(syn.value);
  }
  const edwrap = el('edwrap');
  if (edwrap && window.setEditorWrap) {
    edwrap.checked = localStorage.getItem('slateWrapEditor') === '1';
    edwrap.onchange = () => window.setEditorWrap(edwrap.checked);
  }
}
window.bindDisplaySettings = bindDisplaySettings;

// ── Keymap preset picker ───────────────────────────────────────────────────────
// Bound the same way as the display block, and for the same reason: two views offer it — the authoring
// Settings modal and app mode's display popover — so the wiring lives here once. `ids` maps to
// `{preset, count}`; a missing id is skipped.
//
// It re-reads on `slate:keymap-changed` so the count stays right while the Customise… dialog is open
// behind it, and so switching preset from that dialog moves this select too. Both views are
// long-lived DOM, so without that they would drift the moment anything changed elsewhere.
function bindKeymapSettings(ids) {
  const km = window.slateKeymap;
  if (!km) return;
  const sel = ids.preset ? document.getElementById(ids.preset) : null;
  const out = ids.count ? document.getElementById(ids.count) : null;
  const paint = () => {
    if (sel) {
      const presets = km.presets();
      // Rebuilt each time: an extension could in principle contribute a preset, and rebuilding is
      // cheaper than deciding whether the list changed.
      sel.innerHTML = presets.map(p => `<option value="${p.name}" title="${window.slateEscHtml(p.about || '')}">${window.slateEscHtml(p.label)}</option>`).join('');
      sel.value = km.preset();
    }
    if (out) {
      const n = window.slateCmd ? window.slateCmd.all().filter(c => km.isCustom(c.id)).length : 0;
      const bad = km.conflicts().length;
      out.textContent = (n ? `${n} customised` : 'none customised') + (bad ? ` · ${bad} conflicting` : '');
      out.classList.toggle('warn', bad > 0);
    }
  };
  if (sel) sel.onchange = () => km.setPreset(sel.value);
  // The Settings modal re-binds on every open, so the subscription is attached once per element set —
  // otherwise each open would add another listener and the repaint would run N times per change.
  const marker = sel || out;
  if (marker && !marker._kmSubscribed) {
    marker._kmSubscribed = true;
    window.addEventListener('slate:keymap-changed', paint);
  }
  paint();
}
window.bindKeymapSettings = bindKeymapSettings;

// ── Section list + filter, over any grouped panel ───────────────────────────────
// Sections are DERIVED from the group headers already in the markup — every row belongs to the
// header above it — so adding a setting stays a one-line change and the nav follows with no list to
// keep in sync. That is what lets one implementation drive both scopes of this dialog: the global
// rows are static HTML with `.setsec`/`.setrow`, the per-notebook rows are built from /api/config
// with `.cfggroup`/`.cfgrow`, and neither needs to know about the other.
//
// Filtering searches what the reader can actually read: visible text plus `title` tooltips and input
// placeholders, which is where most of a setting's vocabulary lives ("vim", "trackpad", "svg"). It
// spans every section — a filter that only searched the section you were already looking at would be
// a worse version of reading it.
const _NAV_MAX_HITS = 6;      // a filter is a shortcut, not a second way to read the whole panel
function slateSectionNav(opt) {
  const grpSel = opt.group || '.setsec', rowSel = opt.row || '.setrow';
  const max = opt.max || _NAV_MAX_HITS;
  const el = x => typeof x === 'string' ? document.getElementById(x) : x;
  const token = {};        // identity of THIS instance — see the filter wiring in `rebuild`
  let tab = '';

  function sections() {
    const body = el(opt.body);
    if (!body) return [];
    const out = [];
    let cur = null;
    for (const node of body.children) {
      if (node.matches(grpSel)) { cur = { name: node.textContent.trim(), head: node, rows: [] }; out.push(cur); }
      else if (cur && node.matches(rowSel)) cur.rows.push(node);
    }
    // A section holding no control is a signpost, not a destination: no nav entry (an entry you
    // cannot act in is a dead end) and its rows stay hidden.
    for (const s of out) s.nav = s.rows.some(r => r.querySelector('input,select,textarea,button'));
    return out;
  }
  // Searchable text for a row, computed once and cached on the node. Config rows are replaced
  // wholesale on every render, so the cache expires with them.
  function rowText(r) {
    if (r._navText != null) return r._navText;
    const attrs = Array.from(r.querySelectorAll('[title],[placeholder]'))
      .map(n => (n.getAttribute('title') || '') + ' ' + (n.getAttribute('placeholder') || '')).join(' ');
    r._navText = (r.textContent + ' ' + attrs + ' ' + (r.getAttribute('title') || ''))
      .toLowerCase().replace(/\s+/g, ' ');
    return r._navText;
  }
  // A few rows have their own visibility logic (the custom-model row, the restart hint). The section
  // list still hides them when their section isn't showing, but it must never RE-show one its owner
  // meant to keep hidden — so the owner's last intent is remembered and restored, not guessed.
  const ownerHidden = r => !!r._navForced && (r._navOwn ?? r.style.display) === 'none';
  function show(r, on, cat) {
    if (!on) {
      if (r._navForced && r.style.display !== 'none') r._navOwn = r.style.display;
      r.style.display = 'none';
      r.removeAttribute('data-cat');
      return;
    }
    r.style.display = r._navForced ? (r._navOwn ?? 'none') : '';
    if (cat) r.setAttribute('data-cat', cat); else r.removeAttribute('data-cat');
  }
  function apply() {
    const secs = sections();
    const navSecs = secs.filter(s => s.nav);
    if (!navSecs.length) return;
    const filt = el(opt.filter), status = el(opt.status), nav = el(opt.nav);
    const q = ((filt || {}).value || '').trim().toLowerCase();
    if (!tab || !navSecs.some(s => s.name === tab)) tab = navSecs[0].name;
    const btns = nav ? Array.from(nav.children) : [];

    if (!q) {
      for (const s of secs) {
        const on = s.nav && s.name === tab;
        s.head.style.display = 'none';        // the nav entry beside it already names the section
        for (const r of s.rows) show(r, on, '');
      }
      // Browsing: each entry carries how many of its rows are MARKED (an overridden setting), so the
      // list doubles as a summary of what this notebook has changed.
      btns.forEach(b => {
        const s = navSecs.find(x => x.name === b.dataset.sec);
        const n = (opt.mark && s) ? s.rows.filter(r => !ownerHidden(r) && opt.mark(r)).length : 0;
        b.classList.toggle('on', b.dataset.sec === tab);
        b.classList.remove('hit'); delete b.dataset.hits;
        b.classList.toggle('marked', n > 0);
        if (n) b.dataset.marks = String(n); else delete b.dataset.marks;
      });
      if (status) status.style.display = 'none';
      return;
    }
    // Filtering spans every section, so results are a flat list in panel order and each row carries a
    // chip naming the section it came from — the reader is after one setting, not a section, and
    // headers would bury a single hit under its group. Capped: past a handful the useful move is a
    // better query, and the count of what is hidden says so.
    const hits = [];
    for (const s of navSecs) {
      for (const r of s.rows) {
        if (ownerHidden(r)) continue;               // not on show for its own reasons — not a result
        if (rowText(r).includes(q) || s.name.toLowerCase().includes(q)) hits.push([s, r]);
      }
    }
    const keep = new Map(hits.slice(0, max).map(([s, r]) => [r, s.name]));
    const counts = {};
    for (const [s] of hits) counts[s.name] = (counts[s.name] || 0) + 1;
    for (const s of secs) {
      s.head.style.display = 'none';
      for (const r of s.rows) show(r, keep.has(r), keep.get(r));
    }
    btns.forEach(b => {
      const n = counts[b.dataset.sec] || 0;
      b.classList.remove('on', 'marked'); delete b.dataset.marks;
      b.classList.toggle('hit', n > 0);
      if (n) b.dataset.hits = String(n); else delete b.dataset.hits;
    });
    if (status) {
      const extra = hits.length - keep.size;
      status.textContent = !hits.length ? 'No settings match.'
        : `+${extra} more match${extra === 1 ? '' : 'es'} — keep typing to narrow.`;
      status.style.display = (!hits.length || extra > 0) ? '' : 'none';
    }
  }
  function rebuild() {
    const nav = el(opt.nav), filt = el(opt.filter);
    const secs = sections().filter(s => s.nav);
    if (nav) {
      nav.innerHTML = secs.map(s => `<button type="button" data-sec="${window.slateEscHtml(s.name)}"><span>${window.slateEscHtml(s.name)}</span></button>`).join('');
      Array.from(nav.children).forEach(b => {
        b.onclick = () => { tab = b.dataset.sec; if (filt) filt.value = ''; apply(); };   // a click is a reset
      });
    }
    // Both scopes share one filter input and one nav element, so the guard has to key on the
    // INSTANCE. Keying it on an element id left the input bound to whichever scope wired it first,
    // and typing in the other scope silently did nothing.
    if (filt && filt._navWired !== token) { filt._navWired = token; filt.oninput = apply; }
    apply();
  }
  // Rows whose visibility is owned elsewhere — flagged so the list leaves them alone rather than
  // fighting the code that toggles them.
  function forced(ids) { ids.forEach(id => { const n = el(id); if (n) n._navForced = true; }); }
  return { apply, rebuild, forced, get tab() { return tab; }, set tab(v) { tab = v; } };
}
window.slateSectionNav = slateSectionNav;

// ── Scope: your global preferences vs THIS notebook's overrides ─────────────────
// One dialog, two scopes. These were separate surfaces — a modal and a side panel — which hid the
// relationship that matters most: several settings exist in BOTH, as a global default in one and a
// per-notebook override in the other (agent model and permissions are the pair people trip over).
// A scope switch puts them one click apart, and the section list shows how many rows this notebook
// has actually pinned.
let _setScope = 'global';
const _setNavs = {};
function _setNavFor(scope) {
  if (!_setNavs[scope]) {
    _setNavs[scope] = scope === 'notebook'
      ? slateSectionNav({ body: 'configlist', nav: 'settabs', filter: 'setfilter', status: 'setempty',
                          group: '.cfggroup', row: '.cfgrow',
                          // An overridden row is one pinned to this notebook — its badge says so.
                          mark: r => !!r.querySelector('.cfgbadge.override') })
      : slateSectionNav({ body: 'setbody', nav: 'settabs', filter: 'setfilter', status: 'setempty' });
  }
  return _setNavs[scope];
}
function setSettingsScope(scope) {
  _setScope = scope === 'notebook' ? 'notebook' : 'global';
  const gb = document.getElementById('setbody'), cb = document.getElementById('configlist');
  if (gb) gb.style.display = _setScope === 'global' ? '' : 'none';
  if (cb) cb.style.display = _setScope === 'notebook' ? '' : 'none';
  document.querySelectorAll('.setscope button').forEach(b => b.classList.toggle('on', b.dataset.scope === _setScope));
  const filt = document.getElementById('setfilter');
  if (filt) filt.value = '';                      // a scope is a different set of rows — start clean
  // The notebook rows are fetched, so `loadConfig` rebuilds the list when they land (see config.js).
  if (_setScope === 'notebook') { try { loadConfig(); } catch (_) {} }
  else _setNavFor('global').rebuild();
  if (filt) filt.focus();
}
window.setSettingsScope = setSettingsScope;
window.slateSettingsNav = _setNavFor;             // config.js rebuilds the list after each render

// Apply the persisted reader settings that live on the BODY (the CSS-var ones apply themselves at
// load, above). Called once at startup by whichever view boots — both postures need it, so neither
// owns it. `dragdrop.js` historically did the full-width half; this is the single place now.
function applyDisplaySettings() {
  document.body.classList.toggle('fullwidth', localStorage.getItem('slateFullWidth') === '1');
  document.body.classList.toggle('wrap-output', localStorage.getItem('slateWrapOutput') === '1');
}
window.applyDisplaySettings = applyDisplaySettings;

// ── Settings modal ────────────────────────────────────────────────────────────
function openSettings(scope) {
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
  // Editor keymap (default / vim / emacs). Live across every open editor — the alternative keymap
  // sits in its own compartment, so switching reconfigures the views in place rather than rebuilding
  // them. Options a build didn't bundle are dropped, so the menu can't offer a mode that won't apply.
  const km = document.getElementById('seteditorkeymap');
  if (km) {
    const have = window.editorKeymapModes ? window.editorKeymapModes() : [];
    for (const o of [...km.options]) {
      if (o.value !== 'default' && !have.includes(o.value)) o.remove();
    }
    km.value = window.editorKeymapMode ? window.editorKeymapMode() : 'default';
    km.onchange = () => { window.setEditorKeymap && window.setEditorKeymap(km.value); };
  }
  const ct = document.getElementById('setcomptab');
  if (ct) {
    ct.value = localStorage.getItem('slateCompleteTab') || 'accept';
    ct.onchange = () => localStorage.setItem('slateCompleteTab', ct.value);
  }
  // Keymap preset + how many shortcuts have been changed on top of it. The preset select lives here
  // because it is the one keyboard decision most people ever make; everything finer is the Customise…
  // dialog (keymap-ui.js). The count is the honest summary of what that dialog holds — "3 customised"
  // tells you there is something in there, where a bare button tells you nothing.
  bindKeymapSettings({ preset: 'setkeymappreset', count: 'setkeymapcount' });
  // Theme + widths + scroll-zoom + output wrap — the reader-facing block, shared verbatim with app
  // mode's display popover (see `bindDisplaySettings` above).
  bindDisplaySettings({ theme: 'settheme', renderer: 'setrenderer',
                        wide: 'setwide', page: 'setpage', pagev: 'setpagev',
                        fig: 'setfig', figv: 'setfigv', zoom: 'setzoom', zoomv: 'setzoomv',
                        wrap: 'setwrap' });
  // Soft-wrap long lines in the CODE editor (markdown editors always wrap). Live across all editors.
  const wraped = document.getElementById('setwraped');
  if (wraped) {
    wraped.checked = localStorage.getItem('slateWrapEditor') === '1';
    wraped.onchange = () => { window.setEditorWrap && window.setEditorWrap(wraped.checked); };
  }
  // Editor chrome — line numbers, indent guides, code folding. Off by default so a cell keeps the
  // uncluttered look; each applies live to every open editor via its compartment (editor.js).
  for (const [id, key, apply] of [['setlinenums', 'slateLineNumbers', 'setLineNumbers'],
                                  ['setguides', 'slateIndentGuides', 'setIndentGuides'],
                                  ['setfolding', 'slateCodeFolding', 'setCodeFolding']]) {
    const el = document.getElementById(id);
    if (!el) continue;
    el.checked = localStorage.getItem(key) === '1';
    el.onchange = () => { window[apply] ? window[apply](el.checked) : localStorage.setItem(key, el.checked ? '1' : '0'); };
  }
  // Matching-word highlight. Unlike the three above this one defaults ON — it is how the feature
  // shipped — so the stored value is read as "not off" rather than "is on". Its colour list comes
  // from editor.js so the two can't drift; `theme` (the default) tracks the notebook theme's accent.
  {
    const on = document.getElementById('setmatchhi');
    if (on) {
      on.checked = localStorage.getItem('slateMatchHighlight') !== '0';
      on.onchange = () => window.setMatchHighlight && window.setMatchHighlight(on.checked);
    }
    // Swatches rather than a <select>: the choice IS a colour, so showing the colours is the whole
    // point — and an <option>'s background is unstylable in Safari, so a coloured dropdown would
    // silently degrade to a plain list there. Each swatch carries the tint at the strength the
    // editor paints it, so what you pick is what you get.
    //
    // `theme` is the odd one out and has to LOOK it. It renders in whatever the current theme's
    // accent is, so on its own it is indistinguishable from the fixed blue sitting next to it — you
    // could neither tell which swatch meant "follow the theme" nor what colour picking it would
    // give. It gets a marker ring, and the current choice is named in text beside the row, so the
    // answer is on screen instead of in a tooltip.
    const tint = document.getElementById('setmatchtint');
    const tintName = document.getElementById('setmatchtintname');
    if (tint && window.matchTintNames && window.matchTintValue) {
      const label = n => n === 'theme' ? 'Theme' : n[0].toUpperCase() + n.slice(1);
      const paint = () => {
        const cur = localStorage.getItem('slateMatchTint') || 'theme';
        tint.innerHTML = window.matchTintNames().map(n =>
          `<button class="swatch${n === cur ? ' on' : ''}${n === 'theme' ? ' auto' : ''}" data-tint="${n}"
                   title="${n === 'theme' ? 'Follow the notebook theme’s accent colour' : label(n)}"
                   style="--sw:${window.matchTintValue(n)}"></button>`).join('');
        // Short enough not to crowd the row. What "theme accent" MEANS lives in the swatch's own
        // tooltip and in the marker ring, not in a sentence the row has no space for.
        if (tintName) tintName.textContent = cur === 'theme' ? 'Theme accent' : label(cur);
        for (const b of tint.querySelectorAll('.swatch')) {
          b.onclick = () => { window.setMatchTint && window.setMatchTint(b.dataset.tint); paint(); };
        }
      };
      paint();
      // The theme swatch shows the LIVE accent, so a theme change has to repaint it.
      const themeSel = document.getElementById('settheme');
      if (themeSel) themeSel.addEventListener('change', () => setTimeout(paint, 60));
    }
  }
  // Per-notebook settings (hot-reload, parallel, threads, slides, bibstyle, agent-model override)
  // live in this dialog's "This notebook" scope (config.js) — a single view with effective value +
  // source badge + clear-override, instead of being scattered here.
  // (The overall Slate UI theme is bound above, with the rest of the reader-facing settings.)
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
  // Built LAST: every row above is in place, so the section list and the filter index see the final
  // panel. `scope` lets a caller open straight onto the notebook's overrides (the top menu and the
  // palette both do); anything else means the global scope.
  _setNavFor('global').forced(['setmodelcustomrow', 'setmodelhint']);
  document.getElementById('setbg').classList.add('show');
  // Search-first: `setSettingsScope` clears the filter and puts the caret in it, so opening and
  // typing finds a setting without a click. Has to follow `show` — focus doesn't take on a
  // display:none subtree.
  setSettingsScope(scope === 'notebook' ? 'notebook' : 'global');
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

