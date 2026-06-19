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
import { cells as cellsSignal, selected as selectedSignal, liveStates as liveSignal, focus as focusSignal } from './store.js';

const raw = s => ({ __html: s || '' });

// Dep-focus: the cells in `id`'s dependency CHAIN — itself, its transitive precursors (deps),
// and its transitive dependents — so focusing on a cell shows just that flow. `null` → all.
function _focusCone(cells, id) {
  if (!id) return cells;
  const byId = {}; cells.forEach(c => (byId[c.id] = c));
  if (!byId[id]) return cells;
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
  return cells.filter(c => cone.has(c.id));
}

// <Editor>: a CodeMirror created ONCE into a host div and preserved. The component renders a
// stable empty host and never re-renders it (empty-dep effect), so cursor/undo/scroll/the
// signature-placeholder state survive notebook updates. Keyed by cell id at the call site.
function Editor({ cell }) {
  const ref = useRef(null);
  useEffect(() => {
    const ed = window.CodeMirror(ref.current, {
      value: cell.source, mode: 'julia', theme: 'material-darker', lineNumbers: false, viewportMargin: Infinity,
    });
    window.wireCodeEditor(ed, cell);
    window.editors[cell.id] = ed;
    return () => { if (window.editors[cell.id] === ed) delete window.editors[cell.id]; };
  }, []);
  return html`<div ref=${ref}></div>`;
}

function Cell({ cell, selectedId, live, focusId }) {
  const c = cell;
  const ref = useRef(null);
  const last = useRef({ bindKey: undefined, ctrlKey: undefined, out: undefined, vis: undefined });
  const state = (live && live[c.id]) || c.state;   // transient (running/edited) wins until server state arrives

  // Dispose this cell's ECharts when it unmounts; charts otherwise update in place.
  useEffect(() => () => {
    const cs = window.charts[c.id];
    if (cs) { cs.forEach(i => { try { i.dispose(); } catch (_) {} }); delete window.charts[c.id]; }
  }, []);

  // Fill/update the cell's content IMPERATIVELY via the vanilla helpers, so live widgets aren't
  // recreated on a value echo (a drag survives), outputs swap in place (no flash in cells below),
  // and a CodeMirror created inside a collapsed cell is refreshed once it becomes visible (it
  // renders blank otherwise). The hosts in the returned vnode are stable, so Preact keeps them.
  useEffect(() => {
    const el = ref.current; if (!el) return;
    window.srcMap[c.id] = c.source;
    const badge = el.querySelector('.badge');     // header renders c.state; reflect the live state
    if (badge && badge.textContent !== state) badge.textContent = state;

    if (c.kind === 'md') {
      const md = el.querySelector('.md'); const h = window.mdHtml(c);
      if (md && h !== last.current.out) { last.current.out = h; window._swapOutput(md, h); window.typeset(md); }
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
    window.renderCharts(c);                           // in-place setOption — animates, keeps canvas
    window.renderTables(c);                           // refill rows in place — keeps sort/filter/page
    window.syncControlValues({ cells: [c] });         // values in place; skips focused/just-touched → drag-safe

    // Only a plain code cell has the always-on <Editor> to refresh once it becomes visible.
    const visible = !window.hasBinds(c) && !c.collapsed && !c.codeHidden;
    if (visible && !last.current.vis) { const ed = window.editors[c.id]; ed && ed.refresh(); }
    last.current.vis = visible;
  });

  const isBind = window.hasBinds(c);
  const cls = 'cell ' + (c.kind === 'md' ? 'md' : (isBind ? 'bind' : 'code')) + ' state-' + state
    + (c.collapsed ? ' collapsed' : '') + (c.codeHidden ? ' codehidden' : '')
    + (selectedId === c.id ? ' selected' : '') + (focusId === c.id ? ' dep-focus' : '');
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

function Notebook({ cells, selectedId, live, focusId }) {
  useEffect(() => {
    window.renderPalette && window.renderPalette();
    window.syncAgentTop && window.syncAgentTop();
  });
  const banner = focusId ? html`<div class="focusbar" onClick=${() => window.slateStore.setFocus(focusId)}
      title="click or press Esc to exit focus">🔗 Dependency chain of <b>${focusId}</b> · ${cells.length} cell${cells.length === 1 ? '' : 's'} — click to exit</div>` : null;
  return html`${banner}${(cells || []).map(c => html`<${Cell} key=${c.id} cell=${c} selectedId=${selectedId} live=${live} focusId=${focusId} />`)}`;
}

const nbHost = document.getElementById('nb');
if (nbHost) {
  // Re-render on cell list / selection / live-state / dep-focus change. When focused, only the
  // focus cell's dependency chain is rendered (the rest dissolve away).
  effect(() => {
    const fid = focusSignal.value;
    render(html`<${Notebook} cells=${_focusCone(cellsSignal.value, fid)} selectedId=${selectedSignal.value} live=${liveSignal.value} focusId=${fid} />`, nbHost);
  });
  console.log('[preact] phase 2+3 — <Notebook> owns #nb (editors preserved across updates)');
}
