// ── Destinations (per-cell run regions) ─────────────────────────────────────────────────────────
// A "destination" is a named region from the GLOBAL registry (defined in the home-page Regions
// manager) that THIS notebook uses (its `regions` footer list). Cells tagged `region=<name>` execute
// on that region's worker; boundary values cross automatically as content-addressed blobs. This module
// provides the per-cell "Run on" picker (🏷 tag editor) and the notebook-level Destinations manager
// (enable/disable a region for this notebook). The DAG zones reuse it too.

function _nbRegions() { return (typeof nbState !== 'undefined' && nbState && nbState.regions) || []; }

// A cell's ASSIGNED region from its tags ('' = local/main). The *plan*, not where it ran — the DAG's
// `_dagCellRegion` prefers stats.ranOn for provenance; here we only read the tags.
function cellAssignedRegion(c) {
  const tags = (c && c.tags) || [];
  for (const t of tags) if (t.startsWith('region=')) return t.slice(7);
  return '';
}

// Persist which regions this notebook uses (comma-separated NAMES → the `regions` footer). `api()`'s
// _apipath rewrites this to /api/<nb>/regions (per-notebook), distinct from the global /api/regions.
async function _postRegions(names) { renderAll(await api('POST', '/api/regions', { regions: names.join(',') })); }

// Enable a global region for this notebook (add its name to the footer list) / disable it.
async function enableDestination(name) {
  const names = _nbRegions().map(r => r.name);
  if (names.indexOf(name) < 0) names.push(name);
  await _postRegions(names);
}
async function removeDestination(name) {
  await _postRegions(_nbRegions().map(r => r.name).filter(n => n !== name));
}

// Set a cell's region ('' = local/main): drop any region tag, add the new one.
async function setCellRegion(id, name) {
  const cur = _curTags(id).filter(t => t !== 'remote' && !t.startsWith('region='));
  await setTags(id, name ? [...cur, 'region=' + name] : cur);
}

// ── "Run on" section for the 🏷 tag editor ───────────────────────────────────────────────────────
// local + every region this notebook uses as a radio, plus a link to manage destinations. renderTagPop
// injects runOnSectionHtml(id) and calls wireRunOnSection(pop, id).
function runOnSectionHtml(id) {
  const cur = cellAssignedRegion(_cellById(id));
  const opt = (val, label, sub) =>
    `<label class="ctlrow"><input type="radio" name="runon-${id}" value="${_escc(val)}"${cur === val ? ' checked' : ''}>` +
    `<span>${_escc(label)}${sub ? `<span class="tagdesc">${_escc(sub)}</span>` : ''}</span></label>`;
  let rows = opt('', '💻 local', 'main kernel · this machine');
  rows += _nbRegions().map(r => opt(r.name, '🖧 ' + r.name,
    (r.host || '') + (r.transport === 'direct' ? ' · direct' : '') + (r.defined === false ? ' · ⚠ not in registry' : ''))).join('');
  // A cell tagged with a region NOT in the notebook's list still shows (selected) so it isn't lost.
  if (cur && !_nbRegions().some(r => r.name === cur)) rows += opt(cur, '🖧 ' + cur, 'tagged (not enabled)');
  return '<div class="ctlhead">Run on</div>' + rows +
    '<div class="tagadd"><a href="#" class="destadd" title="manage this notebook\'s run destinations">＋ Add destination…</a></div>';
}
function wireRunOnSection(pop, id) {
  pop.querySelectorAll(`input[name="runon-${id}"]`).forEach(rb => rb.onchange = () => setCellRegion(id, rb.value));
  const a = pop.querySelector('.destadd');
  if (a) a.onclick = e => { e.preventDefault(); openDestinations(); };
}

// ── Destinations manager modal ───────────────────────────────────────────────────────────────────
// Enable/disable GLOBAL regions (defined in the home-page Regions manager) for this notebook — no host
// or transport is entered here; regions carry their own config. `_destRegions` = the global registry.
let _destRegions = [];
function _destRegionByName(n) { return _destRegions.find(r => r.name === n) || null; }

function openDestinations() {
  document.getElementById('destbg').classList.add('show');
  renderDestinations();
  _destLoad();
}
function closeDestinations() { document.getElementById('destbg').classList.remove('show'); }

function renderDestinations() {
  const cur = _nbRegions(), used = new Set(cur.map(r => r.name));
  const el = document.getElementById('destlist');
  if (el) {
    el.innerHTML = cur.length
      ? '<div class="ctlsub">Enabled for this notebook</div>' + cur.map(r => {
          const g = _destRegionByName(r.name);
          const badge = g && g.warm > 0 ? `<span class="destwarm" title="warm workers ready to adopt">${g.warm} warm</span>` : '';
          const where = _escc(r.host || '(no host)') + (r.transport === 'direct' ? ' · direct' : '') +
            (r.root ? ' · root ' + _escc(r.root) : '') + (r.defined === false ? ' · ⚠ not in registry' : '');
          return `<div class="destitem"><div class="destinfo"><b>🖧 ${_escc(r.name)}</b> <span class="desthost">${where}</span>${badge}</div>` +
            `<button class="destdel" data-n="${_escc(r.name)}" title="disable this region for this notebook">✕</button></div>`;
        }).join('')
      : '<div class="destempty">No regions enabled yet — pick one below, then tag cells to it (🏷 → Run on) or drag them into its DAG zone.</div>';
    el.querySelectorAll('.destdel').forEach(b => b.onclick = () => removeDestination(b.dataset.n));
  }
  const av = document.getElementById('destavail');
  if (av) {
    const avail = _destRegions.filter(r => !used.has(r.name));
    av.innerHTML = '<div class="ctlsub">Regions (defined on the home page)</div>' +
      (avail.length ? avail.map(r => {
        const meta = [r.host, r.transport, r.warm > 0 ? `${r.warm} warm` : '', r.data_root ? `root ${r.data_root}` : '']
          .filter(Boolean).join(' · ');
        return `<div class="destitem"><div class="destinfo"><b>${_escc(r.name)}</b> <span class="destsrc">${_escc(meta)}</span></div>` +
          `<button class="desten" data-n="${_escc(r.name)}" title="use this region in this notebook">Enable →</button></div>`;
      }).join('') : '<div class="destempty">No regions defined yet — create one on the home page (🖧 Remotes → Regions ›).</div>');
    av.querySelectorAll('.desten').forEach(b => b.onclick = () => enableDestination(b.dataset.n));
  }
  const hint = document.getElementById('desthint');
  if (hint) hint.innerHTML = _destRegions.some(r => r.warm > 0)
    ? '💡 A region with warm workers adopts one instantly — no ~90s cold boot.'
    : '💡 Give a region a warm count on the home page (🖧 Remotes → Regions ›) so it adopts instantly.';
}

// Load the global region registry, then render (warm counts + availability need it).
async function _destLoad() {
  try { const d = await (await fetch('/api/regions')).json(); _destRegions = (d && d.regions) || []; }
  catch (_) { _destRegions = []; }
  renderDestinations();
}

// Backdrop / Esc close (mirrors the run-location modal).
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'destbg') closeDestinations(); });
document.addEventListener('keydown', e => {
  const bg = document.getElementById('destbg');
  if (e.key === 'Escape' && bg && bg.classList.contains('show')) { e.stopPropagation(); closeDestinations(); }
}, true);
