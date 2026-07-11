// ── Destinations (per-cell run regions) ─────────────────────────────────────────────────────────
// A "destination" is a named region declared in the notebook footer (`regionon`). Cells tagged
// `region=<name>` — or the bare `remote` tag, which is sugar for the `default` region — execute on
// a SECOND kernel on that host; boundary values cross automatically as content-addressed blobs.
// This module provides the per-cell "Run on" picker (surfaced in the 🏷 tag editor) and the
// notebook-level Destinations manager (declare / remove a region, ideally pointed at a warm pool
// so the region ADOPTS a ready worker instead of paying a cold boot). The DAG zones reuse it too.

function _nbRegions() { return (typeof nbState !== 'undefined' && nbState && nbState.regions) || []; }

// A cell's ASSIGNED region from its tags ('' = local/main). This is the *plan*, not where it ran —
// the DAG's `_dagCellRegion` prefers stats.ranOn for provenance; here we only read the tags.
function cellAssignedRegion(c) {
  const tags = (c && c.tags) || [];
  for (const t of tags) if (t.startsWith('region=')) return t.slice(7);
  return tags.includes('remote') ? 'default' : '';
}

// Assemble the `regionon` footer spec from a destination list. A lone `default` writes the bare
// "host[,…]" grammar; anything else writes the named form "name:spec;name2:spec2".
function _regionSpecStr(list) {
  if (!list.length) return '';
  if (list.length === 1 && list[0].name === 'default') return list[0].spec;
  return list.map(r => r.name + ':' + r.spec).join(';');
}
async function _postRegions(spec) { renderAll(await api('POST', '/api/regions', { spec })); }

// Enable a configured host/pool as a destination: pick a region name (first one → `default` so the
// bare `remote` tag works; later ones → the host name, uniquified) and persist. `spec` carries the
// host's transport/ports as configured on the home page, so a pool destination adopts a warm worker.
async function enableDestination(host, spec) {
  if (!spec) return;
  const existing = _nbRegions();
  const used = new Set(existing.map(r => r.name));
  let name = used.has('default') ? host.replace(/[^A-Za-z0-9_]/g, '_') : 'default';
  let base = name, i = 2; while (used.has(name)) { name = base + '_' + i; i++; }
  const list = existing.map(r => ({ name: r.name, spec: r.spec }));
  list.push({ name, spec });
  await _postRegions(_regionSpecStr(list));
}
async function removeDestination(name) {
  const list = _nbRegions().filter(r => r.name !== name).map(r => ({ name: r.name, spec: r.spec }));
  await _postRegions(_regionSpecStr(list));
}
// The region spec for a configured pool — carries its transport + (for :direct) base port, so the
// declared region matches the pool and adoption kicks in.
function _destSpecFromPool(p) {
  return p.transport === 'direct' ? (p.host + ',direct' + (p.base_port > 0 ? ',' + p.base_port : '')) : p.host;
}

// Set a cell's region ('' = local/main): drop any region tag, add the new one. `default` → `remote`.
async function setCellRegion(id, name) {
  const cur = _curTags(id).filter(t => t !== 'remote' && !t.startsWith('region='));
  await setTags(id, name ? [...cur, name === 'default' ? 'remote' : ('region=' + name)] : cur);
}

// ── "Run on" section for the 🏷 tag editor ───────────────────────────────────────────────────────
// local + every declared destination as a radio, plus a link to declare a new one. renderTagPop
// injects runOnSectionHtml(id) and calls wireRunOnSection(pop, id).
function runOnSectionHtml(id) {
  const cur = cellAssignedRegion(_cellById(id));
  const opt = (val, label, sub) =>
    `<label class="ctlrow"><input type="radio" name="runon-${id}" value="${_escc(val)}"${cur === val ? ' checked' : ''}>` +
    `<span>${_escc(label)}${sub ? `<span class="tagdesc">${_escc(sub)}</span>` : ''}</span></label>`;
  let rows = opt('', '💻 local', 'main kernel · this machine');
  rows += _nbRegions().map(r => opt(r.name, (r.name === 'default' ? '🖧 remote' : '🖧 ' + r.name),
    r.host + (r.transport === 'direct' ? ' · direct' : ''))).join('');
  return '<div class="ctlhead">Run on</div>' + rows +
    '<div class="tagadd"><a href="#" class="destadd" title="declare a run destination for this notebook">＋ Add destination…</a></div>';
}
function wireRunOnSection(pop, id) {
  pop.querySelectorAll(`input[name="runon-${id}"]`).forEach(rb => rb.onchange = () => setCellRegion(id, rb.value));
  const a = pop.querySelector('.destadd');
  if (a) a.onclick = e => { e.preventDefault(); openDestinations(); };
}

// ── Destinations manager modal ───────────────────────────────────────────────────────────────────
// Destinations are ENABLED from the hosts/pools you already configured on the home page — no host or
// transport is re-entered here; the pool's spec (transport + :direct base port) is reused so the
// region matches the pool and adopts a warm worker.
let _destPools = { pools: [], parked: [] }, _destSsh = [];
function _destWarm(host) { const p = (_destPools.pools || []).find(x => x.host === host); return p ? p.n : 0; }

function openDestinations() {
  document.getElementById('destbg').classList.add('show');
  renderDestinations();
  _destLoad();
}
function closeDestinations() { document.getElementById('destbg').classList.remove('show'); }

// Configured compute available to enable: pools (authoritative transport/ports + warm count) win
// over ssh-config aliases and locally-remembered remotes; deduped by host, sorted.
function _destAvailable() {
  const byHost = new Map();
  (_destSsh || []).forEach(h => { if (!byHost.has(h)) byHost.set(h, { host: h, transport: 'tunnel', warm: 0, spec: h, src: 'ssh' }); });
  try { JSON.parse(localStorage.getItem('slateRemotes') || '[]').forEach(spec => {
    const parts = String(spec).split(','), h = parts[0]; if (!h) return;
    byHost.set(h, { host: h, transport: parts[1] === 'direct' ? 'direct' : 'tunnel', warm: 0, spec: String(spec), src: 'remembered' });
  }); } catch (_) {}
  (_destPools.pools || []).forEach(p =>
    byHost.set(p.host, { host: p.host, transport: p.transport, warm: p.n, spec: _destSpecFromPool(p), src: 'pool' }));
  return [...byHost.values()].sort((a, b) => a.host.localeCompare(b.host));
}

function renderDestinations() {
  const enabled = new Set(_nbRegions().map(r => r.host));
  // Enabled for this notebook
  const cur = _nbRegions(), el = document.getElementById('destlist');
  if (el) {
    el.innerHTML = cur.length
      ? '<div class="ctlsub">Enabled for this notebook</div>' + cur.map(r => {
          const warm = _destWarm(r.host);
          const badge = warm > 0 ? `<span class="destwarm" title="warm pool workers ready to adopt">${warm} warm</span>` : '';
          const where = _escc(r.host) + (r.transport === 'direct' ? ' · direct' + (r.port ? ' :' + _escc(r.port) : '') : '');
          return `<div class="destitem"><div class="destinfo"><b>🖧 ${_escc(r.name === 'default' ? 'remote' : r.name)}</b> <span class="desthost">${where}</span>${badge}</div>` +
            `<button class="destdel" data-n="${_escc(r.name)}" title="disable this destination">✕</button></div>`;
        }).join('')
      : '<div class="destempty">No destinations enabled yet — pick one below, then tag cells to it (🏷 → Run on) or drag them into its DAG zone.</div>';
    el.querySelectorAll('.destdel').forEach(b => b.onclick = () => removeDestination(b.dataset.n));
  }
  // Available compute (not yet enabled)
  const av = document.getElementById('destavail');
  if (av) {
    const avail = _destAvailable().filter(a => !enabled.has(a.host));
    av.innerHTML = '<div class="ctlsub">Available compute (configured on the home page)</div>' +
      (avail.length ? avail.map(a => {
        const meta = [a.transport, a.warm > 0 ? `${a.warm} warm` : '', a.src === 'pool' ? 'pool' : ''].filter(Boolean).join(' · ');
        return `<div class="destitem"><div class="destinfo"><b>${_escc(a.host)}</b> <span class="destsrc">${_escc(meta)}</span></div>` +
          `<button class="desten" data-h="${_escc(a.host)}" data-s="${_escc(a.spec)}" title="enable as a run destination">Enable →</button></div>`;
      }).join('') : '<div class="destempty">Nothing configured yet — set up a host or warm pool on the home page (🖧 Remotes).</div>');
    av.querySelectorAll('.desten').forEach(b => b.onclick = () => enableDestination(b.dataset.h, b.dataset.s));
  }
  const hint = document.getElementById('desthint');
  if (hint) hint.innerHTML = (_destPools.pools || []).some(p => p.n > 0)
    ? '💡 A host with warm workers adopts one instantly — no ~90s cold boot.'
    : '💡 Configure a warm pool on the home page (🖧 Remotes → Pool ›) so destinations adopt instantly.';
}

// Load the configured pools + ssh-config hosts, then render (warm counts + availability need them).
async function _destLoad() {
  try { _destPools = await (await fetch('/api/pools')).json(); } catch (_) { _destPools = { pools: [], parked: [] }; }
  try { const d = await (await fetch('/api/ssh-hosts')).json(); _destSsh = d.hosts || []; } catch (_) { _destSsh = []; }
  renderDestinations();
}

// Backdrop / Esc close (mirrors the run-location modal).
document.addEventListener('mousedown', e => { if (e.target && e.target.id === 'destbg') closeDestinations(); });
document.addEventListener('keydown', e => {
  const bg = document.getElementById('destbg');
  if (e.key === 'Escape' && bg && bg.classList.contains('show')) { e.stopPropagation(); closeDestinations(); }
}, true);
