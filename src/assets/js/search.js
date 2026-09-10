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
(function () {
  const LS = { q: 'slateFindQuery', r: 'slateFindReplace', case: 'slateFindCase',
               word: 'slateFindWord', re: 'slateFindRegex' };
  const on = k => localStorage.getItem(k) === '1';

  let bar = null, input = null, rInput = null, countEl = null, rRow = null, rToggle = null;
  const opt = { case: on(LS.case), word: on(LS.word), re: on(LS.re) };
  let matches = [];          // [{ cellId, from, to, groups }] in document order
  let cur = -1;              // index into `matches`, or -1 for none
  let painted = new Set();   // cells currently carrying highlights, so they can be cleared
  let lastFocus = null;      // where ⌘F was pressed, to restore on Escape

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

  // Every match in the notebook, in document order. `getCursor` takes an EditorState or a Text, so a
  // mounted cell is scanned in place and only an unmounted one pays for a `Text`. The capture groups
  // ride along for `$1` expansion in a regex replacement.
  function findAll() {
    const sq = query();
    if (!sq) return [];
    const Text = window.CM6.cmState.Text;
    const out = [];
    for (const id of cellIds()) {
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
        out.push({ cellId: id, from: r.value.from, to: r.value.to, groups: r.value.match || [] });
        if (out.length > 5000) return out;         // a pathological query stops being useful long before this
      }
    }
    return out;
  }

  // Hand each cell its own matches (the current one flagged) and clear any cell that had some and
  // no longer does.
  function paint() {
    const byCell = new Map();
    matches.forEach((m, i) => {
      if (!byCell.has(m.cellId)) byCell.set(m.cellId, []);
      byCell.get(m.cellId).push({ from: m.from, to: m.to, active: i === cur });
    });
    for (const id of painted) if (!byCell.has(id)) window.edMarkMatches && window.edMarkMatches(id, []);
    for (const [id, ranges] of byCell) window.edMarkMatches && window.edMarkMatches(id, ranges);
    painted = new Set(byCell.keys());
  }

  function clearPaint() {
    for (const id of painted) window.edMarkMatches && window.edMarkMatches(id, []);
    painted = new Set();
  }

  function status(text, bad) {
    if (!countEl) return;
    countEl.textContent = text;
    countEl.classList.toggle('bad', !!bad);
    if (input) input.classList.toggle('bad', !!bad);
  }

  function report() {
    status(!input.value ? ''
           : !matches.length ? 'No results'
           : cur >= 0 ? (cur + 1) + ' of ' + matches.length
           : matches.length + (matches.length === 1 ? ' result' : ' results'),
           !!input.value && !matches.length);
  }

  // Recompute, keeping the current match if it survived the edit, else the first one at or after
  // where it used to be. `keep` is the {cellId, from} to re-find.
  function recompute(keep) {
    if (query() === false) { matches = []; cur = -1; clearPaint(); status('Bad pattern', true); return; }
    matches = findAll();
    cur = -1;
    if (keep && matches.length) {
      const order = cellIds();
      const rank = m => [order.indexOf(m.cellId), m.from];
      const want = rank(keep);
      cur = matches.findIndex(m => { const r = rank(m); return r[0] > want[0] || (r[0] === want[0] && r[1] >= want[1]); });
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
    const cell = ((window.__slateState || window.nbState || {}).cells || []).find(c => c.id === m.cellId);
    if (cell && cell.codeHidden && window.toggleHideCode) { try { window.toggleHideCode(m.cellId); } catch (_) {} }
    try { window.selectCell && window.selectCell(m.cellId, true); } catch (_) {}
    window.edReveal && window.edReveal(m.cellId, m.from, m.to, mount);
    paint();                                   // the cell may have only just mounted an editor
    status((cur + 1) + ' of ' + matches.length);
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
  // `ensureEditor` returned null for exactly those cells and the edit was dropped on the floor —
  // a Replace All would rewrite the code cells, skip every line of prose, and report only the count
  // it managed. Opening the overlay is a visible change to the cell, which is why find-as-you-type
  // does not do it; a replace is a deliberate write, so here it is the right trade.
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

  function replaceAll() {
    recompute(matches[cur]);
    if (!matches.length) { report(); return; }
    const byCell = new Map();
    for (const m of matches) {
      if (!byCell.has(m.cellId)) byCell.set(m.cellId, []);
      byCell.get(m.cellId).push({ from: m.from, to: m.to, insert: replacement(m) });
    }
    let n = 0, skipped = 0;
    for (const [id, edits] of byCell) {
      if (applyToCell(id, edits)) n += edits.length; else skipped += edits.length;
    }
    cur = -1;
    recompute(null);
    // Say so when a cell refused the edit. Reporting only the successes reads as a completed
    // Replace All while matches are still sitting in the document.
    status(n + (n === 1 ? ' replacement' : ' replacements')
             + (skipped ? ' · ' + skipped + ' skipped' : ''), !!skipped);
    rInput.focus();
  }

  function showReplace(show) {
    rRow.hidden = !show;
    rToggle.textContent = show ? '⌄' : '›';
    rToggle.title = show ? 'Hide replace' : 'Show replace';
    rToggle.classList.toggle('on', show);
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
    if (matches.length && cur < 0) { cur = 0; paint(); status('1 of ' + matches.length); }
  }

  function close() {
    if (!bar) return;
    bar.classList.remove('show');
    clearPaint();
    matches = []; cur = -1;
    if (lastFocus && document.contains(lastFocus)) { try { lastFocus.focus(); } catch (_) {} }
    lastFocus = null;
  }

  window.slateSearchOpen = open;
  window.slateSearchClose = close;
  window.slateSearchStep = step;
  window.slateSearchReplace = replaceCurrent;
  window.slateSearchReplaceAll = replaceAll;

  // ⌘F / ⌘⌥F outside an editor. Inside one, the editor's own binding already ran and called
  // preventDefault (a cell opens this bar; the Files-tab editor opens CM6's single-file panel), so
  // `defaultPrevented` keeps the two from both firing on one keypress.
  document.addEventListener('keydown', e => {
    const mod = e.metaKey || e.ctrlKey;
    if (!mod || e.defaultPrevented) return;
    if (e.key === 'f' || e.key === 'F') {
      if (e.shiftKey) return;                             // ⌘⇧F is the controls palette
      e.preventDefault(); open(e.altKey);
    } else if (e.key === 'g' || e.key === 'G') {
      if (!bar || !bar.classList.contains('show')) return;
      e.preventDefault(); step(e.shiftKey ? -1 : 1);
    }
  });
})();
