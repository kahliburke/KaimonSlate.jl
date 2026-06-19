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
import { cells as cellsSignal, selected as selectedSignal, liveStates as liveSignal } from './store.js';

const raw = s => ({ __html: s || '' });

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

function Cell({ cell, selectedId, live }) {
  const c = cell;
  const ref = useRef(null);
  const last = useRef({ struct: undefined, out: undefined, vis: undefined });
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

    // Binds (bind cell) / control strip (code cell): (re)build the widgets ONLY when their
    // STRUCTURE changes — never on a value echo — then sync values in place. Keyed on
    // names/widgets/params (value excluded) so dragging a slider doesn't rebuild it.
    const isBind = window.hasBinds(c);
    const structKey = isBind
      ? JSON.stringify((c.binds || []).map(b => [b.name, b.widget, b.params]))
      : JSON.stringify((c.controls || []).map(col => col.map(s => [s.name, s.widget, s.params])));
    if (structKey !== last.current.struct) {
      last.current.struct = structKey;
      const host = el.querySelector(isBind ? '.binds' : '.controls');
      if (host) host.innerHTML = isBind ? window.bindsInner(c) : window.controlStripInner(c);
      window.mountControls(c);                       // wire the freshly-built controls
    }
    const out = el.querySelector('.output');
    if (out && c.output !== last.current.out) { last.current.out = c.output; window._swapOutput(out, c.output); window.typeset(out); }
    window.renderCharts(c);                           // in-place setOption — animates, keeps canvas
    window.renderTables(c);                           // refill rows in place — keeps sort/filter/page
    window.syncControlValues({ cells: [c] });         // values in place; skips focused/just-touched → drag-safe

    const visible = !isBind && !c.collapsed && !c.codeHidden;
    if (visible && !last.current.vis) { const ed = window.editors[c.id]; ed && ed.refresh(); }
    last.current.vis = visible;
  });

  const isBind = window.hasBinds(c);
  const cls = 'cell ' + (c.kind === 'md' ? 'md' : (isBind ? 'bind' : 'code')) + ' state-' + state
    + (c.collapsed ? ' collapsed' : '') + (c.codeHidden ? ' codehidden' : '')
    + (selectedId === c.id ? ' selected' : '');
  const header = html`<div class="cellhead" dangerouslySetInnerHTML=${raw(window.cellHeaderInner(c))}></div>`;
  const srcedit = html`<div class="srcedit" style="display:none" dangerouslySetInnerHTML=${raw(window.srcEditInner())}></div>`;
  // Content hosts are empty/stable — Preact preserves them; the effect above fills them.
  let body;
  if (c.kind === 'md') {
    body = html`<div class="md" title="double-click to edit" ondblclick=${() => window.editSource(c.id, 'markdown')}></div>${srcedit}`;
  } else if (isBind) {
    body = html`<div class="binds"></div>${srcedit}<div class="output"></div><div class="tables"></div><div class="echarts"></div>`;
  } else {
    body = html`<${Editor} cell=${c} /><div class="controls${(c.controls || []).length ? '' : ' empty'}" data-cell=${c.id}></div><div class="output"></div><div class="tables"></div><div class="echarts"></div>`;
  }
  return html`<div ref=${ref} id=${'cell-' + c.id} data-cid=${c.id} class=${cls}>${header}${body}</div>`;
}

function Notebook({ cells, selectedId, live }) {
  useEffect(() => {
    window.renderPalette && window.renderPalette();
    window.syncAgentTop && window.syncAgentTop();
  });
  return html`${(cells || []).map(c => html`<${Cell} key=${c.id} cell=${c} selectedId=${selectedId} live=${live} />`)}`;
}

const nbHost = document.getElementById('nb');
if (nbHost) {
  // Re-render whenever the cell list, selection, or transient live-state changes.
  effect(() => render(html`<${Notebook} cells=${cellsSignal.value} selectedId=${selectedSignal.value} live=${liveSignal.value} />`, nbHost));
  console.log('[preact] phase 2+3 — <Notebook> owns #nb (editors preserved across updates)');
}
