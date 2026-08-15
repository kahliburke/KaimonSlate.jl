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
export const localDirty = signal({});                        // cells THIS browser has typed into and not yet applied

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
export function setLiveState(id, s) {
  // `edited` is only ever passed by an editor's own input handler, so it IS the "a human typed
  // here" signal — record it durably, because applyState() wipes liveStates on every server push.
  // Only SET here, never clear: any other transient state (a neighbouring cell's run pushing this
  // one to `fresh`) would otherwise drop an unsaved edit on the floor, which was observed live.
  // Clearing is isDirty's job — it re-checks the text, so the mark lifts the moment the editor
  // agrees with the saved source, whether that came from running, undoing, or discarding.
  if (s === 'edited') markDirty(id);
  liveStates.value = { ...liveStates.value, [id]: s };
}

// Source comparison, shared by every caller — trailing whitespace is not an edit. Defined once
// here because two private copies drifted (one exact `!==`, one tolerant), and the strict copy
// painted cells `edited` over a trailing newline the other considered clean.
export const srcEq = (a, b) => (a || '').replace(/\s+$/, '') === (b || '').replace(/\s+$/, '');
export function markDirty(id) { if (!localDirty.value[id]) localDirty.value = { ...localDirty.value, [id]: true }; }
// Typing back to the saved source is no longer an edit — drop BOTH marks. Called ONLY from an
// editor's own input handler, once its text agrees with the source again: the transient `edited`
// in liveStates outranks everything in <Cell>, so without this the badge sat on `edited` until
// the next server push. Deliberately not driven by cell state — clearing on a neighbour's
// `fresh`/`running` push was observed dropping a genuine unsaved edit.
export function clearEdited(id) {
  if (localDirty.value[id]) { const d = { ...localDirty.value }; delete d[id]; localDirty.value = d; }
  if (liveStates.value[id] === 'edited') { const l = { ...liveStates.value }; delete l[id]; liveStates.value = l; }
}
// `edited` means ONE thing: THIS browser has typing in the cell's editor that hasn't been applied.
// It is NOT inferred from "editor text ≠ server source" — an agent edit landing under an open
// editor also diverges, and inferring from that alone painted the cell `edited` (and froze its
// output) for a change the user never made. Requiring the typed mark keeps agent writes reading as
// `stale`; still re-checking the text keeps it self-healing, so undoing back to the saved source
// drops the mark exactly as running it does. Pure — safe to call during render.
export function isDirty(id, source) {
  return !!localDirty.value[id] && !!window.editors[id] && !srcEq(window.edText(id), source);
}

// Bridge for the classic (non-module) scripts, which can't `import`. They call these;
// Preact components import the signals directly above.
window.slateStore = { nbState, selected, selectedSet, focus, cells, title, worker, liveStates, localDirty, applyState, setSelected, setSelection, toggleInSelection, setFocus, setLiveState, markDirty, clearEdited, isDirty, srcEq };
