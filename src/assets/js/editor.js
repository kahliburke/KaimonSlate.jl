// CodeMirror 6 notebook editor (native — no CM5 compat). `window.editors[id]` is the EditorView.
// Highlighting is Lezer-Julia (cm6.bundle.js); completion, snippets, bracket-close, comment-toggle
// and indentation are CM6 built-ins. Clean helpers (edText/edFocus/markErrorLine/…) are what the
// rest of the UI calls — no `.getValue()`/`.getCursor()` emulation.
(function () {
  const CM = window.CM6;
  if (!CM) { console.error('CM6 bundle missing'); return; }
  const { EditorView, EditorState, EditorSelection, StateField, StateEffect, Decoration,
          keymap, defaultKeymap, history, historyKeymap, indentWithTab, toggleComment,
          indentUnit, bracketMatching, indentOnInput, syntaxTree, drawSelection,
          syntaxHighlighting, julia, juliaHighlightStyle,
          autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } = CM;

  window.editors = window.editors || {};

  // Complete Julia keywords — a finished one is a token, not a completion prefix (e.g. `end`).
  const JL_KEYWORDS = new Set(['baremodule', 'begin', 'break', 'catch', 'const', 'continue', 'do',
    'else', 'elseif', 'end', 'export', 'false', 'finally', 'for', 'function', 'global', 'if', 'import',
    'in', 'isa', 'let', 'local', 'macro', 'module', 'mutable', 'primitive', 'quote', 'return', 'struct',
    'true', 'try', 'type', 'using', 'where', 'while', 'abstract']);
  window._JL_KEYWORDS = JL_KEYWORDS;

  // ── completion: live Julia completions via /api/complete (REPLCompletions) ─────
  const _cmType = k => ({ method: 'function', function: 'function', type: 'type', module: 'namespace',
    macro: 'macro', keyword: 'keyword', field: 'property', kwarg: 'property', latex: 'constant' }[k] || 'variable');
  async function juliaComplete(ctx) {
    const word = ctx.matchBefore(/[A-Za-z_][\w!]*$/);
    const dot = ctx.matchBefore(/\.$/);
    const bs = ctx.matchBefore(/\\[A-Za-z\d^_]*$/);             // LaTeX/emoji: \pi → π
    if (!ctx.explicit && !word && !dot && !bs) return null;
    if (word && JL_KEYWORDS.has(word.text)) return null;        // finished keyword → no popup
    const node = syntaxTree(ctx.state).resolveInner(ctx.pos, -1);
    if (!ctx.explicit && /Comment|String|Char/.test(node.name)) return null;
    const code = ctx.state.doc.toString();
    const bytePos = window._byteLen ? window._byteLen(code.slice(0, ctx.pos)) : ctx.pos;
    let d;
    try {
      d = await (await fetch(window._apipath('/api/complete'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, pos: bytePos }),
      })).json();
    } catch (_) { return null; }
    const raw = d.completions || [];
    if (!raw.length) return null;
    const from = window._charFromByte ? window._charFromByte(code, d.from) : d.from;
    const to = window._charFromByte ? window._charFromByte(code, d.to) : d.to;
    const options = raw.map(it => {
      const o = (it && typeof it === 'object') ? it : { text: String(it) };
      const label = o.text != null ? o.text : (o.label != null ? o.label : String(it));
      const opt = { label, type: _cmType(o.kind) };
      if (o.kind === 'latex' && o.symbol) { opt.apply = o.symbol; opt.detail = o.symbol; }
      if (o.kind === 'method' && o.text) opt.detail = '()';
      return opt;
    });
    return { from, to, options, validFor: /^[\w!]*$/ };
  }

  // ── error-line decoration (replaces CM5 addLineClass) ──────────────────────────
  const setErr = StateEffect.define(), setFlash = StateEffect.define();
  const lineDeco = cls => Decoration.line({ class: cls });
  const mkField = (effect, cls) => StateField.define({
    create: () => Decoration.none,
    update(deco, tr) {
      deco = deco.map(tr.changes);
      for (const e of tr.effects) if (e.is(effect)) {
        deco = (e.value == null) ? Decoration.none
          : Decoration.set([lineDeco(cls).range(tr.state.doc.line(e.value).from)]);
      }
      return deco;
    },
    provide: f => EditorView.decorations.from(f),
  });
  const errField = mkField(setErr, 'cm-errorline');
  const flashField = mkField(setFlash, 'cm-errorline-flash');

  const _validLine = (view, n) => n >= 1 && n <= view.state.doc.lines;
  window.markErrorLine = (id, line1) => { const v = editors[id]; if (v) v.dispatch({ effects: setErr.of(_validLine(v, line1) ? line1 : null) }); };
  window.clearErrorLine = (id) => { const v = editors[id]; if (v) v.dispatch({ effects: setErr.of(null) }); };
  window.flashLine = (id, line1) => {
    const v = editors[id]; if (!v || !_validLine(v, line1)) return;
    const off = v.state.doc.line(line1).from;
    v.dispatch({ selection: { anchor: off }, effects: [setFlash.of(line1), EditorView.scrollIntoView(off, { y: 'center' })] });
    setTimeout(() => { try { v.dispatch({ effects: setFlash.of(null) }); } catch (_) {} }, 1000);
    v.focus();
  };

  // ── clean accessors the rest of the UI uses ───────────────────────────────────
  window.edText = id => { const v = editors[id]; return v ? v.state.doc.toString() : ''; };
  window.edSetText = (id, s) => { const v = editors[id]; if (v && v.state.doc.toString() !== s) v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } }); };
  window.edFocus = id => { const v = editors[id]; if (v) v.focus(); };
  window.edInsert = (id, text) => { const v = editors[id]; if (!v) return; v.dispatch(v.state.replaceSelection(text)); v.focus(); };

  // ── editor factory ─────────────────────────────────────────────────────────────
  function mkEditor(parent, opts) {
    opts = opts || {};
    const lang = opts.markdown ? [] : [julia(), syntaxHighlighting(juliaHighlightStyle)];
    const cellKeys = (opts.keys || []).map(k => ({ key: k.key, run: () => { k.run(); return true; } }));
    const view = new EditorView({
      parent,
      doc: opts.doc || '',
      extensions: [
        history(), drawSelection(), bracketMatching(), closeBrackets(), indentOnInput(),
        indentUnit.of('    '), EditorState.tabSize.of(4), errField, flashField,
        ...lang,
        autocompletion({ override: [juliaComplete], icons: false }),
        keymap.of([
          ...completionKeymap,                  // popup nav/close (Escape) takes precedence over cell keys
          ...cellKeys,
          { key: 'Mod-/', run: toggleComment }, { key: 'Ctrl-/', run: toggleComment },
          indentWithTab, ...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap,
        ]),
        EditorView.updateListener.of(u => {
          if (u.docChanged && opts.onDoc) opts.onDoc(u.state.doc.toString());
          if (u.focusChanged && opts.onFocus && u.view.hasFocus) opts.onFocus();
          if (u.focusChanged && opts.onBlur && !u.view.hasFocus) opts.onBlur();
        }),
        EditorView.theme({
          '&': { fontFamily: "'Cascadia Code','Fira Code',monospace", fontSize: '0.86rem', background: 'transparent' },
          '.cm-content': { padding: '6px 0', caretColor: 'var(--text)' },
          '.cm-cursor': { borderLeftColor: 'var(--text)' },
          '&.cm-focused': { outline: 'none' },
          '.cm-line': { padding: '0 4px' },
        }, { dark: true }),
      ],
    });
    if (opts.cellId) window.editors[opts.cellId] = view;
    return view;
  }
  window.mkEditor = mkEditor;
})();
