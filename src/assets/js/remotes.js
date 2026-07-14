// Remotes MODAL SHELL — Preact island for #remotesbg (the home-page "🖧 Remotes" manager). Owns the
// whole modal: host input + transport/ports, the "Test & prime" SSH preflight (an SSE stream of steps),
// the known-remotes list, the data-transfer settings, and — when a host is focused — the region focus
// view (the exported `Focus` component from remotes-focus.js). Coordinates with the activity monitor +
// focus view purely through shared signals (stores.js); the host store lives in hoststore.js. This
// retires the old inline vanilla shell and every window.__slate*/slate* remotes bridge.
//
// It also mounts the two run-on pickers (open-notebook bar + import dialog) and kicks the initial
// ssh-hosts load, since those pickers share the same host store — the whole remotes/run-on surface is
// owned here.
import { html, render } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';
import { modalOpen, focusHost, editRegion, regions, loadRegions } from './stores.js';
import { RunOnPicker, loadRunon, rememberRemote, forgetHost, setDefaultHost, allHosts, sshHosts, sshGlobal } from './hoststore.js';
import { Focus } from './remotes-focus.js';

// ── host-setup form state ──────────────────────────────────────────────────────────────
const host = signal('');           // #rthost value
const tr = signal('tunnel');       // transport radio
const port = signal('');           // :direct main port (blank = auto)
const stream = signal('');         // :direct stream port
// Preflight stream state: { note, rows:[{name,status,ms,detail}], verdict:{ok,text}|null, err }.
const steps = signal(null);
let _es = null;                     // live preflight EventSource (closed on retest / modal close)

// ── data-transfer settings ──────────────────────────────────────────────────────────────
const xfer = signal(null);         // /api/transfer-settings payload (values + effective placeholders)
function loadXfer() { fetch('/api/transfer-settings').then(r => r.json()).then(d => xfer.value = d).catch(() => {}); }
// Commit all three knobs together, read from the live inputs (like the vanilla shell) so a fast edit to
// one never reverts another from a stale echo. confirm_s='' → -1 (previews off is a real 0, blank = default).
function commitXfer() {
  const c = document.getElementById('rtxchunk'), k = document.getElementById('rtxcarry'), f = document.getElementById('rtxconfirm');
  if (!c || !k || !f) return;
  fetch('/api/transfer-settings', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chunk_mb: c.value || 0, carry_max_s: k.value || 0, confirm_s: f.value === '' ? -1 : f.value }) })
    .then(r => r.json()).then(d => xfer.value = d).catch(() => {});
}

// ── preflight (SSE) ────────────────────────────────────────────────────────────────────
// "host[,transport[,port,stream]]" — ports only for :direct, blank = auto. Remembered on success.
function spec() { if (tr.value !== 'direct') return host.value; const p = (port.value || '').trim(), s = (stream.value || '').trim(); return p ? host.value + ',direct,' + p + (s ? ',' + s : '') : host.value + ',direct'; }
function closeES() { if (_es) { try { _es.close(); } catch (_) {} _es = null; } }
function runTest() {
  const h = (host.value || '').trim();
  if (!h) { steps.value = { note: null, rows: [], verdict: null, err: null, empty: 'Enter a host to test.' }; return; }
  const t = tr.value;
  closeES();
  steps.value = { note: 'Testing ' + h + ' (' + t + ')… a first-time host provisions Julia deps and can take a few minutes.', rows: [], verdict: null, err: null };
  const es = new EventSource('/api/preflight-stream?host=' + encodeURIComponent(h) + '&transport=' + encodeURIComponent(t));
  _es = es;
  es.addEventListener('step', e => {
    let s; try { s = JSON.parse(e.data); } catch (_) { return; }
    const rows = steps.value.rows.slice(), i = rows.findIndex(r => r.name === s.name);
    if (i >= 0) rows[i] = s; else rows.push(s);
    steps.value = { ...steps.value, rows };
  });
  es.addEventListener('done', e => {
    let d = {}; try { d = JSON.parse(e.data); } catch (_) {}
    closeES();
    steps.value = { ...steps.value, note: null, verdict: { ok: !!d.ok, text: d.ok ? '✅ All checks passed — host is primed and ready.' : '❌ Some checks failed — see above.' } };
    if (d.ok) rememberRemote(spec());   // the picker + host list follow the knownRemotes signal automatically
  });
  es.addEventListener('failed', e => { closeES(); steps.value = { ...steps.value, note: null, err: e.data }; });
}

// ── components ──────────────────────────────────────────────────────────────────────────
function TestSteps() {
  const s = steps.value;
  if (!s) return null;
  if (s.empty) return html`<div class="pddim">${s.empty}</div>`;
  const mark = st => st === 'run' ? html`<span class="hydspin"></span>` : st === 'ok' ? '✓' : st === 'skip' ? '–' : '✗';
  return html`
    ${s.note ? html`<div class="rtnote"><span class="hydspin"></span> ${s.note}</div>` : null}
    ${s.verdict ? html`<div class=${'rtverdict ' + (s.verdict.ok ? 'ok' : 'fail')}>${s.verdict.text}</div>` : null}
    <div>${s.rows.map(r => html`<div class=${'rtstep ' + (r.status === 'run' ? 'run' : r.status)}>
      <span class="rtmark">${mark(r.status)}</span> <b>${r.name}</b> <span class="rtms">${r.status === 'run' ? '…' : r.ms + 'ms'}</span>
      ${r.detail ? html`<div class="rtdetail">${r.detail}</div>` : null}</div>`)}</div>
    ${s.err ? html`<div class="rtnote err">${s.err}</div>` : null}`;
}

function KnownHosts() {
  const all = allHosts.value, glob = sshGlobal.value, ssh = sshHosts.value, regs = regions.value;
  if (!all.length) return html`<div class="rthosts"><div class="pddim" style="margin-top:6px">No remotes yet — test one above to add it.</div></div>`;
  const nreg = h => regs.filter(r => r.host === h).length;
  return html`<div class="rthosts"><div class="rthhead">Known remotes</div>
    ${all.map(h => {
      const isDef = h === glob, isCustom = ssh.indexOf(h) < 0, n = nreg(h);
      return html`<div class=${'rthrow' + (isDef ? ' isdef' : '')}>
        <span class="rthname" role="button" title="use this remote" onClick=${() => host.value = h}>${isDef ? '★' : '🖧'} ${h}${isDef ? html` <em>(default)</em>` : null}${isCustom ? html` <em>(custom)</em>` : null}${n ? html` <em>(${n} region${n > 1 ? 's' : ''})</em>` : null}</span>
        <span class="rthbtns">
          <button class="rthexp" title="regions & live workers on this host" onClick=${() => { editRegion.value = null; focusHost.value = h; }}>Regions ›</button>
          ${isDef
            ? html`<button class="rthdef" title="stop using this as the default → new notebooks run local" onClick=${() => setDefaultHost('')}>★ Unset</button>`
            : html`<button class="rthdef" title="make this the default for new notebooks" onClick=${() => setDefaultHost(h)}>★ Default</button>`}
          ${isCustom ? html`<button class="rthforget" title="forget this custom host" onClick=${() => forgetHost(h)}>✕</button>` : null}
        </span></div>`;
    })}</div>`;
}

function Modal() {
  const open = modalOpen.value, focused = !!focusHost.value;
  const close = () => { modalOpen.value = false; focusHost.value = ''; editRegion.value = null; steps.value = null; };
  // Manage the backdrop's .show class + Esc / click-outside on the #remotesbg container, and load the
  // registry / xfer / ssh hosts when the modal opens (works for both entry points — topbar + activity).
  useEffect(() => {
    const bg = document.getElementById('remotesbg');
    if (!bg) return;
    bg.classList.toggle('show', open);
    if (!open) { closeES(); return; }
    loadRegions(); loadXfer(); loadRunon();
    if (!focusHost.value) { const hi = document.getElementById('rthost'); hi && hi.focus(); }
    const onKey = e => {
      if (e.key !== 'Escape') return;   // the worker-detail popup (activity.js) handles its own Esc first (capture-phase)
      if (focusHost.value) { e.stopPropagation(); focusHost.value = ''; editRegion.value = null; }
      else close();
    };
    const onDown = e => { if (e.target === bg) close(); };
    document.addEventListener('keydown', onKey);
    bg.addEventListener('mousedown', onDown);
    return () => { document.removeEventListener('keydown', onKey); bg.removeEventListener('mousedown', onDown); };
  }, [open]);

  const x = xfer.value || {};
  return html`<div class=${'modal remotesmodal' + (focused ? ' focusmode' : '')}>
    <button class="modalx" title="Close (Esc)" onClick=${close}>✕</button>
    <div class="msg"><strong>Remote hosts</strong><span style="display:block;margin-top:3px;font-size:.78rem;color:#7a82a4;font-weight:400">Run notebooks on another machine. A remote is any SSH host you already reach with key auth (a <code>Host</code> in ~/.ssh/config).</span></div>
    <div class="imrow"><label>Host</label><input id="rthost" spellcheck="false" autocomplete="off" placeholder="ssh_host (or user@host)"
      value=${host.value} onInput=${e => host.value = e.target.value} onKeyDown=${e => { if (e.key === 'Enter') { e.preventDefault(); runTest(); } }}/></div>
    <div class="imrow"><label>Transport</label>
      <span class="rttr">
        <label><input type="radio" name="rttr" value="tunnel" checked=${tr.value === 'tunnel'} onChange=${() => tr.value = 'tunnel'}/> SSH tunnel</label>
        <label><input type="radio" name="rttr" value="direct" checked=${tr.value === 'direct'} onChange=${() => tr.value = 'direct'}/> Direct · CURVE</label></span></div>
    ${tr.value === 'direct' ? html`<div class="imrow"><label>Ports</label>
      <span class="rttr"><input class="rtportin" type="number" min="1024" max="65535" placeholder="main" title="remote main/REP port — blank = auto (9100+)" value=${port.value} onInput=${e => port.value = e.target.value}/>
      <input class="rtportin" type="number" min="1024" max="65535" placeholder="stream" title="remote stream/PUB port — blank = main+1" value=${stream.value} onInput=${e => stream.value = e.target.value}/>
      <span class="pddim">blank = auto</span></span></div>` : null}
    <div class="rtactions"><button class="primary" onClick=${runTest}>🩺 Test & prime</button></div>
    <div class="rtsteps"><${TestSteps}/></div>
    <${KnownHosts}/>
    <div class="rthhead" style="margin-top:14px">Data transfer (all notebooks)</div>
    <div class="imrow"><label title="MB sent per round-trip when cached results move to a remote worker. Transfers ride their own channel, so this never delays cell results — it sets the round-trip granularity: smaller chunks bound per-chunk timeouts and let an abort land sooner on a slow uplink; bigger ones move data faster on a good link. Blank = default.">Transfer chunk size</label>
      <span class="rttr"><input id="rtxchunk" class="rtportin" type="number" min="0.1" step="0.5" placeholder=${x.effective_chunk_mb} value=${x.chunk_mb > 0 ? x.chunk_mb : ''} onChange=${commitXfer}/> <span class="pddim">MB / round-trip</span></span></div>
    <div class="imrow"><label title="When a notebook attaches to a remote worker, cached results are carried over only when moving them beats recomputing them — and never if one entry would take longer than this to transfer (the cell just recomputes remotely). The sync_memo tool always pushes everything. Blank = default.">Carry time budget</label>
      <span class="rttr"><input id="rtxcarry" class="rtportin" type="number" min="1" step="5" placeholder=${x.effective_carry_max_s} value=${x.carry_max_s > 0 ? x.carry_max_s : ''} onChange=${commitXfer}/> <span class="pddim">s / entry on attach</span></span></div>
    <div class="imrow"><label title="A cell needing a value from the other side of a region boundary pauses with a preview (exact size + estimated time) when the transfer would take longer than this; running the cell again proceeds. 0 disables previews. Blank = default.">Confirm transfers over</label>
      <span class="rttr"><input id="rtxconfirm" class="rtportin" type="number" min="0" step="5" placeholder=${x.effective_confirm_s} value=${x.confirm_s >= 0 ? x.confirm_s : ''} onChange=${commitXfer}/> <span class="pddim">s (0 = never ask)</span></span></div>
    <div class="rtfocus"><${Focus}/></div>
  </div>`;
}

// ── mount + init ────────────────────────────────────────────────────────────────────────
const bg = document.getElementById('remotesbg');
if (bg) render(html`<${Modal}/>`, bg);

// Run-on pickers (open-notebook bar + import dialog) — same host store, mounted here.
const om = document.getElementById('openrunon-mount'); if (om) render(html`<${RunOnPicker} id="openrunon"/>`, om);
const im = document.getElementById('imrunon-mount'); if (im) render(html`<${RunOnPicker} id="imrunon"/>`, im);

loadRunon();   // populate the pickers on page load (independent of the modal being opened)

// Open on the topbar button (data loads in Modal's open-effect). Resets the setup form to a clean list view.
const btn = document.getElementById('remotesbtn');
if (btn) btn.onclick = () => { focusHost.value = ''; editRegion.value = null; steps.value = null; port.value = ''; stream.value = ''; host.value = ''; modalOpen.value = true; };
