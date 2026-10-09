// Scheduler use: how many scheduler commands (squeue, srun, sbatch, qstat, …) this hub has sent a
// machine, against the per-minute budget sites ask for. A row in the machine pane shows the live
// counts; its Details opens a dashboard with one bar per minute over recent hours and what those
// minutes held, by command and by the Slate function that sent them. Everything comes from the hub's
// own count (GET /api/sched-calls); nothing here asks the cluster.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect, useRef } from 'preact/hooks';
import { chartsReady, initChart } from './telemetry.js';

const live = signal({});            // host → the endpoint's reply for the last hour
const dash = signal(null);          // {host, hours} while the dashboard is open
const dashData = signal(null);
const RANGES = [[1, '1h'], [6, '6h'], [24, '24h'], [168, '7d']];

const get = (host, hours) =>
  fetch('/api/sched-calls?host=' + encodeURIComponent(host) + '&hours=' + hours).then(r => r.json()).catch(() => null);

/** The machine pane's row: the last minute and the last ten against the budget. */
export function SchedUse({ host }) {
  useEffect(() => {
    let off = false;
    const load = () => get(host, 1).then(d => { if (!off && d) live.value = { ...live.value, [host]: d }; });
    load();
    const t = setInterval(load, 15000);
    return () => { off = true; clearInterval(t); };
  }, [host]);
  const d = live.value[host];
  const over = d && d.last_minute > d.budget;
  return html`<div class="rpprow"><label>Scheduler use</label><div class="rppprephead">
      ${!d ? html`<span class="pddim">…</span>` : html`<span class=${over ? 'rppsyswarn' : 'pddim'}>
        ${d.last_minute} in the last minute · ${d.last_10} in 10 min · ${d.in_window} in the hour · budget ${d.budget}/min</span>`}
      <button class="rppsysbtn" onClick=${() => openSchedUse(host)}>Details</button></div></div>`;
}

export function openSchedUse(host) {
  dash.value = { host, hours: 24 };
  load();
}
function load() {
  const v = dash.value; if (!v) return;
  get(v.host, v.hours).then(d => { if (dash.value === v || (dash.value && dash.value.host === v.host && dash.value.hours === v.hours)) dashData.value = d; });
}
function close() { dash.value = null; dashData.value = null; }
function setRange(h) { dash.value = { ...dash.value, hours: h }; dashData.value = null; load(); }

function Chart({ series, budget, hours }) {
  const el = useRef(null), inst = useRef(null);
  useEffect(() => {
    let alive = true;
    chartsReady().then(() => {
      if (!alive || !el.current) return;
      inst.current = initChart(el.current);
      const ro = new ResizeObserver(() => inst.current && inst.current.resize()); ro.observe(el.current);
      inst.current.__ro = ro;
      paint();
    });
    return () => { alive = false; if (inst.current) { inst.current.__ro && inst.current.__ro.disconnect(); inst.current.dispose(); } };
  }, []);
  const paint = () => inst.current && inst.current.setOption({
    animation: false,
    grid: { left: 40, right: 16, top: 16, bottom: 28 },
    tooltip: { trigger: 'axis', valueFormatter: v => v + ' commands' },
    xAxis: { type: 'time', min: Date.now() - hours * 3600e3, max: Date.now() },
    yAxis: { type: 'value', minInterval: 1, splitLine: { lineStyle: { opacity: 0.25 } } },
    series: [{ type: 'bar', name: 'commands per minute', data: series, barMaxWidth: 6,
               itemStyle: { color: p => p.value[1] > budget ? '#d9a441' : '#569cd6' },
               markLine: { silent: true, symbol: 'none', label: { formatter: 'budget ' + budget + '/min', color: '#d9a441', position: 'insideEndTop' },
                           lineStyle: { color: '#d9a441', type: 'dashed' }, data: [{ yAxis: budget }] } }],
  }, true);
  useEffect(paint);
  return html`<div class="tm-chart" ref=${el} style="height:260px"></div>`;
}

function Tile(label, value, sub, warn) {
  return html`<div class=${'tm-tile' + (warn ? ' warn' : '')}>
    <div class="tm-ttop"><span class="tm-tlabel">${label}</span><span class="tm-tval">${value}</span></div>
    ${sub ? html`<div class="tm-tsub">${sub}</div>` : null}</div>`;
}

function Dashboard() {
  const v = dash.value; if (!v) return null;
  const d = dashData.value;
  const span = RANGES.find(([h]) => h === v.hours)?.[1] || v.hours + 'h';
  const head = html`<div class="tm-head">
      <div><div class="tm-title">Scheduler use · ${v.host}</div>
        <div class="tm-sub">commands this hub sent ${v.host}'s scheduler${d ? ' · budget ' + d.budget + '/min (KAIMONSLATE_SCHED_BUDGET)' : ''}</div></div>
      <div class="tm-ranges">${RANGES.map(([h, l]) => html`<button class=${v.hours === h ? 'on' : ''} onClick=${() => setRange(h)}>${l}</button>`)}</div>
      <button class="tm-x" title="Close (Esc)" onClick=${close}>✕</button></div>`;
  const body = !d ? html`<div class="tm-empty">loading…</div>` : html`
    <div class="tm-tiles">
      ${Tile('last minute', d.last_minute, '', d.last_minute > d.budget)}
      ${Tile('last 10 min', d.last_10, (d.last_10 / 10).toFixed(1) + '/min', d.last_10 / 10 > d.budget)}
      ${Tile('in ' + span, d.in_window, (d.in_window / (v.hours * 60)).toFixed(2) + '/min average', false)}
      ${Tile('busiest minute', d.peak, d.over ? d.over + ' minute' + (d.over === 1 ? '' : 's') + ' over budget' : 'none over budget', d.over > 0)}
      ${Tile('since the hub started', d.since_start, '', false)}
    </div>
    <section class="tm-sec"><div class="tm-sechead"><h3>Commands per minute</h3></div>
      ${d.series.length ? html`<${Chart} series=${d.series} budget=${d.budget} hours=${v.hours} />`
                        : html`<div class="tm-empty">nothing sent in this window</div>`}</section>
    <section class="tm-sec"><div class="tm-sechead"><h3>By command and caller · ${span}</h3></div>
      ${d.by.length ? html`<table class="sc-tab"><thead><tr><th>command</th><th>sent by</th><th class="n">count</th><th class="n">share</th></tr></thead>
        <tbody>${d.by.map(r => html`<tr><td><code>${r.command}</code></td><td><code>${r.caller}</code></td>
          <td class="n">${r.n}</td><td class="n">${d.in_window ? Math.round(100 * r.n / d.in_window) + '%' : ''}</td></tr>`)}</tbody></table>`
                    : html`<div class="tm-empty">nothing sent in this window</div>`}</section>`;
  return html`<div class="tm-bg" onMouseDown=${e => e.target.classList.contains('tm-bg') && close()}>
      <div class="tm-card sc-card">${head}<div class="tm-body">${body}</div></div></div>`;
}

document.addEventListener('keydown', e => { if (e.key === 'Escape' && dash.value) close(); });
const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Dashboard} />`, host);
