// Worker activity monitor + worker-detail popup — the FIRST home-page (index.html) Preact island.
// Covers every tier a worker can live in: this machine (/api/local-workers — one per open notebook), the
// per-host rosters (/api/remote-workers — region + leftover workers, an ssh probe), and the hub's own
// off-machine kernels (/api/remote-notebook-workers — a notebook whose run-on target is another machine).
// All three return the same entry shape, so one row component renders any of them; only the available
// ACTIONS differ (see Acts). The last two describe the same processes from different sides and are merged
// on host:port by allEntries() — which is also what makes a plain ssh host visible at all, since the
// per-host probe only ever runs against hosts something told us about.
// Replaces the former inline innerHTML render (`_act*` / `rtWd*` in index.html): a poll assigns signals
// and the components follow — no manual re-render or event re-wiring, no innerHTML clobbering. Reuses the
// existing `.act*` / `.wd*` / `.modal*` CSS already in index.html (same class names), so no styles here.
//
// Coordinates with the Remotes modal island (remotes.js) purely through shared signals (stores.js):
// clicking a region group / worker row calls openRegionConfig(host, name) to open the modal focused on
// that region, and sets the shared `detail` signal to open the worker-detail popup. The popup is also
// where a worker is reaped (POST /api/reap-worker) — the same action the Remotes modal roster offers,
// reachable straight from the monitor without hunting for the row again.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { detail, openRegionConfig } from './stores.js';   // shared with the other home-page islands

const POLL_MS = 3000;
const regions  = signal([]);     // /api/regions            → [{name,host,warm,status,…}]
const hostData = signal([]);     // per-host live rosters    → [{host, workers:[…]}]
const localW   = signal([]);     // /api/local-workers       → this machine's workers (same entry shape)
const nbRemote = signal([]);     // /api/remote-notebook-workers → the hub's OFF-MACHINE kernels for open notebooks
const history  = signal([]);     // /api/worker-stats samples for the open worker
const reaping  = signal(null);   // {port, err?} — in-flight / failed reap for the open popup
// `detail` (open worker popup target) is imported from ./stores.js — shared across home-page islands.

let timer = null, inflight = false;

const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
// Compact bytes for the dense monitor rows (K/M/G); a longer form for the roomier popup (B/KB/MB/GB).
const fmtB = (b) => (b = +b || 0, b < 1048576 ? Math.round(b / 1024) + 'K' : b < 1073741824 ? Math.round(b / 1048576) + 'M' : (b / 1073741824).toFixed(1) + 'G');
const fmtB2 = (b) => (b = +b || 0, b < 1024 ? b + 'B' : b < 1048576 ? Math.round(b / 1024) + 'KB' : b < 1073741824 ? Math.round(b / 1048576) + 'MB' : (b / 1073741824).toFixed(1) + 'GB');
const ago = (unix) => { let s = Math.max(0, Math.floor(Date.now() / 1000 - (+unix || 0))); return s < 90 ? s + 's ago' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 172800 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };
const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));

// ── reap ─────────────────────────────────────────────────────────────────────────
// Kill a worker + remove its files. Always confirmed and never automatic: a worker may hold results
// nobody has fetched yet, so the human decides. The hub drops any live kernel bound to it first, so an
// attached notebook wakes with an error instead of hanging on a dead wire.
async function reapWorker(host, w, bound) {
  const mf = mergeManifest(w, bound), port = +w.port;
  const nb = mf.notebook ? '\nIt is serving “' + String(mf.notebook).replace(/#[^#]*$/, '') + '”' +
    (((bound && bound.state) || w.state) === 'attached' ? ' and is ATTACHED — that notebook loses its kernel.' : '.') : '';
  if (!await confirmP('Reap worker :' + port + ' on ' + host + '?' + nb +
      '\nThis kills the process and removes its files — any un-fetched results are lost.', 'Reap', 'danger')) return;
  reaping.value = { port };
  try {
    const r = await fetch('/api/reap-worker', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ host, port }) }).then(r => r.json());
    if (!r || r.ok === false) { reaping.value = { port, err: 'reap failed — the worker may already be gone, or the host is unreachable' }; return; }
    // Gone: drop it from the roster so the monitor row disappears now rather than at the next poll.
    hostData.value = hostData.value.map(h => h.host === host ? { ...h, workers: (h.workers || []).filter(x => +x.port !== port) } : h);
    reaping.value = null; detail.value = null;
    tick();
  } catch (_) { reaping.value = { port, err: 'request failed' }; }
}

// Restart a worker that is serving an open notebook, from the home page — wherever it runs. Same route
// the notebook's own Restart uses (`side` targets a region kernel, empty the main one), so the open tab
// follows along over its own feed. It re-runs the notebook, which is not what a home-page click implies
// on its own — hence the confirm.
async function restartWorker(w, bound) {
  const mf = mergeManifest(w, bound), port = +w.port, side = mf.side === 'local' ? '' : (mf.side || '');
  if (!mf.nbid) return;
  if (!await confirmP('Restart the ' + (side ? 'region “' + side + '” worker' : 'worker') + ' for “' + (mf.notebook || mf.nbid) +
      '”?\nIts process is killed and the notebook re-runs from a fresh namespace.', 'Restart')) return;
  reaping.value = { port };
  try {
    const res = await fetch('/api/' + encodeURIComponent(mf.nbid) + '/restart', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ side }) });
    if (!res.ok) { reaping.value = { port, err: 'restart failed (' + res.status + ')' }; return; }
    reaping.value = null; detail.value = null;
    tick();
  } catch (_) { reaping.value = { port, err: 'request failed' }; }
}

// ── polling ──────────────────────────────────────────────────────────────────────
async function tick() {
  if (inflight || document.hidden) return;
  inflight = true;
  try {
    const [d, lw, rw] = await Promise.all([
      fetch('/api/regions').then(r => r.json()),
      fetch('/api/local-workers').then(r => r.json()).catch(() => null),
      fetch('/api/remote-notebook-workers').then(r => r.json()).catch(() => null)]);
    if (lw) localW.value = lw.workers || [];
    if (rw) nbRemote.value = rw.workers || [];
    const regs = d.regions || [];
    regions.value = regs;
    const hs = {}; regs.forEach(p => p.host && (hs[p.host] = 1)); (d.parked || []).forEach(p => hs[p.host] = 1);
    // A notebook can be run on any ssh host, with no region defined and nothing parked — the registry
    // would never name that host, so probe the hosts the hub is actually holding kernels on as well.
    // Without this the whole host is unqueried and its workers never appear.
    nbRemote.value.forEach(w => w.host && (hs[w.host] = 1));
    const hosts = Object.keys(hs);
    hostData.value = await Promise.all(hosts.map(h =>
      fetch('/api/remote-workers?host=' + encodeURIComponent(h)).then(r => r.json())
        .then(d => ({ host: h, workers: d.workers || [] })).catch(() => ({ host: h, workers: [] }))));
    if (detail.value) {
      const { host, port } = detail.value;
      // A forwarded wire (an attached `remoteworker`) has no host to ask — its telemetry is in the hub's
      // own ring, which is what host="local" resolves by port.
      const s = await fetch('/api/worker-stats?host=' + encodeURIComponent(host || 'local') + '&port=' + port).then(r => r.json()).catch(() => null);
      if (detail.value && detail.value.host === host && detail.value.port === port) history.value = (s && s.samples) || [];
    }
  } catch (_) {}
  inflight = false;
}
function start() { if (timer) return; tick(); timer = setInterval(tick, POLL_MS); }

// ── sparkline ──────────────────────────────────────────────────────────────────────
const fmtSpan = (s) => (s = Math.max(0, Math.round(s)), s < 90 ? s + 's' : s < 5400 ? Math.round(s / 60) + 'm' : Math.round(s / 3600) + 'h');
// Sparkline. Renders even with 0–1 real samples: a `now` fallback seeds a single reading so the CURRENT
// value shows immediately (a dashed flat line) — you don't wait for history to accumulate to see live data.
function Spark({ samples, get, color, min, max, now }) {
  const vals = samples.map(get);
  if (!vals.length && now != null && now >= 0) vals.push(now);
  const n = vals.length;
  if (!n) return html`<div class="wdnodata">no data yet</div>`;
  const W = 580, H = 64, pad = 5;
  let mx = (max != null) ? max : Math.max(...vals), mn = (min != null) ? min : Math.min(...vals);
  if (mx <= mn) mx = mn + 1;
  const y = (v) => (pad + (H - 2 * pad) * (1 - (Math.max(mn, Math.min(mx, v)) - mn) / (mx - mn))).toFixed(1);
  if (n === 1) {   // one reading → a dashed flat line (a single point, not yet a trend)
    const yy = y(vals[0]);
    return html`<svg class="wdsvg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"><line x1=${pad} y1=${yy} x2=${W - pad} y2=${yy} stroke=${color} stroke-width="1.5" stroke-dasharray="3 4" vector-effect="non-scaling-stroke"/></svg>`;
  }
  const pts = vals.map((v, i) => (pad + (W - 2 * pad) * (i / (n - 1))).toFixed(1) + ',' + y(v)).join(' ');
  return html`<svg class="wdsvg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    <polyline points=${pts} fill="none" stroke=${color} stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>`;
}

// ── merging the two views of an off-machine worker ───────────────────────────────────
// A worker on another machine is described twice, and neither description is complete on its own:
//   • the HOST roster (/api/remote-workers) — the on-disk manifest + telemetry sidecar, and the only
//     view that sees workers this hub isn't connected to (detached, warm-pool, another hub's).
//   • the HUB's own kernels (/api/remote-notebook-workers) — which open notebook is on it right now,
//     available with no ssh, and still answering when the host is unreachable or wrote no manifest.
// Merge on host:port, preferring the host's richer record but taking the live binding from the hub.
// Entries carry `bound` = the hub kernel, i.e. "this is serving an open notebook from here".
// Pure over its two arguments (asserted by test/js/worker_merge.mjs — keep it that way).
function mergeRosters(hostRosters, hubKernels) {
  const out = [], idx = {};
  (hostRosters || []).forEach(h => (h.workers || []).forEach(w => {
    const e = { w, host: h.host, region: pj(w.manifest).region || '', bound: null };
    idx[h.host + ':' + w.port] = e; out.push(e);
  }));
  (hubKernels || []).forEach(k => {
    const e = idx[k.host + ':' + k.port];
    if (e) { e.bound = k; e.region = k.region || ''; return; }
    // Not in any roster: the host probe failed, or (forwarded wire) there is no host to probe.
    const ne = { w: k, host: k.host, region: k.region || '', bound: k };
    idx[k.host + ':' + k.port] = ne; out.push(ne);
  });
  return out;
}
const allEntries = () => mergeRosters(hostData.value, nbRemote.value);
// The hub's fields win: it names the notebook on the worker NOW, and carries the `nbid` a host manifest
// has no reason to know — which is what makes Restart / Open notebook reachable for a remote worker.
const mergeManifest = (w, bound) => Object.assign({}, pj(w && w.manifest), bound ? pj(bound.manifest) : {});

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
  const alive = w.alive !== false;
  // The hub's own kernel outranks the host's `.state` sidecar, which is written by the worker and can
  // lag a reattach — if we hold a live wire to it, it is attached.
  const rawState = (bound && bound.state) || w.state;
  const state = !alive ? 'dead' : (rawState === 'attached' ? 'attached' : 'idle');
  const cpu = (st.cpu !== undefined && st.cpu >= 0) ? st.cpu : null;
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
  const runTip = (state !== 'attached' && !bound && nb && !running.length && !warm)
    ? 'detached from ' + nb + (w.stateSince ? ' · idle since ' + ago(w.stateSince) : '') + ' — reopening it reattaches here'
    : runTxt;
  const cpuPct = cpu == null ? 0 : (cpu <= 0 ? 0 : Math.max(5, Math.min(100, cpu)));
  const barCol = cpu >= 85 ? '#e5636e' : cpu >= 50 ? '#e8a13f' : '#3fb96e';
  return html`<div class="actrow" title="worker details + history" style="cursor:pointer"
      onClick=${() => { detail.value = { host, port: +w.port }; history.value = []; tick(); }}>
    <span class="actlabel"><span class="actwho">${alive ? '🟢' : '⚪'} :${w.port}</span>
      <span class="actbadge ${state}">${state}</span></span>
    <span class="actbar">${(cpu == null || cpuPct <= 0) ? null : html`<span class="actbarf" style=${`width:${cpuPct}%;background-color:${barCol}`}></span>`}</span>
    <span class="actcpun">${cpu == null ? '—' : cpu + '%'}</span>
    <span class="actrss">${st.rss ? fmtB(st.rss) : '—'}</span>
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
    const st = pj(x.w.stats); totRss += st.rss || 0;
    const running = Array.isArray(st.running) ? st.running : [];
    if (x.w.alive !== false && (running.length > 0 || (st.evals || 0) > 0 || (st.warm || '').indexOf('warming') === 0)) busy++;
    return html`<${WorkerRow} w=${x.w} host=${x.host} bound=${x.bound}/>`;
  });
  const group = (head, xs) => html`<div>${head}${xs.length ? rows(xs) : html`<div class="actempty">no workers</div>`}</div>`;
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
      <span class="actgroupname" title="open this region's config" onClick=${() => openRegionConfig(rg.host, rg.name)}>🖧 ${rg.name}</span> <span class="actgrouphost">${rg.host || '(no host)'}</span>
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
  const nW = all.length + mine.length;
  return html`<h2 class="sect">Worker activity</h2><div class="actmon-body">
    <div class="actagg">${nW} worker${nW !== 1 ? 's' : ''} · ${fmtB(totRss)} · ${busy} busy <span class="actlive">●</span></div>
    ${groups}</div>`;
}

// ── worker detail popup: action footer ───────────────────────────────────────────────
// Actions follow the worker's CAPABILITIES, not its tier. Two independent questions:
//   • is an open notebook on it (a `nbid`)? → Restart / Open notebook are meaningful.
//   • is it on a host we can reach? → Reap is meaningful (a local worker dies with its notebook, and a
//     forwarded wire has no host, so neither is reapable).
// A notebook run ON a host answers yes to both, which is why this isn't a local/remote switch.
function Acts({ host, w, bound, isLocal }) {
  const r = reaping.value && reaping.value.port === +w.port ? reaping.value : null;
  const busy = !!(r && !r.err);
  const mf = mergeManifest(w, bound);
  const canReap = !isLocal && !!host;
  const note = r && r.err ? html`<span class="wdacterr">⚠ ${r.err}</span>`
    : isLocal ? 'Bound to an open notebook — it exits when that notebook closes.'
    : !mf.nbid ? (w.alive === false ? 'Not running — reaping clears its leftover files on ' + host + '.'
                                    : 'Reaping kills the process and removes its files on ' + host + '.')
    : canReap ? 'Serving an open notebook on ' + host + '. Reaping kills it and that notebook loses its kernel.'
              : 'An already-running worker this hub attached to — it outlives the notebook and the hub does not manage it.';
  return html`<div class="wdacts">
    <span class="wdactnote">${note}</span>
    ${mf.nbid ? html`<button class="rppsysbtn" disabled=${busy} title="restart this worker and re-run the notebook"
      onClick=${() => restartWorker(w, bound)}>${busy ? 'Restarting…' : 'Restart worker'}</button>
    <button class="rppsysbtn" title="open this notebook"
      onClick=${() => { window.location.href = '/n/' + encodeURIComponent(mf.nbid); }}>Open notebook</button>` : null}
    ${canReap ? html`<button class="rppreap" disabled=${busy} title="kill this worker + remove its files"
      onClick=${() => reapWorker(host, w, bound)}>${busy ? 'Reaping…' : 'Reap worker'}</button>` : null}</div>`;
}

// ── worker detail popup ──────────────────────────────────────────────────────────────
function WorkerDetail() {
  const d = detail.value;
  useEffect(() => {
    reaping.value = null;   // a different worker (or a close) clears any stale in-flight/error state
    if (!d) return;
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); detail.value = null; } };
    document.addEventListener('keydown', onKey, true);
    return () => document.removeEventListener('keydown', onKey, true);
  }, [d]);
  if (!d) return null;
  const host = d.host, isLocal = host === 'local';
  const e = findEntry(host, d.port), w = e && e.w, bound = e && e.bound;
  const close = () => { detail.value = null; };
  const body = () => {
    if (!w) return html`<div class="wdnodata">worker :${d.port} is no longer on ${isLocal ? 'this machine' : (host || 'that wire')}.</div>`;
    const mf = mergeManifest(w, bound), st = pj(w.stats), samples = history.value;
    const rows = [];
    const row = (k, v, region) => { if (v == null || v === '') return; rows.push(html`<div class="k">${k}</div><div class=${'v' + (region ? ' link' : '')} onClick=${region ? (() => { const rn = region; close(); openRegionConfig(host, rn); }) : null} style=${region ? 'cursor:pointer' : ''}>${String(v)}</div>`); };
    // A worker bound to an open notebook — on this machine or on a host — has a manifest that can't be
    // stale. Only an unbound remote one can be detached, in which case it names the notebook it LAST
    // served, which must not read as "serving now".
    const state = (bound && bound.state) || w.state;
    const det = !isLocal && !bound && state !== 'attached';
    row('Host', isLocal ? 'this machine' : (host || 'forwarded wire (no host)'));
    if (mf.region) row('Region', mf.region, mf.region);
    row(det ? 'Last notebook' : 'Notebook', mf.notebook);
    if (mf.side && mf.side !== 'local') row('Region kernel', mf.side);
    if (det && w.stateSince) row('Detached', ago(w.stateSince));
    if (isLocal && mf.pid) row('PID', mf.pid);
    row('Transport', mf.transport); row('Project', mf.project);
    row('Ports', ':' + w.port + (mf.stream_port ? ' · stream :' + mf.stream_port : '')); row('Spawned', mf.spawned);
    const chip = (l, v) => (v == null || v === '') ? null : html`<div class="wdstat"><span class="l">${l}</span><b>${String(v)}</b></div>`;
    const cpuNow = samples.length ? samples[samples.length - 1].cpu : (st.cpu != null ? st.cpu : -1);
    const rssNow = samples.length ? samples[samples.length - 1].rss : (st.rss || 0);
    const span = samples.length >= 2 ? (samples[samples.length - 1].t - samples[0].t) : 0;   // window covered (s)
    const axis = html`<div class="wdaxis"><span>${span > 0 ? '−' + fmtSpan(span) : ''}</span><span>now</span></div>`;
    return html`
      <div class="wdhead"><strong>${w.alive !== false ? '🟢' : '⚪'} :${w.port}</strong>
        <span class="wdsub">${(state || '') + (mf.region ? ' · ' + mf.region : '')}</span></div>
      <div class="wdgrid">${rows}</div>
      ${(det && mf.notebook && w.alive !== false) ? html`<div class="wdhint">Detached but still warm — its namespace, loaded packages and memo store survive. Reopening that notebook on this host reattaches to this worker instead of paying a cold boot.${mf.region ? ' Until then its region can hand it to another notebook with the same env.' : ' No other notebook will reuse it, so reap it if you are done with that one.'}</div>` : null}
      <div class="wdstats">
        ${st.cpu >= 0 ? chip('CPU', st.cpu + '%') : null} ${st.rss ? chip('RSS', fmtB2(st.rss)) : null}
        ${st.memo_bytes > 0 ? chip('Memo store', fmtB2(st.memo_bytes)) : null}
        ${st.running !== undefined ? chip('Running', (st.running && st.running.length) || 0) : null}
        ${st.sys_cpu >= 0 ? chip('Host CPU', st.sys_cpu + '%') : null} ${st.load1 >= 0 ? chip('Load', st.load1) : null}
        ${st.sys_mem_total ? chip('Host mem', fmtB2(st.sys_mem_total - (st.sys_mem_free || 0)) + ' / ' + fmtB2(st.sys_mem_total)) : null}</div>
      <div class="wdchart"><div class="wdchtitle"><span>CPU %</span><b>${cpuNow >= 0 ? cpuNow + '%' : '—'}</b></div>
        <${Spark} samples=${samples} now=${cpuNow} get=${(s) => Math.max(0, s.cpu)} color="#4f7cf0" min=${0} max=${100}/>${axis}</div>
      <div class="wdchart"><div class="wdchtitle"><span>Memory (RSS)</span><b>${fmtB2(rssNow)}</b></div>
        <${Spark} samples=${samples} now=${rssNow} get=${(s) => s.rss} color="#3fb96e" min=${0}/>${axis}</div>
      ${samples.length < 2 ? html`<div class="pddim" style="font-size:.72rem;margin-top:2px">History builds as the hub receives telemetry from this worker${state !== 'attached' ? ' — only an attached worker streams in.' : '.'}</div>` : null}
      <${Acts} host=${host} w=${w} bound=${bound} isLocal=${isLocal}/>`;
  };
  return html`<div class="modal-bg show" onMouseDown=${(e) => { if (e.target.classList.contains('modal-bg')) close(); }}>
    <div class="modal wdmodal"><button class="modalx" title="Close (Esc)" onClick=${close}>✕</button>
      <div>${body()}</div></div></div>`;
}

// ── mount ────────────────────────────────────────────────────────────────────────────
const mon = document.getElementById('actmon');
if (mon) render(html`<${Monitor}/>`, mon);
const popHost = document.createElement('div');
document.body.appendChild(popHost);
render(html`<${WorkerDetail}/>`, popHost);

start();
document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
window.addEventListener('pageshow', () => tick());
