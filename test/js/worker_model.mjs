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

const NAMES = ['getWorkers', 'getWorker', 'workerList', 'applyWorkers', 'applyTelemetry', 'isHeld',
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

// ── applying pushes ─────────────────────────────────────────────────────────────────────────────
{
  M.applyWorkers([{ side: '', status: 'ok' }, { side: 'gpu', status: 'ok', scheduler: 'slurm',
                                                held: true, allocState: 'running', walltimeLeft: 600 }]);
  eq('both workers land', Object.keys(M.getWorkers()).sort(), ['', 'gpu']);

  // A worker that has gone must GO. The list is complete, so a leftover key would keep a pill for a
  // region that is no longer in the notebook.
  M.applyWorkers([{ side: '', status: 'ok' }]);
  eq('a dropped worker disappears', Object.keys(M.getWorkers()), ['']);

  M.applyWorkers([{ side: '', status: 'ok' },
                  { side: 'gpu', status: 'ok', scheduler: 'slurm', held: true,
                    allocState: 'running', walltimeLeft: 600, idleRelease: 180, idleFor: 12 }]);

  // Telemetry merges: stats change, everything else about the worker stays.
  M.applyTelemetry('gpu', '{"cpu":42}', undefined);
  eq('stats update', M.getWorkers().gpu.stats, '{"cpu":42}');
  eq('other fields survive a stats-only frame', M.getWorkers().gpu.walltimeLeft, 600);

  // THE subtle one. When the node goes back, the new `alloc` has no walltime and no idle counter.
  // Merging field-by-field would leave the old ones in place and the panel would count down a
  // walltime for a node that is gone — which is the bug this model was built to end.
  M.applyTelemetry('gpu', '{"cpu":1}', { scheduler: 'slurm', held: false, allocState: 'none' });
  const g = M.getWorkers().gpu;
  eq('held goes false', g.held, false);
  eq('walltime is cleared, not stale', g.walltimeLeft, undefined);
  eq('idle counter is cleared', g.idleFor, undefined);
  eq('idleRelease is cleared', g.idleRelease, undefined);
  eq('the worker itself survives', g.status, 'ok');
  eq('and it is no longer held', M.isHeld(g), false);

  // A frame for a worker we have never heard of is ignored rather than inventing a half-record with
  // no host, port or status for the pills to render.
  M.applyTelemetry('ghost', '{"cpu":1}', undefined);
  eq('unknown side is ignored', M.getWorkers().ghost, undefined);
}

if (fails.length) {
  console.error('worker_model: ' + fails.length + ' failure(s)');
  for (const f of fails) console.error('  - ' + f);
  process.exit(1);
}
console.log('worker_model: ok');
