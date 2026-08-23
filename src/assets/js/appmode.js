// ── App mode: the notebook as a finished application ─────────────────────────────────────────────
//
// The server decides the posture (see server_app.jl) and stamps it into the page as
// `window.__SLATE_APP__`. This file is the front-end half: swap the authoring topbar for an app
// bar, keep a busy indicator honest, offer the reader-facing display settings, and translate cell
// failures into something a domain expert can act on.
//
// Deliberately a CLASSIC script, not a module: it must run in the same pass as settings.js (whose
// live setters it reuses) and before the reading view is revealed. It owns no notebook state — the
// reading VIEW is the zen CSS, which `body.app` already shares.

(function () {
  const APP = window.__SLATE_APP__;
  const ON = !!(APP && APP.on);

  // The head script hid the body to stop the authoring chrome flashing. Whatever happens below,
  // that has to be undone — an app that fails to boot should show a plain notebook, not a blank
  // page. So it's the first thing wired, on both paths.
  function reveal() {
    document.documentElement.classList.remove('app-boot');
    document.body.style.visibility = '';
  }
  if (!ON) { document.addEventListener('DOMContentLoaded', reveal); return; }

  window.appSettingsToggle = function (e) {
    e && e.stopPropagation();
    const p = document.getElementById('appsetpop');
    if (p) p.classList.toggle('open');
  };
  document.addEventListener('click', () => {
    const p = document.getElementById('appsetpop');
    if (p) p.classList.remove('open');
  });

  // ── Busy state ─────────────────────────────────────────────────────────────────────────────
  // A computation takes seconds, and a page that looks identical while it runs reads as broken. The
  // authoring UI answers this with a run chip full of cell ids; an app needs "Working…", and it
  // needs to be TRUE — driven by the same cell states the run chip reads, not by a click handler
  // that guesses when the work is done.
  function syncStatus() {
    const running = document.querySelectorAll('#nb .cell.running').length;
    const st = document.getElementById('appstatus');
    const tx = document.getElementById('appstatustext');
    if (!st || !tx) return;
    st.classList.toggle('busy', running > 0);
    tx.textContent = running > 0 ? 'Working…' : '';
  }

  // ── Failures ───────────────────────────────────────────────────────────────────────────────
  // Julia's exception text is the actionable half and stays visible; the backtrace goes behind a
  // disclosure (the ::after "details" affordance in the CSS). The banner above summarises WHAT
  // failed, using the failing cell's heading where the notebook gives it one — a document written
  // for an app has section headings, and naming the step that failed beats naming a cell id.
  function cellLabel(cell) {
    // The nearest preceding markdown heading is the author's own name for this step.
    let n = cell;
    while (n) {
      const h = n.querySelector && n.querySelector('.md h1, .md h2, .md h3');
      if (h && h.textContent.trim()) return h.textContent.trim();
      n = n.previousElementSibling;
    }
    return '';
  }

  let _failCell = null;
  function syncFailures() {
    const banner = document.getElementById('appfail');
    const text = document.getElementById('appfailtext');
    if (!banner || !text) return;
    const errCell = document.querySelector('#nb .cell:has(.err)');
    if (!errCell) { banner.style.display = 'none'; _failCell = null; return; }
    _failCell = errCell;
    const label = cellLabel(errCell);
    // The first line of the exception is the type + message; the rest is usually a suggestion.
    const msgEl = errCell.querySelector('.err .err-msg, .err pre');
    const first = msgEl ? (msgEl.textContent || '').trim().split('\n')[0] : '';
    text.textContent = label
      ? `“${label}” didn't finish. ${first}`
      : `Something didn't finish. ${first}`;
    banner.style.display = '';
  }

  window.appFailJump = function () {
    if (_failCell) _failCell.scrollIntoView({ behavior: 'smooth', block: 'center' });
  };

  // Click anywhere on an error block toggles its backtrace (the "details" affordance is a CSS
  // pseudo-element, which can't take its own listener).
  document.addEventListener('click', e => {
    const err = e.target && e.target.closest ? e.target.closest('.err') : null;
    if (err) err.classList.toggle('showtrace');
  });

  // ── Authoring surfaces ─────────────────────────────────────────────────────────────────────
  //
  // The reading-view CSS hides the authoring chrome, and that is PRESENTATION, not lockdown: every
  // panel, modal and command is still reachable by whatever opens it — a hotkey, the command
  // palette, a click target that survived. A reader who finds one gets a packages screen, a restart
  // button, an export dialog. The server refuses those routes, so nothing they do lands; the UI
  // offering them at all is the defect.
  //
  // Two gates, both by construction rather than by enumeration of surfaces:
  //   1. every authoring hotkey is swallowed before its handler sees it, and
  //   2. the functions that OPEN an authoring surface are replaced with no-ops.
  // Naming the openers keeps this to one list in one file; naming the surfaces would mean tracking
  // every panel, its markup, and its CSS, in three.

  // The globals that open something an app's reader has no business in. Each is a plain top-level
  // `function` in a classic script — i.e. a writable property of `window` — and every call site
  // resolves through the global object, so replacing the property disables all of them at once.
  const AUTHORING_OPENERS = [
    // Tool panels and modals
    'openSettings', 'togglePackages', 'openExtensions', 'toggleLog', 'toggleTail', 'toggleHistory', 'toggleConfig',
    'toggleTopMenu', 'toggleAgent', 'toggleAgentMax', 'toggleThink', 'openDestinations',
    'openTraceModal', 'toggleDeps',
    // Command palette and the docs browser (their hotkeys are blocked below too — this covers the
    // click paths, and anything that calls them programmatically)
    'openPalette', 'togglePalette', 'openDocs', 'openDocsFor', 'openDocsAtCursor',
    // Export and publish: an app's reader gets `Slate.download` of a RESULT, not the document
    'openExport', 'openPublish', 'publishToSite', 'exportNotebook',
    // Worker lifecycle — a restart mid-session strands the reader with no way to recover
    'restartWorker', 'restartKernel', 'openWorkerPop', 'toggleRunLoc', 'openLaunchPop',
    'toggleLaunchPop',
    // Editing the document itself
    'addCell', 'deleteCell', 'toggleSource', 'toggleType', 'toggleCollapse', 'toggleHideCode',
    'toggleTrace', 'openControlPicker', 'openTagEditor', 'insertBind', 'insertRecipe',
  ];
  function disableAuthoringOpeners() {
    const noop = function () {};
    for (const name of AUTHORING_OPENERS) {
      // Only replace what exists — a name that has moved on shouldn't define a new global, which
      // would turn a rename into a silently-dead stub instead of a visible miss.
      if (typeof window[name] === 'function') { try { window[name] = noop; } catch (_) {} }
    }
  }

  // Slate's shortcuts are registered as ordinary bubble-phase listeners on `document`, so a single
  // CAPTURE listener on `window` runs before all of them. It stops propagation but deliberately does
  // NOT preventDefault: the browser's own combinations — find, print, reload, zoom, copy — are how a
  // reader works with a page and must keep working. Only Slate's handlers are cut out.
  function blockAuthoringKeys(e) {
    // Typing into a control is the one thing a reader DOES do with the keyboard.
    const t = e.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || ''))) return;
    if (e.key === 'Tab' || e.key === 'Escape') return;   // focus order and dismissal stay intact
    e.stopImmediatePropagation();
  }

  // ── Boot ───────────────────────────────────────────────────────────────────────────────────
  function boot() {
    // `zen` IS the reading view — app mode wears it rather than restating it, so notebook.css has
    // one definition of "hide the code and the chrome" and an app can never fall behind it.
    document.body.classList.add('zen', 'app');
    window.addEventListener('keydown', blockAuthoringKeys, true);
    // The opener stubs must land AFTER every script has evaluated — a `function` declaration assigns
    // its window property when its script runs, so stubbing earlier just gets overwritten. This file
    // is not the last one included. `load` re-applies once more, for anything wired asynchronously.
    disableAuthoringOpeners();
    window.addEventListener('load', disableAuthoringOpeners);
    // …but zen is escapable by design (Esc, the ✕) and an app is not: the server refuses the
    // authoring API, so dropping the reading view would only expose editors that 403 on save.
    // Neutralise the toggle rather than special-casing it inside slides.js.
    window.toggleZen = () => {};
    window.exitZen = () => {};
    applyDisplaySettings();
    bindDisplaySettings({ theme: 'apptheme', wide: 'appwide', page: 'apppage', pagev: 'apppagev',
                          fig: 'appfig', figv: 'appfigv', zoom: 'appzoom', zoomv: 'appzoomv',
                          wrap: 'appwrap' });
    // No title element to fill: the document's own `role=title` cell IS the page heading, and
    // repeating it in chrome only competed with it. The browser TAB still carries the document
    // title, substituted server-side into `<title>` (see _inject_app).
    reveal();

    // The notebook re-renders on every state version bump, so poll rather than hook a specific
    // render path — this stays correct as the Preact migration moves cells around, and the cost of
    // two querySelectorAll calls a few times a second is not measurable.
    setInterval(() => {
      syncStatus();
      syncFailures();
    }, 400);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
