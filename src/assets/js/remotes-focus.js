// Remotes-modal REGION FOCUS VIEW — Preact component (the focused host's region list + editor with the
// sysimage panel + live worker roster + parked wires). Exported as `Focus` and mounted by the modal
// island (remotes.js); driven entirely by shared signals (stores.js) — no window.__slate* bridges. A
// worker-row click sets the shared `detail` so the activity.js popup shows it. Reuses the .rtf*/.rpp* CSS.
import { html } from 'htm/preact';
import { signal, effect } from '@preact/signals';
import { detail, focusHost, editRegion, pendingRegion, regions, parked, loadRegions, schedInfo, loadScheduler } from './stores.js';
import { hostTransport } from './hoststore.js';

const roster  = signal({});    // host -> workers[] | undefined (loading)
const rmsg    = signal(null);  // {text, err} save-status line
const sysd    = signal({});    // region name -> last /api/sysimage payload

// editor form fields (seeded from editRegion by an effect; read on save)
const fName = signal(''), fWarm = signal(0), fPre = signal(''), fRoot = signal(''),
      fTr = signal('tunnel'), fPort = signal(''), fSys = signal(false);
// When the host fronts a scheduler, `host` is where you ASK, not where the work runs — the node is
// granted, not chosen. These are what the request needs.
const fSched = signal('none'), fPart = signal(''), fWall = signal(''), fCpus = signal(''),
      fMem = signal(''), fGpus = signal(''), fAcct = signal('');

const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
const fmtB = (b) => (b = +b || 0, b < 1024 ? b + 'B' : b < 1048576 ? Math.round(b / 1024) + 'KB' : b < 1073741824 ? Math.round(b / 1048576) + 'MB' : (b / 1073741824).toFixed(1) + 'GB');
const ago = (u) => { let s = Math.max(0, Math.floor(Date.now() / 1000 - (+u || 0))); return s < 90 ? s + 's ago' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 172800 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };
const regionsOn = (h) => regions.value.filter(r => r.host === h);
const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));

// ── data ──────────────────────────────────────────────────────────────────────────
function fetchRoster(h) { fetch('/api/remote-workers?host=' + encodeURIComponent(h)).then(r => r.json()).then(d => { roster.value = { ...roster.value, [h]: (d && d.workers) || [] }; }).catch(() => { roster.value = { ...roster.value, [h]: [] }; }); }
function loadSysimage(name) { fetch('/api/sysimage?region=' + encodeURIComponent(name)).then(r => r.json()).then(d => { sysd.value = { ...sysd.value, [name]: d }; if (d && d.ok && d.building) setTimeout(() => loadSysimage(name), 4000); }).catch(() => {}); }
function buildSysimage(name) {
  sysd.value = { ...sysd.value, [name]: { ...(sysd.value[name] || {}), ok: true, building: true } };
  fetch('/api/sysimage/build', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ region: name }) })
    .then(r => r.json()).then(d => { if (!d || !d.ok) { sysd.value = { ...sysd.value, [name]: { ok: false, error: (d && d.error) || 'build failed to start' } }; return; } setTimeout(() => loadSysimage(name), 3000); }).catch(() => {});
}
function saveRegion() {
  const h = focusHost.value, name = (fName.value || '').trim();
  if (!name) { rmsg.value = { text: 'give the region a name', err: true }; return; }
  const warm = Math.max(0, parseInt(fWarm.value, 10) || 0), transport = fTr.value;
  const base_port = transport === 'direct' ? (parseInt(fPort.value, 10) || 0) : 0;
  const preload = (fPre.value || '').trim(), data_root = (fRoot.value || '').trim(), sysimage = !!fSys.value;
  const scheduler = fSched.value || 'none';
  const alloc = scheduler === 'none' ? {} : {
    partition: (fPart.value || '').trim(), walltime: (fWall.value || '').trim(),
    cpus: Math.max(0, parseInt(fCpus.value, 10) || 0), mem: (fMem.value || '').trim(),
    gpus: (fGpus.value || '').trim(), account: (fAcct.value || '').trim() };
  rmsg.value = { text: warm > 0 ? 'Saving + warming…' : 'Saving…' };
  fetch('/api/regions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, host: h, warm, preload, transport, base_port, data_root, sysimage, scheduler, ...alloc }) })
    .then(r => r.json()).then(d => {
      if (!d || !d.ok) { rmsg.value = { text: (d && d.error) || 'failed', err: true }; return; }
      const ports = (base_port && warm > 0) ? (' · ports ' + base_port + '–' + (base_port + 3 * warm - 1)) : '', rootS = data_root ? (' · root ' + data_root) : '';
      rmsg.value = { text: 'Region “' + name + '” saved' + (warm > 0 ? (' → ' + warm + ' warm · ' + transport + ports + rootS + ' — workers booting…') : (' · ' + transport + rootS)) };
      loadRegions().then(() => { editRegion.value = regionsOn(h).find(x => x.name === name) || editRegion.value; });
      if (warm > 0) { let n = 0; (function poll() { if (focusHost.value !== h) return; fetchRoster(h); if (++n < 6) setTimeout(poll, 2500); })(); }
    }).catch(() => { rmsg.value = { text: 'request failed', err: true }; });
}
function deleteRegion(h, name) {
  confirmP('Delete region “' + name + '”?\nIts warm workers are reaped (attached ones keep running).', 'Delete', 'danger').then(ok => {
    if (!ok) return;
    fetch('/api/regions/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) }).then(r => r.json())
      .then(() => { if (editRegion.value && editRegion.value.name === name) editRegion.value = null; loadRegions(); fetchRoster(h); }).catch(() => {});
  });
}
function reapWorker(h, port) {
  confirmP('Reap worker :' + port + ' on ' + h + '?\nThis kills it and removes its files — any un-fetched results are lost.', 'Reap', 'danger').then(ok => {
    if (!ok) return;
    fetch('/api/reap-worker', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ host: h, port }) }).then(r => r.json()).then(() => fetchRoster(h)).catch(() => {});
  });
}

// ── sysimage note (live checkbox + cached server status) ──────────────────────────
function sysNote(name, checked, editing) {
  const d = sysd.value[name];
  // Unchecking doesn't delete a built image — it's kept on the host and reused if re-enabled (unchanged).
  if (!checked) return (d && d.current)
    ? html`<span class="pddim">off — a built image is kept (<code>${d.current}.so</code>) and reused if you re-enable</span>`
    : html`<span class="pddim">off — workers boot plain</span>`;
  if (d && d.compiler === false) return html`<span class="rppsyswarn">⚠ no C compiler on ${d.host || ''} — install build tools (e.g. <code>apt install build-essential</code>) to enable sysimages</span>`;
  if (!editing) return html`<span class="pddim">will be built in the background after the region’s first worker starts</span>`;
  if (!d) return html`<span class="pddim">checking build status…</span>`;
  if (!d.ok || d.reachable === false) return html`<span class="pddim">build status unavailable</span>`;
  if (d.building) return html`<div class="rppsysstat"><span class="rppsysbuilding"><span class="hydspin"></span> building…</span></div>`;
  if (d.current) return html`<div class="rppsysstat"><span class=${d.stale ? 'rppsyswarn' : 'rppsysok'}>${d.stale ? '⚠ out of date' : '✓ built'} · <code>${d.current}.so</code> · ${fmtB(d.bytes)}${d.built ? ' · ' + ago(d.built) : ''}</span><button class="rppsysbtn" title=${d.stale ? 'code/deps changed since this image was built — rebuild' : 'rebuild the worker sysimage for this env'} onClick=${() => buildSysimage(name)}>Rebuild</button></div>`;
  return html`<div class="rppsysstat"><span class="pddim">will be built in the background on the next worker start</span><button class="rppsysbtn" title="build it now (detached on the host)" onClick=${() => buildSysimage(name)}>Build now</button></div>`;
}

// ── the allocation a scheduler region is holding ────────────────────────────────────
// Worth its own row rather than a line in a status message: an allocation bills for the time it is
// HELD, not the time it is used, so what is being held — and the way to give it back — should be
// where you are already looking, not something to remember.
const alloc = signal({});   // region name -> payload | null (asking) | undefined (never asked)
function loadAlloc(name, force = false) {
  if (!name || (!force && alloc.value[name] !== undefined)) return;
  alloc.value = { ...alloc.value, [name]: null };
  fetch('/api/allocation?region=' + encodeURIComponent(name)).then(r => r.json())
    .then(d => { alloc.value = { ...alloc.value, [name]: d || { ok: false } }; })
    .catch(() => { alloc.value = { ...alloc.value, [name]: { ok: false, error: 'unreachable' } }; });
}
async function releaseAlloc(name) {
  if (!await confirmP('Release the allocation held for “' + name + '”?\nWorkers on that node go with it; the next cell asks the scheduler for a new one.', 'Release', 'danger')) return;
  await fetch('/api/allocation/release', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ region: name }) }).catch(() => {});
  loadAlloc(name, true); loadRegions();
}
function AllocationRow(name) {
  if (!name || fSched.value === 'none') return null;
  const a = alloc.value[name];
  if (a === undefined) return null;   // the seed effect asks; render never triggers a fetch
  const body =
    a === null ? html`<span class="pddim"><span class="hydspin"></span> asking ${focusHost.value}…</span>`
    : !a.ok ? html`<span class="pddim">${a.error || 'unavailable'}</span>`
    : a.state === 'running' ? html`<span class="rppsysok">✓ node <code>${a.node}</code>${a.timeleft ? ' · ' + a.timeleft + ' left' : ''} · job ${a.id}</span>
        <button class="rppsysbtn" title="release the node now; it bills while held" onClick=${() => releaseAlloc(name)}>Release</button>`
    : a.state === 'pending' ? html`<span class="pddim"><span class="hydspin"></span> queued as job ${a.id} — a cell on this region waits for it</span>
        <button class="rppsysbtn" title="withdraw the request" onClick=${() => releaseAlloc(name)}>Cancel</button>`
    : html`<span class="pddim">nothing held — the first cell on this region asks for a node</span>`;
  return html`<div class="rpprow"><label>Allocation</label><div class="rppsysbox">${body}
    <button class="rppsysbtn" title="ask the scheduler again" onClick=${() => loadAlloc(name, true)}>↻</button></div></div>`;
}

// ── components ──────────────────────────────────────────────────────────────────────
function RegionList() {
  const h = focusHost.value, regs = regionsOn(h), e = editRegion.value, newSel = !(e && e.name);
  return html`<div>
    <div class="rppreglist">
      ${regs.map(r => html`<div class=${'rppregrow' + (e && e.name === r.name ? ' sel' : '')} onClick=${() => editRegion.value = r}>
        <span class="rppregname">${(r.scheduler && r.scheduler !== 'none') ? '⎈' : '🖧'} ${r.name}</span>
        <span class="rppregmeta">${(r.node && r.node !== r.host) ? 'on ' + r.node + ' · ' : ''}warm ${+r.warm || 0} · ${r.transport || 'tunnel'}${r.sysimage ? ' · ⚙ sysimage' : ''}${r.data_root ? ' · root ' + r.data_root : ''}</span>
        ${(r.status && !r.status.ok) ? html`<span class="rppregst err">⚠ ${r.status.msg}</span>` : null}
        <button class="rppregdel" title="delete this region (reaps its warm workers)" onClick=${ev => { ev.stopPropagation(); deleteRegion(h, r.name); }}>✕</button></div>`)}
      <div class=${'rppregrow rppregnew' + (newSel ? ' sel' : '')} title="create a new region on this host" onClick=${() => editRegion.value = null}>
        <span class="rppregname">＋ New region</span><span class="rppregmeta">a new compute def on ${h}</span></div>
    </div>
    ${regs.length ? null : html`<div class="pddim" style="margin:2px 0 8px">No regions here yet — fill in the form below. Cells target one with a <code>${'region=<name>'}</code> tag.</div>`}</div>`;
}
function Editor() {
  const h = focusHost.value, e = editRegion.value, editing = !!(e && e.name);
  return html`<div class="rppcfg">
    <div class="rppformhead">${editing ? ('Edit region “' + e.name + '”') : ('New region on ' + h)}</div>
    <div class="rpprow"><label>Name</label>${editing
      ? html`<input class="rppname" readonly value=${e.name}/>`
      : html`<input class="rppname" autocomplete="off" placeholder="e.g. gpu, bigmem" value=${fName.value} onInput=${ev => fName.value = ev.target.value}/>`}</div>
    <div class="rpprow"><label>Warm</label><input class="rppn" type="text" inputmode="numeric" autocomplete="off" value=${fWarm.value} onInput=${ev => fWarm.value = ev.target.value}/><span class="pddim" style="font-size:.76rem">workers kept ready to adopt</span></div>
    <div class="rpprow"><label>Preload</label><input class="rpppre" autocomplete="off" placeholder="/path/to/project  (folder with Project.toml)" value=${fPre.value} onInput=${ev => fPre.value = ev.target.value}/></div>
    <div class="rpprow"><label>Data root</label><input class="rpproot" autocomplete="off" placeholder="/scratch  (a path ON THE HOST)" value=${fRoot.value} onInput=${ev => fRoot.value = ev.target.value}/></div>
    ${SchedulerRows()}
    ${AllocationRow(editing ? e.name : '')}
    <div class="rpprow"><label>Transport</label>
      <select class="rpptr" value=${fTr.value} onChange=${ev => fTr.value = ev.target.value}><option value="tunnel">tunnel</option><option value="direct">direct</option></select>
      ${fTr.value === 'direct' ? html`<input class="rppport" type="text" inputmode="numeric" autocomplete="off" placeholder="base port" value=${fPort.value} onInput=${ev => fPort.value = ev.target.value}/>` : null}</div>
    <div class="rpprow"><label>Sysimage</label><label class="rppchk"><input type="checkbox" checked=${fSys.value} onChange=${ev => fSys.value = ev.target.checked}/><span>Use worker sysimage <span class="pddim">faster worker boot — built & kept fresh in the background; needs a C compiler + free RAM on the host</span></span></label></div>
    <div class="rpprow rppsysrow"><label></label><div class="rppsysbox">${sysNote(editing ? e.name : '', fSys.value, editing)}</div></div>
    <div class="rppact"><button class="rppsavereg" title="save this region and reconcile toward its warm count" onClick=${saveRegion}>${editing ? 'Save' : 'Create'}</button></div>
    </div>
    <div class=${'rppmsg' + (rmsg.value && rmsg.value.err ? ' err' : '')}>${rmsg.value ? rmsg.value.text : ''}</div>`;
}

// ── Where the work actually runs ──────────────────────────────────────────────────────────────
// On an ordinary host, `host` IS the machine. On a cluster's front door it is only where you ASK:
// the scheduler grants a node, and which one is an output of the request. So these rows appear only
// when the host has a scheduler, and what they collect is what the request needs.
function SchedulerRows() {
  const h = focusHost.value, si = schedInfo.value[h];
  if (si === null) return html`<div class="rpprow"><label>Scheduler</label><span class="pddim"><span class="hydspin"></span> asking ${h}…</span></div>`;
  const kinds = (si && si.kinds) || [];
  // Nothing found AND nothing configured: stay quiet. A workstation should not be asked for a
  // walltime. (An explicit choice already saved still shows, since the tools may be behind a
  // `module load` that detection cannot see.)
  if (!kinds.length && fSched.value === 'none') return null;
  const chosen = fSched.value;
  const parts = ((si && si.partitions) || {})[chosen] || [];
  const opts = ['none', ...kinds.filter(k => k !== 'none')];
  if (chosen !== 'none' && !opts.includes(chosen)) opts.push(chosen);   // honour a saved choice
  return html`
    <div class="rpprow"><label>Scheduler</label>
      <select class="rpptr" value=${chosen} onChange=${ev => { fSched.value = ev.target.value; if (ev.target.value !== 'none' && !fWall.value) fWall.value = '01:00:00'; }}>
        ${opts.map(k => html`<option value=${k}>${k === 'none' ? 'none — run on ' + h + ' itself' : k}</option>`)}
      </select>
      ${kinds.length > 1 ? html`<span class="pddim" style="font-size:.76rem">two found on this host — pick the one that runs the jobs</span>`
        : kinds.length ? html`<span class="pddim" style="font-size:.76rem">detected</span>` : null}</div>
    ${chosen === 'none' ? null : html`
      <div class="rpprow"><label>Partition</label>
        ${parts.length ? html`<select class="rpptr" value=${fPart.value} onChange=${ev => fPart.value = ev.target.value}>
            <option value="">(site default)</option>
            ${parts.map(p => html`<option value=${p.name} disabled=${p.up === false}>${p.name}${p.gpus ? ' · ' + p.gpus : ''}${p.maxtime ? ' · ≤' + p.maxtime : ''}${p.up === false ? ' (down)' : ''}</option>`)}
          </select>`
          : html`<input class="rpppre" autocomplete="off" placeholder="queue name (blank = site default)" value=${fPart.value} onInput=${ev => fPart.value = ev.target.value}/>`}</div>
      <div class="rpprow"><label>Walltime</label>
        <input class="rppn" autocomplete="off" placeholder="01:00:00" value=${fWall.value} onInput=${ev => fWall.value = ev.target.value}/>
        <span class="pddim" style="font-size:.76rem">how long to hold it — it bills for the time held, not used</span></div>
      <div class="rpprow"><label>Resources</label>
        <input class="rppport" type="text" inputmode="numeric" autocomplete="off" placeholder="cpus" title="tasks/cores to request (blank = site default)" value=${fCpus.value} onInput=${ev => fCpus.value = ev.target.value}/>
        <input class="rppport" autocomplete="off" placeholder="mem" title="e.g. 16G (blank = site default)" value=${fMem.value} onInput=${ev => fMem.value = ev.target.value}/>
        <input class="rppport" autocomplete="off" placeholder="gpus" title=${'e.g. 1, or a100:2 — blank means a CPU node' + (parts.some(p => p.gpus) ? '' : '. No partition here reports GPUs.')} value=${fGpus.value} onInput=${ev => fGpus.value = ev.target.value}/>
        <input class="rppport" autocomplete="off" placeholder="account" title="project to bill (blank = default)" value=${fAcct.value} onInput=${ev => fAcct.value = ev.target.value}/></div>
      <div class="rpprow rppsysrow"><label></label><div class="rppsysbox">A worker starts on the node this allocation grants, not on <code>${h}</code>. Reopening attaches to the same allocation while it lasts; when it expires the next cell that needs the region asks for another.</div></div>`}`;
}

function Roster() {
  const h = focusHost.value, rs = roster.value[h], parkedFor = parked.value.filter(p => p.host === h);
  return html`<div>
    <div class="rtfworkers">${
      rs === undefined ? html`<div class="rppempty"><span class="hydspin"></span> listing workers…</div>`
      : !rs.length ? html`<div class="rppempty">No workers on ${h} yet.</div>`
      : rs.map(w => {
        const mf = pj(w.manifest), st = pj(w.stats), tel = [];
        if (st.cpu !== undefined && st.cpu >= 0) tel.push('cpu ' + st.cpu + '%');
        if (st.rss) tel.push('rss ' + fmtB(st.rss));
        if (st.memo_bytes > 0) tel.push('memo ' + fmtB(st.memo_bytes));
        const warm = st.warm || '', wc = warm.indexOf('ready') === 0 ? '#56d364' : warm.indexOf('warming') === 0 ? '#e8a13f' : '#8a90a8';
        return html`<div class="rppworker" title="worker details + history" onClick=${ev => { if (ev.target.closest && ev.target.closest('.rppreap')) return; detail.value = { host: h, port: +w.port }; }}>
          <div class="rppw1"><span class="rppwport">${w.alive ? '🟢' : '⚪'} :${w.port}</span>
            ${w.state ? html`<span class=${'rppbadge ' + (w.state === 'attached' ? 'attached' : 'idle')}>${w.state}</span>` : null}
            ${mf.region ? html`<span class="rppbadge pool">${mf.region}</span>` : null}
            ${(w.state === 'attached' && mf.notebook) ? html`<span class="rppwnb">${mf.notebook}</span>` : null}
            ${tel.length ? html`<div class="rppwtel">${tel.join(' · ')}</div>` : null}
            ${warm ? html`<div class="rppwtel" style=${'color:' + wc}>${warm.indexOf('warming') === 0 ? '⏳ ' : warm.indexOf('ready') === 0 ? '✓ ' : ''}${warm}</div>` : null}</div>
          <button class="rppreap" title="kill this worker + remove its files" onClick=${ev => { ev.stopPropagation(); reapWorker(h, +w.port); }}>✕ Reap</button></div>`;
      })
    }</div>
    <div class="rtfpark">${parkedFor.map(p => html`<div class="rpppark">⇄ parked: ${p.label} → :${p.port} <span style="opacity:.7">(idle ${p.idle_s}s)</span></div>`)}</div></div>`;
}
// The breadcrumb "Remotes ›" returns to the host list — just clear the focus signal (the modal island
// renders the list whenever focusHost is '').
export function Focus() {
  const h = focusHost.value;
  if (!h) return null;
  return html`<div>
    <div class="rtfhead"><strong><span class="rtfcrumb" title="back to Remotes" onClick=${() => { focusHost.value = ''; editRegion.value = null; }}>Remotes</span> › 🖧 ${h}</strong><span class="rtfsub">— regions & live workers</span></div>
    <${RegionList}/><${Editor}/><${Roster}/></div>`;
}

// ── effects ────────────────────────────────────────────────────────────────────────
effect(() => { const h = focusHost.value; if (h) { loadRegions(); fetchRoster(h); loadScheduler(h); } });   // focus → load
effect(() => {   // seed the editor form from the selected region (or blank for "new")
  const e = editRegion.value, h = focusHost.value; if (!h) return;
  if (e && e.name) { fName.value = e.name; fWarm.value = +e.warm || 0; fPre.value = e.preload || ''; fRoot.value = e.data_root || ''; fTr.value = e.transport || 'tunnel'; fPort.value = e.base_port > 0 ? e.base_port : ''; fSys.value = !!e.sysimage;
    fSched.value = e.scheduler || 'none'; fPart.value = e.partition || ''; fWall.value = e.walltime || '';
    fCpus.value = e.cpus > 0 ? e.cpus : ''; fMem.value = e.mem || ''; fGpus.value = e.gpus || ''; fAcct.value = e.account || ''; }
  else { fName.value = ''; fWarm.value = 0; fPre.value = ''; fRoot.value = ''; fTr.value = hostTransport(h); fPort.value = ''; fSys.value = false;
    // A NEW region on a host that fronts a scheduler defaults to using it, with a walltime already
    // filled in: an allocation with no end time is the one people forget they are holding.
    const si = schedInfo.value[h];
    fSched.value = (si && si.suggested) ? si.suggested : 'none';
    fPart.value = ''; fWall.value = fSched.value === 'none' ? '' : '01:00:00';
    fCpus.value = ''; fMem.value = ''; fGpus.value = ''; fAcct.value = ''; }
  rmsg.value = null;
});
effect(() => { const e = editRegion.value; if (e && e.name && focusHost.value) loadSysimage(e.name); });   // editing → fetch build status
// editing a scheduler region → ask the login node what it is holding for us
effect(() => { const e = editRegion.value; if (e && e.name && e.scheduler && e.scheduler !== 'none') loadAlloc(e.name); });
// Resolve a pending region-by-name (set by openRegionConfig) once this host's regions have loaded.
effect(() => {
  const name = pendingRegion.value, h = focusHost.value; if (!name || !h) return;
  const r = regionsOn(h).find(x => x.name === name);
  if (r) { editRegion.value = r; pendingRegion.value = ''; }
});
