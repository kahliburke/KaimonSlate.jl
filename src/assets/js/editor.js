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
          syntaxHighlighting, julia, juliaHighlightStyle, juliaThemes, slateThemes, slateThemeMeta,
          autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap,
          completionStatus, startCompletion, acceptCompletion, snippet } = CM;

  // ── code-highlight theme (Settings → Editor syntax). Each theme is a COMPLETE look — token
  //    colours AND editor chrome (background, gutter, selection, active line, caret) — defined once
  //    in cm6's `slateThemes`. Two Compartments (tokens + chrome) let the choice hot-swap across all
  //    live editors without rebuilding the views. `slateSyntaxTheme` persists the selection. ──────
  const themeComp = new Compartment();    // token colours (HighlightStyle)
  const chromeComp = new Compartment();   // editor chrome (EditorView.theme)
  const wrapComp = new Compartment();     // soft line-wrap: always on for markdown (prose), opt-in for code
  // Markdown editors always soft-wrap (prose); code editors follow the `slateWrapEditor` preference.
  const _wrapCodePref = () => localStorage.getItem('slateWrapEditor') === '1';
  const _wrapExt = isMd => (isMd || _wrapCodePref()) ? EditorView.lineWrapping : [];
  // Live-toggle code-editor wrapping across every open editor (markdown stays wrapped regardless).
  window.setEditorWrap = on => {
    localStorage.setItem('slateWrapEditor', on ? '1' : '0');
    for (const v of Object.values(window.editors || {}))
      v.dispatch({ effects: wrapComp.reconfigure((v._wrapMd || on) ? EditorView.lineWrapping : []) });
  };
  const THEMES = slateThemes || { 'dark-plus': { style: juliaHighlightStyle, chrome: [] } };
  // Exposed for settings.js to build the dropdown — [{name,label}] in declared order.
  window._syntaxThemes = slateThemeMeta || Object.keys(THEMES).map(name => ({ name, label: name }));
  window._syntaxThemeNames = window._syntaxThemes.map(t => t.name);
  const curSyntaxTheme = () => {
    const n = localStorage.getItem('slateSyntaxTheme');
    return (n && THEMES[n]) ? n : 'dark-plus';
  };
  const styleFor = name => syntaxHighlighting((THEMES[name] || THEMES['dark-plus']).style || juliaHighlightStyle);
  const chromeFor = name => (THEMES[name] || THEMES['dark-plus']).chrome || [];
  window.setSyntaxTheme = (name) => {
    if (!THEMES[name]) return;
    localStorage.setItem('slateSyntaxTheme', name);
    for (const v of Object.values(window.editors || {})) {
      try { v.dispatch({ effects: [themeComp.reconfigure(styleFor(name)), chromeComp.reconfigure(chromeFor(name))] }); } catch (_) {}
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

  // Is the cursor inside a fenced code block? Markdown editors have no language tree, so count
  // ``` / ~~~ fence lines before the cursor — an odd count means we're inside code.
  function _inFencedCode(ctx) {
    const before = ctx.state.doc.sliceString(0, ctx.pos);
    return ((before.match(/^[ \t]*(```|~~~)/gm) || []).length % 2) === 1;
  }
  // `[@key]`-citation completion in markdown — keys come from the notebook's :bibliography cells
  // (state_json `bibKeys`). Triggers right after `[@`; inserts the chosen key before the `]`.
  function citeComplete(ctx, match) {
    const keys = (typeof nbState !== 'undefined' && nbState && nbState.bibKeys) || [];
    if (!keys.length) return null;
    return {
      from: match.from + 2,                              // after the `[@`
      options: keys.map(k => ({ label: k.key, detail: k.label || 'citation', type: 'constant', apply: k.key })),
      validFor: /^[\w:.\-]*$/,
    };
  }
  // Markdown editor completion: offer citations on `[@`, delegate to Julia ONLY inside a fenced
  // code block, and otherwise stay quiet — prose must not trigger code completion (the bug a tester
  // hit). Manual (Ctrl/Alt-Space) still completes citations / fenced code, never prose.
  async function markdownComplete(ctx) {
    const cite = ctx.matchBefore(/\[@[\w:.\-]*$/);
    if (cite) return citeComplete(ctx, cite);
    if (_inFencedCode(ctx)) return juliaComplete(ctx);
    return null;
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
  // Three independent line marks: `err` (faint, the call site in the cell that threw), `origin`
  // (brighter, the actual offending line — may be a DIFFERENT cell), and `flash` (transient pulse).
  const setErr = StateEffect.define(), setFlash = StateEffect.define(), setOrigin = StateEffect.define();
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
  const originField = mkField(setOrigin, 'cm-errorline-origin');

  const _validLine = (view, n) => n >= 1 && n <= view.state.doc.lines;
  window.markErrorLine = (id, line1) => { const v = editors[id]; if (v) v.dispatch({ effects: setErr.of(_validLine(v, line1) ? line1 : null) }); };
  window.clearErrorLine = (id) => { const v = editors[id]; if (v) v.dispatch({ effects: setErr.of(null) }); };
  window.markOriginLine = (id, line1) => { const v = editors[id]; if (v) v.dispatch({ effects: setOrigin.of(_validLine(v, line1) ? line1 : null) }); };
  window.clearOriginLine = (id) => { const v = editors[id]; if (v) v.dispatch({ effects: setOrigin.of(null) }); };
  window.flashLine = (id, line1) => {
    const v = editors[id]; if (!v || !_validLine(v, line1)) return;
    const off = v.state.doc.line(line1).from;
    v.dispatch({ selection: { anchor: off }, effects: [setFlash.of(line1), EditorView.scrollIntoView(off, { y: 'center' })] });
    setTimeout(() => { try { v.dispatch({ effects: setFlash.of(null) }); } catch (_) {} }, 1300);  // > the 1.2s flash animation
    v.focus();
  };

  // ── clean accessors the rest of the UI uses ───────────────────────────────────
  // Force a deferred editor to mount NOW (lazy hydration — see notebook.js <Editor>), returning the
  // live view. Used by any path that needs the real editor before idle hydration reaches the cell.
  window.ensureEditor = id => {
    if (editors[id]) return editors[id];
    window.hydrateNow && window.hydrateNow('ed:' + id);          // run its queued mount immediately
    const m = window._editorMount && window._editorMount[id];
    if (!editors[id] && m) m();                                  // belt-and-suspenders if it wasn't queued
    return editors[id] || null;
  };
  // edText falls back to the last server source for a not-yet-mounted (lazy) editor — an unmounted
  // cell has no local edits, so its text IS its source. Keeps save/run/backup correct pre-hydration.
  window.edText = id => { const v = editors[id]; return v ? v.state.doc.toString() : ((window.srcMap && window.srcMap[id]) || ''); };
  window.edSetText = (id, s) => { const v = editors[id]; if (v && v.state.doc.toString() !== s) v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } }); };
  window.edFocus = id => { const v = window.ensureEditor(id); if (v) v.focus(); };
  window.edInsert = (id, text) => { const v = editors[id]; if (!v) return; v.dispatch(v.state.replaceSelection(text)); v.focus(); };

  // ── ⌘-click go-to-definition ────────────────────────────────────────────────────
  // Find the cell that defines top-level `name` — nearest PRIOR definer (the reactive last-writer),
  // else nearest forward — and jump to its defining line. Cell-granular & name-based: resolves
  // notebook globals/functions, not locals inside a function body. Returns true if it navigated.
  window.gotoDef = function (name, fromCellId) {
    const cells = (typeof nbState !== 'undefined' && nbState && nbState.cells) || [];
    if (!cells.length) return false;
    const idx = cells.findIndex(c => c.id === fromCellId);
    const has = c => c.kind === 'code' && Array.isArray(c.defs) && c.defs.includes(name);
    let tgt = null;
    for (let i = (idx < 0 ? cells.length - 1 : idx); i >= 0; i--) if (has(cells[i])) { tgt = cells[i]; break; }
    if (!tgt) for (let i = (idx < 0 ? 0 : idx + 1); i < cells.length; i++) if (has(cells[i])) { tgt = cells[i]; break; }
    if (!tgt || typeof jumpToCellLine !== 'function') return false;
    jumpToCellLine(tgt.id, _defLine(tgt.source || '', name));
    return true;
  };
  // Best-effort line of the definition within a cell's source: a keyword def (function/struct/…),
  // an assignment, a short-form function, or `@bind name`; else first mention; else line 1.
  function _defLine(src, name) {
    const e = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const t = '(?![A-Za-z0-9_!])';   // identifier-end (Julia names may end in `!`, so `\b` won't do)
    const pats = [
      new RegExp('^\\s*(?:function|macro|const|global|local|mutable\\s+struct|struct|abstract\\s+type|primitive\\s+type)\\s+@?' + e + t),
      new RegExp('^\\s*@?' + e + t + '\\s*(?:::[^=\\n]*)?=(?!=)'),   // assignment (incl. typed), not ==
      new RegExp('^\\s*' + e + '\\s*\\('),                          // short-form function def
      new RegExp('^\\s*@bind\\s+' + e + t),
    ];
    const any = new RegExp('(?<![A-Za-z0-9_])' + e + t);
    const lines = src.split('\n');
    let fb = 0;
    for (let i = 0; i < lines.length; i++) {
      if (pats.some(p => p.test(lines[i]))) return i + 1;
      if (!fb && any.test(lines[i])) fb = i + 1;
    }
    return fb || 1;
  }
  // ⌘ held → link cursor over editors, signalling click-to-navigate is live.
  addEventListener('keydown', e => { if (e.key === 'Meta') document.body.classList.add('modkey'); });
  addEventListener('keyup',   e => { if (e.key === 'Meta') document.body.classList.remove('modkey'); });
  addEventListener('blur',    () => document.body.classList.remove('modkey'));

  // ── editor factory ─────────────────────────────────────────────────────────────
  function mkEditor(parent, opts) {
    opts = opts || {};
    // Chrome applies to every editor (code + markdown) so the panel reads coherently; tokens only
    // matter for code, but the compartment is harmless on a markdown editor (no Julia tree).
    const cur = curSyntaxTheme();
    const themed = [chromeComp.of(chromeFor(cur)), themeComp.of(styleFor(cur))];
    const lang = opts.markdown ? themed : [julia(), ...themed];
    const cellKeys = (opts.keys || []).map(k => ({ key: k.key, run: () => { k.run(); return true; } }));
    const view = new EditorView({
      parent,
      doc: opts.doc || '',
      extensions: [
        history(), drawSelection(), bracketMatching(), closeBrackets(), indentOnInput(),
        indentUnit.of('    '), EditorState.tabSize.of(4), errField, originField, flashField,
        wrapComp.of(_wrapExt(!!opts.markdown)),
        ...lang,
        // Markdown editors complete citations + fenced code only (never prose); code cells get Julia.
        autocompletion({ override: [opts.markdown ? markdownComplete : juliaComplete], icons: true }),
        keymap.of([
          ...completionKeymap,                  // popup nav/close (Escape) takes precedence over cell keys
          ...cellKeys,                          // a cell's own Escape (e.g. cancelSource) wins over the blur below
          { key: 'Escape', run: (v) => { v.contentDOM.blur(); return true; } },   // exit edit → command mode
          // ⌘⇧K = help (app shortcut). Bind it here so CM6's defaultKeymap `deleteLine` doesn't eat it.
          { key: 'Mod-Shift-k', run: () => { window.__docsHotkey = Date.now(); window.openDocsAtCursor && window.openDocsAtCursor(); return true; } },
          // ⌘⇧←/→ = back/forward through selected-cell nav history, IN the editor too — so after a
          // ⌘-click go-to-definition (which focuses the target editor) you can jump straight back.
          // (Overrides CM's select-to-line-start; use Home / ⌘← then ⇧ for that.)
          { key: 'Mod-Shift-ArrowLeft', run: () => { window.navBack && window.navBack(); return true; } },
          { key: 'Mod-Shift-ArrowRight', run: () => { window.navFwd && window.navFwd(); return true; } },
          { key: 'Mod-/', run: toggleComment }, { key: 'Ctrl-/', run: toggleComment },
          // Tab: accept the open completion → else trigger one when a word/`\`/`.` precedes the
          // cursor → else fall through to indent. Restores CM5's Tab-to-complete. (macOS eats
          // Ctrl-Space, so Alt-Space is the reliable manual trigger; Ctrl-Space kept for others.)
          { key: 'Tab', run: tabComplete },
          { key: 'Ctrl-Space', run: startCompletion }, { key: 'Alt-Space', run: startCompletion },
          indentWithTab, ...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap,
        ]),
        EditorView.domEventHandlers({
          // ⌘-click an identifier → jump to the cell that defines it (else fall through to normal click).
          mousedown(event, view) {
            if (!event.metaKey || opts.markdown) return false;
            const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
            if (pos == null) return false;
            const w = view.state.wordAt(pos);
            if (!w) return false;
            let name = view.state.doc.sliceString(w.from, w.to);
            if (view.state.doc.sliceString(w.to, w.to + 1) === '!') name += '!';   // Julia bang functions
            if (!/^[A-Za-z_]/.test(name)) return false;
            if (window.gotoDef && window.gotoDef(name, opts.cellId)) { event.preventDefault(); return true; }
            return false;
          },
        }),
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
    view._wrapMd = !!opts.markdown;   // markdown views stay wrapped when the code-wrap toggle flips
    if (opts.cellId) window.editors[opts.cellId] = view;
    return view;
  }
  window.mkEditor = mkEditor;
})();
