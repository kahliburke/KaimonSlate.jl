// The steps of a prepare as they land, its activity and its earlier runs: the parts of the prepare
// dialog (prepdialog.js), and the tested environments the Remotes and Machines panels list.
import { html } from 'htm/preact';
import { signal } from '@preact/signals';
import { ago } from './workerbar.js';

const STEP_MARK = { ok: '✓', warn: '⚠', fail: '✗' };

// Seconds as m:ss. Time is the hub's (`now`), so a laptop whose clock is off still reads it right.
function elapsed(since, now) {
  const t = Math.max(0, Math.round(now - since));
  return t < 60 ? t + 's' : Math.floor(t / 60) + 'm ' + String(t % 60).padStart(2, '0') + 's';
}

// `clock` is the hub's time at the last poll, and `lastOut` when the hub last heard anything from the
// work. A running step shows both, so a slow step reads differently from one that has stopped.
export function StepList(steps, clock = 0, lastOut = 0) {
  return html`<div class="rppprepsteps">${(steps || []).map(s => html`<div class=${'rppprepstep ' + s.status}>
      <span class="rppprepmark">${s.status === 'running' ? html`<span class="hydspin"></span>` : (STEP_MARK[s.status] || '?')}</span>
      <span class="rppprepname">${s.step}</span>${s.secs ? html`<span class="pddim"> ${s.secs}s</span>` : null}
      ${s.status === 'running' && s.started ? html`<span class="pddim"> ${elapsed(s.started, clock)}${
        lastOut ? ' · last output ' + elapsed(lastOut, clock) + ' ago' : ''}</span>` : null}
      ${s.detail ? html`<div class="rppprepdetail">${s.detail}</div>` : null}</div>`)}</div>`;
}

// The hub's log lines for a prepare, behind a toggle: the detail under a step's one-line summary, and
// what is left to read when a step warned or failed. Kept open or shut per `key` across re-renders.
const openActs = signal({});
// A log that follows new lines only while it is scrolled to the bottom: reading back up holds it
// there until it is scrolled down again.
const atBottom = el => el.scrollHeight - el.scrollTop - el.clientHeight < 8;
export const follow = el => { if (el && el._follow !== false) el.scrollTop = el.scrollHeight; };
export const noteScroll = e => { e.currentTarget._follow = atBottom(e.currentTarget); };
const shortTime = l => String(l).replace(/^\[\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d)\.\d+\] /, '$1  ');
// The lines as HTML, in a program's own colours (Julia runs with them on the cluster).
const logHtml = lines => lines.map(l => window.slateAnsiHtml(shortTime(l))).join('\n');
export function Activity(lines, key) {
  if (!lines || !lines.length) return null;
  const open = !!openActs.value[key];
  const flip = () => { openActs.value = { ...openActs.value, [key]: !open }; };
  return html`<div class="rpplog">
    <button type="button" class="rpplogbtn" onClick=${flip}>${open ? '▾' : '▸'} Activity <span class="pddim">${lines.length} lines</span></button>
    ${open ? html`<pre class="rpplogtext" ref=${el => follow(el)} onScroll=${noteScroll} dangerouslySetInnerHTML=${{ __html: logHtml(lines) }}></pre>` : null}
  </div>`;
}

// Whether a finished prepare left anything to look at.
export const hasWarnings = rec => !!(rec && (rec.steps || []).some(s => s.status === 'warn' || s.status === 'fail'));

// Every prepare a region or machine has had, newest first, each opening to its steps and activity.
// Reports are kept by the hub, never rewritten, so a run that failed or was cut off can still be read.
const hist = signal({});   // key -> { open, list, sel, report }
const OUTCOME = { ok: '✓ ok', warnings: '⚠ warnings', failed: '✗ failed', interrupted: '⏸ interrupted', running: '… running' };
const whenOf = id => {   // "20261001T121234" (UTC) → local date and time
  const m = /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)$/.exec(id || '');
  return m ? new Date(Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6])).toLocaleString() : id;
};
// The activity and the history as panes of the prepare dialog (prepdialog.js): the activity fills
// its column and follows the newest line; the history lists its runs straight away.
// A command's output arrives tagged on every line (`⟨sysimage on c1⟩`); the pane shows the tag once,
// as a heading where it changes, so the lines keep their width for what they say.
export function ActivityPane(lines) {
  if (!lines || !lines.length) return html`<div class="pddim rppanempty">nothing yet</div>`;
  const out = []; let tag = null, run = [];
  const flush = () => { if (run.length) { out.push(html`<span dangerouslySetInnerHTML=${{ __html: logHtml(run) + '\n' }}></span>`); run = []; } };
  for (const l of lines) {
    const t = shortTime(l), m = /^(\S+\s+)⟨([^⟩]+)⟩\s?(.*)$/.exec(t);
    const here = m ? m[2] : null;
    if (here !== tag) { flush(); if (here) out.push(html`<span class="rppantag">${here}</span>`); tag = here; }
    run.push(m ? m[1] + m[3] : t);
  }
  flush();
  return html`<pre class="rpplogtext rppanelog" ref=${el => follow(el)} onScroll=${noteScroll}>${out}</pre>`;
}
export function HistoryPane(name, key) {
  const h = hist.value[key] || {};
  const put = p => { hist.value = { ...hist.value, [key]: { ...(hist.value[key] || {}), ...p } }; };
  if (h.list === undefined && !h.loading) {
    put({ loading: true, list: null });
    fetch('/api/regions/prepare/reports?name=' + encodeURIComponent(name)).then(r => r.json())
      .then(d => put({ list: (d && d.reports) || [], loading: false })).catch(() => put({ list: [], loading: false }));
  }
  const pick = id => {
    if (h.sel === id) { put({ sel: '', report: null }); return; }
    put({ sel: id, report: null });
    fetch('/api/regions/prepare/report?name=' + encodeURIComponent(name) + '&id=' + encodeURIComponent(id))
      .then(r => r.json()).then(d => put({ report: d && d.ok ? d.report : null })).catch(() => {});
  };
  return html`<div class="rpphist rppanehist">
    ${!h.list ? html`<span class="pddim">…</span>`
      : !h.list.length ? html`<span class="pddim rppanempty">none yet</span>`
      : h.list.map(x => html`<div>
          <div class=${'rpphistrow ' + x.outcome + (h.sel === x.id ? ' sel' : '')} onClick=${() => pick(x.id)}>
            <span>${whenOf(x.id)}</span> <span class="rpphistout">${OUTCOME[x.outcome] || x.outcome}</span>
            ${x.failures ? html`<span class="pddim"> · ${x.failures} failed</span>` : null}
            ${x.warnings ? html`<span class="pddim"> · ${x.warnings} warned</span>` : null}</div>
          ${h.sel === x.id && h.report ? html`<div class="rpphistrep">${StepList(h.report.steps)}${Activity(h.report.log, 'rep:' + key + ':' + h.sel)}</div>` : null}
        </div>`)}
  </div>`;
}
// A history to read again from the start the next time the pane opens (a prepare just ended).
export const forgetHistory = key => { const v = { ...hist.value }; delete v[key]; hist.value = v; };

// The environments a test task has loaded on a machine or region: one line of counts that opens to a
// table, newest first. `self` is the panel's own name, left out of the "by" column. Open or shut per
// `key` across re-renders.
const openEnvs = signal({});
const ENV_MARK = { ready: '✓', changed: '⚠', fail: '✗' };
const envState = t => t.status === 'fail' ? 'fail' : t.changed ? 'changed' : 'ready';
const nodeOf = t => String(t.node_type || '').replace(/^\/|\/$/g, '');
const cudaOf = t => t.cuda ? (String(t.cuda.functional).startsWith('true') ? 'ok' : 'not functional') : '';
export function Environments(list, key, self = '') {
  if (!list || !list.length) return null;
  const rows = [...list].sort((a, b) => (+b.tested_at || 0) - (+a.tested_at || 0));
  const n = { ready: 0, changed: 0, fail: 0 };
  for (const t of rows) n[envState(t)]++;
  const counts = [n.ready ? n.ready + ' ready' : '', n.changed ? n.changed + ' changed' : '', n.fail ? n.fail + ' failed' : '']
    .filter(Boolean).join(' · ');
  const open = !!openEnvs.value[key];
  const flip = () => { openEnvs.value = { ...openEnvs.value, [key]: !open }; };
  const showNode = rows.some(nodeOf), showBy = rows.some(t => t.by && t.by !== self), showCuda = rows.some(t => t.cuda);
  return html`<div class="rpplog">
    <button type="button" class="rpplogbtn" onClick=${flip}>${open ? '▾' : '▸'} Environments <span class="pddim">${counts}</span></button>
    ${!open ? null : html`<div class="rppenvs"><table class="rppenvtab">
      <thead><tr><th></th><th>project</th>${showNode ? html`<th>node</th>` : null}${showBy ? html`<th>by</th>` : null}
        <th class="num">loads</th>${showCuda ? html`<th>CUDA</th>` : null}<th class="num">tested</th></tr></thead>
      <tbody>${rows.map(t => { const s = envState(t); return html`<tr class=${s}
          title=${s === 'changed' ? 'packages changed since this test' : s === 'fail' ? 'failed to load' : ''}>
        <td class="rppenvmark">${ENV_MARK[s]}</td>
        <td class="rppenvproj" title=${t.project || ''}>${String(t.project || '').split('/').pop()}</td>
        ${showNode ? html`<td>${nodeOf(t) || 'default'}</td>` : null}
        ${showBy ? html`<td>${t.by && t.by !== self ? t.by : ''}</td>` : null}
        <td class="num">${t.load_s ? t.load_s + 's' : ''}</td>
        ${showCuda ? html`<td>${cudaOf(t)}</td>` : null}
        <td class="num">${t.tested_at ? ago(t.tested_at) : ''}</td></tr>`; })}</tbody>
    </table></div>`}
  </div>`;
}
