// ALLOCATION NOTICE — the takeover popup for a compute node that is about to go, or has gone.
//
// Three occasions, one shell, because they ask the same question with different stakes: an idle
// region about to be released, a walltime about to end, and a node that went while nobody was
// looking. The hub pushes FIELDS (see `_ask_still_there!`); every sentence below is written here,
// where the buttons are.
//
// Mounted like mesh.js: a body-appended host, driven by one signal, no notebook.html change.
import { html } from 'htm/preact';
import { render } from 'preact';
import { signal } from '@preact/signals';

const notice = signal(null);   // the pushed payload while the popup is up, else null
const busy   = signal('');     // '' | 'extend' | 'keep' — which action is in flight
const err    = signal('');
const now    = signal(Date.now());

setInterval(() => { if (notice.value) now.value = Date.now(); }, 1000);

// ── shared bits ───────────────────────────────────────────────────────────────────
// Two shapes, as elsewhere: `api` is scoped to THIS notebook (core.js rewrites /api/… to
// /api/<nb>/…), while the allocation routes are hub-wide because a region is not one notebook's.
const api  = (m, p, b) => window.api(m, p, b);
const gapi = (m, p, b) => fetch(p, {
  method: m, headers: { 'Content-Type': 'application/json' },
  body: m === 'GET' ? undefined : JSON.stringify(b || {}),
}).then(r => r.json());

// Module scope, not per render: a signal rebuilt inside the component resets the field on every
// keystroke's re-render.
const amount = signal('30m');

// Seconds as the largest unit that reads cleanly. Deliberately coarse above a minute: a countdown
// ticking every second on a five-minute warning is noise, not information.
function human(s) {
  s = Math.max(0, Math.round(s));
  if (s < 60) return s + 's';
  if (s < 3600) return Math.round(s / 60) + 'm';
  if (s < 86400) return (s / 3600).toFixed(s % 3600 ? 1 : 0) + 'h';
  return (s / 86400).toFixed(s % 86400 ? 1 : 0) + 'd';
}

// How long is left, ticked locally from the pushed deadline so the hub pushes once, not per second.
function secondsLeft(n) {
  if (!n || !n.deadline) return 0;
  return Math.max(0, (n.deadline - now.value) / 1000);
}

function Countdown({ n }) {
  const s = secondsLeft(n);
  return html`<span class=${'anclock' + (s <= 60 ? ' urgent' : '')}>${human(s)}</span>`;
}

function Where({ n }) {
  return html`<div class="anwhere">
    <span class="anreg">🖧 ${n.region}</span>
    ${n.node ? html`<span class="annode">${n.node}</span>` : null}
    ${n.node && n.host && n.node !== n.host ? html`<span class="anvia">via ${n.host}</span>` : null}
    ${+n.walltime_left >= 0 ? html`<span class="anwall">walltime ${human(+n.walltime_left)} left</span>` : null}
  </div>`;
}

// The extend control, shown only when the scheduler actually accepted a probe extension. Sites
// mostly refuse, so an always-visible button that always fails would be worse than none.
function Extend({ n }) {
  // Nothing at all when the site refuses: an extension that cannot be asked for is not a fact the
  // reader has to act on, and the scheduler's refusal text belongs in the log.
  if (!n.extendable) return null;
  const go = async () => {
    busy.value = 'extend'; err.value = '';
    const r = await gapi('POST', '/api/allocation/extend', { region: n.region, by: amount.value });
    busy.value = '';
    if (r && r.ok) { notice.value = null; return; }
    err.value = extendError(r);
  };
  return html`<div class="anextend">
    <label>Extend by</label>
    <input class="anamount" value=${amount.value} onInput=${e => amount.value = e.target.value}
           placeholder="30m" title="how much longer to ask for — 30m, 1h, 2h"/>
    <button class="anbtn" disabled=${!!busy.value} onClick=${go}>
      ${busy.value === 'extend' ? 'Asking…' : 'Extend'}</button>
  </div>`;
}

// Codes from the hub, worded here.
function extendError(r) {
  const c = r && (r.error || r.reason);
  if (c === 'refused')        return 'the scheduler refused' + (r.said ? ': ' + r.said : '');
  if (c === 'unreachable')    return 'could not reach the cluster to ask';
  if (c === 'no_allocation')  return 'there is no running allocation to extend';
  if (c === 'unreadable')     return 'could not read the current walltime';
  if (c === 'unsupported')    return 'this scheduler cannot extend a running job';
  return c || 'the request failed';
}

// ── the three bodies ──────────────────────────────────────────────────────────────
function IdleBody({ n }) {
  // Actually release, rather than dismissing and letting the timer finish: the button says now.
  const release = async () => {
    busy.value = 'release'; err.value = '';
    await gapi('POST', '/api/allocation/release', { region: n.region });
    busy.value = ''; notice.value = null;
  };
  const keep = async () => {
    busy.value = 'keep'; err.value = '';
    await gapi('POST', '/api/allocation/keep', { region: n.region });
    busy.value = ''; notice.value = null;
  };
  return html`<div>
    <h3 class="antitle">Still using ${n.region}?</h3>
    <${Where} n=${n}/>
    <p class="anlede">Idle ${human(n.idle_release)}. ${secondsLeft(n) <= 0
      ? html`Releasing now.`
      : html`Releasing in <${Countdown} n=${n}/>.`}</p>
    <p class="andim">Next run re-queues.</p>
    <${Extend} n=${n}/>
    ${err.value ? html`<div class="anerr">${err.value}</div>` : null}
    <div class="anacts">
      <button class="anbtn" disabled=${!!busy.value} onClick=${release}>
        ${busy.value === 'release' ? 'Releasing…' : 'Release now'}</button>
      <button class="anbtn primary" disabled=${!!busy.value} onClick=${keep}>
        ${busy.value === 'keep' ? 'Keeping…' : 'Keep'}</button>
    </div>
  </div>`;
}

function WalltimeBody({ n }) {
  // At zero the countdown has nothing left to count, and "expires in 0s" describes a future that has
  // already happened. The advice goes with it: there is no longer time to act on it.
  const over = secondsLeft(n) <= 0;
  return html`<div>
    <h3 class="antitle">${n.region}: allocated time ${over ? 'has run out' : 'expiring'}</h3>
    <${Where} n=${n}/>
    <p class="anlede">${over
      ? html`This worker's allocated time has run out. The scheduler is ending the session.`
      : html`This worker's allocated time expires in <${Countdown} n=${n}/>. Persist any
             results before the scheduler ends the session.`}</p>
    <p class="andim">Next run re-queues.</p>
    <${Extend} n=${n}/>
    ${err.value ? html`<div class="anerr">${err.value}</div>` : null}
    <div class="anacts">
      <button class="anbtn primary" onClick=${() => notice.value = null}>Dismiss</button>
    </div>
  </div>`;
}

function ReleasedBody({ n }) {
  return html`<div>
    <h3 class="antitle">${n.region}'s node was released</h3>
    <${Where} n=${n}/>
    <p class="anlede">${n.reason === 'walltime' ? 'Walltime expired.'
                                                : 'Idle ' + human(n.idle_release) + '.'}</p>
    <div class="anacts">
      <button class="anbtn primary" onClick=${dismiss}>Dismiss</button>
    </div>
  </div>`;
}

const BODIES = { idle: IdleBody, walltime: WalltimeBody, released: ReleasedBody };

// A `released` notice is held by the hub until acknowledged, so dismissing one has to say so —
// otherwise it reappears on the next load, having already been read.
function dismiss() {
  const n = notice.value;
  notice.value = null;
  if (n && n.kind === 'released') api('POST', '/api/alloc-notice/ack', {}).catch(() => {});
}

function AllocNotice() {
  const n = notice.value;
  if (!n) return null;
  const Body = BODIES[n.kind] || ReleasedBody;
  return html`<div class="anbg"><div class="ancard" role="dialog" aria-modal="true">
    <${Body} n=${n}/>
  </div></div>`;
}

const host = document.createElement('div');
host.id = 'allocnoticebg';
document.body.appendChild(host);
render(html`<${AllocNotice} />`, host);

// Escape dismisses, except mid-action — the same rule mesh.js uses.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && notice.value && !busy.value) { e.stopPropagation(); dismiss(); }
}, true);

// Live push from the hub (panels.js SSE dispatch). `seconds_left` arrives once; the deadline is
// derived here so the countdown does not need a tick from the server.
window.onAllocNotice = p => {
  if (!p || !p.region) return;
  err.value = ''; busy.value = '';
  // The clock only ticks while a notice is up, so it is stale on arrival — the first render would
  // count from whenever the page last had one.
  now.value = Date.now();
  notice.value = { ...p, deadline: now.value + (+p.seconds_left || 0) * 1000 };
};

// The release happens because nobody was here, so the page asks on load rather than waiting for a
// push it could not have received.
api('GET', '/api/alloc-notice').then(r => {
  if (r && r.pending) window.onAllocNotice(r);
}).catch(() => {});
