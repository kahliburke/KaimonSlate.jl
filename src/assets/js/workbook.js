// ── Workbook mode: the cells a reader fills in ───────────────────────────────────────────────────
//
// The server half is server_app.jl: a hub started as a workbook serves the cell-edit and run routes,
// but only for cells the document tags `workbook`. This is the front-end half — the editor is
// already on the page (the reading view merely hides it, and notebook.css makes an exception for
// `.cell.workbook`), so all this adds is the two affordances an app has no other way to offer.
//
// Why per-cell buttons rather than the authoring chrome: an app has no run chip, no palette and no
// keyboard hints. Shift+Enter still runs the cell — that binding lives in the CM6 keymap, which
// app mode never touched — but nothing on the page SAYS so, and a student who doesn't know it is
// stuck looking at a filled-in function that never ran.
//
// Deliberately a CLASSIC script, like appmode.js: it reuses `runCell`/`edSetText` off `window` and
// must be able to run in the same pass as the rest of the notebook chrome.

(function () {
  const APP = window.__SLATE_APP__;
  if (!(APP && APP.on && APP.workbook)) return;

  // Cells are re-rendered by Preact on every state update, which throws away anything we appended.
  // Rather than fight the render, re-assert after it: an observer on the notebook re-adds the bar to
  // any workbook cell missing one. Idempotent by construction (the `.wbbar` check), so a burst of
  // mutations during a run costs one querySelectorAll per frame and no duplicate buttons.
  function cellId(el) { return (el.id || '').replace(/^cell-/, ''); }

  function ensureBar(cell) {
    if (!cell || cell.querySelector(':scope > .wbbar')) return;
    const id = cellId(cell);
    if (!id) return;

    const bar = document.createElement('div');
    bar.className = 'wbbar';

    const run = document.createElement('button');
    run.className = 'wbrun';
    run.type = 'button';
    run.textContent = 'Run';
    run.addEventListener('click', async () => {
      run.disabled = true;
      try {
        // `force`, because a student who re-runs an unchanged cell means it: the advance-only skip
        // would leave them clicking a button that visibly does nothing.
        await window.runCell(id, true);
      } catch (e) {
        console.error('workbook: run failed', id, e);
      } finally {
        run.disabled = false;
      }
    });

    const reset = document.createElement('button');
    reset.className = 'wbreset';
    reset.type = 'button';
    reset.textContent = 'Reset to the original';
    reset.addEventListener('click', async () => {
      // Their work is about to be thrown away and the notebook file is the only copy — the browser
      // backup is keyed to the same cell and is about to be overwritten too.
      if (!window.confirm('Replace your work in this cell with the original starting code?')) return;
      try {
        // `api` splices the notebook id in (core.js `_apipath`). Reaching for `NB_ID` directly would
        // not work anyway: it's a top-level `const`, which is not a property of `window`.
        const d = await api('GET', '/api/workbook-stub/' + encodeURIComponent(id));
        if (!d || typeof d.source !== 'string') throw new Error('no source in response');
        window.edSetText(id, d.source);
        await window.runCell(id, true);
      } catch (e) {
        console.error('workbook: reset failed', id, e);
        window.alertDark ? window.alertDark('Could not restore the original for this exercise.')
                         : window.alert('Could not restore the original for this exercise.');
      }
    });

    bar.appendChild(run);
    bar.appendChild(reset);
    cell.appendChild(bar);
  }

  function sweep() {
    document.querySelectorAll('#nb .cell.workbook').forEach(ensureBar);
  }

  // ── Scratchpad ─────────────────────────────────────────────────────────────────────────────
  // A reader cannot add cells, so without this the only place to try something out is inside an
  // exercise they then have to put back. The RESULTS half already exists: `slate.eval` streams
  // throwaway runs into `#scratchpanel` and panels.js renders them, in an app as much as in the
  // authoring UI. All that was missing is somewhere to type. So this mounts an editor at the top
  // of that panel rather than building a second one.
  let _scratchView = null;

  function runScratch() {
    if (!_scratchView) return true;
    const source = _scratchView.state.doc.toString();
    if (!source.trim()) return true;
    api('POST', '/api/scratch-eval', { source }).catch(e => console.error('scratchpad: run failed', e));
    return true;   // a CM6 keybinding must say it handled the key
  }

  function ensureScratchEditor() {
    const panel = document.getElementById('scratchpanel');
    const body = document.getElementById('scratchbody');
    if (!panel || !body || document.getElementById('wbscratchin')) return;
    if (!window.mkEditor) return;   // editor bundle not up yet; the opener retries

    const wrap = document.createElement('div');
    wrap.id = 'wbscratchin';
    wrap.className = 'wbscratchin';
    const host = document.createElement('div');
    wrap.appendChild(host);

    const bar = document.createElement('div');
    bar.className = 'wbbar';
    const run = document.createElement('button');
    run.className = 'wbrun'; run.type = 'button'; run.textContent = 'Run';
    run.addEventListener('click', runScratch);
    const hint = document.createElement('span');
    hint.className = 'wbhint';
    hint.textContent = '⇧⏎ to run — this never touches the document';
    bar.appendChild(run); bar.appendChild(hint);
    wrap.appendChild(bar);

    panel.insertBefore(wrap, body);
    // The same factory the cell editors use, so highlighting, completion and the keymap are
    // identical to the exercise cells rather than a second, subtly-different editor.
    _scratchView = window.mkEditor(host, {
      doc: '',
      cellId: '__wbscratch',
      keys: [{ key: 'Shift-Enter', run: runScratch }, { key: 'Mod-Enter', run: runScratch }],
    });
  }

  function openScratch() {
    ensureScratchEditor();
    if (window.toggleScratch) window.toggleScratch();
    setTimeout(() => { try { _scratchView && _scratchView.focus(); } catch (_) {} }, 60);
  }
  window.openWorkbookScratch = openScratch;

  function addScratchLauncher() {
    if (document.getElementById('wbscratchlauncher')) return;
    const b = document.createElement('button');
    b.id = 'wbscratchlauncher';
    b.type = 'button';
    b.title = 'Scratchpad — try something without touching the document (⌘⇧S)';
    b.setAttribute('aria-label', 'Scratchpad');
    b.textContent = '🧪';
    b.addEventListener('click', openScratch);
    document.body.appendChild(b);
  }

  function start() {
    sweep();
    addScratchLauncher();
    // ⌘⇧S / Ctrl+Shift+S. Registered on `window` in the CAPTURE phase for the same reason appmode.js
    // blocks keys there: Slate's own shortcuts are bubble-phase, and this must not be one of the
    // things the app-mode blocker swallows.
    window.addEventListener('keydown', e => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === 'S' || e.key === 's')) {
        e.preventDefault(); e.stopImmediatePropagation(); openScratch();
      }
    }, true);
    const nb = document.getElementById('nb');
    if (!nb) return;
    let queued = false;
    new MutationObserver(() => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => { queued = false; sweep(); });
    }).observe(nb, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
