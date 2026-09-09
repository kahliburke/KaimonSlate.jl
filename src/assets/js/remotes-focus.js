// Remotes-modal REGION FOCUS VIEW — Preact component (the focused host's region list + editor with the
// sysimage panel + live worker roster + parked wires). Exported as `Focus` and mounted by the modal
// island (remotes.js); driven entirely by shared signals (stores.js) — no window.__slate* bridges. A
// worker-row click sets the shared `detail` so the activity.js popup shows it. Reuses the .rtf*/.rpp* CSS.
import { html } from 'htm/preact';
import { signal, effect } from '@preact/signals';
import { detail, focusHost, editRegion, pendingRegion, regions, parked, loadRegions, schedInfo, loadScheduler } from './stores.js';
import { hostTransport } from './hoststore.js';
// One answer to "is a node held" and "what is giving it back called", shared with the notebook's
// pills and panels — these used to be worked out here, and differently in two other files. model.js
// is a classic script loaded before every module, so it is always here by the time this runs.
const { allocState, releaseVerb, isAlive, workerState,
        getAllocation, loadAllocation, refreshAllocation } = window.slateModel;
// The model holds plain state (no signals — it cannot import them). Mirror its changes into one
// signal so this island re-renders when an allocation lands, however it was asked for.
const modelTick = signal(0);
window.slateModel.subscribe(() => { modelTick.value++; });

const roster  = signal({});    // host -> workers[] | undefined (loading)
const rmsg    = signal(null);  // {text, err} save-status line
const sysd    = signal({});    // region name -> last /api/sysimage payload

// editor form fields (seeded from editRegion by an effect; read on save)
const fName = signal(''), fWarm = signal(0), fPre = signal(''), fRoot = signal(''),
      fTr = signal('tunnel'), fPort = signal(''), fSys = signal(false);
// When the host fronts a scheduler, `host` is where you ASK, not where the work runs — the node is
// granted, not chosen. These are what the request needs.
const fSched = signal('none'), fPart = signal(''), fWall = signal(''), fCpus = signal(''),
      fMem = signal(''), fGpus = signal(''), fAcct = signal(''), fIdle = signal(''), fWarn = signal('');
// Everything the fixed fields cannot say, as ordered rows so a half-typed one does not vanish while
// you are still typing it. Stored as a map; kept as a list here because two blank names are two
// rows to the eye and one key to a map.
const fOpts = signal([]);          // [{k, v}]
const fPro = signal('');
const fMore = signal(false);       // the disclosure
const fOptMenu = signal(-1);       // which option row has its suggestion menu open (-1 = none)
// What the fold is hiding that is actually set. A collapsed section must never conceal a setting
// nobody would have guessed was there — the cluster form counts the same way.
const filledExtras = () =>
  fOpts.value.filter(o => (o.k || '').trim()).length + ((fPro.value || '').trim() ? 1 : 0);

const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
const fmtB = (b) => window.slateBytes(b, { compact: true });
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
// The server returns codes with the values behind them. The wording is here, beside the fields.
function saveError(d) {
  const c = d && d.error;
  if (c === 'warn_not_shorter')
    return 'the warning (' + (d.idle_warn || '—') + ') must be shorter than the idle timeout (' +
           (d.idle_release || '—') + ') — a warning that arrives with the release cannot be answered';
  return c || 'failed';
}
function saveNotes(d) {
  return ((d && d.notes) || []).map(n =>
    n.code === 'idle_outlives_walltime'
      ? 'the walltime (' + n.walltime + ') is shorter than the idle timeout (' + n.idle_release +
        '), so the allocation ends first and the timeout will never fire'
      : n.code).filter(Boolean);
}
function saveRegion() {
  const h = focusHost.value, name = (fName.value || '').trim();
  if (!name) { rmsg.value = { text: 'give the region a name', err: true }; return; }
  const scheduler = fSched.value || 'none';
  // Zero on a scheduler region: the field is not offered there, and the server coerces it anyway.
  const warm = scheduler === 'none' ? Math.max(0, parseInt(fWarm.value, 10) || 0) : 0;
  const transport = fTr.value;
  const base_port = transport === 'direct' ? (parseInt(fPort.value, 10) || 0) : 0;
  const preload = (fPre.value || '').trim(), data_root = (fRoot.value || '').trim(), sysimage = !!fSys.value;
  const SO = window.slateSchedOpts;
  // Rows → the stored map. A row with no NAME is a half-typed one and is dropped; a row with a name
  // and no value is a switch (`--exclusive`) and is kept. Names go through the shared normaliser, so
  // typing the scheduler's spelling lands on the key the cell editor would have stored.
  const optMap = {};
  for (const r of fOpts.value) {
    const k = SO ? SO.toKey(r.k) : String(r.k || '').trim();
    if (k) optMap[k] = String(r.v == null ? '' : r.v).trim();
  }
  const alloc = scheduler === 'none' ? {} : {
    partition: (fPart.value || '').trim(), walltime: (fWall.value || '').trim(),
    cpus: Math.max(0, parseInt(fCpus.value, 10) || 0), mem: (fMem.value || '').trim(),
    gpus: (fGpus.value || '').trim(), account: (fAcct.value || '').trim(),
    idle_release: (fIdle.value || '').trim(), idle_warn: (fWarn.value || '').trim(),
    options: optMap, prologue: (fPro.value || '').trim() };
  rmsg.value = { text: warm > 0 ? 'Saving + warming…' : 'Saving…' };
  fetch('/api/regions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, host: h, warm, preload, transport, base_port, data_root, sysimage, scheduler, ...alloc }) })
    .then(r => r.json()).then(d => {
      if (!d || !d.ok) { rmsg.value = { text: saveError(d), err: true }; return; }
      const ports = (base_port && warm > 0) ? (' · ports ' + base_port + '–' + (base_port + 3 * warm - 1)) : '', rootS = data_root ? (' · root ' + data_root) : '';
      const notes = saveNotes(d);
      rmsg.value = { text: 'Region “' + name + '” saved' + (warm > 0 ? (' → ' + warm + ' warm · ' + transport + ports + rootS + ' — workers booting…') : (' · ' + transport + rootS)) + (notes.length ? ' — ' + notes.join('; ') : ''), warn: notes.length > 0 };
      loadRegions().then(() => { editRegion.value = regionsOn(h).find(x => x.name === name) || editRegion.value; });
      if (warm > 0) { let n = 0; (function poll() { if (focusHost.value !== h) return; fetchRoster(h); if (++n < 6) setTimeout(poll, 2500); })(); }
    }).catch(() => { rmsg.value = { text: 'request failed', err: true }; });
}
function deleteRegion(h, name) {
  confirmP('Delete region `' + name + '`?\nIts workers are reaped. On a scheduler region the allocation is released too.', 'Delete', 'danger').then(ok => {
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
// Repair rather than remove: the worker goes and whatever was using it gets a fresh one and re-runs.
// Confirmed like the reap because the namespace goes either way — but not as `danger`, since the
// point of it is to get back to a working notebook.
function restartWorker(h, port) {
  confirmP('Restart worker :' + port + ' on ' + h + '?\nIts namespace is cleared and the cells that were using it re-run.', 'Restart').then(ok => {
    if (!ok) return;
    rmsg.value = { text: 'Restarting worker :' + port + '…' };
    fetch('/api/restart-worker', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ host: h, port }) })
      .then(r => r.json())
      .then(j => { rmsg.value = { text: (j && j.message) || ('worker :' + port + ' restarted') }; fetchRoster(h); })
      .catch(() => { rmsg.value = { text: 'could not restart worker :' + port, err: true }; });
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
// The cache lives in the model, so releasing here also clears what the notebook's region panel shows.
const loadAlloc = (name, force = false) => loadAllocation(name, force);
async function releaseAlloc(name) {
  if (!await confirmP('Release the allocation held for `' + name + '`?\nWorkers on that node go with it; the next cell asks the scheduler for a new one.', 'Release', 'danger')) return;
  await fetch('/api/allocation/release', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ region: name }) }).catch(() => {});
  refreshAllocation(name); loadRegions();
}
function AllocationRow(name) {
  if (!name || fSched.value === 'none') return null;
  modelTick.value;                    // subscribe this row to model changes
  const a = getAllocation(name);
  if (a === undefined) return null;   // the seed effect asks; render never triggers a fetch
  const body =
    a === null ? html`<span class="pddim"><span class="hydspin"></span> asking ${focusHost.value}…</span>`
    : !a.ok ? html`<span class="pddim">${a.error || 'unavailable'}</span>`
    // `allocState` and the verb come from the hub, so this row and the notebook's cannot disagree
    // about whether a node is held or about what giving it back is called.
    : allocState(a) === 'running' ? html`<span class="rppsysok">✓ node <code>${a.node}</code>${a.timeleft ? ' · ' + a.timeleft + ' left' : ''} · job ${a.id}</span>
        <button class="rppsysbtn" title="release the node now; it bills while held" onClick=${() => releaseAlloc(name)}>${releaseVerb(a)}</button>`
    : allocState(a) === 'pending' ? html`<span class="pddim"><span class="hydspin"></span> queued as job ${a.id} — a cell on this region waits for it</span>
        <button class="rppsysbtn" title="withdraw the request" onClick=${() => releaseAlloc(name)}>${releaseVerb(a)}</button>`
    : html`<span class="pddim">nothing held — the first cell on this region asks for a node</span>`;
  return html`<div class="rpprow"><label>Allocation</label><div class="rppsysbox">${body}
    <button class="rppsysbtn" title="ask the scheduler again" onClick=${() => loadAlloc(name, true)}>↻</button></div></div>`;
}

// ── components ──────────────────────────────────────────────────────────────────────
// Warm workers and scheduler allocations are alternatives, not options that combine: a warm worker
// lives on the host between notebooks, and a scheduler region has no host to keep one on. So every
// control and every label that talks about warmth is written for one kind of region or the other,
// never shown to both.
const isSched = r => !!(r && r.scheduler && r.scheduler !== 'none');

function RegionList() {
  const h = focusHost.value, regs = regionsOn(h), e = editRegion.value, newSel = !(e && e.name);
  return html`<div>
    <div class="rppreglist">
      ${regs.map(r => html`<div class=${'rppregrow' + (e && e.name === r.name ? ' sel' : '')} onClick=${() => editRegion.value = r}>
        <span class="rppregname">${isSched(r) ? '⎈' : '🖧'} ${r.name}</span>
        <span class="rppregmeta">${(r.node && r.node !== r.host) ? 'on ' + r.node + ' · ' : ''}${isSched(r)
          ? (r.walltime || '') + (r.partition ? ' · ' + r.partition : '') + (r.walltime || r.partition ? ' · ' : '')
          : 'warm ' + (+r.warm || 0) + ' · '}${r.transport || 'tunnel'}${r.sysimage ? ' · ⚙ sysimage' : ''}${r.data_root ? ' · root ' + r.data_root : ''}</span>
        ${(r.status && !r.status.ok) ? html`<span class="rppregst err">⚠ ${r.status.msg}</span>` : null}
        <button class="rppregdel" title=${isSched(r) ? 'delete this region (releases any allocation it holds)' : 'delete this region (reaps its warm workers)'} onClick=${ev => { ev.stopPropagation(); deleteRegion(h, r.name); }}>✕</button></div>`)}
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
    ${fSched.value === 'none'
      ? html`<div class="rpprow"><label>Warm</label><input class="rppn" type="text" inputmode="numeric" autocomplete="off" value=${fWarm.value} onInput=${ev => fWarm.value = ev.target.value}/><span class="pddim" style="font-size:.76rem">workers kept ready to adopt</span></div>`
      : null}
    <div class="rpprow"><label>Preload</label><input class="rpppre" autocomplete="off" placeholder="/path/to/project  (folder with Project.toml)" value=${fPre.value} onInput=${ev => fPre.value = ev.target.value}/></div>
    ${editing ? TransferRules(e.name) : null}
    <div class="rpprow"><label>Data root</label><input class="rpproot" autocomplete="off" placeholder="/scratch  (a path ON THE HOST)" value=${fRoot.value} onInput=${ev => fRoot.value = ev.target.value}/></div>
    ${SchedulerRows()}
    ${AllocationRow(editing ? e.name : '')}
    <div class="rpprow"><label>Transport</label>
      <select class="rpptr" value=${fTr.value} onChange=${ev => fTr.value = ev.target.value}><option value="tunnel">tunnel</option><option value="direct">direct</option></select>
      ${fTr.value === 'direct' ? html`<input class="rppport" type="text" inputmode="numeric" autocomplete="off" placeholder="base port" value=${fPort.value} onInput=${ev => fPort.value = ev.target.value}/>` : null}</div>
    <div class="rpprow"><label>Sysimage</label><label class="rppchk"><input type="checkbox" checked=${fSys.value} onChange=${ev => fSys.value = ev.target.checked}/><span>Use worker sysimage <span class="pddim">faster worker boot — built & kept fresh in the background; needs a C compiler + free RAM on the host</span></span></label></div>
    <div class="rpprow rppsysrow"><label></label><div class="rppsysbox">${sysNote(editing ? e.name : '', fSys.value, editing)}</div></div>
    <div class="rppact"><button class="rppsavereg" title=${fSched.value === 'none' ? 'save this region and reconcile toward its warm count' : 'save this region — its node is requested when a cell needs one'} onClick=${saveRegion}>${editing ? 'Save' : 'Create'}</button></div>
    </div>
    <div class=${'rppmsg' + (rmsg.value && rmsg.value.err ? ' err' : '')}>${rmsg.value ? rmsg.value.text : ''}</div>`;
}

// ── Where the work actually runs ──────────────────────────────────────────────────────────────
// On an ordinary host, `host` IS the machine. On a cluster's front door it is only where you ASK:
// the scheduler grants a node, and which one is an output of the request. So these rows appear only
// when the host has a scheduler, and what they collect is what the request needs.
// The scheduler options a region carries, and the shell its worker wants first. Rarely set, so
// folded away — with a count, because a fold that hides a setting silently is worse than a long
// form. The catalogue, the spelling and the warnings are `schedopts.js`, shared with the sweep
// cell's editor so one name means one thing in both.
// ── What gets sent ──────────────────────────────────────────────────────────────────────────────
// The preload directory is shipped to the host, and it is the user's project — which routinely has
// data beside the code. `.gitignore` is honoured already; this edits the `.slateignore` next to it
// for what is tracked but still not worth sending, and for projects that are not repositories.
//
// The SIZES are the reason this is a panel rather than a link to a file. A rule is abstract; "4.2 GB
// in data/ is going" is not, and it is the number that makes someone write a rule at all.
const trOpen = signal(false), trData = signal(null), trText = signal(''), trBusy = signal(false);

function loadTransfer(region) {
  trData.value = null;
  fetch('/api/transfer-rules?region=' + encodeURIComponent(region))
    .then(r => r.json())
    .then(d => { trData.value = d; trText.value = (d && d.text) || ''; })
    .catch(() => { trData.value = { dir: '' }; });
}

function saveTransfer(region) {
  trBusy.value = true;
  fetch('/api/transfer-rules', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                 body: JSON.stringify({ region, text: trText.value }) })
    .then(r => r.json())
    .then(d => { trBusy.value = false;
                 if (d && d.ok) loadTransfer(region);          // re-measure: the point is the sizes
                 else rmsg.value = { text: (d && d.error) || 'could not save', err: true }; })
    .catch(() => { trBusy.value = false; rmsg.value = { text: 'could not save', err: true }; });
}

function TransferRules(region) {
  const d = trData.value;
  const bar = (label, side, cls) => !side ? null : html`
    <div class=${'rpptrbar ' + cls}>
      <span class="rpptrlabel">${label}</span>
      <span class="rpptrsize">${fmtB(side.bytes || 0)}</span>
      <span class="pddim">${side.files || 0} files</span>
      ${(side.top || []).slice(0, 3).map(t => html`<span class="rpptrtop">${t.name} ${fmtB(t.bytes)}</span>`)}
    </div>`;
  return html`
    <div class="rpprow rpptrrow"><label>Sent to host</label>
      <div class="rpptrbox">
        ${!trOpen.value
          ? html`<button class="rpptrtoggle" onClick=${() => { trOpen.value = true; loadTransfer(region); }}>
                   Review what gets sent…</button>`
          : !d ? html`<span class="pddim">reading ${'…'}</span>`
          : !d.dir ? html`<span class="pddim">This region has no preload directory, so nothing local is shipped.</span>`
          : html`
            ${bar('sent', d.sent, 'ok')}
            ${bar('held back', d.held, 'held')}
            <div class="rpptrhint">Rules for <code>${d.dir}</code>. <code>.gitignore</code> is always
              honoured; these are for what it does not cover. One pattern per line, gitignore syntax.
              A <code>[region:${region}]</code> section applies to this host only, and
              <code>!pattern</code> puts something back.</div>
            <textarea class="rpptrtext" rows="6" spellcheck="false"
              placeholder=${'# never send these\nresults/\n*.h5\n\n[region:' + region + ']\n# already on this host\ndata/'}
              value=${trText.value} onInput=${ev => trText.value = ev.target.value}></textarea>
            <div class="rpptract">
              <button class="rpptrsave" disabled=${trBusy.value}
                onClick=${() => saveTransfer(region)}>${trBusy.value ? 'Saving…' : 'Save rules'}</button>
              <button class="rpptrclose" onClick=${() => { trOpen.value = false; }}>Close</button>
              ${d.exists ? html`<span class="pddim">${d.file}</span>` : html`<span class="pddim">no ${'.slateignore'} yet</span>`}
            </div>`}
      </div></div>`;
}

function MoreRows(kind) {
  const SO = window.slateSchedOpts;
  const rows = fOpts.value;
  const setRow = (i, patch) => {
    const next = rows.map((r, j) => (j === i ? { ...r, ...patch } : r));
    // Keep exactly one trailing blank row to type into, and drop the others.
    const kept = next.filter((r, j) => (r.k || '').trim() || (r.v || '').trim() || j === next.length - 1);
    fOpts.value = kept;
  };
  const addRow = () => { fOpts.value = [...rows, { k: '', v: '' }]; };
  const delRow = i => { fOpts.value = rows.filter((_, j) => j !== i); };
  const n = filledExtras();
  return html`
    <div class="rpprow rppmorehd">
      <label></label>
      <button type="button" class="rppmorebtn" onClick=${() => fMore.value = !fMore.value}>
        ${fMore.value ? '▾' : '▸'} More settings${n ? html`<span class="rppmoren">${n} set</span>` : ''}</button>
      <span class="pddim" style="font-size:.76rem">scheduler options and a startup command</span></div>
    ${!fMore.value ? null : html`
      <div class="rpprow rppmorebody"><label>Options</label>
        <div class="rppopts">
          ${rows.map((r, i) => {
            const key = SO ? SO.toKey(r.k) : (r.k || '');
            const warn = SO ? SO.warnFor(key, kind) : '';
            const hits = (SO && fOptMenu.value === i) ? SO.matches(r.k, kind, SO.MENU_MAX, SO.FIELD_OWNED) : [];
            const pick = o => {
              setRow(i, { k: SO.spellOf(o, kind) });
              fOptMenu.value = -1;
            };
            return html`<div class=${'rppoptrow' + (warn ? ' unknown' : '')}>
              <input class="rppoptk" autocomplete="off" spellcheck="false" placeholder="option"
                     value=${r.k}
                     onInput=${ev => { setRow(i, { k: ev.target.value }); fOptMenu.value = i; }}
                     onFocus=${() => fOptMenu.value = i}
                     onBlur=${() => setTimeout(() => { if (fOptMenu.value === i) fOptMenu.value = -1; }, 120)}/>
              <input class="rppoptv" autocomplete="off" spellcheck="false" placeholder="value"
                     title="leave blank for a switch such as exclusive"
                     value=${r.v} onInput=${ev => setRow(i, { v: ev.target.value })}/>
              <button type="button" class="rppoptdel" title="remove this option" tabindex="-1"
                      onClick=${() => delRow(i)}>✕</button>
              ${warn ? html`<span class="rppoptwarn">${warn}</span>` : null}
              ${hits.length ? html`<div class="rppoptmenu">
                ${hits.map(o => html`<div class="rppoptmi"
                    onMouseDown=${ev => { ev.preventDefault(); pick(o); }}>
                  <span class="rppoptminame">${SO.spellOf(o, kind)}</span>
                  <span class="rppoptmihint">${SO.hintOf(o, kind)}</span></div>`)}
              </div>` : null}</div>`;
          })}
          <button type="button" class="rppoptadd" onClick=${addRow}>+ option</button>
          <div class="rppfieldhint">Sent as the scheduler spells them. An unlisted name is still
            sent: a site has its own, and dropping one silently is worse than not suggesting it.</div>
        </div></div>
      <div class="rpprow rppmorebody"><label>Before start</label>
        <div class="rppfields" style="flex-direction:column;align-items:stretch">
          <textarea class="rpppre rppprologue" rows="2" autocomplete="off"
                    placeholder="module load cuda"
                    value=${fPro.value} onInput=${ev => fPro.value = ev.target.value}></textarea>
          <span class="rppfieldhint">Shell run on the granted node before the worker starts. The
            allocation itself only holds the node, so this is the one place that reaches the
            worker's environment. A failure here stops the worker rather than booting it
            unconfigured.</span></div></div>`}`;
}

function SchedulerRows() {
  const h = focusHost.value, si = schedInfo.value[h];
  if (si === null) return html`<div class="rpprow"><label>Scheduler</label><span class="pddim"><span class="hydspin"></span> asking ${h}…</span></div>`;
  const kinds = (si && si.kinds) || [];
  // Nothing found AND nothing configured: stay quiet. A workstation should not be asked for a
  // walltime. (An explicit choice already saved still shows, since the tools may be behind a
  // `module load` that detection cannot see.)
  if (!kinds.length && fSched.value === 'none') return null;
  const chosen = fSched.value;
  // Fetched once per page, and only when there is a scheduler to describe. `load` dedupes an
  // in-flight fetch and returns immediately once it has the list, so calling it per render is free.
  if (chosen !== 'none' && window.slateSchedOpts) window.slateSchedOpts.load();
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
      <div class="rppfields">
        ${[['cpus', fCpus, 'cpus', 'tasks/cores to request'],
           ['memory', fMem, '16G', 'per node'],
           ['gpus', fGpus, '1', 'or a100:2'],
           ['account', fAcct, '', 'project to bill']].map(([name, sig, ph, hint]) => html`
          <label class="rppfield"><span class="rppfieldname">${name}</span>
            <input class="rppport" autocomplete="off" placeholder=${ph}
                   title=${hint + ' (blank = site default)' +
                            (name === 'gpus' && !parts.some(p => p.gpus)
                              ? '. No partition on this host reports GPUs.' : '')}
                   value=${sig.value} onInput=${ev => sig.value = ev.target.value}/>
            <span class="rppfieldhint">${hint}</span></label>`)}
      </div></div>
    <div class="rpprow"><label>Release when idle</label>
      <div class="rppfields">
        ${[['idle for', fIdle, 'never', 'no cell running on this region — 30m, 1h, 2d'],
           ['warn before', fWarn, 'none', 'ask first, this long ahead — must be shorter']].map(([name, sig, ph, hint]) => html`
          <label class="rppfield"><span class="rppfieldname">${name}</span>
            <input class="rppport" autocomplete="off" placeholder=${ph} title=${hint}
                   value=${sig.value} onInput=${ev => sig.value = ev.target.value}/>
            <span class="rppfieldhint">${hint}</span></label>`)}
      </div></div>
    ${MoreRows(chosen)}`}`;
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
        return html`<div class="rppworker" title="worker details + history" onClick=${ev => { if (ev.target.closest && ev.target.closest('.rppwacts')) return; detail.value = { host: h, port: +w.port }; }}>
          <div class="rppw1"><span class="rppwport">${isAlive(w) ? '🟢' : '⚪'} :${w.port}</span>
            ${w.state ? html`<span class=${'rppbadge ' + (workerState(w) === 'attached' ? 'attached' : 'idle')}>${w.state}</span>` : null}
            ${mf.region ? html`<span class="rppbadge pool">${mf.region}</span>` : null}
            ${(workerState(w) === 'attached' && mf.notebook) ? html`<span class="rppwnb">${mf.notebook}</span>` : null}
            ${tel.length ? html`<div class="rppwtel">${tel.join(' · ')}</div>` : null}
            ${warm ? html`<div class="rppwtel" style=${'color:' + wc}>${warm.indexOf('warming') === 0 ? '⏳ ' : warm.indexOf('ready') === 0 ? '✓ ' : ''}${warm}</div>` : null}</div>
          <div class="rppwacts">
            <button class="rppwrestart" title="give it a fresh process and re-run what was using it" onClick=${ev => { ev.stopPropagation(); restartWorker(h, +w.port); }}>↻ Restart</button>
            <button class="rppreap" title="kill this worker + remove its files" onClick=${ev => { ev.stopPropagation(); reapWorker(h, +w.port); }}>✕ Reap</button></div></div>`;
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
  // Collapse the transfer panel on every switch. Its contents are one region's directory and one
  // region's sizes; left open it would show the previous region's under the new region's name.
  trOpen.value = false; trData.value = null; trText.value = '';
  if (e && e.name) { fName.value = e.name; fWarm.value = +e.warm || 0; fPre.value = e.preload || ''; fRoot.value = e.data_root || ''; fTr.value = e.transport || 'tunnel'; fPort.value = e.base_port > 0 ? e.base_port : ''; fSys.value = !!e.sysimage;
    fSched.value = e.scheduler || 'none'; fPart.value = e.partition || ''; fWall.value = e.walltime || '';
    fCpus.value = e.cpus > 0 ? e.cpus : ''; fMem.value = e.mem || ''; fGpus.value = e.gpus || ''; fAcct.value = e.account || ''; fIdle.value = e.idle_release || ''; fWarn.value = e.idle_warn || '';
    // A map has no order, so the rows are sorted: the form reads the same on every open.
    fOpts.value = Object.keys(e.options || {}).sort().map(k => ({ k, v: (e.options || {})[k] }));
    fPro.value = e.prologue || '';
    // Open the fold when the REGION has something folded away, so a saved setting is never out of
    // sight. Read from `e`, never from the form's own signals: `filledExtras()` reads `fOpts`, which
    // would subscribe this seeding effect to it — then adding a row would re-run the seed, reset the
    // rows to what was stored, and the new row would vanish as the fold snapped shut.
    fMore.value = Object.keys(e.options || {}).length > 0 || !!(e.prologue || '').trim(); }
  else { fName.value = ''; fWarm.value = 0; fPre.value = ''; fRoot.value = ''; fTr.value = hostTransport(h); fPort.value = ''; fSys.value = false;
    // A NEW region on a host that fronts a scheduler defaults to using it, with a walltime already
    // filled in: an allocation with no end time is the one people forget they are holding.
    const si = schedInfo.value[h];
    fSched.value = (si && si.suggested) ? si.suggested : 'none';
    fPart.value = ''; fWall.value = fSched.value === 'none' ? '' : '01:00:00';
    fCpus.value = ''; fMem.value = ''; fGpus.value = ''; fAcct.value = ''; fIdle.value = ''; fWarn.value = '';
    fOpts.value = []; fPro.value = ''; fMore.value = false; }
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
