// CodeMirror 6 notebook editor (native — no CM5 compat). `window.editors[id]` is the EditorView.
// Highlighting is Lezer-Julia (cm6.bundle.js); completion, snippets, bracket-close, comment-toggle
// and indentation are CM6 built-ins. Clean helpers (edText/edFocus/markErrorLine/…) are what the
// rest of the UI calls — no `.getValue()`/`.getCursor()` emulation.
(function () {
  const CM = window.CM6;
  if (!CM) { console.error('CM6 bundle missing'); return; }
  const { EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect, Decoration,
          keymap, defaultKeymap, history, historyKeymap, indentWithTab, toggleComment,
          indentUnit, bracketMatching, indentOnInput, syntaxTree, drawSelection,
          syntaxHighlighting, julia, juliaHighlightStyle, juliaThemes,
          autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap,
          completionStatus, startCompletion, acceptCompletion, snippet } = CM;

  // ── syntax palette (Settings → Editor syntax). A Compartment so the choice hot-swaps across all
  //    live editors without rebuilding the views. `slateSyntaxTheme` persists the selection. ──────
  const themeComp = new Compartment();
  const SYNTAX_THEMES = juliaThemes || { 'dark-plus': juliaHighlightStyle };
  window._syntaxThemeNames = Object.keys(SYNTAX_THEMES);
  const curSyntaxTheme = () => {
    const n = localStorage.getItem('slateSyntaxTheme');
    return (n && SYNTAX_THEMES[n]) ? n : 'dark-plus';
  };
  const styleFor = name => syntaxHighlighting(SYNTAX_THEMES[name] || juliaHighlightStyle);
  window.setSyntaxTheme = (name) => {
    if (!SYNTAX_THEMES[name]) return;
    localStorage.setItem('slateSyntaxTheme', name);
    for (const v of Object.values(window.editors || {})) {
      try { v.dispatch({ effects: themeComp.reconfigure(styleFor(name)) }); } catch (_) {}
    }
  };

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

  // A method completion's server `text` is the full REPL signature WITH location, e.g.
  //   "diag(B::BitMatrix; k) @ LinearAlgebra ~/…/bitarray.jl:79"
  // We split off the ` @ Module path` tail → a clean signature + the defining module, and turn the
  // arg list into a CM6 snippet (tab-through placeholders) instead of pasting the raw text.
  function parseMethod(text) {
    const at = text.indexOf(' @ ');
    const sig = (at >= 0 ? text.slice(0, at) : text).trim();
    const tail = at >= 0 ? text.slice(at + 3).trim() : '';          // "LinearAlgebra ~/…:79"
    const mod = tail.split(/\s+/)[0] || '';
    const op = sig.indexOf('('), cl = sig.lastIndexOf(')');
    const name = op >= 0 ? sig.slice(0, op) : sig;
    const inner = (op >= 0 && cl > op) ? sig.slice(op + 1, cl) : '';
    return { sig, mod, name, args: _splitArgs(inner) };   // full arg specs (e.g. "A::AbstractMatrix")
  }
  // Split an arg list on top-level `,`/`;` (kwargs), respecting (), [], {} nesting so a type like
  // `Array{Int,2}` isn't torn apart.
  function _splitArgs(s) {
    const out = []; let depth = 0, cur = '';
    for (const ch of s) {
      if ('([{'.includes(ch)) depth++;
      else if (')]}'.includes(ch)) depth--;
      if ((ch === ',' || ch === ';') && depth === 0) { if (cur.trim()) out.push(cur.trim()); cur = ''; }
      else cur += ch;
    }
    if (cur.trim()) out.push(cur.trim());
    return out;
  }

  // Lazy docstring preview shown in CM6's native `.cm-completionInfo` card (restores the old
  // _showHintDoc). Fetches /api/help for the option's base name; methods carry a signature in
  // their label, so strip the arg list first. Returns a DOM node or null (no popup card).
  function docPreview(name) {
    const base = name;
    if (!base || !/^[A-Za-z_@]/.test(base)) return null;   // skip operators/keys with no doc
    return async () => {
      try {
        const r = await (await fetch(_apipath('/api/help') + '?name=' + encodeURIComponent(base))).json();
        if (!r || !r.docHtml) return null;
        const dom = document.createElement('div');
        dom.className = 'docmd';
        // markdown_html puts a `\n` between block tags; as text nodes those render as ~16px
        // anonymous line boxes (huge gaps in the small card). Strip ONLY tag-to-tag newlines
        // (keep real inline spaces, which never contain a newline).
        dom.innerHTML = r.docHtml.replace(/>\s*\n\s*</g, '><');
        return dom;
      } catch (_) { return null; }
    };
  }

  async function juliaComplete(ctx) {
    const word = ctx.matchBefore(/[A-Za-z_][\w!]*$/);
    const dot = ctx.matchBefore(/\.$/);
    const bs = ctx.matchBefore(/\\[A-Za-z\d^_]*$/);             // LaTeX/emoji: \pi → π
    if (!ctx.explicit && !word && !dot && !bs) return null;
    if (word && JL_KEYWORDS.has(word.text)) return null;        // finished keyword → no popup
    const node = syntaxTree(ctx.state).resolveInner(ctx.pos, -1);
    if (!ctx.explicit && /Comment|String|Char/.test(node.name)) return null;
    const code = ctx.state.doc.toString();
    // _byteLen/_apipath/_charFromByte are global `const`s from core.js (NOT window props — classic
    // scripts don't attach const/let to window), so reference them bare via the scope chain.
    const bytePos = _byteLen(code.slice(0, ctx.pos));
    let d;
    try {
      d = await (await fetch(_apipath('/api/complete'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, pos: bytePos }),
      })).json();
    } catch (_) { return null; }
    const raw = d.completions || [];
    if (!raw.length) return null;
    const from = _charFromByte(code, d.from);
    const to = _charFromByte(code, d.to);
    const options = raw.map(it => {
      const o = (it && typeof it === 'object') ? it : { text: String(it) };
      const text = o.text != null ? o.text : (o.label != null ? o.label : String(it));
      if (o.kind === 'method') {
        // Clean label (no location), module as detail, full arg specs as tab-through snippet fields
        // (e.g. `A::AbstractMatrix`). Braces in parametric types are escaped for the snippet syntax.
        const m = parseMethod(text);
        const esc = s => s.replace(/[{}]/g, '\\$&');                  // \{ \} are the only field escapes
        // Trailing ${} is the final tab-stop: after the last arg, Tab lands the cursor just past
        // the closing paren (CM6 has no implicit end field, so without this the last Tab indents).
        const tmpl = m.name + '(' + m.args.map(a => '${' + esc(a) + '}').join(', ') + ')${}';
        return {
          label: m.sig, detail: m.mod || 'method', type: 'function', info: docPreview(m.name),
          apply: (view, completion, from, to) => {
            // The server range covers just the name; swallow the `(` the user typed AND the `)`
            // that closeBrackets auto-inserted, so the snippet's own `()` isn't doubled.
            let end = to;
            if (view.state.sliceDoc(end, end + 1) === '(') { end++; if (view.state.sliceDoc(end, end + 1) === ')') end++; }
            snippet(tmpl)(view, completion, from, end);
          },
        };
      }
      const opt = { label: text, type: _cmType(o.kind) };
      // LaTeX/emoji: a partial query shows the NAME (`\alpha`, filterable) but the server attaches
      // the resolved symbol as `o.apply` → insert the character in ONE step. An exact query already
      // returns the symbol as `text` (no `o.apply`). Show the symbol as the detail (`\alpha  α`);
      // for the exact case the label IS the symbol, so just tag it `tex`.
      if (o.kind === 'latex') { opt.apply = o.apply || text; opt.detail = o.apply || 'tex'; }
      else opt.info = docPreview(text);    // lazy docstring card
      return opt;
    });
    // LaTeX path: the label is the symbol (α), which does NOT fuzzy-match the typed `\alpha`, so
    // CM6 would filter every option out. Disable filtering (the server already narrowed by prefix)
    // and omit `validFor` so each keystroke re-queries the server. Normal completions keep CM6's
    // fuzzy filter + `validFor` (no backslash needed — that span is handled here).
    if (bs) return { from, to, options, filter: false };
    return { from, to, options, validFor: /^[\w!]*$/ };
  }

  // Tab: accept an open completion → else indent when the cursor is in leading whitespace or a
  // selection is active (block indent) → else trigger completion. This way `diag(`+Tab completes
  // the call (after `(` isn't whitespace) while Tab at line start still indents. Returns false to
  // fall through to indentWithTab when we choose to indent.
  function tabComplete(v) {
    if (completionStatus(v.state) === 'active') return acceptCompletion(v);
    const sel = v.state.selection.main;
    if (!sel.empty) return false;                                   // selection → indent block
    const line = v.state.doc.lineAt(sel.from);
    if (/^\s*$/.test(v.state.sliceDoc(line.from, sel.from))) return false;   // only whitespace before → indent
    return startCompletion(v);
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
    const lang = opts.markdown ? [] : [julia(), themeComp.of(styleFor(curSyntaxTheme()))];
    const cellKeys = (opts.keys || []).map(k => ({ key: k.key, run: () => { k.run(); return true; } }));
    const view = new EditorView({
      parent,
      doc: opts.doc || '',
      extensions: [
        history(), drawSelection(), bracketMatching(), closeBrackets(), indentOnInput(),
        indentUnit.of('    '), EditorState.tabSize.of(4), errField, flashField,
        ...lang,
        autocompletion({ override: [juliaComplete], icons: true }),
        keymap.of([
          ...completionKeymap,                  // popup nav/close (Escape) takes precedence over cell keys
          ...cellKeys,                          // a cell's own Escape (e.g. cancelSource) wins over the blur below
          { key: 'Escape', run: (v) => { v.contentDOM.blur(); return true; } },   // exit edit → command mode
          // ⌘⇧K = help (app shortcut). Bind it here so CM6's defaultKeymap `deleteLine` doesn't eat it.
          { key: 'Mod-Shift-k', run: () => { window.openDocsAtCursor && window.openDocsAtCursor(); return true; } },
          { key: 'Mod-/', run: toggleComment }, { key: 'Ctrl-/', run: toggleComment },
          // Tab: accept the open completion → else trigger one when a word/`\`/`.` precedes the
          // cursor → else fall through to indent. Restores CM5's Tab-to-complete. (macOS eats
          // Ctrl-Space, so Alt-Space is the reliable manual trigger; Ctrl-Space kept for others.)
          { key: 'Tab', run: tabComplete },
          { key: 'Ctrl-Space', run: startCompletion }, { key: 'Alt-Space', run: startCompletion },
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
