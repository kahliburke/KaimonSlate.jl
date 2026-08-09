// ── Files tab: browse + edit + preview the notebook's OWN project files ─────────────────────────────
// Fetches the project tree (/api/tree). A click routes on the node's `kind`:
//   text            → open in a standalone CM6 editor (window.mkFileEditor); ⌘S / Save writes it back
//                     (POST /api/file). A save just hits disk — the worker's Revise hot-reload watcher
//                     reloads it and restales the cells that use it (memo `_src_digest` makes that
//                     precise); we deliberately do NOT rerun from here.
//   image/audio/video → preview inline via the raw `/n/{id}/asset/**` byte route (no base64-in-JSON).
//   binary          → a guarded info card (size + Download + "open as text anyway").
// Structural operations (new / new folder / rename / duplicate / delete) go through /api/file-op from
// a right-click menu; dropping files onto a folder attaches them there (/api/attach).
//
// A save carries the mtime the file was OPENED at, so an edit made meanwhile in another editor is a
// 409 (reload-vs-overwrite) instead of a silent clobber — see `_filesSave`.
let _filesTree = null, _fileView = null, _fileOpen = null, _fileDirty = false;
let _fileMtime = 0;            // disk mtime the open file was read at (the save's concurrency token)
let _fileStale = false;        // the open file changed on disk under a dirty buffer
let _fileSel = '';             // selected tree path (file OR dir) — survives a tree reload
let _filesFilter = '';
const _fileStates = {};        // path → {anchor, head, scrollTop} — where each file was last left
const _openDirs = new Set();   // expanded directory paths
let _openDirsInit = false;

const _lsKey = k => 'slateFiles' + k + ':' + (typeof NB_ID === 'undefined' ? '' : NB_ID);
const _filesHiddenPref = () => localStorage.getItem(_lsKey('Hidden')) === '1';

// Raw byte URL for a project-relative path (the media/download route), each segment URL-encoded.
function _assetURL(path) {
  return '/n/' + NB_ID + '/asset/' + String(path).split(/[\\/]/).map(encodeURIComponent).join('/');
}
function _fmtBytes(n) {
  if (!(n > 0)) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)) + ' ' + u[i];
}
function _kindIcon(kind) {
  return kind === 'image' ? '🖼️' : kind === 'audio' ? '🔊' : kind === 'video' ? '🎬'
       : kind === 'binary' ? '📦' : '📄';
}
const _baseName = p => String(p).split(/[\\/]/).pop();
const _dirName = p => { const i = String(p).replace(/\\/g, '/').lastIndexOf('/'); return i < 0 ? '' : p.slice(0, i); };
const _joinRel = (dir, name) => (dir ? dir.replace(/\/+$/, '') + '/' : '') + name;
const _toast = (m, ms, cls) => { if (window.toast) toast(m, ms || 3500, cls || 'ok'); };

function toggleFiles() {
  const p = document.getElementById('filespanel');
  const opening = !p.classList.contains('open');
  p.classList.toggle('open');
  if (opening) _filesLoadOpenNbs();                 // the hub's notebook list can change while we're away
  if (opening && _filesTree === null) _filesLoadTree();
  else if (opening) { _filesCheckExternal(); if (_fileView) setTimeout(() => _fileView.focus(), 0); }
}
window.toggleFiles = toggleFiles;

// ── tree loading + rendering ────────────────────────────────────────────────
// `opts.select` re-selects a path after the reload (e.g. the file a rename produced). Tree scroll
// position and expansion state are preserved across every reload — a create/attach/rename must not
// collapse the tree back to its initial shape.
async function _filesLoadTree(opts) {
  opts = opts || {};
  const box = document.getElementById('filestree');
  const scroll = box ? box.scrollTop : 0;
  if (_filesTree === null) { box.textContent = ''; box.appendChild(_hintEl('loading…')); }
  try {
    const q = _filesHiddenPref() ? '?hidden=1' : '';
    _filesTree = await (await fetch(_apipath('/api/tree' + q))).json();
  } catch (_) { box.textContent = ''; box.appendChild(_hintEl('failed to load the project tree')); _filesTree = null; return; }
  const rootEl = document.getElementById('filesroot');
  const detached = _filesTree.detached || !(_filesTree.tree || []).length;
  document.querySelectorAll('#filestreebar button, #filesfilter').forEach(b => { b.disabled = !!_filesTree.detached; });
  if (detached) {
    if (rootEl) rootEl.textContent = '';
    box.textContent = '';
    box.appendChild(_hintEl(_filesTree.detached ? 'no editable project source (in-process notebook)'
                                                : 'this project has no visible files'));
    return;
  }
  if (rootEl) rootEl.textContent = _filesTree.name || '';
  if (!_openDirsInit) {                          // first load: top-level dirs open, as before
    for (const n of _filesTree.tree) if (n.dir) _openDirs.add(n.path);
    _openDirsInit = true;
  }
  if (opts.select) { _fileSel = opts.select; for (let d = _dirName(opts.select); d; d = _dirName(d)) _openDirs.add(d); }
  _filesRender();
  if (opts.select) _filesScrollSelIntoView(); else box.scrollTop = scroll;
}
window._filesLoadTree = _filesLoadTree;
function _hintEl(t) { const d = document.createElement('div'); d.className = 'hint'; d.style.padding = '8px'; d.textContent = t; return d; }

// Subsequence match over the whole relative path, so `srvcmp` finds `src/server_complete.jl`.
function _fuzzy(hay, needle) {
  if (!needle) return true;
  hay = String(hay).toLowerCase();
  let i = 0;
  for (const ch of needle) { i = hay.indexOf(ch, i); if (i < 0) return false; i++; }
  return true;
}
const _dirHasMatch = n => (n.children || []).some(c => c.dir ? _dirHasMatch(c) : _fuzzy(c.path, _filesFilter));

// Flatten the tree into the rows that are currently VISIBLE (expansion + filter applied). A filter
// force-expands every directory on a matching path, so results are visible without clicking.
function _visibleRows(nodes, depth, out) {
  for (const n of nodes) {
    if (n.dir) {
      if (_filesFilter && !_dirHasMatch(n)) continue;
      const open = _filesFilter ? true : _openDirs.has(n.path);
      out.push({ n, depth, dir: true, open });
      if (open) _visibleRows(n.children || [], depth + 1, out);
    } else if (_fuzzy(n.path, _filesFilter)) {
      out.push({ n, depth, dir: false });
    }
  }
  return out;
}

function _filesRender() {
  const box = document.getElementById('filestree');
  if (!box || !_filesTree || _filesTree.detached) return;
  const rows = _visibleRows(_filesTree.tree || [], 0, []);
  box.textContent = '';
  if (!rows.length) { box.appendChild(_hintEl(_filesFilter ? 'no file matches “' + _filesFilter + '”' : 'empty')); return; }
  const frag = document.createDocumentFragment();
  for (const r of rows) frag.appendChild(_filesRow(r));
  box.appendChild(frag);
  const cnt = document.getElementById('filescount');
  if (cnt) cnt.textContent = _filesFilter ? rows.filter(r => !r.dir).length + ' match' + (rows.filter(r => !r.dir).length === 1 ? '' : 'es') : '';
}

function _filesRow(r) {
  const n = r.n;
  const el = document.createElement('div');
  el.className = 'ftrow ' + (r.dir ? 'ftdir' : 'ftfile') + (n.hidden ? ' fthidden' : '');
  el.style.paddingLeft = (6 + r.depth * 13 + (r.dir ? 0 : 4)) + 'px';
  el.dataset.path = n.path;
  el.dataset.dir = r.dir ? '1' : '';
  el.tabIndex = -1;
  if (r.dir) {
    const tw = document.createElement('span'); tw.className = 'fttw'; tw.textContent = r.open ? '▾' : '▸';
    el.appendChild(tw);
    el.appendChild(document.createTextNode('📁 ' + n.name));
    el.onclick = () => { _filesToggleDir(n.path); };
    _filesDropTarget(el, n.path);
  } else {
    el.dataset.kind = n.kind || 'text';
    const ico = document.createElement('span'); ico.className = 'ftico';
    ico.textContent = n.notebook ? '📓' : _kindIcon(n.kind);
    if (n.notebook) ico.title = 'a Slate notebook — double-click to open it';
    el.appendChild(ico);
    el.appendChild(document.createTextNode(' ' + n.name));
    if (n.path === (_filesTree.self || ' ')) {
      const s = document.createElement('span'); s.className = 'ftself'; s.textContent = 'notebook';
      s.title = "this notebook's own source"; el.appendChild(s);
    }
    if (n.bytes) { const s = document.createElement('span'); s.className = 'ftsize'; s.textContent = _fmtBytes(n.bytes); el.appendChild(s); }
    el.onclick = () => _filesOpen(n.path, n.kind || 'text');
    // A notebook opens as a NOTEBOOK on double-click (single click still edits its source as text —
    // both are legitimate things to want from a `.jl`).
    if (n.notebook && n.path !== (_filesTree.self || ' ')) el.ondblclick = () => _filesOpenNotebook(n.path);
    _filesDropTarget(el, _dirName(n.path));
  }
  if (n.path === _fileSel) el.classList.add('sel');
  el.oncontextmenu = ev => { ev.preventDefault(); _fileSel = n.path; _filesMarkSel(); _filesMenu(ev, n, r.dir); };
  return el;
}

function _filesToggleDir(path) {
  _openDirs.has(path) ? _openDirs.delete(path) : _openDirs.add(path);
  _fileSel = path;
  _filesRender();
}
function _filesMarkSel() {
  document.querySelectorAll('#filestree .ftrow').forEach(x => x.classList.toggle('sel', x.dataset.path === _fileSel));
}
function _filesScrollSelIntoView() {
  const el = document.querySelector('#filestree .ftrow.sel');
  if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' });
}

// Find a node by path (files and dirs).
function _findNode(path, nodes) {
  for (const n of (nodes || (_filesTree && _filesTree.tree) || [])) {
    if (n.path === path) return n;
    if (n.dir) { const f = _findNode(path, n.children || []); if (f) return f; }
  }
  return null;
}

// ── toolbar: filter, hidden files, refresh ──────────────────────────────────
function _filesSetFilter(v) {
  _filesFilter = String(v || '').trim().toLowerCase();
  _filesRender();
}
window._filesSetFilter = _filesSetFilter;
function _filesToggleHidden() {
  const on = !_filesHiddenPref();
  localStorage.setItem(_lsKey('Hidden'), on ? '1' : '0');
  _filesSyncHiddenBtn();
  _filesLoadTree();
}
window._filesToggleHidden = _filesToggleHidden;
function _filesSyncHiddenBtn() {
  const b = document.getElementById('fileshidden');
  if (!b) return;
  const on = _filesHiddenPref();
  b.classList.toggle('on', on);
  b.title = on ? 'Hiding dotfiles' : 'Show dotfiles (.gitignore, .github/…)';
}

// ── keyboard navigation in the tree ─────────────────────────────────────────
// ↑/↓ move, →/← expand/collapse (← on a file jumps to its folder), Enter opens, F2 renames,
// ⌫ deletes, `/` jumps to the filter box.
function _filesTreeKey(ev) {
  const rows = Array.from(document.querySelectorAll('#filestree .ftrow'));
  if (!rows.length) return;
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  const i = rows.findIndex(r => r.dataset.path === _fileSel);
  const k = ev.key;
  if (!['ArrowDown', 'ArrowUp', 'ArrowRight', 'ArrowLeft', 'Enter', 'F2', 'Backspace', 'Delete', '/'].includes(k)) return;
  // Swallow the key: the notebook's command-mode shortcuts (Backspace deletes a CELL) are on
  // document and would otherwise fire behind the tree.
  ev.preventDefault(); ev.stopPropagation();
  const sel = j => { _fileSel = rows[Math.max(0, Math.min(rows.length - 1, j))].dataset.path; _filesMarkSel(); _filesScrollSelIntoView(); };
  if (k === 'ArrowDown') sel(i + 1);
  else if (k === 'ArrowUp') sel(i < 0 ? rows.length - 1 : i - 1);
  else if (k === 'ArrowRight') {
    const n = _findNode(_fileSel); if (!n) return;
    if (n.dir && !_openDirs.has(n.path)) { _openDirs.add(n.path); _filesRender(); } else sel(i + 1);
  } else if (k === 'ArrowLeft') {
    const n = _findNode(_fileSel); if (!n) return;
    if (n.dir && _openDirs.has(n.path)) { _openDirs.delete(n.path); _filesRender(); }
    else { const d = _dirName(_fileSel); if (d) { _fileSel = d; _filesMarkSel(); _filesScrollSelIntoView(); } }
  } else if (k === 'Enter') {
    const n = _findNode(_fileSel); if (!n) return;
    n.dir ? _filesToggleDir(n.path) : _filesOpen(n.path, n.kind || 'text');
  } else if (k === 'F2') { const n = _findNode(_fileSel); if (n) _fileOpRename(n); }
  else if (k === 'Backspace' || k === 'Delete') { const n = _findNode(_fileSel); if (n) _fileOpDelete(n); }
  else if (k === '/') { const f = document.getElementById('filesfilter'); if (f) { f.focus(); f.select(); } }
}
window._filesTreeKey = _filesTreeKey;

// ── context menu ────────────────────────────────────────────────────────────
let _ftMenuEl = null;
function _filesCloseMenu() { if (_ftMenuEl) { _ftMenuEl.remove(); _ftMenuEl = null; } }
document.addEventListener('mousedown', e => { if (_ftMenuEl && !_ftMenuEl.contains(e.target)) _filesCloseMenu(); }, true);
document.addEventListener('keydown', e => { if (_ftMenuEl && e.key === 'Escape') { e.stopPropagation(); _filesCloseMenu(); } }, true);

function _filesMenu(ev, n, isDir) {
  _filesCloseMenu();
  const isSelf = !isDir && n.path === (_filesTree && _filesTree.self);
  const dir = isDir ? n.path : _dirName(n.path);
  const items = [];
  if (!isDir && n.notebook) items.push(['Open as notebook ↗', isSelf ? null : () => _filesOpenNotebook(n.path),
                                        isSelf ? 'this is the notebook you are in' : '']);
  if (!isDir) items.push([n.notebook ? 'Edit source' : 'Open', () => _filesOpen(n.path, n.kind || 'text')]);
  items.push(['New file…', () => _fileOpNew(dir)]);
  items.push(['New folder…', () => _fileOpMkdir(dir)]);
  items.push(['—']);
  items.push(['Rename…', isSelf ? null : () => _fileOpRename(n),
              isSelf ? "the notebook's own file — rename it from the notebook title" : '']);
  if (!isDir) items.push(['Duplicate', () => _fileOpDuplicate(n)]);
  items.push(['Copy path', () => _fileOpCopyPath(n)]);
  if (!isDir) items.push(['Download', () => _fileOpDownload(n)]);
  items.push(['—']);
  items.push(['Delete…', isSelf ? null : () => _fileOpDelete(n), '', 'danger']);
  const m = document.createElement('div');
  m.className = 'ftmenu';
  for (const [label, fn, title, cls] of items) {
    if (label === '—') { const s = document.createElement('div'); s.className = 'ftmsep'; m.appendChild(s); continue; }
    const b = document.createElement('button');
    b.className = 'ftmitem' + (cls ? ' ' + cls : '') + (fn ? '' : ' disabled');
    b.textContent = label; if (title) b.title = title;
    if (fn) b.onclick = () => { _filesCloseMenu(); fn(); }; else b.disabled = true;
    m.appendChild(b);
  }
  document.body.appendChild(m);
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(ev.clientX, innerWidth - r.width - 8) + 'px';
  m.style.top = Math.min(ev.clientY, innerHeight - r.height - 8) + 'px';
  _ftMenuEl = m;
}

// ── opening / switching notebooks ───────────────────────────────────────────
// A `.jl` in the tree that carries Slate structure (server-marked `notebook`) can be opened AS a
// notebook rather than edited as text. `/api/open` is hub-global and idempotent — an already-open
// notebook returns its existing id, so this doubles as "switch to it".
async function _filesOpenNotebook(rel) {
  if (!_filesTree || rel === _filesTree.self) return;
  if (!await _filesConfirmDiscard()) return;
  const abs = (_filesTree.root || '').replace(/\/+$/, '') + '/' + rel;
  try {
    if (window.showLoading) showLoading('Opening ' + _baseName(rel) + '…');
    const r = await fetch('/api/open', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: abs }),
    });
    if (!r.ok) {
      if (window.hideLoading) hideLoading();
      await alertDark('Could not open ' + rel + ' as a notebook:\n' + (await r.text()));
      return;
    }
    const j = await r.json();
    _fileDirty = false;                          // guarded above; don't trip beforeunload on the way out
    location.href = j.url;
  } catch (e) {
    if (window.hideLoading) hideLoading();
    await alertDark('Open failed: ' + e);
  }
}
window._filesOpenNotebook = _filesOpenNotebook;

// The "Open notebooks" strip above the tree: every notebook this hub is serving, so the Files panel
// is also how you switch between them (including notebooks outside this project). The current one is
// marked and inert.
async function _filesLoadOpenNbs() {
  const box = document.getElementById('filesnbs');
  if (!box) return;
  let nbs = [];
  try { nbs = await (await fetch('/api/notebooks', { cache: 'no-store' })).json(); } catch (_) { return; }
  box.textContent = '';
  for (const n of (nbs || [])) {
    const el = document.createElement('div');
    const here = n.id === NB_ID;
    el.className = 'ftrow ftnb' + (here ? ' current' : '');
    const ico = document.createElement('span'); ico.className = 'ftico'; ico.textContent = here ? '▶' : '📓';
    el.appendChild(ico);
    el.appendChild(document.createTextNode(' ' + (n.title || n.id)));
    if (n.errors) { const b = document.createElement('span'); b.className = 'ftnberr'; b.textContent = n.errors + ' err'; el.appendChild(b); }
    el.title = n.path || '';
    if (!here) el.onclick = async () => {
      if (!await _filesConfirmDiscard()) return;
      _fileDirty = false; location.href = '/n/' + encodeURIComponent(n.id);
    };
    box.appendChild(el);
  }
  const idx = document.createElement('a');
  idx.className = 'ftrow ftnbindex'; idx.href = '/'; idx.textContent = '⌂ All notebooks…';
  box.appendChild(idx);
}
window._filesLoadOpenNbs = _filesLoadOpenNbs;

// ── file operations (/api/file-op) ──────────────────────────────────────────
async function _fileOp(body) {
  try {
    const r = await fetch(_apipath('/api/file-op'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    if (!r.ok) { await alertDark(body.op + ' failed:\n' + (await r.text())); return null; }
    return await r.json();
  } catch (e) { await alertDark(body.op + ' failed: ' + e); return null; }
}

async function _fileOpNew(dir) {
  if (!_filesTree || _filesTree.detached) return;
  const rel = await promptDark('New file in ' + (dir || _filesTree.name || 'project') + ':', '', { ok: 'Create', placeholder: 'name.jl', selectAll: true });
  if (!rel) return;
  const path = _joinRel(dir, rel).replace(/^\/+/, '');
  try {
    const r = await fetch(_apipath('/api/file'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path, content: '', create: true }),
    });
    if (!r.ok) { await alertDark('Could not create ' + path + ':\n' + (await r.text())); return; }
    const j = await r.json().catch(() => ({}));
    await _filesLoadTree({ select: path });
    _filesMount(path, '', j.mtime || 0);
  } catch (e) { await alertDark('Create failed: ' + e); }
}
window._filesNewFile = () => _fileOpNew(_fileSel && _findNode(_fileSel) && _findNode(_fileSel).dir ? _fileSel : _dirName(_fileSel));

async function _fileOpMkdir(dir) {
  const name = await promptDark('New folder in ' + (dir || _filesTree.name || 'project') + ':', '', { ok: 'Create', placeholder: 'name', selectAll: true });
  if (!name) return;
  const path = _joinRel(dir, name).replace(/^\/+/, '');
  const j = await _fileOp({ op: 'mkdir', path });
  if (j) { _openDirs.add(path); await _filesLoadTree({ select: path }); }
}

async function _fileOpRename(n) {
  const to = await promptDark('Rename ' + n.path + ' to:', n.name, { ok: 'Rename' });
  if (!to || to === n.name) return;
  // A typed `/` means move: the name is interpreted relative to the file's own folder.
  const dst = _joinRel(_dirName(n.path), to).replace(/^\/+/, '');
  const j = await _fileOp({ op: 'rename', path: n.path, to: dst });
  if (!j) return;
  if (_fileOpen === n.path) { _fileOpen = j.path; _filesSetPath(j.path); _filesSetDownload(j.path); }
  if (_fileStates[n.path]) { _fileStates[j.path] = _fileStates[n.path]; delete _fileStates[n.path]; }
  await _filesLoadTree({ select: j.path });
  _toast('Renamed → ' + j.path);
}

async function _fileOpDuplicate(n) {
  const j = await _fileOp({ op: 'duplicate', path: n.path });
  if (!j) return;
  await _filesLoadTree({ select: j.path });
  const node = _findNode(j.path);
  if (node && (node.kind || 'text') === 'text') _filesOpen(j.path, 'text');
  _toast('Duplicated → ' + j.path);
}

async function _fileOpDelete(n) {
  const isDir = !!n.dir;
  let count = 0;
  if (isDir) { const walk = x => { for (const c of x.children || []) { count++; if (c.dir) walk(c); } }; walk(n); }
  const msg = isDir
    ? 'Delete the folder ' + n.path + ' and everything in it (' + count + ' item' + (count === 1 ? '' : 's') + ')?\nThis cannot be undone.'
    : 'Delete ' + n.path + '?\nThis cannot be undone.';
  if (!await confirmDark(msg, 'Delete', 'danger')) return;
  const j = await _fileOp({ op: 'delete', path: n.path, recursive: isDir });
  if (!j) return;
  if (_fileOpen && (_fileOpen === n.path || (isDir && _fileOpen.startsWith(n.path + '/')))) _filesClose();
  delete _fileStates[n.path];
  _fileSel = _dirName(n.path);
  await _filesLoadTree();
  _toast('Deleted ' + n.path, 3500, 'err');
}

async function _fileOpCopyPath(n) {
  const abs = ((_filesTree && _filesTree.root) || '') + '/' + n.path;
  try { await navigator.clipboard.writeText(abs); _toast('Copied ' + abs); }
  catch (_) { await alertDark(abs); }
}
function _fileOpDownload(n) {
  const a = document.createElement('a');
  a.href = _assetURL(n.path); a.download = n.name; document.body.appendChild(a); a.click(); a.remove();
}

// ── drag & drop into a folder ───────────────────────────────────────────────
// Dropping OS files onto a folder row (or onto empty tree space → `assets/`) copies them in via
// /api/attach — the same route a cell-editor drop uses, pointed at the chosen subdir.
function _filesDropTarget(el, dir) {
  el.addEventListener('dragover', ev => {
    if (!(ev.dataTransfer && Array.from(ev.dataTransfer.types || []).includes('Files'))) return;
    ev.preventDefault(); ev.stopPropagation(); ev.dataTransfer.dropEffect = 'copy';
    el.classList.add('ftdrop');
  });
  el.addEventListener('dragleave', () => el.classList.remove('ftdrop'));
  el.addEventListener('drop', ev => {
    const files = ev.dataTransfer && ev.dataTransfer.files;
    if (!files || !files.length) return;
    ev.preventDefault(); ev.stopPropagation();
    el.classList.remove('ftdrop');
    _filesUploadInto(files, dir);
  });
}
async function _filesUploadInto(files, dir) {
  const target = dir || '.';                    // "." = the project root (attach resolves it there)
  let last = '';
  for (const f of Array.from(files)) {
    if (f.size > 64 * 1024 * 1024) { _toast(f.name + ' is too large (' + _fmtBytes(f.size) + ')', 6000, 'err'); continue; }
    let dataURL;
    try { dataURL = await _readDataURL(f); } catch (_) { _toast('Could not read ' + f.name, 4000, 'err'); continue; }
    try {
      const r = await fetch(_apipath('/api/attach'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: f.name, contentB64: dataURL.slice(dataURL.indexOf(',') + 1), subdir: target }),
      });
      if (!r.ok) { _toast('Upload failed: ' + (await r.text()), 5000, 'err'); continue; }
      const j = await r.json(); last = j.path;
      _toast('⭱ ' + j.path);
    } catch (e) { _toast('Upload failed: ' + e, 5000, 'err'); }
  }
  if (last) await _filesLoadTree({ select: last });
}

// Open a node by kind: text → editor, media → preview, binary → info card. `forceText` (from the
// card's "open as text" button) re-fetches with `?as=text` regardless of the file's classified kind.
async function _filesOpen(path, kind, forceText) {
  if (path === _fileOpen && !forceText && !_fileDirty) { if (_fileView) _fileView.focus(); return; }
  if (!await _filesConfirmDiscard()) return;
  _filesStashState();
  _fileSel = path; _filesMarkSel();
  const effective = forceText ? 'text' : kind;
  if (effective === 'text') {
    try {
      const r = await fetch(_apipath('/api/file?path=' + encodeURIComponent(path) + (forceText ? '&as=text' : '')));
      if (!r.ok) { await alertDark('Could not open ' + path + ':\n' + (await r.text())); return; }
      const j = await r.json();
      _filesMount(path, j.content, j.mtime || 0);
    } catch (e) { await alertDark('Open failed: ' + e); }
  } else {
    _filesPreview(path, kind);
  }
}
// Guard leaving an unsaved buffer: save / discard / stay.
async function _filesConfirmDiscard() {
  if (!_fileDirty) return true;
  const v = await dlg('Unsaved changes to ' + _fileOpen + '.', [
    { label: 'Stay', value: 'stay' }, { label: 'Discard', value: 'discard', cls: 'danger' },
    { label: 'Save', value: 'save', cls: 'primary' }]);
  if (v === 'save') { const ok = await _filesSave(); return ok; }
  return v === 'discard';
}
function _filesStashState() {
  if (_fileOpen && _fileView && window.fileEditorState) _fileStates[_fileOpen] = window.fileEditorState(_fileView);
}

// ── text editor mode ────────────────────────────────────────────────────────
function _filesShowEditor() {
  document.getElementById('fileedit').style.display = '';
  const pv = document.getElementById('filepreview'); pv.style.display = 'none'; pv.textContent = '';
}
function _filesMount(path, content, mtime) {
  _filesShowEditor();
  const host = document.getElementById('fileedit');
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  host.textContent = '';
  _fileOpen = path; _fileDirty = false; _fileMtime = mtime || 0; _fileStale = false;
  _filesSetPath(path);
  _filesSetDownload(path);
  _filesSyncDirty();
  _fileView = window.mkFileEditor(host, content, {
    filename: path,
    state: _fileStates[path],
    onSave: _filesSave,
    onChange: () => { if (!_fileDirty) { _fileDirty = true; _filesSyncDirty(); } },
  });
  setTimeout(() => { try { _fileView.focus(); } catch (_) {} }, 0);
}
// Tear the editor down (the open file was deleted or renamed away).
function _filesClose() {
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  document.getElementById('fileedit').textContent = '';
  _fileOpen = null; _fileDirty = false; _fileMtime = 0; _fileStale = false;
  const pe = document.getElementById('filepath'); if (pe) { pe.textContent = 'select a file'; pe.classList.add('hint'); }
  const dl = document.getElementById('filedownload'); if (dl) dl.style.display = 'none';
  _filesSyncDirty();
}

// ── media / binary preview mode ─────────────────────────────────────────────
function _filesPreview(path, kind) {
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  _fileOpen = null; _fileDirty = false; _fileMtime = 0; _fileStale = false; _filesSyncDirty();
  _filesSetPath(path);
  _filesSetDownload(path);
  document.getElementById('fileedit').style.display = 'none';
  const pv = document.getElementById('filepreview');
  pv.style.display = ''; pv.textContent = '';
  const url = _assetURL(path);

  if (kind === 'image') {
    const img = document.createElement('img'); img.src = url; img.alt = path;
    const meta = document.createElement('div'); meta.className = 'fpmeta'; meta.textContent = _baseName(path);
    img.onload = () => { meta.textContent = img.naturalWidth + '×' + img.naturalHeight + ' · ' + _baseName(path); };
    pv.appendChild(img); pv.appendChild(meta);
    pv.appendChild(_previewActions(path, kind, /*offerText=*/ /\.svg$/i.test(path)));
  } else if (kind === 'audio') {
    const a = document.createElement('audio'); a.controls = true; a.src = url;
    pv.appendChild(a); pv.appendChild(_previewActions(path, kind, false));
  } else if (kind === 'video') {
    const v = document.createElement('video'); v.controls = true; v.src = url;
    pv.appendChild(v); pv.appendChild(_previewActions(path, kind, false));
  } else {
    // binary / unknown — a guarded card
    const card = document.createElement('div'); card.className = 'fpcard';
    const ic = document.createElement('div'); ic.className = 'fpicon'; ic.textContent = '📦';
    const nm = document.createElement('div'); nm.style.margin = '6px 0'; nm.style.color = 'var(--text)'; nm.textContent = _baseName(path);
    const sz = document.createElement('div'); sz.textContent = 'Binary file — not shown';
    card.appendChild(ic); card.appendChild(nm); card.appendChild(sz);
    card.appendChild(_previewActions(path, kind, true));
    pv.appendChild(card);
  }
}
// Download + optional "open as text anyway" row shared by every preview kind.
function _previewActions(path, kind, offerText) {
  const row = document.createElement('div'); row.className = 'fprow';
  const dl = document.createElement('a'); dl.className = 'ftbtn'; dl.href = _assetURL(path);
  dl.download = _baseName(path); dl.textContent = '⭳ Download';
  row.appendChild(dl);
  if (offerText) {
    const t = document.createElement('button'); t.className = 'ftbtn'; t.textContent = '≡ Open as text';
    t.onclick = () => _filesOpen(path, kind, /*forceText=*/ true);
    row.appendChild(t);
  }
  return row;
}

// ── toolbar / status helpers ────────────────────────────────────────────────
function _filesSetPath(path) {
  const pe = document.getElementById('filepath');
  if (pe) { pe.textContent = path; pe.classList.remove('hint'); }
}
function _filesSetDownload(path) {
  const dl = document.getElementById('filedownload');
  if (!dl) return;
  dl.href = _assetURL(path); dl.download = _baseName(path); dl.style.display = '';
}
function _filesSyncDirty() {
  // The open file is itself a notebook → offer to leave the text editor and open it for real.
  const nbBtn = document.getElementById('fileopennb');
  if (nbBtn) {
    const node = _fileOpen ? _findNode(_fileOpen) : null;
    const show = !!(node && node.notebook && _filesTree && _fileOpen !== _filesTree.self);
    nbBtn.style.display = show ? '' : 'none';
    nbBtn.onclick = show ? () => _filesOpenNotebook(_fileOpen) : null;
  }
  const b = document.getElementById('filesave');
  if (b) { b.disabled = !_fileOpen || !_fileDirty; b.textContent = _fileDirty ? 'Save ⌘S' : 'Saved';
    b.style.display = _fileOpen ? '' : 'none'; }        // Save is meaningless in preview mode
  const dot = document.getElementById('filedirty'); if (dot) dot.style.visibility = _fileDirty ? 'visible' : 'hidden';
  const st = document.getElementById('filestale');
  if (st) { st.style.display = _fileStale ? '' : 'none'; }
}

// The open file's disk state moved while we were editing it. Not-dirty → silently adopt the new
// bytes (the panel should never show a stale copy). Dirty → flag it, and let the save's own 409
// handling resolve the two versions.
async function _filesCheckExternal() {
  if (!_fileOpen || !_fileView) return;
  let j;
  try {
    const r = await fetch(_apipath('/api/file?path=' + encodeURIComponent(_fileOpen)));
    if (!r.ok) return;
    j = await r.json();
  } catch (_) { return; }
  if (!j || !j.mtime || Math.abs(j.mtime - _fileMtime) < 1e-6) return;
  if (_fileDirty) { _fileStale = true; _filesSyncDirty(); return; }
  _filesStashState();
  _filesMount(_fileOpen, j.content, j.mtime);
  _toast('↻ ' + _fileOpen + ' reloaded — it changed on disk');
}
addEventListener('focus', () => {
  const p = document.getElementById('filespanel');
  if (p && p.classList.contains('open')) _filesCheckExternal();
});

// Save the open buffer. Sends the mtime it was opened at; a 409 means someone else wrote the file
// meanwhile, and we ask rather than clobber. Resolves true when the file is on disk as shown.
async function _filesSave() {
  if (!_fileOpen || !_fileView) return false;
  const path = _fileOpen;
  const content = _fileView.state.doc.toString();
  try {
    const post = force => fetch(_apipath('/api/file'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path, content, mtime: _fileMtime, force: !!force }),
    });
    let r = await post(false);
    if (r.status === 409) {
      const j = await r.json().catch(() => ({}));
      if (!j.conflict) { await alertDark('Save failed:\n' + (j.message || 'conflict')); return false; }
      const v = await dlg(path + ' changed on disk since you opened it.\n\n'
        + 'Overwrite it with your version, or discard your edits and reload what is on disk?', [
        { label: 'Cancel', value: 'cancel' },
        { label: 'Reload from disk', value: 'reload' },
        { label: 'Overwrite', value: 'force', cls: 'danger' }]);
      if (v === 'cancel') return false;
      if (v === 'reload') {
        _fileDirty = false; _filesStashState();
        _filesMount(path, j.content || '', j.mtime || 0);
        _toast('↻ reloaded ' + path);
        return false;
      }
      r = await post(true);
    }
    if (!r.ok) { await alertDark('Save failed:\n' + (await r.text())); return false; }
    const j = await r.json().catch(() => ({}));
    _fileMtime = j.mtime || 0; _fileDirty = false; _fileStale = false; _filesSyncDirty();
    if (window.showLoading) { showLoading('Saved ' + path + ' — Revise will reload it ✓'); setTimeout(hideLoading, 950); }
    // A new file's size/mtime changed — keep the tree's metadata honest without disturbing it.
    const node = _findNode(path); if (node) { node.bytes = new Blob([content]).size; node.mtime = _fileMtime; }
    return true;
  } catch (e) { await alertDark('Save failed: ' + e); return false; }
}
window._filesSave = _filesSave;

// A browser-level guard: the in-panel prompts only cover switching files, not closing the tab.
addEventListener('beforeunload', e => {
  if (!_fileDirty) return;
  e.preventDefault(); e.returnValue = '';       // browsers show their own generic wording
  return '';
});

// ── resizable tree column ───────────────────────────────────────────────────
function _filesInitResize() {
  const wrap = document.querySelector('.filestree-wrap'), grip = document.getElementById('filesgrip');
  if (!wrap || !grip) return;
  const w = parseInt(localStorage.getItem(_lsKey('Width')), 10);
  if (w >= 160 && w <= 700) { wrap.style.width = w + 'px'; wrap.style.flexBasis = w + 'px'; }
  grip.addEventListener('mousedown', ev => {
    ev.preventDefault();
    const x0 = ev.clientX, w0 = wrap.getBoundingClientRect().width;
    const move = e => {
      const nw = Math.max(160, Math.min(700, w0 + (e.clientX - x0)));
      wrap.style.width = nw + 'px'; wrap.style.flexBasis = nw + 'px';
    };
    const up = () => {
      removeEventListener('mousemove', move); removeEventListener('mouseup', up);
      document.body.classList.remove('resizing');
      localStorage.setItem(_lsKey('Width'), String(Math.round(wrap.getBoundingClientRect().width)));
    };
    document.body.classList.add('resizing');
    addEventListener('mousemove', move); addEventListener('mouseup', up);
  });
}
function _filesInitPanel() {
  _filesInitResize();
  _filesSyncHiddenBtn();
  const box = document.getElementById('filestree');
  if (box) _filesDropTarget(box, '');            // drop on empty tree space → the project root
}
if (document.readyState === 'loading') addEventListener('DOMContentLoaded', _filesInitPanel);
else _filesInitPanel();

// ── Embed media into a cell (drag/drop + paste) ─────────────────────────────────────────────────────
// Called from the cell editor's drop/paste handlers (editor.js). Each dropped file is either INLINED
// as a data URL (small, or forced with Alt) or ATTACHED into the project's `assets/` dir and referenced
// by its served `/n/{id}/asset/**` URL (larger, or forced with Shift). A reference (Markdown for a
// prose cell, the raw URL for a code cell) is inserted at the drop point. A notebook with no project
// root can't attach — those drops fall back to inline.
const _EMBED_INLINE_MAX = 48 * 1024;         // ≤ this ⇒ inline by default (tiny icons, pasted snippets)
const _EMBED_INLINE_HARD_MAX = 2 * 1024 * 1024;   // never inline past this, even when forced
const _EMBED_ATTACH_MAX = 64 * 1024 * 1024;  // refuse to copy an enormous file into the project

function _readDataURL(file) {
  return new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(r.error); r.readAsDataURL(file); });
}
function _embedKind(file) {
  const t = (file.type || '').toLowerCase();
  if (t.startsWith('image/')) return 'image';
  if (t.startsWith('audio/')) return 'audio';
  if (t.startsWith('video/')) return 'video';
  const e = (String(file.name).match(/\.[^.]+$/) || [''])[0].toLowerCase();
  if (/\.(png|jpe?g|gif|webp|svg|ico|bmp|avif)$/.test(e)) return 'image';
  if (/\.(mp3|wav|ogg|oga|flac|m4a|aac|opus)$/.test(e)) return 'audio';
  if (/\.(mp4|webm|mov|m4v|ogv)$/.test(e)) return 'video';
  return 'file';
}
// Build the reference to insert, by editor syntax. `it` = {kind, url (served/data URL), rel (project-
// relative path, for @asset), name}.
function _embedSnippet(it, syntax) {
  const { kind, url, rel, name } = it;
  const alt = String(name).replace(/[\[\]\r\n]/g, '');
  if (syntax === 'julia') {                                   // @asset needs a real file (rel is always set — julia forces attach)
    const p = JSON.stringify(String(rel || '').replace(/\\/g, '/'));
    // Read known-text files as a String; everything else (images, binaries) as bytes — reading a
    // binary via `@asset` (String) would throw at run time, so `bytes` is the safe default.
    const isText = /\.(txt|text|csv|tsv|json|jsonl|xml|ya?ml|toml|ini|cfg|md|markdown|jl|py|r|html?|css|js|svg|log|tex)$/i.test(name);
    return (isText ? '@asset ' : '@asset bytes ') + p;
  }
  if (syntax === 'css') return 'url("' + url + '")';
  if (syntax === 'js') return JSON.stringify(url);
  if (syntax === 'html') {
    if (kind === 'image') return '<img src="' + url + '" alt="' + alt + '">\n';
    if (kind === 'audio') return '<audio controls src="' + url + '"></audio>\n';
    if (kind === 'video') return '<video controls src="' + url + '" style="max-width:100%"></video>\n';
    return '<a href="' + url + '">' + alt + '</a>\n';
  }
  // markdown (default)
  if (kind === 'image') return '![' + alt + '](' + url + ')\n';
  if (kind === 'audio') return '<audio controls src="' + url + '"></audio>\n';
  if (kind === 'video') return '<video controls src="' + url + '" style="max-width:100%"></video>\n';
  return '[' + alt + '](' + url + ')\n';
}
function _embedInsert(o, text) {
  const v = o.view; if (!v) return;
  const pos = (o.pos == null) ? v.state.selection.main.head : o.pos;
  v.dispatch({ changes: { from: pos, insert: text }, selection: { anchor: pos + text.length }, scrollIntoView: true });
  o.pos = pos + text.length;   // advance so multiple dropped files land in order, not reversed
  v.focus();
}

async function slateEmbedFiles(files, o) {
  const syntax = o.syntax || 'markdown';
  const mustAttach = syntax === 'julia';       // @asset references a real file — never inline into Julia code
  for (const f of Array.from(files)) {
    const kind = _embedKind(f);
    let mode = mustAttach ? 'attach' : (o.force || (f.size <= _EMBED_INLINE_MAX ? 'inline' : 'attach'));
    if (mode === 'attach' && f.size > _EMBED_ATTACH_MAX) {
      _toast(f.name + ' is too large to embed (' + _fmtBytes(f.size) + ')', 6000, 'err');
      continue;
    }
    let dataURL;
    try { dataURL = await _readDataURL(f); }
    catch (_) { _toast('Could not read ' + f.name, 4000, 'err'); continue; }
    let url = dataURL, rel = '', note = '';
    if (mode === 'attach') {
      try {
        const b64 = dataURL.slice(dataURL.indexOf(',') + 1);
        const r = await fetch(_apipath('/api/attach'), {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: f.name, contentB64: b64, subdir: 'assets' }),
        });
        if (r.ok) { const j = await r.json(); url = j.url; rel = j.path; note = 'attached → ' + j.path; }
        else if (r.status === 409) {
          // No project to attach into. Julia @asset can't work without a file — bail with a clear note.
          if (mustAttach) { _toast("Can't reference a file from code in a project-less notebook", 6500, 'err'); continue; }
          mode = 'inline'; note = 'inlined (no project to attach into)';
        } else { _toast('Attach failed: ' + (await r.text()), 5000, 'err'); continue; }
      } catch (_) {
        if (mustAttach) { _toast('Attach failed — could not save the file', 5000, 'err'); continue; }
        mode = 'inline'; note = 'inlined (attach unavailable)';
      }
    }
    if (mode === 'inline') {
      if (f.size > _EMBED_INLINE_HARD_MAX) {
        _toast(f.name + ' is too large to inline (' + _fmtBytes(f.size) + ') — open it from a project to attach', 6500, 'err');
        continue;
      }
      if (!note) note = 'inlined as data URL';
    }
    _embedInsert(o, _embedSnippet({ kind, url, rel, name: f.name }, syntax));
    _toast(_kindIcon(kind === 'file' ? 'binary' : kind) + ' ' + f.name + ' — ' + note, 3500, 'ok');
  }
  // If the file tree is loaded, a fresh attach means a new file in assets/ — refresh it.
  if (_filesTree && !_filesTree.detached) _filesLoadTree();
}
window.slateEmbedFiles = slateEmbedFiles;
