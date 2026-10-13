// `slateSetBind` (core.js) sends a control's value to the server. While one POST is in flight it
// holds only the last value of a burst, so a fast drag does not build a backlog. When the held
// value and the new value are both plain objects, the new keys merge into the held object.
//
// The real function is extracted and evaluated, with stand-ins for `api`, `_bindOwner` and the
// ack handler.
//
//   node test/js/setbind_coalesce.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const CORE = join(here, '..', '..', 'src', 'assets', 'js', 'core.js');

let bad = 0;
const fail = m => { console.error('setbind_coalesce: ' + m); bad++; };
const eq = (got, want, m) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fail(`${m}: got ${g}, want ${w}`);
};

const src = readFileSync(CORE, 'utf8');
const m = src.match(/\nconst _extBindQueue = [\s\S]*?\nfunction slateSetBind\(name, value\) \{[\s\S]*?\n\}/);
if (!m) { console.error('setbind_coalesce: slateSetBind is gone from core.js'); process.exit(2); }

// Each POST stays open until the test resolves it, so the test sets the order of events.
let posts = [];
const api = (method, url, body) => new Promise(res => posts.push({ url, body, res }));
const _bindOwner = name => (name === 'missing' ? null : { cell: 'c_' + name, value: null });
const window = { slateApplyAck: () => {} };

let setBind;
try {
  setBind = (0, eval)('(function (api, _bindOwner, window) {' + m[0] + '\nreturn slateSetBind; })')(
    api, _bindOwner, window);
} catch (e) {
  console.error('setbind_coalesce: could not evaluate slateSetBind: ' + e.message);
  process.exit(2);
}

const flush = () => new Promise(r => setTimeout(r, 0));
const finish = async (ack) => { const p = posts.shift(); p.res(ack); await flush(); };

// ── a burst sends the first value, then only the last ────────────────────────────────────────────
{
  posts = [];
  const first = setBind('x', 1);
  for (let i = 2; i <= 50; i++) setBind('x', i);
  eq(posts.map(p => p.body.value), [1], 'only the first value is in flight');
  eq(posts[0].url, '/api/bind/c_x', 'POST goes to the declaring cell');
  await finish({ revs: {} });
  eq(await first, { revs: {} }, 'the first call resolves to its ack');
  eq(posts.map(p => p.body.value), [50], 'then only the last value of the burst');
  await finish({ revs: {} });
  eq(posts.length, 0, 'nothing more after the burst');
}

// ── plain objects merge while held ────────────────────────────────────────────────────────────────
{
  posts = [];
  setBind('o', { a: 0 });
  setBind('o', { a: 1, b: 1 });
  setBind('o', { b: 2 });
  setBind('o', { c: 3 });
  await finish({});
  eq(posts.map(p => p.body.value), [{ a: 1, b: 2, c: 3 }], 'held objects merge, newer keys win');
  await finish({});
}

// ── arrays and mixed values: last one wins ────────────────────────────────────────────────────────
{
  posts = [];
  setBind('r', [0, 1]);
  setBind('r', [1, 2]);
  setBind('r', [3, 4]);
  await finish({});
  eq(posts.map(p => p.body.value), [[3, 4]], 'arrays replace, not merge');
  await finish({});

  setBind('r', 'busy');
  setBind('r', { a: 1 });
  setBind('r', 7);
  await finish({});
  eq(posts.map(p => p.body.value), [7], 'an object followed by a scalar keeps the scalar');
  await finish({});
}

// ── an unknown control sends nothing ──────────────────────────────────────────────────────────────
{
  posts = [];
  eq(await setBind('missing', 1), null, 'unknown control resolves null');
  eq(posts.length, 0, 'no POST for an unknown control');
}

process.exit(bad ? 1 : 0);
