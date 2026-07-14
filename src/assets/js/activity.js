// Remote activity monitor + worker-detail popup — the FIRST home-page (index.html) Preact island.
// Replaces the former inline innerHTML render (`_act*` / `rtWd*` in index.html): a poll assigns signals
// and the components follow — no manual re-render or event re-wiring, no innerHTML clobbering. Reuses the
// existing `.act*` / `.wd*` / `.modal*` CSS already in index.html (same class names), so no styles here.
//
// Coordinates with the Remotes modal island (remotes.js) purely through shared signals (stores.js):
// clicking a region group / worker row calls openRegionConfig(host, name) to open the modal focused on
// that region, and sets the shared `detail` signal to open the worker-detail popup.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { detail, openRegionConfig } from './stores.js';   // shared with the other home-page islands

const POLL_MS = 3000;
const regions  = signal([]);     // /api/regions            → [{name,host,warm,status,…}]
const hostData = signal([]);     // per-host live rosters    → [{host, workers:[…]}]
const history  = signal([]);     // /api/worker-stats samples for the open worker
// `detail` (open worker popup target) is imported from ./stores.js — shared across home-page islands.

let timer = null, inflight = false;

const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
// Compact bytes for the dense monitor rows (K/M/G); a longer form for the roomier popup (B/KB/MB/GB).
const fmtB = (b) => (b = +b || 0, b < 1048576 ? Math.round(b / 1024) + 'K' : b < 1073741824 ? Math.round(b / 1048576) + 'M' : (b / 1073741824).toFixed(1) + 'G');
const fmtB2 = (b) => (b = +b || 0, b < 1024 ? b + 'B' : b < 1048576 ? Math.round(b / 1024) + 'KB' : b < 1073741824 ? Math.round(b / 1048576) + 'MB' : (b / 1073741824).toFixed(1) + 'GB');
const ago = (unix) => { let s = Math.max(0, Math.floor(Date.now() / 1000 - (+unix || 0))); return s < 90 ? s + 's ago' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 172800 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };

// ── polling ──────────────────────────────────────────────────────────────────────
async function tick() {
  if (inflight || document.hidden) return;
  inflight = true;
  try {
    const d = await fetch('/api/regions').then(r => r.json());
    const regs = d.regions || [];
    regions.value = regs;
    const hs = {}; regs.forEach(p => p.host && (hs[p.host] = 1)); (d.parked || []).forEach(p => hs[p.host] = 1);
    const hosts = Object.keys(hs);
    hostData.value = await Promise.all(hosts.map(h =>
      fetch('/api/remote-workers?host=' + encodeURIComponent(h)).then(r => r.json())
        .then(d => ({ host: h, workers: d.workers || [] })).catch(() => ({ host: h, workers: [] }))));
    if (detail.value) {
      const { host, port } = detail.value;
      const s = await fetch('/api/worker-stats?host=' + encodeURIComponent(host) + '&port=' + port).then(r => r.json()).catch(() => null);
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

// ── monitor: one worker row ──────────────────────────────────────────────────────────
function WorkerRow({ w, host }) {
  const st = pj(w.stats), mf = pj(w.manifest);
  const alive = w.alive !== false;
  const state = !alive ? 'dead' : (w.state === 'attached' ? 'attached' : 'idle');
  const cpu = (st.cpu !== undefined && st.cpu >= 0) ? st.cpu : null;
  const running = Array.isArray(st.running) ? st.running : [];
  const warm = st.warm || '', warming = warm.indexOf('warming') === 0;
  const nb = (state === 'attached' && mf.notebook) ? String(mf.notebook).replace(/#[^#]*$/, '').replace(/\.jl$/, '') : '';
  const runTxt = !alive ? 'dead' : running.length ? ('▶ ' + running.join(', ')) : warming ? ('⏳ ' + warm) : warm.indexOf('ready') === 0 ? ('✓ ' + warm) : (nb || 'idle');
  const cpuPct = cpu == null ? 0 : (cpu <= 0 ? 0 : Math.max(5, Math.min(100, cpu)));
  const barCol = cpu >= 85 ? '#e5636e' : cpu >= 50 ? '#e8a13f' : '#3fb96e';
  return html`<div class="actrow" title="worker details + history" style="cursor:pointer"
      onClick=${() => { detail.value = { host, port: +w.port }; history.value = []; tick(); }}>
    <span class="actlabel"><span class="actwho">${alive ? '🟢' : '⚪'} :${w.port}</span>
      <span class="actbadge ${state}">${state}</span></span>
    <span class="actbar">${(cpu == null || cpuPct <= 0) ? null : html`<span class="actbarf" style=${`width:${cpuPct}%;background-color:${barCol}`}></span>`}</span>
    <span class="actcpun">${cpu == null ? '—' : cpu + '%'}</span>
    <span class="actrss">${st.rss ? fmtB(st.rss) : '—'}</span>
    <span class="actrun ${runTxt === 'idle' ? 'idle' : ''}" title=${runTxt}>${runTxt}</span></div>`;
}

// ── monitor panel ──────────────────────────────────────────────────────────────────
function Monitor() {
  const regs = regions.value, hd = hostData.value;
  const all = [];
  hd.forEach(h => (h.workers || []).forEach(w => all.push({ w, host: h.host, region: pj(w.manifest).region || '' })));
  const byRegion = {}; all.forEach(x => (byRegion[x.region] = byRegion[x.region] || []).push(x));
  let totRss = 0, busy = 0; const shown = {}; const groups = [];
  const rows = (xs) => xs.map(x => {
    const st = pj(x.w.stats); totRss += st.rss || 0;
    const running = Array.isArray(st.running) ? st.running : [];
    if (x.w.alive !== false && (running.length > 0 || (st.evals || 0) > 0 || (st.warm || '').indexOf('warming') === 0)) busy++;
    return html`<${WorkerRow} w=${x.w} host=${x.host}/>`;
  });
  const group = (head, xs) => html`<div>${head}${xs.length ? rows(xs) : html`<div class="actempty">no workers</div>`}</div>`;
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
  const nW = all.length;
  return html`<h2 class="sect">Remote activity</h2><div class="actmon-body">
    <div class="actagg">${nW} worker${nW !== 1 ? 's' : ''} · ${fmtB(totRss)} · ${busy} busy <span class="actlive">●</span></div>
    ${groups}</div>`;
}

// ── worker detail popup ──────────────────────────────────────────────────────────────
function WorkerDetail() {
  const d = detail.value;
  useEffect(() => {
    if (!d) return;
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); detail.value = null; } };
    document.addEventListener('keydown', onKey, true);
    return () => document.removeEventListener('keydown', onKey, true);
  }, [d]);
  if (!d) return null;
  const host = d.host;
  const w = (hostData.value.find(h => h.host === host) || { workers: [] }).workers.find(x => +x.port === +d.port);
  const close = () => { detail.value = null; };
  const body = () => {
    if (!w) return html`<div class="wdnodata">worker :${d.port} is no longer on ${host}.</div>`;
    const mf = pj(w.manifest), st = pj(w.stats), samples = history.value;
    const rows = [];
    const row = (k, v, region) => { if (v == null || v === '') return; rows.push(html`<div class="k">${k}</div><div class=${'v' + (region ? ' link' : '')} onClick=${region ? (() => { const rn = region; close(); openRegionConfig(host, rn); }) : null} style=${region ? 'cursor:pointer' : ''}>${String(v)}</div>`); };
    row('Host', host);
    if (mf.region) row('Region', mf.region, mf.region);
    row('Notebook', mf.notebook); row('Transport', mf.transport); row('Project', mf.project);
    row('Ports', ':' + w.port + (mf.stream_port ? ' · stream :' + mf.stream_port : '')); row('Spawned', mf.spawned);
    const chip = (l, v) => (v == null || v === '') ? null : html`<div class="wdstat"><span class="l">${l}</span><b>${String(v)}</b></div>`;
    const cpuNow = samples.length ? samples[samples.length - 1].cpu : (st.cpu != null ? st.cpu : -1);
    const rssNow = samples.length ? samples[samples.length - 1].rss : (st.rss || 0);
    const span = samples.length >= 2 ? (samples[samples.length - 1].t - samples[0].t) : 0;   // window covered (s)
    const axis = html`<div class="wdaxis"><span>${span > 0 ? '−' + fmtSpan(span) : ''}</span><span>now</span></div>`;
    return html`
      <div class="wdhead"><strong>${w.alive !== false ? '🟢' : '⚪'} :${w.port}</strong>
        <span class="wdsub">${(w.state || '') + (mf.region ? ' · ' + mf.region : '')}</span></div>
      <div class="wdgrid">${rows}</div>
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
      ${samples.length < 2 ? html`<div class="pddim" style="font-size:.72rem;margin-top:2px">History builds as the hub receives telemetry from this worker${w.state !== 'attached' ? ' — only an attached worker streams in.' : '.'}</div>` : null}`;
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
