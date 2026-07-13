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
// Remotes-modal region focus view (migrated to Preact in remotes-focus.js). The still-vanilla modal shell
// (openRemotes / the known-hosts list / closeRemotes) drives these via thin window.__slate* setters during
// the strangler-fig transition; they retire once the shell itself migrates.
export const focusHost  = signal('');     // the host whose regions/workers the focus view shows ('' = none)
export const editRegion = signal(null);   // region object being edited (null = the "new region" form)
