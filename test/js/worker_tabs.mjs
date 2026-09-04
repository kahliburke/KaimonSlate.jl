// Asserts the worker popup's tab strip from workers.js — which workers get a visible tab, and which
// fold into the overflow.
//
// The property that matters is BOUNDING: a warm pool means the tab count cannot track the worker
// count, so tabs are severity-ranked with a `+N ▾` overflow (the same shape the topbar pill uses).
// An unwell worker must always hold a visible tab — a tab you cannot see reports nothing, which
// defeats the reason tabs beat the dropdown. The open worker keeps its tab too: you are reading it.
//
//   node test/js/worker_tabs.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'workers.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('worker_tabs: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('worker_tabs: unbalanced braces in ' + name); process.exit(2);
}
const constOf = name => {
  const m = new RegExp('^const ' + name + ' = (\\d+)', 'm').exec(src);
  if (!m) { console.error('worker_tabs: could not locate const ' + name); process.exit(2); }
  return Number(m[1]);
};
const MAX = constOf('_WP_TABS_MAX');

// `_wpPaintTabs` writes DOM, so the selection rule is re-derived here from the same inputs it uses:
// `_wpSeverity` (sliced from the source, so a change to the ranking is caught) plus the max.
const severity = new Function('_wpLive', `${sliceFn('_wpSeverity')}\n  return _wpSeverity;`)({});
function shownTabs(ws, open) {
  const ranked = ws.slice().sort((a, b) => severity(b) - severity(a));
  const shown = ranked.slice(0, MAX);
  if (!shown.some(w => (w.side || '') === open)) {
    const cur = ranked.find(w => (w.side || '') === open);
    if (cur) shown[shown.length - 1] = cur;
  }
  return { shown, rest: ranked.filter(w => !shown.includes(w)) };
}

const fails = [];
const eq = (label, got, want) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) fails.push(`${label}: ${a} (expected ${b})`);
};
const W = (side, status) => ({ side, host: side ? 'h' : '', connected: status !== 'disconnected', status });
const sides = list => list.map(w => w.side);

// Severity ordering is the whole basis of the selection: 4 disconnected · 3 degraded · 2 connecting ·
// 1 running · 0 idle.
eq('disconnected outranks degraded', severity(W('a', 'disconnected')) > severity(W('b', 'degraded')), true);
eq('degraded outranks connecting', severity(W('a', 'degraded')) > severity(W('b', 'connecting')), true);
eq('connecting outranks idle', severity(W('a', 'connecting')) > severity(W('b', 'ok')), true);

// Under the cap every worker gets a tab and nothing overflows.
{
  const ws = [W('', 'ok'), W('r1', 'ok')];
  const { shown, rest } = shownTabs(ws, 'r1');
  eq('small set: all shown', shown.length, 2);
  eq('small set: no overflow', rest.length, 0);
}

// Over the cap the strip stays bounded, and the unwell worker is on it.
{
  const ws = [W('', 'ok'), W('a', 'ok'), W('b', 'ok'), W('c', 'ok'), W('d', 'degraded'), W('e', 'ok')];
  const { shown, rest } = shownTabs(ws, '');
  eq('bounded to the cap', shown.length, MAX);
  eq('the rest overflow', rest.length, ws.length - MAX);
  eq('degraded leads', shown[0].side, 'd');
  eq('unwell worker is visible', shown.some(w => w.side === 'd'), true);
}

// The worker you are READING keeps its tab even when every other worker outranks it.
{
  const ws = [W('', 'disconnected'), W('a', 'disconnected'), W('b', 'degraded'), W('c', 'degraded'),
              W('d', 'degraded'), W('quiet', 'ok')];
  const { shown, rest } = shownTabs(ws, 'quiet');
  eq('open worker is shown', shown.some(w => w.side === 'quiet'), true);
  eq('still bounded', shown.length, MAX);
  eq('open worker is not also in the overflow', rest.some(w => w.side === 'quiet'), false);
  // …and it displaces exactly one, so the most urgent are still there.
  eq('most urgent retained', sides(shown).includes('') && sides(shown).includes('a'), true);
}

if (fails.length) { console.error('worker_tabs FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('worker_tabs OK');
