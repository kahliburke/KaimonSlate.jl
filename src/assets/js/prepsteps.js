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
const shortTime = l => String(l).replace(/^\[\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d)\.\d+\] /, '$1  ');
export function Activity(lines, key) {
  if (!lines || !lines.length) return null;
  const open = !!openActs.value[key];
  const flip = () => { openActs.value = { ...openActs.value, [key]: !open }; };
  return html`<div class="rpplog">
    <button type="button" class="rpplogbtn" onClick=${flip}>${open ? '▾' : '▸'} Activity <span class="pddim">${lines.length} lines</span></button>
    ${open ? html`<pre class="rpplogtext" ref=${el => { if (el) el.scrollTop = el.scrollHeight; }}>${lines.map(shortTime).join('\n')}</pre>` : null}
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
