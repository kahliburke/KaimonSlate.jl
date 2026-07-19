// Preact notebook view — Phase 2+3 of the migration. Owns #nb and diffs cells by id, so
// CodeMirror editors and live figures SURVIVE structural ops (add/move/delete/rename) instead
// of being wiped and rebuilt on every renderAll. The signals store (store.js) is the source;
// the per-cell HTML and the imperative output processors are reused from the classic scripts
// via window.* (see the expose block at the end of view.js). One single render path.
//
// The top-level render is driven by an explicit `effect()` reading the store signals and
// passing them as props — robust regardless of component auto-subscription, and Preact still
// diffs the keyed <Cell>/<Editor> children so editors are preserved across re-renders.
import { html, render } from 'htm/preact';
import { useRef, useEffect } from 'preact/hooks';
import { effect } from '@preact/signals';
import { cells as cellsSignal, selected as selectedSignal, selectedSet as selectedSetSignal, liveStates as liveSignal, focus as focusSignal } from './store.js';

const raw = s => ({ __html: s || '' });
const _reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

// Dep-focus: the SET of cell ids in `id`'s dependency CHAIN — itself, its transitive precursors
// (deps), and its transitive dependents — so focusing on a cell shows just that flow. Returns a
// Set, or `null` when nothing is focused (→ every cell visible). All cells stay mounted either
// way; cells outside the cone are animated collapsed (see <Cell>), so editors/figures survive.
function _coneIds(cells, id) {
  if (!id) return null;
  const byId = {}; cells.forEach(c => (byId[c.id] = c));
  if (!byId[id]) return null;
  const cone = new Set([id]);
  const up = x => (byId[x]?.deps || []).forEach(d => { if (!cone.has(d)) { cone.add(d); up(d); } });
  up(id);                                            // upstream precursors
  // downstream dependents: reachability from `id` ONLY (seeding from the whole cone would pull
  // in siblings that merely share a precursor like `setup`).
  const down = new Set();
  let changed = true;
  while (changed) {
    changed = false;
    for (const c of cells) {
      if (down.has(c.id) || c.id === id) continue;
      if ((c.deps || []).some(d => d === id || down.has(d))) { down.add(c.id); changed = true; }
    }
  }
  down.forEach(x => cone.add(x));
  return cone;
}

// Smoothly collapse a cell out of the flow (focus dropped it from the cone) or expand it back,
// by animating max-height/opacity/margin. max-height is set to the MEASURED pixel height first
// (not a guessed large value), so there's no "wait then snap" — neighbours flow as it shrinks.
function _animateCollapse(el, collapse) {
  const T = 'max-height .26s ease, opacity .18s ease, margin .26s ease, border-top-width .26s, border-bottom-width .26s';
  if (_reduceMotion) {                               // honour the OS setting: no tween, just the end state
    el.style.maxHeight = collapse ? '0px' : '';
    el.style.opacity = collapse ? '0' : '';
    el.style.marginTop = el.style.marginBottom = collapse ? '0px' : '';
    el.style.borderTopWidth = el.style.borderBottomWidth = collapse ? '0px' : '';
    return;
  }
  if (collapse) {
    el.style.maxHeight = el.scrollHeight + 'px';     // start from the real height
    el.getBoundingClientRect();                      // force reflow so the next change transitions
    el.style.transition = T;
    el.style.maxHeight = '0px'; el.style.opacity = '0';
    el.style.marginTop = '0px'; el.style.marginBottom = '0px';
    el.style.borderTopWidth = '0px'; el.style.borderBottomWidth = '0px';
  } else {
    el.style.maxHeight = 'none';                      // measure natural height
    const full = el.scrollHeight;
    el.style.maxHeight = '0px';
    el.getBoundingClientRect();                       // reflow at collapsed size
    el.style.transition = T;
    el.style.maxHeight = full + 'px'; el.style.opacity = '1';
    el.style.marginTop = '14px'; el.style.marginBottom = '14px';   // back to the .cell CSS value
    el.style.borderTopWidth = '1px'; el.style.borderBottomWidth = '1px';
    const done = e => {                               // wait for max-height (the longest) before cleanup
      if (e.target !== el || e.propertyName !== 'max-height') return;
      el.removeEventListener('transitionend', done);
      el.style.maxHeight = el.style.transition = el.style.marginTop = el.style.marginBottom = el.style.borderTopWidth = el.style.borderBottomWidth = '';
    };
    el.addEventListener('transitionend', done);
  }
}

// <Editor>: a CodeMirror created into a host div and preserved. To keep a large notebook from
// freezing on load (each CM6 mount costs ~tens of ms), the real editor is mounted LAZILY — a cheap
// static <pre> placeholder shows the code immediately, and the EditorView is created when the cell
// nears the viewport (IntersectionObserver), when something needs it (ensureEditor), or during idle
// background hydration (hydrateSoon) — whichever comes first. The placeholder is plain DOM appended
// in the effect (NOT Preact's vdom — the returned host stays empty), so reconciliation never
// disturbs the editor we append. Once mounted, cursor/undo/scroll survive notebook updates.
function Editor({ cell }) {
  const ref = useRef(null);
  useEffect(() => {
    const host = ref.current;
    host.querySelector('.cm-editor')?.remove();               // guard against a stacked editor in a reused host
    const ph = document.createElement('pre');
    ph.className = 'cm-placeholder'; ph.textContent = cell.source || '';
    host.appendChild(ph);
    let view = null;
    const mount = () => {
      if (view) return view;
      try { io.disconnect(); } catch (_) {}
      const p = host.querySelector('.cm-placeholder'); if (p) p.remove();
      let primed = false;
      view = window.mkEditor(host, {
        doc: cell.source, cellId: cell.id,
        // Compare against the LIVE server source (srcMap), NOT the mount-time `cell.source` closure —
        // else applying an agent/external edit via edSetText (which fires this) would look like a USER
        // edit, falsely marking the cell `edited` + backing it up, which later pops phantom reconcile
        // popups for cells you never touched. (Mirrors the editSource editor.)
        onDoc: () => { if (primed && window.edText(cell.id) !== (window.srcMap[cell.id] || '')) { window.setState(cell.id, 'edited'); window._backupSoon && window._backupSoon(); } },
        onFocus: () => window.setEditing(cell.id, true),
        onBlur: () => window.setEditing(cell.id, false),
        keys: [
          { key: 'Shift-Enter', run: () => window.runCell(cell.id) },
          { key: 'Shift-Mod-Enter', run: () => window.runAndAddBelow(cell.id) },
          { key: 'Shift-Ctrl-Enter', run: () => window.runAndAddBelow(cell.id) },
          { key: 'Shift-Mod--', run: () => window.splitCell(cell.id, view) },
          { key: 'Shift-Ctrl--', run: () => window.splitCell(cell.id, view) },
        ],
      });
      setTimeout(() => primed = true, 0);
      // Apply a pending unsaved-edit restore (restore.js): a prior session's in-flight text.
      const pend = window._pendingRestore && window._pendingRestore[cell.id];
      if (pend != null) { window.edSetText(cell.id, pend); window.setState && window.setState(cell.id, 'edited'); delete window._pendingRestore[cell.id]; }
      return view;
    };
    // ensureEditor(id) and the IO both call the (idempotent) mount; register so ensureEditor finds it.
    (window._editorMount || (window._editorMount = {}))[cell.id] = mount;
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) mount(); }, { rootMargin: '600px 0px' });
    io.observe(host);
    window.hydrateSoon && window.hydrateSoon('ed:' + cell.id, mount);   // background fallback for off-screen cells
    return () => {
      try { io.disconnect(); } catch (_) {}
      if (window._editorMount) delete window._editorMount[cell.id];
      if (window.editors[cell.id] === view) delete window.editors[cell.id];
      try { view && view.destroy(); } catch (_) {}
    };
  }, []);
  return html`<div ref=${ref} class="srchost"></div>`;
}

// <WebEditor>: a web cell's HTML/CSS/JS editor. Not all web cells need all three panes, so only the ones
// with content are mounted (a fresh cell opens JS-only — most widgets render into `root`); absent panes
// show a `+ HTML`/`+ CSS`/`+ JS` chip to add one, and each mounted pane has a `×` to remove it. Panes stay
// in HTML→CSS→JS order regardless of add order. Each pane is a CM6 view with its native grammar; on any
// edit they reassemble into the `@web(...)` source (via _webSkin, which OMITS empty sections) so run/save
// see ONE source. The first mounted pane is registered in `window.editors[id]` so the generic cell logic
// (edited-state, reveal-measure) works; edText/edSetText route through `window.webEditors[id]`.
const _WEB_LANGS = [['html', 'HTML'], ['css', 'CSS'], ['js', 'JS']];
function WebEditor({ cell }) {
  const ref = useRef(null);
  useEffect(() => {
    const host = ref.current;
    host.querySelector('.webedit')?.remove();
    const wrap = document.createElement('div'); wrap.className = 'webedit';
    host.appendChild(wrap);
    const chips = document.createElement('div'); chips.className = 'webadd';
    wrap.appendChild(chips);                              // add-chips row stays LAST
    const secs = cell.web || window._webSections(cell.source) || { html: '', css: '', js: '' };
    const idx = l => _WEB_LANGS.findIndex(x => x[0] === l);
    const label = l => (_WEB_LANGS.find(x => x[0] === l) || [, ''])[1];
    const panes = {};   // lang → EditorView (mounted only)
    const boxes = {};   // lang → pane element
    let primed = false;

    // Only mounted panes contribute — a removed pane's content is dropped from the assembled source.
    const assemble = () => window._webSkin({
      html: panes.html ? panes.html.state.doc.toString() : '',
      css:  panes.css  ? panes.css.state.doc.toString()  : '',
      js:   panes.js   ? panes.js.state.doc.toString()   : '',
    });
    const onAnyDoc = () => {
      if (primed && assemble() !== (window.srcMap[cell.id] || '')) { window.setState(cell.id, 'edited'); window._backupSoon && window._backupSoon(); }
    };
    const setPrimary = () => {                            // a real view for edited-state/measure
      const first = _WEB_LANGS.map(x => x[0]).find(l => panes[l]);
      if (first) window.editors[cell.id] = panes[first]; else delete window.editors[cell.id];
    };
    const refreshChips = () => {
      chips.innerHTML = '';
      for (const [l, lab] of _WEB_LANGS) {
        if (panes[l]) continue;
        const b = document.createElement('button');
        b.className = 'webadd-chip'; b.type = 'button'; b.textContent = '+ ' + lab;
        b.onclick = () => { addPane(l, ''); const v = panes[l]; v && v.focus(); };
        chips.appendChild(b);
      }
    };
    function addPane(lang, code) {
      if (panes[lang]) return;
      const box = document.createElement('div'); box.className = 'webpane webpane-' + lang;
      const head = document.createElement('div'); head.className = 'webpane-label';
      const name = document.createElement('span'); name.textContent = label(lang);
      const rm = document.createElement('button'); rm.className = 'webpane-rm'; rm.type = 'button';
      rm.title = 'remove this pane'; rm.textContent = '×'; rm.onclick = () => removePane(lang);
      head.appendChild(name); head.appendChild(rm);
      const edhost = document.createElement('div'); edhost.className = 'webpane-ed';
      box.appendChild(head); box.appendChild(edhost);
      boxes[lang] = box;
      const later = _WEB_LANGS.map(x => x[0]).find(l => idx(l) > idx(lang) && boxes[l]);
      wrap.insertBefore(box, later ? boxes[later] : chips);   // keep HTML→CSS→JS order, before the chips
      panes[lang] = window.mkEditor(edhost, {
        doc: code || '', lang,
        onDoc: onAnyDoc,
        onFocus: () => window.setEditing(cell.id, true),
        onBlur: () => window.setEditing(cell.id, false),
        keys: [
          { key: 'Shift-Enter', run: () => window.runCell(cell.id) },
          { key: 'Shift-Mod-Enter', run: () => window.runAndAddBelow(cell.id) },
          { key: 'Shift-Ctrl-Enter', run: () => window.runAndAddBelow(cell.id) },
        ],
      });
      setPrimary(); refreshChips(); onAnyDoc();
    }
    function removePane(lang) {
      const v = panes[lang]; if (!v) return;
      try { v.destroy(); } catch (_) {}
      delete panes[lang];
      if (boxes[lang]) { boxes[lang].remove(); delete boxes[lang]; }
      setPrimary(); refreshChips(); onAnyDoc();           // dropping a pane changes the assembled source
    }

    // Initial panes: the sections that have content, else JS-only for a fresh web cell.
    const activeLangs = _WEB_LANGS.map(x => x[0]).filter(l => (secs[l] || '').trim() !== '');
    if (!activeLangs.length) activeLangs.push('js');
    for (const [l] of _WEB_LANGS) if (activeLangs.includes(l)) addPane(l, secs[l] || '');

    (window.webEditors || (window.webEditors = {}))[cell.id] = { panes, assemble, addPane };
    setTimeout(() => { primed = true; }, 0);
    return () => {
      if (window.editors[cell.id] && Object.values(panes).includes(window.editors[cell.id])) delete window.editors[cell.id];
      Object.values(panes).forEach(v => { try { v.destroy(); } catch (_) {} });
      if (window.webEditors) delete window.webEditors[cell.id];
    };
  }, []);
  return html`<div ref=${ref} class="srchost webhost"></div>`;
}

function Cell({ cell, selectedId, selSet, live, focusId, collapsed }) {
  const c = cell;
  const ref = useRef(null);
  const last = useRef({ bindKey: undefined, ctrlKey: undefined, out: undefined, vis: undefined });
  let state = (live && live[c.id]) || c.state;   // transient (running/edited) wins until server state arrives
  // A cell whose editor diverges from its saved source stays `edited` even after a server-state
  // push clears the transient live mark (applyState wipes liveStates) — derive it from the editor
  // so an unsaved edit doesn't silently read as `fresh`. Covers code cells and OPEN markdown/@bind
  // source editors; `running` still wins (it's executing).
  if (state !== 'running') {
    if (window.editors[c.id] && window.edText(c.id) !== c.source) state = 'edited';
  }

  // Dep-focus: cells outside the focused cone collapse out of the flow (and expand back) rather
  // than unmounting, so the transition is smooth and editors/figures survive. Animate only on a
  // real change; `false` initial avoids animating the first mount of an already-collapsed cell.
  const wasCollapsed = useRef(false);
  useEffect(() => {
    const el = ref.current;
    if (el && collapsed !== wasCollapsed.current) { wasCollapsed.current = collapsed; _animateCollapse(el, collapsed); }
  }, [collapsed]);

  // Dispose this cell's ECharts when it unmounts; charts otherwise update in place.
  useEffect(() => () => {
    const cs = window.charts[c.id];
    if (cs) { cs.forEach(i => { try { i.dispose(); } catch (_) {} }); delete window.charts[c.id]; }
    const el = ref.current;   // inline `{{ echart }}` instances live on the nodes, not in window.charts
    if (el) el.querySelectorAll('.ichart').forEach(e => { if (e._inst) { try { e._inst.dispose(); } catch (_) {} } });
    // Cancel any pending debounced snapshot (core.js _snapCell) — its closure holds a reference
    // to the now-disposed chart instances and would otherwise fire against a removed cell.
    if (window._cancelSnap) window._cancelSnap(c.id);
  }, []);

  // Fill/update the cell's content IMPERATIVELY via the vanilla helpers, so live widgets aren't
  // recreated on a value echo (a drag survives), outputs swap in place (no flash in cells below),
  // and a CodeMirror created inside a collapsed cell is refreshed once it becomes visible (it
  // renders blank otherwise). The hosts in the returned vnode are stable, so Preact keeps them.
  useEffect(() => {
    const el = ref.current; if (!el) return;
    // An EXTERNAL source change (agent edit, file watcher, another tab) must refresh the editor —
    // the always-on <Editor> is created once and never re-applies cell.source, so without this an
    // agent edit updates the output but leaves the editor showing the OLD source. Only refresh when
    // the user has no unsaved local edits (editor still matches the prior server source), so we
    // never clobber in-flight work; a true divergence stays `edited` for the reconcile flow.
    const _prevSrc = window.srcMap[c.id];
    const _prevHash = (window.srcHash || (window.srcHash = {}))[c.id];
    window.srcMap[c.id] = c.source;
    window.srcHash[c.id] = c.hash;
    // Compare trailing-whitespace-insensitively: a lone trailing newline (which CM6 and the server
    // can disagree on) is not a real edit and must NOT pop the conflict modal.
    const _eq = (a, b) => (a || '').replace(/\s+$/, '') === (b || '').replace(/\s+$/, '');
    // The server's per-cell content hash is the authoritative "did THIS cell change" signal — immune to
    // browser-side srcMap drift. Fall back to a string compare only if an older state carries no hash.
    const _serverMoved = (c.hash != null && _prevHash != null) ? c.hash !== _prevHash : !_eq(c.source, _prevSrc);
    if (window.editors[c.id] && _serverMoved) {
      const _mine = window.edText(c.id);
      if (_eq(_mine, _prevSrc)) window.edSetText(c.id, c.source);                       // no local edits → fast-forward to the new source
      else if (!_eq(_mine, c.source) && window.slateLiveConflict) window.slateLiveConflict(c.id, _mine, c.source);   // both changed → reconcile modal
    } else if (!window.editors[c.id] && _serverMoved) {
      const ph = el.querySelector('.cm-placeholder'); if (ph) ph.textContent = c.source || '';   // not yet hydrated → keep placeholder current
    }
    const badge = el.querySelector('.badge');     // header renders c.state; reflect the live state
    if (badge && badge.textContent !== state) badge.textContent = state;
    // Durable-cache badge — the memo verdict arrives with a run (celldone), AFTER the header mounted,
    // so patch it in place (like `.badge`) keyed on memo+reason rather than re-rendering the header.
    const head = el.querySelector('.cellhead');
    if (head) {
      const mkey = (c.memo || '') + '\x1f' + (c.memoWhy || '');
      if (head.dataset.memokey !== mkey) {
        head.dataset.memokey = mkey;
        const slot = head.querySelector('.memoslot');   // fixed-width slot rendered in the header; just refill it
        if (slot) slot.innerHTML = window._memoBadge(c);
      }
      // Interim stored-render badge: present during hydration (c.preview), cleared the moment a live
      // celldone (no preview flag) replaces the cell — patch the slot in place like the memo badge.
      const pkey = c.preview ? (c.previewStale ? 'stale' : 'stored') : '';
      if (head.dataset.previewkey !== pkey) {
        head.dataset.previewkey = pkey;
        const pslot = head.querySelector('.previewslot');
        if (pslot) pslot.innerHTML = window._previewBadge(c);
      }
    }

    if (c.kind === 'md') {
      const md = el.querySelector('.md'); const h = window.mdHtml(c);
      if (md && h !== last.current.out) {
        // Dispose any inline `{{ echart }}` instances before the innerHTML swap orphans their nodes
        // (their ECharts instance + zrender would otherwise leak on every markdown re-render).
        md.querySelectorAll('.ichart').forEach(e => { if (e._inst) { try { e._inst.dispose(); } catch (_) {} e._inst = null; } });
        last.current.out = h; window._swapOutput(md, h); window.typesetVisible(md, c.id);
      }
      return;
    }

    // The cell's own @bind rows (`.binds`) and its surfaced-control strip (`.controls`) are
    // INDEPENDENT structures — a MIXED cell (e.g. a plot that also declares @bind) has both.
    // (Re)build each ONLY when ITS structure changes — never on a value echo — then sync
    // values in place. Keyed on names/widgets/params (value excluded so dragging a slider
    // doesn't rebuild). The binds key also tracks `hosted`/`hostedby` (a row flips between live
    // widget and jump-chip as it's surfaced/unsurfaced); the strip keys on `controls` so the 🎛
    // picker, which mutates `controls` (not `binds`), actually re-renders the strip.
    const bindKey = JSON.stringify((c.binds || []).map(b => [b.name, b.widget, b.params, b.hosted, b.hostedby]));
    const ctrlKey = JSON.stringify((c.controls || []).map(col => col.map(s => [s.name, s.widget, s.params])));
    let rebuilt = false;
    if (bindKey !== last.current.bindKey) {
      last.current.bindKey = bindKey;
      const host = el.querySelector('.binds');
      // Let any custom widgets clean up before the swap orphans their nodes (mirrors the .ichart dispose above).
      if (host) { window.teardownCustomWidgets(host); host.innerHTML = window.bindsInner(c); rebuilt = true; }
    }
    if (ctrlKey !== last.current.ctrlKey) {
      last.current.ctrlKey = ctrlKey;
      const host = el.querySelector('.controls');
      if (host) { window.teardownCustomWidgets(host); host.innerHTML = window.controlStripInner(c); rebuilt = true; }
    }
    if (rebuilt) window.mountControls(c);             // wire the freshly-built controls
    // A cell you're actively editing is YOURS until you resolve. When its editor holds unsaved edits
    // that diverge from the incoming server source (a live conflict — the modal above is offering the
    // choice), DON'T let the external run's output/charts replace what you're looking at. Freeze the
    // presentation; the reconcile flow re-applies the incoming result if you pick "use the change".
    const _conflicted = window.editors[c.id] && !_eq(window.edText(c.id), c.source);
    const out = el.querySelector('.output');
    if (!_conflicted && out && c.output !== last.current.out) { last.current.out = c.output; window._swapOutput(out, c.output); window.typesetVisible(out, c.id); window._clampOutputs && window._clampOutputs(out); }
    window._applyErrorLine && window._applyErrorLine(c);   // tint the offending line
    window._applyMissingPkg && window._applyMissingPkg(c);   // "Package X not found" → one-click install banner
    // Only re-apply setOption / refill rows when the chart/table DATA actually changed — reference
    // compare, since a selection click or live-state tick re-renders with the SAME nbState (same cell
    // objects). Without this, every such re-render re-ran setOption on EVERY chart in the notebook
    // (a real CPU sink during slider drags). Data changes produce a fresh cell object → fresh array.
    if (!_conflicted && c.echarts !== last.current.echarts) { last.current.echarts = c.echarts; window.renderCharts(c); }
    if (!_conflicted && c.tables !== last.current.tables) { last.current.tables = c.tables; window.renderTables(c); }
    if (!_conflicted && c.animations !== last.current.animations) { last.current.animations = c.animations; window.renderAnimation && window.renderAnimation(c); }
    if ((c.binds && c.binds.length) || (c.controls && c.controls.length)) window.syncControlValues({ cells: [c] });

    // Only a plain code cell has the always-on <Editor> to refresh once it becomes visible.
    const visible = !window.hasBinds(c) && !c.collapsed && !c.codeHidden;
    if (visible && !last.current.vis) {
      const ed = window.editors[c.id]; ed && ed.requestMeasure && ed.requestMeasure();
      (window.charts[c.id] || []).forEach(i => { try { i.resize(); } catch (_) {} });   // chart sized 0 while hidden → fix on reveal
    }
    last.current.vis = visible;
  });

  // Selection: the ACTIVE cell gets `.selected` (strong); other members of a multi-selection
  // get `.multisel` (lighter), so "the cell ops act on" reads distinctly from "also selected".
  const inSet = selSet ? selSet.has(c.id) : false;
  const selCls = selectedId === c.id ? ' selected' : (inSet ? ' multisel' : '');
  const isBind = window.hasBinds(c);
  // Document-metadata roles (title / abstract / bibliography) style the cell in place, so what
  // you author flows naturally in the notebook and exports interpret the role for placement.
  const roleCls = (c.roleTitle ? ' role-title' : '') + (c.roleAbstract ? ' role-abstract' : '')
    + (c.roleBib ? ' role-bib' : '') + (c.roleCaption ? ' role-caption' : '');
  const cls = 'cell ' + (c.kind === 'md' ? 'md' : c.kind === 'web' ? 'web' : (isBind ? 'bind' : 'code')) + ' state-' + state
    + (c.collapsed ? ' collapsed' : '') + (c.codeHidden ? ' codehidden' : '')
    + roleCls + selCls + (focusId === c.id ? ' dep-focus' : '');
  const header = html`<div class="cellhead" dangerouslySetInnerHTML=${raw(window.cellHeaderInner(c))}></div>`;
  const srcedit = html`<div class="srcedit" style="display:none" dangerouslySetInnerHTML=${raw(window.srcEditInner())}></div>`;
  // Content hosts are empty/stable — Preact preserves them; the effect above fills them.
  let body;
  if (c.kind === 'md') {
    body = html`<div class="md" title="double-click to edit" ondblclick=${() => window.editSource(c.id, 'markdown')}></div>${srcedit}`;
  } else if (c.kind === 'web') {
    // Web cell: the 3-pane HTML/CSS/JS editor, then the same output/controls hosts a code cell uses
    // (the rendered WebPage swaps into `.output`).
    body = html`<${WebEditor} cell=${c} /><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div><div class="output"></div><div class="tables"></div><div class="echarts"></div><div class="anim"></div>`;
  } else if (isBind) {
    // A bind/MIXED cell: its own @bind rows, the surfaced-control strip (so controls surfaced
    // here — including its own @bind — actually render), then the toggle source editor + output.
    body = html`<div class="binds"></div><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div>${srcedit}<div class="output"></div><div class="tables"></div><div class="echarts"></div><div class="anim"></div>`;
  } else {
    body = html`<${Editor} cell=${c} /><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div><div class="output"></div><div class="tables"></div><div class="echarts"></div><div class="anim"></div>`;
  }
  return html`<div ref=${ref} id=${'cell-' + c.id} data-cid=${c.id} class=${cls}>${header}${body}</div>`;
}

// Inter-cell insert affordance: a thin hover zone in the gap between rows (and above the first / below
// the last) that reveals a "+" to insert a cell RIGHT THERE. `afterId` = insert after that cell; the
// top gap has no `afterId`, so it inserts BEFORE `firstId`. Left-click = code cell; right-click =
// the code/markdown chooser (reuses addMenu, which inserts below `afterId`). Like the other add-cell
// affordances, a fresh cell is NOT put into edit mode — so it can be flipped to markdown first.
function CellGap({ afterId, firstId }) {
  const insert = (kind) => afterId
    ? window.addCell(afterId, kind, false)           // after afterId (last cell of the row above)
    : window.addCell(firstId, kind, true);           // top gap → before the first cell (firstId='' ⇒ append)
  // Right-click → chooser. Below a cell: insert after `afterId`. Top gap: insert before `firstId`.
  const onMenu = (e) => {
    e.preventDefault();
    if (!window.addMenu) return insert('code');
    afterId ? window.addMenu(e, afterId, false) : window.addMenu(e, firstId, true);
  };
  return html`<div class="cellgap">
    <button class="cellgap-add" onClick=${() => insert('code')} oncontextmenu=${onMenu}
      title="insert a cell here — right-click for markdown">＋</button>
  </div>`;
}

function Notebook({ cells, selectedId, selSet, live, focusId, cone }) {
  useEffect(() => {
    window.renderPalette && window.renderPalette();
    window.syncAgentTop && window.syncAgentTop();
    window._tocOpen && window.renderTOC && window.renderTOC();   // keep the open TOC in sync with edits
  });
  const coneCount = cone ? cone.size : (cells || []).length;
  const banner = focusId ? html`<div class="focusbar" onClick=${() => window.slateStore.setFocus(focusId)}
      title="click or press Esc to exit focus">🔗 Dependency chain of <b>${focusId}</b> · ${coneCount} cell${coneCount === 1 ? '' : 's'} — click to exit</div>` : null;
  // Render EVERY cell always; cells outside the cone collapse (see <Cell>) instead of unmounting.
  const renderCell = c => html`<${Cell} key=${c.id} cell=${c} selectedId=${selectedId} selSet=${selSet} live=${live} focusId=${focusId} collapsed=${!!(cone && !cone.has(c.id))} />`;
  // Side-by-side columns: a `column=N` tag (N≥2) places a cell in the Nth slot of the row anchored by
  // the preceding un-tagged (column 1, the default) cell — so you only tag the EXTRA columns. A plain
  // cell always starts a fresh row; a lone row renders as a normal full-width cell (no wrapper).
  const rows = [];
  (cells || []).forEach(c => {
    const col = _cellColumn(c);
    if (col >= 2 && rows.length) rows[rows.length - 1].push(c);
    else rows.push([c]);
  });
  const renderRow = row => row.length === 1
    ? renderCell(row[0])
    : html`<div class="cell-row" key=${'row-' + row[0].id}>${row.map(renderCell)}</div>`;
  // Interleave a CellGap before the first row and after each one — EXCEPT in dep-focus (a read-oriented
  // view where gaps between collapsed cells would just be noise). A row's trailing gap is anchored to
  // its LAST cell, so an insert lands after the whole row as a new full-width cell.
  const firstId = (cells && cells.length) ? cells[0].id : '';
  const out = [];
  if (!focusId) out.push(html`<${CellGap} key="gap-top" afterId=${''} firstId=${firstId} />`);
  rows.forEach(row => {
    out.push(renderRow(row));
    if (!focusId) out.push(html`<${CellGap} key=${'gap-' + row[row.length - 1].id} afterId=${row[row.length - 1].id} firstId=${firstId} />`);
  });
  return html`${banner}${out}`;
}
// The row column a cell sits in: `column=N` tag → N, default 1. Only N≥2 pulls a cell up beside its predecessor.
function _cellColumn(c) {
  const tags = (c && c.tags) || [];
  for (const t of tags) { const m = /^column=(\d+)$/.exec(t); if (m) return Math.max(1, parseInt(m[1], 10) || 1); }
  return 1;
}

// The floating "N cells selected" pill (top-left), shown only when a multi-selection is active.
function _updateSelCount(selSet) {
  const el = document.getElementById('selcount'); if (!el) return;
  const n = selSet ? selSet.size : 0;
  if (n > 1) { el.textContent = n + ' cells selected'; el.classList.add('show'); }
  else el.classList.remove('show');
}

const nbHost = document.getElementById('nb');
if (nbHost) {
  // Re-render on cell list / selection / live-state / dep-focus change. Every cell stays
  // mounted; when focused, cells outside the dependency cone animate collapsed (the rest of the
  // smoothing lives in <Cell>/_animateCollapse), so editors and live figures survive the toggle.
  let _prevFocus;
  effect(() => {
    const fid = focusSignal.value;
    const cone = _coneIds(cellsSignal.value, fid);
    // On a focus TOGGLE the cells above the anchor collapse/expand, which would shift the page
    // (you'd land at the top on exit). Pin the anchor cell — the one focused, or the one we're
    // leaving — to its current viewport offset for the duration of the collapse animation, so it
    // stays put while everything reflows around it.
    const focusChanged = fid !== _prevFocus;
    const anchorId = focusChanged ? (fid || _prevFocus) : null;
    const anchorEl = anchorId && document.getElementById('cell-' + anchorId);
    const beforeTop = anchorEl ? anchorEl.getBoundingClientRect().top : null;
    _prevFocus = fid;

    const selSet = selectedSetSignal.value;
    _updateSelCount(selSet);
    render(html`<${Notebook} cells=${cellsSignal.value} cone=${cone} selectedId=${selectedSignal.value} selSet=${selSet} live=${liveSignal.value} focusId=${fid} />`, nbHost);

    if (beforeTop != null) {
      const t0 = performance.now();
      const pin = () => {
        const el = document.getElementById('cell-' + anchorId);
        if (el) { const d = el.getBoundingClientRect().top - beforeTop; if (Math.abs(d) > 0.5) window.scrollBy(0, d); }
        if (performance.now() - t0 < 340) requestAnimationFrame(pin);   // through the .26s collapse
      };
      requestAnimationFrame(pin);
    }
  });
}
