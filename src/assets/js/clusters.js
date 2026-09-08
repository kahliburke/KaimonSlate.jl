// Compute targets — the "Compute targets" section of the Remotes modal, under the known-remotes list.
//
// A target is what a `#%% sweep cluster=<name>` cell submits to. Its fields describe a MACHINE (login
// host, scheduler, partition, where the scratch store is), which is the same thing a region on that
// machine needs, so it belongs here beside the hosts rather than inside each notebook that uses it.
//
// The NAME is the contract, not the address: a notebook says `cluster=hpc`, and each machine that
// opens it resolves that against its own registry — which is what lets one notebook run against a
// laptop's toy cluster and a site's real one with nothing edited in a cell.
import { html } from 'htm/preact';
import { signal } from '@preact/signals';
import { schedInfo, loadScheduler } from './stores.js';
import { sessions, loadSessions, openSessions } from './sessions.js';

export const clusters = signal([]);
const editing = signal(null);        // the target being edited (null = the "new" form)
const cmsg = signal(null);           // {text, err}
const more = signal(false);          // show the set-once fields (chunk, account, prologue, …)

const confirmP = (msg, ok, cls) => (window.confirmDark ? window.confirmDark(msg, ok, cls) : Promise.resolve(window.confirm(msg)));

// Form fields.
const kName = signal(''), kKind = signal('slurm'), kHost = signal(''), kRootRemote = signal(''),
      kProject = signal(''), kPayload = signal(''), kPartition = signal(''), kWalltime = signal(''),
      kCpus = signal(''), kMem = signal(''), kChunk = signal(''), kAccount = signal(''),
      kRoot = signal(''), kPrologue = signal(''), kNote = signal('');
// Every key the form above collects. The registry is deliberately schema-light — the fields a
// scheduler wants are the scheduler's business — so anything NOT in here is carried through a save
// untouched rather than dropped by an editor that has not heard of it.
const FORM_KEYS = ['name', 'kind', 'host', 'root', 'root_remote', 'project', 'payload', 'partition',
                   'walltime', 'cpus', 'mem', 'chunk', 'account', 'prologue', 'note'];

export function loadClusters() {
  return fetch('/api/clusters').then(r => r.json())
    .then(d => { clusters.value = (d && d.clusters) || []; }).catch(() => {});
}

function seed(c) {
  editing.value = c;
  cmsg.value = null;
  const g = k => (c && c[k] != null ? String(c[k]) : '');
  kName.value = g('name'); kKind.value = g('kind') || 'slurm'; kHost.value = g('host');
  kRootRemote.value = g('root_remote'); kRoot.value = g('root');
  kProject.value = g('project'); kPayload.value = g('payload');
  kPartition.value = g('partition'); kWalltime.value = g('walltime'); kCpus.value = g('cpus');
  kMem.value = g('mem'); kChunk.value = g('chunk'); kAccount.value = g('account');
  kPrologue.value = g('prologue'); kNote.value = g('note');
  if (kHost.value && kKind.value !== 'local') { loadScheduler(kHost.value); loadSessions(); }
}

// How many of the folded-away fields this target actually uses. Shown on the disclosure so a
// collapsed section never hides a setting you would not have guessed was there.
const filledExtras = () =>
  [kChunk, kAccount, kPrologue, kPayload, kNote].filter(s => (s.value || '').trim()).length;

// One line saying where the work goes, for the list and for the sweep cell's summary.
export function clusterSummary(c) {
  if (!c) return '';
  const k = c.kind || 'slurm';
  const bits = [k === 'local' ? 'here' : (c.host || 'no host yet')];
  if (c.partition) bits.push(c.partition);
  if (c.walltime) bits.push('≤' + c.walltime);
  if (c.cpus) bits.push(c.cpus + ' cpu');
  if (c.mem) bits.push(c.mem);
  return k + ' · ' + bits.join(' · ');
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
  if (!await confirmP('Delete compute target “' + name + '”?\nSweep cells using it will stop resolving. Work already in its store is untouched.', 'Delete', 'danger')) return;
  await fetch('/api/clusters/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) }).catch(() => {});
  if (editing.value && editing.value.name === name) seed(null);
  loadClusters();
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

export function Clusters() {
  const cs = clusters.value, e = editing.value, isLocal = kKind.value === 'local';
  return html`<div>
    <div class="msg"><strong>Compute targets</strong><span style="display:block;margin-top:3px;font-size:.78rem;color:#7a82a4;font-weight:400">Where sweep cells send their jobs.</span></div>
    <div class="rppreglist">
      ${cs.map(c => html`<div class=${'rppregrow' + (e && e.name === c.name ? ' sel' : '')} onClick=${() => seed(c)}>
        <span class="rppregname">⎈ ${c.name}</span>
        <span class="rppregmeta" title=${c.note || ''}>${clusterSummary(c)}${c.note ? ' · ' + c.note : ''}</span>
        <button class="rppregdel" title="forget this compute target" onClick=${ev => { ev.stopPropagation(); del(c.name); }}>✕</button></div>`)}
      <div class=${'rppregrow rppregnew' + (e ? '' : ' sel')} onClick=${() => seed(null)}>
        <span class="rppregname">＋ New target</span><span class="rppregmeta">cluster or local</span></div>
    </div>
    <div class="rppcfg">
      <div class="rppformhead">${e ? ('Edit target “' + e.name + '”') : 'New compute target'}</div>
      <div class="rpprow"><label>Name</label>
        <input class="rppname" autocomplete="off" spellcheck="false" placeholder="e.g. hpc, gpu, here" value=${kName.value} onInput=${ev => kName.value = ev.target.value}/>
        <span class="pddim" style="flex:0 0 auto">how sweep cells refer to it</span></div>
      <div class="rpprow"><label>Kind</label>
        <select class="rpptr" value=${kKind.value} onChange=${ev => kKind.value = ev.target.value}>
          <option value="slurm">slurm</option>
          <option value="pbs">pbs</option>
          <option value="local">local — no scheduler</option>
        </select>
        ${isLocal ? html`<span class="pddim">runs here, no scheduler</span>` : null}</div>
      ${isLocal ? html`
        <div class="rpprow"><label>Store</label>
          <input class="rpproot" autocomplete="off" spellcheck="false" placeholder="/path/to/store  (on THIS machine)" value=${kRoot.value} onInput=${ev => kRoot.value = ev.target.value}/></div>`
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
    <div class="rpprow"><label>Project</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="/path/to/project  (folder with Project.toml, on the cluster)" value=${kProject.value} onInput=${ev => kProject.value = ev.target.value}/></div>`}
      ${isLocal ? html`
        <div class="rpprow"><label>Project</label>
          <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="/path/to/project  (folder with Project.toml)" value=${kProject.value} onInput=${ev => kProject.value = ev.target.value}/></div>` : null}
      ${/* Everything a site sets once and then forgets. Folded away because a form you scroll is a
            form where the field that matters — the walltime — stops being the one you look at. */ null}
      <div class="rpprow rppmorerow"><label></label>
        <button class="rppmore" onClick=${() => more.value = !more.value}>${more.value ? '▾' : '▸'} ${more.value ? 'Fewer' : 'More'} settings${more.value || !filledExtras() ? '' : ' · ' + filledExtras() + ' set'}</button></div>
      ${!more.value ? null : html`
        <div class="rpprow"><label>Chunk</label>
          <input class="rppn" type="text" inputmode="numeric" autocomplete="off" placeholder="units" value=${kChunk.value} onInput=${ev => kChunk.value = ev.target.value}/>
          <span class="pddim">sweep units per job; blank = auto</span></div>
        ${isLocal ? null : html`
          <div class="rpprow"><label>Account</label>
            <input class="rppport" autocomplete="off" spellcheck="false" placeholder="charge code" value=${kAccount.value} onInput=${ev => kAccount.value = ev.target.value}/>
            <span class="pddim">if the site bills one</span></div>
          <div class="rpprow"><label>Prologue</label>
            <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="module load julia   (runs before each job)" value=${kPrologue.value} onInput=${ev => kPrologue.value = ev.target.value}/></div>
          <div class="rpprow"><label>Task script</label>
            <input class="rpppre" autocomplete="off" spellcheck="false" placeholder="task runner path on the cluster; blank = shipped" value=${kPayload.value} onInput=${ev => kPayload.value = ev.target.value}/></div>`}
        <div class="rpprow"><label>Note</label>
          <input class="rppname" autocomplete="off" placeholder="note" value=${kNote.value} onInput=${ev => kNote.value = ev.target.value}/></div>`}
      <div class="rppact"><button class="rppsavereg" onClick=${save}>${e ? 'Save' : 'Create'}</button></div>
    </div>
    <div class=${'rppmsg' + (cmsg.value && cmsg.value.err ? ' err' : '')}>${cmsg.value ? cmsg.value.text : ''}</div>
  </div>`;
}
