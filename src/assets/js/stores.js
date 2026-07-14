// Shared signal store for the home-page (index.html) Preact islands. Signals live here — not inside any
// one island — so multiple islands (and, during the strangler-fig migration, the still-vanilla Remotes
// modal via thin window.* setters) read/write the SAME state without prop-drilling or window bridges.
//
// First shared signal: `detail` — the worker-detail popup's open target {host, port} | null. The
// activity monitor sets it (clicking a worker row); the WorkerDetail popup renders from it. As the
// Remotes modal's worker roster migrates to Preact, it will set this same signal directly, retiring the
// window.slateOpenWorkerDetail bridge.
import { signal } from '@preact/signals';

export const detail = signal(null);       // worker-detail popup target {host, port} | null
// Remotes-modal region focus view (remotes-focus.js) + the modal shell (remotes.js) — both are Preact
// islands driven off these shared signals, so no window.__slate* bridges are needed between them.
export const modalOpen  = signal(false);  // is the Remotes modal (#remotesbg) open?
export const focusHost  = signal('');     // the host whose regions/workers the focus view shows ('' = none)
export const editRegion = signal(null);   // region object being edited (null = the "new region" form)
export const pendingRegion = signal('');  // a region name to auto-select once focusHost's regions load ('' = none)

// The global region registry (all hosts) + parked wires, shared so BOTH the modal's known-hosts list
// (per-host region counts) and the focus view's region list read one source — a save/delete anywhere
// calls loadRegions() and every island re-renders. This is what retires the old slateSyncHosts bridge.
export const regions = signal([]);
export const parked  = signal([]);
export function loadRegions() {
  return fetch('/api/regions').then(r => r.json())
    .then(d => { regions.value = (d && d.regions) || []; parked.value = (d && d.parked) || []; }).catch(() => {});
}

// Open the Remotes modal focused on a host with a specific region selected in its editor. Called by the
// activity monitor (a region group / worker-detail row) and the known-hosts list. The focus island's
// effects resolve pendingRegion → editRegion once that host's regions have loaded.
export function openRegionConfig(host, name) {
  focusHost.value = host || '';
  editRegion.value = null;
  pendingRegion.value = name || '';
  modalOpen.value = true;
}
