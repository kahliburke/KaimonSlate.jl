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
import { cells as cellsSignal, selected as selectedSignal } from './store.js';

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

function Cell({ cell, selectedId }) {
  const c = cell;
  const last = useRef({ out: undefined, wire: undefined });
  // Dispose this cell's ECharts when it unmounts; charts otherwise update in place.
  useEffect(() => () => {
    const cs = window.charts[c.id];
    if (cs) { cs.forEach(i => { try { i.dispose(); } catch (_) {} }); delete window.charts[c.id]; }
  }, []);
  // Output/controls processing after each render — but the imperative bits (scripts, control
  // wiring) only re-run when their content actually changed, so we never double-execute a
  // <script> or double-bind a control listener (Preact left unchanged innerHTML in place).
  useEffect(() => {
    const el = document.getElementById('cell-' + c.id);
    if (!el) return;
    window.srcMap[c.id] = c.source;
    if (c.output !== last.current.out) { last.current.out = c.output; window.runScripts(el); window.typeset(el); }
    const wireKey = (window.hasBinds(c) ? window.bindsInner(c) : '') + ' '
                  + ((c.kind === 'code' && !window.hasBinds(c)) ? window.controlStrip(c) : '');
    if (wireKey !== last.current.wire) { last.current.wire = wireKey; window.mountControls(c); }
    window.renderCharts(c);   // in-place setOption — animates data changes, keeps the canvas
    window.renderTables(c);   // refill rows in place — keeps sort/filter/page
  });

  const cls = 'cell ' + (c.kind === 'md' ? 'md' : (window.hasBinds(c) ? 'bind' : 'code')) + ' state-' + c.state
    + (c.collapsed ? ' collapsed' : '') + (c.codeHidden ? ' codehidden' : '')
    + (selectedId === c.id ? ' selected' : '');
  const header = html`<div class="cellhead" dangerouslySetInnerHTML=${raw(window.cellHeaderInner(c))}></div>`;
  const srcedit = html`<div class="srcedit" style="display:none" dangerouslySetInnerHTML=${raw(window.srcEditInner())}></div>`;
  let body;
  if (c.kind === 'md') {
    body = html`
      <div class="md" title="double-click to edit" ondblclick=${() => window.editSource(c.id, 'markdown')}
           dangerouslySetInnerHTML=${raw(window.mdHtml(c))}></div>
      ${srcedit}`;
  } else if (window.hasBinds(c)) {
    body = html`
      <div class="binds" dangerouslySetInnerHTML=${raw(window.bindsInner(c))}></div>
      ${srcedit}
      <div class="output" dangerouslySetInnerHTML=${raw(c.output)}></div>
      <div class="tables"></div>
      <div class="echarts"></div>`;
  } else {
    body = html`
      <${Editor} cell=${c} />
      <div dangerouslySetInnerHTML=${raw(window.controlStrip(c))}></div>
      <div class="output" dangerouslySetInnerHTML=${raw(c.output)}></div>
      <div class="tables"></div>
      <div class="echarts"></div>`;
  }
  return html`<div id=${'cell-' + c.id} data-cid=${c.id} class=${cls}>${header}${body}</div>`;
}

function Notebook({ cells, selectedId }) {
  useEffect(() => {
    window.renderPalette && window.renderPalette();
    window.syncAgentTop && window.syncAgentTop();
  });
  return html`${(cells || []).map(c => html`<${Cell} key=${c.id} cell=${c} selectedId=${selectedId} />`)}`;
}

const nbHost = document.getElementById('nb');
if (nbHost) {
  // Re-render whenever the cell list or selection changes (the effect subscribes to both).
  effect(() => render(html`<${Notebook} cells=${cellsSignal.value} selectedId=${selectedSignal.value} />`, nbHost));
  console.log('[preact] phase 2+3 — <Notebook> owns #nb (editors preserved across updates)');
}
