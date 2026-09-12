// ── Command registry ──────────────────────────────────────────────────────────
// Every keyboard-reachable action in the notebook, under a STABLE id. The keymap (keymap.js), the
// command palette (palette.js) and the Keyboard settings panel (keymap-ui.js) all read this one list,
// so a binding and the shortcut hint shown beside it come from the same record.
//
// The palette's `key:` field used to be a hand-written display string with nothing tying it to the
// handler that ran, so a rebind left the palette advertising a chord that did nothing. Hints are
// DERIVED from the live keymap now.
//
// A command declares WHERE it can fire. The chord comes from the keymap.
//
//   ctx: ['command']            a cell is selected and you are not editing it (single keys live here)
//   ctx: ['global']             anywhere, including inside a cell editor (must carry a modifier)
//   ctx: ['editor']             inside a CodeMirror editor (fed to CM6's keymap, so it can win over
//                               the text-editing defaults)
//
// `keys` is the Slate preset's binding. keymaps.js ships alternative presets (VS Code, Jupyter,
// vim-flavoured) and the user's overlay wins over both. See keymap.js.
//
// Load order: this file only describes actions, so it can load before the scripts that implement
// them. Every `run` reaches through `window.` and is called long after the page is up. That also
// makes it safe in app mode, where whole scripts (palette.js, search.js, files.js) are never shipped:
// the command is registered, `available()` answers false, and nothing throws.

// ── Registry ──────────────────────────────────────────────────────────────────
// Insertion order is preserved (Map), so a group's commands stay in the order written here and an
// extension's commands stay grouped together at the end.
const _CMDS = new Map();

// Is the function backing this command present in the page at all? Used by the palette to hide a
// command app mode has no script for, and by the keymap UI to grey its row rather than pretend.
function _available(c) {
  if (!c) return false;
  if (typeof c.available === 'function') { try { return !!c.available(); } catch (_) { return false; } }
  return true;
}

// A command's current chords come from the keymap, which loads after this file — asked for lazily so
// there is no boot-order coupling and no cached copy to invalidate on a rebind.
const _chords = id => (window.slateKeymap ? window.slateKeymap.chordsFor(id) : []);

window.slateCmd = {
  // `spec`: {id, label, group, ctx, keys, run, available?, ext?, hidden?}. Re-registering an id
  // REPLACES it — extension scripts are re-injected on every run drain, so stacking would duplicate.
  register(spec) {
    if (!spec || !spec.id || typeof spec.run !== 'function') return null;
    const c = {
      id: String(spec.id),
      label: String(spec.label || spec.id),
      group: String(spec.group || 'Other'),
      ctx: (spec.ctx && spec.ctx.length ? spec.ctx : ['command']).slice(),
      keys: (spec.keys || []).slice(),          // the Slate preset's default binding(s)
      run: spec.run,
      available: spec.available,
      ext: spec.ext || '',                      // owning package, for the badge in the palette/UI
      hidden: !!spec.hidden,                    // reachable by key, but not offered in the palette
      inst: !!spec.inst,                        // the editor binds this one per instance (see below)
      // `soft` = this command may DECLINE a keypress (return false) when it has nothing to do, and the
      // keymap then offers the chord to whoever else wants it. Declaring it is what lets two commands
      // share a chord on purpose without being reported as a conflict.
      soft: !!spec.soft,
    };
    _CMDS.set(c.id, c);
    return c;
  },
  unregister(id) { return _CMDS.delete(String(id)); },
  get(id) { return _CMDS.get(String(id)) || null; },
  all() { return Array.from(_CMDS.values()); },
  // Commands offered in a chooser: present in this page, not hidden.
  listed() { return this.all().filter(c => !c.hidden && _available(c)); },
  available: _available,
  chords: _chords,
  // The display hint for a command — what the palette shows on the right of a row, in host-OS
  // glyphs. First chord only: a row is not the place to enumerate three synonyms.
  hint(id) {
    const ch = _chords(id);
    return ch.length && window.slateKeymap ? window.slateKeymap.format(ch[0]) : '';
  },
  // Run a command by id. Returns true when it ran, so the keymap dispatcher can decide whether to
  // consume the keypress. A command absent from this page, or one that DECLINES by returning `false`,
  // leaves the key for whoever else wants it. The command-mode Escape relies on that: it has nothing
  // to do unless a source overlay or a multi-selection is open, and swallowing the key regardless
  // would stop Escape closing the docs dock.
  run(id, ev) {
    const c = _CMDS.get(String(id));
    if (!_available(c)) return false;
    try {
      return c.run(_target(), ev) !== false;
    } catch (e) {
      window.toast && window.toast('Command failed: ' + (e && e.message ? e.message : e), 4000);
      return true;                              // it fired; the failure is the command's, not the key's
    }
  },
};

// What a command acts on. The selection lives in keyboard.js as a classic-script `let`, so it is
// reached through the accessors it publishes rather than read off `window` directly.
function _target() {
  const id = (window.slateSelectedId && window.slateSelectedId()) || '';
  const ids = (window.slateSelectedIds && window.slateSelectedIds()) || (id ? [id] : []);
  return { id, ids, cell: id && window._cellById ? window._cellById(id) : null };
}

// ── Core commands ─────────────────────────────────────────────────────────────
// Shorthands. `has` gates a command on its implementation being on the page; `fn` calls one.
const _has = (...names) => () => names.every(n => typeof window[n] === 'function');
const _fn = (name, ...args) => { const f = window[name]; if (typeof f === 'function') f(...args); };
const R = spec => window.slateCmd.register(spec);

// A command-mode command that needs a selected cell. Without one there is nothing to act on, so it
// DECLINES the keypress (returns false) rather than acting on a guess or swallowing the key.
const _onSel = body => (t, ev) => (t.id ? (body(t, ev) !== false) : false);

// ── Running ───────────────────────────────────────────────────────────────────
R({ id: 'nb.runStale', label: 'Run stale cells', group: 'Run', ctx: ['global', 'editor'],
    keys: ['Mod-Enter'], available: _has('runAll'), run: () => _fn('runAll') });
R({ id: 'nb.runAll', label: 'Run all cells (whole notebook)', group: 'Run', ctx: ['command'],
    available: _has('rerunAll'), run: () => _fn('rerunAll') });
R({ id: 'cell.runBelow', label: 'Run this cell and below', group: 'Run', ctx: ['command'],
    available: _has('runCellAndBelow'), run: _onSel(t => _fn('runCellAndBelow', t.id)) });
// Two commands, because ⇧⏎ means two different things depending on where you press it: in the editor
// it runs the cell and leaves you in it, in command mode it runs and moves to the next cell. Splitting
// them gives each its own row in the Keyboard panel, so the two can be made uniform if you want that.
// `inst` = the EDITOR supplies this binding, per instance. In a code cell ⇧⏎ runs the cell, in a
// markdown cell's source overlay it commits the source, in the scratchpad it runs the scratch. The
// editor binds it from `opts.keys` (see `_mkCellKeys`) and the keymap contributes only the chord.
// Listed here so it still gets a row in the Keyboard panel.
R({ id: 'cell.run', label: 'Run selected cell / apply the editor', group: 'Run', ctx: ['editor'],
    keys: ['Shift-Enter'], inst: true, available: _has('runCell'),
    run: _onSel(t => { if (_runnable(t.cell)) _fn('runCell', t.id); }) });
R({ id: 'cell.runAdvance', label: 'Run selected cell and select the next', group: 'Run',
    ctx: ['command'], keys: ['Shift-Enter'], available: _has('runCell'),
    // Only a plain code cell has the always-on editor `runCell` reads; a markdown or `@bind` cell has
    // nothing to run, so the key just advances.
    run: _onSel(t => {
      const ran = _runnable(t.cell) ? window.runCell(t.id) : Promise.resolve();
      Promise.resolve(ran).then(() => _advance(t.id));
    }) });
R({ id: 'cell.runAndAdd', label: 'Run selected cell and add one below', group: 'Run',
    ctx: ['command', 'editor'], keys: ['Mod-Shift-Enter'], inst: true, available: _has('runCell', 'addCell'),
    run: _onSel(t => {
      const ran = _runnable(t.cell) ? window.runCell(t.id) : Promise.resolve();
      Promise.resolve(ran).then(() => _fn('addCell', t.id, 'code', false, true));
    }) });
R({ id: 'nb.cancel', label: 'Cancel the running cell', group: 'Run', ctx: ['global', 'editor'],
    available: _has('cancelRun'), run: () => _fn('cancelRun') });
R({ id: 'nb.rebuild', label: 'Rebuild (fresh namespace)', group: 'Run', ctx: ['command'],
    available: _has('resetAll'), run: () => _fn('resetAll') });
R({ id: 'nb.restartWorker', label: 'Restart worker', group: 'Run', ctx: ['command'],
    available: _has('restartWorker'), run: () => _fn('restartWorker') });
R({ id: 'nb.reload', label: 'Reload from disk', group: 'Run', ctx: ['command'],
    available: _has('reload'), run: () => _fn('reload') });

// Is this a cell `runCell` can actually run? (A `@bind` cell's value comes from its controls.)
function _runnable(c) {
  return !!(c && c.kind === 'code' && !(window.hasBinds && window.hasBinds(c)));
}
// Move the selection one cell down — what ⇧⏎ does on a cell with nothing to execute.
function _advance(id) {
  const ids = (window.slateCellIds && window.slateCellIds()) || [];
  const i = ids.indexOf(id);
  if (i >= 0 && i < ids.length - 1) _fn('selectCell', ids[i + 1], true);
}

// ── Navigating & selecting ────────────────────────────────────────────────────
// The motions are written against the id list rather than the DOM so they behave identically whether
// a cell is scrolled into view or not.
const _step = (delta, extend) => (t) => {
  const ids = (window.slateCellIds && window.slateCellIds()) || [];
  if (!ids.length) return;
  const i = t.id ? ids.indexOf(t.id) : -1;
  if (i < 0) { _fn('selectCell', delta > 0 ? ids[0] : ids[ids.length - 1], true); return; }
  const j = i + delta;
  if (j < 0 || j >= ids.length) return;
  extend ? _fn('slateSelectRangeTo', ids[j], true) : _fn('selectCell', ids[j], true);
};
R({ id: 'cell.next', label: 'Select next cell', group: 'Navigate', ctx: ['command'],
    keys: ['ArrowDown', 'j'], run: _step(1, false) });
R({ id: 'cell.prev', label: 'Select previous cell', group: 'Navigate', ctx: ['command'],
    keys: ['ArrowUp', 'k'], run: _step(-1, false) });
R({ id: 'cell.extendNext', label: 'Extend selection to next cell', group: 'Navigate', ctx: ['command'],
    keys: ['Shift-ArrowDown', 'Shift-j'], run: _step(1, true) });
R({ id: 'cell.extendPrev', label: 'Extend selection to previous cell', group: 'Navigate', ctx: ['command'],
    keys: ['Shift-ArrowUp', 'Shift-k'], run: _step(-1, true) });
R({ id: 'cell.first', label: 'Select first cell', group: 'Navigate', ctx: ['command'],
    run: () => { const a = (window.slateCellIds && window.slateCellIds()) || []; if (a.length) _fn('selectCell', a[0], true); } });
R({ id: 'cell.last', label: 'Select last cell', group: 'Navigate', ctx: ['command'],
    run: () => { const a = (window.slateCellIds && window.slateCellIds()) || []; if (a.length) _fn('selectCell', a[a.length - 1], true); } });
R({ id: 'nav.back', label: 'Back (selected-cell history)', group: 'Navigate', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-ArrowLeft'], available: _has('navBack'), run: () => _fn('navBack') });
R({ id: 'nav.forward', label: 'Forward (selected-cell history)', group: 'Navigate', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-ArrowRight'], available: _has('navFwd'), run: () => _fn('navFwd') });

// ── Editing cells ─────────────────────────────────────────────────────────────
R({ id: 'cell.edit', label: 'Edit selected cell', group: 'Cells', ctx: ['command'],
    keys: ['Enter'], available: _has('enterEdit'), run: _onSel(t => _fn('enterEdit', t.id)) });
R({ id: 'cell.addAbove', label: 'Add code cell above', group: 'Cells', ctx: ['command'],
    keys: ['a'], available: _has('addCell'), run: t => _fn('addCell', t.id || '', 'code', true) });
R({ id: 'cell.addBelow', label: 'Add code cell below', group: 'Cells', ctx: ['command'],
    keys: ['b'], available: _has('addCell'), run: t => _fn('addCell', t.id || '', 'code', false) });
R({ id: 'cell.addMarkdown', label: 'Add markdown cell below', group: 'Cells', ctx: ['command'],
    available: _has('addCell'), run: t => _fn('addCell', t.id || '', 'md') });
R({ id: 'cell.addWeb', label: 'Add web cell (HTML/CSS/JS widget)', group: 'Cells', ctx: ['command'],
    available: _has('addCell'), run: t => _fn('addCell', t.id || '', 'web') });
R({ id: 'cell.addTool', label: 'Add tool call cell', group: 'Cells', ctx: ['command'],
    available: _has('addCell'), run: t => _fn('addCell', t.id || '', 'tool') });
R({ id: 'cell.delete', label: 'Delete selected cell(s)', group: 'Cells', ctx: ['command'],
    keys: ['d d'], available: _has('delCell'), run: _onSel(t => _fn('delCell', t.id)) });
R({ id: 'cell.copy', label: 'Copy selected cell(s)', group: 'Cells', ctx: ['command'],
    keys: ['c'], available: _has('copyCells'), run: () => _fn('copyCells') });
R({ id: 'cell.cut', label: 'Cut selected cell(s)', group: 'Cells', ctx: ['command'],
    keys: ['x'], available: _has('cutCells'), run: () => _fn('cutCells') });
R({ id: 'cell.paste', label: 'Paste cell(s) below', group: 'Cells', ctx: ['command'],
    keys: ['v'], available: _has('pasteCells'), run: () => _fn('pasteCells') });
R({ id: 'cell.moveUp', label: 'Move selected cell up', group: 'Cells', ctx: ['command'],
    keys: ['Alt-ArrowUp'], available: _has('moveCell'), run: _onSel(t => _fn('moveCell', t.id, 'up')) });
R({ id: 'cell.moveDown', label: 'Move selected cell down', group: 'Cells', ctx: ['command'],
    keys: ['Alt-ArrowDown'], available: _has('moveCell'), run: _onSel(t => _fn('moveCell', t.id, 'down')) });
R({ id: 'cell.merge', label: 'Merge selected cell with the one below', group: 'Cells', ctx: ['command'],
    keys: ['Shift-m'], available: _has('mergeBelow'), run: _onSel(t => _fn('mergeBelow', t.id)) });
R({ id: 'cell.split', label: 'Split selected cell at the cursor', group: 'Cells', ctx: ['command', 'editor'],
    keys: ['Mod-Shift--'], inst: true, available: _has('splitCell'),
    run: _onSel(t => { if ((window.editors || {})[t.id]) _fn('splitCell', t.id); }) });
const _toKind = kind => _onSel(t => { if (t.cell && t.cell.kind !== kind) _fn('toggleType', t.id, kind); });
R({ id: 'cell.toMarkdown', label: 'Convert selected to markdown', group: 'Cells', ctx: ['command'],
    keys: ['m'], available: _has('toggleType'), run: _toKind('md') });
R({ id: 'cell.toCode', label: 'Convert selected to code', group: 'Cells', ctx: ['command'],
    keys: ['y'], available: _has('toggleType'), run: _toKind('code') });
R({ id: 'cell.toWeb', label: 'Convert selected to web (HTML/CSS/JS)', group: 'Cells', ctx: ['command'],
    keys: ['w'], available: _has('toggleType'), run: _toKind('web') });
R({ id: 'cell.toTool', label: 'Convert selected to tool call', group: 'Cells', ctx: ['command'],
    available: _has('toggleType'), run: _toKind('tool') });
R({ id: 'cell.deps', label: 'Show the dependency chain of the selected cell', group: 'Cells',
    ctx: ['command'], available: _has('toggleDeps'), run: _onSel(t => _fn('toggleDeps', t.id)) });
R({ id: 'cell.collapse', label: 'Fold / unfold the selected cell', group: 'Cells', ctx: ['command'],
    available: _has('toggleCollapse'), run: _onSel(t => _fn('toggleCollapse', t.id)) });
R({ id: 'cell.toggleCode', label: 'Hide / show the selected cell’s code', group: 'Cells',
    ctx: ['command'], available: _has('toggleHideCode'), run: _onSel(t => _fn('toggleHideCode', t.id)) });
R({ id: 'cell.trace', label: 'Trace values in the selected cell', group: 'Cells', ctx: ['command'],
    available: _has('toggleTrace'), run: _onSel(t => _fn('toggleTrace', t.id)) });
// Notebook-level undo, as distinct from the editor's text undo. `global` but NOT `editor`, which is how
// ⌘Z keeps deferring to CodeMirror while a cell is being typed in; `command` as well, so a preset can
// put a BARE key on it — Jupyter's `z` and vim's `u` both live there, and a bare chord is filtered out
// of `global` automatically (it would eat ordinary typing).
R({ id: 'nb.undo', label: 'Undo', group: 'Cells', ctx: ['global', 'command'],
    keys: ['Mod-z'], available: _has('undoNb'), run: () => _fn('undoNb') });
R({ id: 'nb.redo', label: 'Redo', group: 'Cells', ctx: ['global', 'command'],
    keys: ['Mod-Shift-z'], available: _has('redoNb'), run: () => _fn('redoNb') });

// Escape in command mode: collapse a raw-source overlay left open by the Escape that brought you
// here, then collapse a multi-selection down to the active cell. Closing the overlay goes through
// `toggleSource`, so a changed source is COMMITTED rather than dropped.
//
// It DECLINES when there is neither an overlay nor a multi-selection, which keeps Escape reaching the
// docs dock and anything else treating it as "dismiss the innermost thing".
R({ id: 'cell.dismiss', label: 'Close source overlay / collapse the selection', group: 'Cells',
    ctx: ['command'], keys: ['Escape'], hidden: true, soft: true,
    run: _onSel(t => {
      if (window.slateSrcOpen && window.slateSrcOpen(t.id)) {
        _fn('toggleSource', t.id, t.cell && t.cell.kind === 'md' ? 'markdown' : 'julia');
        return true;
      }
      if (t.ids.length > 1) { _fn('selectCell', t.id); return true; }
      return false;
    }) });

// ── Panels, views, dialogs ────────────────────────────────────────────────────
R({ id: 'view.palette', label: 'Command palette', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-k'], available: _has('openPalette'), run: () => _fn('slateTogglePalette') });
R({ id: 'view.docs', label: 'Search docs…', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-k'], available: _has('openDocsAtCursor'), run: () => _fn('openDocsAtCursor') });
R({ id: 'view.agent', label: 'Toggle agent panel', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-a'], available: _has('toggleAgent'), run: () => _fn('toggleAgent') });
R({ id: 'view.controls', label: 'Toggle controls palette', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-f'], available: _has('togglePalette'), run: () => _fn('togglePalette') });
R({ id: 'view.toc', label: 'Table of contents', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-l'], available: _has('toggleTOC'), run: () => _fn('toggleTOC') });
R({ id: 'view.dag', label: 'Pipeline DAG (dataflow graph)', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-g'], available: _has('toggleDag'), run: () => _fn('toggleDag') });
R({ id: 'view.search', label: 'Find across cells', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-f'], available: _has('slateSearchOpen'), run: () => _fn('slateSearchOpen') });
R({ id: 'view.replace', label: 'Find & replace across cells', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Alt-f'], available: _has('slateSearchOpen'), run: () => _fn('slateSearchOpen', true) });
// Both are SOFT: they decline unless the find bar is actually open. ⌘G then falls through to the
// browser's own Find Again with the bar shut, and ⇧⌘G reaches the dependency graph, which also holds
// that chord.
R({ id: 'view.searchNext', label: 'Next search hit', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-g'], soft: true, available: _has('slateSearchStepKey'),
    run: () => window.slateSearchStepKey(false) });
R({ id: 'view.searchPrev', label: 'Previous search hit', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-g'], soft: true, available: _has('slateSearchStepKey'),
    run: () => window.slateSearchStepKey(true) });
R({ id: 'view.packages', label: 'Packages…', group: 'Panels', ctx: ['command'],
    available: _has('togglePackages'), run: () => _fn('togglePackages') });
R({ id: 'view.workerLog', label: 'Worker log', group: 'Panels', ctx: ['command'],
    available: _has('toggleLog'), run: () => _fn('toggleLog') });
R({ id: 'view.history', label: 'History…', group: 'Panels', ctx: ['command'],
    available: _has('toggleHistory'), run: () => _fn('toggleHistory') });
R({ id: 'view.extensions', label: 'Extensions…', group: 'Panels', ctx: ['command'],
    available: _has('openExtensions'), run: () => _fn('openExtensions') });
R({ id: 'view.sessions', label: 'Sign in to a host… (cluster / region authentication)',
    group: 'Panels', ctx: ['command'],
    available: _has('openSessions'), run: () => _fn('openSessions') });
// `appSettingsToggle` only exists in app mode, and it is checked FIRST there for a reason: app mode
// leaves `openSettings` defined but replaced with a no-op (appmode.js `disableAuthoringOpeners`), so
// preferring it would silently do nothing. The app's display popover is what Settings means to a reader.
R({ id: 'view.settings', label: 'Settings…', group: 'Panels', ctx: ['global', 'editor'],
    available: () => typeof window.appSettingsToggle === 'function' || typeof window.openSettings === 'function',
    run: () => (window.appSettingsToggle ? window.appSettingsToggle() : _fn('openSettings')) });
R({ id: 'view.keymap', label: 'Keyboard shortcuts…', group: 'Panels', ctx: ['global', 'editor'],
    available: _has('openKeymapEditor'), run: () => _fn('openKeymapEditor') });
R({ id: 'view.zen', label: 'Zen mode (hide code — reading view)', group: 'Panels', ctx: ['command'],
    available: _has('toggleZen'), run: () => _fn('toggleZen') });
R({ id: 'view.present', label: 'Present (slideshow)', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-p'], available: _has('enterPresent'), run: () => _fn('enterPresent') });
R({ id: 'view.presenter', label: 'Open presenter window', group: 'Panels', ctx: ['command'],
    available: _has('openPresenter'), run: () => _fn('openPresenter') });
R({ id: 'view.scratch', label: 'Scratchpad — try something out', group: 'Panels', ctx: ['global', 'editor'],
    keys: ['Mod-Shift-s'], available: _has('openWorkbookScratch'), run: () => _fn('openWorkbookScratch') });
R({ id: 'view.export', label: 'Export… (HTML · PDF · Markdown · standalone)', group: 'Panels',
    ctx: ['command'], available: _has('openExport'), run: () => _fn('openExport') });
R({ id: 'view.publish', label: 'Publish… (to GitHub Pages)', group: 'Panels', ctx: ['command'],
    available: _has('openPublish'), run: () => _fn('openPublish') });
R({ id: 'view.hideCode', label: 'Hide all code (show only output)', group: 'Panels', ctx: ['command'],
    available: _has('hideAllCode'), run: () => _fn('hideAllCode', true) });
R({ id: 'view.showCode', label: 'Show all code', group: 'Panels', ctx: ['command'],
    available: _has('hideAllCode'), run: () => _fn('hideAllCode', false) });
R({ id: 'view.hidePlotCode', label: 'Hide code for all plot cells', group: 'Panels', ctx: ['command'],
    available: _has('hideAllPlotCode'), run: () => _fn('hideAllPlotCode', true) });
R({ id: 'view.showPlotCode', label: 'Show code for all plot cells', group: 'Panels', ctx: ['command'],
    available: _has('hideAllPlotCode'), run: () => _fn('hideAllPlotCode', false) });
R({ id: 'view.files', label: 'Files… (project browser)', group: 'Panels', ctx: ['command'],
    available: _has('toggleFiles'), run: () => _fn('toggleFiles') });
R({ id: 'view.notebooks', label: 'All notebooks', group: 'Panels', ctx: ['command'],
    run: () => { location.href = '/'; } });

// ── Inside the editor ─────────────────────────────────────────────────────────
// Slate's own in-editor bindings. CM6's text-editing defaults (word motion, indent, bracket matching)
// are not listed here and are not remappable from this panel. Those come with the editor keymap picked
// in Settings → Editing (default / vim / emacs), which brings a complete set of its own.
//
// `run` takes the CM6 view as its second argument here (keymap.js passes it through), because these
// act on the editor rather than on the notebook.
//
// Two of them also have a chord in CM6's own default keymap: ⌘/ for comment-toggle and ⌃Space for
// completion. That copy belongs to the editor keymap, so changing the chord here ADDS one rather than
// moving it. The labels say so, since otherwise the old key still working looks like a bug.
R({ id: 'editor.comment', label: 'Toggle comment (adds to the editor keymap’s own ⌘/)', group: 'Editor',
    ctx: ['editor'], keys: ['Mod-/', 'Ctrl-/'], hidden: true, run: () => {} });
R({ id: 'editor.complete', label: 'Trigger autocomplete (adds to the editor keymap’s own ⌃Space)',
    group: 'Editor', ctx: ['editor'], keys: ['Ctrl-Space', 'Alt-Space'], hidden: true, run: () => {} });
// These two are Slate's alone, so their chords move rather than multiply. `selectNextOccurrence` lives
// in CM6's searchKeymap, which only the Files-tab editor is given, and go-to-definition is Slate's own
// index lookup. Go-to-definition ships unbound; ⌘-click is how people reach it.
R({ id: 'editor.nextOccurrence', label: 'Select next occurrence', group: 'Editor', ctx: ['editor'],
    keys: ['Mod-d'], hidden: true, run: () => {} });
R({ id: 'editor.gotoDefinition', label: 'Go to definition of the symbol at the cursor', group: 'Editor',
    ctx: ['editor'], hidden: true, run: () => {} });

// The four above are declarations. The editor owns their implementations, which need the CM6 view and
// its state, and editor.js fills in each `run` as it builds its keymap. Declaring them here puts them
// in the Keyboard panel and keeps their chords in the one keymap everything reads.
window.slateBindEditorCommand = (id, run) => {
  const c = _CMDS.get(id);
  if (c) c.run = run;
};

// ── Jump to a cell by name ────────────────────────────────────────────────────
// Not a keybinding — a palette-only entry per cell, so the palette's list stays one source. Cells
// change constantly, so these are generated on demand rather than registered.
window.slateCellCommands = () => {
  const ids = (window.slateCellIds && window.slateCellIds()) || [];
  return ids.map(id => ({ id: 'cell.jump/' + id, label: 'Jump to cell: ' + id, group: 'Cells',
                          tag: 'cell', run: () => _fn('selectCell', id, true) }));
};
