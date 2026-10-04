// Asserts src/assets/js/model.js — the one place that answers "is a node held", "is this worker
// alive", "how healthy is it". Four components used to answer the first for themselves from three
// different fields, and seven answered the second from four different tests; the same worker read
// as attached in one panel and idle in another, on the same page, at the same moment.
//
// Those answers now have one definition each, so this file is what stops them drifting apart again.
//
// model.js is a CLASSIC script (an IIFE that assigns `slateModel`), so node just evaluates it and
// reads the object back — no import stripping, no signal stubs. That is also the property the page
// depends on: it must not need a module loader to exist.
//
//   node test/js/worker_model.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'model.js'), 'utf8');

const NAMES = ['getWorkers', 'getWorker', 'workerList', 'applyTelemetry', 'workersOf', 'sessions',
               'session', 'hubNow', 'walltimeLeft', 'idleFor', 'regions', 'parked', 'sampleOf', 'isHeld',
               'isScheduled', 'allocState', 'releaseVerb', 'isAlive', 'workerState', 'workerStatus',
               'workerSeverity', 'getAllocation', 'loadAllocation', 'refreshAllocation',
               'rosterKey', 'mergeWorker', 'subscribe'];

let M;
try {
  (0, eval)(src);
  M = globalThis.slateModel;
} catch (e) {
  console.error('worker_model: could not evaluate model.js —', e.message);
  process.exit(2);
}
if (!M) { console.error('worker_model: model.js did not define slateModel'); process.exit(2); }
for (const n of NAMES) {
  if (M[n] === undefined) { console.error('worker_model: model.js no longer exposes ' + n); process.exit(2); }
}

const fails = [];
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fails.push(`${label}: got ${g}, want ${w}`);
};

// ── held ────────────────────────────────────────────────────────────────────────────────────────
{
  // The three shapes the hub sends, and the one thing each must mean. `scheduler` absent is NOT
  // "no allocation" — it is "this worker cannot have one", which is why absence had to stop
  // carrying the answer.
  const main = { side: '' };
  const free = { side: 'gpu', scheduler: 'slurm', held: false, allocState: 'none' };
  const queued = { side: 'gpu', scheduler: 'slurm', held: true, allocState: 'pending' };
  const running = { side: 'gpu', scheduler: 'slurm', held: true, allocState: 'running', walltimeLeft: 600 };

  eq('main is not held', M.isHeld(main), false);
  eq('main is not scheduled', M.isScheduled(main), false);
  eq('free is not held', M.isHeld(free), false);
  eq('queued IS held', M.isHeld(queued), true);        // a queue place is withdrawn, not ignored
  eq('running is held', M.isHeld(running), true);
  eq('null is not held', M.isHeld(null), false);

  eq('main allocState', M.allocState(main), '');       // '' = the question does not apply
  eq('free allocState', M.allocState(free), 'none');
  eq('queued allocState', M.allocState(queued), 'pending');

  // The verb is the promise the button makes. Cancelling a queue place and releasing a node are
  // different acts, and one label for both misdescribes one of them.
  eq('queued verb', M.releaseVerb(queued), 'Cancel');
  eq('running verb', M.releaseVerb(running), 'Release');

  // The regression this whole model exists for: a walltime left over from a held node must not be
  // what decides held-ness. This record has one and is NOT held.
  const stale = { side: 'gpu', scheduler: 'slurm', held: false, allocState: 'none', walltimeLeft: 600 };
  eq('a leftover walltime does not mean held', M.isHeld(stale), false);
}

// ── alive / state ───────────────────────────────────────────────────────────────────────────────
{
  // The disagreement: `w.alive` vs `w.alive !== false`. A record that omits the field is one the
  // hub did not speak about, not one it declared dead — it read alive in the monitor and dead in
  // the roster.
  eq('absent alive is alive', M.isAlive({ port: 9300 }), true);
  eq('explicit false is dead', M.isAlive({ port: 9300, alive: false }), false);
  eq('explicit true is alive', M.isAlive({ port: 9300, alive: true }), true);
  eq('nothing is not alive', M.isAlive(null), false);

  eq('attached', M.workerState({ alive: true, state: 'attached' }), 'attached');
  eq('idle', M.workerState({ alive: true, state: 'idle' }), 'idle');
  eq('alive with no state is idle', M.workerState({ alive: true }), 'idle');
  // dead and none are both "not alive" and are NOT interchangeable: one is a process to clean up,
  // the other a region whose worker has not started, and offering Reap for the second is wrong.
  eq('a process that went is dead', M.workerState({ alive: false, state: 'idle' }), 'dead');
  eq('a worker never started is none', M.workerState({ alive: false, state: 'none' }), 'none');
  eq('no record at all is none', M.workerState(null), 'none');
}

// ── status / severity ───────────────────────────────────────────────────────────────────────────
{
  // Six copies of this existed. One checked `connected` first, so a degraded worker whose wire
  // happened to be up ranked as healthy — the pill went green while the hub was reporting trouble.
  eq('server status wins over connected', M.workerStatus({ status: 'degraded', connected: true }), 'degraded');
  eq('connected with no status is ok', M.workerStatus({ connected: true }), 'ok');
  eq('unconnected with no status is connecting', M.workerStatus({ connected: false }), 'connecting');
  eq('no worker is none', M.workerStatus(null), 'none');

  const rank = (w) => M.workerSeverity(w);
  const worse = (a, b) => rank(a) > rank(b);
  eq('disconnected outranks degraded',
     worse({ status: 'disconnected' }, { status: 'degraded' }), true);
  eq('degraded outranks connecting',
     worse({ status: 'degraded' }, { status: 'connecting' }), true);
  eq('degraded outranks a healthy connected worker',
     worse({ status: 'degraded', connected: true }, { status: 'ok', connected: true }), true);
}

// ── the roster merge ────────────────────────────────────────────────────────────────────────────
{
  // The hub knows whether the wire is live; the on-host sidecar only knows a process is running.
  // Merging the other way is what made the monitor and the roster disagree about one worker.
  const roster = { port: 9300, alive: true, state: 'idle', manifest: '{}' };
  const hub    = { port: 9300, alive: true, state: 'attached' };
  eq('hub state wins', M.workerState(M.mergeWorker(roster, hub)), 'attached');
  eq('roster fields survive the merge', M.mergeWorker(roster, hub).manifest, '{}');
  eq('roster alone is itself', M.workerState(M.mergeWorker(roster, null)), 'idle');
  eq('hub alone is itself', M.workerState(M.mergeWorker(null, hub)), 'attached');
  eq('roster key', M.rosterKey('gpu-box', 9300), 'gpu-box:9300');
}

// ── the hub's facts ─────────────────────────────────────────────────────────────────────────────
{
  M._setPageNotebook('nb1');
  const T = Date.now() / 1000;
  M._applyFrame({ t: 'facts', rev: 1, now: T, full: true, set: {
    'worker/nb1/': { nb: 'nb1', side: '', status: 'ok' },
    'worker/nb1/gpu': { nb: 'nb1', side: 'gpu', status: 'ok', scheduler: 'slurm', held: true,
                        allocState: 'running', until: T + 600, idleRelease: 180, lastUsed: T - 12 },
    'worker/nb2/': { nb: 'nb2', side: '', status: 'ok' },
    'session/pm': { host: 'pm', connected: true, nbs: ['nb1'] },
    'session/other': { host: 'other', connected: false, nbs: ['nb2'] } } });
  eq('this notebook\'s workers land', Object.keys(M.getWorkers()).sort(), ['', 'gpu']);
  eq('walltime is measured from the instant', Math.round(M.walltimeLeft(M.getWorker('gpu'))), 600);
  eq('idle is measured from the last use', Math.round(M.idleFor(M.getWorker('gpu'))), 12);
  eq('a notebook sees the hosts it uses', M.sessions('nb1').map(x => x.host), ['pm']);
  eq('the home page sees every host', M.sessions('').map(x => x.host), ['other', 'pm']);

  // A worker that has gone must GO, or a pill lingers for a region the notebook no longer has.
  M._applyFrame({ t: 'facts', rev: 2, now: T, set: {}, del: ['worker/nb1/gpu'] });
  eq('a dropped worker disappears', Object.keys(M.getWorkers()), ['']);

  // A delta after a gap is not applied over a set it does not follow: the page reloads the whole set.
  M._applyFrame({ t: 'facts', rev: 9, now: T, set: { 'session/pm': { host: 'pm', connected: false, nbs: ['nb1'] } }, del: [] });
  eq('a delta after a gap is not applied', M.session('pm').connected, true);

  // A sign-out changes the session fact, and everything reading it reads the new one.
  M._applyFrame({ t: 'facts', rev: 3, now: T, set: { 'session/pm': { host: 'pm', connected: false, nbs: ['nb1'] } }, del: [] });
  eq('a session change lands', M.session('pm').connected, false);

  // Telemetry merges into a worker's record and never into the facts.
  M.applyTelemetry('', '{"cpu":42}');
  eq('stats update', M.getWorker('').stats, '{"cpu":42}');
  eq('the fact is untouched', M.getFacts()['worker/nb1/'].stats, undefined);
  M._applyFrame({ t: 'facts', rev: 4, now: T, set: { 'worker/nb1/': { nb: 'nb1', side: '', status: 'degraded' } }, del: [] });
  eq('stats survive a fact change', M.getWorker('').stats, '{"cpu":42}');
  M.applyTelemetry('ghost', '{"cpu":1}');
  eq('unknown side is ignored', M.getWorkers().ghost, undefined);

  // Samples ride the same stream, for any notebook's workers, and are never stored as facts.
  M._applyFrame({ t: 'sample', key: 'worker/nb1/', at: T, stats: '{"cpu":7}' });
  eq('a sample reaches this page\'s worker', M.getWorker('').stats, '{"cpu":7}');
  M._applyFrame({ t: 'sample', key: 'worker/nb2/', at: T, stats: '{"cpu":9}' });
  eq('another notebook\'s sample is kept for it', M.workersOf('nb2')[0].stats, '{"cpu":9}');
  eq('and is not a fact', M.getFacts()['worker/nb2/'].stats, undefined);

  M._applyFrame({ t: 'facts', rev: 5, now: T, set: {
    'region/b': { name: 'b', host: 'h' }, 'region/a': { name: 'a', host: 'h' },
    'parked/n1/lbl/9100': { host: 'n1', label: 'lbl', port: 9100, since: T - 5 } }, del: [] });
  eq('regions, by name', M.regions().map(r => r.name), ['a', 'b']);
  eq('parked wires', M.parked().map(p => p.port), [9100]);
}

if (fails.length) {
  console.error('worker_model: ' + fails.length + ' failure(s)');
  for (const f of fails) console.error('  - ' + f);
  process.exit(1);
}
console.log('worker_model: ok');
