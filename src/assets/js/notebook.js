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

// <Editor>: a CodeMirror created ONCE into a host div and preserved. The component renders a
// stable empty host and never re-renders it (empty-dep effect), so cursor/undo/scroll/the
// signature-placeholder state survive notebook updates. Keyed by cell id at the call site.
function Editor({ cell }) {
  const ref = useRef(null);
  useEffect(() => {
    ref.current.querySelector('.cm-editor')?.remove();        // guard against a stacked editor in a reused host
    let primed = false;
    const view = window.mkEditor(ref.current, {
      doc: cell.source, cellId: cell.id,
      onDoc: () => { if (primed && window.edText(cell.id) !== cell.source) { window.setState(cell.id, 'edited'); window._backupSoon && window._backupSoon(); } },
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
    return () => {
      if (window.editors[cell.id] === view) delete window.editors[cell.id];
      try { view.destroy(); } catch (_) {}
    };
  }, []);
  return html`<div ref=${ref}></div>`;
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
    window.srcMap[c.id] = c.source;
    if (window.editors[c.id] && c.source !== _prevSrc) {
      const _mine = window.edText(c.id);
      if (_mine === _prevSrc) window.edSetText(c.id, c.source);                         // no local edits → fast-forward to the new source
      else if (_mine !== c.source && window.slateLiveConflict) window.slateLiveConflict(c.id, _mine, c.source);   // both changed → reconcile modal
    }
    const badge = el.querySelector('.badge');     // header renders c.state; reflect the live state
    if (badge && badge.textContent !== state) badge.textContent = state;

    if (c.kind === 'md') {
      const md = el.querySelector('.md'); const h = window.mdHtml(c);
      if (md && h !== last.current.out) {
        // Dispose any inline `{{ echart }}` instances before the innerHTML swap orphans their nodes
        // (their ECharts instance + zrender would otherwise leak on every markdown re-render).
        md.querySelectorAll('.ichart').forEach(e => { if (e._inst) { try { e._inst.dispose(); } catch (_) {} e._inst = null; } });
        last.current.out = h; window._swapOutput(md, h); window.typeset(md);
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
      if (host) { host.innerHTML = window.bindsInner(c); rebuilt = true; }
    }
    if (ctrlKey !== last.current.ctrlKey) {
      last.current.ctrlKey = ctrlKey;
      const host = el.querySelector('.controls');
      if (host) { host.innerHTML = window.controlStripInner(c); rebuilt = true; }
    }
    if (rebuilt) window.mountControls(c);             // wire the freshly-built controls
    const out = el.querySelector('.output');
    if (out && c.output !== last.current.out) { last.current.out = c.output; window._swapOutput(out, c.output); window.typeset(out); }
    window._applyErrorLine && window._applyErrorLine(c);   // tint the offending line
    // Only re-apply setOption / refill rows when the chart/table DATA actually changed — reference
    // compare, since a selection click or live-state tick re-renders with the SAME nbState (same cell
    // objects). Without this, every such re-render re-ran setOption on EVERY chart in the notebook
    // (a real CPU sink during slider drags). Data changes produce a fresh cell object → fresh array.
    if (c.echarts !== last.current.echarts) { last.current.echarts = c.echarts; window.renderCharts(c); }
    if (c.tables !== last.current.tables) { last.current.tables = c.tables; window.renderTables(c); }
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
  const cls = 'cell ' + (c.kind === 'md' ? 'md' : (isBind ? 'bind' : 'code')) + ' state-' + state
    + (c.collapsed ? ' collapsed' : '') + (c.codeHidden ? ' codehidden' : '')
    + selCls + (focusId === c.id ? ' dep-focus' : '');
  const header = html`<div class="cellhead" dangerouslySetInnerHTML=${raw(window.cellHeaderInner(c))}></div>`;
  const srcedit = html`<div class="srcedit" style="display:none" dangerouslySetInnerHTML=${raw(window.srcEditInner())}></div>`;
  // Content hosts are empty/stable — Preact preserves them; the effect above fills them.
  let body;
  if (c.kind === 'md') {
    body = html`<div class="md" title="double-click to edit" ondblclick=${() => window.editSource(c.id, 'markdown')}></div>${srcedit}`;
  } else if (isBind) {
    // A bind/MIXED cell: its own @bind rows, the surfaced-control strip (so controls surfaced
    // here — including its own @bind — actually render), then the toggle source editor + output.
    body = html`<div class="binds"></div><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div>${srcedit}<div class="output"></div><div class="tables"></div><div class="echarts"></div>`;
  } else {
    body = html`<${Editor} cell=${c} /><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div><div class="output"></div><div class="tables"></div><div class="echarts"></div>`;
  }
  return html`<div ref=${ref} id=${'cell-' + c.id} data-cid=${c.id} class=${cls}>${header}${body}</div>`;
}

function Notebook({ cells, selectedId, selSet, live, focusId, cone }) {
  useEffect(() => {
    window.renderPalette && window.renderPalette();
    window.syncAgentTop && window.syncAgentTop();
  });
  const coneCount = cone ? cone.size : (cells || []).length;
  const banner = focusId ? html`<div class="focusbar" onClick=${() => window.slateStore.setFocus(focusId)}
      title="click or press Esc to exit focus">🔗 Dependency chain of <b>${focusId}</b> · ${coneCount} cell${coneCount === 1 ? '' : 's'} — click to exit</div>` : null;
  // Render EVERY cell always; cells outside the cone collapse (see <Cell>) instead of unmounting.
  return html`${banner}${(cells || []).map(c => html`<${Cell} key=${c.id} cell=${c} selectedId=${selectedId} selSet=${selSet} live=${live} focusId=${focusId} collapsed=${!!(cone && !cone.has(c.id))} />`)}`;
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
  console.log('[preact] phase 2+3 — <Notebook> owns #nb (editors preserved across updates)');
}
