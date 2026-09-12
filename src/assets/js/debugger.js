// Cell debugger — Preact island. Two surfaces over one session.
//
// The STRIP lives under the cell being stepped: controls, where it is running, and the values in
// scope. It is where you spend most of a session, because most of a session is spent on the cell's
// own lines, which the cell's own editor is already showing (gold line, via markDebugLine).
//
// The FOCUS view is for the moment you step INTO something. The frame is then a method in a file —
// usually on a different machine from the browser — and the cell has no line to highlight because
// the code is not in it. So the focus view shows that source, the call stack that got there, and a
// scratchpad that evaluates in the paused frame.
//
// Nothing here is remote-aware beyond a label. The server resolves which kernel a cell runs on once,
// at start (server_debug.jl), and every verb after that lands on the same one — a region worker
// across an SSH tunnel answers the same five routes a local one does. What IS remote-aware is the
// values: a frame on a compute node can hold far more than a viewer wants, so what arrives is a
// summary (type, size, a clipped repr) and never the value.
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';
import { useRef, useEffect } from 'preact/hooks';

// ── state ─────────────────────────────────────────────────────────────────────────────────────────
// One session per notebook (the interpreter's compiled-module scope is process-global, so two at
// once on one kernel would fight over it) — hence one signal, not a map.
const DEBUG_ROLE = 'debugger';   // which specialist this workspace is for
const st = signal(null);      // the debug state from the server, or null when nothing is running
const busy = signal(false);   // a verb is in flight — the controls disable rather than queue
const focus = signal(false);  // focus view open
const probes = signal([]);    // scratchpad history: {expr, ok, repr, type, error}
const changed = signal(new Set());  // names whose repr moved on the last step (for the flash)
// Breakpoints, as the server holds them: [{file, line}]. `file` is `cell:<id>` for notebook code
// and a real path for a package — the browser never interprets it, it only groups by it.
const marks = signal([]);
// Which stack frame the source pane shows. `null` follows the current frame, which is what you
// want while stepping; an index pins a CALLER, because the line you are stopped on is often not
// the line that is wrong — the arguments that got you here were built further up.
const selFrame = signal(null);
// Requests an agent is BLOCKED on: [{id, kind, from, text}]. A question it needs answered, or
// permission to disturb a session it does not own. Its turn is stopped until one of these is
// answered, so they are shown where the session is, not tucked in a notification.
const asks = signal([]);

const live = computed(() => st.value && !st.value.finished);
export const debugCell = computed(() => (st.value ? st.value.cell : ''));

const A = (m, p, b) => window.api(m, p, b);

// Which names changed between two states — the point of stepping is watching a value arrive, so
// the ones that just moved are worth marking. Keyed by name across BOTH panes; a local and a
// binding never share a name in the same frame.
function diffNames(prev, next) {
  const out = new Set();
  if (!prev || !next) return out;
  const was = new Map();
  for (const v of [...(prev.locals || []), ...(prev.bindings || [])]) was.set(v.name, v.repr);
  for (const v of [...(next.locals || []), ...(next.bindings || [])]) {
    if (was.get(v.name) !== v.repr) out.add(v.name);
  }
  return out;
}

// Paint the gutters from the server's set. Grouped by cell so an editor is dispatched once, and
// every code cell is repainted — including the ones dropping back to none — so a cleared
// breakpoint cannot leave a dot behind.
let _painted = [];
function paintMarks(ms) {
  marks.value = ms || [];
  const byCell = new Map();
  for (const m of marks.value) {
    if (!m.file || m.file.indexOf('cell:') !== 0) continue;
    const id = m.file.slice(5);
    if (!byCell.has(id)) byCell.set(id, []);
    byCell.get(id).push({ line: m.line, enabled: m.enabled !== false });
  }
  for (const id of _painted) if (!byCell.has(id)) window.setBreakpointLines?.(id, []);
  for (const [id, lines] of byCell) window.setBreakpointLines?.(id, lines);
  _painted = [...byCell.keys()];
}

// The gutter is mounted only while the notebook is debugging — see setDebugGutter. A session or a
// breakpoint both count, so a mark survives Stop and you can set the next one without restarting.
function syncGutter() {
  window.setDebugGutter?.(!!st.value || marks.value.length > 0);
}

async function setMark(file, line, on, cond, enabled) {
  const body = { file, line };
  if (on !== undefined) body.on = on;
  if (cond !== undefined) body.cond = cond;
  if (enabled !== undefined) body.enabled = enabled;
  try {
    const r = await A('POST', '/api/debug/mark', body);
    if (r && r.ok === false) { probes.value = [...probes.value, { expr: cond, ok: false, error: r.error }]; return; }
    paintMarks(r && r.marks);
    syncGutter();
  } catch (e) {}
}
const toggleMark = (cellId, line) => setMark('cell:' + cellId, line);

// A breakpoint that only fires when an expression holds. This is what makes a long run reachable:
// stopping on the first pass of a loop shows the iteration that is fine, and you cannot step to
// the four-thousandth. The predicate is evaluated in that frame, so it is written in terms of the
// locals shown there.
const condOf = (file, line) =>
  (marks.value.find(m => m.file === file && m.line === line) || {}).cond || '';
// Which breakpoint is being edited, as "file:line", or null. One at a time: the editor is a real
// CodeMirror and two of them competing for the completion popup is worse than a queue.
const condEdit = signal(null);

// Watches: where to sample, and what. Separate from marks even on the same line — one asks to be
// interrupted, the other asks to be shown a history, and you usually want both.
const watches = signal([]);
const traces = signal({});          // expr → the samples it has collected
const watchEdit = signal(null);     // "file:line" being edited, or "" for the new-watch row

// Stepping INTO a chosen call.
//
// A line usually makes several calls, and `into` on its own takes whichever the lowered code
// reaches first. So the server is asked what the line calls, and anything with a choice in it asks.
//
// `intoLib` is whether calls into code the session runs compiled are offered at all. Off by
// default, since stepping into `getindex` is usually an accident. It is a browser preference
// rather than session state: the server reports every target, and this picks which to show.
const intoTargets = signal(null);   // [{pc, name, mod, interpreted}] while the picker is open
const intoSkipped = signal(null);   // names Into passed over because they were library calls
const dbgErr = signal(null);        // a verb that failed, shown under the controls rather than swallowed
const intoLib = signal((() => { try { return localStorage.getItem('slateDbgIntoLib') === '1'; }
                                catch (_) { return false; } })());
function setIntoLib(v) {
  intoLib.value = !!v;
  try { localStorage.setItem('slateDbgIntoLib', v ? '1' : '0'); } catch (_) {}
}

// Live watches: a piece of the notebook re-evaluated at every stop. `spec` is either Julia text or
// `cell:<id>`. Each carries its own status, because "this does not evaluate here" is the ordinary
// condition of stepping rather than a failure — you walk into a frame where the name is not yet a
// thing. `cell` is the rendered output, and is dropped on any non-ok status so a stale picture is
// never left standing in for a current one.
const liveW = signal([]);                   // [spec]
const liveOut = signal({});                 // spec → {status, why, cell}
const liveOpen = signal(null);              // spec shown full size, or null
const liveAdd = signal(false);              // the "add a watch" editor is open

async function setLive(source, on) {
  try {
    const r = await A('POST', '/api/debug/live', on === undefined ? { source } : { source, on });
    if (r && r.live) liveW.value = r.live;
  } catch (e) {}
}
const dropLive = (spec) => setLive(spec, false);

async function setWatch(file, line, expr) {
  try {
    const r = await A('POST', '/api/debug/watch', { file, line, expr });
    if (r && r.watches) watches.value = r.watches;
  } catch (e) {}
}

// Fetched rather than pushed: a series is thousands of numbers and the state payload carries only
// a summary. Pulled when the run stops, which is when there is something new to look at.
async function loadTraces() {
  if (!watches.value.length) { traces.value = {}; return; }
  try {
    const r = await A('GET', '/api/debug/traces');
    if (r && r.ok) traces.value = r.traces || {};
  } catch (e) {}
}
// What a watch has seen so far. The frame carries a SUMMARY per expression (the series itself is
// thousands of numbers and is fetched separately, only when something wants to draw it).
const _traceOf = (w) => ((st.value && st.value.traces) || []).find(t => t.expr === w.expr) || null;
// Non-finite samples arrive as null — a watched value reaching NaN is most of why someone watches
// one — so a missing number is shown as such rather than as the string "null".
const _fmtN = (x) => (x === null || x === undefined ? '—'
  : Math.abs(x) >= 1e4 || (x !== 0 && Math.abs(x) < 1e-3) ? Number(x).toExponential(2)
  : String(Number(x.toFixed(4))));

const clearMark = (file, line) => setMark(file, line, false);
window.onBreakpointClick?.(toggleMark);

let _flashTimer = null;
function apply(next) {
  // Any move invalidates the pin: the stack has changed underneath it, so index 2 of the new one
  // is not the frame you were reading.
  selFrame.value = null;
  changed.value = diffNames(st.value, next);
  const prev = st.value ? st.value.cell : '';
  const had = !!(st.value && !st.value.finished);
  const s = (next && next.session === false) ? null : next;
  st.value = s;
  // A session appearing where there was none opens the workspace, whoever started it. An agent's
  // session arrives as a push and would otherwise run entirely off-screen — the whole reason to
  // watch one work is that you can see it. Only on the TRANSITION, so closing the view mid-session
  // stays closed and the next step does not drag it back open.
  if (!had && s && !s.finished && !s.error) focus.value = true;
  // The cell's own editor carries the "you are here" line, but only while the frame really is in
  // that cell. Stepping into a method defined elsewhere clears it rather than leaving the mark on a
  // line that is no longer the one running.
  const here = s && !s.finished && s.in_cell ? s.cell : '';
  if (prev && prev !== here) window.clearDebugLine?.(prev);
  if (s && s.cell && s.cell !== here) window.clearDebugLine?.(s.cell);
  if (here) window.markDebugLine?.(here, s.line);
  if (s && s.asks !== undefined) asks.value = s.asks || [];
  if (s && s.marks) paintMarks(s.marks);
  if (s && s.watches) watches.value = s.watches;
  if (s && s.live) liveW.value = s.live;
  s && !s.finished === false && loadTraces();
  syncGutter();
  window._slateRefreshCells?.();   // the header's 🐞 reflects whether this cell has the session
  if (_flashTimer) clearTimeout(_flashTimer);
  _flashTimer = setTimeout(() => { changed.value = new Set(); }, 900);
}

// ── verbs ─────────────────────────────────────────────────────────────────────────────────────────

// Start on a cell. The editor's CURRENT text is what runs: you step what you are looking at, not
// what was last saved — a debugger that made you save first would be a worse editor.
export async function startDebug(cellId) {
  if (busy.value) return;
  busy.value = true;
  try {
    const source = (window.edText && window.edText(cellId)) || '';
    const r = await A('POST', '/api/debug/start', { cell: cellId, source });
    // Straight into the workspace — `apply` opens it on the transition, for this start and for an
    // agent's alike. Stepping is involved enough that the cell is never where you want to be.
    apply(r);
    probes.value = [];
  } catch (e) { apply(null); } finally { busy.value = false; }
}
export async function step(mode) {
  if (busy.value || !live.value) return;
  intoSkipped.value = null;   // the note is about the step you just took, not the next one
  busy.value = true;
  try { apply(await A('POST', '/api/debug/step', { mode })); }
  catch (e) { apply(null); } finally { busy.value = false; }
}
// `into`, which asks first when the line gives it a choice.
//
// Straight in when there is exactly one candidate and it is the notebook's own code, since there
// is nothing to decide there. Several candidates ask which. A lone library call also asks, because
// entering one starts interpreting its whole module.
export async function stepInto() {
  if (busy.value || !live.value) return;
  busy.value = true;
  let ts = [];
  try {
    const r = await A('GET', '/api/debug/into-targets');
    ts = (r && r.targets) || [];
  } catch (e) {}
  busy.value = false;
  const shown = intoLib.value ? ts : ts.filter(t => t.interpreted);
  if (!shown.length) {
    // Everything this line calls is library code and the switch is off, so `into` is about to
    // behave exactly like `next`. Name the calls it passed over rather than appearing to do
    // nothing. Set after the step, because stepping clears it.
    await step('into');
    if (ts.length) intoSkipped.value = ts.map(t => t.name);
    return;
  }
  if (shown.length === 1 && shown[0].interpreted) return intoTarget(shown[0]);
  intoTargets.value = shown;
}

// Commit to one. A target the session runs compiled needs its module admitted first, which the
// `interpreting` strip then lists (and offers to drop again).
export async function intoTarget(t) {
  intoTargets.value = null;
  if (busy.value || !live.value || !t) return;
  busy.value = true;
  try { apply(await A('POST', '/api/debug/into',
                      { pc: t.pc, admit: t.interpreted ? '' : t.mod })); }
  catch (e) { apply(null); } finally { busy.value = false; }
}

// Hand a module back, so it runs compiled again. Every line steps while it is in the set, so a
// library admitted to answer one question slows the rest of the session if it stays.
export async function dropModule(name) {
  if (busy.value || !live.value) return;
  busy.value = true;
  dbgErr.value = null;
  try {
    const r = await A('POST', '/api/debug/interpret', { drop: name });
    if (r && r.error) dbgErr.value = String(r.error);
    else apply(r);
  } catch (e) {
    // A request that does not arrive is the one case worth naming: the route is registered at
    // startup, so a hub running older code answers 404 and the click looks like it did nothing.
    dbgErr.value = 'could not reach /api/debug/interpret (restart the hub if it was added since)';
  } finally { busy.value = false; }
}

// Turn off the breakpoint under the cursor, then carry on. A breakpoint inside a loop fires on
// every iteration, and this is how to leave one. The mark stays set, hollow, with its predicate.
export async function skipHere() {
  const s = st.value;
  if (busy.value || !live.value || !s || !s.file) return;
  await setMark(s.file, s.line, undefined, undefined, false);
  await step('continue');
}
export async function stopDebug() {
  const cell = debugCell.value;
  busy.value = true;
  try { await A('POST', '/api/debug/stop', {}); } catch (e) {}
  busy.value = false;
  focus.value = false;
  apply(null);
  if (cell) window.clearDebugLine && window.clearDebugLine(cell);
}
// Runs the probe and says nothing about the result: the server broadcasts every evaluation, and
// this page receives that broadcast like any other. Appending here TOO listed each probe twice —
// the same trap the state panes avoid by rendering what they are told rather than what they asked
// for. An evaluation that fails to reach the server is reported here, because no push will come.
async function probe(expr) {
  if (!expr.trim() || !live.value) return;
  try {
    await A('POST', '/api/debug/eval', { expr });
  } catch (e) {
    probes.value = [...probes.value, { expr, ok: false, repr: '', type: '', error: 'request failed' }];
  }
}

// ── the specialist ────────────────────────────────────────────────────────────────────────────────
// Summoned from inside the session you are already in. It works in the chat pane — reasoning and
// every tool call streaming as it goes — so the pane opens with it.
const models = signal(null);     // ACP backends, loaded on first open of the picker
const summoning = signal(false);
const pickerOpen = signal(false);
const specialist = signal(null); // {agent_id, cell, model} once one is here

async function loadModels() {
  if (models.value) return;
  try {
    const r = await A('GET', '/api/acp-models');
    models.value = (r && r.models) || [];
  } catch (e) { models.value = []; }
}

async function summon(model) {
  const s = st.value;
  if (!s || summoning.value) return;
  summoning.value = true; pickerOpen.value = false;
  try {
    const r = await A('POST', '/api/debug/agent', { cell: s.cell, model: model || '' });
    if (r && r.ok) {
      specialist.value = { agent_id: r.agent_id, cell: r.cell, model: model || '' };
      focus.value = true;   // the debugging workspace is where it works — and where you watch it
    }
  } catch (e) {} finally { summoning.value = false; }
}

// The picker. An ACP agent can reach ~70 models, which is a list you search, not one you scroll —
// so it opens on a filter box, and the last model you used is offered first because in practice
// you summon the same one over and over.
const filter = signal('');
const lastModel = () => { try { return localStorage.getItem('slateDbgModel') || ''; } catch (_) { return ''; } };

// The bare model name: `acp:opencode:opencode/claude-sonnet-5` → `claude-sonnet-5`.
const bareModel = (m) => String(m).replace(/^acp:\w+:/, '').replace(/^.*\//, '');
// Its family — the first hyphen-segment with any version digits stripped, so `claude-sonnet-5`,
// `gpt-5.4-mini` and `qwen3.6-plus` land under claude / gpt / qwen. Cheap and wrong for nothing in
// the current list; a name it can't parse simply becomes its own group rather than being hidden.
const familyOf = (m) => (bareModel(m).split('-')[0].replace(/[\d.]+$/, '') || 'other').toLowerCase();

// Grouped, each family's own models in the order the server gave them (newest last there, so
// reversed here — you almost always want the newest of a family).
function byFamily(list) {
  const g = new Map();
  for (const m of list) {
    const f = familyOf(m);
    if (!g.has(f)) g.set(f, []);
    g.get(f).push(m);
  }
  return [...g.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
}

function Summon() {
  const s = st.value;
  if (!s || s.finished) return null;
  if (specialist.value) {
    return html`<button class="dbgspec on" title="a debugging specialist is working on this — open the workspace"
      onClick=${() => focus.value = true}>🐞 specialist</button>`;
  }
  const pick = (m) => { try { localStorage.setItem('slateDbgModel', m); } catch (_) {} summon(m); };
  const q = filter.value.trim().toLowerCase();
  const all = models.value || [];
  const shown = q ? all.filter(m => m.toLowerCase().includes(q)) : all;
  const prev = lastModel();
  const open = () => {
    pickerOpen.value = !pickerOpen.value;
    filter.value = '';
    loadModels();
  };
  return html`<span class="dbgspecwrap">
    <button class="dbgspec" disabled=${summoning.value}
      title="bring in a debugging specialist to work on this cell with you"
      onClick=${open}>${summoning.value ? 'summoning…' : '＋ specialist'}</button>
    ${pickerOpen.value ? html`<div class="dbgspecmenu">
      <input class="dbgspecfind" autofocus placeholder="search models…" value=${filter.value}
        onInput=${e => filter.value = e.target.value}
        onKeyDown=${e => {
          if (e.key === 'Escape') { pickerOpen.value = false; }
          // Enter takes the top of the list, which is what the search narrowed it to.
          else if (e.key === 'Enter' && shown.length) pick(shown[0]);
        }} />
      <div class="dbgspeclist">
        ${!q && prev ? html`<div class="dbgspecrow recent" onClick=${() => pick(prev)}>
            <span class="dbgspecmark">↩</span>${bareModel(prev)}</div>` : null}
        ${!q ? html`<div class="dbgspecrow" onClick=${() => pick('')}>
            <span class="dbgspecmark">·</span>Default model</div>` : null}
        ${models.value === null ? html`<div class="dbgspecnote">loading…</div>`
          : !all.length ? html`<div class="dbgspecnote">no ACP agents installed</div>`
          : !shown.length ? html`<div class="dbgspecnote">nothing matches “${filter.value}”</div>`
          // Searching already narrows, so a query renders flat; browsing renders by family.
          : q ? shown.map(m => html`<div class="dbgspecrow" key=${m} onClick=${() => pick(m)}>
                  ${bareModel(m)}</div>`)
          : byFamily(shown).map(([fam, ms]) => html`<div class="dbgspecgrp" key=${fam}>
              <div class="dbgspechead">${fam}<span class="dbgspecn">${ms.length}</span></div>
              ${ms.map(m => html`<div class="dbgspecrow" key=${m} onClick=${() => pick(m)}>
                  ${bareModel(m)}</div>`)}
            </div>`)}
      </div>
      ${all.length ? html`<div class="dbgspecfoot">${shown.length} of ${all.length}</div>` : null}
    </div>` : null}
  </span>`;
}

// ── the specialist's transcript ────────────────────────────────────────────────────────────────
// Its own, not the chat panel's. A debugging transcript wants different things on screen: a step
// is one line saying where it landed, not a JSON blob; an evaluation is the expression and its
// answer; and the whole thing sits beside the frame it is talking about.
const convo = signal([]);   // [{role:'said'|'think'|'act'|'brief'|'you', text, verb, detail, done}]
const working = signal(false);
// The standing instructions and toolset, which go in at spawn and never appear on the event bus.
const brief = signal(null);
const briefOpen = signal(false);
async function loadBrief() {
  briefOpen.value = !briefOpen.value;
  if (brief.value || !briefOpen.value) return;
  try { brief.value = await A('GET', '/api/debug/brief'); } catch (e) { brief.value = { system: '(unavailable)' }; }
}

// A tool call, named the way a debugger session reads. Everything the specialist can call is one
// of seven verbs, so the row is the verb plus what came back — not the tool name and its arguments.
const VERB = {
  dbg_start: 'start', dbg_step: 'step', dbg_frame: 'frame', dbg_eval: 'eval',
  dbg_break: 'breakpoint', dbg_ask: 'ask', dbg_done: 'done',
};
const verbOf = (title) => {
  const t = String(title || '').replace(/^.*?(dbg_\w+).*$/, '$1');
  return VERB[t] || null;
};
// The one line worth keeping from a result: where it stopped, or what the answer was.
function gist(verb, text) {
  const s = String(text || '').trim();
  if (!s) return '';
  if (verb === 'eval') return s.split('\n')[0].slice(0, 160);
  const stop = s.match(/^[⏸✅⛔].*$/m);
  if (stop) return stop[0].replace(/^⏸\s*/, '').slice(0, 160);
  return s.split('\n')[0].slice(0, 160);
}

window.onDebugAgentEvent = (env) => {
  // Exactly this role, not a name containing it. The server stamps `crew` with the specialist's
  // registered name verbatim (relay_agent_event), so a substring test would quietly pull a second
  // role's events into this transcript once one is registered whose name contains this one.
  if (!env || env.crew !== DEBUG_ROLE) return;
  const d = env.data || {}, k = env.kind;
  // Anything arriving from it means a turn is in flight. Keying the spinner on `turn_started`
  // alone left the pane looking idle whenever a backend doesn't send one — rows appeared
  // underneath with nothing saying the specialist was still going.
  if (k !== 'result' && k !== 'turn_ended') working.value = true;
  const list = convo.value.slice();
  // What it was TOLD, shown alongside what it said. The opening brief arrives this way, and
  // dropping it left the transcript starting at the specialist's first move with no sign of the
  // question it was answering — you cannot judge the answer without seeing the brief.
  if (k === 'user_text') {
    const txt = (d.content && d.content.text) || d.text || '';
    if (txt && !list.some(m => m.role === 'brief' && m.text === txt)) {
      list.push({ role: 'brief', text: txt, done: true });
      convo.value = list;
    }
    return;
  }
  if (k === 'assistant_text' || k === 'thought' || k === 'assistant') {
    const role = k === 'thought' ? 'think' : 'said';
    const txt = (d.content && d.content.text) || d.text || '';
    const last = list[list.length - 1];
    if (d.delta === true) {
      if (!txt) return;
      if (last && last.role === role && !last.done) last.text += txt;
      else list.push({ role, text: txt, done: false });
    } else if (last && last.role === role && !last.done) {
      last.text = txt || last.text; last.done = true;
    } else if (txt) list.push({ role, text: txt, done: true });
  } else if (k === 'tool_use') {
    const c = d.call || {};
    const verb = verbOf(c.title || c.kind);
    if (!verb) return;                       // a refused tool shows up as its result, not a row
    if (!list.some(m => m.id === c.toolCallId)) {
      const inp = c.rawInput || {};
      list.push({ role: 'act', id: c.toolCallId, verb,
                  arg: inp.mode || inp.expr || inp.cell || (inp.file ? inp.file + ':' + inp.line : ''),
                  detail: '', done: false });
    }
  } else if (k === 'tool_result') {
    const u = d.update || {};
    const m = list.find(x => x.id === u.toolCallId);
    if (!m) return;
    const c = ((u.content || [])[0] || {}).content || {};
    m.detail = gist(m.verb, c.text);
    m.failed = String(u.status || '') === 'failed';
    m.done = true;
  } else if (k === 'turn_started') working.value = true;
  else if (k === 'result' || k === 'turn_ended') {
    working.value = false;
    convo.value = list;
    // Anything you typed while it worked goes in now, before it takes its next step.
    setTimeout(flushQueue, 0);
    return;
  }
  convo.value = list;
};

// Clearing the transcript is a VIEW action, not `chat-clear` — that reaps every agent and wipes
// the notebook's whole conversation, which would kill the specialist mid-thought. So the pane
// empties and a watermark records how much of the server's log has been read, which is what makes
// the clear survive a reload without destroying anything.
const _wmKey = () => 'slateDbgSeen:' + (window.NB_ID || '');
const seenMark = () => { const n = parseInt(localStorage.getItem(_wmKey()), 10); return isFinite(n) ? n : 0; };

async function clearConvo() {
  convo.value = [];
  try {
    const log = await A('GET', '/api/agent-log');
    localStorage.setItem(_wmKey(), String(((log && log.events) || []).length));
  } catch (e) {}
}

// Talking to it WHILE it works.
//
// A turn cannot take a second message: the backend fires another `session/prompt` on the same ACP
// session and clears the buffer the running turn is accumulating into, so the reply you were
// reading is destroyed. So a message sent mid-turn is HELD and delivered when the turn ends — it
// still reaches the specialist before its next move, which is what you wanted it for. If you need
// it to stop and read you now, interrupt: that ends the turn and the queue flushes into the gap.
const queued = signal([]);

async function deliver(text) {
  try { await A('POST', '/api/chat', { text, crew: DEBUG_ROLE }); }
  catch (e) { working.value = false; }
}

function sayToSpecialist(text) {
  if (!text.trim()) return;
  convo.value = [...convo.value, { role: 'you', text, done: true, held: working.value }];
  if (working.value) { queued.value = [...queued.value, text]; return; }
  working.value = true;
  deliver(text);
}

// Flush on the turn boundary, joined into ONE turn — several notes typed while it worked are one
// piece of context, not a queue of interruptions to answer in order.
function flushQueue() {
  const q = queued.value;
  if (!q.length) return false;
  queued.value = [];
  convo.value = convo.value.map(m => (m.held ? { ...m, held: false } : m));
  working.value = true;
  deliver(q.join('\n\n'));
  return true;
}

async function interruptSpecialist() {
  try { await A('POST', '/api/chat-interrupt', {}); } catch (e) {}
  working.value = false;
  setTimeout(flushQueue, 300);   // let the turn-ended event land before the next turn opens
}

async function answerAsk(id, text) {
  try {
    const r = await A('POST', '/api/debug/answer', { id, text });
    asks.value = (r && r.asks) || [];
  } catch (e) {}
}

// ── live push ─────────────────────────────────────────────────────────────────────────────────────
// Every verb the server runs is broadcast, whoever ran it. That is what makes an agent's session
// watchable: the strip and the focus view are reading the session, not their own last click.
// Specialist-framework events arrive on their own channel and name the role they belong to, so a
// second kind of specialist gets its own pane without either surface knowing about the other.
(window.slateSpecialistSubs ||= []).push((p) => {
  if (!p || p.role !== DEBUG_ROLE) return;
  if (p.asks !== undefined) asks.value = p.asks || [];
  if (p.ask) asks.value = [...asks.value.filter(a => a.id !== p.ask.id), p.ask];
  if (p.specialist) specialist.value = p.specialist;
});

window.onDebugPush = (p) => {
  if (!p) return;
  if (p.probe) {
    const v = p.probe;
    probes.value = [...probes.value, {
      expr: v.expr || '', ok: !!v.ok, repr: v.value ? v.value.repr : '',
      type: v.value ? v.value.type : '', error: v.error,
    }];
    return;
  }
    if (p.session === false) { specialist.value = null; apply(null); paintMarks(p.marks || []); syncGutter(); return; }
  if (p.livecell) {
    const d = p.livecell;
    liveOut.value = { ...liveOut.value, [d.spec]: { status: d.status, why: d.why, cell: d.cell } };
    return;
  }
  if (p.live !== undefined && p.cell === undefined) { liveW.value = p.live; return; }
  if (p.marks !== undefined && p.cell === undefined) { paintMarks(p.marks); syncGutter(); return; }
  if (p.cell !== undefined) apply(p);
};

// A page that reloads mid-session picks the session back up rather than orphaning it in the worker.
(async function resume() {
  try {
    // The specialist and its transcript outlive a reload: both live on the server, so replay them
    // rather than showing an empty pane beside a session that is plainly still going.
    const log = await A('GET', '/api/agent-log');
    const aid = (log && log.agents && log.agents.debugger) || '';
    if (aid) specialist.value = { agent_id: aid, cell: '', model: '' };
    const events = (log && log.events) || [];
    // Skip what was cleared. The server's log is capped and pops from the front, so a watermark
    // past the end means it has rotated — treat that as nothing to skip rather than showing blank.
    const skip = seenMark() <= events.length ? seenMark() : 0;
    for (const line of events.slice(skip)) {
      try { window.onDebugAgentEvent(JSON.parse(line)); } catch (e) {}
    }
    working.value = false;   // a turn that was live when the page went away is not live now
  } catch (e) {}
  try {
    const r = await A('GET', '/api/debug/frame');
    if (r && r.session) return apply(r);
    const m = await A('GET', '/api/debug/marks');   // no session, but the breakpoints outlive one
    paintMarks(m && m.marks);
    syncGutter();
  } catch (e) {}
})();

// ── shared bits ───────────────────────────────────────────────────────────────────────────────────

const shortFile = f => {
  if (!f) return '';
  if (f.indexOf('cell:') === 0) return 'cell ' + f.slice(5);
  const p = f.split('/');
  return p.length > 2 ? p.slice(-2).join('/') : f;
};

// Where this is happening — never implied by the notebook, which can be stepping code on a compute
// node while the rest of it runs locally.
function Locus({ s, big }) {
  if (!s) return null;
  const remote = !!s.side;
  return html`<span class=${'dbgloc' + (remote ? ' remote' : '') + (big ? ' big' : '')}
    title=${remote ? 'the frame lives on ' + s.where : 'this notebook’s own kernel'}>
    ${remote ? '\u{1F5A7} ' : '\u{1F4BB} '}${remote ? s.where : 'local'}</span>`;
}

// One value: name, what it is, and a clipped repr. Never the value itself — see the file header.
// A binding the session hasn't reached yet still HOLDS last run's value; shown dimmed and labelled
// so it can't be read as the answer this session produced.
function Val({ v, flash }) {
  const unset = !v.type;
  const stale = !unset && v.fresh === false;
  return html`<div class=${'dbgval' + (flash ? ' chg' : '') + (unset ? ' unset' : '') + (stale ? ' stale' : '')}
    title=${stale ? 'from the previous run — this line has not run yet in this session' : ''}>
    <span class="dbgvn">${v.name}</span>
    <span class="dbgvt" title=${v.type}>${unset ? '—' : v.type}${v.size ? ' ' + v.size : ''}</span>
    <span class="dbgvr" title=${v.repr}>${unset ? 'not assigned yet' : v.repr}</span>
  </div>`;
}

function Vals({ title, items, hint }) {
  if (!items || !items.length) return null;
  const ch = changed.value;
  return html`<div class="dbgvals">
    <div class="dbgvhead" title=${hint || ''}>${title}<span class="dbgvn-count">${items.length}</span></div>
    ${items.map(v => html`<${Val} key=${v.name} v=${v} flash=${ch.has(v.name)} />`)}
  </div>`;
}

// A watched expression is a series, not a reading: `n` samples taken as the run went on, and what
// makes it worth having is the shape. So it is drawn, in its own strip.
//
// The series is already fetched (`loadTraces`) and was never drawn anywhere, which left a sampled
// watch showing a single number — the one thing a series is least useful reduced to.
function Spark({ xs }) {
  if (!xs || xs.length < 2) return null;
  const pts = xs.filter(v => v !== null && v !== undefined && isFinite(v));
  if (pts.length < 2) return null;
  const lo = Math.min(...pts), hi = Math.max(...pts);
  if (hi === lo) return null;          // a flat line says less than the words beside it
  const span = hi - lo;
  const W = 132, H = 26;
  // Non-finite samples break the line rather than being drawn as zero: a gap is what happened.
  let d = '', pen = false;
  xs.forEach((v, i) => {
    const x = (i / (xs.length - 1)) * W;
    if (v === null || v === undefined || !isFinite(v)) { pen = false; return; }
    const y = H - ((v - lo) / span) * H;
    d += (pen ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1) + ' ';
    pen = true;
  });
  return html`<svg class="dbgspark" viewBox=${'0 0 ' + W + ' ' + H} preserveAspectRatio="none">
    <path d=${d.trim()} fill="none" stroke="currentColor" stroke-width="1.2" />
  </svg>`;
}

// Which watch is opened out, as "file:line", or null. Click rather than hover: the plot is worth
// studying across several steps, and a hover panel goes away the moment you reach for Next.
const watchOpen = signal(null);

// The series against evaluation count. Bigger than the row it came from, with the bounds labelled,
// because the question a watch answers is what the value has been DOING.
function WatchPlot({ xs, t }) {
  const W = 300, H = 120, PAD = 4;
  const fin = xs.filter(v => v !== null && v !== undefined && isFinite(v));
  if (fin.length < 2) return html`<div class="dbgwpempty">not enough samples to plot yet</div>`;
  const lo = Math.min(...fin), hi = Math.max(...fin);
  const span = (hi - lo) || 1;
  const y = v => PAD + (1 - (v - lo) / span) * (H - 2 * PAD);
  let d = '', pen = false, gaps = 0;
  xs.forEach((v, i) => {
    const x = (i / (xs.length - 1)) * W;
    if (v === null || v === undefined || !isFinite(v)) { pen = false; gaps++; return; }
    d += (pen ? 'L' : 'M') + x.toFixed(1) + ' ' + y(v).toFixed(1) + ' ';
    pen = true;
  });
  return html`<div class="dbgwplot">
    <svg viewBox=${'0 0 ' + W + ' ' + H} preserveAspectRatio="none">
      <line x1="0" y1=${y(hi)} x2=${W} y2=${y(hi)} class="dbgwpgrid" />
      <line x1="0" y1=${y(lo)} x2=${W} y2=${y(lo)} class="dbgwpgrid" />
      ${lo < 0 && hi > 0 ? html`<line x1="0" y1=${y(0)} x2=${W} y2=${y(0)} class="dbgwpzero" />` : null}
      <path d=${d.trim()} fill="none" stroke="currentColor" stroke-width="1.4" />
    </svg>
    <div class="dbgwpax"><span>${_fmtN(hi)}</span><span>${_fmtN(lo)}</span></div>
    <div class="dbgwpfoot">
      ${xs.length} evaluations${gaps ? ' · ' + gaps + ' non-finite' : ''}
      <span class="dbgsp"></span>now ${_fmtN(t ? t.last : fin[fin.length - 1])}
    </div>
  </div>`;
}

function WatchStrip({ s }) {
  const ws = watches.value;
  const here = s && s.line ? s.file + ':' + s.line : '';
  return html`<div class="dbgrhead dbgrhead2" title="sampled every time that line runs, without stopping">
      watches
      ${here ? html`<button class="dbgwadd" title=${'sample an expression every time line ' + s.line + ' runs'}
        onClick=${() => watchEdit.value = here}>+</button>` : null}
    </div>
    <div class="dbgwatches">
      ${!ws.length && watchEdit.value === null
        ? html`<div class="dbgwempty">none</div>` : null}
      ${ws.map(w => { const key = w.file + ':' + w.line, t = _traceOf(w), xs = traces.value[w.expr] || [];
        const n = t ? t.n : 0;
        const open = watchOpen.value === key;
        return html`<div class=${'dbgwatch' + (open ? ' open' : '')} key=${key}>
          <div class="dbgwtop" title=${n > 1 ? 'show what it has been' : w.expr}
               onClick=${() => watchOpen.value = open ? null : key}>
            <span class="dbgwx">${w.expr}</span>
            ${n > 0 ? html`<span class="dbgwnow">${_fmtN(t.last)}</span>` : null}
            <button class="dbgwrm" title="stop sampling"
              onClick=${e => { e.stopPropagation(); setWatch(w.file, w.line, ''); }}>✕</button>
          </div>
          ${n === 0 ? (t && t.hits > 0
            // The line has run and kept nothing. A trace is a curve, so a value that is not a
            // number is counted and dropped. Reporting that as "waiting" reads as a line the run
            // has not reached.
            ? html`<div class="dbgwrange nonum" title=${'sampled ' + t.hits + ' time(s); a watch plots numbers'}>
                ${t.type || 'not a number'} · ${t.hits}× not plotted</div>`
            : html`<div class="dbgwrange" title=${w.file}>
                waiting for ${shortFile(w.file)}:${w.line}</div>`) : null}
          ${open ? html`<${WatchPlot} xs=${xs} t=${t} />` : null}
        </div>`; })}
      ${watchEdit.value !== null
        ? html`<${CondEditor} file="" line=${0} initial="" label=""
                 onDone=${t => { const at = watchEdit.value; watchEdit.value = null;
                                 if (t === null || !t.trim() || !at) return;
                                 const i = at.lastIndexOf(':');
                                 setWatch(at.slice(0, i), Number(at.slice(i + 1)), t.trim()); }} />`
        : null}
    </div>`;
}

// The step controls. One row, in the order you reach for them, with Stop set apart so it is never
// the button you hit while stepping quickly.
function Controls({ compact }) {
  const d = busy.value || !live.value;
  const B = (mode, glyph, label, tip) => html`<button class=${'dbgb dbgb-' + mode} disabled=${d}
    title=${tip} onClick=${() => step(mode)}><span class="dbgbg">${glyph}</span>${compact ? null : html`<span>${label}</span>`}</button>`;
  return html`<div class="dbgctl">
    ${B('next', '⤷', 'Next', 'F10')}
    <button class="dbgb dbgb-into" disabled=${d} title="F11 — asks which call when the line makes more than one"
      onClick=${stepInto}><span class="dbgbg">⤓</span>${compact ? null : html`<span>Into</span>`}</button>
    ${B('out', '⤒', 'Out', '⇧F11')}
    ${B('continue', '▶▶', 'Continue', 'F5')}
    ${st.value && st.value.at_breakpoint
      ? html`<button class="dbgb dbgb-past" disabled=${d}
          title="turn this breakpoint off and carry on. It stays set, hollow, and you can turn it back on"
          onClick=${skipHere}><span class="dbgbg">▶|</span>${compact ? null : html`<span>Skip</span>`}</button>`
      : null}
    <span class="dbgsp"></span>
    <button class="dbgb dbgb-stop" disabled=${busy.value} title="⇧F5"
      onClick=${stopDebug}><span class="dbgbg">■</span>${compact ? null : html`<span>Stop</span>`}</button>
  </div>
  ${dbgErr.value ? html`<div class="dbgskipnote err">
    ${dbgErr.value}
    <button class="dbgskipx" title="dismiss" onClick=${() => dbgErr.value = null}>✕</button>
  </div>` : null}
  ${intoSkipped.value ? html`<div class="dbgskipnote">
    Into passed over ${intoSkipped.value.join(', ')} — library code, which this session runs compiled.
    <button class="dbgskipgo" onClick=${() => { setIntoLib(true); intoSkipped.value = null; stepInto(); }}>
      step inside anyway</button>
    <button class="dbgskipx" title="dismiss" onClick=${() => intoSkipped.value = null}>✕</button>
  </div>` : null}`;
}

// Who is driving. Absent for your own session — the common case shouldn't carry a label.
function Owner({ s }) {
  if (!s || !s.owner || s.owner === 'human') return null;
  return html`<span class="dbgowner" title="an agent is driving this session — your controls still work">
    ⌁ ${s.owner.replace(/^agent:/, '')}</span>`;
}

// An agent waiting on an answer. Its turn is stopped here, so this is a blocking prompt, not a
// notice: consent gets two buttons, a question gets a box.
//
// Rendered INSIDE the specialist pane, with the rest of its voice. It used to be a band across
// the whole workspace, which put agent prose in two places at once — the band and the transcript
// — and read as two different conversations happening about the same thing.
function Asks() {
  // This specialist's questions only. `asks_json` is per notebook and unfiltered, and the frame
  // carries it wholesale — so without this, a question the notebook's own agent asked (a plan to
  // approve, a request for file access) rendered here AND in the chat, which is the two-places
  // problem the note above describes, reintroduced by a different route.
  const list = asks.value.filter(a => a.role === DEBUG_ROLE);
  if (!list.length) return null;
  return html`<div class="dbgasks">${list.map(a => html`<div class=${'dbgask ' + a.kind} key=${a.id}>
    <div class="dbgaskq">${a.text}</div>
    ${a.kind === 'consent'
      ? html`<div class="dbgaskbtns">
          <button class="dbgb" onClick=${() => answerAsk(a.id, 'yes')}>Allow</button>
          <button class="dbgb dbgb-stop" onClick=${() => answerAsk(a.id, 'no')}>Keep it</button></div>`
      : a.kind === 'choice' && (a.options || []).length
      /* Buttons, not a text box: whoever asked has already worked out the alternatives, and making
         someone retype one of them is slower and invites a typo nobody notices until the call
         using it fails. The LABEL is what you read, the VALUE is what the asker gets back. */
      ? html`<div class="dbgaskopts">
          ${a.options.map(o => html`<button class="dbgopt" key=${o.value} title=${o.value}
              onClick=${() => answerAsk(a.id, o.value)}>${o.label}</button>`)}
          <button class="dbgopt skip" title="answer in your own words instead"
              onClick=${() => answerAsk(a.id, '')}>none of these</button></div>`
      : html`<form class="dbgpform" onSubmit=${e => { e.preventDefault(); const el = e.target.querySelector('input');
               const v = el.value; el.value = ''; answerAsk(a.id, v); }}>
          <span class="dbgpp">›</span><input autocomplete="off" autofocus placeholder="answer…" /></form>`}
  </div>`)}</div>`;
}

// ── the cell strip ────────────────────────────────────────────────────────────────────────────────

export function DebugStrip({ cell }) {
  const s = st.value;
  if (!s || s.cell !== cell.id) return null;
  // A clean finish leaves nothing to say: the cell ran, and it renders its own output right below.
  // Only an ERROR earns a banner, because that is the one outcome the cell will not show you.
  // After the render, not during it: `stopDebug` writes the signal this component is reading.
  if (s.finished && !s.error) { queueMicrotask(stopDebug); return null; }
  if (s.finished) {
    return html`<div class="dbgstrip done"><div class="dbgbar">
      <span class="dbgdone err">⚠ ${s.error}</span>
      <span class="dbgsp"></span>
      <button class="dbgb dbgb-stop" onClick=${stopDebug}><span class="dbgbg">✕</span><span>Close</span></button>
    </div></div>`;
  }
  // A ribbon, not a control surface. A column the width of a cell cannot hold a stack, a source
  // pane, forty locals and a specialist — trying made all four bad. The cell keeps the one thing
  // only it can show (the gold line in its own editor) and a line saying where the session is;
  // everything else is the workspace, one click away.
  return html`<div class=${'dbgstrip' + (s.side ? ' remote' : '')}>
    <div class="dbgbar open" title="open the debugging workspace" onClick=${() => focus.value = true}>
      <span class="dbgribbon">▸ debugging</span>
      ${s.at_breakpoint ? html`<span class="dbgbp" title="stopped at a breakpoint">●</span>` : null}
      <span class="dbgscope">${s.scope}</span>
      <span class="dbgfile" title=${s.file}>${shortFile(s.file)}${s.line ? ':' + s.line : ''}</span>
      <span class="dbgsp"></span>
      <span class="dbgsteps">${s.steps} ${s.steps === 1 ? 'step' : 'steps'}</span>
      <${Owner} s=${s} />
      <${Locus} s=${s} />
      <button class="dbgexp" title="open the debugging workspace"
        onClick=${e => { e.stopPropagation(); focus.value = true; }}>⤢</button>
      <button class="dbgexp" title="end the session"
        onClick=${e => { e.stopPropagation(); stopDebug(); }}>■</button>
    </div>
    ${/* The specialist's, not every ask on the notebook — this badge sends you to the workspace,
          which is the wrong place to answer a question the notebook's own agent asked in chat. */''}
    ${asks.value.some(a => a.role === DEBUG_ROLE) ? html`<div class="dbgaskbadge" onClick=${() => focus.value = true}>
      ❓ the specialist is waiting on you — open the workspace to answer</div>` : null}
  </div>`;
}

// ── the focus view ────────────────────────────────────────────────────────────────────────────────

// A read-only CodeMirror showing the frame's source, with the gutter re-based so its numbers read
// as the file's. The text comes from the kernel (server_debug.jl fills in a cell's own source):
// `file` is a path on that machine, and reading it here would show a different file, or none.
// The frame the source pane is showing: the selected caller, or the current frame. A caller's
// text is already in `s.sources` — every frame ships its own, indexed by `frame.src` — so this
// costs a lookup rather than a round trip.
function shownFrame(s) {
  const st = s.stack || [], sel = selFrame.value;
  if (sel === null || sel < 0 || sel >= st.length) {
    return { file: s.file, scope: s.scope, line: s.line, source: s.source,
             srcfirst: s.srcfirst, caller: false };
  }
  const f = st[sel], src = (s.sources || [])[f.src - 1];
  return { file: f.file, scope: f.scope, line: f.line,
           source: src ? src.text : '', srcfirst: src ? src.first : 1, caller: true };
}

function Source({ s: raw }) {
  const s = shownFrame(raw);
  const host = useRef(null), vw = useRef(null), file = useRef(s.file);
  file.current = s.file;   // the click handler is installed once; read the CURRENT file from a ref
  useEffect(() => {
    if (!host.current || !window.slateSourceViewer) return;
    vw.current = window.slateSourceViewer(host.current, {
      onToggleLine: (absLine) => setMark(file.current, absLine),
    });
    return () => { try { vw.current && vw.current.destroy(); } catch (e) {} vw.current = null; };
  }, []);
  useEffect(() => {
    const v = vw.current; if (!v) return;
    v.setDoc(s.source || '', s.srcfirst || 1);
    if (s.line) v.setLine(s.line);
  }, [s.source, s.srcfirst, s.line]);
  // Repaint whenever the marks change OR the frame moves to another file — the armed lines shown
  // are only the ones belonging to the source on screen.
  useEffect(() => {
    const v = vw.current; if (!v) return;
    v.setMarks(marks.value.filter(m => m.file === s.file)
                          .map(m => ({ line: m.line, enabled: m.enabled !== false })));
  }, [marks.value, s.file, s.source]);
  return html`<div class=${'dbgsrc' + (s.caller ? ' caller' : '')}>
    <div class="dbgsrchead"><span class="dbgfile" title=${s.file}>${shortFile(s.file)}</span>
      <span class="dbgscope">${s.scope}</span>
      ${s.caller ? html`<button class="dbgback" onClick=${() => selFrame.value = null}
          title="back to the frame execution is stopped in">▸ back to current</button>` : null}
      <span class="dbgsp"></span>
      ${s.source && !marks.value.length
        ? html`<span class="dbgsrchint">click the margin to set a breakpoint</span>` : null}
      ${s.source ? null : html`<span class="dbgnosrc">no source</span>`}</div>
    <div class="dbgsrcbody" ref=${host}></div>
  </div>`;
}

// The call stack, outermost last — the frame you are in sits at the top, where the eye starts.
function Stack({ s }) {
  const fr = [...(s.stack || [])].reverse();
  return html`<div class="dbgrail">
    <div class="dbgrhead">call stack</div>
    <div class="dbgstack">${fr.map((f, i) => {
      const idx = (s.stack || []).length - 1 - i;          // `fr` is reversed for display
      const sel = selFrame.value === idx || (selFrame.value === null && i === 0);
      return html`<div class=${'dbgfr' + (i === 0 ? ' cur' : '') + (sel ? ' sel' : '')} key=${i}
        title="show this frame's source"
        onClick=${() => selFrame.value = (i === 0 ? null : idx)}>
      <div><span class="dbgfrm">${i === 0 ? '▸' : '·'}</span> <span class="dbgscope">${f.scope}</span></div>
      <span class="dbgfile" title=${f.file}>${shortFile(f.file)}:${f.line}</span>
    </div>`; })}</div>
    ${marks.value.length ? html`<div class="dbgrhead dbgrhead2">breakpoints</div>
      <div class="dbgmarks">${marks.value.map(m => html`<div
          class=${'dbgmark' + (m.enabled === false ? ' off' : '')} key=${m.file + ':' + m.line}>
        <button class="dbgmarko" title=${m.enabled === false ? 'set but disabled: turn it back on' : 'disable without clearing'}
                onClick=${() => setMark(m.file, m.line, undefined, undefined, m.enabled === false)}
        >${m.enabled === false ? '○' : '●'}</button>
        <span class="dbgfile" title=${m.file}>${shortFile(m.file)}:${m.line}</span>
        <button class=${'dbgmarkc' + (m.cond ? ' on' : '')}
                title=${m.cond ? 'stops only when: ' + m.cond : 'stop only when an expression holds'}
                onClick=${() => condEdit.value = m.file + ':' + m.line}>${m.cond ? 'when' : '+when'}</button>
        <button class="dbgmarkx" title="clear" onClick=${() => clearMark(m.file, m.line)}>✕</button>
      </div>
      ${condEdit.value === m.file + ':' + m.line
        ? html`<${CondEditor} file=${m.file} line=${m.line} initial=${m.cond || ''}
                 onDone=${t => { condEdit.value = null;
                                 t === null || setMark(m.file, m.line, undefined, t); }} />`
        : (m.cond ? html`<div class="dbgcond" title=${m.cond}
                          onClick=${() => condEdit.value = m.file + ':' + m.line}>${m.cond}</div>` : null)}`)}</div>` : null}
    <${WatchStrip} s=${s} />
    <div class="dbgrhead dbgrhead2" title="modules stepped rather than run compiled">interpreting</div>
    <div class="dbginterp">${(s.interpreting || []).map(m => {
      // The cell's namespace is the code being stepped, so it is the one chip that cannot go.
      const fixed = m === s.ns;
      return html`<span class=${'dbgmod' + (fixed ? '' : ' drop')} key=${m}
        title=${fixed ? 'the namespace the cell runs in' : 'stop interpreting ' + m + ', so it runs compiled again'}>
        ${m}${fixed ? null : html`<button class="dbgmodx" onClick=${() => dropModule(m)}>✕</button>`}</span>`;
    })}</div>
    <${LibSwitch} />
  </div>`;
}

// Evaluate in the paused frame. The frame's locals are bound first, so a probe sees exactly what
// the code sees at that line — including on a machine you have no REPL on.
// A REPL's worth of history, because a debugging probe is usually the previous one with one
// thing changed. ↑/↓ walk it when the caret is on the first/last line, so a multi-line expression
// still navigates normally.
const hist = [];
let histAt = 0;

function Scratch({ s }) {
  const host = useRef(null), view = useRef(null), logRef = useRef(null);

  const run = () => {
    const v = view.current; if (!v) return true;
    const code = v.state.doc.toString().trim();
    if (!code) return true;
    hist.push(code); histAt = hist.length;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: '' } });
    probe(code).then(() => {
      const el = logRef.current; if (el) el.scrollTop = el.scrollHeight;
    });
    return true;
  };
  // Recall only from the edge of the document, so ↑ inside a multi-line probe still moves the caret.
  const recall = (dir) => () => {
    const v = view.current; if (!v || !hist.length) return false;
    const st2 = v.state, pos = st2.selection.main.head, line = st2.doc.lineAt(pos);
    if (dir < 0 && line.number !== 1) return false;
    if (dir > 0 && line.number !== st2.doc.lines) return false;
    histAt = Math.max(0, Math.min(hist.length, histAt + dir));
    const text = histAt >= hist.length ? '' : hist[histAt];
    v.dispatch({ changes: { from: 0, to: st2.doc.length, insert: text },
                 selection: { anchor: text.length } });
    return true;
  };

  useEffect(() => {
    if (!host.current || !window.mkEditor) return;
    // The same factory the cells use, so highlighting, completion and the keymap are the ones
    // already in your fingers — a probe is Julia, and typing it should feel like typing a cell.
    view.current = window.mkEditor(host.current, {
      doc: '',
      cellId: '__dbgscratch',
      noBreakpoints: true,   // not a cell's source: a breakpoint here has no line to be on
      keys: [{ key: 'Enter', run }, { key: 'Mod-Enter', run },
             { key: 'ArrowUp', run: recall(-1) }, { key: 'ArrowDown', run: recall(1) }],
    });
    return () => { try { view.current && view.current.destroy(); } catch (e) {} view.current = null; };
  }, []);

  return html`<div class="dbgscratch">
    <div class="dbgrhead">scratchpad
      <span class="dbgsp"></span>
      <span class="dbgscope">${s.scope}</span>
    </div>
    <div class="dbgprobes" ref=${logRef}>${probes.value.map((p, i) => html`<div class="dbgprobe" key=${i}>
      <div class="dbgpq">${p.expr}</div>
      <div class=${'dbgpa' + (p.ok ? '' : ' err')} title=${p.ok ? p.type : ''}>${p.ok ? p.repr : p.error}</div>
    </div>`)}
    </div>
    <div class="dbgped"><span class="dbgpp">›</span><div class="dbgpedhost" ref=${host}></div></div>
  </div>`;
}

// The predicate editor: the SAME factory the cells and the scratchpad use, so completion,
// highlighting and the keymap are the ones already in your fingers. A predicate is Julia written
// against the paused frame's locals — exactly what the scratchpad completes — so a browser prompt
// box was the wrong surface for it twice over: no completion, and not Slate's UI.
function CondEditor({ file, line, initial, onDone, label }) {
  const host = useRef(null), view = useRef(null);
  const commit = () => {
    const v = view.current;
    const text = v ? v.state.doc.toString().trim() : '';
    onDone(text);
    return true;
  };
  useEffect(() => {
    if (!host.current || !window.mkEditor) return;
    view.current = window.mkEditor(host.current, {
      doc: initial || '',
      cellId: '__dbgcond',            // shares the scratchpad's frame-local completion source
      noBreakpoints: true,
      keys: [{ key: 'Enter', run: commit }, { key: 'Mod-Enter', run: commit },
             { key: 'Escape', run: () => { onDone(null); return true; } }],
    });
    try { view.current.focus(); } catch (e) {}
    return () => { try { view.current && view.current.destroy(); } catch (e) {} view.current = null; };
  }, []);
  return html`<div class="dbgcondedit">
    ${label === '' ? null : html`<span class="dbgcondwhen">${label || 'when'}</span>`}
    <div class="dbgcondhost" ref=${host}></div>
    <button class="dbgcondok" title="set (enter)" onClick=${commit}>✓</button>
    <button class="dbgcondx" title="cancel (esc)" onClick=${() => onDone(null)}>✕</button>
  </div>`;
}

// ── live watches ───────────────────────────────────────────────────────────────────────────────
// A strip of tiles under the source, because the point of a live view is seeing it WHILE you read
// the line you are stopped on. Each tile renders through the notebook's own cell renderer, so a
// plot is a plot and an echart is an echart — nothing here knows what a chart is, which is why
// pointing a watch at a cell you already wrote works at all.

// Put a cell payload on screen. `output` is already HTML (text, images — a Makie figure arrives as
// one), but an echart is a SPEC that needs a live instance, which is why the scratch panel shows
// "run it in a real cell to see the chart" instead of the chart. A live view whose main use is a
// chart cannot do that, so the specs are mounted here.
function mountLiveOutput(el, c) {
  (el.__charts || []).forEach(ch => { try { ch.dispose(); } catch (e) {} });
  el.__charts = [];
  el.replaceChildren();
  if (c.output) {
    const stage = document.createElement('div');
    stage.className = 'dbgtileout';
    stage.innerHTML = c.output;
    el.appendChild(stage);
  }
  for (const spec of (c.echarts || [])) {
    if (!window.echarts || !window.slateInitChart) break;
    const box = document.createElement('div');
    box.className = 'dbgtilechart';
    el.appendChild(box);
    try {
      const inst = window.slateInitChart(box);
      inst.setOption(spec, true);
      el.__charts.push(inst);
    } catch (e) {}
  }
  if (!c.output && !(c.echarts || []).length) {
    const p = document.createElement('div');
    p.className = 'dbgtileempty';
    p.textContent = c.value_repr || '(no output)';
    el.appendChild(p);
  }
}

// The output is a cell payload, so it mounts the same way any cell's output does. Rendering it
// small costs no more than rendering it large: a chart sizes to its box. What costs is the
// EVALUATION, which is why it happens on stop rather than on every frame.
function LiveTile({ spec, expanded }) {
  const host = useRef(null);
  const rec = liveOut.value[spec] || {};
  useEffect(() => {
    const el = host.current; if (!el) return;
    if (rec.status !== 'ok' || !rec.cell) { el.replaceChildren(); return; }
    mountLiveOutput(el, rec.cell);
    // A chart sizes to its box, so expanding is a resize rather than a scale — the redraw is what
    // makes the big version actually more readable instead of just bigger.
    const ro = new ResizeObserver(() => { (el.__charts || []).forEach(c => { try { c.resize(); } catch (e) {} }); });
    ro.observe(el);
    return () => { ro.disconnect(); };
  }, [rec.cell, rec.status, expanded]);
  const label = spec.indexOf('cell:') === 0 ? spec.slice(5) : spec;
  return html`<div class=${'dbgtile' + (expanded ? ' big' : '') + (rec.status && rec.status !== 'ok' ? ' quiet' : '')}>
    <div class="dbgtilehead">
      <span class=${'dbgtilename' + (spec.indexOf('cell:') === 0 ? ' iscell' : '')}
            title=${spec}>${label}</span>
      <span class="dbgsp"></span>
      ${rec.status === 'unavailable'
        ? html`<span class="dbgtilenote" title=${rec.why}>not in this frame</span>` : null}
      ${rec.status === 'error'
        ? html`<span class="dbgtilenote err" title=${rec.why}>error</span>` : null}
      <button class="dbgtilebtn" title=${expanded ? 'shrink' : 'expand'}
              onClick=${() => liveOpen.value = expanded ? null : spec}>${expanded ? '⤡' : '⤢'}</button>
      <button class="dbgtilebtn" title="remove" onClick=${() => dropLive(spec)}>✕</button>
    </div>
    <div class="dbgtilebody" ref=${host}></div>
  </div>`;
}

// Adding one: the same editor the predicates use, so completion and highlighting are the cell
// keymap. `cell:<id>` is offered as text rather than as a picker — it is one token, and typing it
// keeps a single input for both kinds instead of a mode switch.
function LiveStrip() {
  if (!liveW.value.length && !liveAdd.value) {
    return html`<div class="dbgstrip2">
      <button class="dbgaddwatch" onClick=${() => liveAdd.value = true}>+ live view</button>
    </div>`;
  }
  return html`<div class="dbgstrip2">
    <div class="dbgtiles">
      ${liveW.value.map(spec => html`<${LiveTile} key=${spec} spec=${spec} expanded=${false} />`)}
    </div>
    ${liveAdd.value
      ? html`<${CondEditor} file="" line=${0} initial=""
               onDone=${t => { liveAdd.value = false; t && setLive(t, true); }} />`
      : html`<button class="dbgaddwatch" onClick=${() => liveAdd.value = true}>+ live view</button>`}
  </div>`;
}

// Expanded: over the focus view, dismissed like the detail modal. Same output, bigger box — the
// chart redraws at the new size rather than being scaled up.
function LiveOverlay() {
  const spec = liveOpen.value;
  if (!spec) return null;
  return html`<div class="dbgoverlay" onClick=${e => { if (e.target === e.currentTarget) liveOpen.value = null; }}>
    <div class="dbgoverlaybox"><${LiveTile} spec=${spec} expanded=${true} /></div>
  </div>`;
}

// ── resizable panes ────────────────────────────────────────────────────────────────────────────
// A debugging session is not one shape. Reading a long method wants the source wide; watching a
// specialist reason wants the transcript wide; a frame with forty locals wants the values tall.
// So every divider drags, and where you put it is remembered — per pane, across sessions.
const _lsNum = (k, d) => { const v = parseFloat(localStorage.getItem(k)); return isFinite(v) ? v : d; };
const paneRail = signal(_lsNum('slateDbgRail', 220));    // px
const paneRight = signal(_lsNum('slateDbgRight', 360));  // px
const paneVals = signal(_lsNum('slateDbgVals', 34));     // % of the middle column

// One drag handler for all four. `apply` turns a pointer position into the new size; the store
// is written on release rather than per-frame, so a drag is one localStorage write.
function drag(e, sig, key, apply) {
  e.preventDefault();
  const move = (ev) => { sig.value = apply(ev); };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    try { localStorage.setItem(key, String(sig.value)); } catch (_) {}
    document.body.style.cursor = '';
  };
  document.body.style.cursor = e.currentTarget.dataset.axis === 'y' ? 'row-resize' : 'col-resize';
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
}
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

// A divider. Double-click restores the default, which is the escape hatch for a pane dragged shut.
function Grip({ axis, onDrag, onReset }) {
  return html`<div class=${'dbggrip ' + axis} data-axis=${axis}
    onPointerDown=${onDrag} onDblClick=${onReset}></div>`;
}

// The specialist, working, beside the frame it is working on. Deliberately not the chat panel:
// this is a debugging transcript — what it thought, what it did, where that landed.
// Nothing unless something needs you.
//
// This was a header, an empty state, a brief viewer, a summon button and a disabled text box whose
// placeholder told you to press the summon button. Only one of those had a claim on the screen: an
// unanswered question means a stopped turn.
//
// The brief documented a choice nobody can make. Summoning offered one option, and belongs where
// the conversation is. Talking to the specialist directly routed around the orchestrator that is
// supposed to be running it.
function Convo({ s }) {
  const here = !!specialist.value;
  if (!here && !asks.value.some(a => a.role === DEBUG_ROLE)) return null;
  return html`<div class="dbgconvo">
    ${here ? html`<div class="dbgrhead">specialist
      ${working.value ? html`<span class="hydspin"></span>` : null}
      <span class="dbgsp"></span>
      <span class="dbgcrew">${bareModel(specialist.value.model || 'default')}</span>
      ${working.value ? html`<button class="dbgclear" title="stop its turn so it reads you now"
        onClick=${interruptSpecialist}>interrupt</button>` : null}
    </div>` : null}
    <${Asks} />
  </div>`;
}

// Whether Into offers library calls. A labelled switch at readable size, since nothing else on
// screen says what it controls.
function LibSwitch() {
  const on = intoLib.value;
  return html`<button class=${'dbglibsw' + (on ? ' on' : '')} role="switch" aria-checked=${on}
    title=${on ? 'Into offers calls into Base, stdlibs and packages. Picking one starts interpreting that whole module'
               : 'Into only offers calls into your own code, which is the usual thing to want'}
    onClick=${() => setIntoLib(!on)}>
    <span class="dbglibtrack"><span class="dbglibknob"></span></span>
    <span class="dbgliblabel">step into library code</span>
  </button>`;
}

// Which call to step into. Body-level, so it floats over the strip and the focus view alike.
//
// A library row names its module, because picking one starts interpreting that whole module.
// Everything in it steps from then on, which is worth knowing before choosing.
function IntoPicker() {
  const ts = intoTargets.value;
  if (!ts || !ts.length) return null;
  const close = () => intoTargets.value = null;
  return html`<div class="dbgintobg" onClick=${e => { if (e.target.classList.contains('dbgintobg')) close(); }}>
    <div class="dbginto">
      <div class="dbgintohead">step into<span class="dbgsp"></span>
        <button class="dbgfx" title="cancel" onClick=${close}>✕</button></div>
      ${ts.map(t => html`<div class=${'dbgintorow' + (t.interpreted ? '' : ' lib')} key=${t.pc}
          onClick=${() => intoTarget(t)}>
        <span class="dbgintoname">${t.name}</span>
        <span class="dbgintomod">${t.mod}</span>
        <span class="dbgintogo">${t.interpreted ? '▸' : 'go in anyway'}</span>
      </div>`)}
      ${ts.some(t => !t.interpreted)
        ? html`<div class="dbgintonote">going into a library starts interpreting its whole module
            for this session</div>` : null}
    </div>
  </div>`;
}

function Focus() {
  if (!focus.value) return null;
  const s = st.value;
  if (!s || s.finished) return null;
  return html`<div class="dbgfocusbg" onClick=${e => { if (e.target.classList.contains('dbgfocusbg')) focus.value = false; }}>
    <div class=${'dbgfocus' + (s.side ? ' remote' : '')}>
      <${LiveOverlay} />
      <div class="dbgfhead">
        <span class="dbgftitle">▸ stepping</span>
        <span class="dbgfcell">cell ${s.cell}</span>
        <${Owner} s=${s} />
        <${Locus} s=${s} big=${true} />
        <span class="dbgsp"></span>
        <span class="dbgsteps">${s.steps} ${s.steps === 1 ? 'step' : 'steps'}</span>
        <button class="dbgfx" title="close (the session keeps running)" onClick=${() => focus.value = false}>✕</button>
      </div>
      <div class="dbgfctl"><${Controls} /></div>
      <div class="dbgfbody"
        style=${'grid-template-columns:' + paneRail.value + 'px 5px minmax(0,1fr) 5px ' + paneRight.value + 'px'}>
        <${Stack} s=${s} />
        <${Grip} axis="x"
          onDrag=${e => drag(e, paneRail, 'slateDbgRail', ev => {
            const box = document.querySelector('.dbgfbody').getBoundingClientRect();
            return clamp(ev.clientX - box.left, 0, box.width - 360);
          })}
          onReset=${() => { paneRail.value = 220; localStorage.setItem('slateDbgRail', '220'); }} />
        <div class="dbgfmid">
          <${Source} s=${s} />
          <${LiveStrip} />
          <${Grip} axis="y"
            onDrag=${e => drag(e, paneVals, 'slateDbgVals', ev => {
              const box = document.querySelector('.dbgfmid').getBoundingClientRect();
              return clamp((box.bottom - ev.clientY) / box.height * 100, 0, 85);
            })}
            onReset=${() => { paneVals.value = 34; localStorage.setItem('slateDbgVals', '34'); }} />
          <div class="dbgfvals" style=${'height:' + paneVals.value + '%'}>
            <${Vals} title="locals" items=${s.locals} />
            <${Vals} title="cell" items=${s.bindings} hint="module-level bindings of the cell" />
          </div>
        </div>
        <${Grip} axis="x"
          onDrag=${e => drag(e, paneRight, 'slateDbgRight', ev => {
            const box = document.querySelector('.dbgfbody').getBoundingClientRect();
            return clamp(box.right - ev.clientX, 0, box.width - 360);
          })}
          onReset=${() => { paneRight.value = 360; localStorage.setItem('slateDbgRight', '360'); }} />
        <div class="dbgfright">
          <div class="dbgconvowrap"><${Convo} s=${s} /></div>
          <${Scratch} s=${s} />
        </div>
      </div>
    </div>
  </div>`;
}

// ── keys ──────────────────────────────────────────────────────────────────────────────────────────
// The conventional debugger keys, live only while a session is. They are ignored while the focus is
// in a text field, so the scratchpad and the cell editors keep every key they already had.
document.addEventListener('keydown', (e) => {
  if (!live.value) return;
  const t = e.target;
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable ||
            (t.closest && t.closest('.cm-editor')))) {
    if (!(e.key === 'Escape' && focus.value)) return;
  }
  if (e.key === 'F10') { e.preventDefault(); step('next'); }
  else if (e.key === 'F11') { e.preventDefault(); e.shiftKey ? step('out') : stepInto(); }
  else if (e.key === 'F5') { e.preventDefault(); e.shiftKey ? stopDebug() : step('continue'); }
  else if (e.key === 'Escape' && focus.value) { e.preventDefault(); focus.value = false; }
});

// ── the cell header button ────────────────────────────────────────────────────────────────────────
window.slateDebugCell = (id) => (debugCell.value === id ? stopDebug() : startDebug(id));
window.slateDebugActive = (id) => debugCell.value === id;
// What the scratchpad's completion should offer first: the names actually in scope at the paused
// line. The server's completer works on the namespace and cannot see a frame's locals.
window.slateDebugNames = () => {
  const s = st.value;
  if (!s || s.finished) return [];
  return [...(s.locals || []), ...(s.bindings || [])]
    .filter(v => v.type)
    .map(v => ({ name: v.name, type: v.type }));
};

// ── styles ────────────────────────────────────────────────────────────────────────────────────────
// Every colour is a theme token: the notebook ships seven themes, three of them light, and a
// hardcoded value is right in at most one of them.
const style = document.createElement('style');
style.textContent = `
.dbgstrip { margin:6px 0 0; border:1px solid color-mix(in srgb, var(--gold) 40%, var(--border));
  border-radius:8px; background:var(--bg2); overflow:hidden; font-size:.8rem;
  box-shadow:0 1px 0 color-mix(in srgb, var(--gold) 18%, transparent) inset; }
.dbgstrip.remote { border-color:color-mix(in srgb, var(--purple) 45%, var(--border)); }
.dbgstrip.done { border-color:var(--border); }

.dbgbar { display:flex; align-items:center; gap:8px; padding:6px 8px;
  background:color-mix(in srgb, var(--gold) 7%, var(--bg2)); border-bottom:1px solid var(--border); }
.dbgstrip.remote .dbgbar { background:color-mix(in srgb, var(--purple) 8%, var(--bg2)); }
.dbgstrip.done .dbgbar { background:var(--bg2); border-bottom:none; }
.dbgsp { flex:1 1 auto; }

.dbgctl { display:flex; align-items:center; gap:4px; }
.dbgb { display:inline-flex; align-items:center; gap:5px; padding:3px 9px; font-size:.78rem;
  border-radius:6px; background:var(--bg3); color:var(--text); border:1px solid var(--border);
  cursor:pointer; line-height:1.5; }
.dbgb:hover:not(:disabled) { border-color:var(--gold); color:var(--strong); }
.dbgb:disabled { opacity:.4; cursor:default; }
.dbgbg { font-size:.9em; opacity:.85; }
.dbgb-next:hover:not(:disabled) { background:color-mix(in srgb, var(--gold) 16%, var(--bg3)); }
.dbgb-continue:hover:not(:disabled) { background:color-mix(in srgb, var(--green) 16%, var(--bg3)); border-color:var(--green); }
.dbgb-stop:hover:not(:disabled) { background:color-mix(in srgb, var(--red) 16%, var(--bg3)); border-color:var(--red); color:var(--red); }

.dbgloc { display:inline-flex; align-items:center; gap:4px; padding:2px 8px; border-radius:11px;
  border:1px solid var(--border); color:var(--dim); font-size:.72rem; white-space:nowrap; }
.dbgloc.remote { color:var(--purple); border-color:var(--purple);
  background:color-mix(in srgb, var(--purple) 10%, transparent); }
.dbgloc.big { font-size:.78rem; padding:3px 10px; }

.dbgspecwrap { position:relative; display:inline-block; }
.dbgspec { padding:3px 9px; font-size:.75rem; border-radius:6px; background:var(--bg3);
  color:var(--dim); border:1px dashed var(--border); cursor:pointer; white-space:nowrap; }
.dbgspec:hover:not(:disabled) { color:var(--teal); border-color:var(--teal); border-style:solid; }
.dbgspec.on { color:var(--teal); border-color:var(--teal); border-style:solid;
  background:color-mix(in srgb, var(--teal) 12%, var(--bg3)); }
/* Anchored to the RIGHT: the button lives at the top-right of the specialist pane, and a
   left-anchored menu of this width would hang off the edge of the column. */
.dbgspecmenu { position:absolute; z-index:80; top:calc(100% + 4px); right:0;
  width:max(280px, 22vw); display:flex; flex-direction:column;
  background:var(--bg2); border:1px solid var(--border); border-radius:8px; overflow:hidden;
  box-shadow:0 8px 26px rgba(0,0,0,.4); }
.dbgspecfind { flex:0 0 auto; padding:7px 10px; background:var(--bg3); color:var(--text);
  border:none; border-bottom:1px solid var(--border); outline:none; font-size:.78rem; }
.dbgspecfind:focus { border-bottom-color:var(--accent); }
/* A list this long is scrolled, not shown — bounded so the menu can never outgrow the window. */
.dbgspeclist { flex:1 1 auto; max-height:min(360px, 45vh); overflow:auto; padding:3px 0; }
.dbgspecrow { display:flex; align-items:baseline; gap:7px; padding:5px 10px; font-size:.76rem;
  cursor:pointer; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
  font-family:var(--mono,ui-monospace,monospace); }
.dbgspecrow:hover { background:var(--ovl); color:var(--teal); }
.dbgspecrow.recent { color:var(--teal); }
/* Family headers, so ~70 models read as a handful of groups. Sticky, because you scroll past
   several of them looking for one. */
.dbgspechead { position:sticky; top:0; z-index:1; display:flex; align-items:baseline; gap:6px;
  padding:4px 10px 3px; background:var(--bg2); color:var(--dim);
  font-size:.66rem; text-transform:uppercase; letter-spacing:.08em;
  border-top:1px solid color-mix(in srgb, var(--border) 60%, transparent); }
.dbgspecgrp:first-child .dbgspechead { border-top:none; }
.dbgspecn { opacity:.6; font-variant-numeric:tabular-nums; }
.dbgspecgrp .dbgspecrow { padding-left:18px; }
.dbgspecmark { flex:0 0 auto; color:var(--dim); }
.dbgspecnote { padding:6px 10px; font-size:.72rem; color:var(--dim); }
.dbgspecfoot { flex:0 0 auto; padding:4px 10px; font-size:.68rem; color:var(--dim);
  border-top:1px solid var(--border); font-variant-numeric:tabular-nums; }

.dbgowner { display:inline-flex; align-items:center; gap:4px; padding:2px 8px; border-radius:11px;
  font-size:.72rem; white-space:nowrap; color:var(--teal); border:1px solid var(--teal);
  background:color-mix(in srgb, var(--teal) 10%, transparent); }

/* The specialist is blocked on this. Sits at the foot of its own pane, just above the box you
   would reply in — one column, one voice. */
.dbgasks { flex:0 0 auto; display:flex; flex-direction:column; gap:7px; margin-top:8px;
  padding:8px 9px; border-radius:7px; border:1px solid var(--teal);
  background:color-mix(in srgb, var(--teal) 10%, transparent); }
.dbgask { display:flex; flex-direction:column; gap:7px; font-size:.78rem; }
.dbgaskq { color:var(--strong); line-height:1.5; }
.dbgaskbtns { display:flex; gap:6px; }
.dbgask .dbgpform { margin-top:0; }
/* In the cell ribbon, when the workspace is shut: a nudge, not the prompt itself. */
.dbgaskbadge { padding:5px 10px; font-size:.74rem; cursor:pointer; color:var(--teal);
  border-top:1px solid var(--border);
  background:color-mix(in srgb, var(--teal) 10%, transparent); }
.dbgaskbadge:hover { background:color-mix(in srgb, var(--teal) 18%, transparent); }

.dbgexp { padding:2px 7px; border-radius:6px; background:transparent; border:1px solid transparent;
  color:var(--dim); cursor:pointer; font-size:.9rem; line-height:1; }
.dbgexp:hover { color:var(--accent); border-color:var(--border); background:var(--bg3); }

/* The in-cell ribbon: one clickable line into the workspace. */
.dbgbar.open { cursor:pointer; font-family:var(--mono,ui-monospace,monospace); font-size:.74rem; }
.dbgbar.open:hover { background:color-mix(in srgb, var(--gold) 13%, var(--bg2)); }
.dbgstrip.remote .dbgbar.open:hover { background:color-mix(in srgb, var(--purple) 14%, var(--bg2)); }
.dbgribbon { color:var(--gold); font-weight:600; white-space:nowrap; }
.dbgstrip.remote .dbgribbon { color:var(--purple); }
.dbgclear { padding:1px 7px; border-radius:5px; font-size:.68rem; background:transparent;
  border:1px solid var(--border); color:var(--dim); cursor:pointer;
  text-transform:none; letter-spacing:0; }
.dbgclear:hover { color:var(--red); border-color:var(--red); }
.dbgscope { color:var(--accent); }
.dbgbp { color:var(--red); font-size:.8em; }
.dbgfile { color:var(--dim); }
.dbgsteps { color:var(--dim); font-size:.72rem; font-variant-numeric:tabular-nums; }
.dbgdone { color:var(--green); font-size:.78rem; }
.dbgdone.err { color:var(--red); }

.dbgvals { flex:1 1 260px; min-width:0; padding-top:6px; }
.dbgvhead { display:flex; align-items:baseline; gap:6px; color:var(--dim); font-size:.68rem;
  text-transform:uppercase; letter-spacing:.07em; padding-bottom:3px; }
/* A count, not a second word in the heading. */
.dbgvn-count { color:var(--dim); opacity:.45; font-size:.9em; text-transform:none; letter-spacing:0;
  font-variant-numeric:tabular-nums; }

.dbgval { display:grid; grid-template-columns:minmax(60px,auto) minmax(0,1fr) minmax(0,2fr);
  gap:10px; align-items:baseline; padding:2px 4px; border-radius:4px;
  font-family:var(--mono,ui-monospace,monospace); font-size:.74rem; line-height:1.6; }
.dbgval:hover { background:var(--ovl); }
.dbgval.chg { animation:dbgflash 900ms ease-out; }
@keyframes dbgflash {
  0% { background:color-mix(in srgb, var(--gold) 45%, transparent); }
  100% { background:transparent; }
}
.dbgvn { color:var(--strong); }
.dbgvt { color:var(--dim); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.dbgvr { color:var(--val); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.dbgval.unset .dbgvr { color:var(--dim); font-style:italic; }
/* Holds the PREVIOUS run's value — the line that writes it hasn't run yet this session. Dimmed
   rather than hidden: it is still what is in the namespace, and sometimes that's what you want. */
.dbgval.stale { opacity:.5; }
.dbgval.stale .dbgvn::after { content:'·'; margin-left:5px; color:var(--gold); }

/* ── focus view ─────────────────────────────────────────────────────────────── */
/* Step-into picker. Above the focus view (70), which is what asked the question. Undimmed, so
   the line being chosen from stays readable. */
.dbgintobg { position:fixed; inset:0; z-index:90; display:flex; align-items:center; justify-content:center; }
.dbginto { min-width:320px; max-width:min(560px,92vw); max-height:70vh; overflow:auto;
  background:var(--bg2); border:1px solid var(--border); border-radius:9px;
  box-shadow:0 18px 48px rgba(0,0,0,.55); padding:6px; }
.dbgintohead { display:flex; align-items:center; gap:6px; padding:2px 6px 6px;
  font-size:.7rem; letter-spacing:.05em; text-transform:uppercase; color:var(--dim); }
.dbgintorow { display:flex; align-items:baseline; gap:8px; padding:5px 8px; border-radius:6px;
  cursor:pointer; font-family:var(--mono,ui-monospace,monospace); font-size:.78rem; }
.dbgintorow:hover { background:color-mix(in srgb, var(--teal) 14%, transparent); }
.dbgintoname { flex:0 0 auto; color:var(--text); }
.dbgintomod { flex:1 1 auto; color:var(--dim); font-size:.7rem; }
.dbgintogo { flex:0 0 auto; color:var(--teal); font-size:.7rem; }
/* A library row sits in the same list, quieter, with an action that says what it does. */
.dbgintorow.lib .dbgintoname { color:var(--dim); }
.dbgintorow.lib .dbgintogo { color:var(--gold); }
.dbgintonote { padding:6px 8px 2px; color:var(--dim); font-size:.68rem; }
/* The library switch, at readable size with its label spelled out. Nothing else on screen says
   what it controls. */
.dbglibsw { display:flex; align-items:center; gap:8px; width:100%; margin-top:7px; padding:6px 7px;
  background:transparent; border:1px solid var(--border); border-radius:7px; cursor:pointer;
  color:var(--dim); font-size:.72rem; text-align:left; }
.dbglibsw:hover { border-color:var(--teal); color:var(--text); }
.dbglibsw.on { border-color:var(--teal); color:var(--text);
  background:color-mix(in srgb, var(--teal) 10%, transparent); }
/* The track carries its own inset border. On a dark theme a flat fill close to the panel colour
   disappears, and the knob alone reads as a stray dot. */
.dbglibtrack { flex:0 0 auto; width:26px; height:14px; border-radius:7px; position:relative;
  background:var(--bg3); box-shadow:inset 0 0 0 1px var(--border); transition:background .12s; }
.dbglibsw.on .dbglibtrack { background:var(--teal); box-shadow:none; }
.dbglibknob { position:absolute; top:2px; left:2px; width:10px; height:10px; border-radius:50%;
  background:var(--dim); transition:transform .12s, background .12s; }
.dbglibsw.on .dbglibknob { transform:translateX(12px); background:var(--bg); }
.dbgliblabel { flex:1 1 auto; }
/* Shown where the step happened rather than in the rail, which is where the switch is wanted. */
.dbgskipnote { display:flex; align-items:center; gap:7px; margin:5px 0 0; padding:5px 8px;
  border-radius:6px; border:1px solid var(--border); color:var(--dim); font-size:.7rem; }
.dbgskipgo { padding:1px 7px; background:transparent; border:1px solid var(--teal); border-radius:4px;
  color:var(--teal); cursor:pointer; font-size:.68rem; white-space:nowrap; }
.dbgskipgo:hover { background:color-mix(in srgb, var(--teal) 16%, transparent); }
.dbgskipx { margin-left:auto; padding:0 3px; background:transparent; border:none; color:var(--dim);
  cursor:pointer; }
.dbgskipnote.err { border-color:var(--red); color:var(--red); }
.dbgfocusbg { position:fixed; inset:0; z-index:70; background:rgba(0,0,0,.55);
  display:flex; align-items:center; justify-content:center; padding:24px; }
/* Beside the chat, not over it. Watching an agent debug means reading two things at once — the
   frame it is stopped on, and what it is saying about it — and a workspace that covered the panel
   made you pick one. Insetting by the panel's own width is how the editor already behaves. */
body.agent-open .dbgfocusbg { right:var(--agentw, 380px); }
/* Positioned, so the expanded live view sits over THIS box rather than the viewport: the focus
   view is already a dialog, and an overlay escaping it would cover the page behind. (No backticks
   in here — this whole block is a template literal.) */
.dbgfocus { position:relative; display:flex; flex-direction:column; width:min(1580px,100%); height:min(900px,100%);
  background:var(--bg); border:1px solid color-mix(in srgb, var(--gold) 40%, var(--border));
  border-radius:12px; overflow:hidden; box-shadow:0 18px 60px rgba(0,0,0,.45); }
.dbgfocus.remote { border-color:color-mix(in srgb, var(--purple) 45%, var(--border)); }

.dbgfhead { display:flex; align-items:center; gap:10px; padding:9px 12px;
  background:color-mix(in srgb, var(--gold) 8%, var(--bg2)); border-bottom:1px solid var(--border); }
.dbgfocus.remote .dbgfhead { background:color-mix(in srgb, var(--purple) 10%, var(--bg2)); }
.dbgftitle { color:var(--gold); font-weight:600; font-size:.86rem; }
.dbgfocus.remote .dbgftitle { color:var(--purple); }
.dbgfcell { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); font-size:.78rem; }
.dbgfx { padding:2px 8px; border-radius:6px; background:transparent; border:1px solid transparent;
  color:var(--dim); cursor:pointer; }
.dbgfx:hover { color:var(--red); border-color:var(--border); background:var(--bg3); }
.dbgfctl { padding:7px 12px; border-bottom:1px solid var(--border); background:var(--bg2); }

/* Three columns — where you came from, where you are, who you are working with — with every
   divider draggable, because a debugging session is not one shape. Sizes come from inline styles
   (the signals), so the grid template is set in JS; only the grips are styled here. */
.dbgfbody { flex:1 1 auto; min-height:0; display:grid; }
.dbgfmid { display:flex; flex-direction:column; min-width:0; min-height:0; }

.dbggrip { background:transparent; flex:0 0 auto; position:relative; z-index:2; }
.dbggrip.x { cursor:col-resize; }
.dbggrip.y { cursor:row-resize; height:5px; margin:-2px 0; }
/* The hairline shows on hover/drag only, so an idle workspace has no seams drawn across it. */
.dbggrip::after { content:''; position:absolute; inset:0; background:transparent; transition:background .12s; }
.dbggrip:hover::after, .dbggrip:active::after { background:var(--accent); }
.dbggrip.x::after { left:2px; right:2px; }
.dbggrip.y::after { top:2px; bottom:2px; }

.dbgconvowrap { min-height:0; display:flex; flex-direction:column; }
.dbgrail { min-height:0; overflow:auto; padding:10px; border-right:1px solid var(--border);
  background:var(--bg2); }
.dbgrhead { display:flex; align-items:baseline; gap:6px; color:var(--dim); font-size:.68rem;
  text-transform:uppercase; letter-spacing:.07em; margin:2px 0 5px; }
/* A scope is a Julia name, and Main.NB is not MAIN.NB — undo the header's casing for anything
   that carries an identifier. (No backticks in here: this whole block is a template literal.) */
.dbgrhead .dbgscope, .dbgrhead .dbgcrew, .dbgrhead .dbgfile { text-transform:none; letter-spacing:0; }
.dbgrhead2 { margin-top:16px; }
.dbgfr { display:flex; flex-direction:column; gap:1px; padding:4px 6px; border-radius:5px;
  font-family:var(--mono,ui-monospace,monospace); font-size:.73rem; border-left:2px solid transparent; }
.dbgfr .dbgfile { font-size:.92em; padding-left:13px; }
.dbgfr.cur { background:color-mix(in srgb, var(--gold) 12%, transparent); border-left-color:var(--gold); }
.dbgfrm { color:var(--gold); }
.dbgfr { cursor:pointer; }
.dbgfr:hover { background:color-mix(in srgb, var(--text) 6%, transparent); }
/* The pinned frame reads as teal, the frame execution is actually stopped in stays gold — they
   are different claims and the eye should not have to check which is which. */
.dbgfr.sel:not(.cur) { background:color-mix(in srgb, var(--teal) 14%, transparent);
  border-left-color:var(--teal); }
.dbgback { margin-left:6px; padding:0 6px; background:transparent; border:1px solid var(--teal);
  border-radius:4px; color:var(--teal); cursor:pointer; font-size:.66rem; }
.dbgback:hover { background:color-mix(in srgb, var(--teal) 16%, transparent); }
.dbgsrc.caller .dbgsrcbody { box-shadow:inset 3px 0 0 var(--teal); }
.dbgfr .dbgscope { display:inline; }
.dbgmarks { display:flex; flex-direction:column; gap:2px; }
.dbgmark { display:flex; align-items:center; gap:6px; padding:2px 6px; border-radius:5px;
  font-family:var(--mono,ui-monospace,monospace); font-size:.72rem;
  border-left:2px solid var(--red); background:color-mix(in srgb, var(--red) 8%, transparent); }
.dbgmark .dbgfile { flex:1 1 auto; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
/* Disabled: the row stays, without the colour that marks a live breakpoint. */
.dbgmark.off { border-left-color:var(--dim); background:transparent; opacity:.6; }
.dbgmarko { padding:0; background:transparent; border:none; cursor:pointer; font-size:.7rem;
  line-height:1; color:var(--red); }
.dbgmark.off .dbgmarko { color:var(--dim); }
/* A watch whose expression is not a number. It samples, it just has no curve to draw. */
.dbgwrange.nonum { color:var(--dim); font-style:italic; }
.dbgmarko:hover { opacity:.75; }
.dbgmarkc { padding:0 5px; background:transparent; border:1px solid var(--border); border-radius:4px;
  color:var(--dim); cursor:pointer; font-size:.68rem; font-family:var(--mono,ui-monospace,monospace); }
.dbgmarkc:hover { color:var(--teal); border-color:var(--teal); }
.dbgmarkc.on { color:var(--teal); border-color:var(--teal); }
/* The predicate on its own line: these get long, and truncating the only thing that says WHEN a
   breakpoint fires hides the part that matters. */
.dbgcond { margin:0 6px 3px 18px; padding:1px 5px; border-left:2px solid var(--teal);
  color:var(--teal); font-family:var(--mono,ui-monospace,monospace); font-size:.68rem;
  overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.dbgcondedit { display:flex; align-items:center; gap:4px; margin:1px 6px 3px 14px; padding:1px 4px;
  border-left:2px solid var(--teal); border-radius:4px;
  background:color-mix(in srgb, var(--teal) 8%, transparent); }
.dbgcondwhen { color:var(--teal); font-size:.66rem; font-family:var(--mono,ui-monospace,monospace); }
.dbgcondhost { flex:1 1 auto; min-width:0; }
.dbgcondhost .cm-editor { background:transparent; font-size:.72rem; }
.dbgcondhost .cm-content { padding:1px 2px; }
.dbgcondhost .cm-gutters { display:none; }
.dbgcondok, .dbgcondx { padding:0 3px; background:transparent; border:none; cursor:pointer; font-size:.7rem; }
.dbgcondok { color:var(--teal); }
.dbgcondx { color:var(--dim); }
.dbgcond { cursor:pointer; }
/* The live-view strip: under the source, because the point of a live view is seeing it WHILE you
   read the line you are stopped on. Tiles scroll horizontally rather than wrapping — comparing two
   traces side by side is the case this exists for, and wrapping breaks the comparison. */
.dbgstrip2 { display:flex; align-items:stretch; gap:6px; padding:4px 6px;
  border-top:1px solid var(--border); background:var(--bg2); overflow-x:auto; flex:0 0 auto; }
.dbgtiles { display:flex; gap:6px; align-items:stretch; }
.dbgtile { display:flex; flex-direction:column; min-width:190px; max-width:340px;
  border:1px solid var(--border); border-radius:6px; background:var(--bg); overflow:hidden; }
/* Sized to content with a cap, not a uniform grid: forcing a scalar into a chart-sized box wastes
   the height the source needs. */
.dbgtile .dbgtilebody { max-height:150px; overflow:auto; padding:3px 5px; }
.dbgtile.big { min-width:0; max-width:none; width:100%; height:100%; border:none; }
.dbgtile.big .dbgtilebody { max-height:none; height:100%; }
.dbgtile.quiet { opacity:.55; }
.dbgtilehead { display:flex; align-items:center; gap:4px; padding:2px 5px;
  border-bottom:1px solid var(--border); font-size:.68rem; }
.dbgtilename { font-family:var(--mono,ui-monospace,monospace); color:var(--dim);
  overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:150px; }
.dbgtilename.iscell { color:var(--teal); }
.dbgtilenote { color:var(--dim); font-size:.64rem; }
.dbgtilenote.err { color:var(--red); }
.dbgtilebtn { padding:0 3px; background:transparent; border:none; color:var(--dim);
  cursor:pointer; font-size:.7rem; }
.dbgtilebtn:hover { color:var(--text); }
.dbgtilechart { width:100%; height:130px; }
.dbgtile.big .dbgtilechart { height:calc(100% - 10px); min-height:320px; }
.dbgtileout img, .dbgtileout svg { max-width:100%; height:auto; }
.dbgtileempty { color:var(--dim); font-family:var(--mono,ui-monospace,monospace); font-size:.7rem; }
.dbgaskopts { display:flex; flex-wrap:wrap; gap:5px; margin-top:5px; }
/* Wrapping, not a row: an option's label is a sentence explaining the trade-off, and truncating
   it to fit leaves you choosing between two things you cannot tell apart. */
.dbgopt { padding:4px 9px; border:1px solid var(--teal); border-radius:6px; background:transparent;
  color:var(--teal); cursor:pointer; font-size:.74rem; text-align:left; max-width:100%; }
.dbgopt:hover { background:color-mix(in srgb, var(--teal) 15%, transparent); }
.dbgopt.skip { border-color:var(--border); color:var(--dim); }
/* The expression, what it is now, and what it has been. */
.dbgwatches { display:flex; flex-direction:column; }
.dbgwatches .dbgwatch { padding:4px 0 6px; border-bottom:1px solid var(--bg3); }
.dbgwatches .dbgwatch:last-child { border-bottom:none; }
.dbgwtop { display:flex; align-items:baseline; gap:7px; }
.dbgwx { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
  font-family:'Cascadia Code',monospace; font-size:.74rem; color:var(--teal); }
.dbgwat { font-size:.64rem; color:var(--dim); }
.dbgwrm { cursor:pointer; background:none; border:none; padding:0 2px; color:var(--dim); font-size:.7rem; }
.dbgwrm:hover { color:var(--red,#e57575); }
.dbgwnow { font-family:'Cascadia Code',monospace; font-size:.76rem; color:var(--strong); }
.dbgspark { display:block; width:100%; height:26px; color:var(--teal); margin:2px 0 1px; }
.dbgwrange { font-size:.66rem; color:var(--dim); }
.dbgwempty { font-size:.7rem; color:var(--dim); font-style:italic; padding:2px 0; }
.dbgwadd { cursor:pointer; background:none; border:1px dashed var(--border); border-radius:4px;
  color:var(--dim); font-size:.7rem; line-height:1; padding:1px 6px; }
.dbgwadd:hover { color:var(--teal); border-color:var(--teal); }
.dbgaddwatch { align-self:center; padding:2px 8px; background:transparent; border:1px dashed var(--border);
  border-radius:6px; color:var(--dim); cursor:pointer; font-size:.7rem; white-space:nowrap; }
.dbgaddwatch:hover { color:var(--teal); border-color:var(--teal); }
.dbgoverlay { position:absolute; inset:0; z-index:40; display:flex; padding:24px;
  background:color-mix(in srgb, var(--bg) 82%, transparent); }
.dbgoverlaybox { flex:1 1 auto; border:1px solid var(--border); border-radius:10px;
  background:var(--bg2); overflow:hidden; }
.dbgmarkx { padding:0 4px; background:transparent; border:none; color:var(--dim); cursor:pointer; font-size:.8rem; }
.dbgmarkx:hover { color:var(--red); }
.dbginterp { display:flex; flex-wrap:wrap; gap:4px; }
.dbgmod { display:inline-flex; align-items:center; gap:3px; padding:1px 7px; border-radius:9px;
  background:var(--bg3); border:1px solid var(--border);
  color:var(--teal); font-size:.7rem; font-family:var(--mono,ui-monospace,monospace); }
/* The ✕ appears on hover. This list is read far more often than it is edited, and a standing
   column of delete buttons reads as a warning. */
.dbgmod.drop { padding-right:3px; }
.dbgmodx { padding:0 2px; background:transparent; border:none; color:var(--dim); cursor:pointer;
  font-size:.62rem; line-height:1; opacity:0; transition:opacity .1s; }
.dbgmod.drop:hover .dbgmodx { opacity:1; }
.dbgmodx:hover { color:var(--red); }

.dbgsrc { display:flex; flex-direction:column; min-width:0; min-height:0; }
.dbgsrchead { display:flex; align-items:baseline; gap:10px; padding:6px 12px;
  border-bottom:1px solid var(--border); font-family:var(--mono,ui-monospace,monospace); font-size:.74rem; }
.dbgnosrc { color:var(--dim); font-style:italic; }
/* Said once, in the pane where the margin is — it is not obvious that a read-only viewer is
   clickable. Hidden as soon as anything is armed, which is the proof you found it. (Gated in JS
   on the mark COUNT, not on a dot being present: the gutter's own spacer contains one always.) */
.dbgsrchint { color:var(--dim); font-size:.68rem; opacity:.65;
  font-family:'Segoe UI',system-ui,sans-serif; }
.dbgsrcbody { flex:1 1 auto; min-height:0; overflow:auto; }
.dbgsrcbody .cm-editor { height:100%; }
.dbgsrcbody .cm-scroller { overflow:auto; }

.dbgfright { display:flex; flex-direction:column; min-width:0; min-height:0;
  border-left:1px solid var(--border); background:var(--bg2); }
/* Values sit UNDER the source, in the same column, because they belong to the line above them.
   Height is dragged (inline style); 0 is allowed, so the pane can be shut and reopened. */
.dbgfvals { flex:0 0 auto; min-height:0; overflow:auto; padding:8px 12px;
  border-top:1px solid var(--border); display:flex; flex-wrap:wrap; gap:0 20px; }
.dbgfvals .dbgvals { flex:1 1 300px; min-width:0; }
/* One line per value. Stacking the repr underneath cost two rows and a gap each — four locals
   filled the pane, and a frame routinely has thirty. */
.dbgfvals .dbgval { padding:1px 4px; line-height:1.45; }
.dbgfvals .dbgvhead { padding-bottom:2px; }

/* ── the specialist pane ─────────────────────────────────────────────────────── */
.dbgconvo { flex:0 0 auto; display:flex; flex-direction:column; padding:8px 12px 6px; }
.dbgcrew { color:var(--teal); font-family:var(--mono,ui-monospace,monospace);
  font-size:.68rem; text-transform:none; letter-spacing:0; }
.dbgcempty { color:var(--dim); font-size:.76rem; display:flex; flex-direction:column;
  align-items:flex-start; gap:8px; padding:6px 0; }
.dbgcmsg { font-size:.78rem; line-height:1.5; white-space:pre-wrap; word-break:break-word; }
.dbgcmsg.said { color:var(--text); }
.dbgcmsg.think { color:var(--dim); font-style:italic; border-left:2px solid var(--border); padding-left:7px; }
.dbgcmsg.you { color:var(--strong); background:var(--ovl); border-radius:6px; padding:5px 8px; }
/* The turn it was handed. Collapsed to a few lines — it is context, not conversation — and
   expands on click, because when an answer looks wrong the brief is the first thing to check. */
.dbgcmsg.brief { color:var(--dim); font-size:.72rem; white-space:pre-wrap;
  border-left:2px solid var(--accent); padding:4px 0 4px 8px;
  max-height:5.2em; overflow:hidden; cursor:zoom-in; }
.dbgcmsg.brief:hover { color:var(--text); }
.dbgcmsg.brief.open { max-height:none; cursor:zoom-out; }

.dbgbrief { flex:0 0 auto; max-height:40%; overflow:auto; margin-bottom:6px; padding:7px 9px;
  border:1px solid var(--border); border-radius:7px; background:var(--bg3); }
.dbgbriefhead { color:var(--dim); font-size:.66rem; text-transform:uppercase; letter-spacing:.07em;
  margin:2px 0 4px; }
.dbgbriefhead + .dbginterp + .dbgbriefhead { margin-top:9px; }
.dbgbrieftxt { margin:0; white-space:pre-wrap; word-break:break-word; color:var(--text);
  font-family:var(--mono,ui-monospace,monospace); font-size:.68rem; line-height:1.5; }
.dbgclear.on { color:var(--accent); border-color:var(--accent); }
/* Typed while it was working — sent, but not yet delivered. Dashed until it goes. */
.dbgcmsg.held { border:1px dashed var(--teal); background:transparent; }
.dbgheld { display:block; margin-top:3px; color:var(--teal); font-size:.68rem; font-style:italic; }
/* One step, one line: the verb, what it was given, and where it landed. */
.dbgcact { display:flex; align-items:baseline; gap:7px; font-size:.72rem;
  font-family:var(--mono,ui-monospace,monospace); padding:1px 0; }
.dbgcact.live { opacity:.55; }
.dbgcverb { flex:0 0 auto; color:var(--teal); }
.dbgcact.err .dbgcverb { color:var(--red); }
.dbgcarg { flex:0 0 auto; color:var(--strong); }
.dbgcgist { flex:1 1 auto; min-width:0; color:var(--dim);
  overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }

/* Takes whatever the transcript above it isn't using — drag their divider up and the scratchpad
   grows into the space. Content sits at the TOP: the input follows the probes rather than being
   pinned to the floor, so an empty pad is a box under its heading, not a box below a void. */
.dbgscratch { flex:1 1 auto; min-height:0; display:flex; flex-direction:column;
  justify-content:flex-start; border-top:1px solid var(--border); padding:8px 12px 10px; }
/* Grows with what is in it; an empty scratchpad should not hold open a third of the column. */
.dbgprobes { flex:0 1 auto; min-height:0; overflow:auto;
  font-family:var(--mono,ui-monospace,monospace); font-size:.73rem; }
.dbgprobe { padding:3px 0; border-bottom:1px solid color-mix(in srgb, var(--border) 55%, transparent); }
.dbgpq { color:var(--dim); }
.dbgpq::before { content:'\\203A '; color:var(--accent); }
.dbgpa { color:var(--val); white-space:pre-wrap; word-break:break-word; }
.dbgpa.err { color:var(--red); }
.dbgpform { display:flex; align-items:center; gap:6px; margin-top:7px; padding:4px 8px;
  border:1px solid var(--border); border-radius:6px; background:var(--bg3); }
.dbgpform:focus-within { border-color:var(--accent); }
.dbgpp { color:var(--accent); font-family:var(--mono,ui-monospace,monospace); flex:0 0 auto; }
.dbgpform input { flex:1 1 auto; background:transparent; border:none; outline:none; color:var(--text);
  font-family:var(--mono,ui-monospace,monospace); font-size:.76rem; }

/* The probe editor: a real CodeMirror, so completion, highlighting and the keymap match the cells.
   Enter runs it, ⇧Enter is a newline (CodeMirror's own), ↑/↓ walk history from the document edge. */
.dbgped { display:flex; align-items:flex-start; gap:6px; margin-top:7px; padding:3px 8px;
  border:1px solid var(--border); border-radius:6px; background:var(--bg3); }
.dbgped:focus-within { border-color:var(--accent); }
.dbgpedhost { flex:1 1 auto; min-width:0; }
.dbgpedhost .cm-editor { background:transparent; font-size:.76rem; }
.dbgpedhost .cm-content { padding:2px 0; }
.dbgpedhost .cm-line { padding:0; }
.dbgpedhost .cm-focused { outline:none; }

/* No width breakpoint: the grid template is an inline style (the drag signals), and hiding a grid
   ITEM does not free its track — the remaining panes would slide into the wrong ones. Narrow
   screens are served by the same thing wide ones are: drag the rail shut. */
`;
document.head.appendChild(style);

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Focus} />`, host);

// Its own root: the picker has to outrank the focus view, and rendering it inside would put it
// under the same stacking context.
const intoHost = document.createElement('div');
document.body.appendChild(intoHost);
render(html`<${IntoPicker} />`, intoHost);
