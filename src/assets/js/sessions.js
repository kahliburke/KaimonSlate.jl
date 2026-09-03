// Signing in to the hosts this machine works with.
//
// Keyed by HOST, not by cluster or region. Whether a host wants a password and a second factor is a
// property of its sshd — a cluster can take keys and a plain remote can demand 2FA — so this lists
// hosts and shows what each one is FOR. Sessions live in the hub, so one sign-in here covers every
// notebook on this machine, its sweeps and its regions.
//
// Mounted on BOTH pages (the home page and a notebook), because "am I signed in?" is the same
// question in both and the answer is the same session.
import { render, Fragment } from 'preact';
import { html } from 'htm/preact';
import { signal } from '@preact/signals';
import { useEffect } from 'preact/hooks';

const open = signal(false);
export const sessions = signal([]);   // [{host, used_by, connected, auth, asks}] — the one copy
const busy = signal('');          // the host an action is in flight for
const note = signal(null);        // {text, err}
const probing = signal('');

// On a NOTEBOOK page, only the hosts that notebook names — a notebook that sweeps on one cluster
// has no business showing a control for another. The home page passes no doc and gets all of them.
//
// From the URL rather than the page's state object: this is an ES module and `nbState` is a
// classic-script binding, which a module cannot see. `/n/<id>` is the notebook route.
const docId = () => {
  const m = /^\/n\/([^/]+)/.exec(location.pathname);
  return m ? decodeURIComponent(m[1]) : '';
};

export function loadSessions() {
  const d = docId();
  return fetch('/api/sessions' + (d ? '?doc=' + encodeURIComponent(d) : '')).then(r => r.json())
    .then(j => { sessions.value = (j && j.sessions) || []; }).catch(() => {});
}

// What the row says about getting in. `unknown` is honest: nothing has asked this host yet, and
// finding out costs a connection, so it stays unknown until someone presses Check.
const LABEL = {
  connected:   { text: 'signed in',     cls: 'ssok' },
  interactive: { text: 'sign-in needed', cls: 'sswarn' },
  key:         { text: 'key',            cls: 'ssdim' },
  unreachable: { text: 'unreachable',    cls: 'sserr' },
  unknown:     { text: 'not checked',    cls: 'ssdim' },
};

// The prompts arrive while the request below is open. The dialog is the same one a notebook uses
// for a prompt raised by a cell (sshauth.js) — there is only one way to answer a host.
function watchPrompts(stop) {
  let shown = null;
  const tick = () => {
    if (stop.done) return;
    fetch('/api/sshauth').then(r => r.json()).then(d => {
      const p = ((d && d.pending) || [])[0];
      if (p && p.id !== shown) { shown = p.id; window.onSshAuth && window.onSshAuth(p); }
    }).catch(() => {}).then(() => { if (!stop.done) setTimeout(tick, 400); });
  };
  tick();
}

function signIn(host, out) {
  busy.value = host;
  note.value = { text: out ? `closing the session on ${host}…` : `answer the prompts for ${host}…` };
  const stop = { done: false };
  if (!out) watchPrompts(stop);
  fetch('/api/host-session', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                               body: JSON.stringify({ host, logout: !!out }) })
    .then(r => r.json()).then(d => {
      const ok = !!(d && d.connected);
      note.value = ok ? { text: `signed in to ${host}` }
        : { text: out ? `signed out of ${host}` : ((d && d.error) || 'could not sign in'), err: !out };
      // This page gets no push, so hand the outcome to the dialog that is showing "signing in…".
      if (!out && window.onSshAuthResult) window.onSshAuthResult({ host, ok, error: (d && d.error) || '' });
      return loadSessions();
    })
    .catch(() => { note.value = { text: 'request failed', err: true }; })
    .then(() => { stop.done = true; busy.value = ''; });
}

// Ask the host what it wants, without authenticating.
function check(host) {
  probing.value = host;
  fetch('/api/sessions/probe', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                 body: JSON.stringify({ host }) })
    .then(r => r.json()).then(d => {
      sessions.value = sessions.value.map(r => r.host === host
        ? { ...r, auth: (d && d.auth) || 'unknown', error: (d && d.error) || '' } : r);
      if (d && d.error) note.value = { text: `${host}: ${d.error}`, err: true };
    })
    .catch(() => { note.value = { text: 'could not reach this Slate', err: true }; })
    .then(() => { probing.value = ''; });
}

function Row({ r }) {
  const st = r.connected ? 'connected' : (r.auth || 'unknown');
  const lab = LABEL[st] || LABEL.unknown;
  const working = busy.value === r.host;
  return html`<div class="ssrow">
    <span class="sshost">${r.host}</span>
    <span class=${'sstag ' + lab.cls}>${lab.text}</span>
    <span class="ssuse">${(r.used_by || []).join(' · ')}</span>
    ${working ? html`<span class="sswait"><span class="hydspin"></span> waiting…</span>`
     : r.connected
       ? html`<button class="ssbtn" onClick=${() => signIn(r.host, true)}>Sign out</button>`
       : html`<${Fragment}>
           <button class="ssbtn" disabled=${probing.value === r.host} onClick=${() => check(r.host)}>
             ${probing.value === r.host ? 'checking…' : 'Check'}</button>
           <button class="ssbtn ssgo" onClick=${() => signIn(r.host, false)}>Sign in</button>
         <//>`}
  </div>`;
}

function Panel() {
  useEffect(() => { if (open.value) { note.value = null; loadSessions(); } }, [open.value]);
  if (!open.value) return null;
  const rs = sessions.value;
  return html`<div class="ssback" onClick=${e => { if (e.target.classList.contains('ssback')) open.value = false; }}>
    <div class="sspanel" role="dialog" aria-modal="true">
      <div class="sshead">
        <span class="sstitle">🔑 Sign in to a host</span>
        <button class="ssclose" onClick=${() => open.value = false}>✕</button>
      </div>
      ${!rs.length ? html`<div class="ssempty">No hosts. One appears when a compute target or a
        region names it.</div>`
       : html`<div class="sslist">${rs.map(r => html`<${Row} key=${r.host} r=${r}/>`)}</div>`}
      <div class=${'ssmsg' + (note.value && note.value.err ? ' err' : '')}>${note.value ? note.value.text : ''}</div>
    </div>
  </div>`;
}

// A padlock, drawn rather than an emoji so it can take the state's colour. Open shackle = you are
// in; closed = you are not. `currentColor` throughout, so the tone is one CSS class.
const Padlock = ({ open }) => html`<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"
  fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
  <rect x=${open ? 2 : 3} y="7" width="9" height="6.5" rx="1.5"/>
  ${open ? html`<path d="M9 7V4.6a2.4 2.4 0 0 1 4.8 0v1"/>`
         : html`<path d="M5.6 7V4.6a2.4 2.4 0 0 1 4.8 0V7"/>`}
</svg>`;

// The topbar control. ABSENT when no host is involved — a notebook with no cluster and no region has
// nothing to sign in to, and a button for that is clutter. Otherwise the padlock carries the state
// and the tooltip carries the detail, so the common case needs no click at all.
function SignInButton() {
  // Only hosts there is something to sign INTO. One confirmed to take a key needs no session, so it
  // earns no control. `unknown` still counts: not having asked is not the same as not needing.
  const rs = sessions.value.filter(r => r.connected || r.auth !== 'key');
  if (!rs.length) return null;
  const bad  = rs.filter(r => !r.connected && r.auth === 'unreachable');
  const need = rs.filter(r => !r.connected && r.auth === 'interactive');
  const inn  = rs.filter(r => r.connected);
  // Red is a host that cannot be reached, amber one that is waiting for you, green nothing to do —
  // either signed in or takes a key. Green is the only one that shows an OPEN padlock.
  const tone = bad.length ? 'ssbad' : need.length ? 'ssneed' : 'ssin';
  const word = r => r.connected ? 'signed in'
             : r.auth === 'unreachable' ? 'unreachable'
             : r.auth === 'interactive' ? 'needs a sign-in'
             : r.auth === 'key' ? 'takes a key' : 'not checked';
  const title = (bad.length ? `${bad.length} unreachable\n` :
                 need.length ? `${need.length} waiting for a sign-in\n` :
                 inn.length ? `signed in to ${inn.length} of ${rs.length}\n` : '') +
                rs.map(r => `${r.host} — ${word(r)}`).join('\n') +
                '\n\nClick to sign in or out.';
  return html`<button class=${'ssbtn ssbar ' + tone} title=${title}
    aria-label="ssh sign-in" onClick=${() => openSessions()}>
    <${Padlock} open=${tone === 'ssin' && inn.length > 0}/>
  </button>`;
}

// One mount point, created on demand so neither page needs a placeholder div.
let panelHost = document.getElementById('sessions-mount');
if (!panelHost) { panelHost = document.createElement('div'); panelHost.id = 'sessions-mount'; document.body.appendChild(panelHost); }
render(html`<${Panel}/>`, panelHost);

const btnHost = document.getElementById('sessions-btn-mount');
if (btnHost) render(html`<${SignInButton}/>`, btnHost);

export function openSessions() { open.value = true; }
window.openSessions = openSessions;

// The button needs the list before anyone opens the panel — that is how it knows whether to appear
// at all. One cheap call; re-read after any sign-in, and on a timer slow enough to be free.
loadSessions();
setInterval(loadSessions, 30000);

if (location.hash === '#signin') openSessions();
