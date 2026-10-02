// Machines — the "Machines" section of the Remotes modal, under the known-remotes list.
//
// A machine is what a `#%% job cluster=<name>` cell submits to and what a region runs its workers on.
// Its fields describe the machine (login host, scheduler, the Julia and depot to use, where the
// scratch store is), so it belongs here beside the hosts rather than inside each notebook that uses it.
//
// The NAME is the contract, not the address: a notebook says `cluster=hpc`, and each machine that
// opens it resolves that against its own registry — which is what lets one notebook run against a
// laptop's toy cluster and a site's real one with nothing edited in a cell.
import { html } from 'htm/preact';
import { signal, effect } from '@preact/signals';
import { schedInfo, loadScheduler } from './stores.js';
import { sessions, loadSessions, openSessions } from './sessions.js';
import { StepList, Activity, History } from './prepsteps.js';
import { OptionsTable, optionsMap, optionRows } from './optstable.js';

export const clusters = signal([]);
const procsDefault = signal(0);      // what a local target that names no `procs` gets on this machine
const editing = signal(null);        // the target being edited (null = the "new" form)
// Whether the form is showing. Closed until asked for: open by default, it filled the pane under a
// list whose own "New target" row already offers it, and pushed the list's purpose out of view.
const formOpen = signal(false);
export function closeClusterForm() { formOpen.value = false; cmsg.value = null; }
// The list selects; the selected machine is always shown beside it.
function toggleForm(c) {
  const same = formOpen.value && ((c === null && editing.value === null) || (c && editing.value && editing.value.name === c.name));
  if (same) return;
  seed(c);
  formOpen.value = true;
}
// Something is always selected once there is anything to select.
effect(() => {
  const cs = clusters.value;
  if (!formOpen.peek() && cs.length) { seed(cs[0]); formOpen.value = true; }
});
const cmsg = signal(null);           // {text, err}
const more = signal(false);          // show the set-once fields (chunk, account, prologue, …)

const isExecKind = k => k === 'exec' || k === 'local';
const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));

// Form fields.
const kName = signal(''), kKind = signal('slurm'), kHost = signal(''), kRootRemote = signal(''),
      kProject = signal(''), kPayload = signal(''), kPartition = signal(''), kWalltime = signal(''),
      kCpus = signal(''), kMem = signal(''), kChunk = signal(''), kAccount = signal(''),
      kRoot = signal(''), kPrologue = signal(''), kNote = signal(''), kProcs = signal(''),
      kDepot = signal(''), kJulia = signal(''), kTestQos = signal('');
const kOpts = signal([]), kOptMenu = signal(-1);   // scheduler options, as the region form edits them
// Every key the form above collects. The registry is deliberately schema-light — the fields a
// scheduler wants are the scheduler's business — so anything NOT in here is carried through a save
// untouched rather than dropped by an editor that has not heard of it.
const FORM_KEYS = ['name', 'kind', 'host', 'root', 'root_remote', 'project', 'payload', 'partition',
                   'walltime', 'cpus', 'mem', 'chunk', 'account', 'prologue', 'note', 'procs',
                   'depot', 'julia', 'test_qos', 'options', 'directives', 'qos'];

export function loadClusters() {
  return fetch('/api/clusters').then(r => r.json())
    .then(d => {
      clusters.value = (d && d.clusters) || [];
      procsDefault.value = (d && d.local_procs) || 0;
    }).catch(() => {});
}

function seed(c) {
  editing.value = c;
  cmsg.value = null;
  const g = k => (c && c[k] != null ? String(c[k]) : '');
  // A definition written before the split says `local`, which is no longer one of the options — so
  // the select would render with nothing chosen. Normalised on the way in; saving then migrates it.
  kName.value = g('name');
  kKind.value = g('kind') === 'local' ? 'exec' : (g('kind') || 'slurm');
  kHost.value = g('host');
  kRootRemote.value = g('root_remote'); kRoot.value = g('root');
  kProject.value = g('project'); kPayload.value = g('payload');
  kPartition.value = g('partition'); kWalltime.value = g('walltime'); kCpus.value = g('cpus');
  kMem.value = g('mem'); kChunk.value = g('chunk'); kAccount.value = g('account');
  kPrologue.value = g('prologue'); kNote.value = g('note'); kProcs.value = g('procs');
  kDepot.value = g('depot'); kJulia.value = g('julia'); kTestQos.value = g('test_qos');
  kOpts.value = optionRows(c && c.options); kOptMenu.value = -1;
  if (c && c.host) loadMachine(c.name);
  if (kHost.value && !isExecKind(kKind.value)) { loadScheduler(kHost.value); loadSessions(); }
  if (kHost.value && isExecKind(kKind.value)) loadSessions();
}

// How many of the folded-away fields this target actually uses. Shown on the disclosure so a
// collapsed section never hides a setting you would not have guessed was there.
const filledExtras = () =>
  [kChunk, kAccount, kPrologue, kPayload, kNote, kJulia, kTestQos].filter(s => (s.value || '').trim()).length;

// One line saying where the work goes, for the list and for the job cell's summary.
export function clusterSummary(c) {
  if (!c) return '';
  const k = c.kind || 'slurm';
  const ex = isExecKind(k);
  const bits = [ex ? (c.host || 'here') : (c.host || 'no host yet')];
  if (ex && c.procs) bits.push(c.procs + ' at once');
  if (c.partition) bits.push(c.partition);
  if (c.walltime) bits.push('≤' + c.walltime);
  if (c.cpus) bits.push(c.cpus + ' cpu');
  if (c.mem) bits.push(c.mem);
  return (ex ? 'no scheduler' : k) + ' · ' + bits.join(' · ');
}

function save() {
  const name = (kName.value || '').trim();
  if (!name) { cmsg.value = { text: 'needs a name', err: true }; return; }
  const e = editing.value;
  const body = { name, kind: kKind.value };
  for (const k of Object.keys(e || {})) if (!FORM_KEYS.includes(k)) body[k] = e[k];
  // Only send what was filled in: blank means "the site's default", which is not the same thing as an
  // empty string forced into a job script.
  const put = (k, v) => { v = (v || '').trim(); if (v) body[k] = v; };
  put('host', kHost.value); put('root_remote', kRootRemote.value); put('root', kRoot.value);
  put('project', kProject.value); put('payload', kPayload.value);
  put('partition', kPartition.value); put('walltime', kWalltime.value); put('cpus', kCpus.value);
  put('mem', kMem.value); put('chunk', kChunk.value); put('account', kAccount.value);
  put('prologue', kPrologue.value); put('note', kNote.value);
  put('depot', kDepot.value); put('julia', kJulia.value); put('test_qos', kTestQos.value);
  const om = optionsMap(kOpts.value);
  if (Object.keys(om).length) body.options = om;
  if (isExecKind(kKind.value)) put('procs', kProcs.value);
  cmsg.value = { text: 'Saving…' };
  fetch('/api/clusters', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
    .then(r => r.json()).then(d => {
      if (!d || !d.ok) { cmsg.value = { text: (d && d.error) || 'failed', err: true }; return; }
      return loadClusters().then(() => {
        seed(clusters.value.find(x => x.name === name) || null);
        cmsg.value = { text: 'Saved' };
      });
    }).catch(() => { cmsg.value = { text: 'request failed', err: true }; });
}

async function del(name) {
  if (!await confirmP('Delete machine “' + name + '”?\nJob cells and regions using it will stop resolving. Work already in its store is untouched.', 'Delete', 'danger')) return;
  await fetch('/api/clusters/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) }).catch(() => {});
  if (editing.value && editing.value.name === name) { seed(null); closeClusterForm(); }
  loadClusters().then(() => { const cs = clusters.value; if (cs.length) toggleForm(cs[0]); });
}

// ── Is this host signed in? ─────────────────────────────────────────────────────────────────
// Status only, read from the sign-in panel's list. A session belongs to a HOST and is shared by
// every notebook, sweep and region on this machine, so there is one list of them and one way to
// start one — this form just shows where the host it names stands.
function Session() {
  const h = (kHost.value || '').trim();
  if (!h) return null;
  const st = sessions.value.find(s => s.host === h);
  return html`<div class="rpprow"><label></label>
    ${st && st.connected ? html`<span class="pddim">✓ signed in to ${h}</span>`
                         : html`<span class="pddim">not signed in — only needed where keys are refused</span>`}
    <button class="rppmore" onClick=${() => openSessions()}>Sign in…</button></div>`;
}

// What the named host actually reports, once it has been asked. Detection is a suggestion, not the
// setting: a site can have both toolsets installed with only one of them running the jobs, so the
// `kind` above stays the user's choice and this only says what was found.
function HostSays() {
  const h = (kHost.value || '').trim(), si = schedInfo.value[h];
  if (!h || si === undefined) return null;
  if (si === null) return html`<div class="rpprow"><label></label><span class="pddim"><span class="hydspin"></span> asking ${h}…</span></div>`;
  const kinds = (si.kinds || []).filter(k => k !== 'none');
  const note = !kinds.length ? html`<span class="pddim">no scheduler on ${h}</span>`
    : kinds.includes(kKind.value) ? html`<span class="pddim">✓ ${kKind.value} found on ${h}${kinds.length > 1 ? ' (also ' + kinds.filter(k => k !== kKind.value).join(', ') + ')' : ''}</span>`
    : html`<span class="pddim" style="color:#d9a441">⚠ ${h} reports ${kinds.join(' and ')}, not ${kKind.value}</span>`;
  return html`<div class="rpprow"><label></label>${note}</div>`;
}

// The queues the host reported, as a menu — a partition name is not something to be guessed at, and
// a down queue should be visible as down rather than fail at submit. Falls back to a text box when
// the host was never asked or reported nothing.
function Partitions() {
  const h = (kHost.value || '').trim(), si = schedInfo.value[h];
  const parts = (si && si.partitions && si.partitions[kKind.value]) || [];
  if (!parts.length)
    return html`<input class="rpppre" autocomplete="off" spellcheck="false" placeholder="queue name (blank = site default)" value=${kPartition.value} onInput=${ev => kPartition.value = ev.target.value}/>`;
  const known = parts.some(p => p.name === kPartition.value);
  return html`<select class="rpptr" value=${kPartition.value} onChange=${ev => kPartition.value = ev.target.value}>
    <option value="">(site default)</option>
    ${parts.map(p => html`<option value=${p.name} disabled=${p.up === false}>${p.name}${p.gpus ? ' · ' + p.gpus : ''}${p.maxtime ? ' · ≤' + p.maxtime : ''}${p.up === false ? ' (down)' : ''}</option>`)}
    ${kPartition.value && !known ? html`<option value=${kPartition.value}>${kPartition.value}</option>` : null}
  </select>`;
}

// ── What preparing a machine found ───────────────────────────────────────────────────────────
// Read from /api/machines/view: the host's facts, the depot in use, the environments that passed a
// test task, and a prepare of the machine running now. Polled while one runs.
const mview = signal({});           // name → view
function loadMachine(name) {
  return fetch('/api/machines/view?name=' + encodeURIComponent(name)).then(r => r.json()).then(d => {
    mview.value = { ...mview.value, [name]: d };
    if (d && d.preparing && d.preparing.running) setTimeout(() => loadMachine(name), 1500);
  }).catch(() => {});
}
function prepareMachine(name) {
  fetch('/api/machines/prepare', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                   body: JSON.stringify({ name }) })
    .then(() => setTimeout(() => loadMachine(name), 500)).catch(() => {});
}
const ago = t => { const s = Math.max(0, Date.now() / 1000 - t);
  return s < 90 ? 'just now' : s < 5400 ? Math.round(s / 60) + 'm ago' : s < 129600 ? Math.round(s / 3600) + 'h ago' : Math.round(s / 86400) + 'd ago'; };

function MachineReadiness(name) {
  const d = mview.value[name];
  if (!d || !d.ok) return null;
  const site = d.site || {}, p = d.preparing, running = !!(p && p.running);
  const head = running ? html`<span class="pddim"><span class="hydspin"></span> preparing</span>`
    : !site.prepared_at ? html`<span class="pddim">not prepared</span>`
    : site.stale ? html`<span class="rppsyswarn">⚠ ${site.stale}</span>`
    : html`<span class="rppsysok">✓ prepared · ${ago(site.prepared_at)}</span>`;
  const julia = (site.facts && site.facts.julia) || '';
  return html`<div class="rpprow"><label>Readiness</label><div class="rppsysbox rppprep">
      <div class="rppprephead">${head}
        ${running ? null : html`<button class="rppsysbtn" onClick=${() => prepareMachine(name)}>${site.prepared_at ? 'Prepare again' : 'Prepare'}</button>`}</div>
      ${running ? StepList(p.steps, p.now, p.last_output) : null}
      ${running ? Activity(p.log, 'm:' + name) : null}
      ${History(d.key, 'm:' + name)}
      ${site.prepared_at ? html`<div class="pddim">${[julia, 'depot ' + (d.depot || '~/.julia')].filter(Boolean).join(' · ')}</div>` : null}
      ${site.site_prologue ? html`<div class="pddim">site prologue <code>${site.site_prologue}</code></div>` : null}
      ${(d.tests || []).map(t => html`<div class="pddim">${[
          'tested ' + String(t.project || '').split('/').slice(-2).join('/'),
          t.node_type && t.node_type !== '/' ? 'on ' + t.node_type.replace(/\/$/, '').replace(/^\//, '') : '',
          t.by ? 'by ' + t.by : '',
          t.status === 'fail' ? 'failed' : '',
          t.load_s ? 'loads in ' + t.load_s + 's' : '',
          t.cuda ? 'CUDA ' + (String(t.cuda.functional).startsWith('true') ? 'ok' : 'not functional') : '',
          t.tested_at ? ago(t.tested_at) : ''].filter(Boolean).join(' · ')}${t.changed ? html` · <span class="rppsyswarn">packages changed since</span>` : null}</div>`)}
    </div></div>`;
}

export function Clusters() {
  const cs = clusters.value, e = editing.value, open = formOpen.value;
  // `local` is the older spelling of `exec` with no host; a definition on disk still uses it.
  const isExec = kKind.value === 'exec' || kKind.value === 'local';
  return html`<div>
    <div class="mchsplit">
    <div class="mchlist">
      ${cs.map(c => html`<div class=${'mchrow' + (open && e && e.name === c.name ? ' sel' : '')} title=${c.note || ''} onClick=${() => toggleForm(c)}>
        <span class="mchname">⎈ ${c.name}</span>
        <span class="mchmeta">${(isExecKind(c.kind) ? 'no scheduler' : (c.kind || 'slurm')) + ' · ' + (c.host || 'here')}</span></div>`)}
      <div class=${'mchrow new' + (open && !e ? ' sel' : '')} onClick=${() => toggleForm(null)}>
        <span class="mchname">＋ New machine</span></div>
    </div>
    <div class="mchdetail">
    ${!open ? html`<div class="pddim mchempty">No machines yet</div>` : html`<div class="rppcfg">
      <div class="mchhead"><div class="rppformhead">${e ? e.name : 'New machine'}</div>
        ${e ? html`<span class="pddim">${clusterSummary(e)}</span>
          <button class="rppregdel" title="forget this machine" onClick=${() => del(e.name)}>Delete</button>` : null}</div>
      ${e && e.host ? MachineReadiness(e.name) : null}
      <div class="rpprow"><label>Name</label>
        <input class="rppname" autocomplete="off" spellcheck="false" placeholder="e.g. hpc, gpu, here" value=${kName.value} onInput=${ev => kName.value = ev.target.value}/>
        <span class="pddim">${'cluster=<name> in a job cell'}</span></div>
      <div class="rpprow"><label>Kind</label>
        <select class="rpptr" value=${kKind.value} onChange=${ev => kKind.value = ev.target.value}>
          <option value="slurm">slurm</option>
          <option value="pbs">pbs</option>
          <option value="exec">no scheduler — Slate runs the processes</option>
        </select>
        ${isExec ? html`<span class="pddim">${kHost.value.trim() ? 'on ' + kHost.value.trim() : 'here'}</span>` : null}</div>
      ${isExec ? html`
        <div class="rpprow"><label>Host</label>
          <input class="rpppre" autocomplete="off" spellcheck="false"
            placeholder="ssh host to run on — blank runs on this machine"
            value=${kHost.value} onInput=${ev => kHost.value = ev.target.value}
            onBlur=${() => loadSessions()}/></div>
        ${kHost.value.trim() ? Session() : null}
        <div class="rpprow"><label>Store</label>
          ${kHost.value.trim()
            ? html`<input class="rpproot" autocomplete="off" spellcheck="false" placeholder="/path/to/store  (on THAT machine)" value=${kRootRemote.value} onInput=${ev => kRootRemote.value = ev.target.value}/>`
            : html`<input class="rpproot" autocomplete="off" spellcheck="false" placeholder="/path/to/store  (on THIS machine)" value=${kRoot.value} onInput=${ev => kRoot.value = ev.target.value}/>`}</div>
        ${/* With no scheduler there is nothing else deciding how much of the machine a sweep takes.
              Each task is a whole Julia loading the project, so this is a memory question rather than
              a core-count one — hence a default well under the core count, overridable here. */ null}
        <div class="rpprow"><label>At once</label>
          <input class="rppn" type="text" inputmode="numeric" autocomplete="off"
                 placeholder=${procsDefault.value || 'auto'} title="how many tasks run in parallel on this machine"
                 value=${kProcs.value} onInput=${ev => kProcs.value = ev.target.value}/>
          <span class="pddim">tasks in parallel${procsDefault.value ? ' (default ' + procsDefault.value + ')' : ''}</span></div>`
      : html`
        <div class="rpprow"><label>Login host</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="ssh host you submit from"
            value=${kHost.value} onInput=${ev => kHost.value = ev.target.value} onBlur=${ev => { loadScheduler(ev.target.value.trim()); loadSessions(); }}/></div>
        ${HostSays()}
        ${Session()}
        <div class="rpprow"><label>Store</label>
          <input class="rpproot" autocomplete="off" spellcheck="false" placeholder="/scratch/…  (a path ON the cluster)" value=${kRootRemote.value} onInput=${ev => kRootRemote.value = ev.target.value}/></div>
        <div class="rpprow"><label></label><span class="pddim">Use scratch, not $HOME.</span></div>
        <div class="rpprow"><label>Partition</label>${Partitions()}</div>
        <div class="rpprow"><label>Per job</label>
      <div class="rppfields">
        ${[['walltime', kWalltime, '01:00:00', 'time limit per job'],
           ['cpus', kCpus, '4', 'cores per job'],
           ['memory', kMem, kKind.value === 'pbs' ? '8gb' : '8G', 'per job']].map(([nm, sig, ph, hint]) => html`
          <label class="rppfield"><span class="rppfieldname">${nm}</span>
            <input class="rppport" autocomplete="off" spellcheck="false" placeholder=${ph}
                   title=${hint} value=${sig.value} onInput=${ev => sig.value = ev.target.value}/>
            <span class="rppfieldhint">${hint}</span></label>`)}
      </div>
      <span class="pddim">a cell can override these</span></div>
        <div class="rpprow"><label>Options</label>${OptionsTable(kOpts, kOptMenu, kKind.value)}</div>
    <div class="rpprow"><label>Project</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="blank = the notebook's own project" value=${kProject.value} onInput=${ev => kProject.value = ev.target.value}/></div>`}
      ${isExec ? html`
        <div class="rpprow"><label>Project</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="blank = the notebook's own project" value=${kProject.value} onInput=${ev => kProject.value = ev.target.value}/></div>` : null}
      ${kHost.value.trim() ? html`
        <div class="rpprow"><label>Depot</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="blank = automatic (scratch when the site has it)" value=${kDepot.value} onInput=${ev => kDepot.value = ev.target.value}/></div>` : null}
      ${/* Everything a site sets once and then forgets. Folded away because a form you scroll is a
            form where the field that matters — the walltime — stops being the one you look at. */ null}
      <div class="rpprow rppmorerow"><label></label>
        <button class="rppmore" onClick=${() => more.value = !more.value}>${more.value ? '▾' : '▸'} ${more.value ? 'Fewer' : 'More'} settings${more.value || !filledExtras() ? '' : ' · ' + filledExtras() + ' set'}</button></div>
      ${!more.value ? null : html`
        <div class="rpprow"><label>Chunk</label>
          <input class="rppn" type="text" inputmode="numeric" autocomplete="off" placeholder="units" value=${kChunk.value} onInput=${ev => kChunk.value = ev.target.value}/>
          <span class="pddim">sweep units per job; blank = auto</span></div>
        ${isExec ? null : html`
          <div class="rpprow"><label>Account</label>
            <input class="rppport" autocomplete="off" spellcheck="false" placeholder="charge code" value=${kAccount.value} onInput=${ev => kAccount.value = ev.target.value}/>
            <span class="pddim">if the site bills one</span></div>
          <div class="rpprow"><label>Prologue</label>
            <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="module load …   (runs before every Julia here)" value=${kPrologue.value} onInput=${ev => kPrologue.value = ev.target.value}/></div>
          <div class="rpprow"><label>Test QoS</label>
            <input class="rppport" autocomplete="off" spellcheck="false" placeholder="e.g. debug" value=${kTestQos.value} onInput=${ev => kTestQos.value = ev.target.value}/>
            <span class="pddim">for the test task before a sweep</span></div>
          <div class="rpprow"><label>Task script</label>
            <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="task runner path on the cluster; blank = shipped" value=${kPayload.value} onInput=${ev => kPayload.value = ev.target.value}/></div>`}
        ${kHost.value.trim() ? html`<div class="rpprow"><label>Julia</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="blank = juliaup at this hub's version" value=${kJulia.value} onInput=${ev => kJulia.value = ev.target.value}/></div>` : null}
        <div class="rpprow"><label>Note</label>
          <input class="rppname" autocomplete="off" placeholder="note" value=${kNote.value} onInput=${ev => kNote.value = ev.target.value}/></div>`}
      <div class="rppact"><button class="rppsavereg" onClick=${save}>${e ? 'Save' : 'Create'}</button></div>
    </div>`}
    <div class=${'rppmsg' + (cmsg.value && cmsg.value.err ? ' err' : '')}>${cmsg.value ? cmsg.value.text : ''}</div>
    </div></div>
  </div>`;
}
