// Signals state store — Phase 1 of the Preact migration.
//
// The single reactive source the new components read. During the migration it is FED BY the
// existing vanilla state flow: the classic scripts' renderAll()/updateStates() push each
// fresh /api/state payload in via window.slateStore.applyState(), and selectCell() pushes the
// selection — so signals and the legacy DOM stay in lockstep until each island is ported.
// Backend and the JSON shape are untouched. Once the notebook view is a Preact component,
// these signals become the *only* source and the bridge calls are removed.
import { signal, computed } from '@preact/signals';

export const nbState  = signal(window.nbState || null);      // the whole /api/state payload
export const selected = signal(window.selectedId || null);   // selected cell id (command mode)

export const cells = computed(() => (nbState.value && nbState.value.cells) || []);
export const title = computed(() => (nbState.value && nbState.value.title) || 'Notebook');
export const worker = computed(() => (nbState.value && nbState.value.worker) || {});

export function applyState(state) { if (state) nbState.value = state; }
export function setSelected(id) { selected.value = id; }

// Bridge for the classic (non-module) scripts, which can't `import`. They call these;
// Preact components import the signals directly above.
window.slateStore = { nbState, selected, cells, title, worker, applyState, setSelected };
