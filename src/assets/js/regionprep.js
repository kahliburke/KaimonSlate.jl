// PREPARE A REGION — what a notebook opens before its first worker on a region.
//
// The hub holds a region cell (`needs_prepare`) when this notebook's project was never prepared on
// the region, or the site has changed since, and pushes `regionprep:` on an explicit run. The cell's
// chip opens the same dialog (prepdialog.js). The waiting cells run when it ends.
//
import { openPrepare } from './prepdialog.js';
import { openImagePackages } from './imagepkgs.js';

const nbId = () => (window.__slateState || {}).id || '';

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

// What a prepare does, after the hub's sentence saying why this one is needed (machines.jl
// `env_readiness`, server.jl `_prepare_reason`). `again`: the region was prepared before.
function explainPrepare(d, again) {
  if (d.batch) return '';
  const sched = d.scheduler && d.scheduler !== 'none';
  return (again ? 'Preparing again' : 'Preparing') + ' installs the packages on ' + (d.host || 'the host') +
         ', compiles them' + (sched ? ' on one of its nodes' : '') + ' and checks that they load in a worker.';
}

// p: {region, host, scheduler, sysimage?, reason?, batch?}
function open(p) {
  if (!p || !p.region) return;
  openPrepare({
    key: p.region, notebook: nbId(),
    title: p.batch ? `Prepare ⚙ ${p.host} for sweeps` : `Prepare 🖧 ${p.region}`,
    sub: p.host + (p.scheduler && p.scheduler !== 'none' ? ' · ' + p.scheduler : ''),
    planned: planned(p), reason: p.reason || '', explain: again => explainPrepare(p, again),
    // A region that boots from a sysimage builds it in this prepare, from a list chosen first in its
    // own modal; that modal's Prepare comes back here.
    before: p.sysimage && !p.batch ? go => openImagePackages({ region: p.region, host: p.host, onConfirm: go }) : null,
    start: () => p.batch ? window.api('POST', '/api/prepare-batch', p.batch)
                         : window.api('POST', '/api/prepare-region', { region: p.region }),
  });
}

// Pushed by the hub when an explicit run meets the wait (panels.js dispatch).
window.onRegionPrep = p => open(p);
// A held sweep card's "testing" line (sweep.jl): test this notebook's environment on the machine
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
