// Telemetry view: one worker's resource use over time, opened from the figures in the worker popup.
//
// Everything comes from the hub's telemetry ring (GET /api/worker-stats?full=1): the full history on
// open, then only what is new every two seconds. The charts share one time axis and a linked
// crosshair, so a moment can be read across all of them; the strip on top shows which cells were
// running, from the `running` list each sample carries. Sections a worker cannot fill (no GPU, no
// Linux host figures) are left out rather than shown empty.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect, useRef } from 'preact/hooks';
import { lockScroll } from './scrolllock.js';

const view = signal(null);        // {side, host, port, label} while open
const samples = signal([]);       // full samples, oldest first
const runs = signal([]);          // completed cell runs the hub recorded: {id, t0, t1, memo, err}
const range = signal(300);        // seconds shown; 0 = everything the hub holds
const failed = signal('');
// The page's model changed (model.js): what the header and the caller's bar show comes from it.
const modelTick = signal(0);
window.slateModel && window.slateModel.subscribe(() => { modelTick.value++; });
let timer = null, lastT = -Infinity, gen = 0;

const RANGES = [[60, '1m'], [300, '5m'], [900, '15m'], [0, 'All']];
const GROUP = 'slate-telemetry';
const B = (v) => window.slateBytes(v, { compact: true });
const pct = (v) => (v == null || v < 0) ? '—' : Math.round(v) + '%';

/** Open the view for a worker: `host` as the popup knows it ("" for this machine), `port` its gate.
 *  A caller that knows more about the worker passes `actions`, a function returning markup for a bar
 *  under the title (called on every render, so it stays current), and `onClose`. */
export async function openTelemetry({ side, host, port, label, actions, onClose, nb }) {
  await chartsReady();
  view.value = { side: side || '', host: host || 'local', port, label: label || (side || 'main worker'),
                 actions, onClose, nb: nb || '' };
  samples.value = []; runs.value = []; failed.value = ''; lastT = -Infinity; gen++;
  poll(gen);
  clearInterval(timer);
  timer = setInterval(() => poll(gen), 2000);
}
window.openTelemetry = openTelemetry;

/** Close the view, if open. */
export function closeTelemetry() { view.value && close(); }
// A notebook page has ECharts and its own chart theme already. The home page has neither: ECharts is
// loaded the first time the view opens there, with a theme in the default notebook palette (the home
// page defines no theme variables) covering what these charts use.
let echartsLoad = null;
function chartsReady() {
  if (window.echarts) return Promise.resolve();
  return echartsLoad || (echartsLoad = new Promise((ok, fail) => {
    const s = document.createElement('script');
    s.src = '/assets/vendor/echarts/echarts.min.js'; s.onload = ok; s.onerror = fail;
    document.head.appendChild(s);
  }));
}
function homeTheme() {
  const text = '#d4d8e8', dim = '#6a7090', line = '#2a2e40';
  const ax = { axisLine: { lineStyle: { color: line } }, axisTick: { lineStyle: { color: line } },
               axisLabel: { color: dim }, nameTextStyle: { color: text }, splitLine: { lineStyle: { color: line } } };
  return { color: ['#569cd6', '#56d364', '#ce9178', '#c586c0', '#4ec9b0', '#ffd700', '#e57575'],
           backgroundColor: 'transparent', textStyle: { color: text }, legend: { textStyle: { color: dim } },
           categoryAxis: ax, valueAxis: ax, logAxis: ax, timeAxis: ax,
           tooltip: { backgroundColor: '#141828', borderColor: line, textStyle: { color: text } } };
}
let homeThemeSet = false;
function initChart(el) {
  if (window.slateInitChart) return window.slateInitChart(el);
  if (!homeThemeSet) { window.echarts.registerTheme('slate-home', homeTheme()); homeThemeSet = true; }
  return window.echarts.init(el, 'slate-home');
}

// Where the worker runs: for a view that follows a notebook's side, from the facts, so a restart shows
// at once; otherwise the host and port it was opened on.
function subWhere(v) {
  modelTick.value;   // re-render when the model changes
  const f = v.nb && window.slateModel ? window.slateModel.getFacts()['worker/' + v.nb + '/' + v.side] : null;
  const w = f ? { host: f.host || 'local', port: f.port, connected: f.connected } : null;
  const host = w ? w.host : v.host, port = w ? w.port : v.port;
  return (host === 'local' ? 'this machine' : host) + (port ? ' :' + port : '') +
         (w && !w.connected ? ' · not connected (starting or restarting)' : '');
}

function close() {
  const v = view.value;
  view.value = null; clearInterval(timer); timer = null;
  v && v.onClose && v.onClose();
}

// While the tab is hidden only the first load is made; the rest catches up when it is shown again.
async function poll(g) {
  const v = view.value; if (!v || (document.hidden && isFinite(lastT))) return;
  let r;
  try {
    // A hub route, not a notebook's: fetched directly, since `api()` would put the notebook's id in the path.
    // Named by notebook and side, the view follows that side's worker through a restart; by host and
    // port, it shows that one process.
    const who = v.nb ? 'nb=' + encodeURIComponent(v.nb) + '&side=' + encodeURIComponent(v.side)
                     : 'host=' + encodeURIComponent(v.host) + '&port=' + v.port;
    r = await fetch('/api/worker-stats?full=1&' + who + (isFinite(lastT) ? '&since=' + lastT : '')).then(x => x.json());
  } catch (_) { r = null; }
  if (g !== gen) return;                                        // closed, or reopened on another worker
  if (!r || !r.ok) { failed.value = (r && r.error) || 'no telemetry from this worker'; return; }
  failed.value = '';
  // A run can come back on two polls when no sample landed between them, so each is kept once.
  const seen = new Set(runs.value.map(x => x.id + '@' + x.t1));
  const fresh = (r.runs || []).filter(x => !seen.has(x.id + '@' + x.t1));
  if (fresh.length) { const rs = runs.value.concat(fresh); runs.value = rs.length > 2000 ? rs.slice(rs.length - 2000) : rs; }
  const add = r.samples || [];
  if (!add.length) return;
  lastT = add[add.length - 1].t;
  const all = samples.value.concat(add);
  samples.value = all.length > 2000 ? all.slice(all.length - 2000) : all;
}

// ── data helpers ────────────────────────────────────────────────────────────────────────────────
const shown = () => {
  const s = samples.value, r = range.value;
  if (!r || !s.length) return s;
  const t0 = s[s.length - 1].t - r;
  return s.filter(x => x.t >= t0);
};
const ms = (x) => x.t * 1000;
const series = (s, f) => s.map(x => { const v = f(x); return [ms(x), (v == null || v < 0 || Number.isNaN(v)) ? null : v]; });
const ncores = (x) => (x.host && ((x.host.cores && x.host.cores.length) || x.host.ncpu)) || 0;
// A worker's CPU in cores, or in percent of one core below a core, where `0.0 cores` says nothing.
const coresText = (cpu) => cpu < 0 ? '—' : cpu >= 100 ? (cpu / 100).toFixed(1) + ' cores' : Math.round(cpu) + '% of a core';
const coreTick = (v) => Number.isInteger(+v) ? String(v) : (+v).toFixed(1);

// Cells run over the window: each completed run as the hub timed it, and each cell still running from
// the first sample that shows it, to now. Samples alone miss any run shorter than their interval.
function cellSpans(s, done) {
  if (!s.length) return [];
  const from = s[0].t, last = s[s.length - 1];
  // Clipped to the window: a run that began before the first sample starts at the axis, not past it.
  const spans = done.filter(r => r.t1 >= from)
    .map(r => ({ id: r.id, a: Math.max(r.t0, from) * 1000, b: r.t1 * 1000,
                 kind: r.err ? 'err' : r.memo === 'restored' ? 'restored' : 'ran' }));
  for (const id of last.running || []) {
    let i = s.length - 1;
    while (i > 0 && (s[i - 1].running || []).includes(id)) i--;
    spans.push({ id, a: ms(s[i]), b: ms(last), kind: 'running' });
  }
  return spans;
}
const SPAN_COLOR = { ran: '#569cd6', running: '#56d364', restored: '#9d8fd6', err: '#e5636e' };

// GC time as a share of wall time between samples, from the cumulative `gc_ms`.
const gcPct = (s) => s.map((x, i) => {
  if (!i) return [ms(x), null];
  const p = s[i - 1], dt = x.t - p.t;
  return [ms(x), dt > 0 ? Math.max(0, Math.min(100, (x.gc_ms - p.gc_ms) / 10 / dt)) : null];
});

// ── charts ──────────────────────────────────────────────────────────────────────────────────────
const AXIS = { type: 'time', axisLabel: { hideOverlap: true }, splitLine: { show: false } };
const GRID = { left: 56, right: 16, top: 30, bottom: 22 };
function base(yname, yfmt, extra = {}) {
  return Object.assign({
    animation: false, grid: GRID, xAxis: AXIS,
    yAxis: { type: 'value', name: yname, nameTextStyle: { align: 'left' }, axisLabel: { formatter: yfmt },
             splitLine: { lineStyle: { opacity: 0.25 } } },
    tooltip: { trigger: 'axis', valueFormatter: (v) => v == null ? '—' : yfmt(v) },
    legend: { top: 0, right: 8, itemWidth: 14, itemHeight: 3, icon: 'rect' },
  }, extra);
}
// A light centred moving average (three samples, gaps kept as gaps) and a gentle spline, so a series
// reads as a trend rather than sample-to-sample jitter. `raw: true` keeps a series as measured: a
// peak exists to show the spikes the average flattens.
function ease(data) {
  return data.map((p, i) => {
    if (p[1] == null) return p;
    let t = 0, n = 0;
    for (let j = Math.max(0, i - 1); j <= Math.min(data.length - 1, i + 1); j++)
      if (data[j][1] != null) { t += data[j][1]; n++; }
    return [p[0], t / n];
  });
}
const line = (name, data, extra = {}) => {
  const { raw, ...rest } = extra;
  return Object.assign({ name, type: 'line', data: raw ? data : ease(data), smooth: 0.3, showSymbol: false,
                         connectNulls: false, lineStyle: { width: 2 } }, rest);
};
const limit = (name, y) => ({ silent: true, symbol: 'none', lineStyle: { type: 'dashed', width: 1.5, color: '#e5636e' },
                              label: { formatter: name, position: 'insideEndBottom', color: '#e5636e', fontSize: 11 }, data: [{ yAxis: y }] });

// Text sized for small charts: the notebook theme sizes it for full-width figures, which here pushes
// axis names out of the top margin. Applied to whatever axes and legend an option has; anything an
// option sets itself is kept.
// Every time axis spans the same window, set by the view as it renders, so the charts line up with
// each other and with the run timeline, whose spans can start before the first sample.
let xWindow = null;
function compact(option) {
  const o = Object.assign({ backgroundColor: 'transparent' }, option);
  if (xWindow && o.xAxis && !Array.isArray(o.xAxis) && o.xAxis.type === 'time')
    o.xAxis = Object.assign({}, o.xAxis, { min: xWindow[0], max: xWindow[1] });
  const small = (x) => Object.assign({ fontSize: 11 }, x || {});
  const axis = (a) => a && Object.assign({}, a, { axisLabel: small(a.axisLabel), nameTextStyle: small(a.nameTextStyle),
                                                  nameGap: a.nameGap ?? 8 });
  for (const k of ['xAxis', 'yAxis']) if (o[k]) o[k] = Array.isArray(o[k]) ? o[k].map(axis) : axis(o[k]);
  if (o.legend) o.legend = Object.assign({}, o.legend, { textStyle: small(o.legend.textStyle) });
  return o;
}

function Chart({ option, height = 140 }) {
  const el = useRef(null), inst = useRef(null);
  useEffect(() => {
    const c = initChart(el.current);
    c.group = GROUP; window.echarts.connect(GROUP);
    inst.current = c;
    const ro = new ResizeObserver(() => c.resize()); ro.observe(el.current);
    return () => { ro.disconnect(); c.dispose(); };
  }, []);
  useEffect(() => { inst.current && inst.current.setOption(compact(option), { notMerge: true }); });
  return html`<div class="tm-chart" ref=${el} style=${'height:' + height + 'px'}></div>`;
}

function Section({ title, children, aside }) {
  return html`<section class="tm-sec"><div class="tm-sechead"><h3>${title}</h3>${aside}</div>${children}</section>`;
}

function Tile({ label, value, sub, frac, tone }) {
  return html`<div class=${'tm-tile' + (tone ? ' ' + tone : '')}>
    <div class="tm-tlabel">${label}</div><div class="tm-tval">${value}</div>
    ${frac != null ? html`<div class="tm-bar"><span style=${'width:' + Math.min(100, Math.max(0, frac * 100)) + '%'}></span></div>` : null}
    ${sub ? html`<div class="tm-tsub">${sub}</div>` : null}</div>`;
}

function Telemetry() {
  const v = view.value;
  useEffect(() => { lockScroll('telemetry', !!v); }, [!!v]);
  if (!v) return null;
  const s = shown(), last = s[s.length - 1];
  const head = html`<div class="tm-head">
      <div><div class="tm-title">Telemetry · ${v.label}</div>
        <div class="tm-sub">${subWhere(v)}
          ${last ? html` · ${s.length} samples · updated ${Math.max(0, Math.round(Date.now() / 1000 - last.t))}s ago` : null}</div></div>
      <div class="tm-ranges">${RANGES.map(([r, l]) => html`<button class=${range.value === r ? 'on' : ''} onClick=${() => range.value = r}>${l}</button>`)}</div>
      <button class="tm-x" title="Close (Esc)" onClick=${close}>✕</button></div>`;
  const acts = v.actions ? html`<div class="tm-acts">${v.actions()}</div>` : null;
  if (!last) return html`<div class="tm-bg" onMouseDown=${e => e.target.classList.contains('tm-bg') && close()}>
      <div class="tm-card">${head}${acts}<div class="tm-body"><div class="tm-empty">${failed.value || 'waiting for telemetry…'}</div></div></div></div>`;

  const job = last.job || {}, host = last.host || {}, proc = last.proc || {}, gpus = last.gpus || [];
  const memLimit = job.mem_max > 0 ? job.mem_max : (last.sys_mem_total || 0);
  const memUsed = job.mem_max > 0 ? job.mem_cur : (host.mem_avail >= 0 ? last.sys_mem_total - host.mem_avail : -1);
  xWindow = [ms(s[0]), ms(last)];
  const nc = ncores(last), spans = cellSpans(s, runs.value);
  const ids = [...new Set(spans.map(x => x.id))];
  const gpuAvg = gpus.length ? gpus.reduce((a, g) => a + Math.max(0, g.util), 0) / gpus.length : -1;
  const gcNow = gcPct(s.slice(-2)).pop()[1];

  const tiles = html`<div class="tm-tiles">
    <${Tile} label="CPU · this worker" value=${coresText(last.cpu)}
             sub=${last.sys_cpu >= 0 ? 'host ' + pct(last.sys_cpu) + (nc ? ' of ' + nc + ' cores' : '') : null}/>
    <${Tile} label=${job.mem_max > 0 ? 'Memory · job limit' : memUsed >= 0 ? 'Memory · host' : 'Memory · this worker'}
             value=${memUsed >= 0 ? B(memUsed) + ' / ' + B(memLimit) : B(last.rss)}
             frac=${memUsed >= 0 && memLimit > 0 ? memUsed / memLimit : null}
             tone=${memUsed >= 0 && memLimit > 0 && memUsed / memLimit > 0.85 ? 'warn' : ''}
             sub=${memUsed >= 0 ? 'this worker ' + B(last.rss) : null}/>
    ${gpus.length ? html`<${Tile} label=${gpus.length > 1 ? 'GPUs · ' + gpus.length : 'GPU'} value=${pct(gpuAvg)}
             frac=${gpuAvg >= 0 ? gpuAvg / 100 : null}
             sub=${gpus.map(g => B(g.mem_used) + ' / ' + B(g.mem_total)).join(' · ')}/>` : null}
    <${Tile} label="Garbage collection" value=${gcNow == null ? '—' : gcNow.toFixed(1) + '%'}
             sub=${proc.alloc_rate >= 0 ? 'allocating ' + B(proc.alloc_rate) + '/s' : null}
             tone=${gcNow > 30 ? 'warn' : ''}/>
  </div>`;

  const spanKey = html`<span class="tm-key">${Object.entries({ ran: 'ran', running: 'running', restored: 'restored', err: 'failed' })
    .map(([k, l]) => html`<span><i style=${'background:' + SPAN_COLOR[k]}></i>${l}</span>`)}</span>`;
  const running = ids.length ? html`<${Chart} height=${Math.min(120, 30 + 16 * ids.length)} option=${{
      animation: false, grid: { left: 90, right: 16, top: 6, bottom: 20 }, xAxis: AXIS,
      yAxis: { type: 'category', data: ids, axisLabel: { width: 80, overflow: 'truncate' } },
      tooltip: { formatter: (p) => {
        const [, a, b, id, kind] = p.data.value, d = b - a;
        return id + ' · ' + (d < 1000 ? Math.round(d) + ' ms' : (d / 1000).toFixed(d < 10000 ? 1 : 0) + ' s') +
               ' · ' + ({ ran: 'ran', running: 'running', restored: 'restored', err: 'failed' })[kind];
      } },
      series: [{ type: 'custom', encode: { x: [1, 2], y: 0 },
        renderItem: (params, api) => {
          const y = api.value(0), a = api.coord([api.value(1), y]), b = api.coord([api.value(2), y]);
          const h = api.size([0, 1])[1] * 0.6, cs = params.coordSys;
          // Kept inside the plot: nothing draws over the cell names or past the last sample.
          const r = window.echarts.graphic.clipRectByRect(
            { x: a[0], y: a[1] - h / 2, width: Math.max(2, b[0] - a[0]), height: h },
            { x: cs.x, y: cs.y, width: cs.width, height: cs.height });
          return r && { type: 'rect', shape: Object.assign(r, { r: 3 }), style: api.style() };
        },
        data: spans.map(x => ({ value: [ids.indexOf(x.id), x.a, x.b, x.id, x.kind], itemStyle: { color: SPAN_COLOR[x.kind] } })) }] }}/>` : html`<div class="tm-none">no cell ran in this window</div>`;

  const cpuMax = Math.max(job.cpus || 0, nc || 0);
  // Scaled to what the worker may use, so the headroom shows; a limit line does not stretch the axis.
  // At least one core tall, so an idle worker does not stretch noise across the chart.
  const cpu = base('cores', (v) => (+v).toFixed(2), {
    yAxis: { type: 'value', name: 'cores', min: 0, max: (v) => Math.max(1, cpuMax > 0 ? Math.ceil(cpuMax * 1.05) : Math.ceil(v.max)),
             axisLabel: { formatter: coreTick }, splitLine: { lineStyle: { opacity: 0.25 } } },
    series: [line('this worker', series(s, x => x.cpu / 100), { areaStyle: { opacity: 0.12 } }),
             nc ? line('host', series(s, x => x.sys_cpu >= 0 ? x.sys_cpu / 100 * ncores(x) : -1)) : null,
             job.cpus > 0 ? line('allowed', [], { markLine: limit('job allows ' + job.cpus, job.cpus) }) : null].filter(Boolean) });

  const mem = base('', B, {
    yAxis: { type: 'value', max: memLimit > 0 ? memLimit * 1.05 : null, axisLabel: { formatter: B },
             splitLine: { lineStyle: { opacity: 0.25 } } },
    series: [line('this worker', series(s, x => x.rss), { areaStyle: { opacity: 0.12 } }),
             job.mem_max > 0 ? line('job', series(s, x => (x.job || {}).mem_cur)) :
               host.mem_avail >= 0 ? line('host used', series(s, x => ((x.host || {}).mem_avail >= 0 ? x.sys_mem_total - x.host.mem_avail : -1))) : null,
             memLimit > 0 ? line('limit', [], { markLine: limit((job.mem_max > 0 ? 'job limit ' : 'host ') + B(memLimit), memLimit) }) : null]
            .filter(Boolean) });

  // Every core over time, as a heatmap; columns thinned to at most 240 so a long window stays light.
  // On a shared node only the job's own cores are this worker's business; the rest are other jobs'.
  let heat = null;
  if (host.cores && host.cores.length) {   // per-core load is read on Linux only
    const step = Math.max(1, Math.ceil(s.length / 240)), cols = s.filter((_, i) => i % step === 0);
    const own = (job.cpuset && job.cpuset.length) ? job.cpuset : [...Array(nc).keys()];
    const data = [];
    cols.forEach((x, ci) => { const c = (x.host || {}).cores || []; own.forEach((k, row) => data.push([ci, row, c[k] ?? 0])); });
    heat = { animation: false, grid: { left: 56, right: 16, top: 8, bottom: 24 },
      xAxis: { type: 'category', data: cols.map(x => new Date(ms(x)).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })),
               axisLabel: { hideOverlap: true }, splitArea: { show: false } },
      yAxis: { type: 'category', data: own.map(String), name: own.length < nc ? 'job cores' : 'core',
               axisLabel: { interval: Math.max(0, Math.ceil(own.length / 8) - 1) } },
      visualMap: { min: 0, max: 100, show: false, inRange: { color: ['#151a2b', '#1f4f8a', '#3f8fe0', '#9fd2ff'] } },
      tooltip: { formatter: (p) => 'core ' + own[p.value[1]] + ' · ' + Math.round(p.value[2]) + '%' },
      series: [{ type: 'heatmap', data, progressive: 0 }] };
  }

  const hasIO = s.some(x => (x.proc || {}).io_read >= 0 || (x.host || {}).net_rx >= 0);
  const io = !hasIO ? null : base('per second', B, {
    series: [line('read', series(s, x => (x.proc || {}).io_read)), line('write', series(s, x => (x.proc || {}).io_write)),
             host.net_rx != null ? line('net in', series(s, x => (x.host || {}).net_rx)) : null,
             host.net_tx != null ? line('net out', series(s, x => (x.host || {}).net_tx)) : null].filter(Boolean) });
  const psi = host.psi_cpu >= 0 ? base('% of time', (v) => Math.round(v) + '%', {
    series: [line('cpu', series(s, x => (x.host || {}).psi_cpu)), line('memory', series(s, x => (x.host || {}).psi_mem)),
             line('io', series(s, x => (x.host || {}).psi_io))] }) : null;
  const julia = base('', (v) => Math.round(v) + '%', {
    series: [line('gc time', gcPct(s), { areaStyle: { opacity: 0.12 } })] });
  const alloc = base('per second', B, { series: [line('allocation', series(s, x => (x.proc || {}).alloc_rate))] });

  const gpuSec = gpus.length ? html`<${Section} title="GPU">
      <div class="tm-gpus">${gpus.map(g => html`<div class="tm-gpu">
        <div class="tm-gname">gpu${g.i} · ${g.name}</div>
        <div class="tm-gstats">
          <span>${pct(g.util)} busy</span><span>${pct(g.mem_util)} memory bandwidth</span>
          <span>${g.temp >= 0 ? g.temp + '°C' : '—'}</span>
          <span>${g.power_w >= 0 ? Math.round(g.power_w) + (g.power_limit_w > 0 ? ' / ' + Math.round(g.power_limit_w) : '') + ' W' : '—'}</span>
          <span>${g.sm_mhz >= 0 ? g.sm_mhz + (g.sm_max_mhz > 0 ? ' / ' + g.sm_max_mhz : '') + ' MHz' : ''}</span>
          ${g.proc_mem > 0 ? html`<span>this worker ${B(g.proc_mem)}</span>` : null}
          ${(g.throttle || []).length ? html`<span class="tm-throttle">held back: ${g.throttle.join(', ')}</span>` : null}
        </div></div>`)}</div>
      <div class="tm-grid">
        <${Chart} option=${base('%', (v) => Math.round(v) + '%', { yAxis: { type: 'value', max: 100, axisLabel: { formatter: (v) => v + '%' }, splitLine: { lineStyle: { opacity: 0.25 } } },
          // The average over each interval, and its busiest moment, faint behind it.
          series: gpus.flatMap(g => [line('gpu' + g.i, series(s, x => ((x.gpus || [])[g.i] || {}).util)),
            line('gpu' + g.i + ' peak', series(s, x => { const v = ((x.gpus || [])[g.i] || {}).util_max; return v == null ? -1 : v; }),
                 { raw: true, lineStyle: { width: 1, type: 'dotted', opacity: 0.7 } })]) })}/>
        <${Chart} option=${base('', B, { series: gpus.map(g => line('gpu' + g.i, series(s, x => ((x.gpus || [])[g.i] || {}).mem_used),
            g.i === 0 ? { markLine: limit('total ' + B(g.mem_total), g.mem_total) } : {})) })}/>
      </div></${Section}>` : null;

  return html`<div class="tm-bg" onMouseDown=${e => e.target.classList.contains('tm-bg') && close()}>
    <div class="tm-card" role="dialog" aria-modal="true">
      ${head}${acts}
      <div class="tm-body">
        ${tiles}
        <${Section} title="Cells running" aside=${spanKey}>${running}</${Section}>
        <${Section} title="CPU"><div class="tm-grid"><${Chart} option=${cpu}/>${heat ? html`<${Chart} option=${heat}/>` : null}</div></${Section}>
        <${Section} title="Memory"><${Chart} option=${mem}/></${Section}>
        ${gpuSec}
        ${io || psi ? html`<${Section} title=${io && psi ? 'I/O and pressure' : io ? 'I/O' : 'Pressure'}><div class="tm-grid">
          ${io ? html`<${Chart} option=${io}/>` : null}${psi ? html`<${Chart} option=${psi}/>` : null}</div></${Section}>` : null}
        <${Section} title="Julia runtime"><div class="tm-grid"><${Chart} option=${julia}/><${Chart} option=${alloc}/></div></${Section}>
      </div></div></div>`;
}

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Telemetry} />`, host);
document.addEventListener('visibilitychange', () => { if (!document.hidden && view.value) poll(gen); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && view.value) { e.stopImmediatePropagation(); close(); }
}, true);
