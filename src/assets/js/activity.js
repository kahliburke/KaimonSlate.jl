// Worker activity monitor — the FIRST home-page (index.html) Preact island. Opening a worker shows it
// in the telemetry view (telemetry.js), with its actions and manifest.
// Covers every tier a worker can live in: this hub's own kernels (from its facts, model.js) and the
// per-host rosters (/api/remote-workers — region + leftover workers, an ssh probe). Both come in the
// same entry shape, so one row component renders either; only the available ACTIONS differ (see Acts).
// An off-machine kernel is described from both sides and merged on host:port by allEntries(), which is
// also what makes a plain ssh host visible at all, since the per-host probe only ever runs against
// hosts something told us about.
// Replaces the former inline innerHTML render (`_act*` / `rtWd*` in index.html): a poll assigns signals
// and the components follow — no manual re-render or event re-wiring, no innerHTML clobbering. Reuses the
// existing `.act*` / `.wd*` / `.modal*` CSS already in index.html (same class names), so no styles here.
//
// Coordinates with the Remotes modal island (remotes.js) purely through shared signals (stores.js):
// clicking a region group / worker row calls openRegionConfig(host, name) to open the modal focused on
// that region, and sets the shared `detail` signal to open the worker in the telemetry view. That is also
// where a worker is reaped (POST /api/reap-worker) — the same action the Remotes modal roster offers,
// reachable straight from the monitor without hunting for the row again.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { detail, openRegionConfig } from './stores.js';   // shared with the other home-page islands
import { openTelemetry, closeTelemetry } from './telemetry.js';
import { WorkerBar, workerLabel, pending, pj, mergeManifest, ago } from './workerbar.js';
// The liveness/attachment questions, answered once. This island had the careful version and the
// remotes roster had a looser one, so the same worker read green here and grey there. model.js is a
// classic script loaded before every module, so it is always here by the time this runs.
const { isAlive, workerState, mergeWorker } = window.slateModel;

const POLL_MS = 3000;
const regions  = signal([]);     // the region registry, from the facts → [{name,host,warm,status,…}]
const hostData = signal([]);     // per-host live rosters    → [{host, workers:[…]}]
const localW   = signal([]);     // the hub's kernels on this machine, from its facts (roster-shaped)
const nbRemote = signal([]);     // the hub's OFF-MACHINE kernels for open notebooks, from its facts

// `detail` (open worker popup target) is imported from ./stores.js — shared across home-page islands.

let timer = null, inflight = false;

// Compact bytes for the dense monitor rows (K/M/G).
const fmtB = (b) => window.slateBytes(b, { letter: true });

// Clear stopped workers' leftover files. Nothing is running, so nothing is lost and there is no confirm.
const clearing = signal({});   // host:port → true while its clear is in flight
async function clearStopped(xs) {
  const key = x => x.host + ':' + x.w.port;
  clearing.value = Object.assign({}, clearing.value, ...xs.map(x => ({ [key(x)]: true })));
  await Promise.all(xs.map(x => fetch('/api/reap-worker', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ host: x.host, port: +x.w.port }) }).catch(() => null)));
  const done = new Set(xs.map(key));
  hostData.value = hostData.value.map(h => ({ ...h, workers: (h.workers || []).filter(w => !done.has(h.host + ':' + w.port)) }));
  const c = Object.assign({}, clearing.value); done.forEach(k => delete c[k]); clearing.value = c;
  tick();
}

// A group's stopped workers, as one line. Their manifests outlive them until cleared or collected, and
// as full rows they read like activity.
function Stopped({ xs }) {
  const busy = xs.some(x => clearing.value[x.host + ':' + x.w.port]);
  const tip = xs.map(x => {
    const nb = String(pj(x.w.manifest).notebook || '').replace(/#[^#]*$/, '').replace(/\.jl$/, '');
    return ':' + x.w.port + (nb ? ' ' + nb : '') + (x.w.lastActivity ? ' · last seen ' + ago(x.w.lastActivity) : '');
  }).join('\n');
  return html`<div class="actstopped" title=${tip}>
    <span>⚪ ${xs.length} stopped</span>
    <span class="ports">${xs.map(x => ':' + x.w.port).join(' ')}</span>
    <button disabled=${busy} title="remove their leftover files" onClick=${() => clearStopped(xs)}>${busy ? 'Clearing…' : 'Clear'}</button></div>`;
}

// The hub's kernels for open notebooks and the region registry, from the facts (model.js), each
// kernel with its latest sample (which rides the same stream).
function fromFacts() {
  const M = window.slateModel, facts = M.getFacts(), loc = [], rem = [];
  for (const k of Object.keys(facts)) {
    const f = facts[k];
    if (!k.startsWith('worker/') || !f || !(+f.port > 0)) continue;   // a region with no worker yet
    const e = M.asRosterEntry(f), smp = M.sampleOf(k);
    if (smp) { e.stats = smp.stats; e.lastActivity = Math.round(smp.at); }
    (f.host ? rem : loc).push(e);
  }
  localW.value = loc; nbRemote.value = rem;
  regions.value = M.regions();
}
window.slateModel.subscribe(fromFacts);
fromFacts();   // the facts may have landed before this module subscribed

// ── polling ──────────────────────────────────────────────────────────────────────
async function tick() {
  if (inflight || document.hidden) return;
  inflight = true;
  try {
    const M = window.slateModel, regs = M.regions();
    const hs = {}; regs.forEach(p => p.host && (hs[p.host] = 1)); M.parked().forEach(p => hs[filedUnder(p)] = 1);
    // A notebook can be run on any ssh host, with no region defined and nothing parked — the registry
    // would never name that host, so probe the hosts the hub is actually holding kernels on as well.
    // Without this the whole host is unqueried and its workers never appear.
    // Under the name a roster read uses. A scheduler region's kernel names the granted node, and
  // probing that separately reads the same shared directory a second time and lists every worker
  // twice — as well as paying a second ssh round trip for it.
  nbRemote.value.forEach(w => { const h = filedUnder(w); h && (hs[h] = 1); });
    const hosts = Object.keys(hs);
    hostData.value = await Promise.all(hosts.map(h =>
      fetch('/api/remote-workers?host=' + encodeURIComponent(h)).then(r => r.json())
        .then(d => ({ host: h, workers: d.workers || [] })).catch(() => ({ host: h, workers: [] }))));
  } catch (_) {}
  inflight = false;
}
function start() { if (timer) return; tick(); timer = setInterval(tick, POLL_MS); }


// ── merging the two views of an off-machine worker ───────────────────────────────────
// A worker on another machine is described twice, and neither description is complete on its own:
//   • the HOST roster (/api/remote-workers) — the on-disk manifest + telemetry sidecar, and the only
//     view that sees workers this hub isn't connected to (detached, warm-pool, another hub's).
//   • the HUB's own kernels (its facts) — which open notebook is on it right now,
//     available with no ssh, and still answering when the host is unreachable or wrote no manifest.
// Merge on host:port, preferring the host's richer record but taking the live binding from the hub.
// Entries carry `bound` = the hub kernel, i.e. "this is serving an open notebook from here".
// Pure over its two arguments (asserted by test/js/worker_merge.mjs — keep it that way).
// The name a worker is FILED under, which is not always the machine it runs on. A scheduler region's
// worker lives on the granted node, but its manifest sits on the shared filesystem and is probed
// through the login node — so the roster files it under the login host and the hub knows it by the
// node. Keying on the running host alone listed such a worker twice: the hub's live kernel, and the
// roster's stale manifest for the same process, with contradictory verdicts.
// The name a worker is FILED under, which is not always the machine it runs on. A scheduler region's
// worker lives on the granted node, but its manifest sits on the shared filesystem and is read
// through the login node, so that is the name every roster read uses. `viaHost` is present only when
// the two differ.
//
// Used twice, and both uses matter: keying the merge, and deciding which hosts to probe at all.
// Probing the node separately reads the SAME directory over the shared filesystem and returns the
// same manifests under a second name, which is two rows for one worker before the hub kernel is even
// looked at.
const filedUnder = k => k.viaHost || k.host;
function mergeRosters(hostRosters, hubKernels) {
  const mergeKey = (host, port) => String(host) + ':' + String(port);
  const out = [], idx = {};
  (hostRosters || []).forEach(h => (h.workers || []).forEach(w => {
    const e = { w, host: h.host, region: pj(w.manifest).region || '', bound: null };
    idx[mergeKey(h.host, w.port)] = e; out.push(e);
  }));
  (hubKernels || []).forEach(k => {
    const e = idx[mergeKey(filedUnder(k), k.port)];
    // The hub's `host` wins on the merged entry: it names the machine the worker actually runs on,
    // which is what a reap has to address.
    if (e) { e.bound = k; e.region = k.region || ''; e.host = k.host || e.host; return; }
    // Not in any roster: the host probe failed, or (forwarded wire) there is no host to probe.
    // Filed under the same name the roster would use, so a probe that succeeds later matches it.
    const ne = { w: k, host: k.host, region: k.region || '', bound: k };
    idx[mergeKey(filedUnder(k), k.port)] = ne; out.push(ne);
  });
  return out;
}
const allEntries = () => mergeRosters(hostData.value, nbRemote.value);
// The hub's fields win: it names the notebook on the worker NOW, and carries the `nbid` a host manifest
// has no reason to know — which is what makes Restart / Open notebook reachable for a remote worker.

// The entry behind an open popup — same merge, plus this machine's own workers.
function findEntry(host, port) {
  if (host === 'local') {
    const w = localW.value.find(x => +x.port === +port);
    return w ? { w, host, region: '', bound: null } : null;
  }
  return allEntries().find(x => x.host === host && +x.w.port === +port) || null;
}

// ── monitor: one worker row ──────────────────────────────────────────────────────────
function WorkerRow({ w, host, bound }) {
  const st = pj(w.stats), mf = mergeManifest(w, bound);
  // The hub's own kernel outranks the host's `.state` sidecar, which is written by the worker and can
  // lag a reattach — if we hold a live wire to it, it is attached. `mergeWorker` is that precedence,
  // shared so the remotes roster cannot merge the two the other way round.
  const merged = mergeWorker(w, bound);
  const alive = isAlive(merged);
  const state = workerState(merged);
  // A dead worker's telemetry is its LAST sample, written before the process ended. Rendering it in
  // the live columns showed a worker that had been gone for a day or two as burning a quarter of a
  // core on a cluster nobody had touched, which is a alarming way to say "nothing is running here".
  const cpu = (alive && st.cpu !== undefined && st.cpu >= 0) ? st.cpu : null;
  const rss = alive ? st.rss : 0;
  const running = Array.isArray(st.running) ? st.running : [];
  const warm = st.warm || '', warming = warm.indexOf('warming') === 0;
  const nb = mf.notebook ? String(mf.notebook).replace(/#[^#]*$/, '').replace(/\.jl$/, '') : '';
  // A detached worker keeps its manifest, so it still knows the notebook it LAST served — show it
  // (with ↩, dimmed) rather than a bare "idle": that notebook reattaches straight back to this worker,
  // which is exactly what the row needs to convey. A warm-pool worker never served one → plain "idle".
  // A worker the hub holds a kernel for is never "detached" — with no wire yet it is mid-connect, so it
  // names its notebook plainly rather than claiming a reattach that hasn't happened.
  const runTxt = !alive ? 'dead' : running.length ? ('▶ ' + running.join(', ')) : warming ? ('⏳ ' + warm)
    : warm.indexOf('ready') === 0 ? ('✓ ' + warm)
    : (state === 'attached' || bound) ? (nb || 'idle') : (nb ? '↩ ' + nb : 'idle');
  const runTip = !alive
    // WHEN it died is what makes a dead row readable as leftovers rather than as something wrong
    // right now. Its manifest outlives it, which is the only reason the row is here at all.
    ? 'process is gone' + (w.lastActivity ? ' · last seen ' + ago(w.lastActivity) : '') +
      (nb ? ' · last served ' + nb : '') + ' — reaping clears its leftover files'
    : (state !== 'attached' && !bound && nb && !running.length && !warm)
    ? 'detached from ' + nb + (w.stateSince ? ' · idle since ' + ago(w.stateSince) : '') + ' — reopening it reattaches here'
    : runTxt;
  const cpuPct = cpu == null ? 0 : (cpu <= 0 ? 0 : Math.max(5, Math.min(100, cpu)));
  const barCol = cpu >= 85 ? '#e5636e' : cpu >= 50 ? '#e8a13f' : '#3fb96e';
  return html`<div class="actrow" title="worker details + history" style="cursor:pointer"
      onClick=${() => { detail.value = { host, port: +w.port }; }}>
    <span class="actlabel"><span class="actwho">${alive ? '🟢' : '⚪'} :${w.port}</span>
      <span class="actbadge ${state}">${state}</span></span>
    <span class="actbar">${(cpu == null || cpuPct <= 0) ? null : html`<span class="actbarf" style=${`width:${cpuPct}%;background-color:${barCol}`}></span>`}</span>
    <span class="actcpun">${cpu == null ? '—' : cpu + '%'}</span>
    <span class="actrss">${rss ? fmtB(rss) : '—'}</span>
    <span class="actrun ${(runTxt === 'idle' || runTxt.charAt(0) === '↩') ? 'idle' : ''}" title=${runTip}>${runTxt}</span></div>`;
}

// ── monitor panel ──────────────────────────────────────────────────────────────────
function Monitor() {
  const regs = regions.value, lw = localW.value;
  const all = allEntries(), mine = lw.map(w => ({ w, host: 'local', region: '', bound: null }));
  // Local workers get their OWN group rather than folding into the untagged bucket — they're a different
  // tier (bound to an open notebook, not adoptable, no manifest on a host) and the actions differ.
  // Same for a notebook RUN ON a host with no region: it's a notebook's kernel that merely lives
  // elsewhere, so it belongs next to "this machine", not in the anonymous leftovers bucket.
  const byRegion = {}, byNbHost = {};
  all.forEach(x => (x.bound && !x.region ? (byNbHost[x.host] = byNbHost[x.host] || [])
                                         : (byRegion[x.region] = byRegion[x.region] || [])).push(x));
  let totRss = 0, busy = 0; const shown = {}; const groups = [];
  const rows = (xs) => xs.map(x => {
    // Only what is actually resident counts: a dead worker's last sample is not memory in use, and
    // summing it made the footer's total describe a machine that no longer exists.
    const st = pj(x.w.stats); totRss += st.rss || 0;
    const running = Array.isArray(st.running) ? st.running : [];
    if (running.length > 0 || (st.evals || 0) > 0 || (st.warm || '').indexOf('warming') === 0) busy++;
    return html`<${WorkerRow} w=${x.w} host=${x.host} bound=${x.bound}/>`;
  });
  const live = x => isAlive(mergeWorker(x.w, x.bound));
  const group = (head, xs) => {
    const up = xs.filter(live), down = xs.filter(x => !live(x));
    return html`<div>${head}${up.length ? rows(up) : down.length ? null : html`<div class="actempty">no workers</div>`}
      ${down.length ? html`<${Stopped} xs=${down}/>` : null}</div>`;
  };
  // This machine first — it's the tier you're always running on, whether or not any host is configured.
  if (mine.length) groups.push(group(html`<div class="actgrouphd">💻 <span class="actgroupname" style="cursor:default">this machine</span>
    <span class="actgrouphost">${mine.length} notebook worker${mine.length !== 1 ? 's' : ''} · killed when the notebook closes</span></div>`, mine));
  // Then the notebooks running ON a host — one group per host. These aren't region workers: they were
  // spawned because a notebook's run-on target is that machine, so they're named by host, not region,
  // and there may be no region defined there at all.
  Object.keys(byNbHost).sort().forEach(hn => {
    const xs = byNbHost[hn];
    groups.push(group(html`<div class="actgrouphd">🖥 <span class="actgroupname" style="cursor:default">${hn || 'forwarded wire'}</span>
      <span class="actgrouphost">${xs.length} notebook worker${xs.length !== 1 ? 's' : ''} · ${hn ? 'run-on host' : 'attached, hub-unmanaged'}</span></div>`, xs));
  });
  // Registry regions first (sorted) — with host / warm / reconcile status; skip a bare def with nothing live/warm/failed.
  regs.slice().sort((a, b) => (a.name || '').localeCompare(b.name || '')).forEach(rg => {
    shown[rg.name] = 1;
    const xs = byRegion[rg.name] || [], err = rg.status && rg.status.ok === false;
    if (!xs.length && !(rg.warm > 0) && !err) return;
    const head = html`<div class=${'actgrouphd' + (err ? ' err' : '')}>
      <span class="actgroupname" title="open this region's config" onClick=${() => openRegionConfig(rg.host, rg.name)}>${window.slateModel.regionIcon(rg)} ${rg.name}</span> <span class="actgrouphost">${rg.host || '(no host)'}</span>
      ${rg.warm > 0 ? html` <span class="actgroupwarm">warm ${rg.warm}</span>` : null}
      ${err ? html` <span class="actgrouperr" title=${rg.status.msg}>⚠ reconcile failed</span>` : null}</div>`;
    groups.push(group(head, xs));
  });
  // Region tags with no registry def, then untagged workers.
  Object.keys(byRegion).sort().forEach(name => {
    if (name === '' || shown[name]) return;
    const head = html`<div class="actgrouphd">🖧 ${name} <span class="actgrouphost">${(byRegion[name][0] || {}).host || ''} · not in registry</span></div>`;
    groups.push(group(head, byRegion[name]));
  });
  if (byRegion[''] && byRegion[''].length) groups.push(group(html`<div class="actgrouphd">💻 other workers</div>`, byRegion['']));

  if (!groups.length) return null;   // nothing → collapse (index.html hides an empty #actmon)
  const nW = all.filter(live).length + mine.length;
  return html`<h2 class="sect">Worker activity</h2><div class="actmon-body">
    <div class="actagg">${nW} worker${nW !== 1 ? 's' : ''} · ${fmtB(totRss)} · ${busy} busy <span class="actlive">●</span></div>
    ${groups}</div>`;
}

// ── worker detail: the telemetry view ──────────────────────────────────────────────────
// Opening a worker (`detail`, also set by the remotes roster) opens the telemetry view with the
// worker's bar (workerbar.js) above the charts, read from the roster on every render so it follows
// the polls while the view is open.
function done(kind, host, port) {
  // Reaped: drop it from the host's roster so its row goes now rather than at the next probe. What
  // the hub knows about the worker arrives through the facts.
  if (kind === 'reaped' && host !== 'local')
    hostData.value = hostData.value.map(h => h.host === host ? { ...h, workers: (h.workers || []).filter(x => +x.port !== +port) } : h);
  detail.value = null;
  tick();
}

function WorkerDetail() {
  const d = detail.value;
  useEffect(() => {
    if (!d) return;
    pending.value = null;   // a different worker clears any stale in-flight/error state
    const e = findEntry(d.host, d.port), mf = e ? mergeManifest(e.w, e.bound) : {};
    openTelemetry({
      side: mf.side && mf.side !== 'local' ? mf.side : '', host: d.host === 'local' ? '' : d.host, port: d.port,
      label: workerLabel(mf, d.port),
      actions: () => html`<${WorkerBar} host=${d.host} port=${d.port} entry=${findEntry(d.host, d.port)}
        onRegion=${(name) => { detail.value = null; openRegionConfig(d.host, name); }} onDone=${done}/>`,
      onClose: () => { if (detail.value === d) detail.value = null; } });
    // Cleared from outside (a reap, a region link): the view goes with it.
    return () => { if (detail.value !== d) closeTelemetry(); };
  }, [d]);
  return null;
}

// ── mount ────────────────────────────────────────────────────────────────────────────
// Not on an app. This monitor is about WHERE work runs — regions, hosts, warm pools — which is an
// operator's question, and its UI is authoring chrome the reading view hides anyway. Left mounted it
// would probe every region host over ssh on a timer
// forever, and every one of those is refused: a console full of 403s, restarting every POLL_MS, on a
// page where nothing can act on the answer. An app's operator view is `/status`.
if (!(window.__SLATE_APP__ && window.__SLATE_APP__.on)) {
  const mon = document.getElementById('actmon');
  if (mon) render(html`<${Monitor}/>`, mon);
  const popHost = document.createElement('div');
  document.body.appendChild(popHost);
  render(html`<${WorkerDetail}/>`, popHost);

  start();
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
  window.addEventListener('pageshow', () => tick());
}
