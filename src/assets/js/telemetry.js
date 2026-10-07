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
const gpuPick = signal('all');    // the GPU charts: 'all' combined, 'each' one line per GPU, or one GPU's index
const gcShow = signal('all');     // the timeline's collections: 'all', or 'full' only
const gcBusy = signal(false);     // a collection asked of the worker and not yet done
const failed = signal('');
// The page's model changed (model.js): what the header and the caller's bar show comes from it.
const modelTick = signal(0);
window.slateModel && window.slateModel.subscribe(() => { modelTick.value++; });
let timer = null, lastT = -Infinity, gen = 0;

const RANGES = [[60, '1m'], [300, '5m'], [900, '15m'], [0, 'All']];
const GROUP = 'slate-telemetry';
const B = (v) => window.slateBytes(v, { compact: true });
const pct = (v) => (v == null || v < 0) ? '—' : Math.round(v) + '%';
// A percent axis tick: one decimal below 10%, where whole percents would label every tick "0%".
const pctTick = (v) => (Math.abs(v) < 10 && v % 1 ? (+v).toFixed(1) : Math.round(v)) + '%';
// A percent axis at least 1% tall, so a share that sits near zero does not stretch noise across it.
const pctAxis = { type: 'value', min: 0, max: (v) => Math.max(1, v.max), axisLabel: { formatter: pctTick },
                  splitLine: { lineStyle: { opacity: 0.25 } } };

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
// One poll at a time: a reply slower than the interval would otherwise let the next poll ask from the
// same point, and both would append the same samples.
let polling = false;
async function poll(g) {
  const v = view.value; if (!v || polling || (document.hidden && isFinite(lastT))) return;
  polling = true;
  try { await pollOnce(g, v); } finally { polling = false; }
}
async function pollOnce(g, v) {
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
  // Only what is newer than what the view holds: the hub's `since` may include the sample it starts at.
  const add = (r.samples || []).filter(x => x.t > lastT);
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
const { reading, sampleCores: ncores } = window.slateModel;
const coreTick = (v) => Number.isInteger(+v) ? String(v) : (+v).toFixed(1);

// Cells run over the window: each completed run as the hub timed it, and each cell still running from
// the first sample that shows it, to now. Samples alone miss any run shorter than their interval.
function cellSpans(s, done) {
  if (!s.length) return [];
  const from = s[0].t, last = s[s.length - 1];
  // Clipped to the window: a run that began before the first sample starts at the axis, not past it.
  const spans = done.filter(r => r.t1 >= from)
    .map(r => ({ id: r.id, a: Math.max(r.t0, from) * 1000, b: r.t1 * 1000, profile: r.profile || '',
                 kind: r.err ? 'err' : r.memo === 'restored' ? 'restored' : 'ran' }));
  for (const id of last.running || []) {
    let i = s.length - 1;
    while (i > 0 && (s[i - 1].running || []).includes(id)) i--;
    spans.push({ id, a: ms(s[i]), b: ms(last), kind: 'running' });
  }
  return spans;
}
const SPAN_COLOR = { ran: '#569cd6', running: '#56d364', restored: '#9d8fd6', err: '#e5636e' };
const PROFILED = '#e8933a';   // the profiler's colour, on a run that was profiled

// The worker's collections. Each one as it happened where the worker reports them (`gc`: [end, pause
// ms, full, live bytes after]); otherwise the intervals between samples in which it collected, from
// its cumulative counts, a sample being the finest those resolve.
const GC_COLOR = '#8a93b8', GC_FULL = '#e8a33d';
function gcSpans(s) {
  const out = [], P = (x) => x.proc || {};
  for (let i = 1; i < s.length; i++) {
    const p = s[i - 1], x = s[i];
    if (Array.isArray(x.gc)) {
      for (const [t, pause, full, live] of x.gc)
        out.push({ a: t * 1000 - pause, b: t * 1000, n: 1, full: full ? 1 : 0, t: pause, live, one: true });
      continue;
    }
    const n = P(x).gc_pauses - P(p).gc_pauses;
    if (!(P(p).gc_pauses >= 0) || !(n > 0)) continue;
    const full = Math.max(0, (P(x).gc_full ?? 0) - (P(p).gc_full ?? 0)), t = Math.max(0, x.gc_ms - p.gc_ms);
    out.push({ a: ms(p), b: ms(x), n, full, t, share: x.t > p.t ? Math.min(1, t / 1000 / (x.t - p.t)) : 0 });
  }
  return out;
}
// How dark a collection is drawn: an interval by the share of it spent collecting, one collection by
// its pause, a quarter of the interval or 50 ms being the darkest.
const gcOpacity = (g) => 0.35 + 0.65 * Math.min(1, g.one ? g.t / 50 : g.share * 4);

// A collection run on the worker now, for the buttons. The next sample shows what it freed.
async function collectNow(v, full) {
  gcBusy.value = true;
  try {
    await fetch('/api/worker-gc', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ nb: v.nb, side: v.side || '', full }) });
  } catch (_) {}
  gcBusy.value = false;
}

// A cumulative milliseconds counter (GC time, compile time) as a share of wall time between samples.
const msShare = (s, get) => s.map((x, i) => {
  if (!i) return [ms(x), null];
  const p = s[i - 1], dt = x.t - p.t, a = get(p), b = get(x);
  return [ms(x), dt > 0 && a >= 0 && b >= 0 ? Math.max(0, Math.min(100, (b - a) / 10 / dt)) : null];
});
const gcPct = (s) => msShare(s, x => x.gc_ms);
const compilePct = (s) => msShare(s, x => (x.proc || {}).compile_ms ?? -1);
// How much a cumulative count grew over the window shown, or 0 when the samples cannot say.
const grew = (s, get) => { if (s.length < 2) return 0; const a = get(s[0]), b = get(s[s.length - 1]);
                           return a >= 0 && b >= a ? b - a : 0; };

// ── charts ──────────────────────────────────────────────────────────────────────────────────────
// The tooltip's heading is the axis pointer's label: the time of day, the window being minutes long.
const AXIS = { type: 'time', splitNumber: 3, axisLabel: { hideOverlap: true }, splitLine: { show: false },
               axisPointer: { label: { formatter: (p) => new Date(+p.value).toLocaleTimeString() } } };
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

// Text sized for small charts: the notebook theme sizes it for full-width figures, which here pushes
// axis names out of the top margin. Applied to whatever axes and legend an option has; anything an
// option sets itself is kept.
// Every time axis spans the same window, set by the view as it renders, so the charts line up with
// each other and with the run timeline, whose spans can start before the first sample.
let xWindow = null;
// `active`: the pointer is over this chart. Every connected chart shows its values at the hovered
// time, and only this one heads them with the time, which would otherwise repeat in every box.
function compact(option, active = false) {
  const o = Object.assign({ backgroundColor: 'transparent' }, option);
  if (o.tooltip) {
    const tt = o.tooltip, vf = tt.valueFormatter || ((v) => v);
    // A series on a second axis carries its own units (`tooltip.valueFormatter` on the series).
    const vfOf = (p) => ((((o.series || [])[p.seriesIndex] || {}).tooltip || {}).valueFormatter) || vf;
    const body = tt.formatter || ((ps) => ps.filter(p => p.value && p.value[1] != null).map(p =>
      p.marker + p.seriesName + '<span style="float:right;margin-left:14px;font-weight:600">' + vfOf(p)(p.value[1]) + '</span>').join('<br>'));
    const fmt = tt.trigger !== 'axis' ? tt.formatter : (ps) => {
      const list = Array.isArray(ps) ? ps : [ps], rows = body(list);
      const head = active && list[0] ? new Date(+list[0].axisValue).toLocaleTimeString() : '';
      return head && rows ? head + '<br>' + rows : rows || head;
    };
    o.tooltip = Object.assign({}, tt, { formatter: fmt, padding: [4, 8], textStyle: { fontSize: 11 } });
  }
  if (xWindow && o.xAxis && !Array.isArray(o.xAxis) && o.xAxis.type === 'time')
    o.xAxis = Object.assign({}, o.xAxis, { min: xWindow[0], max: xWindow[1] });
  const small = (x) => Object.assign({ fontSize: 11 }, x || {});
  const axis = (a) => a && Object.assign({}, a, { axisLabel: small(a.axisLabel), nameTextStyle: small(a.nameTextStyle),
                                                  nameGap: a.nameGap ?? 8 });
  for (const k of ['xAxis', 'yAxis']) if (o[k]) o[k] = Array.isArray(o[k]) ? o[k].map(axis) : axis(o[k]);
  if (o.legend) o.legend = Object.assign({}, o.legend, { textStyle: small(o.legend.textStyle) });
  // An update replaces each series by id (`Chart`); one without an id is added again instead.
  if (Array.isArray(o.series)) o.series = o.series.map((x, i) => x.id != null ? x : Object.assign({ id: x.name || 'series' + i }, x));
  return o;
}

function Chart({ option, height = 140, onClick = null }) {
  const el = useRef(null), inst = useRef(null), active = useRef(false), opt = useRef(option), click = useRef(onClick);
  opt.current = option; click.current = onClick;
  useEffect(() => {
    const c = initChart(el.current);
    c.group = GROUP; window.echarts.connect(GROUP);
    inst.current = c;
    const mark = (on) => { if (active.current === on) return; active.current = on;
                           c.setOption(compact(opt.current, on), { replaceMerge: ['series'] }); };
    c.getZr().on('mousemove', () => mark(true));
    c.getZr().on('globalout', () => mark(false));
    c.on('click', (p) => click.current && click.current(p));
    const ro = new ResizeObserver(() => c.resize()); ro.observe(el.current);
    return () => { ro.disconnect(); c.dispose(); };
  }, []);
  // Merged into the chart rather than replacing it, which would rebuild it and drop the tooltip being
  // read, with the connected charts' pointers, every couple of seconds. The series are replaced
  // whole, because which ones a chart has changes with the sample.
  useEffect(() => { inst.current && inst.current.setOption(compact(option, active.current), { replaceMerge: ['series'] }); });
  return html`<div class="tm-chart" ref=${el} style=${'height:' + height + 'px'}></div>`;
}

function Section({ title, children, aside }) {
  return html`<section class="tm-sec"><div class="tm-sechead"><h3>${title}</h3>${aside}</div>${children}</section>`;
}

function Tile({ label, value, sub, frac, tone }) {
  return html`<div class=${'tm-tile' + (tone ? ' ' + tone : '')}>
    <div class="tm-ttop"><span class="tm-tlabel">${label}</span><span class="tm-tval">${value}</span></div>
    ${frac != null ? html`<div class="tm-bar"><span style=${'width:' + Math.min(100, Math.max(0, frac * 100)) + '%'}></span></div>` : null}
    ${sub ? html`<div class="tm-tsub" onMouseEnter=${(e) => { const t = e.currentTarget; t.title = t.scrollWidth > t.clientWidth ? sub : ''; }}>${sub}</div>` : null}</div>`;
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
  const r = reading(last), memLimit = r.mem ? r.mem.limit : (last.sys_mem_total || 0);
  xWindow = [ms(s[0]), ms(last)];
  const nc = r.hostCores, spans = cellSpans(s, runs.value);
  const ids = [...new Set(spans.map(x => x.id))];
  const gcNow = gcPct(s.slice(-2)).pop()[1], compileNow = compilePct(s.slice(-2)).pop()[1];
  const P = (x) => x.proc || {}, J = (x) => x.job || {};
  const pauses = grew(s, x => P(x).gc_pauses ?? -1), fulls = grew(s, x => P(x).gc_full ?? -1);
  const compiled = grew(s, x => P(x).compile_ms ?? -1) / 1000;
  const throttled = grew(s, x => J(x).nr_throttled ?? -1);
  const limitHits = grew(s, x => J(x).mem_limit_hits ?? -1), oomKills = grew(s, x => J(x).oom_kills ?? -1);
  const disks = last.disks || [];
  const dot = (...xs) => xs.filter(Boolean).join(' · ') || null;

  const tiles = html`<div class="tm-tiles">
    <${Tile} label="CPU" value=${r.cpuText} tone=${throttled > 0 ? 'warn' : ''}
             sub=${dot(r.hostCpu != null ? 'host ' + pct(r.hostCpu) : '',
                       last.load1 >= 0 ? 'load ' + last.load1 : '', throttled > 0 ? 'throttled ' + throttled + '×' : '')}/>
    <${Tile} label=${r.mem && r.mem.of === 'host' ? 'Memory · host' : 'Memory'}
             value=${r.mem ? B(r.mem.used) + ' / ' + B(r.mem.limit) : B(last.rss)}
             frac=${r.memFrac}
             tone=${r.memFrac > 0.85 || limitHits > 0 || oomKills > 0 ? 'warn' : ''}
             sub=${dot(r.mem ? 'this worker ' + B(last.rss) : '', host.swap_used > 0 ? 'swap ' + B(host.swap_used) : '',
                       limitHits > 0 ? 'at limit ' + limitHits + '×' : '', oomKills > 0 ? oomKills + ' OOM kill' + (oomKills > 1 ? 's' : '') : '')}/>
    ${r.gpus.length ? html`<${Tile} label=${r.gpus.length > 1 ? 'GPUs · ' + r.gpus.length : 'GPU'} value=${r.gpuAvg == null ? '—' : pct(r.gpuAvg)}
             frac=${r.gpuAvg == null ? null : r.gpuAvg / 100}
             sub=${r.gpus.map(g => B(g.memUsed) + ' / ' + B(g.memTotal)).join(' · ')}/>` : null}
    <${Tile} label="Garbage collection" value=${gcNow == null ? '—' : gcNow.toFixed(1) + '%'}
             sub=${dot(proc.alloc_rate >= 0 ? 'allocating ' + B(proc.alloc_rate) + '/s' : '',
                       pauses > 0 ? pauses + ' pauses' : '', fulls > 0 ? fulls + ' full' : '')}
             tone=${gcNow > 30 ? 'warn' : ''}/>
    ${proc.compile_ms >= 0 ? html`<${Tile} label="Compilation" value=${compileNow == null ? '—' : compileNow.toFixed(1) + '%'}
             sub=${compiled > 0 ? compiled.toFixed(1) + ' s in window' : null}/>` : null}
    ${proc.threads > 0 ? html`<${Tile} label="Process" value=${proc.threads + ' threads'}
             sub=${proc.fds >= 0 ? proc.fds + ' open files' : null}/>` : null}
    ${disks.map(d => html`<${Tile} label=${'Disk · ' + d.label} value=${B(d.free) + ' free'}
             frac=${d.total > 0 ? 1 - d.free / d.total : null} tone=${d.total > 0 && d.free / d.total < 0.1 ? 'warn' : ''}
             sub=${d.path}/>`)}
  </div>`;

  const spanKey = html`<span class="tm-key">${[...Object.entries({ ran: 'ran', running: 'running', restored: 'restored', err: 'failed' })
      .map(([k, l]) => [SPAN_COLOR[k], l]), [GC_COLOR, 'GC'], [GC_FULL, 'full GC']]
    .map(([c, l]) => html`<span><i style=${'background:' + c}></i>${l}</span>`)}${
    spans.some(x => x.profile) ? html`<span><i style=${'border:2px solid ' + PROFILED + ';box-sizing:border-box'}></i>profiled</span>` : null}</span>`;
  // A profiled run opens its own profile, in place of this view.
  const openRunProfile = (id, prof) => {
    if (v.nb !== (window.__slateState || {}).id || typeof window.slateProfileCell !== 'function') return reveal(id);
    close();
    window.slateProfileCell(id, prof);
  };
  // A run clicked here brings its cell into view in the notebook behind, so it is there on closing.
  const reveal = (id) => {
    const el = document.getElementById('cell-' + id);
    if (!el || v.nb !== (window.__slateState || {}).id) return;
    if (typeof window.selectCell === 'function') window.selectCell(id, false);
    el.scrollIntoView({ block: el.getBoundingClientRect().height >= window.innerHeight * 0.9 ? 'start' : 'center',
                        behavior: 'smooth' });
  };
  const gcAll = gcSpans(s), gcEach = gcAll.some(g => g.one);
  const gcs = gcShow.value === 'full' ? gcAll.filter(g => g.full) : gcAll;
  // The GC lane is there whenever the worker reports collections, so the chart keeps its height
  // whether or not one happened in the window.
  const gcLane = s.some(x => Array.isArray(x.gc) || (x.proc || {}).gc_pauses >= 0);
  const lanes = gcLane ? [...ids, 'GC'] : ids;
  // One bar drawer for runs and collections, kept inside the plot: nothing draws over the lane names
  // or past the last sample.
  const bar = (params, api) => {
    const y = api.value(0), a = api.coord([api.value(1), y]), b = api.coord([api.value(2), y]);
    const h = api.size([0, 1])[1] * 0.6, cs = params.coordSys;
    const r = window.echarts.graphic.clipRectByRect(
      { x: a[0], y: a[1] - h / 2, width: Math.max(2, b[0] - a[0]), height: h },
      { x: cs.x, y: cs.y, width: cs.width, height: cs.height });
    return r && { type: 'rect', shape: Object.assign(r, { r: 3 }), style: api.style() };
  };
  const running = lanes.length ? html`<${Chart} height=${Math.min(136, 30 + 16 * lanes.length)}
      onClick=${(p) => p && p.data && p.data.value && (p.data.value[5] ? openRunProfile(p.data.value[3], p.data.value[5]) : reveal(p.data.value[3]))} option=${{
      animation: false, grid: { left: 90, right: 16, top: 6, bottom: 20 }, xAxis: AXIS,
      yAxis: { type: 'category', data: lanes, axisLabel: { width: 80, overflow: 'truncate' } },
      tooltip: { formatter: (p) => {
        if (p.seriesId === 'gc') {
          const g = gcs[p.dataIndex];
          if (g.one) return new Date(g.b).toLocaleTimeString() + ' · ' + (g.full ? 'full' : 'minor') + ' GC · ' +
                            (g.t < 1 ? g.t.toFixed(2) + ' ms' : window.slateDuration(g.t)) + ' · ' + B(g.live) + ' live after';
          return 'GC · ' + g.n + (g.n > 1 ? ' pauses' : ' pause') + (g.full ? ' · ' + g.full + ' full' : '') +
                 ' · ' + window.slateDuration(g.t);
        }
        const [, a, b, id, kind, prof] = p.data.value, d = b - a;
        return id + ' · ' + window.slateDuration(d) +
               ' · ' + ({ ran: 'ran', running: 'running', restored: 'restored', err: 'failed' })[kind] +
               (prof ? ' · profiled' : '');
      } },
      series: [{ id: 'runs', type: 'custom', encode: { x: [1, 2], y: 0 }, cursor: 'pointer', renderItem: bar,
        data: spans.map(x => ({ value: [ids.indexOf(x.id), x.a, x.b, x.id, x.kind, x.profile],
                                itemStyle: x.profile ? { color: SPAN_COLOR[x.kind], borderColor: PROFILED, borderWidth: 2 }
                                                     : { color: SPAN_COLOR[x.kind] } })) },
        gcs.length ? { id: 'gc', type: 'custom', encode: { x: [1, 2], y: 0 }, cursor: 'default', renderItem: bar,
          data: gcs.map(g => ({ value: [ids.length, g.a, g.b],
                                itemStyle: { color: g.full ? GC_FULL : GC_COLOR, opacity: gcOpacity(g) } })) } : null
      ].filter(Boolean) }}/>` : html`<div class="tm-none">no cell ran in this window</div>`;

  // Scaled to what the worker may use, so the headroom shows: the job's allowance on a scheduler
  // node, the host's cores elsewhere. The top of the axis is the limit, which the section header
  // states. At least one core tall, so an idle worker does not stretch noise across the chart. On a shared node the rest of the host is other jobs' load, so the second
  // line is the load on the job's own cores rather than the host's, which would set the scale.
  const allow = job.cpus > 0 ? job.cpus : 0;
  const own = (job.cpuset && job.cpuset.length) ? job.cpuset : null;
  const cpuMax = allow || nc || 0;
  const ownLoad = (x) => { const c = (x.host || {}).cores; return c && c.length ? own.reduce((t, k) => t + (c[k] ?? 0), 0) / 100 : -1; };
  const cpu = base('cores', (v) => (+v).toFixed(2), {
    yAxis: { type: 'value', name: 'cores', min: 0, max: (v) => Math.max(1, cpuMax || Math.ceil(v.max)),
             axisLabel: { formatter: coreTick }, splitLine: { lineStyle: { opacity: 0.25 } } },
    series: [line('this worker', series(s, x => x.cpu / 100), { areaStyle: { opacity: 0.12 } }),
             !allow ? (nc ? line('host', series(s, x => x.sys_cpu >= 0 ? x.sys_cpu / 100 * ncores(x) : -1)) : null)
                    : (own && host.cores && host.cores.length ? line('job cores', series(s, ownLoad)) : null)].filter(Boolean) });

  // Each chart ends at the limit that bounds it, and the section header says what that limit is.
  const limitKey = (t) => t ? html`<span class="tm-key">${t}</span>` : null;
  const cpuLimit = limitKey(allow && nc && allow < nc ? allow + '/' + nc + ' cores' : cpuMax ? cpuMax + ' cores' : '');
  const memLimitText = limitKey(memLimit > 0 ? B(memLimit) + ' available' : '');
  const mem = base('', B, {
    yAxis: { type: 'value', max: memLimit > 0 ? memLimit : null, axisLabel: { formatter: B },
             splitLine: { lineStyle: { opacity: 0.25 } } },
    series: [line('this worker', series(s, x => x.rss), { areaStyle: { opacity: 0.12 } }),
             proc.heap >= 0 ? line('Julia heap', series(s, x => (x.proc || {}).heap ?? -1)) : null,
             job.mem_max > 0 ? line('job', series(s, x => (x.job || {}).mem_cur)) :
               host.mem_avail >= 0 ? line('host used', series(s, x => ((x.host || {}).mem_avail >= 0 ? x.sys_mem_total - x.host.mem_avail : -1))) : null]
            .filter(Boolean) });

  // Every core over time, as cells on the same time axis as the other charts, so the hover line runs
  // through it with them (ECharts draws a heatmap on category axes only, which the other charts'
  // hover cannot follow). Columns are thinned to at most 240 so a long window stays light. On a shared
  // node only the job's own cores are this worker's business; the rest are other jobs'.
  let heat = null;
  if (host.cores && host.cores.length) {   // per-core load is read on Linux only
    const step = Math.max(1, Math.ceil(s.length / 240)), cols = s.filter((_, i) => i % step === 0);
    const own = (job.cpuset && job.cpuset.length) ? job.cpuset : [...Array(nc).keys()];
    // Each column is centred on its sample, reaching halfway to the samples either side, so the time
    // line of a sample runs through the middle of its column as it does through the other charts' points.
    const t = cols.map(ms), gap = (ci) => ci > 0 ? t[ci] - t[ci - 1] : (t.length > 1 ? t[1] - t[0] : 2000);
    const starts = t.map((v, ci) => v - gap(ci) / 2);
    const ends = t.map((v, ci) => v + (ci + 1 < t.length ? t[ci + 1] - v : gap(ci)) / 2);
    const loads = cols.map(x => { const c = (x.host || {}).cores || []; return own.map(k => c[k] ?? 0); });
    const data = [];
    // [sample time, row, load, start, end]: the sample time is what the time axis sees, so the hover
    // snaps to the middle of a column; its edges are only drawn.
    cols.forEach((x, ci) => loads[ci].forEach((v, row) => data.push([t[ci], row, v, starts[ci], ends[ci]])));
    // Dark when idle, through blue at moderate load, warming to red at full.
    const RAMP = ['#151a2b', '#1d3f7a', '#2f7fd0', '#36b3a8', '#e3c34a', '#f08a3c', '#e5484d'];
    // The sample nearest the hovered time.
    const colAt = (x) => { let best = 0; t.forEach((v, ci) => { if (Math.abs(v - x) < Math.abs(t[best] - x)) best = ci; }); return best; };
    // The hover follows the time line shared with the charts above, and sums the cores at that time.
    heat = { animation: false, grid: { left: 56, right: 16, top: 8, bottom: 24 }, xAxis: AXIS,
      yAxis: { type: 'category', data: own.map(String), name: own.length < nc ? 'job cores' : 'core',
               axisPointer: { show: false }, axisLabel: { interval: Math.max(0, Math.ceil(own.length / 8) - 1) } },
      tooltip: { trigger: 'axis', axisPointer: { axis: 'x', type: 'line' }, formatter: (ps) => {
        const p = Array.isArray(ps) ? ps[0] : ps, l = p ? loads[colAt(+p.axisValue)] : null;
        if (!l || !l.length) return '';
        let top = 0; l.forEach((v, r) => { if (v > l[top]) top = r; });
        const total = l.reduce((a, v) => a + v, 0) / 100;
        return total.toFixed(1) + ' of ' + l.length + ' cores<br>busiest core ' + own[top] + ' · ' + Math.round(l[top]) + '%';
      } },
      // Drawn in one pass: a series this large is otherwise painted over several frames, which shows
      // as the map filling in on every update.
      series: [{ type: 'custom', encode: { x: 0, y: 1 }, data, progressive: 0,
        renderItem: (params, api) => {
          const row = api.value(1), a = api.coord([api.value(3), row]), b = api.coord([api.value(4), row]);
          const h = api.size([0, 1])[1], cs = params.coordSys;
          const r = window.echarts.graphic.clipRectByRect(
            { x: a[0], y: a[1] - h / 2, width: Math.max(1, b[0] - a[0] + 0.5), height: h },
            { x: cs.x, y: cs.y, width: cs.width, height: cs.height });
          return r && { type: 'rect', shape: r,
                        style: { fill: window.echarts.color.lerp(Math.min(1, Math.max(0, api.value(2) / 100)), RAMP) } };
        } }] };
  }

  const hasIO = s.some(x => (x.proc || {}).io_read >= 0 || (x.host || {}).net_rx >= 0);
  const io = !hasIO ? null : base('per second', B, {
    series: [line('read', series(s, x => (x.proc || {}).io_read)), line('write', series(s, x => (x.proc || {}).io_write)),
             host.net_rx != null ? line('net in', series(s, x => (x.host || {}).net_rx)) : null,
             host.net_tx != null ? line('net out', series(s, x => (x.host || {}).net_tx)) : null].filter(Boolean) });
  const psi = host.psi_cpu >= 0 ? base('% of time', pctTick, { yAxis: Object.assign({ name: '% of time', nameTextStyle: { align: 'left' } }, pctAxis),
    series: [line('cpu', series(s, x => (x.host || {}).psi_cpu)), line('memory', series(s, x => (x.host || {}).psi_mem)),
             line('io', series(s, x => (x.host || {}).psi_io))] }) : null;
  const julia = base('', pctTick, { yAxis: pctAxis,
    series: [line('gc time', gcPct(s), { areaStyle: { opacity: 0.12 } }),
             proc.compile_ms >= 0 ? line('compile', compilePct(s)) : null].filter(Boolean) });
  const memoStore = s.some(x => (x.memo_bytes ?? x.memo) >= 0)
    ? base('', B, { series: [line('memo store', series(s, x => x.memo_bytes ?? x.memo ?? -1), { areaStyle: { opacity: 0.12 } })] })
    : null;
  const alloc = base('per second', B, { series: [line('allocation', series(s, x => (x.proc || {}).alloc_rate))] });

  // Two charts, each with an axis either side: busy and memory, and power and temperature. Across
  // every GPU, busy and bandwidth are means, the peak the highest, memory and power totals, and the
  // temperature the hottest; a selector narrows them all to one GPU.
  const each = gpus.length > 1 && gpuPick.value === 'each';
  const sel = gpus.length > 1 && gpus.some(g => String(g.i) === gpuPick.value) ? +gpuPick.value : null;
  const mine = gpus.filter(g => sel == null || g.i === sel);
  const sum = (a) => a.reduce((t, v) => t + v, 0), mean = (a) => sum(a) / a.length, top = (a) => Math.max(...a);
  const gv = (f, agg) => (x) => { const v = (x.gpus || []).filter(g => sel == null || g.i === sel).map(f)
                                     .filter(v => v != null && v >= 0); return v.length ? agg(v) : -1; };
  const cap = (f) => (each ? Math.max(0, ...gpus.map(g => g[f] || 0)) : sum(mine.map(g => g[f] || 0))) || null;
  const memCap = cap('mem_total'), powCap = cap('power_limit_w');
  const W = (v) => Math.round(v) + ' W', C = (v) => Math.round(v) + '°C', Pc = (v) => Math.round(v) + '%';
  const right = { splitLine: { show: false } }, grid2 = Object.assign({}, GRID, { right: 56 });
  // `each`: every GPU on its own lines, one colour per GPU, the second-axis figure dashed.
  const HUE = ['#569cd6', '#56d364', '#e3c34a', '#e5636e', '#9d8fd6', '#36b3a8', '#f08a3c', '#c586c0'];
  const one = (g, f) => (x) => { const v = (((x.gpus || [])[g.i] || {})[f]); return v == null ? -1 : v; };
  const perGpu = (f, f2, fmt2) => gpus.flatMap(g => {
    const c = { lineStyle: { width: 2, color: HUE[g.i % HUE.length] }, itemStyle: { color: HUE[g.i % HUE.length] } };
    return [line('gpu' + g.i + ' ' + f.label, series(s, one(g, f.key)), c),
            line('gpu' + g.i + ' ' + f2.label, series(s, one(g, f2.key)),
                 { yAxisIndex: 1, tooltip: { valueFormatter: fmt2 }, itemStyle: c.itemStyle,
                   lineStyle: { width: 1.5, type: 'dashed', color: HUE[g.i % HUE.length] } })];
  });
  const gpuBusy = base('', Pc, { grid: grid2,
    yAxis: [{ type: 'value', min: 0, max: 100, axisLabel: { formatter: Pc }, splitLine: { lineStyle: { opacity: 0.25 } } },
            Object.assign({ type: 'value', min: 0, max: memCap, axisLabel: { formatter: B } }, right)],
    series: each ? perGpu({ key: 'util', label: 'busy' }, { key: 'mem_used', label: 'memory' }, B)
      : [line('busy', series(s, gv(g => g.util, mean)), { areaStyle: { opacity: 0.12 } }),
         line('peak', series(s, gv(g => g.util_max, top)), { raw: true, lineStyle: { width: 1, type: 'dotted', opacity: 0.7 } }),
         line('bandwidth', series(s, gv(g => g.mem_util, mean))),
         line('memory', series(s, gv(g => g.mem_used, sum)), { yAxisIndex: 1, tooltip: { valueFormatter: B } })] });
  const gpuHeat = base('', W, { grid: grid2,
    yAxis: [{ type: 'value', min: 0, max: powCap, axisLabel: { formatter: W }, splitLine: { lineStyle: { opacity: 0.25 } } },
            Object.assign({ type: 'value', min: 0, axisLabel: { formatter: C } }, right)],
    series: each ? perGpu({ key: 'power_w', label: 'power' }, { key: 'temp', label: 'temperature' }, C)
      : [line('power', series(s, gv(g => g.power_w, sum))),
         line('temperature', series(s, gv(g => g.temp, top)), { yAxisIndex: 1, tooltip: { valueFormatter: C } })] });
  const picked = each ? 'each' : sel == null ? 'all' : String(sel);
  const gpuSel = gpus.length > 1 ? html`<span class="tm-seg">${[['all', 'all'], ['each', 'each'], ...gpus.map(g => [String(g.i), 'gpu' + g.i])]
      .map(([k, l]) => html`<button class=${'tm-segb' + (picked === k ? ' on' : '')}
                                    onClick=${() => { gpuPick.value = k; }}>${l}</button>`)}</span>` : null;
  const gpuSec = gpus.length ? html`<${Section} title="GPU" aside=${gpuSel}>
      <div class="tm-gpus">${mine.map(g => html`<div class="tm-gpu">
        <div class="tm-gname">gpu${g.i} · ${g.name}</div>
        <div class="tm-gstats">
          <span>${pct(g.util)} busy</span><span>${pct(g.mem_util)} memory bandwidth</span>
          <span>${g.temp >= 0 ? g.temp + '°C' : '—'}</span>
          <span>${g.power_w >= 0 ? Math.round(g.power_w) + (g.power_limit_w > 0 ? ' / ' + Math.round(g.power_limit_w) : '') + ' W' : '—'}</span>
          <span>${g.sm_mhz >= 0 ? g.sm_mhz + (g.sm_max_mhz > 0 ? ' / ' + g.sm_max_mhz : '') + ' MHz' : ''}</span>
          ${g.mem_total > 0 ? html`<span>${B(g.mem_total)} memory</span>` : null}
          ${g.proc_mem > 0 ? html`<span>this worker ${B(g.proc_mem)}</span>` : null}
          ${(g.throttle || []).length ? html`<span class="tm-throttle">held back: ${g.throttle.join(', ')}</span>` : null}
        </div></div>`)}</div>
      <div class="tm-grid"><${Chart} option=${gpuBusy}/><${Chart} option=${gpuHeat}/></div></${Section}>` : null;

  const gcSel = gcEach ? html`<label class="tm-tog">
      <input type="checkbox" checked=${gcShow.value === 'full'}
             onChange=${(e) => { gcShow.value = e.currentTarget.checked ? 'full' : 'all'; }}/><i></i>full GC only</label>` : null;
  const gcButtons = v.nb ? [['Minor GC', false], ['Full GC', true]]
      .map(([l, full]) => html`<button class="tm-btn" disabled=${gcBusy.value}
                                          onClick=${() => collectNow(v, full)}>${l}</button>`) : null;
  const gcCtl = gcSel || gcButtons ? html`<span class="tm-gcctl">${gcSel}${gcButtons}</span>` : null;

  return html`<div class="tm-bg" onMouseDown=${e => e.target.classList.contains('tm-bg') && close()}>
    <div class="tm-card" role="dialog" aria-modal="true">
      ${head}${acts}
      <div class="tm-body">
        ${tiles}
        <${Section} title="Timeline" aside=${html`${spanKey}${gcCtl}`}>${running}</${Section}>
        <${Section} title="CPU" aside=${cpuLimit}><div class="tm-grid"><${Chart} option=${cpu}/>${heat ? html`<${Chart} option=${heat}/>` : null}</div></${Section}>
        <${Section} title="Memory" aside=${memLimitText}><${Chart} option=${mem}/></${Section}>
        ${gpuSec}
        ${io || psi ? html`<${Section} title=${io && psi ? 'I/O and pressure' : io ? 'I/O' : 'Pressure'}><div class="tm-grid">
          ${io ? html`<${Chart} option=${io}/>` : null}${psi ? html`<${Chart} option=${psi}/>` : null}</div></${Section}>` : null}
        <${Section} title="Julia runtime"><div class="tm-grid"><${Chart} option=${julia}/><${Chart} option=${alloc}/>
          ${memoStore ? html`<${Chart} option=${memoStore}/>` : null}</div></${Section}>
      </div></div></div>`;
}

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Telemetry} />`, host);
document.addEventListener('visibilitychange', () => { if (!document.hidden && view.value) poll(gen); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && view.value) { e.stopImmediatePropagation(); close(); }
}, true);
