// ── Unsaved-edit backup & restore (survive tab close / server restart) ─────────
// In-flight editor edits (typed but not run) live only in CodeMirror — a tab close or a
// server restart loses them. We mirror them to localStorage keyed by notebook id, each entry
// {mine, base}: `mine` is the editor text, `base` the server source when captured — so a reopen
// can tell "server untouched → safe to restore" from "both changed → conflict". On reopen we
// restore the safe ones into their editors (marked edited, NEVER run) and surface conflicts for
// review. Backups self-clear as cells are saved (mine === server) and on explicit discard.

const _BK_KEY = () => 'slate:backup:' + NB_ID;
function _readBackup() { try { return JSON.parse(localStorage.getItem(_BK_KEY()) || '{}'); } catch (_) { return {}; } }
// Single writer, deduped: only touches localStorage when the backup actually changed. Returns
// whether it wrote, so callers can log only on real change (the 2s timer calls this constantly).
let _lastBackupStr = null;
function _writeBackup(b) {
  const s = (b && Object.keys(b).length) ? JSON.stringify(b) : '';
  if (s === _lastBackupStr) return false;
  _lastBackupStr = s;
  try { s ? localStorage.setItem(_BK_KEY(), s) : localStorage.removeItem(_BK_KEY()); } catch (_) {}
  return true;
}

// Entries loaded from a PRIOR session that haven't been restored/discarded yet. On reopen the
// editors hold the SERVER text (the backed-up edit isn't loaded), so a naive sweep would see
// "nothing dirty" and wipe them — destroying exactly what the reconcile modal is about to offer.
// We protect these until they're resolved. `_reconcileRan` gates the sweep until reconcile has
// read the backup, so an early sweep can't clear it first.
let _reconcileRan = false;
const _pendingIds = new Set();
// Snapshot EVERY editor whose content diverges from its last-saved (server) source. Doesn't care
// what KIND of editor it is (always-on code, markdown/@bind source editor, or any future editor),
// as long as it's registered in window.editors. Driven by per-editor change hooks (low latency)
// AND a periodic timer (so nothing a user edits can be missed). MERGES with the stored backup:
// a live dirty editor is captured (and stops being "pending"); a still-pending entry with no dirty
// editor is preserved; anything else (editor back at server — saved or reverted) is dropped.
function backupEdits() {
  if (!_reconcileRan) return;                 // don't manage the backup until reconcile has read it
  const b = {}, prev = _readBackup();
  for (const id of Object.keys(window.editors)) {
    if (!window.editors[id]) continue;
    const mine = window.edText(id), base = window.srcMap[id] || '';
    if (mine !== base) {
      // `ts` = when THIS text was captured (browser-snapshot time). Keep it stable while the text is
      // unchanged so the backup dedup still short-circuits (a fresh ts every sweep would rewrite it).
      const p = prev[id], ts = (p && p.mine === mine && p.ts) ? p.ts : Math.floor(Date.now() / 1000);
      b[id] = { mine, base, ts }; _pendingIds.delete(id);                        // live edit → capture; no longer just pending
    }
  }
  for (const id of _pendingIds) if (!b[id] && prev[id]) b[id] = prev[id];       // preserve un-restored pending entries
  _writeBackup(b);
}
const _backupSoon = debounce(backupEdits, 400);
window.backupEdits = backupEdits;
window._backupSoon = _backupSoon;
// Safety net: a low-frequency sweep of all editors, so capture never depends on a per-editor
// change hook being wired. Idle-cheap — a single DOM check gates the per-editor getValue() work,
// so when nothing is dirty (no cell marked `edited`) the sweep costs ~one querySelector.
setInterval(() => { if (_reconcileRan && document.querySelector('.cell.state-edited')) backupEdits(); }, 2000);
// Capture on tab close. `pagehide` covers Safari/iOS, where `beforeunload` is unreliable.
window.addEventListener('beforeunload', backupEdits);
window.addEventListener('pagehide', backupEdits);

// Pending restores keyed by cell id — the <Editor> mount (notebook.js) applies these for cells
// whose editor isn't created yet; already-mounted editors get it immediately below.
window._pendingRestore = window._pendingRestore || {};
const _cellOf = id => ((window.__slateState && window.__slateState.cells) || []).find(c => c.id === id);
// Load `mine` into a cell's editor as an unsaved edit — non-destructive, never runs the cell.
function _applyRestore(id, mine) {
  const cm = window.editors[id];
  if (cm) {
    window.edSetText(id, mine);
    window.setState && window.setState(id, 'edited');
    delete window._pendingRestore[id];
    return true;
  }
  // No live editor. A markdown / @bind cell edits via its on-demand source editor — open it
  // (editSource applies the pending restore). A code cell's editor mounts async → the <Editor>
  // hook (notebook.js) applies it. Either way, stash the pending value first.
  window._pendingRestore[id] = mine;
  const cell = _cellOf(id);
  if (cell && window.editSource && (cell.kind === 'md' || (cell.binds && cell.binds.length))) {
    window.editSource(id, cell.kind === 'md' ? 'markdown' : 'julia');   // opens + applies pending
    return !window._pendingRestore[id];
  }
  return false;
}
window._applyRestore = _applyRestore;

let _reconcileDone = false;
const _isEmpty = s => !s || !s.trim();
// Run once after the initial state loads. Classify each backed-up cell vs the just-loaded server
// source: already-saved → drop; a brand-new/empty server cell that now has content → auto-accept
// SILENTLY (no harm replacing nothing with something — never shown); otherwise → queue it for the
// reconcile walkthrough (diff + choose). We don't write editors at reconcile time beyond the
// auto-fills; the walkthrough applies on the user's click, when editors definitely exist.
function reconcileBackup(state) {
  if (_reconcileDone) return; _reconcileDone = true; _reconcileRan = true;   // capture may now manage the backup
  const b = _readBackup();
  if (!Object.keys(b).length) return;
  const byId = {}; (state.cells || []).forEach(c => byId[c.id] = c);
  const cands = [], keep = {}; let autoFilled = 0;
  for (const id of Object.keys(b)) {
    const { mine, base } = b[id] || {};
    const cell = byId[id];
    if (!cell) continue;                                          // cell deleted — drop the entry
    const server = cell.source != null ? cell.source : '';
    if (server === mine) continue;                               // already saved — drop
    if (_isEmpty(server) && !_isEmpty(mine)) { _applyRestore(id, mine); keep[id] = b[id]; autoFilled++; continue; }  // empty cell ← content: silent auto-accept
    // ts = when the browser snapshot was captured; serverTs = the notebook file's on-disk mtime.
    cands.push({ id, mine, server, conflict: server !== base, ts: (b[id] || {}).ts, serverTs: state.savedAt || 0 });
    keep[id] = b[id];
  }
  _writeBackup(keep);
  Object.keys(keep).forEach(id => _pendingIds.add(id));   // protect these from the sweep until restored/discarded
  autoFilled && window.toast && window.toast(`Restored ${autoFilled} new cell${autoFilled === 1 ? '' : 's'} from your last session`, 3500, 'ok');
  cands.length && _startReconcile(cands);
}
window.reconcileBackup = reconcileBackup;

// ── Reconcile walkthrough (one cell at a time: navigate · diff · choose) ───────
const _navTo = id => id && window.selectCell && window.selectCell(id, true);
// Revert a cell's editor to the server source and drop its backup entry.
function _discardRestored(ids) {
  const b = _readBackup();
  ids.forEach(id => {
    if (window.editors[id]) { window.edSetText(id, window.srcMap[id] || ''); window.setState && window.setState(id, 'fresh'); }
    delete b[id]; delete window._pendingRestore[id]; _pendingIds.delete(id);
  });
  _writeBackup(b);
}
let _rcQueue = [], _rcIdx = 0;
function _startReconcile(cands) { _rcQueue = cands; _rcIdx = 0; _rcRender(); }
// A LIVE conflict: an external edit (agent / file / another tab) landed on a cell that has the
// user's unsaved edits. Surface it through the same reconcile walkthrough (mine vs theirs). Dedup
// by cell id; append if the modal is already open, else start a fresh one.
function slateLiveConflict(id, mine, server) {
  const m = document.getElementById('reconcilemodal'), open = m && m.style.display !== 'none';
  if (!open) { _rcQueue = []; _rcIdx = 0; }
  const now = Math.floor(Date.now() / 1000);   // a live conflict = an external edit that just landed
  const cur = _rcQueue.find((c, i) => i >= _rcIdx && c.id === id);
  if (cur) { cur.mine = mine; cur.server = server; cur.conflict = true; cur.serverTs = now; cur.live = true; }   // refresh to the latest
  else _rcQueue.push({ id, mine, server, conflict: true, ts: now, serverTs: now, live: true });
  if (!open) _rcRender();
}
window.slateLiveConflict = slateLiveConflict;
function _rcModal() {
  let m = document.getElementById('reconcilemodal');
  if (!m) { m = document.createElement('div'); m.id = 'reconcilemodal'; m.className = 'rcmodal'; document.body.appendChild(m); }
  return m;
}
function _rcClose(msg) { const m = document.getElementById('reconcilemodal'); if (m) m.style.display = 'none'; msg && window.toast && window.toast(msg, 3500, 'ok'); }
// Resolve the current cell (keep mine → restore my edit; else keep the saved version), then advance.
function _rcResolve(useMine) {
  const c = _rcQueue[_rcIdx];
  if (c && useMine) {
    _applyRestore(c.id, c.mine);
    // A LIVE conflict interrupted active editing — hand the cursor back so typing continues. Focus now
    // AND on the next frame, so any blur from closing the modal / state re-render can't win the race.
    if (c.live && window.edFocus) { const _fid = c.id; window.edFocus(_fid); requestAnimationFrame(() => window.edFocus(_fid)); }
  } else if (c) {
    _discardRestored([c.id]);
    // Accepting the incoming change: notebook.js FROZE the external result while the conflict was open
    // (so it couldn't clobber your edit), so re-apply it now from live state — else the cell would keep
    // showing your stale output next to the incoming source.
    if (c.live && window.patchCells) { const nc = _cellOf(c.id); if (nc) window.patchCells([nc]); }
  }
  if (++_rcIdx >= _rcQueue.length) _rcClose(`Reconciled ${_rcQueue.length} cell${_rcQueue.length === 1 ? '' : 's'}`);
  else _rcRender();
}
// Global override: accept ALL remaining cells as mine (best-judgement default = the backed-up text).
function _rcAuto() {
  const rem = _rcQueue.length - _rcIdx;
  for (let i = _rcIdx; i < _rcQueue.length; i++) _applyRestore(_rcQueue[i].id, _rcQueue[i].mine);
  _rcIdx = _rcQueue.length;
  _rcClose(`Restored ${rem} cell${rem === 1 ? '' : 's'} (your edits)`);
}
function _rcRender() {
  const m = _rcModal(), c = _rcQueue[_rcIdx], n = _rcQueue.length, rem = n - _rcIdx;
  _navTo(c.id);                                  // scroll the notebook to this cell behind the modal
  const diff = (typeof _lineDiff === 'function' ? _lineDiff(c.server, c.mine) : [])
    .map(d => `<span class="dl ${d.t}">${d.t === 'add' ? '+' : d.t === 'del' ? '-' : ' '} ${_esc(d.s)}</span>`).join('');
  m.innerHTML = `<div class="rc-card">
    <div class="rc-head"><span class="rc-title">${c.live ? '🤖 A change just landed while you were editing' : '♻️ Unsaved edits from your last session'}</span>
      <span class="rc-prog">cell ‘${_esc(c.id)}’ · ${_rcIdx + 1} of ${n}</span></div>
    ${c.live
      ? `<div class="rc-warn">⚠ An <b>external edit</b> (an agent, the file on disk, or another tab) just changed this cell while you had unsaved edits here. Keep the incoming change, or your edit.</div>`
      : c.conflict
      ? `<div class="rc-warn">⚠ This cell <b>also changed on the server</b> since your edit — review carefully.</div>`
      : `<div class="rc-note">The saved version matches what you started from — your unsaved edit here just isn't on disk yet.</div>`}
    <div class="rc-legend"><span class="dl del">− ${c.live ? 'incoming change' : 'saved version'}</span><span class="dl add">+ your unsaved edit</span></div>
    ${!c.live && c.ts && typeof _reltime === 'function'
      ? `<div class="rc-times">${c.conflict && c.serverTs ? `saved on disk ${_reltime(c.serverTs)} · ` : ''}your edit ${_reltime(c.ts)}</div>` : ''}
    <div class="rc-diff">${diff || '<span class="hint">(no line differences)</span>'}</div>
    <div class="rc-acts">
      <button class="rc-server">${c.live ? 'Use the incoming change' : 'Use saved'}</button>
      <button class="rc-mine primary">Use my edit</button>
    </div>
    <div class="rc-foot">
      <button class="rc-auto" title="accept your edit for this and all remaining cells">Auto-accept all my edits${rem > 1 ? ` (${rem})` : ''}</button>
      <button class="rc-later">Decide later</button>
    </div></div>`;
  m.style.display = 'flex';
  m.querySelector('.rc-server').onclick = () => _rcResolve(false);
  m.querySelector('.rc-mine').onclick = () => _rcResolve(true);
  m.querySelector('.rc-auto').onclick = _rcAuto;
  m.querySelector('.rc-later').onclick = () => _rcClose();
}
