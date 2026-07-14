// Shared remote-host store for the home page (index.html) Preact islands. The locally-remembered remote
// list + the ssh-config fetch live here as signals, so every consumer — the open-notebook + import
// run-on pickers and the Remotes modal's known-hosts list — reads/writes ONE source of truth (this
// retires the window.slateKnownRemotes bridge the vanilla shell used to expose).
//
// localStorage key `slateRemotes`: a JSON array of "host[,transport[,port,stream]]" specs — hosts you've
// tested here that aren't in ~/.ssh/config, remembered so they stay pickable (the "set up a new remote"
// story). `/api/ssh-hosts` supplies the ~/.ssh/config aliases + the global default (server-side, not
// localStorage).
import { html } from 'htm/preact';
import { signal, computed } from '@preact/signals';
import { useState } from 'preact/hooks';

// ── the store (signals) ──────────────────────────────────────────────────────────────
export const sshHosts = signal([]);              // ~/.ssh/config aliases (from /api/ssh-hosts)
export const sshGlobal = signal('');             // the global run-on default host ('' = local)
export const knownRemotes = signal(_readKnown()); // locally-remembered specs (a signal so lists re-render)

function _readKnown() { try { return JSON.parse(localStorage.getItem('slateRemotes') || '[]'); } catch (_) { return []; } }
function _writeKnown(a) { try { localStorage.setItem('slateRemotes', JSON.stringify(a)); } catch (_) {} knownRemotes.value = a; }

export function rememberRemote(spec) { if (!spec || spec === 'local') return; const a = knownRemotes.value.slice(); if (a.indexOf(spec) < 0) { a.push(spec); _writeKnown(a); } }
export function forgetRemote(spec) { _writeKnown(knownRemotes.value.filter(x => x !== spec)); }
export function forgetHost(h) { _writeKnown(knownRemotes.value.filter(s => s.split(',')[0] !== h)); }

// ssh-config hosts ∪ the host-part of each remembered spec (sorted by first-seen, ssh first).
export const allHosts = computed(() => {
  const s = sshHosts.value.slice();
  knownRemotes.value.forEach(spec => { const h = spec.split(',')[0]; if (s.indexOf(h) < 0) s.push(h); });
  return s;
});

// Default transport for a NEW region on a host: inferred from a remembered `,direct` spec (else tunnel).
export function hostTransport(h) { const s = knownRemotes.value.filter(x => x.split(',')[0] === h)[0] || ''; return s.indexOf('direct') >= 0 ? 'direct' : 'tunnel'; }

// ── server sync ──────────────────────────────────────────────────────────────────────
export function loadRunon() {
  return fetch('/api/ssh-hosts').then(r => r.json()).then(d => { sshHosts.value = d.hosts || []; sshGlobal.value = d.global || ''; }).catch(() => {});
}
// Set (or clear, host='') the global run-on default; server persists it in slate.json.
export function setDefaultHost(host) {
  return fetch('/api/run-on-default', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ host }) })
    .then(r => r.json()).then(d => { sshGlobal.value = (d && d.global) || ''; }).catch(() => {});
}

// ── RunOnPicker ────────────────────────────────────────────────────────────────────────
// Renders the SAME <select id=${id}> + <input id=${id}host> DOM the still-vanilla openPath/startImport
// read on submit via _runonOf(id) — so those submit paths stay untouched while option rendering moves
// here. `id` is 'openrunon' or 'imrunon'. Options mirror the old _fillRunon: '' = default/local, an
// explicit 'local' when a global default exists, each host as '🖧 host', and '__custom__' = free-text.
export function RunOnPicker({ id }) {
  const hostId = id + 'host';
  // Selected value is controlled state so it survives store-driven re-renders (options reload) — the old
  // _fillRunon restored it by hand. _runonOf reads the DOM select.value, which equals this.
  const [val, setVal] = useState('');
  const custom = val === '__custom__';
  const opts = [];
  opts.push(html`<option value="">${sshGlobal.value ? 'Default — ' + sshGlobal.value + ' (global)' : 'Local (this machine)'}</option>`);
  if (sshGlobal.value) opts.push(html`<option value="local">Local (this machine)</option>`);
  allHosts.value.forEach(h => { if (h !== sshGlobal.value) opts.push(html`<option value=${h}>🖧 ${h}</option>`); });
  opts.push(html`<option value="__custom__">✎ Custom host…</option>`);
  const onChange = (e) => {
    setVal(e.target.value);
    if (e.target.value === '__custom__') { const hi = document.getElementById(hostId); if (hi) setTimeout(() => hi.focus(), 0); }
  };
  return html`
    <select id=${id} class="runonsel" title="where this notebook's worker will run" value=${val} onChange=${onChange}>${opts}</select>
    <input id=${hostId} class="runonsel" type="text" placeholder="ssh host (or user@host)"
           spellcheck="false" autocomplete="off" style=${'display:' + (custom ? 'inline-block' : 'none')}/>`;
}
