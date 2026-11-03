// THE PREPARE DIALOG — one prepare of a region, a machine, or a notebook's environment on a machine,
// with its steps on the left and the activity and earlier runs on the right.
//
// Opened by a notebook (regionprep.js) and by the Remotes and Machines panels. The caller says what is
// being prepared: `key` is the name its runs are kept under (`/api/regions/prepare?name=`), `start`
// asks the hub to begin one. Preparing runs in the hub; this only starts it and shows each step as it
// lands.
//
import { html } from 'htm/preact';
import { render } from 'preact';
import { signal, effect } from '@preact/signals';
import { lockScroll } from './scrolllock.js';
import { StepList, ActivityPane, HistoryPane, forgetHistory, hasWarnings, follow, noteScroll } from './prepsteps.js';

// {key, title, sub, planned, start, reason, explain, notebook, onPoll, onClose} while the dialog is up.
//   start()   → Promise of the hub's reply ({ok:false, error} when it would not start)
//   before(go) a step of the opener's own before starting (a modal of its own); it calls `go` to start
//   planned   the steps to show before the first prepare
//   notebook  the notebook's id, when a notebook opened it: its cells wait on the prepare, so the
//             dialog closes once every step passes
//   onPoll(d) each payload, so the panel that opened it can follow along
const dlg   = signal(null);
const st    = signal(null);   // last /api/regions/prepare payload for `dlg.key`
const begun = signal(false);  // this dialog started (or found) a prepare
// Set by a click until the hub reports a run that began after it: the button stays disabled, and the
// dialog keeps asking rather than reading the last finished run as the answer.
const awaiting = signal(null); // { after: hub time of the last run seen, tries } | null
const err = signal('');
const tab = signal('activity');   // the right column: 'activity' | 'history'

function poll(key) {
  const cur = dlg.value; if (!cur || cur.key !== key) return;
  fetch('/api/regions/prepare?name=' + encodeURIComponent(key) + (cur.notebook ? '&nb=' + encodeURIComponent(cur.notebook) : ''))
    .then(r => r.json()).then(d => {
    const cur = dlg.value;
    if (!cur || cur.key !== key || !d) return;
    if (!d.ok) { awaiting.value = null; err.value = d.error || 'the hub could not read this prepare'; st.value = st.value || {}; return; }
    const w = awaiting.value;
    if (w) {
      const seen = d.preparing && (+d.preparing.started || 0) > w.after;
      if (!seen) {
        if (w.tries >= 40) { awaiting.value = null; err.value = 'the hub did not start it; see the hub log'; return; }
        awaiting.value = { ...w, tries: w.tries + 1 };
        setTimeout(() => poll(key), 750);
        return;
      }
      awaiting.value = null;
    }
    st.value = d;
    cur.onPoll && cur.onPoll(d);
    const running = !!(d.preparing && d.preparing.running);
    if (running) { begun.value = true; setTimeout(() => poll(key), 1500); return; }
    forgetHistory('dlg:' + key);   // the run that just ended belongs in the history
    // A notebook's cells are already running again once every step passes, so there is nothing left
    // to ask. A warning keeps it open, since that is the part worth reading.
    const rec = (d.preparing && d.preparing.record) || d.readiness || {};
    if (cur.notebook && begun.value && rec.ok && !hasWarnings(rec))
      setTimeout(() => { if (dlg.value && dlg.value.key === key) close(); }, 2500);
  }).catch(() => {});
}

export function startPrepare() {
  const cur = dlg.value; if (!cur || awaiting.value) return;
  cur.before ? cur.before(begin) : begin();
}
function begin() {
  const cur = dlg.value; if (!cur || awaiting.value) return;
  const s = st.value;
  begun.value = true; err.value = '';
  awaiting.value = { after: (s && s.preparing && +s.preparing.started) || 0, tries: 0 };
  Promise.resolve(cur.start())
    .then(d => { if (d && d.ok === false) { awaiting.value = null; err.value = d.error || 'could not start'; return; }
                 setTimeout(() => poll(cur.key), 300); })
    .catch(() => { awaiting.value = null; err.value = 'request failed'; });
}

// Open the dialog on `p`; `go` also starts a prepare. A dialog already showing `p.key` is kept.
export function openPrepare(p, go = false) {
  if (!p || !p.key) return;
  if (!(dlg.value && dlg.value.key === p.key)) {
    if (dlg.value) close();
    dlg.value = p; st.value = null; begun.value = false; awaiting.value = null; err.value = ''; tab.value = 'activity';
    forgetHistory('dlg:' + p.key);
    poll(p.key);
  }
  if (go) startPrepare();
}
export const preparingKey = () => dlg.value && dlg.value.key;

function close() {
  const cur = dlg.value; dlg.value = null;
  cur && cur.onClose && cur.onClose();
}

function PrepareDialog() {
  const d = dlg.value;
  if (!d) return null;
  const s = st.value;
  const running = !!(s && s.preparing && s.preparing.running);
  // Not running: the last report, whether this dialog started it or is only showing it.
  const rec = s && !running ? ((s.preparing && s.preparing.record) || s.readiness) : null;
  const has = !!(rec && rec.prepared_at);
  const steps = running ? s.preparing.steps : (has ? rec.steps : null);
  const done = !running && has;
  const log = running ? s.preparing.log : (has ? s.last_log : null);
  // Why it needs preparing: as given by the opener, else as the hub reads it for this notebook.
  // Shown until this dialog starts a prepare, over an earlier report as much as over none.
  const why = d.reason || (s && s.reason) || '';
  const explain = typeof d.explain === 'function' ? d.explain(has) : (d.explain || '');
  const later = has ? 'Close' : 'Later';
  return html`<div class="anbg"><div class="ancard rpcard" role="dialog" aria-modal="true">
    <div class="rphead">${d.title}</div>
    <div class="pddim rpsub">${d.sub || ''}${!s ? html` <span class="hydspin"></span>` : null}</div>
    <div class="rpsplit">
      <div class="rppane">
        <div class="slate-tabs rpstrip"><span class="rpstriplabel">Steps</span></div>
        <div class="rptabbody" ref=${el => follow(el)} onScroll=${noteScroll}>
        ${steps ? StepList(steps, running ? s.preparing.now : 0, running ? s.preparing.last_output : 0)
                : html`<div class="rppprepsteps">${(d.planned || []).map(t => html`<div class="rppprepstep planned"><span class="rppprepmark">·</span><span class="rppprepname">${t}</span></div>`)}</div>`}
        ${done ? html`<div class=${rec.ok && !hasWarnings(rec) ? 'rppsysok rpres' : 'rppsyswarn rpres'}>${
            !rec.ok ? '⚠ finished with failures'
            : hasWarnings(rec) ? '⚠ prepared, with warnings'
            : begun.value && d.notebook ? '✓ prepared — the waiting cells are running' : '✓ prepared'} · ${new Date(rec.prepared_at * 1000).toLocaleString()}</div>` : null}
        </div>
      </div>
      <div class="rppane">
        <div class="slate-tabs rpstrip">
          <button class=${tab.value === 'activity' ? 'on' : ''} onClick=${() => tab.value = 'activity'}>Activity${log && log.length ? html`<span class="n">${log.length}</span>` : null}</button>
          <button class=${tab.value === 'history' ? 'on' : ''} onClick=${() => tab.value = 'history'}>History</button>
        </div>
        <div class="rptabbody">${tab.value === 'activity' ? ActivityPane(log) : HistoryPane(d.key, 'dlg:' + d.key)}</div>
      </div>
    </div>
    <div class="rpbtns">
      ${err.value ? html`<span class="rppsyswarn" style="margin-right:auto">${err.value}</span>`
        : why && !running && !begun.value ? html`<div class="rpwhy">${why} ${explain}</div>` : null}
      ${!s && !awaiting.value && !begun.value ? html`<button class="anbtn primary" disabled><span class="hydspin"></span></button>
                                                     <button class="anbtn" onClick=${close}>${later}</button>`
        : awaiting.value ? html`<button class="anbtn primary" disabled>Starting…</button>`
        : running ? html`<button class="anbtn" onClick=${close}>Hide</button>`
        : done ? html`<button class=${'anbtn' + (rec.ok ? '' : ' primary')} onClick=${startPrepare}>Prepare again</button>
                   <button class="anbtn" onClick=${close}>Close</button>`
        : html`<button class="anbtn primary" onClick=${startPrepare}>Prepare</button>
               <button class="anbtn" onClick=${close}>Later</button>`}
    </div>
  </div></div>`;
}

effect(() => lockScroll('prepdialog', !!dlg.value));

const host = document.createElement('div');
host.id = 'prepdialogbg';
document.body.appendChild(host);
render(html`<${PrepareDialog} />`, host);

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && dlg.value) { e.stopPropagation(); close(); }
}, true);
