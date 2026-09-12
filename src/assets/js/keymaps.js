// ── Keymap presets ────────────────────────────────────────────────────────────
// Four complete keymaps, and the tables saying which chords the browser will never let us have.
//
// A preset is a SPARSE OVERLAY. It lists only the commands where that platform's convention differs
// from Slate's; everything else keeps the `keys` declared on the command in commands.js. A command
// added later is therefore reachable under every preset without touching this file.
//
// A command listed with `[]` is deliberately UNBOUND in that preset. Jupyter has no "run stale cells",
// and leaving Slate's ⌘↵ in place there would collide with Jupyter's own ⌘↵ (run this cell).
//
// Chords are written platform-neutrally with `Mod-` (⌘ on macOS, Ctrl elsewhere), lowercase letters
// and an explicit `Shift-`. That is CodeMirror's own normal form, so the same string can be handed to
// CM6's keymap for the in-editor context. See keymap.js for the parser.

window.SLATE_KEYMAP_PRESETS = [
  {
    name: 'slate',
    label: 'Slate (default)',
    about: 'Slate’s own bindings: Jupyter-style command mode with ⌘-chords for the panels.',
    bindings: {},          // the defaults declared on each command — the baseline the others overlay
  },
  {
    name: 'vscode',
    label: 'VS Code',
    about: 'VS Code’s chords where one exists: ⌘⇧P palette, ⌘⇧O outline, ⌃↵ run cell, ⌥↵ run and add.',
    bindings: {
      'view.palette':   ['Mod-Shift-p', 'Mod-p'],
      'view.settings':  ['Mod-,'],
      'view.search':    ['Mod-Shift-f', 'Mod-f'],
      'view.toc':       ['Mod-Shift-o'],          // "go to symbol in file" — the outline
      'view.workerLog': ['Mod-Shift-u'],          // the Output panel
      'view.packages':  ['Mod-Shift-x'],          // the Extensions view
      'view.files':     ['Mod-Shift-e'],          // the Explorer
      'view.zen':       ['Mod-k z'],              // ⌘K ⌘Z in VS Code; the second stroke is bare here
      // ⌘⇧F and ⌘⇧P are claimed above, so the two Slate panels that held them move to chords VS Code
      // leaves free. A preset that reassigns a chord has to rehome whatever had it, or one of the two
      // commands never fires. test/js/keymap_resolve.mjs asserts every preset is conflict-free.
      'view.controls':  ['Mod-Shift-y'],
      'view.present':   ['Mod-k p'],
      // VS Code notebooks: ⌃↵ runs and stays, ⇧↵ runs and advances, ⌥↵ runs and inserts below.
      'cell.run':        ['Mod-Enter'],
      'cell.runAdvance': ['Shift-Enter'],
      'cell.runAndAdd':  ['Alt-Enter'],
      'cell.split':      ['Mod-Shift--'],
      'cell.delete':     ['d d', 'Mod-Shift-Backspace'],
      'nb.redo':         ['Mod-Shift-z', 'Mod-y'],   // ⌘Y is the Windows/VS Code redo
      // ⌘↵ is run-cell above, so run-stale moves to the chord VS Code leaves free.
      'nb.runStale':     ['Mod-Alt-Enter'],
    },
  },
  {
    name: 'jupyter',
    label: 'Jupyter / Colab',
    about: 'Classic Jupyter command mode verbatim: ⌃↵ run, ⇧↵ run and advance, z undo, ii interrupt, 00 restart.',
    bindings: {
      // JupyterLab's own palette chord is ⌘⇧C, which Chrome keeps for the devtools element picker —
      // so it is unusable in a browser page and ⌘⇧F (Jupyter's own second binding) is the one we can
      // actually honour. `view.controls` gives that chord up in exchange.
      'view.palette':    ['Mod-Shift-f'],
      'view.controls':   ['Mod-Shift-y'],
      'cell.run':        ['Mod-Enter'],
      'cell.runAdvance': ['Shift-Enter'],
      'cell.runAndAdd':  ['Alt-Enter'],
      'nb.runStale':     [],                  // no Jupyter equivalent, and ⌘↵ is taken above
      'nb.runAll':       [],
      // Jupyter's command mode owns bare z / ⇧Z for the notebook-level undo, alongside the ⌘-chords.
      'nb.undo':         ['Mod-z', 'z'],
      'nb.redo':         ['Mod-Shift-z', 'Shift-z'],
      'nb.cancel':       ['i i'],
      'nb.restartWorker': ['0 0'],
      'cell.collapse':   ['o'],               // Jupyter's "toggle output"; Slate folds the cell
      'view.toc':        [],                  // JupyterLab keeps the outline in the sidebar, unbound
      'view.zen':        [],
    },
  },
  {
    name: 'vim',
    label: 'Vim-flavoured',
    about: 'Vim motions over the CELLS: hjkl-style j/k, gg/⇧G, i/o/⇧O, dd/yy/p, u and ⌃R. Pairs with the vim editor keymap.',
    bindings: {
      'cell.next':     ['j', 'ArrowDown'],
      'cell.prev':     ['k', 'ArrowUp'],
      'cell.first':    ['g g'],
      'cell.last':     ['Shift-g'],
      'cell.edit':     ['i', 'Enter'],
      'cell.addBelow': ['o'],
      'cell.addAbove': ['Shift-o'],
      'cell.delete':   ['d d'],
      'cell.copy':     ['y y'],
      'cell.cut':      [],                    // `dd` already means cut-a-line to a vim user
      'cell.paste':    ['p'],
      // `y` is the yank prefix here, so the cell-type toggles move off it and onto the shifted keys.
      'cell.toCode':   ['Shift-c'],
      'nb.undo':       ['u', 'Mod-z'],
      'nb.redo':       ['Ctrl-r', 'Mod-Shift-z'],
      'view.search':   ['/', 'Mod-f'],
      'cell.toMarkdown': ['Shift-m'],
      'cell.merge':      ['Shift-j'],         // ⇧J joins, as in vim
      'cell.extendNext': ['Shift-ArrowDown'],
      'cell.extendPrev': ['Shift-ArrowUp'],
    },
  },
];

// ── Chords the browser or the OS takes, and won't give back ────────────────────
//
// `preventDefault` is not a general escape hatch. A browser keeps a handful of chords for itself above
// the page (new tab, close window, the address bar, the devtools) and a page listener either never
// sees them or sees them too late to matter. Binding one produces a shortcut that does nothing, or
// closes the tab, depending on the browser. The panel REFUSES these rather than warning about them.
//
// Written as normalized chords with `Mod-` unresolved; the check resolves per platform.
window.SLATE_KEYS_RESERVED = {
  // Taken everywhere. Tab/window lifecycle plus the devtools chords, none of which reach the page.
  all: [
    'Mod-t', 'Mod-n', 'Mod-w', 'Mod-q',
    'Mod-Shift-t', 'Mod-Shift-n', 'Mod-Shift-w', 'Mod-Shift-q',
    'Mod-Shift-i', 'Mod-Shift-j', 'Mod-Shift-c',          // devtools: inspect / console / picker
    'Mod-Alt-i', 'Mod-Alt-j', 'Mod-Alt-c',
    'F12',
    'Mod-Tab', 'Mod-Shift-Tab', 'Alt-Tab',                 // window/tab cycling
    'Mod-1', 'Mod-2', 'Mod-3', 'Mod-4', 'Mod-5', 'Mod-6', 'Mod-7', 'Mod-8', 'Mod-9',
  ],
  // macOS hands these to the window server before the browser sees them.
  mac: ['Meta-m', 'Meta-h', 'Meta-Alt-h', 'Meta-Alt-ArrowLeft', 'Meta-Alt-ArrowRight'],
  // Windows/Linux equivalents.
  other: ['Alt-F4', 'Ctrl-Shift-Delete', 'Alt-ArrowLeft', 'Alt-ArrowRight'],
};

// Chords the browser uses but WILL yield on `preventDefault`. Bindable, and Slate already takes ⌘F and
// ⌘K. The panel still names them, because taking one means the browser's own version is gone while
// this page has focus.
window.SLATE_KEYS_DISCOURAGED = {
  'Mod-s': 'the browser’s Save Page',
  'Mod-p': 'the browser’s Print',
  'Mod-o': 'the browser’s Open File',
  'Mod-f': 'the browser’s Find on Page',
  'Mod-g': 'the browser’s Find Again',
  'Mod-d': 'Add Bookmark',
  'Mod-r': 'Reload',
  'Mod-Shift-r': 'Hard Reload',
  'Mod-l': 'focus the address bar',
  'Mod-u': 'View Source',
  'Mod-h': 'History',
  'Mod-j': 'Downloads',
  'Mod-y': 'History',
  'Mod-0': 'reset the page zoom',
  'Mod--': 'zoom out',
  'Mod-=': 'zoom in',
  'Mod-[': 'Back',
  'Mod-]': 'Forward',
  'Mod-Shift-p': 'the private-window shortcut (Firefox)',
  'Mod-Shift-s': 'the screenshot tool (Firefox)',
  'Mod-Shift-a': 'Search Tabs (Chrome, macOS)',
  'Mod-Shift-o': 'the Bookmark Manager',
  'F1': 'browser help',
  'F5': 'Reload',
  'F11': 'Full Screen',
};
