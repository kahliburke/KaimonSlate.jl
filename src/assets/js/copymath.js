// ── Copying typeset math ────────────────────────────────────────────────────────
// A KaTeX formula is two trees: the visible HTML, one span per glyph, and a hidden MathML copy. A
// plain copy takes the text of both, so a formula pastes as hundreds of one-glyph lines. When a
// selection holds math, this puts each formula on the clipboard as its LaTeX source instead
// (`$…$` inline, `$$…$$` on its own line for display math) and keeps a line break between blocks.
//
// Phantoms are dropped from the copied source: they only reserve space, which is how a document
// aligns separately typeset equations with each other, and they hold copies of the visible rows.
//
// Self-contained, so a static export inlines this file unchanged. `slateCleanTex(tex)` is the pure
// part, exposed for tests.
(function () {
  if (window.slateCleanTex) return;

  // `\phantom{…}`, `\hphantom{…}` and `\vphantom{…}` removed, braces balanced; then any row of an
  // alignment left holding nothing but `&` separators.
  function cleanTex(tex) {
    let out = '', i = 0;
    const re = /\\[hv]?phantom\s*\{/g;
    for (let m = re.exec(tex); m; m = re.exec(tex)) {
      let depth = 1, j = m.index + m[0].length;
      for (; j < tex.length && depth; j++) {
        if (tex[j] === '\\') { j++; continue; }
        if (tex[j] === '{') depth++;
        else if (tex[j] === '}') depth--;
      }
      out += tex.slice(i, m.index);
      i = re.lastIndex = j;
    }
    out += tex.slice(i);
    const empty = /(\\begin\{[a-z]+\*?\}(?:\{[^}]*\})?|\\\\(?:\[[^\]]*\])?)\s*(?:&\s*)*\\\\(?:\[[^\]]*\])?/g;
    return out.replace(empty, '$1').trim();
  }
  window.slateCleanTex = cleanTex;
  if (typeof document === 'undefined') return;

  // KaTeX draws a phantom's glyphs in transparent ink, but they are still text a selection paints,
  // so selecting an aligned derivation lights up invisible copies of its other rows.
  const css = document.createElement('style');
  css.textContent = '.katex [style*="color: transparent"], .katex [style*="color: transparent"] * '
                  + '{ -webkit-user-select: none; user-select: none; }';
  document.head.appendChild(css);

  const TEX = 'annotation[encoding="application/x-tex"]';
  const SKIP = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'NOSCRIPT']);
  const BLOCK = new Set(['P', 'DIV', 'LI', 'UL', 'OL', 'DL', 'DT', 'DD', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
                         'TABLE', 'THEAD', 'TBODY', 'TR', 'PRE', 'BLOCKQUOTE', 'SECTION', 'FIGURE',
                         'FIGCAPTION', 'DETAILS', 'SUMMARY', 'HR', 'BR']);

  const formula = n => {
    const e = n && (n.nodeType === 1 ? n : n.parentElement);
    return e && e.closest ? (e.closest('.katex-display') || e.closest('.katex')) : null;
  };

  // A formula's LaTeX with its delimiters, or null when KaTeX left no source behind.
  function source(k) {
    const a = k.querySelector(TEX);
    if (!a) return null;
    const tex = cleanTex(a.textContent);
    return k.classList.contains('katex-display') ? '$$' + tex + '$$' : '$' + tex + '$';
  }

  // The fragment as text: formulas already replaced, a newline at each block boundary.
  function plain(root) {
    let text = '';
    const walk = n => {
      if (n.nodeType === 3) { text += n.data; return; }
      if (n.nodeType !== 1 && n.nodeType !== 11) return;
      if (n.nodeType === 1 && SKIP.has(n.tagName)) return;
      const block = n.nodeType === 1 && BLOCK.has(n.tagName);
      if (block && text && !text.endsWith('\n')) text += '\n';
      if (n.tagName === 'TD' || n.tagName === 'TH') { if (n.previousSibling) text += '\t'; }
      n.childNodes.forEach(walk);
      if (block && !text.endsWith('\n')) text += '\n';
    };
    walk(root);
    return text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  document.addEventListener('copy', ev => {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount || !ev.clipboardData) return;
    const range = sel.getRangeAt(0).cloneRange();
    const common = range.commonAncestorContainer;
    const host = common.nodeType === 1 ? common : common.parentElement;
    if (host && host.closest && host.closest('.cm-editor, input, textarea')) return;
    // A selection that starts or ends inside a formula takes the whole formula.
    const s = formula(range.startContainer), e = formula(range.endContainer);
    if (s) range.setStartBefore(s);
    if (e) range.setEndAfter(e);
    const frag = range.cloneContents();
    const ks = [...frag.querySelectorAll('.katex-display, .katex')].filter(k => !k.parentElement || !formula(k.parentElement));
    if (!ks.length && !s && !e) return;
    for (const k of ks) {
      const tex = source(k);
      if (tex !== null) k.replaceWith(document.createTextNode(tex));
    }
    const box = document.createElement('div');
    box.appendChild(frag);
    ev.clipboardData.setData('text/plain', plain(box));
    ev.clipboardData.setData('text/html', box.innerHTML);
    ev.preventDefault();
  });
})();
