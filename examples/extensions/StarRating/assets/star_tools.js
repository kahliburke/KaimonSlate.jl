// StarRating's package-global front-end — the parts that aren't tied to a single `@bind`. Shipped as a
// classic (non-module) script and injected once by Slate from the package's `__slate_frontend` hook via
// `provide_frontend!` (no boot cell). It contributes TWO of the extension seams:
//
//   1. window._starRatingInsert(cellId) — the helper a per-cell TOOLBAR ACTION calls (registered in
//      Julia via `register_cell_action!`): it scaffolds a `@bind rating Stars()` snippet into the cell's
//      editor. Kept here (not inline in the action's onclick) so the action stays a one-liner.
//   2. An EDITOR EXTENSION (`slateRegisterEditorExtension`): a CodeMirror keymap, on code cells only,
//      that inserts a ★ glyph at the cursor with Ctrl-Alt-8 — the smallest useful editor add-on.
//
// Both guard against racing the core bundle (poll briefly for the host seam), mirroring how a cell
// action's own injected script waits for `window.slateRegisterCellAction`.
(function () {
  // (1) Toolbar-action helper: append a Stars() scaffold to a cell and focus it. `window.editors[id]`
  // is the cell's CodeMirror EditorView (see editor.js).
  window._starRatingInsert = function (cellId) {
    var v = (window.editors || {})[cellId];
    if (!v) return;
    var end = v.state.doc.length;
    var snip = (end > 0 ? "\n" : "") + "@bind rating Stars(; max = 5)\nrating";
    v.dispatch({ changes: { from: end, insert: snip }, selection: { anchor: end + snip.length }, scrollIntoView: true });
    v.focus();
  };

  // (2) Editor extension: a CM6 keymap that inserts ★ at the cursor. `ctx = { markdown, cellId }`;
  // return [] for markdown cells so it only augments code editors. `window.CM6` is the host's bundled
  // CodeMirror surface (keymap, EditorView, …) — an extension MUST build against it, not its own copy.
  var registerEditorExt = function () {
    if (!window.slateRegisterEditorExtension || !window.CM6) return false;
    window.slateRegisterEditorExtension(function (ctx) {
      if (ctx.markdown) return [];
      return window.CM6.keymap.of([{
        key: "Ctrl-Alt-8",   // 8 = '*' — insert a star at the cursor
        run: function (view) {
          var at = view.state.selection.main.head;
          view.dispatch({ changes: { from: at, insert: "★" }, selection: { anchor: at + 1 } });
          return true;
        }
      }]);
    });
    return true;
  };
  if (!registerEditorExt()) {
    var n = 0, t = setInterval(function () { if (registerEditorExt() || ++n > 50) clearInterval(t); }, 100);
  }
})();
