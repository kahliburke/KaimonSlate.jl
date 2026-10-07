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

// The live install status from the worker log: the last few lines of Pkg's own output. Precompilation
// prints a "✓ <pkg>" line as EACH package finishes (there's no in-progress line in a non-TTY log), so
// a tail advances package-by-package instead of sitting on "Precompiling packages…".
//
// Lines keep their ANSI, because the caller colours them — Pkg writes SGR into the log, and the
// package names and counts are the part that is coloured. Matching and trimming run against the
// ESCAPE-STRIPPED text: a `[32m` between the ✓ and the name defeats the pattern otherwise, and
// nothing here truncates, so there is no way to cut a line mid-sequence and leave a dangling escape.
// Width is the card's problem, handled in CSS.
const _PKG_LOG_LINES = 4;
// Margin whitespace and box-drawing, trimmed from both ends while STEPPING OVER the colour runs. Pkg
// opens the colour before its indent (`ESC[32m  ✓ ESC[39mExample`), so a plain anchored trim sees the
// escape first and leaves the indentation behind it — every line would sit ragged in a left-aligned
// box. The escapes are kept exactly where they are, since each one colours the text that follows it.
const _SGR_RUN = '(?:\\x1b\\[[0-9;:]*m)*';
const _PKG_LEAD = new RegExp('^(' + _SGR_RUN + ')[\\s│]+');
const _PKG_TAIL = new RegExp('[\\s│]+(' + _SGR_RUN + ')$');
function _trimPkgMargin(s) {
  let prev;
  do { prev = s; s = s.replace(_PKG_LEAD, '$1').replace(_PKG_TAIL, '$1'); } while (s !== prev);
  return s;
}
function _lastPkgLines(log, n) {
  n = n || _PKG_LOG_LINES;
  if (!log) return [];
  const plain = s => (window.slateAnsiText ? window.slateAnsiText(s) : s);
  const lines = String(log).split('\n')
    .map(s => _trimPkgMargin(s))
    .map(raw => ({ raw, text: plain(raw) }))
    .filter(l => l.text);
  if (!lines.length) return [];
  // Pkg activity only, so unrelated worker chatter cannot crowd the install out of a short window.
  const pat = /[✓√]|Precompil|Resolv|Installed|Download|Updating|Building|Added|No Changes|Cloning|Compiling/i;
  const hits = lines.filter(l => pat.test(l.text));
  return (hits.length ? hits : lines).slice(-n).map(l => l.raw);
}

// Install the missing package — into the NOTEBOOK's own env (reproducible; travels to a remote worker
// via the Manifest) or the shared PARENT PROJECT — then re-run so the `using` lights up. Streams live
// install status by tailing the worker log while the (blocking) add runs.
function hidePkgInstalling() { const bg = document.getElementById('pkginstallbg'); if (bg) bg.classList.remove('show'); }
window.hidePkgInstalling = hidePkgInstalling;
// SGR → spans, escaping as it goes. Falls back to escaped text so a missing ansi.js degrades to
// readable output rather than markup. `slateEscHtml` is esc.js's, which ansi.js itself uses: this
// must not grow its own escaper (see test/js/esc_html.mjs).
const _ansi = s => (window.slateAnsiHtml ? window.slateAnsiHtml(s) : window.slateEscHtml(String(s == null ? '' : s)));
// Show a package-install failure IN the blocking modal (leaves it up with a Close button). Pkg's
// message carries its own colour, and `<`/`>` appear in real ones (a version bound, a type in a
// stacktrace), so it is escaped rather than having those characters deleted from it.
function _pkgInstallFail(msg) {
  const st = document.getElementById('pkginstallstatus'), sp = document.getElementById('pkginstallspin'),
        ac = document.getElementById('pkginstallactions');
  if (st) { st.innerHTML = '⚠ ' + _ansi(String(msg == null ? '?' : msg)); st.style.color = 'var(--red)'; st.classList.add('failed'); }
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
  // `failed` is cleared, not just overwritten: a retry after a failure would otherwise keep the
  // wrapping, auto-height layout that message needed.
  if (st) { st.innerHTML = '<div class="pkgline">resolving…</div>'; st.style.color = 'var(--accent)'; st.classList.remove('failed'); }
  if (sp) sp.style.display = '';
  if (ac) { ac.style.display = 'none'; ac.innerHTML = ''; }
  bg.classList.add('show');
  let live = true;
  // THIS install's output only. The worker log is cumulative, so whatever is in it when the modal
  // opens belongs to earlier work and would otherwise be presented as install progress. The baseline
  // is taken on the first poll (rather than before the modal opens, which would make this function
  // async and change its contract) and lands on a line boundary, so a line still being written is
  // treated as new rather than shown from its middle. A log shorter than the baseline has rotated,
  // and then all of it is new.
  let base = null;
  (async () => { while (live) {
    try {
      const r = await api('GET', '/api/worker-log');
      const log = String((r && r.log) || '');
      if (base === null) base = log.lastIndexOf('\n') + 1;
      else if (log.length < base) base = 0;
      const ls = _lastPkgLines(log.slice(base));
      if (ls.length && live && st) st.innerHTML = ls.map(l => '<div class="pkgline">' + _ansi(l) + '</div>').join('');
    } catch (_) {}
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
