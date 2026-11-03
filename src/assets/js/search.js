// Notebook-wide search and replace (⌘F / ⌘⌥F) — one find bar for the whole notebook rather than a
// panel inside the focused cell. In a notebook the thing you are looking for is usually in a
// DIFFERENT cell, so a per-cell find answers the wrong question; this walks every cell in document
// order, counts the hits, and steps through them across cell boundaries.
//
// Where the work is split: this file owns the bar, the query and the match list. Painting is
// editor.js's `edMarkMatches` (a StateField of decorations per editor) and `edReveal` (select +
// scroll, mounting a lazy editor if the match is in a cell that has not hydrated yet). A cell whose
// editor has not mounted still contributes matches — its text comes from `edText`, which falls back
// to the last server source — so the count is over the whole notebook, not just what is on screen.
//
// The match list is recomputed on every step rather than cached, so editing a cell mid-search can
// never leave a stale offset behind; the current match is re-found by (cell, offset) afterwards.
//
// A markdown or @bind cell shows its rendered form, and by default it is searched as it reads: the
// matches are in its rendered text, painted with the CSS Custom Highlight API, and the cell stays
// rendered. A match only its source holds (a link target, LaTeX) is listed as "in source"; stepping
// to one opens the source, and the search closes it again when it moves on, unless it was edited.
// The ¶ / </> switch searches every cell's source instead, and replacing always works on source.
(function () {
  const LS = { q: 'slateFindQuery', r: 'slateFindReplace', case: 'slateFindCase',
               word: 'slateFindWord', re: 'slateFindRegex', scope: 'slateFindScope' };
  const on = k => localStorage.getItem(k) === '1';

  let bar = null, input = null, rInput = null, countEl = null, rRow = null, rToggle = null;
  const opt = { case: on(LS.case), word: on(LS.word), re: on(LS.re) };
  let matches = [];          // [{ cellId, from, to, groups }] in document order
  let cur = -1;              // index into `matches`, or -1 for none
  let painted = new Set();   // cells currently carrying highlights, so they can be cleared
  let lastFocus = null;      // where ⌘F was pressed, to restore on Escape
  let scope = localStorage.getItem(LS.scope) === 'source' ? 'source' : 'rendered';
  let scopeBtn = null;
  const opened = new Set();  // rendered cells this search switched to their source, to switch back

  const cellIds = () => ((window.__slateState || window.nbState || {}).cells || []).map(c => c.id);
  const cellText = id => { try { return window.edText ? (window.edText(id) || '') : ''; } catch (_) { return ''; } };

  // The query as a CodeMirror `SearchQuery`, or null for an empty query, or false for an unparseable
  // one (which the bar reports rather than silently finding nothing).
  //
  // CodeMirror's own query object rather than a hand-built RegExp: it escapes a literal search, and
  // it decides "whole word" by character category instead of `\b`. That distinction matters here
  // because Julia encourages Unicode names — `\b` is defined on [A-Za-z0-9_], so `\b(?:α)\b` matches
  // nothing at all, and `\bcafé\b` matches inside `caférista` while missing a standalone `café`.
  // Multi-line patterns work either way. The Files-tab editor uses the same query type, so the two
  // search surfaces agree on what a match is.
  function query() {
    const q = input ? input.value : '';
    if (!q) return null;
    const S = window.CM6 && window.CM6.cmSearch;
    if (!S) return false;
    const sq = new S.SearchQuery({ search: q, caseSensitive: opt.case, regexp: opt.re, wholeWord: opt.word });
    return sq.valid ? sq : false;
  }

  // A one-character query over a book-length notebook finds tens of thousands of matches, which are
  // no use to anyone and cost a full rescan on every step. Stop at this many — but SAY so (`capped`),
  // because reporting a truncated total as though it were exact is worse than the truncation: the
  // count read `5001` on a notebook that held far more, and Replace All would have quietly rewritten
  // only the first slice of them.
  const MAX_MATCHES = 5000;
  let capped = false;

  // Replacing edits source, so matches come from the source while the replace row is open.
  const effScope = () => (rRow && !rRow.hidden) ? 'source' : scope;

  // The rendered view of a markdown or @bind cell whose source overlay is closed, else null.
  function renderedView(id) {
    const cell = document.getElementById('cell-' + id);
    const sed = cell && cell.querySelector('.srcedit');
    if (!sed || sed.style.display !== 'none') return null;
    return cell.querySelector('.md') || cell.querySelector('.binds');
  }

  // The text a reader sees in `root`, with the text node and offset each character came from. Block
  // elements are separated by a newline so a match cannot run from one paragraph into the next.
  // KaTeX keeps the LaTeX source in a visually hidden MathML copy; that is left out.
  const SKIP = new Set(['SCRIPT', 'STYLE', 'TEXTAREA', 'NOSCRIPT']);
  const BLOCK = new Set(['P', 'DIV', 'LI', 'UL', 'OL', 'DL', 'DT', 'DD', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
                         'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH', 'PRE', 'BLOCKQUOTE', 'SECTION',
                         'FIGURE', 'FIGCAPTION', 'DETAILS', 'SUMMARY', 'HR', 'BR']);
  function visibleText(root) {
    const segs = [];
    let text = '', lastBlock = null;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => {
        for (let e = n.parentElement; e && e !== root; e = e.parentElement)
          if (SKIP.has(e.tagName) || e.classList.contains('katex-mathml')) return NodeFilter.FILTER_REJECT;
        return n.data ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      },
    });
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      let b = n.parentElement;
      while (b && b !== root && !BLOCK.has(b.tagName)) b = b.parentElement;
      if (lastBlock && b !== lastBlock && !text.endsWith('\n')) text += '\n';
      lastBlock = b;
      segs.push({ node: n, start: text.length });
      text += n.data;
    }
    return { text, segs };
  }

  // A DOM Range for `[from, to)` of `visibleText`'s text.
  function domRange(segs, from, to) {
    const at = (pos, end) => {
      let lo = 0, hi = segs.length - 1;
      while (lo < hi) {
        const mid = (lo + hi + 1) >> 1;
        (end ? segs[mid].start < pos : segs[mid].start <= pos) ? (lo = mid) : (hi = mid - 1);
      }
      const sg = segs[lo];
      return [sg.node, Math.max(0, Math.min(sg.node.data.length, pos - sg.start))];
    };
    try {
      const r = document.createRange();
      r.setStart(...at(from, false));
      r.setEnd(...at(to, true));
      return r;
    } catch (_) { return null; }
  }

  // The matches in the text a reader sees in `root`, appended to `out` with the DOM range each one
  // covers and the fields in `extra`. Returns how many were added; sets `capped` at the cap.
  function scanRendered(root, id, sq, Text, out, extra) {
    const { text, segs } = visibleText(root);
    if (!segs.length) return 0;
    let cursor, n = 0;
    try { cursor = sq.getCursor(Text.of(text.split('\n'))); } catch (_) { return 0; }
    for (let r = cursor.next(); !r.done; r = cursor.next()) {
      const range = domRange(segs, r.value.from, r.value.to);
      if (!range) continue;
      out.push({ cellId: id, from: r.value.from, to: r.value.to, groups: r.value.match || [], range, ...extra });
      n++;
      if (out.length >= MAX_MATCHES) { capped = true; break; }
    }
    return n;
  }

  // The id shown in a cell's header, if it is on screen.
  function idView(id) {
    const cell = document.getElementById('cell-' + id);
    const cid = cell && cell.querySelector(':scope > .cellhead .cid');
    return cid && cid.offsetParent !== null ? cid : null;
  }

  // Every match in the notebook, in document order. `getCursor` takes an EditorState or a Text, so a
  // mounted cell is scanned in place and only an unmounted one pays for a `Text`. The capture groups
  // ride along for `$1` expansion in a regex replacement.
  //
  // A cell's id in its header is searched too, ahead of the cell's contents, so a cell can be found
  // by name. Not while replacing: that rewrites source, and must not offer to rename cells.
  function findAll() {
    capped = false;
    const sq = query();
    if (!sq) return [];
    const Text = window.CM6.cmState.Text;
    const out = [];
    const rendered = effScope() === 'rendered';
    const replacing = rRow && !rRow.hidden;
    for (const id of cellIds()) {
      const head = replacing ? null : idView(id);
      if (head) { scanRendered(head, id, sq, Text, out, { inId: true }); if (capped) return out; }
      let inSource = false;
      const disp = rendered ? renderedView(id) : null;
      if (disp) {
        const n = scanRendered(disp, id, sq, Text, out, {});
        if (capped) return out;
        if (n) continue;
        inSource = true;                          // nothing visible: what the source holds, flagged
      }
      const view = (window.editors || {})[id];
      const web = (window.webEditors || {})[id];
      // A mounted plain cell is scanned in place. A web cell is not: its panes hold the sections
      // while the offsets are against the assembled skin, so it is read as text like an unmounted
      // cell, and `edMarkMatches` moves the offsets back into the right pane.
      let doc;
      if (view && !web) doc = view.state;
      else { const t = cellText(id); if (!t) continue; doc = Text.of(t.split('\n')); }
      let cursor;
      try { cursor = sq.getCursor(doc); } catch (_) { continue; }
      for (let r = cursor.next(); !r.done; r = cursor.next()) {
        out.push({ cellId: id, from: r.value.from, to: r.value.to, groups: r.value.match || [], inSource });
        if (out.length >= MAX_MATCHES) { capped = true; return out; }
      }
    }
    return out;
  }

  // Hand each cell its own matches (the current one flagged) and clear any cell that had some and
  // no longer does.
  // Matches in rendered text are painted as two highlights, the current one on its own.
  const HL = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function';
  function paintRendered() {
    if (!HL) return;
    const rest = [], current = [];
    matches.forEach((m, i) => { if (m.range) (i === cur ? current : rest).push(m.range); });
    CSS.highlights.set('slate-find', new Highlight(...rest));
    CSS.highlights.set('slate-find-cur', new Highlight(...current));
  }
  function clearRendered() {
    if (!HL) return;
    CSS.highlights.delete('slate-find');
    CSS.highlights.delete('slate-find-cur');
  }

  // Close the source of every cell this search opened, except `keepId`'s. A cell edited while open
  // keeps its source, since closing would drop the edit.
  function restoreOpened(keepId) {
    for (const id of [...opened]) {
      if (id === keepId) continue;
      opened.delete(id);
      const cell = document.getElementById('cell-' + id);
      const sed = cell && cell.querySelector('.srcedit');
      if (!sed || sed.style.display === 'none') continue;
      const edited = (window.editors || {})[id] && window.edText(id) !== ((window.srcMap || {})[id] || '');
      if (!edited && window.cancelSource) window.cancelSource(id);
    }
  }

  function paint() {
    paintRendered();
    const byCell = new Map();
    matches.forEach((m, i) => {
      if (m.range) return;
      if (!byCell.has(m.cellId)) byCell.set(m.cellId, []);
      byCell.get(m.cellId).push({ from: m.from, to: m.to, active: i === cur });
    });
    for (const id of painted) if (!byCell.has(id)) window.edMarkMatches && window.edMarkMatches(id, []);
    for (const [id, ranges] of byCell) window.edMarkMatches && window.edMarkMatches(id, ranges);
    painted = new Set(byCell.keys());
  }

  function clearPaint() {
    clearRendered();
    for (const id of painted) window.edMarkMatches && window.edMarkMatches(id, []);
    painted = new Set();
  }

  function status(text, bad) {
    if (!countEl) return;
    countEl.textContent = text;
    countEl.classList.toggle('bad', !!bad);
    if (input) input.classList.toggle('bad', !!bad);
  }

  // How many matches there are, as a string. `5000+` once the scan stopped early — the total is not
  // known, so it must not be printed as though it were.
  const total = () => matches.length + (capped ? '+' : '');

  const where = () => (!matches[cur] ? '' : matches[cur].inSource ? ' · in source'
                       : matches[cur].inId ? ' · cell name' : '');

  function report() {
    status(!input.value ? ''
           : !matches.length ? 'No results'
           : cur >= 0 ? (cur + 1) + ' of ' + total() + where()
           : total() + (matches.length === 1 ? ' result' : ' results'),
           !!input.value && !matches.length);
  }

  // Recompute, keeping the current match if it survived the edit, else the first one at or after
  // where it used to be. `keep` is the {cellId, from, inId} to re-find; a cell's id comes before
  // its contents, whose offsets start from zero as well.
  function recompute(keep) {
    if (query() === false) { matches = []; cur = -1; clearPaint(); status('Bad pattern', true); return; }
    matches = findAll();
    cur = -1;
    if (keep && matches.length) {
      const order = cellIds();
      const rank = m => [order.indexOf(m.cellId), m.inId ? 0 : 1, m.from];
      const want = rank(keep);
      const after = r => r[0] !== want[0] ? r[0] > want[0] : r[1] !== want[1] ? r[1] > want[1] : r[2] >= want[2];
      cur = matches.findIndex(m => after(rank(m)));
      if (cur < 0) cur = 0;
    }
    paint();
    report();
  }

  // Scroll the current match into view and select it, WITHOUT taking focus off the find box —
  // stepping with Enter has to stay possible. A cell whose code is hidden is revealed first,
  // otherwise the match would be scrolled to behind a collapsed body.
  function reveal(focusEl, mount) {
    const m = matches[cur];
    if (!m) return;
    restoreOpened(m.cellId);
    try { window.selectCell && window.selectCell(m.cellId, true); } catch (_) {}
    if (m.range) {
      const el = m.range.startContainer.parentElement;
      el && el.scrollIntoView({ block: 'center' });
    } else {
      const cell = ((window.__slateState || window.nbState || {}).cells || []).find(c => c.id === m.cellId);
      if (cell && cell.codeHidden && window.toggleHideCode) { try { window.toggleHideCode(m.cellId); } catch (_) {} }
      if (mount && renderedView(m.cellId)) opened.add(m.cellId);
      window.edReveal && window.edReveal(m.cellId, m.from, m.to, mount);
    }
    paint();                                   // the cell may have only just mounted an editor
    status((cur + 1) + ' of ' + total() + where());
    (focusEl || input).focus();
  }

  function step(dir, focusEl) {
    const keep = matches[cur];
    recompute(keep);
    if (!matches.length) return;
    // After a recompute `cur` already points AT the old match, so stepping forward from it is one
    // move; stepping back from a re-found (not stepped-to) match is also one.
    cur = ((cur < 0 ? (dir > 0 ? -1 : 0) : cur) + dir + matches.length) % matches.length;
    reveal(focusEl, true);
  }

  // ── Replace ───────────────────────────────────────────────────────────────────
  // `$1`…`$9`, `$&` and `$$` expand only in regex mode, matching what VS Code does: in plain mode
  // the replacement is literal, so a `$` in it stays a `$`.
  function replacement(m) {
    const tpl = rInput ? rInput.value : '';
    if (!opt.re) return tpl;
    return tpl.replace(/\$(\d|&|\$)/g, (_s, d) =>
      d === '$' ? '$' : d === '&' ? m.groups[0] : (m.groups[+d] == null ? '' : m.groups[+d]));
  }

  // Apply one cell's edits, which must be in ascending, non-overlapping order.
  //
  // A web cell is the awkward case: its match offsets are against the ASSEMBLED `@web(html"…",
  // css"…", js"…")` source that `edText` returns, not against any one of its three panes, so an
  // offset cannot be dispatched to a pane. Rebuild the whole source and hand it to `edSetText`,
  // which splits it back into the panes the same way an agent edit does. Every other cell takes a
  // precise CodeMirror transaction, which keeps that cell's own undo history usable.
  //
  // `edEnsureSource`, not `ensureEditor`: a markdown or @bind cell renders its output and keeps its
  // source in a hidden overlay, so it has NO editor until that overlay is opened. Resolving with
  // `ensureEditor` returned null for exactly those cells and the edit was dropped on the floor.
  // Opening the overlay is a visible change to the cell, which is why find-as-you-type does not do
  // it; replacing ONE match is a deliberate write to a cell you have already stepped to, so here it
  // is the right trade. (Replace All does not come through here — see `replaceAll`.)
  function applyToCell(cellId, edits) {
    if (window.webEditors && window.webEditors[cellId]) {
      const src = cellText(cellId);
      let out = '', at = 0;
      for (const e of edits) { out += src.slice(at, e.from) + e.insert; at = e.to; }
      window.edSetText(cellId, out + src.slice(at));
      return true;
    }
    const v = window.edEnsureSource ? window.edEnsureSource(cellId)
                                    : (window.ensureEditor && window.ensureEditor(cellId));
    if (!v) return false;
    const max = v.state.doc.length;
    const changes = edits
      .filter(e => e.to <= max)
      .map(e => ({ from: e.from, to: e.to, insert: e.insert }));
    if (!changes.length) return false;
    try { v.dispatch({ changes }); } catch (_) { return false; }
    return true;
  }

  // Replace the current match, then land on the one that follows it.
  function replaceCurrent() {
    recompute(matches[cur]);
    const m = matches[cur];
    if (!m) return;
    const where = { cellId: m.cellId, from: m.from };
    applyToCell(m.cellId, [{ from: m.from, to: m.to, insert: replacement(m) }]);
    // The edit shifted every later offset in that cell, so re-find from where this match started.
    recompute(where);
    if (matches.length) reveal(rInput, true);
    else { paint(); report(); rInput.focus(); }
  }

  // Replace every match in the notebook — ONE operation, applied by the server.
  //
  // Not a loop of editor edits. A bulk rewrite has to be reversible as the single thing you asked
  // for, and applying it here would leave one CM6 undo stack per touched cell: undoing a replace
  // across nine cells would mean nine ⌘Z presses in nine editors, and a web cell could not be undone
  // from the cell at all. `/api/cells-replace` puts the whole rewrite on the notebook's undo stack
  // (⌘Z reverses it, and the toast reads back the label below) and records one timeline checkpoint.
  //
  // Each cell's COMPLETE new text goes over, not the match offsets: the server holds the last SAVED
  // source, so sending offsets would apply them to the wrong text whenever a cell has unsaved edits.
  // Building the text here from `cellText` — which reads the live editor — is what carries those in.
  async function replaceAll() {
    recompute(matches[cur]);
    if (!matches.length) { report(); return; }
    // The scan stopped at the cap, so "every match" is not what we hold. Replacing anyway would
    // rewrite an arbitrary prefix of the notebook and report it as done; narrow the query instead.
    if (capped) {
      status(`Over ${MAX_MATCHES} matches — narrow the search first`, true);
      rInput.focus();
      return;
    }
    const byCell = new Map();
    for (const m of matches) {
      if (!byCell.has(m.cellId)) byCell.set(m.cellId, []);
      byCell.get(m.cellId).push({ from: m.from, to: m.to, insert: replacement(m) });
    }
    const edits = {};
    let n = 0;
    for (const [id, ms] of byCell) {
      const src = cellText(id);
      let out = '', at = 0;
      for (const e of ms) { out += src.slice(at, e.from) + e.insert; at = e.to; }
      edits[id] = out + src.slice(at);
      n += ms.length;
    }
    const q = input.value, r = rInput ? rInput.value : '';
    const label = `replace ${JSON.stringify(q)} → ${JSON.stringify(r)} `
                + `(${n} in ${byCell.size} ${byCell.size === 1 ? 'cell' : 'cells'})`;
    status('Replacing…');
    let st = null;
    try { st = await window.api('POST', '/api/cells-replace', { edits, label }); }
    catch (_) { status('Replace failed', true); rInput.focus(); return; }
    // The server owns the sources now, so re-render from what it returned rather than trusting the
    // editors — cells it restaled have to show that.
    // Bare `lastVersion`, not `window.lastVersion`: core.js declares it with `let`, so it is a global
    // LEXICAL binding and never a property of `window` — assigning through `window` would set a
    // shadow and leave the real one stale. Same idiom as `histRestore` in panels.js.
    // …and rebaseline first: a replacement THIS tab asked for is not an external edit, and an open
    // editor whose cell was rewritten would otherwise be offered the reconcile modal.
    if (st && st.cells) {
      window.slateRebaselineAll && window.slateRebaselineAll(st);
      renderAll(st);
      if (st.version != null) lastVersion = st.version;
    }
    cur = -1;
    recompute(null);
    status(n + (n === 1 ? ' replacement' : ' replacements') + ' · ⌘Z to undo');
    rInput.focus();
  }

  function showReplace(show) {
    const was = !rRow.hidden;
    rRow.hidden = !show;
    rToggle.textContent = show ? '⌄' : '›';
    rToggle.title = show ? 'Hide replace' : 'Show replace';
    rToggle.classList.toggle('on', show);
    showScope();
    if (was !== show && bar.classList.contains('show') && input.value) recompute(matches[cur]);
  }

  function showScope() {
    if (!scopeBtn) return;
    const s = effScope();
    scopeBtn.textContent = s === 'source' ? '</>' : '¶';
    scopeBtn.classList.toggle('on', scope === 'source');
    scopeBtn.disabled = !rRow.hidden;
    scopeBtn.title = !rRow.hidden ? 'Replacing works on the source'
      : s === 'source' ? 'Searching source; click to search the rendered text'
      : 'Searching the rendered text; click to search source';
  }

  function build() {
    if (bar) return;
    bar = document.createElement('div');
    bar.className = 'nbfind';
    bar.innerHTML =
      '<button class="nbfind-toggle" title="Show replace">›</button>' +
      '<div class="nbfind-rows">' +
        '<div class="nbfind-row">' +
          '<input type="text" class="nbfind-q" placeholder="Find in notebook" spellcheck="false"/>' +
          '<span class="nbfind-count"></span>' +
          '<button class="nbfind-opt" data-opt="case" title="Match case">Aa</button>' +
          '<button class="nbfind-opt" data-opt="word" title="Match whole word">ab</button>' +
          '<button class="nbfind-opt" data-opt="re" title="Use regular expression">.*</button>' +
          '<button class="nbfind-scope"></button>' +
          '<button class="nbfind-nav" data-nav="-1" title="Previous match (⇧⏎)">↑</button>' +
          '<button class="nbfind-nav" data-nav="1" title="Next match (⏎)">↓</button>' +
          '<button class="nbfind-x" title="Close (Esc)">✕</button>' +
        '</div>' +
        '<div class="nbfind-row nbfind-rrow" hidden>' +
          '<input type="text" class="nbfind-r" placeholder="Replace" spellcheck="false"/>' +
          '<button class="nbfind-do" data-all="0" title="Replace this match (⏎)">Replace</button>' +
          '<button class="nbfind-do" data-all="1" title="Replace every match in the notebook (⌘⏎)">All</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(bar);
    input = bar.querySelector('.nbfind-q');
    rInput = bar.querySelector('.nbfind-r');
    countEl = bar.querySelector('.nbfind-count');
    rRow = bar.querySelector('.nbfind-rrow');
    rToggle = bar.querySelector('.nbfind-toggle');

    rToggle.onclick = () => { showReplace(rRow.hidden); if (!rRow.hidden) rInput.focus(); };
    for (const b of bar.querySelectorAll('.nbfind-opt')) {
      const k = b.dataset.opt;
      b.classList.toggle('on', opt[k]);
      b.onclick = () => {
        opt[k] = !opt[k];
        localStorage.setItem(LS[k], opt[k] ? '1' : '0');
        b.classList.toggle('on', opt[k]);
        recompute(matches[cur]);
        input.focus();
      };
    }
    scopeBtn = bar.querySelector('.nbfind-scope');
    scopeBtn.onclick = () => {
      scope = scope === 'source' ? 'rendered' : 'source';
      localStorage.setItem(LS.scope, scope);
      showScope();
      restoreOpened(null);
      recompute(null);
      if (matches.length) { cur = 0; reveal(); }
      input.focus();
    };
    for (const b of bar.querySelectorAll('.nbfind-nav')) b.onclick = () => step(+b.dataset.nav);
    for (const b of bar.querySelectorAll('.nbfind-do'))
      b.onclick = () => (b.dataset.all === '1' ? replaceAll() : replaceCurrent());
    bar.querySelector('.nbfind-x').onclick = () => close();

    let t = null;
    input.oninput = () => {
      localStorage.setItem(LS.q, input.value);
      clearTimeout(t);
      t = setTimeout(() => { recompute(null); if (matches.length) { cur = 0; reveal(); } }, 140);
    };
    rInput.oninput = () => localStorage.setItem(LS.r, rInput.value);
    input.onkeydown = e => {
      if (e.key === 'Enter') { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
      else if (e.key === 'Escape') { e.preventDefault(); close(); }
      // ⌘F inside the box re-selects the query, the way a second ⌘F does everywhere else.
      else if ((e.metaKey || e.ctrlKey) && (e.key === 'f' || e.key === 'F')) { e.preventDefault(); input.select(); }
      else if ((e.metaKey || e.ctrlKey) && (e.key === 'g' || e.key === 'G')) { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
    };
    rInput.onkeydown = e => {
      if (e.key === 'Enter') { e.preventDefault(); (e.metaKey || e.ctrlKey) ? replaceAll() : replaceCurrent(); }
      else if (e.key === 'Escape') { e.preventDefault(); close(); }
    };
    showReplace(false);
  }

  // Opening seeds the box from the selection in the focused editor (VS Code's "find what I have
  // highlighted"), else from the last query, and selects it so typing replaces it. `withReplace`
  // opens the replace row as well (⌘⌥F).
  function open(withReplace) {
    build();
    const active = document.activeElement;
    lastFocus = (active && active.closest && active.closest('.cm-editor')) ? active : null;
    let seed = '';
    for (const v of Object.values(window.editors || {})) {
      if (!v.hasFocus) continue;
      const sel = v.state.selection.main;
      if (!sel.empty && sel.to - sel.from < 200) seed = v.state.doc.sliceString(sel.from, sel.to);
      break;
    }
    bar.classList.add('show');
    if (withReplace) showReplace(true);
    input.value = seed || input.value || localStorage.getItem(LS.q) || '';
    if (!rInput.value) rInput.value = localStorage.getItem(LS.r) || '';
    input.focus(); input.select();
    recompute(null);
    if (matches.length && cur < 0) { cur = 0; paint(); status('1 of ' + total()); }
  }

  function close() {
    if (!bar) return;
    bar.classList.remove('show');
    clearPaint();
    restoreOpened(null);
    matches = []; cur = -1;
    if (lastFocus && document.contains(lastFocus)) { try { lastFocus.focus(); } catch (_) {} }
    lastFocus = null;
  }

  window.slateSearchOpen = open;
  window.slateSearchClose = close;
  window.slateSearchStep = step;
  window.slateSearchReplace = replaceCurrent;
  window.slateSearchReplaceAll = replaceAll;

  // Opening the bar is the `view.search` / `view.replace` command (commands.js); the keymap decides
  // which chord does it and keeps the editor's binding and the document's from both firing on one
  // keypress. Stepping between hits stays here, because it only means anything while the bar is up —
  // it declines the key otherwise, so the browser's own Find Again keeps working when the bar is shut.
  window.slateSearchStepKey = back => {
    if (!bar || !bar.classList.contains('show')) return false;
    step(back ? -1 : 1);
    return true;
  };
})();
