// ── Files tab: browse + edit + preview the notebook's OWN project files ─────────────────────────────
// Fetches the project tree (/api/tree). A click routes on the node's `kind`:
//   text            → open in a standalone CM6 editor (window.mkFileEditor); ⌘S / Save writes it back
//                     (POST /api/file). A save just hits disk — the worker's Revise hot-reload watcher
//                     reloads it and restales the cells that use it (memo `_src_digest` makes that
//                     precise); we deliberately do NOT rerun from here.
//   image/audio/video → preview inline via the raw `/n/{id}/asset/**` byte route (no base64-in-JSON).
//   binary          → a guarded info card (size + Download + "open as text anyway").
// "＋ New" creates a file (POST /api/file {create:true}); Download links the asset route.
let _filesTree = null, _fileView = null, _fileOpen = null, _fileDirty = false;

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
  const newBtn = document.getElementById('filesnew');
  const detached = _filesTree.detached || !(_filesTree.tree || []).length;
  if (newBtn) newBtn.disabled = !!_filesTree.detached;
  if (detached) {
    if (rootEl) rootEl.textContent = '';
    box.textContent = ''; box.appendChild(_hintEl('no editable project source (in-process notebook)'));
    return;
  }
  if (rootEl) rootEl.textContent = _filesTree.name || '';
  box.textContent = '';
  box.appendChild(_filesRenderNodes(_filesTree.tree, 0));
}
window._filesLoadTree = _filesLoadTree;
function _hintEl(t) { const d = document.createElement('div'); d.className = 'hint'; d.style.padding = '8px'; d.textContent = t; return d; }

// Recursive tree: collapsible dirs (top level open), clickable files tagged with a kind icon + size.
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
      f.style.paddingLeft = (6 + depth * 13 + 4) + 'px';
      const ico = document.createElement('span'); ico.className = 'ftico'; ico.textContent = _kindIcon(n.kind);
      f.appendChild(ico); f.appendChild(document.createTextNode(' ' + n.name));
      if (n.bytes) { const s = document.createElement('span'); s.className = 'ftsize'; s.textContent = _fmtBytes(n.bytes); f.appendChild(s); }
      f.dataset.path = n.path; f.dataset.kind = n.kind || 'text';
      f.onclick = () => _filesOpen(n.path, n.kind || 'text', f);
      frag.appendChild(f);
    }
  }
  return frag;
}

// Open a node by kind: text → editor, media → preview, binary → info card. `forceText` (from the
// card's "open as text" button) re-fetches with `?as=text` regardless of the file's classified kind.
async function _filesOpen(path, kind, el, forceText) {
  if (_fileDirty && !window.confirm('Discard unsaved changes to ' + _fileOpen + '?')) return;
  document.querySelectorAll('#filestree .ftfile.sel').forEach(x => x.classList.remove('sel'));
  if (el) el.classList.add('sel');
  const effective = forceText ? 'text' : kind;
  if (effective === 'text') {
    try {
      const r = await fetch(_apipath('/api/file?path=' + encodeURIComponent(path) + (forceText ? '&as=text' : '')));
      if (!r.ok) { await alertDark('Could not open ' + path + ':\n' + (await r.text())); return; }
      const j = await r.json();
      _filesMount(path, j.content);
    } catch (e) { await alertDark('Open failed: ' + e); }
  } else {
    _filesPreview(path, kind);
  }
}

// ── text editor mode ────────────────────────────────────────────────────────
function _filesShowEditor() {
  document.getElementById('fileedit').style.display = '';
  const pv = document.getElementById('filepreview'); pv.style.display = 'none'; pv.textContent = '';
}
function _filesMount(path, content) {
  _filesShowEditor();
  const host = document.getElementById('fileedit');
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  host.textContent = '';
  _fileOpen = path; _fileDirty = false;
  _filesSetPath(path);
  _filesSetDownload(path);
  _filesSyncDirty();
  _fileView = window.mkFileEditor(host, content, {
    filename: path,
    onSave: _filesSave,
    onChange: () => { if (!_fileDirty) { _fileDirty = true; _filesSyncDirty(); } },
  });
  setTimeout(() => { try { _fileView.focus(); } catch (_) {} }, 0);
}

// ── media / binary preview mode ─────────────────────────────────────────────
function _filesPreview(path, kind) {
  if (_fileView) { try { _fileView.destroy(); } catch (_) {} _fileView = null; }
  _fileOpen = null; _fileDirty = false; _filesSyncDirty();
  _filesSetPath(path);
  _filesSetDownload(path);
  document.getElementById('fileedit').style.display = 'none';
  const pv = document.getElementById('filepreview');
  pv.style.display = ''; pv.textContent = '';
  const url = _assetURL(path);

  if (kind === 'image') {
    const img = document.createElement('img'); img.src = url; img.alt = path;
    const meta = document.createElement('div'); meta.className = 'fpmeta'; meta.textContent = path.split(/[\\/]/).pop();
    img.onload = () => { meta.textContent = img.naturalWidth + '×' + img.naturalHeight + ' · ' + path.split(/[\\/]/).pop(); };
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
    const nm = document.createElement('div'); nm.style.margin = '6px 0'; nm.style.color = 'var(--text)'; nm.textContent = path.split(/[\\/]/).pop();
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
  dl.download = path.split(/[\\/]/).pop(); dl.textContent = '⭳ Download';
  row.appendChild(dl);
  if (offerText) {
    const t = document.createElement('button'); t.className = 'ftbtn'; t.textContent = '≡ Open as text';
    const el = document.querySelector('#filestree .ftfile.sel');
    t.onclick = () => _filesOpen(path, kind, el, /*forceText=*/ true);
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
  dl.href = _assetURL(path); dl.download = path.split(/[\\/]/).pop(); dl.style.display = '';
}
function _filesSyncDirty() {
  const b = document.getElementById('filesave');
  if (b) { b.disabled = !_fileOpen || !_fileDirty; b.textContent = _fileDirty ? 'Save ⌘S' : 'Saved';
    b.style.display = _fileOpen ? '' : 'none'; }        // Save is meaningless in preview mode
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

// Create a new empty file at a project-relative path, then open it in the editor.
async function _filesNewFile() {
  if (!_filesTree || _filesTree.detached) return;
  const rel = window.prompt('New file (path relative to ' + (_filesTree.name || 'project') + '):', 'assets/');
  if (!rel || !rel.trim() || rel.trim().endsWith('/')) return;
  const path = rel.trim();
  try {
    const r = await fetch(_apipath('/api/file'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path, content: '', create: true }),
    });
    if (!r.ok) { await alertDark('Could not create ' + path + ':\n' + (await r.text())); return; }
    await _filesLoadTree();
    _filesMount(path, '');
  } catch (e) { await alertDark('Create failed: ' + e); }
}
window._filesNewFile = _filesNewFile;

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
      window.toast && toast(f.name + ' is too large to embed (' + _fmtBytes(f.size) + ')', 6000, 'err');
      continue;
    }
    let dataURL;
    try { dataURL = await _readDataURL(f); }
    catch (_) { window.toast && toast('Could not read ' + f.name, 4000, 'err'); continue; }
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
          if (mustAttach) { window.toast && toast("Can't reference a file from code in a project-less notebook", 6500, 'err'); continue; }
          mode = 'inline'; note = 'inlined (no project to attach into)';
        } else { window.toast && toast('Attach failed: ' + (await r.text()), 5000, 'err'); continue; }
      } catch (_) {
        if (mustAttach) { window.toast && toast('Attach failed — could not save the file', 5000, 'err'); continue; }
        mode = 'inline'; note = 'inlined (attach unavailable)';
      }
    }
    if (mode === 'inline') {
      if (f.size > _EMBED_INLINE_HARD_MAX) {
        window.toast && toast(f.name + ' is too large to inline (' + _fmtBytes(f.size) + ') — open it from a project to attach', 6500, 'err');
        continue;
      }
      if (!note) note = 'inlined as data URL';
    }
    _embedInsert(o, _embedSnippet({ kind, url, rel, name: f.name }, syntax));
    window.toast && toast(_kindIcon(kind === 'file' ? 'binary' : kind) + ' ' + f.name + ' — ' + note, 3500, 'ok');
  }
  // If the file tree is loaded, a fresh attach means a new file in assets/ — refresh it.
  if (_filesTree && !_filesTree.detached) _filesLoadTree();
}
window.slateEmbedFiles = slateEmbedFiles;
