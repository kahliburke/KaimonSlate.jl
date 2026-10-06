// PREPARE A REGION — the dialog a notebook shows before its first worker on a region.
//
// The hub holds a region cell (`needs_prepare`) when this notebook's project was never prepared on
// the region, or the site has changed since, and pushes `regionprep:` on an explicit run. The cell's
// chip opens the same dialog. Preparing runs in the hub (`prepare_region!`); this only starts it and
// shows each step as it lands, from `/api/regions/prepare`. The waiting cells run when it ends.
//
import { html } from 'htm/preact';
import { render } from 'preact';
import { signal, effect } from '@preact/signals';
import { lockScroll } from './scrolllock.js';
import { StepList, ActivityPane, HistoryPane, forgetHistory, hasWarnings, follow, noteScroll } from './prepsteps.js';
import { openImagePackages } from './imagepkgs.js';

const dlg   = signal(null);   // {region, host, scheduler} while the dialog is up
const st    = signal(null);   // last /api/regions/prepare payload for that region
const begun = signal(false);  // this dialog started (or found) a prepare
// Set by a click until the hub reports a run that began after it: the button stays disabled, and the
// dialog keeps asking rather than reading the last finished run as the answer.
const awaiting = signal(null); // { after: hub time of the last run seen, tries } | null

function poll(name) {
  const nb = (window.__slateState || {}).id || '';
  fetch('/api/regions/prepare?name=' + encodeURIComponent(name) + (nb ? '&nb=' + encodeURIComponent(nb) : ''))
    .then(r => r.json()).then(d => {
    const cur = dlg.value;
    if (!cur || cur.region !== name || !d || !d.ok) return;
    const w = awaiting.value;
    if (w) {
      const seen = d.preparing && (+d.preparing.started || 0) > w.after;
      if (!seen) {
        if (w.tries >= 40) { awaiting.value = null; err.value = 'the hub did not start it; see the hub log'; return; }
        awaiting.value = { ...w, tries: w.tries + 1 };
        setTimeout(() => poll(name), 750);
        return;
      }
      awaiting.value = null;
    }
    st.value = d;
    const running = !!(d.preparing && d.preparing.running);
    if (running) { begun.value = true; setTimeout(() => poll(name), 1500); return; }
    forgetHistory('dlg:' + name);   // the run that just ended belongs in the history
    // Done with every step passing: the cells are already running again, so there is nothing left to
    // ask. A warning keeps it open, since that is the part worth reading.
    const rec = (d.preparing && d.preparing.record) || d.readiness || {};
    if (begun.value && rec.ok && !hasWarnings(rec))
      setTimeout(() => { if (dlg.value && dlg.value.region === name) dlg.value = null; }, 2500);
  }).catch(() => {});
}

const err = signal('');
const tab = signal('activity');   // the right column: 'activity' | 'history'
// A region that boots from a sysimage builds it in this prepare, from a list chosen first in its
// own modal; that modal's Prepare comes back here.
function prepare() {
  const cur = dlg.value; if (!cur || awaiting.value) return;
  if (cur.sysimage && !cur.batch) return openImagePackages({ region: cur.region, host: cur.host, onConfirm: start });
  start();
}

function start() {
  const cur = dlg.value; if (!cur || awaiting.value) return;
  const s = st.value;
  begun.value = true; err.value = '';
  awaiting.value = { after: (s && s.preparing && +s.preparing.started) || 0, tries: 0 };
  const req = cur.batch ? window.api('POST', '/api/prepare-batch', cur.batch)
                        : window.api('POST', '/api/prepare-region', { region: cur.region });
  req
    .then(d => { if (d && d.ok === false) { awaiting.value = null; err.value = d.error || 'could not start'; return; }
                 setTimeout(() => poll(cur.region), 300); })
    .catch(() => { awaiting.value = null; err.value = 'request failed'; });
}

function open(p) {
  if (!p || !p.region) return;
  if (dlg.value && dlg.value.region === p.region) return;   // already showing it
  dlg.value = p; st.value = null; begun.value = false; awaiting.value = null; err.value = ''; tab.value = 'activity';
  forgetHistory('dlg:' + p.region);
  poll(p.region);
}

function planned(d) {
  if (d.batch) return ['Sign in to ' + d.host, 'Julia', 'Read the site', 'Depot',
                       "Build this notebook's task environment", 'Run a test task on the nodes'];
  const sched = d.scheduler && d.scheduler !== 'none';
  const image = d.sysimage ? [sched ? 'Build the sysimage there' : 'Build the sysimage'] : [];
  return [
    'Sign in to ' + d.host, 'Julia and the worker runtime', 'Read the site',
    ...(sched ? ["Download this notebook's packages", 'Get a node', 'Read the node',
                 'Install and precompile the packages there', ...image, "Start this notebook's worker and load them",
                 'Keep the node for this notebook']
              : ['Install and precompile the packages', ...image, "Start this notebook's worker and load them"]),
  ];
}

function RegionPrep() {
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
  // Why it needs preparing: as pushed with the request, else as the hub reads it for this notebook.
  // Shown until this dialog starts a prepare, over an earlier report as much as over none.
  const why = d.reason || (s && s.reason) || '';
  return html`<div class="anbg"><div class="ancard rpcard" role="dialog" aria-modal="true">
    <div class="rphead">${d.batch ? html`Prepare ⚙ ${d.host} for sweeps` : html`Prepare 🖧 ${d.region}`}</div>
    <div class="pddim rpsub">${d.host}${d.scheduler && d.scheduler !== 'none' ? ' · ' + d.scheduler : ''}</div>
    ${why && !running && !begun.value ? html`<div class="rppsyswarn rpsub">${why}</div>` : null}
    <div class="rpsplit">
      <div class="rppane">
        <div class="rptabs"><span class="rpstriplabel">Steps</span></div>
        <div class="rptabbody" ref=${el => follow(el)} onScroll=${noteScroll}>
        ${steps ? StepList(steps, running ? s.preparing.now : 0, running ? s.preparing.last_output : 0)
                : html`<div class="rppprepsteps">${planned(d).map(t => html`<div class="rppprepstep planned"><span class="rppprepmark">·</span><span class="rppprepname">${t}</span></div>`)}</div>`}
        ${done ? html`<div class=${rec.ok && !hasWarnings(rec) ? 'rppsysok rpres' : 'rppsyswarn rpres'}>${
            !rec.ok ? '⚠ finished with failures'
            : hasWarnings(rec) ? '⚠ prepared, with warnings'
            : begun.value ? '✓ prepared — the waiting cells are running' : '✓ prepared'} · ${new Date(rec.prepared_at * 1000).toLocaleString()}</div>` : null}
        </div>
      </div>
      <div class="rppane">
        <div class="rptabs">
          <button class=${tab.value === 'activity' ? 'on' : ''} onClick=${() => tab.value = 'activity'}>Activity${log && log.length ? html` <span class="pddim">${log.length}</span>` : null}</button>
          <button class=${tab.value === 'history' ? 'on' : ''} onClick=${() => tab.value = 'history'}>History</button>
        </div>
        <div class="rptabbody">${tab.value === 'activity' ? ActivityPane(log) : HistoryPane(d.region, 'dlg:' + d.region)}</div>
      </div>
    </div>
    <div class="rpbtns">
      ${err.value ? html`<span class="rppsyswarn" style="margin-right:auto">${err.value}</span>` : null}
      ${awaiting.value ? html`<button class="anbtn primary" disabled>Starting…</button>`
        : running ? html`<button class="anbtn" onClick=${() => dlg.value = null}>Hide</button>`
        : done ? html`<button class=${'anbtn' + (rec.ok ? '' : ' primary')} onClick=${prepare}>Prepare again</button>
                   <button class="anbtn" onClick=${() => dlg.value = null}>Close</button>`
        : html`<button class="anbtn primary" onClick=${prepare}>Prepare</button>
               <button class="anbtn" onClick=${() => dlg.value = null}>Later</button>`}
    </div>
  </div></div>`;
}

effect(() => lockScroll('regionprep', !!dlg.value));

const host = document.createElement('div');
host.id = 'regionprepbg';
document.body.appendChild(host);
render(html`<${RegionPrep} />`, host);

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && dlg.value) { e.stopPropagation(); dlg.value = null; }
}, true);

// Pushed by the hub when an explicit run meets the wait (panels.js dispatch).
window.onRegionPrep = p => open(p);
// A sweep card's Prepare (sweep.jl `_prepare_html`): test this notebook's environment on the machine
// its job cell names. Progress is kept under the machine's batch key, as the server folds it.
window.slatePrepareBatch = (machine, el) => {
  const cell = el && el.closest ? (el.closest('[data-cid]') || {}).dataset : null;
  open({ region: 'batch_' + String(machine).trim().replace(/[^A-Za-z0-9_]+/g, '_'), host: machine,
         scheduler: 'batch', batch: { machine, cell: (cell && cell.cid) || '' } });
};
// The waiting chip (view.js). Its region's host and scheduler come from the regions list.
window.openPrepare = (name, ev) => {
  if (ev) { ev.preventDefault(); ev.stopPropagation(); }
  const r = window.slateModel.getFacts()['region/' + name];
  open({ region: name, host: r ? r.host : '', scheduler: r ? r.scheduler : '', sysimage: !!(r && r.sysimage) });
};
