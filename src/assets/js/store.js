// Signals state store — Phase 1 of the Preact migration.
//
// The single reactive source the new components read. During the migration it is FED BY the
// existing vanilla state flow: the classic scripts' renderAll()/updateStates() push each
// fresh /api/state payload in via window.slateStore.applyState(), and selectCell() pushes the
// selection — so signals and the legacy DOM stay in lockstep until each island is ported.
// Backend and the JSON shape are untouched. Once the notebook view is a Preact component,
// these signals become the *only* source and the bridge calls are removed.
import { signal, computed } from '@preact/signals';

// Seed from the last state the classic boot published (window.__slateState). The boot's
// reload() is async and may run before this module loads, so it stashes state there for us.
export const nbState  = signal(window.__slateState || null); // the whole /api/state payload
export const selected = signal(window.selectedId || null);   // ACTIVE/anchor cell id (command mode; the one single-cell ops act on)
export const selectedSet = signal(new Set(window.selectedId ? [window.selectedId] : [])); // ALL selected ids (multi-select)
export const focus    = signal(null);                        // dep-focus: show ONLY this cell's dependency chain
export const liveStates = signal({});                        // transient per-cell state (running/edited) for instant feedback,
                                                             // until the authoritative server state arrives

export const cells = computed(() => (nbState.value && nbState.value.cells) || []);
export const title = computed(() => (nbState.value && nbState.value.title) || 'Notebook');
export const worker = computed(() => (nbState.value && nbState.value.worker) || {});

// New server state is authoritative — drop the transient live-state overrides.
export function applyState(state) { if (state) { nbState.value = state; if (Object.keys(liveStates.value).length) liveStates.value = {}; } }
// Single-select: the active cell IS the whole selection.
export function setSelected(id) { selected.value = id; selectedSet.value = new Set(id ? [id] : []); }
// Multi-select: set the whole selection at once; `active` is the primary/anchor cell.
export function setSelection(ids, active) { selectedSet.value = new Set(ids); selected.value = active != null ? active : (ids.length ? ids[ids.length - 1] : null); }
// Toggle one cell in/out of the selection (⌘/ctrl-click); the toggled cell becomes active.
export function toggleInSelection(id) { const s = new Set(selectedSet.value); s.has(id) ? s.delete(id) : s.add(id); selectedSet.value = s; selected.value = id; }
export function setFocus(id) { focus.value = (focus.value === id ? null : id); }   // toggle
export function setLiveState(id, s) { liveStates.value = { ...liveStates.value, [id]: s }; }

// Bridge for the classic (non-module) scripts, which can't `import`. They call these;
// Preact components import the signals directly above.
window.slateStore = { nbState, selected, selectedSet, focus, cells, title, worker, liveStates, applyState, setSelected, setSelection, toggleInSelection, setFocus, setLiveState };
