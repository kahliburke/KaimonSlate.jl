// Remotes-modal REGION FOCUS VIEW — Preact island (strangler-fig migration of the vanilla
// rtRenderFocus / rtRenderWorkers / rtSaveRegion / rtDelete / rtReap / sysimage funcs into #rtfocus).
// Owns: the focused host's region list + editor (with the sysimage panel) + live worker roster + parked
// wires. Driven by shared signals (stores.js): the still-vanilla modal shell sets focusHost/editRegion
// via window.__slate* setters; a worker-row click sets the shared `detail` so the activity.js popup shows
// it (retiring the window.slateOpenWorkerDetail bridge here). Reuses the existing .rtf*/.rpp* CSS.
import { html, render } from 'htm/preact';
import { signal, effect } from '@preact/signals';
import { detail, focusHost, editRegion } from './stores.js';

const regions = signal([]);    // registry regions (all hosts; filtered by focusHost)
const parked  = signal([]);
const roster  = signal({});    // host -> workers[] | undefined (loading)
const rmsg    = signal(null);  // {text, err} save-status line
const sysd    = signal({});    // region name -> last /api/sysimage payload

// editor form fields (seeded from editRegion by an effect; read on save)
const fName = signal(''), fWarm = signal(0), fPre = signal(''), fRoot = signal(''),
      fTr = signal('tunnel'), fPort = signal(''), fSys = signal(false);

const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
const fmtB = (b) => (b = +b || 0, b < 1024 ? b + 'B' : b < 1048576 ? Math.round(b / 1024) + 'KB' : b < 1073741824 ? Math.round(b / 1048576) + 'MB' : (b / 1073741824).toFixed(1) + 'GB');
const ago = (u) => { let s = Math.max(0, Math.floor(Date.now() / 1000 - (+u || 0))); return s < 90 ? s + 's ago' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 172800 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };
const regionsOn = (h) => regions.value.filter(r => r.host === h);
const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));
// Default transport for a NEW region: inferred from a remembered `,direct` spec (host store lives in the
// still-vanilla shell, exposed as window.slateKnownRemotes).
const hostTr = (h) => { try { const s = ((window.slateKnownRemotes && window.slateKnownRemotes()) || []).filter(x => x.split(',')[0] === h)[0] || ''; return s.indexOf('direct') >= 0 ? 'direct' : 'tunnel'; } catch (_) { return 'tunnel'; } };

// ── data ──────────────────────────────────────────────────────────────────────────
function loadRegions() { return fetch('/api/regions').then(r => r.json()).then(d => { regions.value = (d && d.regions) || []; parked.value = (d && d.parked) || []; }).catch(() => {}); }
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
  rmsg.value = { text: warm > 0 ? 'Saving + warming…' : 'Saving…' };
  fetch('/api/regions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name, host: h, warm, preload, transport, base_port, data_root, sysimage }) })
    .then(r => r.json()).then(d => {
      if (!d || !d.ok) { rmsg.value = { text: (d && d.error) || 'failed', err: true }; return; }
      const ports = (base_port && warm > 0) ? (' · ports ' + base_port + '–' + (base_port + 3 * warm - 1)) : '', rootS = data_root ? (' · root ' + data_root) : '';
      rmsg.value = { text: 'Region “' + name + '” saved' + (warm > 0 ? (' → ' + warm + ' warm · ' + transport + ports + rootS + ' — workers booting…') : (' · ' + transport + rootS)) };
      loadRegions().then(() => { editRegion.value = regionsOn(h).find(x => x.name === name) || editRegion.value; window.slateSyncHosts && window.slateSyncHosts(); });
      if (warm > 0) { let n = 0; (function poll() { if (focusHost.value !== h) return; fetchRoster(h); if (++n < 6) setTimeout(poll, 2500); })(); }
    }).catch(() => { rmsg.value = { text: 'request failed', err: true }; });
}
function deleteRegion(h, name) {
  confirmP('Delete region “' + name + '”?\nIts warm workers are reaped (attached ones keep running).', 'Delete', 'danger').then(ok => {
    if (!ok) return;
    fetch('/api/regions/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) }).then(r => r.json())
      .then(() => { if (editRegion.value && editRegion.value.name === name) editRegion.value = null; loadRegions().then(() => window.slateSyncHosts && window.slateSyncHosts()); fetchRoster(h); }).catch(() => {});
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

// ── components ──────────────────────────────────────────────────────────────────────
function RegionList() {
  const h = focusHost.value, regs = regionsOn(h), e = editRegion.value, newSel = !(e && e.name);
  return html`<div>
    <div class="rppreglist">
      ${regs.map(r => html`<div class=${'rppregrow' + (e && e.name === r.name ? ' sel' : '')} onClick=${() => editRegion.value = r}>
        <span class="rppregname">🖧 ${r.name}</span>
        <span class="rppregmeta">warm ${+r.warm || 0} · ${r.transport || 'tunnel'}${r.sysimage ? ' · ⚙ sysimage' : ''}${r.data_root ? ' · root ' + r.data_root : ''}</span>
        ${(r.status && !r.status.ok) ? html`<span class="rppregst err">⚠ ${r.status.msg}</span>` : null}
        <button class="rppregdel" title="delete this region (reaps its warm workers)" onClick=${ev => { ev.stopPropagation(); deleteRegion(h, r.name); }}>✕</button></div>`)}
      <div class=${'rppregrow rppregnew' + (newSel ? ' sel' : '')} title="create a new region on this host" onClick=${() => editRegion.value = null}>
        <span class="rppregname">＋ New region</span><span class="rppregmeta">a new compute def on ${h}</span></div>
    </div>
    ${regs.length ? null : html`<div class="pddim" style="margin:2px 0 8px">No regions here yet — fill in the form below. Cells target one with a <code>region=&lt;name&gt;</code> tag.</div>`}</div>`;
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
    <div class="rpprow"><label>Transport</label>
      <select class="rpptr" value=${fTr.value} onChange=${ev => fTr.value = ev.target.value}><option value="tunnel">tunnel</option><option value="direct">direct</option></select>
      ${fTr.value === 'direct' ? html`<input class="rppport" type="text" inputmode="numeric" autocomplete="off" placeholder="base port" value=${fPort.value} onInput=${ev => fPort.value = ev.target.value}/>` : null}</div>
    <div class="rpprow"><label>Sysimage</label><label class="rppchk"><input type="checkbox" checked=${fSys.value} onChange=${ev => fSys.value = ev.target.checked}/><span>Use worker sysimage <span class="pddim">faster worker boot — built &amp; kept fresh in the background; needs a C compiler + free RAM on the host</span></span></label></div>
    <div class="rpprow rppsysrow"><label></label><div class="rppsysbox">${sysNote(editing ? e.name : '', fSys.value, editing)}</div></div>
    <div class="rppact"><button class="rppsavereg" title="save this region and reconcile toward its warm count" onClick=${saveRegion}>${editing ? 'Save' : 'Create'}</button></div>
    </div>
    <div class=${'rppmsg' + (rmsg.value && rmsg.value.err ? ' err' : '')}>${rmsg.value ? rmsg.value.text : ''}</div>`;
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
function Focus() {
  const h = focusHost.value;
  if (!h) return null;
  return html`<div>
    <div class="rtfhead"><strong><span class="rtfcrumb" title="back to Remotes" onClick=${() => window.slateUnfocus && window.slateUnfocus()}>Remotes</span> › 🖧 ${h}</strong><span class="rtfsub">— regions &amp; live workers</span></div>
    <${RegionList}/><${Editor}/><${Roster}/></div>`;
}

// ── mount + effects + shell bridges ──────────────────────────────────────────────────
const mnt = document.getElementById('rtfocus');
if (mnt) render(html`<${Focus}/>`, mnt);

effect(() => { const h = focusHost.value; if (h) { loadRegions(); fetchRoster(h); } });   // focus → load
effect(() => {   // seed the editor form from the selected region (or blank for "new")
  const e = editRegion.value, h = focusHost.value; if (!h) return;
  if (e && e.name) { fName.value = e.name; fWarm.value = +e.warm || 0; fPre.value = e.preload || ''; fRoot.value = e.data_root || ''; fTr.value = e.transport || 'tunnel'; fPort.value = e.base_port > 0 ? e.base_port : ''; fSys.value = !!e.sysimage; }
  else { fName.value = ''; fWarm.value = 0; fPre.value = ''; fRoot.value = ''; fTr.value = hostTr(h); fPort.value = ''; fSys.value = false; }
  rmsg.value = null;
});
effect(() => { const e = editRegion.value; if (e && e.name && focusHost.value) loadSysimage(e.name); });   // editing → fetch build status

// Transitional setters the still-vanilla modal shell calls (retire when the shell migrates):
window.__slateFocus = (h) => { editRegion.value = null; focusHost.value = h || ''; };
window.__slateUnfocus = () => { focusHost.value = ''; editRegion.value = null; };
window.__slateSelectRegion = (name) => {
  const pick = () => { const r = regionsOn(focusHost.value).find(x => x.name === name); if (r) editRegion.value = r; };
  const r = regionsOn(focusHost.value).find(x => x.name === name);
  r ? (editRegion.value = r) : loadRegions().then(pick);
};
