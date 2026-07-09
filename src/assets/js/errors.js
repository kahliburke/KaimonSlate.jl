// ── Error line: highlight the offending source line + click-to-jump ───────────
// A cell that errored carries `errorLine` (1-based) — the `string:N` from the backtrace, i.e. the
// cell's OWN source line. We tint that line in the editor, and a click on the error message scrolls
// to and flashes it. Plain code cells have an always-on editor (window.editors[id]); @bind cells
// don't, so for those a click just scrolls to the cell.

// Called from the cell render effect (notebook.js) after output swaps in. Marks two lines via CM6
// line decorations (editor.js): the ORIGIN — the actual offending line, possibly in another cell —
// gets the brighter `cm-errorline-origin`; the call site in THIS cell (when distinct) gets the faint
// `cm-errorline`. The origin is read from the rendered error message (`.errjump` carries the origin
// cell id + line — see render.jl). Both persist regardless of navigation/edit (CM6 maps them) and
// clear when the cell re-runs clean. `_originMarks` lets a cell clear the origin mark it owns.
const _originMarks = {};   // erroredCellId -> origin cellId it currently marks
function _applyErrorLine(c) {
  if (!c || !window.editors[c.id]) return;
  const cellEl = document.querySelector('.cell[data-cid="' + c.id + '"]');
  const ej = cellEl && cellEl.querySelector('.errjump');
  const oCid = ej && ej.dataset.cid, oLine = ej && parseInt(ej.dataset.line, 10);
  const prev = _originMarks[c.id];
  if (prev && prev !== oCid) { window.clearOriginLine(prev); delete _originMarks[c.id]; }   // origin moved/cleared
  if (c.errorLine && oCid && oLine && window.editors[oCid]) {
    window.markOriginLine(oCid, oLine);                                    // bright: the actual offending line
    _originMarks[c.id] = oCid;
    (oCid !== c.id || oLine !== c.errorLine)                              // faint call site only when distinct
      ? window.markErrorLine(c.id, c.errorLine) : window.clearErrorLine(c.id);
  } else if (c.errorLine) {
    window.markErrorLine(c.id, c.errorLine);                              // no origin info → faint own line
  } else {
    window.clearErrorLine(c.id);
    if (prev) { window.clearOriginLine(prev); delete _originMarks[c.id]; }
  }
}
window._applyErrorLine = _applyErrorLine;

// Put the cell into edit mode with the cursor on `line1` (1-based) and flash it: select the cell,
// enter edit (focuses the code editor / opens the source editor for a @bind/md cell), then flash
// the line in the now-mounted editor (editor.js::flashLine focuses + scrolls + flashes).
function jumpToCellLine(cellId, line1) {
  if (typeof selectCell === 'function') selectCell(cellId, true);
  if (typeof enterEdit === 'function') enterEdit(cellId);
  requestAnimationFrame(() => { if (window.editors[cellId]) window.flashLine(cellId, line1); });
}
window.jumpToCellLine = jumpToCellLine;

// ── Missing-package interceptor (additive; never touches the error rendering above) ──────────────
// When a cell errors because a package isn't installed, Julia says "Package X not found in current
// path". We scan the ALREADY-RENDERED output text for that (so it catches every case — static and
// dynamic `using`, local or remote worker) and inject a one-click install banner. Purely a DOM add +
// a POST; if the pattern isn't there we just remove any stale banner.
const _MISSING_PKG_RE = /Package\s+([A-Za-z_][A-Za-z0-9_]*)\s+not found in current path/;
function _applyMissingPkg(c) {
  const cellEl = c && document.querySelector('.cell[data-cid="' + c.id + '"]');
  if (!cellEl) return;
  const out = cellEl.querySelector('.output');
  const existing = cellEl.querySelector(':scope > .pkgmissing');   // banner is a DIRECT child of the cell
  const m = out ? (out.textContent || '').match(_MISSING_PKG_RE) : null;
  if (!m) { if (existing) existing.remove(); return; }        // cell no longer missing a package
  const pkg = m[1];
  if (existing && existing.dataset.pkg === pkg) return;       // already showing for this package
  if (existing) existing.remove();
  // When the notebook lives in a project, offer BOTH: its own env (private, reproducible) or the shared
  // parent project. Detached notebooks (no project) only get "Add to notebook".
  const parented = !!(typeof nbState !== 'undefined' && nbState && nbState.project);
  const b = document.createElement('div');
  b.className = 'pkgmissing'; b.dataset.pkg = pkg;
  b.innerHTML = '<span class="pmicon">\u{1F4E6}</span><span class="pmtext"><b>' + pkg +
    '</b> isn’t in this notebook’s environment.</span>' +
    '<button class="pmadd" onclick="installMissingPkg(\'' + pkg + '\',\'notebook\')" title="add to this notebook only">Add to notebook</button>' +
    (parented ? '<button class="pmadd alt" onclick="installMissingPkg(\'' + pkg + '\',\'project\')" title="add to the shared parent project">Add to project</button>' : '');
  cellEl.insertBefore(b, cellEl.firstChild);   // top of the cell, above the header/editor
  // Surface the version the notebook was likely using (from your global env) + pin to it, so we don't
  // silently install a newer version that could break the notebook.
  api('GET', '/api/pkg-info?name=' + encodeURIComponent(pkg)).then(r => {
    const v = r && r.globalVersion, cur = cellEl.querySelector(':scope > .pkgmissing[data-pkg="' + pkg + '"]');
    if (!v || !cur) return;
    cur.dataset.ver = v;
    const t = cur.querySelector('.pmtext');
    if (t) t.innerHTML = '<b>' + pkg + '</b> isn’t in this notebook’s environment <span class="pmstat">(your env has v' + v + ')</span>';
  }).catch(() => {});
}
window._applyMissingPkg = _applyMissingPkg;

// The live install status from the worker log. Precompilation prints a "✓ <pkg>" line as EACH package
// finishes (there's no in-progress line in a non-TTY log), so we surface the most-recently-completed
// package — the status then advances package-by-package instead of sitting on "Precompiling packages…".
// Falls back to the latest Resolving/Installed/… line before precompilation begins.
function _lastPkgLine(log) {
  if (!log) return '';
  const lines = String(log).split('\n').map(s => s.replace(/[\s│]+$/, '').replace(/^[\s│]+/, '')).filter(Boolean);
  if (!lines.length) return '';
  for (let i = lines.length - 1; i >= 0; i--) {              // most recent completed package
    const m = lines[i].match(/[✓√]\s+(\S[^│]*)$/);
    if (m) return 'compiled ' + m[1].trim().slice(0, 60);
  }
  const pat = /(Precompil|Resolv|Installed|Download|Updating|Building|Added|No Changes|Cloning|Compiling)/i;
  for (let i = lines.length - 1; i >= 0; i--) if (pat.test(lines[i])) return lines[i].slice(0, 90);
  return lines[lines.length - 1].slice(0, 90);
}

// Install the missing package — into the NOTEBOOK's own env (reproducible; travels to a remote worker
// via the Manifest) or the shared PARENT PROJECT — then re-run so the `using` lights up. Streams live
// install status by tailing the worker log while the (blocking) add runs.
function hidePkgInstalling() { const bg = document.getElementById('pkginstallbg'); if (bg) bg.classList.remove('show'); }
window.hidePkgInstalling = hidePkgInstalling;
// Show a package-install failure IN the blocking modal (leaves it up with a Close button).
function _pkgInstallFail(msg) {
  const st = document.getElementById('pkginstallstatus'), sp = document.getElementById('pkginstallspin'),
        ac = document.getElementById('pkginstallactions');
  if (st) { st.innerHTML = '⚠ ' + String(msg || '?').replace(/[<>&]/g, ''); st.style.color = 'var(--red)'; }
  if (sp) sp.style.display = 'none';
  if (ac) { ac.style.display = 'flex'; ac.innerHTML = '<button onclick="hidePkgInstalling()">Close</button>'; }
}
window._pkgInstallFail = _pkgInstallFail;
// Raise the blocking install modal (notebook is frozen while the worker resolves/precompiles) and stream
// live status from the worker log. Returns a stop() that ends the polling. Shared by both add paths.
function startPkgInstall(titleHtml) {
  const bg = document.getElementById('pkginstallbg'), st = document.getElementById('pkginstallstatus'),
        sp = document.getElementById('pkginstallspin'), ac = document.getElementById('pkginstallactions');
  if (!bg) return () => {};
  document.getElementById('pkginstalltitle').innerHTML = titleHtml;
  if (st) { st.textContent = 'resolving…'; st.style.color = 'var(--accent)'; }
  if (sp) sp.style.display = '';
  if (ac) { ac.style.display = 'none'; ac.innerHTML = ''; }
  bg.classList.add('show');
  let live = true;
  (async () => { while (live) {
    try { const r = await api('GET', '/api/worker-log'); const l = _lastPkgLine(r && r.log); if (l && live && st) st.textContent = l; } catch (_) {}
    await new Promise(res => setTimeout(res, 1500));
  } })();
  return () => { live = false; };
}
window.startPkgInstall = startPkgInstall;

async function installMissingPkg(pkg, target) {
  const b = document.querySelector('.pkgmissing[data-pkg="' + pkg + '"]');
  const where = target === 'project' ? 'project' : 'notebook';
  const ver = b && b.dataset.ver;                            // pin to the version your global env had (if known)
  const spec = ver ? (pkg + '@' + ver) : pkg;
  const stop = startPkgInstall('Installing <b>' + pkg + '</b>' + (ver ? ' v' + ver : '') + ' → ' + where);
  try {
    const r = await api('POST', '/api/package', { op: 'add', name: spec, target: where });
    stop();
    if (r && r.ok === false) { _pkgInstallFail(r.message); return; }
    hidePkgInstalling();
    if (b) b.remove();
    if (typeof runAll === 'function') runAll();               // re-run stale cells → the using resolves
  } catch (_) { stop(); _pkgInstallFail('Install failed.'); }
}
window.installMissingPkg = installMissingPkg;

// Click the error message (`.errjump`) or a backtrace frame (`.cellref`) → jump to the offending
// line. A `cell:<id>:N` frame carries its OWN `data-cid` → jump to THAT cell (cross-cell: a function
// defined elsewhere); otherwise fall back to the cell containing the error. (Real `path.jl:line`
// links keep their VS Code `.srcref` behavior.)
document.addEventListener('click', e => {
  if (!e.target.closest) return;
  const ref = e.target.closest('.cellref, .errjump');
  if (!ref) return;
  e.preventDefault();
  const line = parseInt(ref.dataset.line, 10);
  const cell = ref.closest('.cell');
  const cid = ref.dataset.cid || (cell && cell.dataset && cell.dataset.cid);
  if (cid && line) jumpToCellLine(cid, line);
});
