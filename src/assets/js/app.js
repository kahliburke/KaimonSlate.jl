// Preact migration entrypoint (no build — ESM + htm + signals).
//
// Phase 0: prove the pipeline. This renders a tiny interactive probe into the topbar so a
// reload confirms three things work in the *served* environment: the import map resolves a
// single pinned Preact, htm templates render, and @preact/signals drives reactivity. Once
// verified, this file grows into the real app (state store → editor island → notebook →
// chrome) and the classic scripts are retired island by island. See notebook.html.
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';

const clicks = signal(0);
const label = computed(() => (clicks.value ? `⚛ Preact · ${clicks.value}` : '⚛ Preact ready'));

function Probe() {
  return html`
    <span
      onClick=${() => clicks.value++}
      title="Preact pipeline live (htm + signals). Click me — the count is signal-driven."
      style="cursor:pointer;font-size:.72rem;color:var(--accent);border:1px solid var(--accent);
             border-radius:999px;padding:1px 8px;user-select:none;white-space:nowrap;">
      ${label.value}
    </span>`;
}

const tb = document.querySelector('.topbar');
if (tb) {
  const host = document.createElement('span');
  host.style.marginLeft = '6px';
  tb.appendChild(host);
  render(html`<${Probe} />`, host);
  console.log('[preact] pipeline up — htm + signals rendering into the topbar');
}
