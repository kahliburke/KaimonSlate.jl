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
// EDIT MODE: the id of the cell whose editor holds the keyboard, else null. Mode has to be state,
// not a class poked onto the DOM: <Cell> rewrites the cell's `class` whenever its computed value
// changes (the first keystroke does exactly that, fresh → edited), so an imperatively-added
// `.editing` was silently dropped the moment you started typing and the ring lied about where
// your keys were going.
export const editing  = signal(null);
export const liveStates = signal({});                        // transient per-cell state (running/edited) for instant feedback,
                                                             // until the authoritative server state arrives
export const localDirty = signal({});                        // cells THIS browser has typed into and not yet applied

export const cells = computed(() => (nbState.value && nbState.value.cells) || []);
export const title = computed(() => (nbState.value && nbState.value.title) || 'Notebook');
export const worker = computed(() => (nbState.value && nbState.value.worker) || {});

// Is this incoming cell the same one we already hold? `rev` is the server's own answer — engine.jl
// documents it as "bumped on every change worth pushing" — so an equal rev means nothing about this
// cell changed. The primitive sweep is belt-and-braces for anything that mutates a scalar without
// bumping (a tag toggle, say); structured payloads (output, charts, tables, binds) are left to `rev`,
// because the server re-serialises them into fresh arrays on every push and comparing them by value
// would cost more than the render we are trying to avoid.
function _sameCell(a, b) {
  if (a === b) return true;
  if (!a || !b || a.id !== b.id || a.rev !== b.rev || typeof a.rev !== 'number') return false;
  const ka = Object.keys(a);
  if (ka.length !== Object.keys(b).length) return false;
  for (const k of ka) {
    const va = a[k], vb = b[k];
    if (va === vb) continue;
    if (va !== null && typeof va === 'object' && vb !== null && typeof vb === 'object') continue;
    return false;
  }
  return true;
}

// Carry unchanged cell OBJECTS across a state push. Every push is freshly parsed JSON, so without
// this every cell in the document arrives with a new identity and the view re-renders all of them,
// on every push — and a single run produces a push per cell transition. Reusing the old object lets
// the view skip the cells that did not change (see MemoCell.shouldComponentUpdate).
function _shareUnchanged(prev, next) {
  if (!prev || !Array.isArray(prev.cells) || !Array.isArray(next.cells)) return next;
  const before = new Map(prev.cells.map(c => [c.id, c]));
  let reused = 0;
  const cells = next.cells.map(c => {
    const old = before.get(c.id);
    if (old && _sameCell(old, c)) { reused++; return old; }
    return c;
  });
  return reused ? { ...next, cells } : next;
}

// New server state is authoritative — drop the transient live-state overrides.
export function applyState(state) {
  if (!state) return;
  nbState.value = _shareUnchanged(nbState.value, state);
  if (Object.keys(liveStates.value).length) liveStates.value = {};
}
// Single-select: the active cell IS the whole selection.
export function setSelected(id) { selected.value = id; selectedSet.value = new Set(id ? [id] : []); }
// Multi-select: set the whole selection at once; `active` is the primary/anchor cell.
export function setSelection(ids, active) { selectedSet.value = new Set(ids); selected.value = active != null ? active : (ids.length ? ids[ids.length - 1] : null); }
// Toggle one cell in/out of the selection (⌘/ctrl-click); the toggled cell becomes active.
export function toggleInSelection(id) { const s = new Set(selectedSet.value); s.has(id) ? s.delete(id) : s.add(id); selectedSet.value = s; selected.value = id; }
export function setFocus(id) { focus.value = (focus.value === id ? null : id); }   // toggle
// Enter/leave edit mode. Clearing is guarded on the id: focus moving between two cells fires the
// old editor's blur AFTER the new one's focus, and an unguarded clear would drop the mode we just
// entered. Callers must also clear on DESTROY — tearing down a focused editor moves focus to the
// body without firing a blur event, which is how a cell used to keep an edit-mode ring forever.
export function setEditingCell(id, on) {
  if (on) { if (editing.value !== id) editing.value = id; }
  else if (editing.value === id) editing.value = null;
}
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
window.slateStore = { nbState, selected, selectedSet, focus, editing, cells, title, worker, liveStates, localDirty, applyState, setSelected, setSelection, toggleInSelection, setFocus, setEditingCell, setLiveState, markDirty, clearEdited, isDirty, srcEq };
