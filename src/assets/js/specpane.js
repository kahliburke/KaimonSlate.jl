// A specialist working inside a workspace: what it was asked, what it thinks and says, each step it
// takes, the questions it is waiting on, and a line to talk to it. One per role; a workspace makes
// its own with `specialistPane(role, …)` and renders the `Pane` it returns.
//
// The pane claims its role (`slateRolePanes`), so the notebook's chat leaves that role's questions
// to it, and it reads every agent envelope the page receives (`slateAgentEventSubs`), keeping the
// ones its role sent.

import { html } from 'htm/preact';
import { signal } from '@preact/signals';
import { useRef, useEffect } from 'preact/hooks';

const A = (m, p, b) => window.api(m, p, b);
const bareModel = (m) => String(m || '').replace(/^acp:\w+:/, '').replace(/^.*\//, '');

/**
 * `verbs`: tool name → the word a step is shown as. `arg(verb, input)`: what the step was about.
 * `gist(verb, text)`: the line worth keeping from its result. `onStep(verb, input)`: called when a
 * step starts, so the workspace can show what the specialist is looking at. `summonPath`: the route
 * that brings one in, posted `{cell}`.
 */
export function specialistPane(role, { verbs = {}, arg = () => '', gist = defaultGist, onStep = null, summonPath }) {
  const convo = signal([]);      // [{role:'brief'|'think'|'said'|'act'|'you', text, verb, arg, detail, done}]
  const working = signal(false);
  const asks = signal([]);
  const agent = signal(null);    // {agent_id, model} once one is here
  const queued = signal([]);
  const summoning = signal(false);

  const toolRe = new RegExp('(?:^|[^a-z])(' + Object.keys(verbs).sort((a, b) => b.length - a.length).join('|') + ')(?![a-z_])');
  const verbOf = (title) => { const m = toolRe.exec(String(title || '')); return m ? m[1] : null; };

  (window.slateRolePanes ||= new Set()).add(role);
  (window.slateSpecialistSubs ||= []).push((p) => {
    if (!p || p.role !== role) return;
    if (p.asks !== undefined) asks.value = (p.asks || []).filter(a => a.role === role);
    if (p.ask) asks.value = [...asks.value.filter(a => a.id !== p.ask.id), p.ask];
    if (p.specialist) agent.value = { ...(agent.value || {}), ...p.specialist };
  });

  function onEvent(env, live = true) {
    if (!env || env.crew !== role) return;
    const d = env.data || {}, k = env.kind;
    if (live && k !== 'result' && k !== 'turn_ended') working.value = true;
    const list = convo.value.slice();
    if (k === 'user_text') {
      const txt = (d.content && d.content.text) || d.text || '';
      // The first is the briefing; later ones are what you said, already shown when you sent it.
      if (txt && !list.some(m => (m.role === 'brief' || m.role === 'you') && m.text === txt))
        list.push({ role: list.some(m => m.role === 'brief') ? 'you' : 'brief', text: txt, done: true });
    } else if (k === 'assistant_text' || k === 'thought' || k === 'assistant') {
      const r = k === 'thought' ? 'think' : 'said';
      const txt = (d.content && d.content.text) || d.text || '';
      const last = list[list.length - 1];
      if (d.delta === true) {
        if (!txt) return;
        if (last && last.role === r && !last.done) last.text += txt;
        else list.push({ role: r, text: txt, done: false });
      } else if (last && last.role === r && !last.done) { last.text = txt || last.text; last.done = true; }
      else if (txt) list.push({ role: r, text: txt, done: true });
    } else if (k === 'tool_use') {
      // Sent when the call begins and again with its arguments, which the first may not carry.
      const c = d.call || {};
      const inp = c.rawInput || {}, known = Object.keys(inp).length > 0;
      let m = list.find(x => x.id === c.toolCallId);
      if (!m) {
        const name = verbOf(c.title || c.kind);
        if (!name) return;
        m = { role: 'act', id: c.toolCallId, name, verb: verbs[name], arg: '', input: {}, detail: '', done: false };
        list.push(m);
      }
      if (known && !m.hasInput) {
        m.hasInput = true; m.input = inp; m.arg = arg(m.name, inp);
        if (live && onStep) { try { onStep(m.name, inp); } catch (_) {} }
      }
    } else if (k === 'tool_result') {
      const u = d.update || {};
      const m = list.find(x => x.id === u.toolCallId);
      if (!m) return;
      const c = ((u.content || [])[0] || {}).content || {};
      m.detail = gist(m.name, c.text);
      m.failed = String(u.status || '') === 'failed';
      m.done = true;
    } else if (k === 'turn_started') { if (live) working.value = true; }
    else if (k === 'result' || k === 'turn_ended') {
      working.value = false;
      for (const m of list) if (!m.done) m.done = true;
      convo.value = list;
      if (live) setTimeout(flushQueue, 0);
      return;
    }
    convo.value = list;
  }
  (window.slateAgentEventSubs ||= []).push((env) => onEvent(env, true));

  // A message sent while it works is held to the end of the turn: a second message into a running
  // turn would replace the reply it is writing. Interrupt to make it read you now.
  async function deliver(text) {
    try {
      const r = await A('POST', '/api/chat', { text, crew: role });
      if (r && r.ok === false) { working.value = false; convo.value = [...convo.value, { role: 'said', text: '⚠ ' + (r.error || 'not delivered'), done: true }]; }
    } catch (e) { working.value = false; }
  }
  function say(text) {
    if (!text.trim()) return;
    convo.value = [...convo.value, { role: 'you', text, done: true, held: working.value }];
    if (working.value) { queued.value = [...queued.value, text]; return; }
    working.value = true;
    deliver(text);
  }
  function flushQueue() {
    const q = queued.value;
    if (!q.length) return;
    queued.value = [];
    convo.value = convo.value.map(m => (m.held ? { ...m, held: false } : m));
    working.value = true;
    deliver(q.join('\n\n'));
  }
  async function interrupt() {
    try { await A('POST', '/api/chat-interrupt', { crew: role }); } catch (e) {}
    working.value = false;
    setTimeout(flushQueue, 300);
  }
  async function answer(id, text) {
    try {
      const r = await A('POST', '/api/debug/answer', { id, text });
      asks.value = ((r && r.asks) || []).filter(a => a.role === role);
    } catch (e) {}
  }

  // Brought in with the model the role is set to (Settings → agent roles), else the notebook's.
  async function summon(cell) {
    if (summoning.value) return false;
    summoning.value = true;
    try {
      const r = await A('POST', summonPath, { cell });
      if (r && r.ok) { agent.value = { agent_id: r.agent_id, model: r.model || '', cell }; working.value = true; return true; }
      convo.value = [...convo.value, { role: 'said', text: '⚠ ' + ((r && r.error) || 'could not bring a specialist in'), done: true }];
      return false;
    } catch (e) { return false; } finally { summoning.value = false; }
  }

  // After a reload: the specialist and its transcript live on the server, so replay them.
  async function resume() {
    try {
      const log = await A('GET', '/api/agent-log');
      const aid = (log && log.agents && log.agents[role]) || '';
      if (!aid) return;
      agent.value = { agent_id: aid, model: '' };
      for (const line of (log.events || [])) { try { onEvent(JSON.parse(line), false); } catch (_) {} }
      working.value = false;
      const q = await A('GET', '/api/asks');
      asks.value = ((q && q.asks) || []).filter(a => a.role === role);
    } catch (e) {}
  }

  function Pane({ title, onClose, extra = null }) {
    const log = useRef(null), stick = useRef(true);
    const rows = convo.value, w = working.value;
    useEffect(() => { const el = log.current; if (el && stick.current) el.scrollTop = el.scrollHeight; });
    const scrolled = () => { const el = log.current; if (el) stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40; };
    const a = agent.value;
    return html`<div class="sppane">
      <div class="sphead">
        <span class="sptitle">${title}</span>
        ${w ? html`<span class="hydspin"></span>` : null}
        <span class="spsp"></span>
        ${extra}
        ${a && a.model ? html`<span class="spmodel" title=${a.model}>${bareModel(a.model)}</span>` : null}
        ${w ? html`<button class="spbtn" title="stop its turn, so it reads you now" onClick=${interrupt}>interrupt</button>` : null}
        ${onClose ? html`<button class="spx" title="hide (it keeps working)" onClick=${onClose}>✕</button>` : null}
      </div>
      <div class="splog" ref=${log} onScroll=${scrolled}>
        ${!rows.length ? html`<div class="spempty">${w || summoning.value ? html`<span class="hydspin"></span> starting` : ''}</div>` : null}
        ${rows.map((m, i) => html`<${Row} key=${m.id || i} m=${m} />`)}
        ${w && rows.length ? html`<div class="spworking"><span class="hydspin"></span> working</div>` : null}
      </div>
      ${asks.value.length ? html`<div class="spasks">${asks.value.map(q => html`<${Ask} key=${q.id} q=${q} answer=${answer} />`)}</div>` : null}
      <form class="spsay" onSubmit=${e => { e.preventDefault(); const el = e.target.querySelector('input'); say(el.value); el.value = ''; }}>
        <input autocomplete="off" placeholder=${w ? 'tell it something (it reads this when its turn ends)' : 'tell it something'} />
      </form>
    </div>`;
  }

  return { role, convo, working, asks, agent, summoning, summon, resume, say, interrupt, Pane };
}

function defaultGist(_verb, text) {
  const s = String(text || '').trim();
  return s ? s.split('\n').find(l => l.trim()) .slice(0, 160) : '';
}

// `code` and **bold** in what it writes, and nothing else: a transcript, not a document.
function inline(text) {
  const out = [];
  String(text).split(/(`[^`]+`|\*\*[^*]+\*\*)/).forEach((p, i) => {
    if (p.startsWith('`') && p.endsWith('`') && p.length > 2) out.push(html`<code key=${i}>${p.slice(1, -1)}</code>`);
    else if (p.startsWith('**') && p.endsWith('**') && p.length > 4) out.push(html`<b key=${i}>${p.slice(2, -2)}</b>`);
    else if (p) out.push(p);
  });
  return out;
}

function Row({ m }) {
  if (m.role === 'act') return html`<div class=${'spact' + (m.failed ? ' failed' : '')}>
    <span class="spverb">${m.verb}</span>
    <span class="sparg">${m.arg}</span>
    ${m.done ? (m.detail ? html`<span class="spgist">${m.detail}</span>` : null) : html`<span class="hydspin"></span>`}
  </div>`;
  if (m.role === 'brief') return html`<details class="spbrief"><summary>asked to: ${firstLine(m.text)}</summary><pre>${m.text}</pre></details>`;
  if (m.role === 'think') return html`<details class="spthink" open=${!m.done}><summary>thinking</summary><div>${inline(m.text)}</div></details>`;
  if (m.role === 'you') return html`<div class="spyou">${m.text}${m.held ? html`<span class="spheld">when its turn ends</span>` : null}</div>`;
  return html`<div class="spsaid">${block(m.text)}</div>`;
}
// Headings as headings; every other line as written.
function block(text) {
  return String(text).split('\n').map((l, i) => {
    const h = /^(#{1,4})\s+(.*)$/.exec(l);
    return h ? html`<div class="sph" key=${i}>${inline(h[2])}</div>` : html`<div key=${i}>${l ? inline(l) : '\u00a0'}</div>`;
  });
}
// The briefing ends with the request, after the context it carries.
function firstLine(t) {
  const ls = String(t).trim().split('\n').map(s => s.trim()).filter(Boolean);
  const last = ls[ls.length - 1] || '';
  return last.length > 90 ? last.slice(0, 90) + '…' : last;
}

function Ask({ q, answer }) {
  return html`<div class=${'spask ' + (q.kind || '')}>
    <div class="spaskq">${inline(q.text)}</div>
    ${q.kind === 'consent'
      ? html`<div class="spaskbtns"><button class="spbtn primary" onClick=${() => answer(q.id, 'yes')}>Allow</button>
          <button class="spbtn" onClick=${() => answer(q.id, 'no')}>Keep it</button></div>`
      : q.kind === 'choice' && (q.options || []).length
      ? html`<div class="spaskbtns">${q.options.map(o => html`<button class="spbtn" key=${o.value} title=${o.value}
            onClick=${() => answer(q.id, o.value)}>${o.label}</button>`)}
          <button class="spbtn dim" title="answer in your own words below" onClick=${() => answer(q.id, '')}>none of these</button></div>`
      : html`<form class="spsay" onSubmit=${e => { e.preventDefault(); const el = e.target.querySelector('input'); answer(q.id, el.value); el.value = ''; }}>
          <input autocomplete="off" autofocus placeholder="answer…" /></form>`}
  </div>`;
}

const style = document.createElement('style');
style.textContent = `
.sppane { display:flex; flex-direction:column; min-width:0; min-height:0; height:100%; background:var(--bg); }
.sphead { display:flex; align-items:center; gap:8px; padding:6px 10px; border-bottom:1px solid var(--border); font-size:.76rem; }
.sptitle { font-weight:600; color:var(--text); }
.spsp { flex:1 1 auto; }
.spmodel { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); font-size:.7rem; }
.spbtn { font:inherit; font-size:.72rem; padding:2px 9px; border-radius:5px; cursor:pointer; background:var(--bg3); color:var(--text); border:1px solid var(--border); }
.spbtn:hover { border-color:#e8933a; }
.spbtn.primary { border-color:color-mix(in srgb, #e8933a 60%, var(--border)); background:color-mix(in srgb, #e8933a 18%, var(--bg3)); }
.spbtn.dim { color:var(--dim); }
.spx { padding:1px 7px; border-radius:5px; background:transparent; border:1px solid transparent; color:var(--dim); cursor:pointer; }
.spx:hover { color:var(--text); border-color:var(--border); }
.splog { flex:1 1 auto; min-height:0; overflow:auto; overscroll-behavior:contain; padding:8px 10px; display:flex; flex-direction:column; gap:7px; font-size:.78rem; line-height:1.5; }
.spempty, .spworking { display:flex; align-items:center; gap:7px; color:var(--dim); font-size:.74rem; }
.spsaid { color:var(--text); white-space:pre-wrap; }
.sph { font-weight:600; color:var(--text); margin-top:4px; }
.spsaid code, .spthink code, .spaskq code { font-family:var(--mono,ui-monospace,monospace); font-size:.92em; padding:0 3px; border-radius:3px; background:var(--bg3); }
.spthink { color:var(--dim); font-size:.74rem; }
.spthink summary, .spbrief summary { cursor:pointer; color:var(--dim); font-size:.72rem; }
.spthink div { white-space:pre-wrap; font-style:italic; margin-top:3px; }
.spbrief pre { white-space:pre-wrap; font-size:.7rem; color:var(--dim); max-height:240px; overflow:auto; margin:4px 0 0; }
.spact { display:flex; align-items:baseline; gap:7px; padding:3px 7px; border-radius:6px; background:color-mix(in srgb, var(--bg3) 60%, transparent);
  font-size:.74rem; min-width:0; }
.spact.failed { box-shadow:inset 2px 0 0 var(--red); }
.spverb { flex:0 0 auto; color:#e8933a; font-weight:600; }
.sparg { font-family:var(--mono,ui-monospace,monospace); color:var(--text); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; min-width:0; }
.spgist { margin-left:auto; color:var(--dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; min-width:0; max-width:50%; }
.spyou { align-self:flex-end; max-width:85%; padding:5px 9px; border-radius:8px; background:color-mix(in srgb, #e8933a 14%, var(--bg3)); white-space:pre-wrap; }
.spheld { display:block; color:var(--dim); font-size:.68rem; }
.spasks { flex:0 0 auto; display:flex; flex-direction:column; gap:8px; padding:8px 10px; border-top:1px solid var(--border);
  background:color-mix(in srgb, #ffd27a 6%, var(--bg)); }
.spask { display:flex; flex-direction:column; gap:7px; font-size:.78rem; }
.spaskq { color:var(--text); line-height:1.5; white-space:pre-wrap; }
.spaskbtns { display:flex; flex-wrap:wrap; gap:6px; }
.spsay { flex:0 0 auto; margin:0; padding:7px 10px; border-top:1px solid var(--border); }
.spask .spsay { padding:0; border:none; }
.spsay input { width:100%; box-sizing:border-box; font:inherit; font-size:.78rem; padding:5px 9px; border-radius:6px; background:var(--bg2);
  color:var(--text); border:1px solid var(--border); }
.spsay input:focus { outline:none; border-color:#e8933a; }
`;
document.head.appendChild(style);
