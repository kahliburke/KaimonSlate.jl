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

// The global region registry (all hosts) + parked wires: the hub's facts (model.js), mirrored into
// signals so every island re-renders when they change. `loadRegions()` brings the facts up to date at
// once, for a caller that just changed a region and reads the result next.
export const regions = signal([]);
export const parked  = signal([]);
const fromModel = () => { regions.value = window.slateModel.regions(); parked.value = window.slateModel.parked(); };
window.slateModel.subscribe(fromModel);
fromModel();
export const loadRegions = () => window.slateModel.refresh();

// What scheduler(s) a host has, keyed by host: `undefined` = never asked, `null` = asking,
// `{kinds, suggested, partitions}` = answered. Shared because a region on a cluster and a batch
// target on the same cluster ask the identical question, and it is a round trip — the region form
// and the compute-target form should not each pay for it.
export const schedInfo = signal({});
export function loadScheduler(h) {
  if (!h || schedInfo.value[h] !== undefined) return;
  schedInfo.value = { ...schedInfo.value, [h]: null };
  fetch('/api/scheduler?host=' + encodeURIComponent(h)).then(r => r.json())
    .then(d => { schedInfo.value = { ...schedInfo.value, [h]: d || { kinds: [] } }; })
    .catch(() => { schedInfo.value = { ...schedInfo.value, [h]: { kinds: [] } }; });
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
