// A worker's facts and actions, in the bar under the telemetry view's title. The home page opens it
// from its worker roster (activity.js) and a notebook from its worker popup (workers.js), so one
// worker reads and acts the same from either place.
//
// The bar renders a roster entry `{ w, bound }`: `w` as a roster lists the worker, `bound` the hub's
// own kernel record for it when an open notebook holds it. The home page passes its live roster; a
// notebook, which has none, gets its entry from the hub's lists here (`openWorkerTelemetry`).
import { html } from 'htm/preact';
import { signal } from '@preact/signals';
import { openTelemetry, closeTelemetry } from './telemetry.js';

const { isAlive, workerState, mergeWorker } = window.slateModel;

export const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };
export const mergeManifest = (w, bound) => Object.assign({}, pj(w && w.manifest), bound ? pj(bound.manifest) : {});
export const ago = (unix) => { let s = Math.max(0, Math.floor(Date.now() / 1000 - (+unix || 0))); return s < 90 ? s + 's ago' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 172800 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };
const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));
const post = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

/** In-flight or failed restart/reap: `{port, err?}`. */
export const pending = signal(null);

// ── reap ─────────────────────────────────────────────────────────────────────────
// Kill a worker + remove its files. Always confirmed and never automatic: a worker may hold results
// nobody has fetched yet, so the human decides. The hub drops any live kernel bound to it first, so an
// attached notebook wakes with an error instead of hanging on a dead wire. `onDone('reaped')` once
// it is gone.
async function reapWorker(host, w, bound, onDone) {
  const mf = mergeManifest(w, bound), port = +w.port;
  const nb = mf.notebook ? '\nIt is serving “' + String(mf.notebook).replace(/#[^#]*$/, '') + '”' +
    (workerState(mergeWorker(w, bound)) === 'attached' ? ' and is ATTACHED — that notebook loses its kernel.' : '.') : '';
  const local = host === 'local';
  if (!await confirmP('Reap worker :' + port + (local ? ' on this machine' : ' on ' + host) + '?' + nb +
      (local ? '\nThis stops the process; the notebook starts a new worker when it next runs.'
             : '\nThis kills the process and removes its files — any un-fetched results are lost.'), 'Reap', 'danger')) return;
  pending.value = { port };
  try {
    const r = await post('/api/reap-worker', { host, port }).then(r => r.json());
    if (!r || r.ok === false) { pending.value = { port, err: 'reap failed — the worker may already be gone, or the host is unreachable' }; return; }
    pending.value = null;
    onDone && onDone('reaped', host, port);
  } catch (_) { pending.value = { port, err: 'request failed' }; }
}

// ── restart ──────────────────────────────────────────────────────────────────────
// Restart a worker that is serving an open notebook, wherever it runs. Same route the notebook's own
// Restart uses (`side` targets a region kernel, empty the main one), so an open tab follows along over
// its own feed. It re-runs the notebook, hence the confirm.
async function restartWorker(w, bound, host, onDone) {
  const mf = mergeManifest(w, bound), port = +w.port, side = mf.side === 'local' ? '' : (mf.side || '');
  // A worker whose manifest does not name an open notebook still deserves the repair — an abandoned
  // region worker on a compute node is the usual one. `/api/restart-worker` identifies it the way
  // the roster does, by host and port, and works out for itself what was using it.
  const orphan = !mf.nbid;
  if (orphan && (!host || !port)) return;
  const ask = orphan
    ? 'Restart worker :' + port + ' on ' + host + '?\nIts process is killed and whatever was using it re-runs.'
    : 'Restart the ' + (side ? 'region “' + side + '” worker' : 'worker') + ' for “' + (mf.notebook || mf.nbid) +
      '”?\nIts process is killed and the notebook re-runs from a fresh namespace.';
  if (!await confirmP(ask, 'Restart', 'danger')) return;
  pending.value = { port };
  try {
    const res = orphan ? await post('/api/restart-worker', { host, port })
                       : await post('/api/' + encodeURIComponent(mf.nbid) + '/restart', { side });
    if (!res.ok) { pending.value = { port, err: 'restart failed (' + res.status + ')' }; return; }
    pending.value = null;
    onDone && onDone('restarted', host, port);
  } catch (_) { pending.value = { port, err: 'request failed' }; }
}

// Actions follow the worker's CAPABILITIES, not its tier: a worker serving an open notebook can be
// restarted; one on a host we can reach, or on this machine and alive, can be reaped. A notebook run
// ON a host answers yes to both, which is why this isn't a local/remote switch.
function Acts({ host, w, bound, openNotebook, onDone }) {
  const isLocal = host === 'local';
  const r = pending.value && pending.value.port === +w.port ? pending.value : null;
  const busy = !!(r && !r.err);
  const mf = mergeManifest(w, bound);
  const canReap = isLocal ? isAlive(w) : !!host;
  const reapTip = isLocal ? 'Stops the process; the notebook starts a new worker when it next runs.'
    : !mf.nbid ? (!isAlive(w) ? 'Clears its leftover files on ' + host + '.' : 'Kills the process and removes its files on ' + host + '.')
    : 'Kills the process on ' + host + '; the notebook it serves loses its kernel.';
  return html`<div class="wdacts">
    ${r && r.err ? html`<span class="wdacterr">⚠ ${r.err}</span>` : null}
    ${(openNotebook && mf.nbid) ? html`<button class="rppsysbtn" title="open this notebook"
      onClick=${() => { window.location.href = '/n/' + encodeURIComponent(mf.nbid); }}>Open notebook</button>` : null}
    ${(mf.nbid || canReap) ? html`<button class="rppsysbtn danger" disabled=${busy} title="Restarts this worker and re-runs what was using it."
      onClick=${() => restartWorker(w, bound, host, onDone)}>${busy ? 'Restarting…' : 'Restart worker'}</button>` : null}
    ${canReap ? html`<button class="rppreap" disabled=${busy} title=${reapTip}
      onClick=${() => reapWorker(host, w, bound, onDone)}>${busy ? 'Reaping…' : 'Reap worker'}</button>` : null}
    ${(!canReap && !mf.nbid) ? html`<span class="wdactnote">attached, not managed by this hub</span>` : null}</div>`;
}

/** The bar for the worker at `host`:`port` ("local" for this machine). `entry` is its roster entry,
 *  `null` once it has gone, `undefined` while it is being looked up. `onRegion(name)` makes the
 *  region a link; `onDone(kind, host, port)` follows a restart or reap. */
export function WorkerBar({ host, port, entry, openNotebook = true, onRegion, onDone }) {
  const isLocal = host === 'local', w = entry && entry.w, bound = entry && entry.bound;
  if (entry === undefined) return html`<div class="wdactnote">looking up worker :${port}…</div>`;
  if (!w) return html`<div class="wdnodata">worker :${port} is no longer on ${isLocal ? 'this machine' : (host || 'that wire')}.</div>`;
  const mf = mergeManifest(w, bound), facts = [];
  const fact = (k, v, onClick) => { if (v == null || v === '') return; facts.push(html`<span class="wdfact"><span class="k">${k}</span><span class=${'v' + (onClick ? ' link' : '')} onClick=${onClick}>${String(v)}</span></span>`); };
  // A worker bound to an open notebook — on this machine or on a host — has a manifest that can't be
  // stale. Only an unbound remote one can be detached, in which case it names the notebook it LAST
  // served, which must not read as "serving now".
  const state = workerState(mergeWorker(w, bound));
  const det = !isLocal && !bound && state !== 'attached';
  fact('Host', isLocal ? 'this machine' : (host || 'forwarded wire'));
  if (mf.region) fact('Region', mf.region, onRegion ? () => onRegion(mf.region) : null);
  fact(det ? 'Last notebook' : 'Notebook', mf.notebook);
  if (mf.side && mf.side !== 'local') fact('Region kernel', mf.side);
  fact('State', state + (det && w.stateSince ? ' · detached ' + ago(w.stateSince) : ''));
  if (isLocal && mf.pid) fact('PID', mf.pid);
  fact('Transport', mf.transport);
  fact('Ports', ':' + w.port + (mf.stream_port ? ' · stream :' + mf.stream_port : ''));
  fact('Spawned', mf.spawned);
  fact('Project', mf.project);
  return html`<div class="wdbar"><div class="wdfacts">${facts}</div>
      <${Acts} host=${host} w=${w} bound=${bound} openNotebook=${openNotebook} onDone=${onDone}/></div>
    ${(det && mf.notebook && isAlive(w)) ? html`<div class="wdhint">Detached but still warm — its namespace, loaded packages and memo store survive. Reopening that notebook on this host reattaches to this worker instead of paying a cold boot.${mf.region ? ' Until then its region can hand it to another notebook with the same env.' : ' No other notebook will reuse it, so reap it if you are done with that one.'}</div>` : null}`;
}

/** A worker's title in the view: its notebook, and its region or region kernel. */
export function workerLabel(mf, port) {
  const side = mf.side && mf.side !== 'local' ? mf.side : '';
  return [String(mf.notebook || '').replace(/#[^#]*$/, ''), mf.region || side].filter(Boolean).join(' · ') || ':' + port;
}

// ── from a notebook ──────────────────────────────────────────────────────────────
// A notebook's workers are in the hub's facts (model.js), found by notebook and side, so the bar
// follows one through a restart and shows what every other part of the page shows about it.

// A worker fact as the bar reads a roster entry: the hub's own record (model.js `asRosterEntry`).
const factEntry = (f) => { const w = window.slateModel.asRosterEntry(f); return { w, bound: w }; };

/** Open the telemetry view for one of notebook `nb`'s workers (`side` "" for its main one), with its bar. */
export function openWorkerTelemetry({ nb, side, host, port, label }) {
  side = side || '';
  pending.value = null;
  const fact = () => window.slateModel.getFacts()['worker/' + nb + '/' + side];
  openTelemetry({
    nb, side, host: host && host !== 'local' ? host : '', port, label,
    actions: () => {
      const f = fact();
      return html`<${WorkerBar} host=${f && f.host ? f.host : 'local'} port=${f ? f.port : port}
        entry=${f ? factEntry(f) : null} openNotebook=${false}/>`;
    } });
}
window.openWorkerTelemetry = openWorkerTelemetry;
