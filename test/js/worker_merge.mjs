// Asserts the PURE `mergeRosters` function from activity.js — the join between the two views of an
// off-machine worker: the per-host ssh roster (/api/remote-workers) and the hub's own off-machine
// kernels (/api/remote-notebook-workers). Getting this wrong either double-lists a worker or, worse,
// hides a notebook running on a host the region registry never names. It depends on nothing but `pj`,
// so we slice it out (balanced braces) and eval it in isolation.
//
//   node test/js/worker_merge.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'activity.js'), 'utf8');

const start = src.indexOf('function mergeRosters(');
if (start < 0) { console.error('worker_merge: could not locate mergeRosters in activity.js'); process.exit(2); }
let depth = 0, end = -1;
for (let i = src.indexOf('{', start); i < src.length; i++) {
  if (src[i] === '{') depth++;
  else if (src[i] === '}' && --depth === 0) { end = i + 1; break; }
}
if (end < 0) { console.error('worker_merge: unbalanced braces'); process.exit(2); }
const pjSrc = "const pj = (s) => { try { return JSON.parse(s || '{}'); } catch (_) { return {}; } };\n";
// `filedUnder` is module scope in activity.js because the poll needs it too (it decides which hosts
// to probe, and probing a node separately re-reads the same shared directory). Take the real line
// rather than restating it here, so the rule under test cannot drift from the shipped one.
const fu = /^const filedUnder = .*$/m.exec(src);
if (!fu) { console.error('worker_merge: could not locate filedUnder in activity.js'); process.exit(2); }
const mergeRosters = new Function(pjSrc + fu[0] + '\n' + src.slice(start, end) + '\nreturn mergeRosters;')();

const mf = (o) => JSON.stringify(o);
const roster = (host, ws) => ({ host, workers: ws });
// A region worker on a host the registry names — roster-only, no open notebook on it here.
const wRegionIdle = { port: 9312, alive: true, state: 'idle', manifest: mf({ region: 'gpu', notebook: 'old.jl' }) };
// A region worker this hub IS attached to: it appears in BOTH views.
const wRegionLive = { port: 9300, alive: true, state: 'idle', manifest: mf({ region: 'gpu', notebook: 'pipeline.jl' }) };
const kRegionLive = { host: 'gpu-box', region: 'gpu', port: 9300, state: 'attached', manifest: mf({ nbid: 'nb1', region: 'gpu', notebook: 'pipeline.jl' }) };
// A notebook RUN ON a plain host: in both views, but with no region.
const wNb = { port: 9400, alive: true, state: 'attached', manifest: mf({ notebook: 'seismic.jl' }) };
const kNb = { host: 'workstation', region: '', port: 9400, state: 'attached', manifest: mf({ nbid: 'nb2', notebook: 'seismic.jl' }) };
// The same, on a host whose probe failed (or was never run) — hub-only.
const kUnreachable = { host: 'darkbox', region: '', port: 9500, state: 'attached', manifest: mf({ nbid: 'nb3', notebook: 'far.jl' }) };
// A forwarded `remoteworker` attach: no host at all.
const kForwarded = { host: '', region: '', port: 9600, state: 'attached', manifest: mf({ nbid: 'nb4', notebook: 'fwd.jl' }) };

const fails = [];
const eq = (label, got, want) => { if (got !== want) fails.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
const find = (es, host, port) => es.filter(e => e.host === host && +e.w.port === +port);

{ // Roster-only workers pass through untouched, with the region read off the manifest.
  const es = mergeRosters([roster('gpu-box', [wRegionIdle])], []);
  eq('roster-only count', es.length, 1);
  eq('roster-only region', es[0].region, 'gpu');
  eq('roster-only unbound', es[0].bound, null);
}
{ // A worker in BOTH views is ONE row — the roster record, tagged with the hub kernel.
  const es = mergeRosters([roster('gpu-box', [wRegionLive, wRegionIdle])], [kRegionLive]);
  eq('merged total', es.length, 2);
  const both = find(es, 'gpu-box', 9300);
  eq('merged not duplicated', both.length, 1);
  eq('merged keeps roster record', both[0].w, wRegionLive);
  eq('merged carries hub kernel', both[0].bound, kRegionLive);
  eq('merged region from hub', both[0].region, 'gpu');
  eq('untouched sibling still unbound', find(es, 'gpu-box', 9312)[0].bound, null);
}
{ // A notebook run on a plain host: merged, region stays empty (that is what groups it separately).
  const es = mergeRosters([roster('workstation', [wNb])], [kNb]);
  eq('run-on count', es.length, 1);
  eq('run-on bound', es[0].bound, kNb);
  eq('run-on region', es[0].region, '');
}
{ // Hub-only kernels still produce a row — an unreachable host must not make a live worker vanish.
  const es = mergeRosters([roster('gpu-box', [wRegionIdle])], [kUnreachable, kForwarded]);
  eq('hub-only total', es.length, 3);
  const dark = find(es, 'darkbox', 9500)[0];
  eq('hub-only uses hub record', dark.w, kUnreachable);
  eq('hub-only bound to itself', dark.bound, kUnreachable);
  const fwd = find(es, '', 9600)[0];
  eq('forwarded present', fwd.bound, kForwarded);
  eq('forwarded hostless', fwd.host, '');
}
{ // Same port on two different hosts is two workers — the key must include the host.
  const es = mergeRosters([roster('a', [{ port: 9400, manifest: mf({}) }]), roster('b', [{ port: 9400, manifest: mf({}) }])],
                          [{ host: 'b', region: '', port: 9400, manifest: mf({ nbid: 'nb5' }) }]);
  eq('host-keyed count', es.length, 2);
  eq('host-keyed a unbound', find(es, 'a', 9400)[0].bound, null);
  eq('host-keyed b bound', find(es, 'b', 9400)[0].bound !== null, true);
}
{ // Two hub kernels on the SAME host:port (main + a region kernel would never collide, but a stale
  // record must not spawn a second row) and empty/missing inputs.
  eq('empty inputs', mergeRosters([], []).length, 0);
  eq('null inputs', mergeRosters(null, null).length, 0);
  eq('roster with no workers', mergeRosters([{ host: 'x' }], []).length, 0);
  const es = mergeRosters([], [kNb, kNb]);
  eq('duplicate hub kernels collapse', es.length, 1);
}

{ // A SCHEDULER REGION's worker is filed under two different names, and this is the case every
  // fixture above quietly assumed away by giving both views the same host.
  //
  // The worker runs on the granted node (`c1`). Its manifest lives on the shared filesystem and is
  // probed through the login node, so the roster files it under `slate-slurm`. Keyed on the running
  // host alone, the two views never meet and the monitor shows one worker twice: the hub's live
  // kernel, and the roster's manifest for the same process, reporting a contradictory state and a
  // CPU figure frozen at whatever it was when the worker died.
  const wOnNode = { port: 9118, alive: false, state: 'attached',
                    manifest: mf({ region: 'slurmgpu', notebook: 'slurm_wait.jl' }) };
  const kOnNode = { host: 'c1', viaHost: 'slate-slurm', region: 'slurmgpu', port: 9118,
                    alive: true, state: 'attached', manifest: mf({ nbid: 'nb9', region: 'slurmgpu' }) };
  const es = mergeRosters([roster('slate-slurm', [wOnNode])], [kOnNode]);
  eq('a region worker is ONE row, not two', es.length, 1);
  eq('and it is bound to the live kernel', es[0].bound, kOnNode);
  eq('region carried through', es[0].region, 'slurmgpu');
  // The row addresses the machine the worker RUNS on: that is what a reap has to reach.
  eq('host is the node, not the login', es[0].host, 'c1');

  // Without `viaHost` the two are genuinely different workers and must stay two rows — the fix must
  // not collapse a same-port pair on unrelated hosts.
  const noVia = mergeRosters([roster('slate-slurm', [wOnNode])],
                             [{ ...kOnNode, viaHost: undefined }]);
  eq('no viaHost means no merge', noVia.length, 2);
}

if (fails.length) { console.error('worker_merge FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('worker_merge OK');
