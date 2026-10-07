// The steps of preparing a region, as they land: shared by the notebook's Prepare dialog
// (regionprep.js) and the Remotes region panel, so a prepare reads the same in both places.
import { html } from 'htm/preact';
import { signal } from '@preact/signals';

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

// Every prepare this region has had, newest first, each opening to its steps and activity. Reports
// are kept by the hub, never rewritten, so a run that failed or was cut off can still be read.
const hist = signal({});   // key -> { open, list, sel, report }
const OUTCOME = { ok: '✓ ok', warnings: '⚠ warnings', failed: '✗ failed', interrupted: '⏸ interrupted', running: '… running' };
const whenOf = id => {   // "20261001T121234" (UTC) → local date and time
  const m = /^(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)$/.exec(id || '');
  return m ? new Date(Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +m[6])).toLocaleString() : id;
};
export function History(name, key) {
  const h = hist.value[key] || {};
  const put = p => { hist.value = { ...hist.value, [key]: { ...(hist.value[key] || {}), ...p } }; };
  const flip = () => {
    if (h.open) { put({ open: false }); return; }
    put({ open: true, list: null, sel: '', report: null });
    fetch('/api/regions/prepare/reports?name=' + encodeURIComponent(name)).then(r => r.json())
      .then(d => put({ list: (d && d.reports) || [] })).catch(() => put({ list: [] }));
  };
  const pick = id => {
    put({ sel: id, report: null });
    fetch('/api/regions/prepare/report?name=' + encodeURIComponent(name) + '&id=' + encodeURIComponent(id))
      .then(r => r.json()).then(d => put({ report: d && d.ok ? d.report : null })).catch(() => {});
  };
  return html`<div class="rpplog">
    <button type="button" class="rpplogbtn" onClick=${flip}>${h.open ? '▾' : '▸'} History</button>
    ${!h.open ? null : html`<div class="rpphist">
      ${h.list === null ? html`<span class="pddim">…</span>`
        : !h.list.length ? html`<span class="pddim">none yet</span>`
        : h.list.map(x => html`<div class=${'rpphistrow ' + x.outcome + (h.sel === x.id ? ' sel' : '')} onClick=${() => pick(x.id)}>
            <span>${whenOf(x.id)}</span> <span class="rpphistout">${OUTCOME[x.outcome] || x.outcome}</span>
            ${x.failures ? html`<span class="pddim"> · ${x.failures} failed</span>` : null}
            ${x.warnings ? html`<span class="pddim"> · ${x.warnings} warned</span>` : null}</div>`)}
      ${h.report ? html`<div class="rpphistrep">${StepList(h.report.steps)}${Activity(h.report.log, 'rep:' + key + ':' + h.sel)}</div>` : null}
    </div>`}
  </div>`;
}

// The same two, always open, for a dialog that gives them a column of their own (regionprep.js):
// the activity fills it and follows the newest line; the history lists its runs straight away.
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
