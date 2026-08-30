// Notebook-level view of batch sweeps.
//
// A sweep runs AWAY from the notebook and outlives the cell that started it, so a card buried in
// one cell's output cannot answer the question a reader actually has: what is this notebook doing
// right now. That belongs in the topbar with the other run status.
//
// The sweep cards already poll their own channels, so this needs no second data path: each card
// reports what it just learned, and this aggregates. A card that is scrolled away, collapsed, or
// below the fold still reports, which is exactly when the pill earns its place.

// ── A sweep cell's spec ──────────────────────────────────────────────────────────────────────
// Where the work runs and under what limits: partition, walltime, memory, how many units ride one
// scheduler job. These are the settings you change WHILE a job is queued, or after one was killed
// for outrunning its walltime — so they must not live in Julia source, where adjusting a number
// means editing code.
//
// They are stored as `key=value` cell-header tags (`#%% sweep walltime=02:00:00`), which round-trip
// through the .jl with no schema, are readable in a diff, and reach `@sweep` through the cell's
// execution context. Deliberately NOT part of the sweep's key: raising a walltime RESUMES the sweep
// rather than discarding the units that already survived at the old one.
// Byte sizes, shared by every surface in this file — the config panel and the topbar pill both
// report the same figures, and they must not disagree about how to spell one.
// The wall-clock time a sweep is expected to finish. Carries the date once the answer is not
// today, because "09:20" on a run that lands tomorrow morning reads as twelve hours early.
function etaClock(secs) {
  const t = new Date(Date.now() + secs * 1000), now = new Date();
  const hhmm = String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0');
  if (t.toDateString() === now.toDateString()) return hhmm;
  const days = Math.round((t - now) / 86400000);
  return (days <= 6 ? t.toLocaleDateString(undefined, { weekday: 'short' })
                    : t.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })) + ' ' + hhmm;
}

const humBytes = b => b == null ? '—' :
  b < 1024 ? b + ' B' :
  b < 1048576 ? (b / 1024).toFixed(1) + ' KB' :
  b < 1073741824 ? (b / 1048576).toFixed(1) + ' MB' : (b / 1073741824).toFixed(2) + ' GB';

(function () {
  const FIELDS = [
    ['Scheduler', [
      ['partition', 'partition', 'queue / partition name'],
      ['walltime',  'walltime',  'HH:MM:SS — the limit a unit is killed at'],
      ['cpus',      'cpus',      'CPUs per unit'],
      ['mem',       'memory',    'per unit, e.g. 4G'],
      ['gpus',      'gpus',      'GPUs per unit'],
      ['nodes',     'nodes',     'nodes per job'],
      ['account',   'account',   'charge to this allocation'],
      ['qos',       'qos',       'quality of service'],
    ]],
    ['Batching', [
      ['chunk', 'units per job', 'how many units ride one scheduler job'],
    ]],
  ];
  // `cluster` names a notebook-level definition; the rest override it for this cell only.
  const KEYS = ['cluster', ...FIELDS.flatMap(([, fs]) => fs.map(f => f[0]))];

  // A cluster DEFINITION. `kind` selects the backend — SLURM is what is real today, `local` runs
  // the same cells with no scheduler, and PBS/Kubernetes are why this is a named string out of
  // configuration rather than a Julia type written into a cell.
  const CLUSTER_FIELDS = [
    ['Where', [
      ['kind',        'kind',          'slurm | local'],
      ['host',        'ssh host',      'a login node from ~/.ssh/config; blank runs the client tools locally'],
      ['root',        'store (local)', 'only used when there is no ssh host — a local run, or a store this notebook has mounted'],
      ['root_remote', 'store (cluster)', 'the store ON the cluster. Put it on SCRATCH: $HOME is a few tens of GB and is not built for parallel writes'],
      ['project',     'project',       'the package whose code the units call into'],
      ['payload',     'task script',   "the task runner's path ON the cluster"],
    ]],
    ['Defaults', [
      ['partition', 'partition', 'default queue'],
      ['walltime',  'walltime',  'HH:MM:SS'],
      ['cpus',      'cpus',      'per unit'],
      ['mem',       'memory',    'per unit, e.g. 4G'],
      ['gpus',      'gpus',      'per unit'],
      ['nodes',     'nodes',     'per job'],
      ['account',   'account',   'allocation to charge'],
      ['qos',       'qos',       'quality of service'],
      ['chunk',     'units/job', 'how many units ride one scheduler job'],
    ]],
    ['Notes', [
      ['partitions',   'partitions',   'comma-separated, for reference'],
      ['max_walltime', 'max walltime', "the site's limit, for reference"],
      ['note',         'note',         'anything a reader should know'],
    ]],
  ];
  const CLUSTER_KEYS = CLUSTER_FIELDS.flatMap(([, fs]) => fs.map(f => f[0]));

  const esc = s => String(s).replace(/[&<>"]/g, ch =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

  const cellTags = id => {
    const st = window.__slateState || window.nbState || {};
    const c = (st.cells || []).find(x => x.id === id);
    return (c && c.tags) ? c.tags.slice() : [];
  };
  const specOf = id => {
    const out = {};
    for (const t of cellTags(id)) {
      const i = t.indexOf('=');
      if (i > 0 && KEYS.includes(t.slice(0, i))) out[t.slice(0, i)] = t.slice(i + 1);
    }
    return out;
  };

  window.openSweepConfig = function (id, ev) {
    ev && ev.stopPropagation();
    let pop = document.getElementById('swcfgpop');
    if (!pop) {
      pop = document.createElement('div');
      pop.id = 'swcfgpop';
      pop.className = 'swcfgpop';
      document.body.appendChild(pop);
      // Backdrop click closes; a click INSIDE the panel does not.
      pop.addEventListener('mousedown', e => { if (e.target === pop) close(); });
      document.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
    }
    if (pop.classList.contains('show') && pop.dataset.cell === id) return close();
    pop.dataset.cell = id;
    render(pop, id);
    pop.classList.add('show');
    const first = pop.querySelector('input');
    if (first) first.focus();
  };

  function close() {
    const pop = document.getElementById('swcfgpop');
    if (pop) pop.classList.remove('show');
  }

  // `meta` is merged into the top level of the state the browser holds (same as `regions`).
  const clusters = () => (window.__slateState || window.nbState || {}).clusters || [];
  const clusterByName = n => clusters().find(c => c.name === n);

  // What a cluster IS, in one line: enough to know where the work goes without opening the editor.
  function clusterSummary(c) {
    if (!c) return '';
    const bits = [];
    const kind = (c.kind || 'slurm').toLowerCase();
    bits.push(kind === 'local' ? 'local' : (c.host ? `${kind} · ${c.host}` : kind));
    if (c.partition) bits.push(c.partition);
    if (c.cpus) bits.push(`${c.cpus} cpu`);
    if (c.gpus) bits.push(`${c.gpus} gpu`);
    if (c.mem) bits.push(c.mem);
    if (c.walltime) bits.push(`≤ ${c.walltime}`);
    if (c.chunk) bits.push(`${c.chunk}/job`);
    return bits.join(' · ');
  }

  // What the cluster is DOING, opposite what it is configured to be. The two belong side by side:
  // a walltime you are about to raise means something different next to "3 units never landed".
  async function loadStatus(pop, name) {
    const host = pop.querySelector('.swst');
    if (!host) return;
    if (!name) { host.innerHTML = '<div class="swst-none">No cluster named on this cell.</div>'; return; }
    let s;
    try {
      s = await window.api('GET', '/api/cluster-status?name=' + encodeURIComponent(name));
    } catch (e) {
      host.innerHTML = `<div class="swst-none">could not read status — ${esc(String(e))}</div>`;
      return;
    }
    if (!host.isConnected) return;                     // panel closed while the round trip was out
    if (s.error) { host.innerHTML = `<div class="swst-none">${esc(s.error)}</div>`; return; }

    const sw = s.sweeps || [];
    const jobs = s.jobs || {}, store = s.store || {}, xf = s.xfer || {};
    const sum = k => sw.reduce((a, r) => a + (r[k] || 0), 0);
    const stored = sum('stored'), units = sum('total'), done = sum('done');
    const failed = sum('failed'), left = sum('missing');
    const rate = sw.reduce((a, r) => a + (r.rate > 0 ? r.rate : 0), 0);
    const eta = Math.max(...sw.map(r => (r.eta >= 0 ? r.eta : -1)), -1);
    const hosts = [...new Set(sw.flatMap(r => r.hosts || []))];

    // Figures, not sentences. Two groups because they answer different questions — whether the
    // work is moving, and whether the data is.
    const stat = (k, v, sub) =>
      `<div class="swst-stat"><span class="swst-k">${esc(k)}</span>` +
      `<span class="swst-v">${v}</span>` +
      (sub ? `<span class="swst-sub">${sub}</span>` : '') + '</div>';
    const pct = (a, b) => b > 0 ? (100 * a / b).toFixed(a / b < 0.01 ? 2 : 1) + '%' : '—';

    host.innerHTML =
      '<div class="swst-grp">compute</div><div class="swst-stats">' +
        stat('jobs', `${jobs.running || 0}<span class="swst-u">run</span>` +
                     `${jobs.pending || 0}<span class="swst-u">queue</span>`,
             `${jobs.known || 0} submitted`) +
        stat('units', `${done}<span class="swst-u">/${units}</span>`, pct(done, units)) +
        stat('failed', failed ? `<b class="bad">${failed}</b>` : '0', left ? `${left} outstanding` : '') +
        // Rate and ETA describe work still to come, so they are blank once there is none: a
        // throughput figure on a finished cluster is a number about the past pretending to be live.
        stat('rate', (left > 0 && rate > 0) ? rate.toFixed(2) + '<span class="swst-u">/s</span>' : '—',
             (left > 0 && eta >= 0) ? 'eta ' + etaClock(eta) : '') +
        stat('nodes', hosts.length || '—', hosts.slice(0, 3).join(' ')) +
      '</div>' +
      '<div class="swst-grp">data</div><div class="swst-stats">' +
        stat('output', humBytes(stored), `${sw.length} sweep${sw.length === 1 ? '' : 's'}`) +
        // `output` is what the sweeps in this store claim; `on disk` is what the store weighs. A
        // large gap is blobs nothing references any more — a reset sweep, a re-keyed one — and on
        // a quota'd scratch that is the number worth seeing. Only flagged when it is well clear of
        // block-rounding, and never when dedup makes the disk figure the smaller of the two.
        stat('on disk', humBytes(store.bytes),
             `${store.blobs || 0} blobs` +
             (store.bytes > stored * 1.1 && stored > 0
                ? ` · ${humBytes(store.bytes - stored)} unreferenced` : '')) +
        stat('read', humBytes(xf.bytes || 0), stored > 0 ? pct(xf.bytes || 0, stored) + ' of output' : '') +
        stat('throughput', xf.reads ? esc(xf.rate) : '—', xf.reads ? `${xf.reads} reads` : '') +
      '</div>' +
      // The store, then the mirror — labelled, because the mirror is a local cache of the metadata
      // and the size above it was measured on the cluster.
      (s.host && s.store_path
        ? `<div class="swst-path" title="${esc(s.host + ':' + s.store_path)}">${esc(s.host + ':' + s.store_path)}</div>` +
          `<div class="swst-path swst-dim" title="${esc(s.root || '')}">mirror ${esc(s.root || '')}</div>`
        : `<div class="swst-path" title="${esc(s.root || '')}">${esc(s.root || '')}</div>`) +
      (s.err ? `<div class="swst-none">⚠ ${esc(s.err)}</div>` : '') +
      (sw.length
        ? '<div class="swst-grp">sweeps</div>' +
          '<table class="swst-tbl"><tr><th>id</th><th>state</th><th class="num">units</th>' +
          '<th class="num">stored</th><th class="num">read</th></tr>' +
          sw.slice(0, 12).map(r =>
            `<tr><td title="${esc(r.sweep)}">${esc(r.sweep.slice(2, 12))}</td>` +
            `<td>${esc(r.state)}</td>` +
            `<td class="num">${r.done}/${r.total}${r.failed ? '<b class="bad"> ✗' + r.failed + '</b>' : ''}</td>` +
            `<td class="num">${humBytes(r.stored)}</td>` +
            `<td class="num">${r.read ? humBytes(r.read) : '—'}</td></tr>`).join('') +
          '</table>' +
          (sw.length > 12 ? `<div class="swst-none">+${sw.length - 12} more</div>` : '')
        : '<div class="swst-none">no sweeps in this store</div>');
  }

  function render(pop, id) {
    const spec = specOf(id);
    const defs = clusters();
    const cur = spec.cluster || '';
    const sel = clusterByName(cur);
    // The cluster is a NOTEBOOK-level definition referenced by name, so several sweep cells share
    // one and moving the work is a single edit. The per-cell fields below only override it.
    const picker =
      '<div class="ctlsub">Cluster</div>' +
      (defs.length
        ? `<select class="swcfg-cluster"><option value=""${cur ? '' : ' selected'}>— none —</option>` +
          defs.map(c => `<option value="${esc(c.name)}"${c.name === cur ? ' selected' : ''}>${esc(c.name)}</option>`).join('') +
          '</select>'
        : '<div class="swcfg-empty">No clusters defined for this notebook yet.</div>') +
      `<div class="swcfg-summary">${esc(clusterSummary(sel)) || (cur ? 'not defined in this notebook' : 'the cell must name a target itself')}</div>` +
      '<button class="swcfg-edit">Edit clusters…</button>';

    const settings = picker +
      FIELDS.map(([group, fs]) =>
        `<div class="ctlsub">${group} <span class="swcfg-sub">— override for this cell</span></div>` +
        '<div class="swcfg-grid">' +
        fs.map(([k, label, hint]) =>
          `<label title="${esc(hint)}"><span>${esc(label)}</span>` +
          `<input data-k="${k}" value="${esc(spec[k] || '')}" placeholder="${esc(sel && sel[k] ? sel[k] : 'inherit')}" spellcheck="false"></label>`
        ).join('') + '</div>').join('') +
      '<div class="swcfg-note">Blank inherits from the cluster. Overrides are not part of the ' +
      'sweep\'s key — raising a walltime RESUMES the sweep instead of discarding the units that ' +
      'already finished.</div>' +
      '<div class="swcfg-actions"><button class="swcfg-apply">Apply &amp; reconcile</button>' +
      '<button class="swcfg-cancel">Cancel</button></div>';

    pop.innerHTML =
      '<div class="swcfg-panel">' +
        '<div class="swcfg-head"><strong>' + (cur ? esc(cur) : 'No cluster') + '</strong>' +
          `<span class="swcfg-for">${esc(clusterSummary(sel)) || 'where this sweep runs'}` +
          ` · cell <code>${esc(id)}</code></span>` +
          '<button class="swcfg-x" title="close">✕</button></div>' +
        '<div class="swcfg-body">' +
          `<div class="swcfg-main">${settings}</div>` +
          '<div class="swcfg-side"><div class="ctlsub">Live</div>' +
            '<div class="swst"><div class="swst-none">…</div></div></div>' +
        '</div>' +
      '</div>';

    // The cluster's live state, fetched once per open. A round trip to the worker (which owns the
    // store view and the transfer ledger), so it is never on the path of opening the panel: the
    // settings are usable immediately and this column fills in.
    loadStatus(pop, cur);

    pop.querySelector('.swcfg-x').onclick = close;
    pop.querySelector('.swcfg-cancel').onclick = close;
    pop.querySelector('.swcfg-apply').onclick = () => apply(pop, id);
    pop.querySelector('.swcfg-edit').onclick = () => { close(); openClusterEditor(cur); };
    const csel = pop.querySelector('.swcfg-cluster');
    if (csel) csel.onchange = () => {
      const c = clusterByName(csel.value);
      pop.querySelector('.swcfg-summary').textContent = clusterSummary(c) || 'the cell must name a target itself';
      pop.querySelectorAll('input[data-k]').forEach(inp => {
        inp.placeholder = (c && c[inp.dataset.k]) ? c[inp.dataset.k] : 'inherit';
      });
    };
    pop.querySelectorAll('input').forEach(inp => {
      inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); apply(pop, id); } };
    });
  }

  async function apply(pop, id) {
    const set = {};
    const csel = pop.querySelector('.swcfg-cluster');
    if (csel && csel.value) set.cluster = csel.value;
    pop.querySelectorAll('input[data-k]').forEach(inp => {
      const v = inp.value.trim();
      if (v) set[inp.dataset.k] = v;
    });
    // Preserve every tag that is NOT one of ours, so editing a walltime cannot drop `collapsed`,
    // a `region=`, or a free-form note.
    const kept = cellTags(id).filter(t => {
      const i = t.indexOf('=');
      return !(i > 0 && KEYS.includes(t.slice(0, i)));
    });
    const tags = [...new Set([...kept, ...Object.entries(set).map(([k, v]) => `${k}=${v}`)])];
    close();
    if (window.setTags) await window.setTags(id, tags);
    // Re-run so the new spec takes effect. Safe and cheap by construction: a sweep cell RECONCILES
    // — it submits only what is missing and never recomputes a unit that has already landed.
    if (window.runCell) window.runCell(id, true);
  }

  // ── The cluster editor ──────────────────────────────────────────────────────────────────────
  // Definitions live on the NOTEBOOK (the `Slate.clusters` footer), so they are visible in a diff,
  // travel with the file, and are referenced by name from any number of sweep cells.
  let draft = null;   // the working copy; committed to the notebook on Save

  window.openClusterEditor = function (select) {
    draft = clusters().map(c => ({ ...c }));
    let dlg = document.getElementById('cludlg');
    if (!dlg) {
      dlg = document.createElement('div');
      dlg.id = 'cludlg';
      dlg.className = 'cludlg';
      document.body.appendChild(dlg);
      dlg.addEventListener('mousedown', e => { if (e.target === dlg) closeClusters(); });
      document.addEventListener('keydown', e => {
        if (e.key === 'Escape' && dlg.classList.contains('show')) closeClusters();
      });
    }
    dlg.dataset.sel = select || (draft[0] && draft[0].name) || '';
    renderClusters(dlg);
    dlg.classList.add('show');
  };
  function closeClusters() {
    const d = document.getElementById('cludlg');
    if (d) d.classList.remove('show');
    draft = null;
  }

  function renderClusters(dlg) {
    const sel = dlg.dataset.sel;
    const c = draft.find(x => x.name === sel);
    dlg.innerHTML = `<div class="cludlg-panel">
      <div class="cludlg-head"><strong>Compute targets</strong>
        <span class="cludlg-sub">defined once for this notebook · referenced from a sweep cell as <code>cluster=&lt;name&gt;</code></span>
        <button class="cludlg-x" title="close">×</button></div>
      <div class="cludlg-body">
        <div class="cludlg-list">
          ${draft.map(x => `<button class="cludlg-item${x.name === sel ? ' on' : ''}" data-n="${esc(x.name)}">
              <span class="cludlg-name">${esc(x.name)}</span>
              <span class="cludlg-sum">${esc(clusterSummary(x))}</span></button>`).join('')
            || '<div class="swcfg-empty">none yet</div>'}
          <button class="cludlg-add">＋ add cluster</button>
        </div>
        <div class="cludlg-form">${c ? clusterForm(c) : '<div class="swcfg-empty">Select or add a cluster.</div>'}</div>
      </div>
      <div class="swcfg-actions cludlg-foot">
        ${c ? '<button class="cludlg-del">Delete</button>' : ''}
        <span style="flex:1"></span>
        <button class="swcfg-apply cludlg-save">Save to notebook</button>
        <button class="cludlg-cancel">Cancel</button>
      </div></div>`;

    dlg.querySelector('.cludlg-x').onclick = closeClusters;
    dlg.querySelector('.cludlg-cancel').onclick = closeClusters;
    dlg.querySelectorAll('.cludlg-item').forEach(b => b.onclick = () => {
      commitForm(dlg); dlg.dataset.sel = b.dataset.n; renderClusters(dlg);
    });
    dlg.querySelector('.cludlg-add').onclick = () => {
      commitForm(dlg);
      let n = 'cluster', i = 1;
      while (draft.some(x => x.name === n)) n = 'cluster' + (++i);
      draft.push({ name: n, kind: 'slurm' });
      dlg.dataset.sel = n; renderClusters(dlg);
    };
    const del = dlg.querySelector('.cludlg-del');
    if (del) del.onclick = () => {
      draft = draft.filter(x => x.name !== dlg.dataset.sel);
      dlg.dataset.sel = (draft[0] && draft[0].name) || '';
      renderClusters(dlg);
    };
    dlg.querySelector('.cludlg-save').onclick = async () => {
      commitForm(dlg);
      const d = draft;
      closeClusters();
      window.renderAll(await window.api('POST', '/api/clusters', { clusters: d }));
    };
  }

  function clusterForm(c) {
    return `<label class="cludlg-nm"><span>name</span>
        <input data-c="name" value="${esc(c.name || '')}" spellcheck="false"></label>` +
      CLUSTER_FIELDS.map(([group, fs]) =>
        `<div class="ctlsub">${group}</div><div class="swcfg-grid">` +
        fs.map(([k, label, hint]) =>
          `<label title="${esc(hint)}"><span>${esc(label)}</span>` +
          `<input data-c="${k}" value="${esc(c[k] || '')}" placeholder="${esc(k === 'kind' ? 'slurm' : '')}" spellcheck="false"></label>`
        ).join('') + '</div>').join('');
  }

  // Read the visible form back into the draft before anything re-renders, so switching clusters or
  // adding one never silently discards what was just typed.
  function commitForm(dlg) {
    const c = draft.find(x => x.name === dlg.dataset.sel);
    if (!c) return;
    dlg.querySelectorAll('input[data-c]').forEach(inp => {
      const k = inp.dataset.c, v = inp.value.trim();
      if (k === 'name') { if (v) c.name = v; }
      else if (v) c[k] = v; else delete c[k];
    });
    dlg.dataset.sel = c.name;
  }
})();

(function () {
  const sweeps = new Map();     // key -> { key, cellId, status, ts }

  const pill = () => document.getElementById('sweeppill');
  const text = () => document.getElementById('sweeppilltext');
  const panel = () => document.getElementById('sweeppanel');

  const RUNNING = s => s === 'running' || s === 'pending';
  const BAD = s => s === 'blocked' || s === 'exhausted';

  // Progress is counted over the sweeps that are LIVE, not over every sweep the page has ever
  // reported. Summing all of them buries a running sweep under the finished ones — a 4-unit job
  // starting next to a finished 2304-unit one reads "2304/2308 · 99%", which describes history
  // rather than the work in hand.
  function summary() {
    let done = 0, total = 0, failed = 0, running = 0, bad = 0, settled = 0;
    let alldone = 0, alltotal = 0, dsbytes = 0, dsread = 0;
    for (const e of sweeps.values()) {
      const s = e.status || {};
      alldone += s.done || 0; alltotal += s.total || 0;
      failed += s.failed || 0;
      dsbytes += s.dsbytes || 0; dsread += s.dsread || 0;
      if (RUNNING(s.state)) {
        running++; done += s.done || 0; total += s.total || 0;
      } else if (BAD(s.state)) bad++;
      else settled++;
    }
    return { n: sweeps.size, done, total, failed, running, bad, settled, alldone, alltotal,
             dsbytes, dsread };
  }

  function render() {
    const p = pill(), t = text();
    if (!p || !t) return;
    if (sweeps.size === 0) { p.style.display = 'none'; return; }
    const s = summary();
    p.style.display = '';
    // The pill says the one thing worth saying at a glance; the panel has the detail. Live work
    // outranks a bad outcome: a stopped sweep is a fact you have already seen and can still read on
    // its card, while a running one is changing now — letting "1 sweep stopped" sit there forever
    // meant the pill went quiet exactly when the notebook was busiest. The stopped count rides
    // along as a suffix so it is deferred, not dropped.
    p.classList.toggle('bad', s.bad > 0 && s.running === 0);
    p.classList.toggle('busy', s.running > 0);
    const pct = s.total ? Math.round(100 * s.done / s.total) : 100;
    let label;
    if (s.running > 0) {
      label = `${s.done}/${s.total} units · ${pct}%`;
      if (s.running > 1) label += ` · ${s.running} sweeps`;
      if (s.bad > 0) label += ` · ${s.bad} stopped`;
    } else if (s.bad > 0) {
      label = `${s.bad} sweep${s.bad > 1 ? 's' : ''} stopped`;
    } else {
      label = `${s.n} sweep${s.n > 1 ? 's' : ''} done`;
    }
    if (s.failed > 0) label += ` · ${s.failed} failed`;
    // Output that is NOT here. A sweep storing addressably leaves its results on the cluster, so
    // the notebook's own size says nothing about how much there is; `↓` is what has come back.
    if (s.dsbytes > 0) {
      label += ` · ${humBytes(s.dsbytes)}`;
      if (s.dsread > 0) label += ` ↓${humBytes(s.dsread)}`;
    }
    t.textContent = label;
    if (panel() && panel().classList.contains('open')) paintPanel();
  }

  function paintPanel() {
    const el = panel();
    if (!el) return;
    const rows = [...sweeps.values()].sort((a, b) => (a.cellId || '').localeCompare(b.cellId || ''));
    el.innerHTML = rows.map(e => {
      const s = e.status || {};
      const pct = s.total ? (100 * (s.done || 0) / s.total) : 0;
      const col = s.color || 'var(--dim,#6a7090)';
      const bits = [`${s.done || 0}/${s.total || 0}`];
      if (s.failed) bits.push(`<span style="color:var(--red,#e57575)">${s.failed} failed</span>`);
      if (s.rate > 0 && !s.settled) bits.push(`${Number(s.rate).toFixed(2)}/s`);
      // When it lands, not just how fast it is going — this panel is the "can I go home?" view.
      if (s.eta >= 0 && !s.settled && !s.stuck) bits.push(`done ~${etaClock(s.eta)}`);
      // What a sweep produced, and how much of it has come back. Progress alone reads identically
      // for a run returning numbers and one leaving terabytes on a cluster; these are the
      // difference. Figures, aligned — the panel is an instrument, not a description.
      if (s.dsbytes > 0) {
        bits.push(`<span class="swprow-fig">${humBytes(s.dsbytes)}</span>`);
        bits.push(s.dsread > 0
          ? `<span class="swprow-fig">↓${humBytes(s.dsread)}</span>` +
            `<span class="swprow-pct">${(100 * s.dsread / s.dsbytes).toFixed(2)}%</span>`
          : '<span class="swprow-pct">↓0</span>');
      }
      return `<div class="swprow" data-cell="${e.cellId || ''}">
          <div class="swprow-top">
            <span class="swprow-dot" style="background:${col}"></span>
            <span class="swprow-cell">${e.cellId || ''}</span>
            <span class="swprow-label" style="color:${col}">${s.label || s.state || ''}</span>
            <span class="swprow-meta">${bits.join(' · ')}</span>
          </div>
          <div class="swprow-bar"><span style="width:${pct.toFixed(1)}%;background:${col}"></span></div>
          ${s.blocked ? `<div class="swprow-note">${s.blocked}</div>` : ''}
        </div>`;
    }).join('') || '<div class="swprow-note">no sweeps</div>';
    // The session total, at the foot: how much output exists against how much of it is here. A
    // question about the notebook rather than any one sweep, so it is stated once.
    const tot = summary();
    if (tot.dsbytes > 0) {
      el.innerHTML +=
        '<div class="swprow-foot">' +
          `<span><i>output</i>${humBytes(tot.dsbytes)}</span>` +
          `<span><i>read</i>${humBytes(tot.dsread)}</span>` +
          `<span><i>of it</i>${(100 * tot.dsread / tot.dsbytes).toFixed(2)}%</span>` +
        '</div>';
    }

    // Clicking a row scrolls to the cell that owns it — the pill's whole job is to get you back to
    // the thing it is telling you about.
    el.querySelectorAll('.swprow').forEach(r => {
      r.addEventListener('click', () => {
        const id = r.dataset.cell;
        const node = id && document.querySelector(`[data-cid="${id}"]`);
        if (node) { node.scrollIntoView({ behavior: 'smooth', block: 'center' }); close(); }
      });
    });
  }

  function close() { panel() && panel().classList.remove('open'); }

  window.slateSweeps = {
    // Called by each card on every poll. `status` is the payload the sweep's channel returned.
    report(key, cellId, status) {
      sweeps.set(key, { key, cellId, status, ts: Date.now() });
      // Mark the owning CELL with the sweep's state, so its rail reads as "work still out there"
      // from across the notebook. A sweep cell's own run took milliseconds and finished long ago;
      // without this the cell chrome would report that and say nothing about the job.
      if (cellId) {
        const el = document.querySelector(`[data-cid="${CSS.escape(cellId)}"]`);
        if (el && el.classList.contains('sweep')) {
          el.dataset.sweepState = (status && status.state) || '';
        }
      }
      render();
    },
    // A card removed from the DOM (cell deleted, notebook reloaded) stops counting.
    drop(key) { sweeps.delete(key); render(); },
    toggle(ev) {
      ev && ev.stopPropagation();
      const el = panel();
      if (!el) return;
      const open = el.classList.toggle('open');
      if (open) { paintPanel(); positionPanel(); }
    },
    all() { return [...sweeps.values()]; }
  };

  function positionPanel() {
    const p = pill(), el = panel();
    if (!p || !el) return;
    const r = p.getBoundingClientRect();
    el.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 360)) + 'px';
    el.style.top = (r.bottom + 6) + 'px';
  }

  document.addEventListener('click', e => {
    const el = panel();
    if (el && el.classList.contains('open') && !el.contains(e.target) &&
        e.target.id !== 'sweeppill' && !e.target.closest('#sweeppill')) close();
  });

  // Sweep away entries whose card has left the page, so a reloaded notebook does not keep
  // reporting sweeps nothing is watching.
  setInterval(() => {
    let changed = false;
    for (const [k] of sweeps) {
      // `k` IS the card's `data-sweep` value — the run key. Reconstructing it from a prefix was a
      // bug waiting to happen: a pilot and the full sweep share a sweep key and differ only in the
      // run, so any truncation collapses two distinct cards into one entry.
      if (!document.querySelector(`[data-sweep="${CSS.escape(k)}"]`)) {
        sweeps.delete(k); changed = true;
      }
    }
    if (changed) render();
  }, 5000);
})();
