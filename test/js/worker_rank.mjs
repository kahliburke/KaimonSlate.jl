// Asserts the severity ranking in workers.js: the order of the worker dock's list and of the pill's
// list, and which worker the topbar pill shows. The most urgent worker comes first, so a warm pool's
// calm workers never push an unwell one out of sight.
//
//   node test/js/worker_rank.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'workers.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('worker_rank: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('worker_rank: unbalanced braces in ' + name); process.exit(2);
}
// `_wpSeverity` reads the shared worker model for a worker's health, so the REAL model goes in
// rather than a stub: a stub would let the ranking and the definition of `status` drift apart, which
// is the class of bug the model was introduced to end. model.js is a classic script, so evaluating
// it is all it takes.
const modelSrc = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'model.js'), 'utf8');
globalThis.window = globalThis.window || {};
try { (0, eval)(modelSrc); } catch (e) {
  console.error('worker_rank: could not evaluate model.js —', e.message);
  process.exit(2);
}
if (!globalThis.window.slateModel) {
  console.error('worker_rank: model.js did not define window.slateModel'); process.exit(2);
}

// `_wpPaintList` writes DOM, so its ordering is re-derived here from `_wpSeverity`, sliced from the
// source so a change to the ranking is caught.
const severity = new Function('_wpLive', `${sliceFn('_wpSeverity')}\n  return _wpSeverity;`)({});
const ranked = ws => ws.slice().sort((a, b) => severity(b) - severity(a));

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

// A large pool lists every worker, the unwell ones first and the calm ones after in their own order.
{
  const ws = [W('', 'ok'), W('a', 'ok'), W('b', 'disconnected'), W('c', 'ok'), W('d', 'degraded'), W('e', 'connecting')];
  const r = sides(ranked(ws));
  eq('every worker listed', r.length, ws.length);
  eq('most urgent first', r.slice(0, 3), ['b', 'd', 'e']);
  eq('calm ones keep their order', r.slice(3), ['', 'a', 'c']);
}

if (fails.length) { console.error('worker_rank FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('worker_rank OK');
