// Asserts that one tool call makes one row in the chat panel, however it is reported.
//
// A call the notebook's own agent makes arrives TWICE. Once as its ACP `tool_use` event, carrying a
// `toolCallId`. Once from the tab itself: `_slateEvalJs` calls `logAgentAction` for every
// `slate.eval_js` that lands there, which is the path that exists so an agent OUTSIDE this
// notebook's chat can be seen acting on it at all. The two share no id — one has ACP's and the
// other has none — so the panel rendered the same call twice, code and all.
//
// The two are matched on the code being run. Order is not fixed: the tab can get there before the
// authoritative input has streamed, so both directions are pinned here.
//
//   node test/js/agent_toolrow.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'agent.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('agent_toolrow: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('agent_toolrow: unbalanced braces in ' + name); process.exit(2);
}

// The upsert under test, lifted out of `agentEvent`'s `tool_use` branch. Sliced rather than
// restated: a stand-in would let the real one drift while this kept passing, which is the whole
// failure mode here — two code paths that agreed in the test and not in the panel.
const branch = (() => {
  const k = src.indexOf("} else if (k === 'tool_use') {");
  const end = src.indexOf("} else if (k === 'tool_input_delta') {", k);
  if (k < 0 || end < 0) { console.error('agent_toolrow: could not locate the tool_use branch'); process.exit(2); }
  return src.slice(src.indexOf('{', k + 10) + 1, end);
})();

const harness = new Function('_extractCode', `
  const agentMsgs = [];
  const _TOOL_LABEL = { eval_js: '\u{1F9E9} eval JS' };
  ${sliceFn('_bareTool')}
  ${sliceFn('_prettyTool')}
  const _argCid = () => '';
  ${sliceFn('logAgentAction').replace('renderAgentMsgs();', '')}
  function toolUse(d, env) {
    const crew = '';
    ${branch}
  }
  return { agentMsgs, logAgentAction, toolUse };
`);

// The real `_extractCode` reads the field an agent is writing out of raw JSON; here the calls carry
// their code directly, so the shape it is handed is the shape it returns.
const mk = () => harness(s => { try { return JSON.parse(s).code || ''; } catch { return ''; } });

const fails = [];
const eq = (got, want, what) => { if (got !== want) fails.push(`${what}: got ${got}, want ${want}`); };

const CODE = 'const c = window.charts["051565"][0]; c._api';
const call = (id, code) => ({ call: { toolCallId: id, title: 'slate_eval_js', rawInput: { code } } });

// ── The agent's event first, then the tab ───────────────────────────────────────────────────
{
  const H = mk();
  H.toolUse(call('t1', CODE), {});
  H.logAgentAction('🧩 eval JS', CODE);
  eq(H.agentMsgs.length, 1, 'tool_use then tab is one row');
  eq(H.agentMsgs[0].id, 't1', '…and it keeps the id the result will arrive under');
}

// ── The tab first, then the agent's event ───────────────────────────────────────────────────
// The tab can win: `tool_use` fires at call-begin and its authoritative input may land after the
// call has already reached the page.
{
  const H = mk();
  H.logAgentAction('🧩 eval JS', CODE);
  H.toolUse(call('t2', CODE), {});
  eq(H.agentMsgs.length, 1, 'tab then tool_use is one row');
  eq(H.agentMsgs[0].id, 't2', '…and the row is adopted, so the result can still find it');
}

// ── Two different calls stay two rows ───────────────────────────────────────────────────────
{
  const H = mk();
  H.toolUse(call('t3', CODE), {});
  H.toolUse(call('t4', CODE + '; 1 + 1'), {});
  eq(H.agentMsgs.length, 2, 'different code is a different call');
}

// ── A finished row is not adopted by the next call ──────────────────────────────────────────
// Running the same snippet twice is ordinary; the second must not land on the first's row.
{
  const H = mk();
  const first = H.logAgentAction('🧩 eval JS', CODE);
  first.done = true;
  H.toolUse(call('t5', CODE), {});
  eq(H.agentMsgs.length, 2, 'a completed row is left alone');
}

// ── An event with no id must not claim a row that has none ──────────────────────────────────
// `undefined === undefined` is what made every externally-driven action pile onto whichever row
// came first.
{
  const H = mk();
  H.logAgentAction('🧩 eval JS', 'alpha');
  H.toolUse({ call: { title: 'slate_eval_js', rawInput: { code: 'beta' } } }, {});
  eq(H.agentMsgs.length, 2, 'an id-less event does not adopt an unrelated row');
}

if (fails.length) { fails.forEach(f => console.error('agent_toolrow:', f)); process.exit(1); }
console.log('agent_toolrow: ok');
