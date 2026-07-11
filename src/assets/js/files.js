// ── Files tab: browse + edit the notebook's OWN package source ─────────────────────────────────────
// Fetches the project tree (/api/tree), opens a file in a standalone CM6 editor (window.mkFileEditor),
// and ⌘S / Save writes it back (POST /api/file). A save just hits disk — the worker's Revise
// hot-reload watcher reloads it like any external edit and restales the cells that use it (the memo
// `_src_digest` makes that precise); we deliberately do NOT rerun from here.
let _filesTree = null, _fileView = null, _fileOpen = null, _fileDirty = false;

function toggleFiles() {
  const p = document.getElementById('filespanel');
  const opening = !p.classList.contains('open');
  p.classList.toggle('open');
  if (opening && _filesTree === null) _filesLoadTree();
  else if (opening && _fileView) setTimeout(() => _fileView.focus(), 0);
}
window.toggleFiles = toggleFiles;

async function _filesLoadTree() {
  const box = document.getElementById('filestree');
  box.textContent = ''; box.appendChild(_hintEl('loading…'));
  try {
    _filesTree = await (await fetch(_apipath('/api/tree'))).json();
  } catch (_) { box.textContent = ''; box.appendChild(_hintEl('failed to load the project tree')); _filesTree = null; return; }
  const rootEl = document.getElementById('filesroot');
  if (_filesTree.detached || !(_filesTree.tree || []).length) {
    if (rootEl) rootEl.textContent = '';
    box.textContent = ''; box.appendChild(_hintEl('no editable project source (in-process notebook)'));
    return;
  }
  if (rootEl) rootEl.textContent = _filesTree.name || '';
  box.textContent = '';
  box.appendChild(_filesRenderNodes(_filesTree.tree, 0));
}
function _hintEl(t) { const d = document.createElement('div'); d.className = 'hint'; d.style.padding = '8px'; d.textContent = t; return d; }

// Recursive tree: collapsible dirs (collapsed by default except the first level), clickable files.
function _filesRenderNodes(nodes, depth) {
  const frag = document.createDocumentFragment();
  for (const n of nodes) {
    if (n.dir) {
      const wrap = document.createElement('div');
      const hdr = document.createElement('div');
      hdr.className = 'ftrow ftdir';
      hdr.style.paddingLeft = (6 + depth * 13) + 'px';
      const tw = document.createElement('span'); tw.className = 'fttw'; tw.textContent = '▸';
      hdr.appendChild(tw); hdr.appendChild(document.createTextNode('📁 ' + n.name));
      const kids = document.createElement('div'); kids.className = 'ftkids';
      kids.appendChild(_filesRenderNodes(n.children || [], depth + 1));
      const open = depth === 0;                       // top-level dirs (src/, notebooks/, …) start open
      kids.style.display = open ? '' : 'none'; tw.textContent = open ? '▾' : '▸';
      hdr.onclick = () => { const show = kids.style.display === 'none'; kids.style.display = show ? '' : 'none'; tw.textContent = show ? '▾' : '▸'; };
      wrap.appendChild(hdr); wrap.appendChild(kids); frag.appendChild(wrap);
    } else {
      const f = document.createElement('div');
      f.className = 'ftrow ftfile';
      f.style.paddingLeft = (6 + depth * 13 + 14) + 'px';
      f.textContent = n.name; f.dataset.path = n.path;
      f.onclick = () => _filesOpen(n.path, f);
      frag.appendChild(f);
    }
  }
  return frag;
}

async function _filesOpen(path, el) {
  if (_fileDirty && !window.confirm('Discard unsaved changes to ' + _fileOpen + '?')) return;
  try {
    const r = await fetch(_apipath('/api/file?path=' + encodeURIComponent(path)));
    if (!r.ok) { await alertDark('Could not open ' + path + ':\n' + (await r.text())); return; }
    const j = await r.json();
    _filesMount(path, j.content);
    document.querySelectorAll('#filestree .ftfile.sel').forEach(x => x.classList.remove('sel'));
    if (el) el.classList.add('sel');
  } catch (e) { await alertDark('Open failed: ' + e); }
}

function _filesMount(path, content) {
  const host = document.getElementById('fileedit');
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  host.textContent = '';
  _fileOpen = path; _fileDirty = false;
  const pe = document.getElementById('filepath'); if (pe) { pe.textContent = path; pe.classList.remove('hint'); }
  _filesSyncDirty();
  _fileView = window.mkFileEditor(host, content, {
    filename: path,
    onSave: _filesSave,
    onChange: () => { if (!_fileDirty) { _fileDirty = true; _filesSyncDirty(); } },
  });
  setTimeout(() => { try { _fileView.focus(); } catch (_) {} }, 0);
}

function _filesSyncDirty() {
  const b = document.getElementById('filesave');
  if (b) { b.disabled = !_fileOpen || !_fileDirty; b.textContent = _fileDirty ? 'Save ⌘S' : 'Saved'; }
  const dot = document.getElementById('filedirty'); if (dot) dot.style.visibility = _fileDirty ? 'visible' : 'hidden';
}

async function _filesSave() {
  if (!_fileOpen || !_fileView) return;
  const content = _fileView.state.doc.toString();
  try {
    const r = await fetch(_apipath('/api/file'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: _fileOpen, content }),
    });
    if (!r.ok) { await alertDark('Save failed:\n' + (await r.text())); return; }
    _fileDirty = false; _filesSyncDirty();
    if (window.showLoading) { showLoading('Saved ' + _fileOpen + ' — Revise will reload it ✓'); setTimeout(hideLoading, 950); }
  } catch (e) { await alertDark('Save failed: ' + e); }
}
window._filesSave = _filesSave;
