// Asserts that a specialist's blocked question reaches a surface, whichever role asked it.
//
// Specialist events go to every subscriber tagged with the role they belong to, and each surface
// takes its own. The debugger's pane takes `debugger`; the chat took only events with NO role,
// because the only asker that had none was the notebook's own agent.
//
// That left a hole exactly the shape of a role defined outside the code. A config-defined
// specialist has no pane, so its question was refused by the debugger's pane for having the wrong
// role and by the chat for having one at all: pushed to the page, rendered nowhere, and left to
// time out while the person who could answer it never saw it. The checker had the same hole the
// moment it was given `spec_ask`.
//
// So the rule under test is ownership, not identity: a role with a pane answers there, and
// everything else falls through to the chat.
//
//   node test/js/specialist_ask_routing.mjs      # exit 0 = pass, 1 = mismatch, 2 = load failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const jsdir = join(here, '..', '..', 'src', 'assets', 'js');
const agent = readFileSync(join(jsdir, 'agent.js'), 'utf8');
const dbg = readFileSync(join(jsdir, 'debugger.js'), 'utf8');

const fails = [];
const ok = (cond, what) => { if (!cond) fails.push(what); };

// The two subscriber bodies, sliced from the real files rather than restated: the bug was that two
// independent filters agreed to drop the same event, which a stand-in for either would hide.
function sub(src, marker) {
  const i = src.indexOf(marker);
  if (i < 0) { console.error('specialist_ask_routing: could not find ' + marker); process.exit(2); }
  let depth = 0, start = src.indexOf('{', i);
  for (let j = start; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start + 1, j);
  }
  console.error('specialist_ask_routing: unbalanced braces'); process.exit(2);
}

// What each surface does with a payload, reduced to "did it take it?".
const CHAT = sub(agent, '(window.slateSpecialistSubs ||= []).push(p => {');
const PANE = sub(dbg, '(window.slateSpecialistSubs ||= []).push((p) => {');

function route(payload, panes) {
  const seen = { chat: false, pane: false };
  const win = { slateRolePanes: panes };
  // Each body returns early when the event is not its own; reaching the ask handler is taking it.
  new Function('p', 'window', '_agentFinding', '_agentAsk', 'renderAgentMsgs', 'renderAsks',
               'agentMsgs', 'took', CHAT + '\n took.chat = true;')
    (payload, win, () => {}, () => { seen.chat = true; }, () => {}, () => {}, [], seen);
  new Function('p', 'window', 'DEBUG_ROLE', 'asks', 'specialist', 'took',
               PANE + '\n took.pane = true;')
    (payload, win, 'debugger',
     { value: [] }, { value: null }, seen);
  return seen;
}

const panes = new Set(['debugger']);

// The notebook's own agent has no role and has always belonged in the chat.
ok(route({ ask: { id: 'a1', text: 'which one?' } }, panes).chat, 'a role-less ask reaches the chat');

// The debugger has a pane, so its question answers there and must NOT be duplicated into the chat.
const d = route({ role: 'debugger', ask: { id: 'a2', text: 'step in?' } }, panes);
ok(d.pane, "the debugger's ask reaches its pane");
ok(!d.chat, "…and is not also drawn in the chat");

// A role with no pane — which is every role defined in the config file — falls through to the chat.
const p = route({ role: 'profiler', ask: { id: 'a3', text: 'which workload?' } }, panes);
ok(p.chat, 'a config-defined role\'s ask reaches the chat');
ok(!p.pane, "…and not the debugger's pane");

// The checker is the case that already existed in the tree: a second role in code, given `spec_ask`
// and no surface.
ok(route({ role: 'checker', ask: { id: 'a4', text: 'is this intended?' } }, panes).chat,
   "the checker's ask reaches the chat");

// With no pane registered at all — a page that does not load the debugger — the chat still takes it,
// since a question nobody renders is worse than one in the wrong place.
ok(route({ role: 'debugger', ask: { id: 'a5', text: '?' } }, new Set()).chat,
   'an unclaimed role reaches the chat even when it is one that usually has a pane');

if (fails.length) { fails.forEach(f => console.error('specialist_ask_routing:', f)); process.exit(1); }
console.log('specialist_ask_routing: ok');
