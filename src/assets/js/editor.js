// CodeMirror 6 notebook editor (native — no CM5 compat). `window.editors[id]` is the EditorView.
// Highlighting is Lezer-Julia (cm6.bundle.js); completion, snippets, bracket-close, comment-toggle
// and indentation are CM6 built-ins. Clean helpers (edText/edFocus/markErrorLine/…) are what the
// rest of the UI calls — no `.getValue()`/`.getCursor()` emulation.
(function () {
  const CM = window.CM6;
  if (!CM) { console.error('CM6 bundle missing'); return; }
  const { EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect, Decoration, Transaction,
          keymap, defaultKeymap, history, historyKeymap, undoDepth, redoDepth, indentWithTab, toggleComment,
          indentUnit, bracketMatching, indentOnInput, syntaxTree, drawSelection,
          syntaxHighlighting, julia, juliaHighlightStyle, juliaThemes, slateThemes, slateThemeMeta,
          htmlLang, cssLang, jsLang, jsEmbed, scopeCompletionSource, localCompletionSource,
          syntaxErrorLinter,

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
  // How long to pause typing before the completion popup auto-opens (Settings → Editing). Manual
  // triggers (Tab / Ctrl-Space) are instant regardless. Default 250ms — a middle ground: CM6's native
  // default is a flickery ~100ms, VS Code is near-instant; 250 cuts the on/off churn without feeling
  // sluggish. In a Compartment so the setting applies LIVE to every open editor (not just new ones).
  const acompComp = new Compartment();
  const _completeDelay = () => { const n = parseInt(localStorage.getItem('slateCompleteDelay'), 10); return Number.isFinite(n) ? n : 250; };
  // The completion extension for one editor (markdown vs code differ only in the override source).
  // `markdownComplete`/`juliaComplete` are hoisted function declarations, so referencing them here is fine.
  const _acompExt = isMd => autocompletion({ override: [isMd ? markdownComplete : juliaComplete], icons: true,
    activateOnTypingDelay: _completeDelay() });
  // Live-apply the autocomplete typing-delay across every open editor (Settings → Editing).
  window.setCompleteDelay = ms => {
    localStorage.setItem('slateCompleteDelay', String(parseInt(ms, 10) || 0));
    for (const v of Object.values(window.editors || {}))
      try { v.dispatch({ effects: acompComp.reconfigure(_acompExt(!!v._wrapMd)) }); } catch (_) {}
  };
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

  // ── Editor-extension registry (extension point) ──────────────────────────────
  // A package can teach EVERY cell editor a new behaviour (e.g. render giac"…" as an
  // inline math field) without editing core — the editor counterpart of
  // slateRegisterWidget. Register a function that, given the editor's context
  // ({markdown, cellId}), returns CM6 extension(s) to merge in. It's consulted when an
  // editor is built, so register at notebook load (before cells hydrate); editors that
  // mount later pick it up. Registered extensions sit BEFORE the default keymap, so a
  // returned keymap can take precedence.
  window._slateEditorExts = window._slateEditorExts || [];
  const _editorExtComp = new Compartment();
  const _buildEditorExts = ctx => window._slateEditorExts.flatMap(fn => {
    try { return fn(ctx) || []; } catch (e) { console.error('slate editor extension failed', e); return []; }
  });
  window.slateRegisterEditorExtension = fn => {
    if (typeof fn !== 'function' || window._slateEditorExts.includes(fn)) return;
    window._slateEditorExts.push(fn);
    // Apply to editors already open (registration can land after they mounted).
    for (const v of Object.values(window.editors || {})) {
      try { v.dispatch({ effects: _editorExtComp.reconfigure(_buildEditorExts(v._edctx || {})) }); } catch (e) {}
    }
  };

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
    const options = raw.map((it, i) => {
      const o = (it && typeof it === 'object') ? it : { text: String(it) };
      const text = o.text != null ? o.text : (o.label != null ? o.label : String(it));
      // The server already ranks (current-cell locals → other-cell notebook vars → library names).
      // CM6 would otherwise re-sort by its own fuzzy score, burying those tiers — so pin each option's
      // `boost` to its server position (descending, floored at -99) to preserve the intended order.
      const boost = Math.max(-99, 99 - i);
      if (o.kind === 'method') {
        // Clean label (no location), module as detail, full arg specs as tab-through snippet fields
        // (e.g. `A::AbstractMatrix`). Braces in parametric types are escaped for the snippet syntax.
        const m = parseMethod(text);
        const esc = s => s.replace(/[{}]/g, '\\$&');                  // \{ \} are the only field escapes
        // Trailing ${} is the final tab-stop: after the last arg, Tab lands the cursor just past
        // the closing paren (CM6 has no implicit end field, so without this the last Tab indents).
        const tmpl = m.name + '(' + m.args.map(a => '${' + esc(a) + '}').join(', ') + ')${}';
        return {
          label: m.sig, detail: m.mod || 'method', type: 'function', info: docPreview(m.name), boost,
          apply: (view, completion, from, to) => {
            // The server range covers just the name; swallow the `(` the user typed AND the `)`
            // that closeBrackets auto-inserted, so the snippet's own `()` isn't doubled.
            let end = to;
            if (view.state.sliceDoc(end, end + 1) === '(') { end++; if (view.state.sliceDoc(end, end + 1) === ')') end++; }
            snippet(tmpl)(view, completion, from, end);
          },
        };
      }
      const opt = { label: text, type: _cmType(o.kind), boost };
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

  // CM6's bundle doesn't export moveCompletionSelection, but completionKeymap binds it to the
  // arrows — pull those run fns out so Tab/Shift-Tab can drive the SAME navigation.
  const _compNav = dir => (completionKeymap.find(k => k.key === (dir > 0 ? 'ArrowDown' : 'ArrowUp')) || {}).run;
  const _compDown = _compNav(1), _compUp = _compNav(-1);
  // What Tab does in an OPEN popup, from the `slateCompleteTab` preference (Settings → Editing):
  //   'accept'   — Tab (and Enter) accept the highlighted item. The mainstream IDE convention. DEFAULT.
  //   'navigate' — Tab moves to the next option, Shift-Tab to the previous; only Enter accepts.
  // Read live (per keypress) so the toggle takes effect without a reload.
  const _tabMode = () => (localStorage.getItem('slateCompleteTab') || 'accept');
  // Tab in an OPEN popup accepts or navigates per the pref. With the popup CLOSED, Tab indents when
  // the cursor is in leading whitespace / a selection is active (block indent), else OPENS completion.
  // Enter always accepts + closes (completionKeymap). Returns false to fall through to indentWithTab.
  function tabComplete(v) {
    if (completionStatus(v.state) === 'active')
      return _tabMode() === 'navigate' ? (_compDown ? _compDown(v) : true) : acceptCompletion(v);
    const sel = v.state.selection.main;
    if (!sel.empty) return false;                                   // selection → indent block
    const line = v.state.doc.lineAt(sel.from);
    if (/^\s*$/.test(v.state.sliceDoc(line.from, sel.from))) return false;   // only whitespace before → indent
    return startCompletion(v);
  }
  // Shift-Tab: navigate UP through an open popup (navigate-mode only), else fall through to indentLess.
  function shiftTabComplete(v) {
    if (completionStatus(v.state) === 'active' && _tabMode() === 'navigate') return _compUp ? _compUp(v) : true;
    return false;
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
  // ── Web cell: assemble/split the `@web(...)` skin (JS mirror of Julia `_web_skin`/`_web_sections`) ──
  // A web cell's "source" is the runnable `@web(html"…", css"…", js"…")` skin; the 3-pane editor holds
  // the sections and this reconstructs the skin byte-for-byte the way the engine does, so a save/parse
  // round-trips stably. `webEditors[id] = { panes:{html,css,js}, assemble() }` is registered by the
  // <WebEditor> component; `edText`/`edSetText` route through it so run/save/reconcile see one source.
  window._webSkin = ({ html = '', css = '', js = '' } = {}) => {
    const secs = [];
    if (String(html).trim()) secs.push('html"""\n' + html + '\n"""');
    if (String(css).trim())  secs.push('css"""\n' + css + '\n"""');
    if (String(js).trim())   secs.push('js"""\n' + js + '\n"""');
    if (!secs.length) secs.push('html""""""');
    return '@web(' + secs.join(',\n') + ')';
  };
  window._webSections = (src) => {
    const grab = tag => { const m = new RegExp(tag + '"""([\\s\\S]*?)"""').exec(src || ''); return m ? m[1].replace(/^\n/, '').replace(/\n$/, '') : ''; };
    return { html: grab('html'), css: grab('css'), js: grab('js') };
  };
  // edText falls back to the last server source for a not-yet-mounted (lazy) editor — an unmounted
  // cell has no local edits, so its text IS its source. Keeps save/run/backup correct pre-hydration.
  window.edText = id => {
    const w = window.webEditors && window.webEditors[id];
    if (w) return w.assemble();
    const v = editors[id]; return v ? v.state.doc.toString() : ((window.srcMap && window.srcMap[id]) || '');
  };
  window.edSetText = (id, s) => {
    const w = window.webEditors && window.webEditors[id];
    if (w) {                                              // external/agent edit → split back into the panes
      const p = window._webSections(s);
      for (const k of ['html', 'css', 'js']) {
        const val = p[k] || '';
        if (!w.panes[k] && val.trim() && w.addPane) w.addPane(k, val);   // a section that arrived → mount its pane
        const v = w.panes[k]; if (v && v.state.doc.toString() !== val) v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: val } });
      }
      return;
    }
    const v = editors[id]; if (v && v.state.doc.toString() !== s) v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  };
  // Standalone CM6 editor for the Files tab. Delegates to the full cell factory `mkEditor` so a
  // source file gets the SAME feature set as a cell — Julia autocomplete (server `/api/complete`,
  // which keys off the code + cursor, not a cell id), snippets, comment-toggle (⌘/), bracket
  // match/close, indent-on-input, Tab-completion, ⌘-Space. No `cellId` ⇒ it isn't registered as a
  // cell editor. `opts`: {filename, onSave, onChange}; ⌘S saves (the caller owns persistence).
  window.mkFileEditor = (parent, text, opts = {}) => mkEditor(parent, {
    doc: text,
    markdown: /\.(md|markdown|qmd)$/i.test(opts.filename || ''),
    keys: opts.onSave ? [{ key: 'Mod-s', run: () => { opts.onSave(); return true; } }] : [],
    onDoc: () => { if (opts.onChange) opts.onChange(); },
  });
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

  // ── Undo through history ─────────────────────────────────────────────────────────
  // Once a cell editor's OWN undo stack is exhausted, ⌘Z keeps going — stepping back
  // through the durable snapshots of THIS cell's source (from the time machine), never
  // touching any other cell. ⌘⇧Z steps forward. The cell header flashes the age of the
  // version you land on. Typing anything commits to that version and leaves the mode (the
  // typed text becomes a fresh branch point, exactly like normal editing). Per-cell state:
  //   cellId → { versions:[{seq,ts,label,source}] (newest-first), idx, loading, applying }
  // idx 0 == the live/committed source (no badge); larger idx == older snapshots.
  const _hu = {};
  function _huBadge(cellId, ts, label, atOldest) {
    const cell = document.getElementById('cell-' + cellId); if (!cell) return null;
    const head = cell.querySelector('.cellhead'); if (!head) return null;
    let b = head.querySelector('.histago');
    if (!b) {
      b = document.createElement('span'); b.className = 'histago';
      const cid = head.querySelector('.cid');
      cid ? cid.insertAdjacentElement('afterend', b) : head.appendChild(b);
    }
    const st = _hu[cellId]; if (st && st._nowTimer) { clearTimeout(st._nowTimer); st._nowTimer = null; }
    b.className = 'histago' + (atOldest ? ' oldest' : '');
    b.textContent = '↶ ' + (window._reltime ? window._reltime(ts) : '') + (atOldest ? ' · oldest' : '');
    b.title = atOldest ? 'beginning of this cell’s history — nothing older'
                       : (label ? ('restored to: ' + label) : '');
    return b;
  }
  // Redone all the way forward → briefly confirm we're back on the live version, then clear.
  function _huNowFlash(cellId) {
    const st = _hu[cellId]; if (st && st._nowTimer) { clearTimeout(st._nowTimer); st._nowTimer = null; }
    const cell = document.getElementById('cell-' + cellId); if (!cell) return;
    const head = cell.querySelector('.cellhead'); if (!head) return;
    let b = head.querySelector('.histago');
    if (!b) {
      b = document.createElement('span'); b.className = 'histago';
      const cid = head.querySelector('.cid');
      cid ? cid.insertAdjacentElement('afterend', b) : head.appendChild(b);
    }
    b.className = 'histago now pulse';
    b.textContent = '⭢ now · current';
    b.title = 'back to the current version';
    if (st) st._nowTimer = setTimeout(() => _huClearBadge(cellId), 1100);
  }
  // Already at the oldest snapshot and ⌘Z again → re-pulse the pill so it's clear there's no more.
  function _huPulseOldest(cellId) {
    const st = _hu[cellId]; if (!st || !st.versions || !st.versions.length) return;
    const v = st.versions[st.versions.length - 1];
    const b = _huBadge(cellId, v.ts, v.label, true); if (!b) return;
    b.classList.remove('pulse'); void b.offsetWidth; b.classList.add('pulse');   // restart the animation
  }
  function _huClearBadge(cellId) {
    const cell = document.getElementById('cell-' + cellId); if (!cell) return;
    const b = cell.querySelector('.cellhead .histago'); if (b) b.remove();
  }
  function _huApply(view, cellId, idx) {
    const st = _hu[cellId]; if (!st || !st.versions || !st.versions.length) return false;
    idx = Math.max(0, Math.min(idx, st.versions.length - 1));
    if (idx === st.idx && idx !== 0) return true;    // already at the oldest — consume, no fall-through
    st.idx = idx;
    const v = st.versions[idx];
    st.applying = true;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: v.source },
      selection: { anchor: Math.min(view.state.selection.main.anchor, v.source.length) },
      scrollIntoView: true,
      // Keep the step OUT of CodeMirror's own undo history — otherwise it re-arms undoDepth and the
      // next ⌘Z would undo this replacement (a "redo") instead of stepping to an older snapshot.
      annotations: Transaction.addToHistory.of(false),
    });
    st.applying = false;
    idx === 0 ? _huNowFlash(cellId) : _huBadge(cellId, v.ts, v.label, idx === st.versions.length - 1);
    return true;
  }
  // ⌘Z when the editor's own undo is spent → one snapshot older. true = consumed.
  function huUndo(view, cellId) {
    if (!cellId) return false;
    let st = _hu[cellId];
    if (!st) {                                       // first step: fetch this cell's timeline, then apply
      st = _hu[cellId] = { versions: null, idx: 0, loading: true, applying: false };
      (async () => {
        let vs = [];
        try { const r = await window.api('GET', '/api/cell-history/' + encodeURIComponent(cellId)); vs = (r && r.versions) || []; } catch (e) {}
        st.versions = vs; st.loading = false;
        if (vs.length > 1) _huApply(view, cellId, 1);
      })();
      return true;
    }
    if (st.loading) return true;
    if (!st.versions || st.versions.length <= 1) return false;
    const next = Math.min(st.idx + 1, st.versions.length - 1);
    if (next === st.idx) { _huPulseOldest(cellId); return true; }   // already at the beginning of history
    return _huApply(view, cellId, next);
  }
  // ⌘⇧Z while stepped into history → one snapshot newer; at the live version, fall through
  // to the editor's normal redo.
  function huRedo(view, cellId) {
    const st = _hu[cellId];
    if (!st || !st.versions) return false;
    if (st.idx <= 0) { _huNowFlash(cellId); return true; }   // already at the current version
    return _huApply(view, cellId, st.idx - 1);
  }
  // A user edit (not one of our applies) branches off the shown version: leave history mode
  // and drop the cached timeline so the next ⌘Z re-fetches (this edit becomes a new version
  // once saved).
  function huUserEdit(cellId) {
    const st = _hu[cellId]; if (!st || st.applying) return;
    if (st._nowTimer) clearTimeout(st._nowTimer);
    if (st.idx !== 0 || st.versions) { _huClearBadge(cellId); }
    delete _hu[cellId];
  }

  // ── editor factory ─────────────────────────────────────────────────────────────
  function mkEditor(parent, opts) {
    opts = opts || {};
    // Chrome applies to every editor (code + markdown) so the panel reads coherently; tokens only
    // matter for code, but the compartment is harmless on a markdown editor (no Julia tree).
    const cur = curSyntaxTheme();
    const themed = [chromeComp.of(chromeFor(cur)), themeComp.of(styleFor(cur))];
    // `opts.lang` names a web-cell section grammar ('html'/'css'/'js'); default is Julia (markdown gets
    // no language tree, just the theme). The web section grammars carry their own native completion
    // (HTML tags/attrs, CSS props, JS), so those panes use plain `autocompletion()` instead of the
    // Julia/markdown override below.
    // The JS pane uses `jsEmbed` (highlights html`…`/css`…` template literals); html/css use their
    // own grammar. Completion: the JS pane completes in-scope locals + real page globals (document.,
    // Slate., root., Math.…); html/css use their grammar's native completion (tags/attrs, properties).
    const webLang = !opts.markdown && ({ html: htmlLang, css: cssLang, js: jsEmbed }[opts.lang]);
    const lang = opts.markdown ? themed : webLang ? [webLang(), ...themed] : [julia(), ...themed];
    const acompExt = !webLang ? _acompExt(!!opts.markdown)
      : opts.lang === 'js'
        ? autocompletion({ icons: true, activateOnTypingDelay: _completeDelay(),
            override: [localCompletionSource, scopeCompletionSource(globalThis)] })
        : autocompletion({ icons: true, activateOnTypingDelay: _completeDelay() });
    const cellKeys = (opts.keys || []).map(k => ({ key: k.key, run: () => { k.run(); return true; } }));
    const _edctx = { markdown: !!opts.markdown, cellId: opts.cellId };   // for registered editor extensions
    // Web-cell panes (HTML/CSS/JS) indent 2 spaces — the web convention — vs Julia's 4. Drives
    // auto-indent (Enter / indentOnInput) and Tab; the language's indent service reads `indentUnit`.
    const _indent = webLang ? '  ' : '    ';
    const view = new EditorView({
      parent,
      doc: opts.doc || '',
      extensions: [
        history(), drawSelection(), bracketMatching(), closeBrackets(), indentOnInput(),
        indentUnit.of(_indent), EditorState.tabSize.of(webLang ? 2 : 4), errField, originField, flashField,
        wrapComp.of(_wrapExt(!!opts.markdown)),
        ...lang,
        // Web panes: inline syntax-error diagnostics (a red underline) as you type, so a typo like
        // `for x of …` is caught at author time instead of a cryptic runtime console error. No lint
        // GUTTER — it would reserve a left column the other (gutterless) Slate editors don't have.
        ...(webLang ? [syntaxErrorLinter] : []),
        // Markdown editors complete citations + fenced code only (never prose); code cells get Julia.
        // Don't pop the completion list WHILE typing — only after a brief pause — so it stops
        // flickering on/off mid-word (and Tab-to-indent can't accidentally land on a just-opened
        // popup). Manual triggers (Tab / Ctrl-Space / Alt-Space) are immediate regardless. Tunable
        // via window.slateCompleteDelay (a settings hook); default 500ms.
        acompComp.of(acompExt),
        // Registered editor extensions (e.g. inline-math rendering), in a compartment so a
        // later registration can reconfigure this open editor. Before the keymap below so a
        // returned keymap out-precedences the defaults.
        _editorExtComp.of(_buildEditorExts(_edctx)),
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
          // Tab: navigate an open popup (down) / open one when a word/`\`/`.` precedes the cursor /
          // else indent — it never accepts (Enter accepts + closes). Shift-Tab navigates up / indents
          // less. (macOS eats Ctrl-Space, so Alt-Space is the reliable manual trigger.)
          { key: 'Tab', run: tabComplete }, { key: 'Shift-Tab', run: shiftTabComplete },
          { key: 'Ctrl-Space', run: startCompletion }, { key: 'Alt-Space', run: startCompletion },
          // ⌘Z / ⌘⇧Z: while the editor's own undo stack has depth, use it; once it's spent,
          // keep undoing back through THIS cell's durable snapshots (returns false only when
          // there's local history to spend, so CM's own undo then runs).
          { key: 'Mod-z', run: (v) => (undoDepth(v.state) > 0 ? false : huUndo(v, opts.cellId)) },
          { key: 'Mod-Shift-z', run: (v) => (redoDepth(v.state) > 0 ? false : huRedo(v, opts.cellId)) },
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
          // A history-undo STEP is provisional + editor-local: don't branch-reset it and don't
          // autosave it. Only a genuine user edit branches off the stepped-to snapshot and saves.
          const _stepping = opts.cellId && _hu[opts.cellId] && _hu[opts.cellId].applying;
          if (u.docChanged && opts.cellId && !_stepping) huUserEdit(opts.cellId);
          if (u.docChanged && !_stepping && opts.onDoc) opts.onDoc(u.state.doc.toString());
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
    view._edctx = _edctx;             // ctx for reconfiguring registered editor extensions
    if (opts.cellId) window.editors[opts.cellId] = view;
    return view;
  }
  window.mkEditor = mkEditor;
})();
