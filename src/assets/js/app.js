// Preact migration entrypoint (no build — ESM + htm + signals).
//
// Phase 1: the signals state store (store.js) is now the reactive source. The probe below
// reads it, so it updates live as the notebook changes (add/delete/rename a cell) — proof
// the store is fed by the existing state flow. Next: the editor island, then <Notebook>.
import { html, render } from 'htm/preact';
import { title, cells, worker } from './store.js';

// A live readout of notebook state, straight from the signals store. Re-renders on its own
// whenever the store changes — no manual wiring.
function Probe() {
  const w = worker.value;
  const dot = w.kind === 'inproc' ? '◷' : (w.connected ? '●' : '○');
  return html`
    <span
      title=${`Preact signals store · ${title.value}`}
      style="font-size:.72rem;color:var(--accent);border:1px solid var(--accent);
             border-radius:999px;padding:1px 8px;user-select:none;white-space:nowrap;">
      ⚛ ${cells.value.length} cells ${dot}
    </span>`;
}

const tb = document.querySelector('.topbar');
if (tb) {
  const host = document.createElement('span');
  host.style.marginLeft = '6px';
  tb.appendChild(host);
  render(html`<${Probe} />`, host);
  console.log('[preact] phase 1 — signals store live (probe reads notebook state)');
}
