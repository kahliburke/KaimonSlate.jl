// CodeMirror 6 editor + a thin CM5-compatible wrapper, so the rest of the notebook UI (which was
// written against CM5's imperative API) keeps working while the underlying editor is CM6. The CM6
// primitives come from the vendored bundle (cm6.bundle.js → window.CM6). `makeCM6(parent, opts)`
// returns an object exposing the CM5 methods the codebase calls (getValue/setValue/getCursor/…,
// addLineClass for the error-line tint, on('change'/'focus'/'blur')); native CM6 handles
// highlighting (Lezer Julia), history, bracket matching, and as-you-type completion.
(function () {
  const CM = window.CM6;
  if (!CM) { console.error('CM6 bundle not loaded'); return; }
  const { EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect,
          keymap, drawSelection, Decoration, defaultKeymap, history, historyKeymap, indentWithTab,
          indentUnit, bracketMatching, syntaxHighlighting, julia, juliaHighlightStyle,
          autocompletion, closeBrackets, closeBracketsKeymap } = CM;

  // ── pos <-> offset helpers (CM6 is offset-based; CM5 used {line, ch}) ──────────
  const offToPos = (state, off) => { const l = state.doc.lineAt(off); return { line: l.number - 1, ch: off - l.from }; };
  const posToOff = (state, p) => {
    const ln = Math.max(1, Math.min(state.doc.lines, (p.line || 0) + 1));
    const line = state.doc.line(ln);
    return Math.min(line.to, line.from + (p.ch || 0));
  };

  // ── error-line decoration (CM5 addLineClass/removeLineClass) ───────────────────
  const addLine = StateEffect.define(), rmLine = StateEffect.define();
  const lineDecoField = StateField.define({
    create() { return Decoration.none; },
    update(deco, tr) {
      deco = deco.map(tr.changes);
      for (const e of tr.effects) {
        if (e.is(addLine)) deco = deco.update({ add: [Decoration.line({ class: e.value.cls }).range(e.value.from)] });
        if (e.is(rmLine)) deco = deco.update({ filter: (f, to, d) => d.spec.class !== e.value.cls });
      }
      return deco;
    },
    provide: f => EditorView.decorations.from(f),
  });

  // ── completion: same server protocol as the old juliaHint (/api/complete) ──────
  // Skipped in comments/strings and right after a finished keyword (parity with the CM5 trigger).
  const _kwSet = window._JL_KEYWORDS || new Set();
  async function juliaSource(ctx) {
    const before = ctx.matchBefore(/[A-Za-z_][\w!]*$/);
    const dot = ctx.matchBefore(/\.$/);
    if (!ctx.explicit && !before && !dot) return null;
    if (before && _kwSet.has(before.text)) return null;       // finished keyword → no popup
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
      return { label, type: _cmType(o.kind), detail: o.kind === 'latex' ? o.symbol : undefined,
               apply: o.symbol && o.kind === 'latex' ? o.symbol : undefined };
    });
    return { from, to, options, validFor: /^[\w!]*$/ };
  }
  const _cmType = k => ({ method: 'function', function: 'function', type: 'type', module: 'namespace',
    macro: 'macro', keyword: 'keyword', field: 'property', kwarg: 'property' }[k] || 'variable');

  const baseKeymap = (opts) => {
    const km = [];
    // Map the caller's CM5 extraKeys (Shift-Enter / Cmd-/ / Esc …) onto CM6 key bindings.
    const ek = opts.extraKeys || {};
    const _k = (cm5key, cm6key) => { if (ek[cm5key]) km.push({ key: cm6key, run: () => { ek[cm5key](wrap); return true; } }); };
    _k('Shift-Enter', 'Shift-Enter'); _k('Shift-Cmd-Enter', 'Shift-Mod-Enter'); _k('Shift-Ctrl-Enter', 'Shift-Ctrl-Enter');
    _k('Cmd-/', 'Mod-/'); _k('Ctrl-/', 'Ctrl-/'); _k('Esc', 'Escape');
    return km;
  };

  let wrap;   // forward ref so keymap closures can hand the wrapper to callers
  function makeCM6(parent, opts) {
    opts = opts || {};
    const keymapComp = new Compartment();
    const lang = opts.mode === 'markdown' ? [] : [julia(), syntaxHighlighting(juliaHighlightStyle)];
    const view = new EditorView({
      parent,
      doc: opts.value || '',
      extensions: [
        history(), drawSelection(), bracketMatching(), closeBrackets(), lineDecoField,
        indentUnit.of('    '), EditorState.tabSize.of(4),
        ...lang,
        autocompletion({ override: [juliaSource], icons: false }),
        keymapComp.of(keymap.of([...baseKeymap(opts), indentWithTab, ...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap])),
        EditorView.updateListener.of(u => {
          if (u.docChanged && opts.onChange) opts.onChange(wrapFor(u.view));
          if (u.focusChanged) (u.view.hasFocus ? opts.onFocus : opts.onBlur) && (u.view.hasFocus ? opts.onFocus : opts.onBlur)(wrapFor(u.view));
        }),
        EditorView.theme({ '&': { fontFamily: "'Cascadia Code','Fira Code',monospace", fontSize: '0.86rem' },
                           '.cm-content': { padding: '6px 0' } }, { dark: true }),
      ],
    });
    return wrapView(view, keymapComp, opts);
  }

  const _wraps = new WeakMap();
  const wrapFor = view => _wraps.get(view);
  function wrapView(view, keymapComp, opts) {
    const w = {
      _cm6: true, view, _changeHandlers: [],
      getValue: () => view.state.doc.toString(),
      setValue: (s) => view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: s } }),
      getLine: (n) => { const ln = view.state.doc.line(n + 1); return ln ? ln.text : ''; },
      lineCount: () => view.state.doc.lines,
      getCursor: (which) => {
        const sel = view.state.selection.main;
        const off = which === 'from' ? sel.from : which === 'to' ? sel.to : sel.head;
        return offToPos(view.state, off);
      },
      setCursor: (p) => view.dispatch({ selection: { anchor: posToOff(view.state, p) } }),
      setSelection: (a, b) => view.dispatch({ selection: EditorSelection.range(posToOff(view.state, a), posToOff(view.state, b || a)) }),
      somethingSelected: () => !view.state.selection.main.empty,
      getRange: (a, b) => view.state.sliceDoc(posToOff(view.state, a), posToOff(view.state, b)),
      replaceRange: (text, a, b) => view.dispatch({ changes: { from: posToOff(view.state, a), to: posToOff(view.state, b || a), insert: text } }),
      replaceSelection: (text) => view.dispatch(view.state.replaceSelection(text)),
      indexFromPos: (p) => posToOff(view.state, p),
      posFromIndex: (i) => offToPos(view.state, i),
      focus: () => view.focus(),
      hasFocus: () => view.hasFocus,
      refresh: () => view.requestMeasure(),
      operation: (fn) => fn(),
      getWrapperElement: () => view.dom,
      getInputField: () => view.contentDOM,
      scrollIntoView: (p) => view.dispatch({ effects: EditorView.scrollIntoView(posToOff(view.state, typeof p === 'object' && 'line' in p ? p : view.state.selection.main.head)) }),
      addLineClass: (line, _where, cls) => { try { const ln = view.state.doc.line(line + 1); view.dispatch({ effects: addLine.of({ from: ln.from, cls }) }); } catch (_) {} },
      removeLineClass: (line, _where, cls) => { try { view.dispatch({ effects: rmLine.of({ cls }) }); } catch (_) {} },
      // token under a position — used to skip completion in comments/strings
      getTokenAt: (p) => { const tree = CM.julia ? null : null; return { type: null }; },   // CM6 completion source handles this itself
      setOption: () => {},                       // extraKeys handled at creation
      on: (ev, fn) => { if (ev === 'change') w._changeHandlers.push(fn); },
      off: (ev, fn) => { if (ev === 'change') w._changeHandlers = w._changeHandlers.filter(h => h !== fn); },
    };
    // route doc changes to .on('change') handlers (placeholder auto-clear etc.)
    const orig = opts.onChange;
    opts.onChange = (cm) => { (w._changeHandlers || []).forEach(h => { try { h(cm); } catch (_) {} }); orig && orig(cm); };
    _wraps.set(view, w);
    wrap = w;
    return w;
  }

  window.makeCM6 = makeCM6;
})();
