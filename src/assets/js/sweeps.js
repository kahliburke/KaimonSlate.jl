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
// Slate's own settings (`cluster=`, `chunk=`) ride the cell header, where they are short and
// readable in a diff. The SCHEDULER options live in the notebook's `Slate.sweep` footer instead: a
// header value loses anything outside [A-Za-z0-9_.:+/@-] to the tag sanitiser, which rules out half
// of what sbatch accepts (`--licenses=ansys@srv`, a constraint expression, anything with a space) —
// and an option a cell cannot express is a batch script a notebook cannot replace. Both reach
// `@sweep` through the cell's execution context, footer over header.
//
// Deliberately NOT part of the sweep's key either way: raising a walltime RESUMES the sweep rather
// than discarding the units that already survived at the old one.
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
  // Slate's OWN cell settings — these mean something to the notebook, not to the scheduler, and so
  // are edited as named controls rather than as scheduler options. Mirrors `Sweep._ATTR_OTHER`.
  const OWN = ['cluster', 'data', 'chunk', 'region', 'needs', 'mutates', 'script'];
  const FIELDS = [
    ['Batching', [
      ['chunk', 'units per job', 'how many units ride one scheduler job'],
    ]],
  ];

  // The scheduler options the name box suggests — fetched from the server (`/api/sched-options`)
  // rather than listed here, so what the editor offers is the same list Slate types and validates.
  // A CATALOGUE, not a permitted set: an unrecognised name warns and is still sent. A scheduler has
  // far more options than are worth naming and sites add their own, so refusing what we have not
  // heard of would be the same mistake as silently dropping it.
  let CATALOGUE = [];
  const catBy = k => CATALOGUE.find(o => o.key === k || o.flag === k);

  // Which scheduler the cell's cluster runs, set when the panel renders. It decides how an option is
  // SPELLED and whether it can be said at all — `constraint` is a real sbatch flag and nothing on
  // PBS — but never what is stored: the key is the same either way, so re-pointing a cell at the
  // other kind of cluster re-labels its options instead of losing them.
  let KIND = 'slurm';
  // On SLURM the box shows the sbatch flag, which is the vocabulary a SLURM user has in front of
  // them. PBS has no equivalent vocabulary of flag names — its settings live inside `-l select=…` —
  // so there the box shows Slate's own key and the PBS spelling goes in the hint.
  const spellOf = o => (KIND === 'pbs' ? o.key : o.flag);
  const availOf = o => (KIND === 'pbs' ? o.pbs !== '' : o.flag !== '');
  const hintOf = o => !availOf(o) ? `no ${KIND} equivalent — ${o.hint}`
                    : KIND === 'pbs' && o.pbs ? `${o.pbs} — ${o.hint}` : o.hint;
  async function loadCatalogue() {
    if (CATALOGUE.length) return;
    // Raw fetch: this list belongs to the MACHINE, not to a notebook, and `api()` would rewrite the
    // path into the per-notebook namespace.
    try {
      CATALOGUE = (await (await fetch('/api/sched-options')).json()).options || [];
    } catch (_) {}
  }

  // What the user typed → the key it is STORED under. Three of Slate's names differ from sbatch's
  // (`cpus`/`cpus-per-task`, `walltime`/`time`, …), so a catalogue lookup comes first: typing the
  // sbatch spelling must land on the same key as picking it from the list, or the two become
  // separate settings that both emit the same flag. Otherwise `-` → `_`, since a stored key has to
  // match [A-Za-z][A-Za-z0-9_]* and no sbatch long option contains `_`.
  const toKey = s => {
    const t = String(s).trim().replace(/^-+/, '');
    const o = catBy(t) || catBy(t.replace(/-/g, '_'));
    return o ? o.key : t.replace(/-/g, '_');
  };
  const toFlag = k => {
    const o = catBy(k);
    if (!o) return KIND === 'pbs' ? String(k) : String(k).replace(/_/g, '-');
    return spellOf(o);
  };

  // Was a local copy that missed `'` — one helper now, so an apostrophe in a sweep or cluster name
  // is escaped here the same as everywhere else.
  const esc = s => window.slateEscHtml(s);

  const cellTags = id => {
    const st = window.__slateState || window.nbState || {};
    const c = (st.cells || []).find(x => x.id === id);
    return (c && c.tags) ? c.tags.slice() : [];
  };
  // Slate's own settings still ride the cell header (`cluster=hpc`, `chunk=25`). The split between
  // those and the scheduler options is exactly the one the Julia side makes (`is_sched_attr`), so
  // an option a site added shows up here as itself rather than being invisible to the editor that
  // is supposed to manage it.
  const ownOf = id => {
    const own = {};
    for (const t of cellTags(id)) {
      const i = t.indexOf('=');
      if (i > 0 && OWN.includes(t.slice(0, i))) own[t.slice(0, i)] = t.slice(i + 1);
    }
    return own;
  };

  // The SCHEDULER options come from the notebook footer instead (`Slate.sweep`), because a header
  // value loses anything outside [A-Za-z0-9_.:+/@-] to the tag sanitiser — which rules out
  // `--licenses=ansys@srv`, a constraint expression, or anything with a space. Legacy header
  // options are still read (and still work) so an existing notebook keeps behaving; the editor
  // writes only to the footer, and a saved option supersedes the header of the same name.
  let SCHED = {};                       // cell id → { key: value }, refreshed when the panel opens
  async function loadSched(id) {
    try {
      const r = await window.api('GET', '/api/sweep-options?cell=' + encodeURIComponent(id));
      SCHED = r.options || {};
    } catch (_) { SCHED = {}; }
  }
  const specOf = id => {
    const legacy = [];
    for (const t of cellTags(id)) {
      const i = t.indexOf('=');
      if (i <= 0) continue;
      const k = t.slice(0, i);
      if (!OWN.includes(k) && !(k in SCHED)) legacy.push([k, t.slice(i + 1)]);
    }
    return { own: ownOf(id), sched: [...legacy, ...Object.entries(SCHED)] };
  };

  window.openSweepConfig = async function (id, ev) {
    ev && ev.stopPropagation();
    await loadCatalogue();      // once per page; the panel is useless without its suggestions
    await loadSched(id);        // and this cell's saved options, which live in the footer
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

  // The machine's compute targets, mirrored into page state (same as `regions`). They are configured
  // on the front page under Remotes → Compute targets: a target describes a machine, so it is shared
  // by every notebook that names it rather than copied into each one.
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

  // One `name  value  ✕` row. The name box autocompletes over the catalogue and is checked on every
  // keystroke: an unknown name is a WARNING, never a block — it still submits, and the scheduler is
  // the one that gets to reject it (loudly, at submit) rather than Slate dropping it quietly.
  function optRow(k = '', v = '', inherited = '') {
    const o = k ? catBy(k) : null;
    const shown = k ? toFlag(k) : '';
    // Warn on two different things with the same amber: a name nobody has heard of, and a name this
    // scheduler cannot express. Both still submit — the scheduler rejects what it will not take, and
    // it says so far better than a guess here would.
    const bad = k && (!o || !availOf(o));
    const hint = o ? hintOf(o) : (k ? 'unknown option' : '');
    return '<div class="swopt' + (bad ? ' unknown' : '') + '">' +
      `<input class="swopt-k" autocomplete="off" spellcheck="false" placeholder="option" ` +
        `value="${esc(shown)}" title="${esc(hint)}">` +
      `<input class="swopt-v" spellcheck="false" value="${esc(v)}" ` +
        `placeholder="${esc(inherited || 'value')}">` +
      '<button class="swopt-x" title="remove" tabindex="-1">✕</button>' +
      '<div class="swopt-menu" hidden></div>' +
      `<span class="swopt-hint">${esc(hint)}</span>` +
      '</div>';
  }

  // Suggestions, as our own menu rather than a `<datalist>`. A datalist shows the WHOLE list the
  // moment the box is focused — eighteen options is a wall that buries the two fields underneath it,
  // and it cannot be capped from CSS because the browser draws it. This filters as you type, shows
  // nothing until you do, and scrolls past a handful.
  const OPT_MENU_MAX = 6;
  function optMatches(typed) {
    const t = String(typed).trim().replace(/^-+/, '').replace(/_/g, '-').toLowerCase();
    if (!t) return [];
    // Prefix first, then anywhere — so typing `mem` offers `mem` before `mem-per-cpu`, and `cpu`
    // still finds `cpus-per-task`.
    const pre = [], mid = [];
    for (const o of CATALOGUE) {
      if (!availOf(o)) continue;                   // this scheduler cannot say it: do not offer it
      const f = spellOf(o).toLowerCase().replace(/_/g, '-');
      if (f === t) continue;                       // already exact: nothing to suggest
      if (f.startsWith(t)) pre.push(o); else if (f.includes(t)) mid.push(o);
    }
    return [...pre, ...mid];
  }

  function showOptMenu(row, inp) {
    const menu = row.querySelector('.swopt-menu');
    const ms = optMatches(inp.value);
    if (!ms.length) { menu.hidden = true; return; }
    menu.innerHTML = ms.map((o, i) =>
      `<div class="swopt-mi${i === 0 ? ' on' : ''}" data-flag="${esc(spellOf(o))}">` +
      `<span class="swopt-mn">${esc(spellOf(o))}</span>` +
      `<span class="swopt-mh">${esc(hintOf(o))}</span></div>`).join('');
    menu.hidden = false;
    menu.querySelectorAll('.swopt-mi').forEach(mi => {
      // `mousedown`, not `click`: the input's blur would hide the menu before a click landed.
      mi.onmousedown = e => {
        e.preventDefault();
        inp.value = mi.dataset.flag;
        menu.hidden = true;
        inp.dispatchEvent(new Event('input'));
        row.querySelector('.swopt-v').focus();
      };
    });
  }

  // ↑/↓ to move, Enter/Tab to take the highlighted one, Escape to dismiss. Returns true when the
  // key was the menu's, so the caller leaves it alone.
  function optMenuKey(row, inp, e) {
    const menu = row.querySelector('.swopt-menu');
    if (menu.hidden) return false;
    const items = [...menu.querySelectorAll('.swopt-mi')];
    if (!items.length) return false;
    let i = items.findIndex(x => x.classList.contains('on'));
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      items[Math.max(i, 0)].classList.remove('on');
      i = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
      items[i].classList.add('on');
      items[i].scrollIntoView({ block: 'nearest' });
      return true;
    }
    if (e.key === 'Enter' || e.key === 'Tab') {
      inp.value = items[Math.max(i, 0)].dataset.flag;
      menu.hidden = true;
      inp.dispatchEvent(new Event('input'));
      return true;
    }
    if (e.key === 'Escape') { menu.hidden = true; return true; }
    return false;
  }

  function render(pop, id) {
    const { own, sched } = specOf(id);
    const spec = own;
    const defs = clusters();
    const cur = spec.cluster || '';
    const sel = clusterByName(cur);
    KIND = ((sel && sel.kind) || 'slurm').toLowerCase();
    // The cell names a target; several sweep cells share one, and moving the work is a single edit.
    // The per-cell fields below only override it.
    const picker =
      '<div class="ctlsub">Cluster</div>' +
      (defs.length
        ? `<select class="swcfg-cluster"><option value=""${cur ? '' : ' selected'}>— none —</option>` +
          defs.map(c => `<option value="${esc(c.name)}"${c.name === cur ? ' selected' : ''}>${esc(c.name)}</option>`).join('') +
          '</select>'
        : '<div class="swcfg-empty">This machine has no compute targets yet.</div>') +
      `<div class="swcfg-summary">${esc(clusterSummary(sel)) || (cur ? 'not defined on this machine' : 'the cell must name a target itself')}</div>` +
      '<div class="swcfg-note">Set up on the front page: <strong>🖧 Remotes → Clusters</strong>.</div>';

    // The scheduler options, as a list of pairs. One empty row is always kept at the end so adding
    // the next one is just typing — no button to find first.
    const rows = sched.map(([k, v]) => optRow(k, v, sel && sel[k] ? sel[k] : ''))
                      .join('') + optRow();
    const settings = picker +
      '<div class="ctlsub">Scheduler options <span class="swcfg-sub">— override for this cell</span></div>' +
      `<div class="swopts">${rows}</div>` +
      FIELDS.map(([group, fs]) =>
        `<div class="ctlsub">${group} <span class="swcfg-sub">— override for this cell</span></div>` +
        '<div class="swcfg-grid">' +
        fs.map(([k, label, hint]) =>
          `<label title="${esc(hint)}"><span>${esc(label)}</span>` +
          `<input data-k="${k}" value="${esc(spec[k] || '')}" placeholder="${esc(sel && sel[k] ? sel[k] : 'inherit')}" spellcheck="false"></label>`
        ).join('') + '</div>').join('') +
      '<div class="swcfg-note">Blank inherits from the cluster.</div>' +
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
    const csel = pop.querySelector('.swcfg-cluster');
    if (csel) csel.onchange = () => {
      const c = clusterByName(csel.value);
      pop.querySelector('.swcfg-summary').textContent = clusterSummary(c) || 'the cell must name a target itself';
      pop.querySelectorAll('input[data-k]').forEach(inp => {
        inp.placeholder = (c && c[inp.dataset.k]) ? c[inp.dataset.k] : 'inherit';
      });
      // Pointing the cell at a cluster of the other kind RE-LABELS its options. The key never moves,
      // only its spelling — so the keys are read while the old vocabulary is still in force.
      const rows = [...pop.querySelectorAll('.swopt')];
      const keys = rows.map(r => toKey(r.querySelector('.swopt-k').value));
      KIND = ((c && c.kind) || 'slurm').toLowerCase();
      rows.forEach((r, i) => {
        if (!keys[i]) return;
        const kf = r.querySelector('.swopt-k');
        kf.value = toFlag(keys[i]);
        kf.dispatchEvent(new Event('input'));
      });
    };
    wireOptRows(pop, id, sel);
    pop.querySelectorAll('input').forEach(inp => {
      inp.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); apply(pop, id); } };
    });
  }

  // Live behaviour of the pair list: recognise-or-warn as you type, show the cluster's inherited
  // value as the placeholder so you can see what you are overriding, grow a fresh row when the last
  // one is used, and remove a row on ✕.
  function wireOptRows(pop, id, sel) {
    const box = pop.querySelector('.swopts');
    if (!box) return;
    const refresh = row => {
      const kf = row.querySelector('.swopt-k'), vf = row.querySelector('.swopt-v');
      const k = toKey(kf.value), o = k ? catBy(k) : null;
      row.classList.toggle('unknown', !!k && (!o || !availOf(o)));
      const hint = row.querySelector('.swopt-hint');
      hint.textContent = o ? hintOf(o) : (k ? 'unknown option' : '');
      kf.title = hint.textContent;
      vf.placeholder = (sel && sel[k]) ? sel[k] : 'value';
      // A count that is not a number is rejected by Julia at run time; say so here instead, where
      // it can still be fixed without a failed submission.
      const bad = o && o.count && vf.value.trim() && !/^\d+$/.test(vf.value.trim());
      row.classList.toggle('badval', !!bad);
      if (bad) hint.textContent = 'must be a whole number';
    };
    const grow = () => {
      const rows = [...box.querySelectorAll('.swopt')];
      const last = rows[rows.length - 1];
      if (last && last.querySelector('.swopt-k').value.trim()) {
        box.insertAdjacentHTML('beforeend', optRow());
        wireOptRows(pop, id, sel);
      }
    };
    box.querySelectorAll('.swopt').forEach(row => {
      const kf = row.querySelector('.swopt-k'), menu = row.querySelector('.swopt-menu');
      kf.oninput = () => { refresh(row); showOptMenu(row, kf); grow(); };
      kf.onblur = () => setTimeout(() => { menu.hidden = true; }, 0);
      kf.onkeydown = e => {
        if (optMenuKey(row, kf, e)) { e.preventDefault(); return; }
        if (e.key === 'Enter') { e.preventDefault(); apply(pop, id); }
      };
      const vf = row.querySelector('.swopt-v');
      vf.oninput = () => { refresh(row); grow(); };
      vf.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); apply(pop, id); } };
      row.querySelector('.swopt-x').onclick = () => {
        row.remove();
        if (!box.querySelector('.swopt')) { box.insertAdjacentHTML('beforeend', optRow()); wireOptRows(pop, id, sel); }
      };
      refresh(row);
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
    // The pair list → the FOOTER, keyed under the header spelling (`mem_per_cpu`) whatever was
    // typed, so the same option written `--mem-per-cpu` or `mem-per-cpu` lands in one place.
    const sched = {};
    pop.querySelectorAll('.swopt').forEach(row => {
      const k = toKey(row.querySelector('.swopt-k').value);
      const v = row.querySelector('.swopt-v').value.trim();
      if (k && v && !OWN.includes(k)) sched[k] = v;
    });
    // Preserve every tag this panel does not edit, so changing an option cannot drop `collapsed`,
    // a `region=`, a `needs=`, or a free-form note. The panel owns `cluster` and `chunk` on the
    // header; scheduler options are no longer written there at all. A LEGACY header option the
    // editor now manages is dropped from the header as it moves into the footer — one home each,
    // rather than the same setting in two places disagreeing.
    const MANAGED = ['cluster', ...FIELDS.flatMap(([, fs]) => fs.map(f => f[0]))];
    const kept = cellTags(id).filter(t => {
      const i = t.indexOf('=');
      if (i <= 0) return true;                                  // a plain flag: never ours
      const k = t.slice(0, i);
      if (!OWN.includes(k)) return !(k in sched);               // a scheduler option: moved, or left alone
      return !MANAGED.includes(k);                              // ours to keep, not ours to write
    });
    const tags = [...new Set([...kept, ...Object.entries(set).map(([k, v]) => `${k}=${v}`)])];
    close();
    // Footer first: the tag write re-serialises the notebook, so saving the options afterwards
    // would race it and could be the version that loses.
    try {
      await window.api('POST', '/api/sweep-options', { cell: id, options: sched });
    } catch (e) {
      if (window.toast) window.toast('could not save the scheduler options — ' + e);
      return;
    }
    if (window.setTags) await window.setTags(id, tags);
    // Re-run so the new spec takes effect. Safe and cheap by construction: a sweep cell RECONCILES
    // — it submits only what is missing and never recomputes a unit that has already landed.
    if (window.runCell) window.runCell(id, true);
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
