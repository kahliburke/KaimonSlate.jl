// Parity check for `Slate.replay`, which exists TWICE: once in src/assets/js/core.js (the live shell
// and any page that loads it) and once, hand-mirrored, inside a Julia string in src/server_export.jl
// (the static page, which cannot load core.js). Both are told to be copies of each other and nothing
// enforced it — so a fix applied to one and not the other shows up as an exported control that
// silently picks the wrong column, which is exactly the failure nobody notices.
//
// The matching half is pure (no DOM): `same` decides equality across the shapes a control's key can
// take, and `index` turns a key into a column. Those are the subtle parts and the ones tested here.
// `read`/`mirror`/`listen` need a document and are covered by driving a real exported page.
//
//   node test/js/replay_parity.mjs      # exit 0 = parity, 1 = divergence, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, objectLiteralAfter, loadReplayCopies } from './_replay_src.mjs';

const core = readFileSync(join(ROOT, 'src', 'assets', 'js', 'core.js'), 'utf8');
const { live, stat } = loadReplayCopies();

// Each case is a domain as `bind_domain` would ship it, plus the key a control reports, plus the
// column that must be selected. Both copies must agree with the expectation AND with each other.
const cases = [
  // A DOM control reports "8" as a string and Julia may have written 8.0 — text comparison would miss.
  { what: 'numeric domain, string key', domain: [1, 3, 5, 7], key: '5', want: 2 },
  { what: 'float domain, integer key', domain: [0.0, 0.5, 1.0], key: '1', want: 2 },
  // A strided export ships every n-th slider position while the slider keeps its original step, so
  // most of the track has no exact column. Snapping keeps the control continuous rather than dead.
  { what: 'nearest on a strided slider', domain: [1, 3, 5, 7], key: 4, want: 1 },
  { what: 'nearest past the end', domain: [1, 3, 5, 7], key: 99, want: 3 },
  // Categorical: an unknown option is a miss, never a nearest-guess.
  { what: 'categorical hit', domain: ['a', 'b', 'c'], key: 'b', want: 1 },
  { what: 'categorical miss', domain: ['a', 'b', 'c'], key: 'zz', want: -1 },
  { what: 'booleans', domain: [false, true], key: true, want: 1 },
  { what: 'boolean from a string', domain: [false, true], key: 'false', want: 0 },
  // TableSelect: row indices, 0 = nothing selected.
  { what: 'table row index', domain: [0, 1, 2, 3], key: 2, want: 2 },
  { what: 'table no selection', domain: [0, 1, 2, 3], key: 0, want: 0 },
  // RangeSlider: ordered pairs, compared elementwise. A crossed pair is not in the domain and must
  // NOT fall back to a nearest scalar — there is no meaningful "closest pair" to guess at.
  { what: 'range pair', domain: [[0, 0], [0, 1], [1, 1]], key: [0, 1], want: 1 },
  { what: 'range pair miss', domain: [[0, 0], [0, 1], [1, 1]], key: [1, 0], want: -1 },
  { what: 'range pair from strings', domain: [[0, 0], [0, 1], [1, 1]], key: ['1', '1'], want: 2 },
  // MultiSelect: the power set, in option order — so the key needs no sorting to match.
  { what: 'empty subset', domain: [[], ['a'], ['b'], ['a', 'b']], key: [], want: 0 },
  { what: 'full subset', domain: [[], ['a'], ['b'], ['a', 'b']], key: ['a', 'b'], want: 3 },
  { what: 'subset order matters', domain: [[], ['a'], ['b'], ['a', 'b']], key: ['b', 'a'], want: -1 },
  // A scalar key against a composite domain must not crash or coerce its way to a false hit.
  { what: 'scalar against pairs', domain: [[0, 0], [1, 1]], key: 1, want: -1 },
];

const fails = [];
for (const c of cases) {
  const a = live.index(c.domain, c.key);
  const b = stat.index(c.domain, c.key);
  if (a !== b) fails.push(`DIVERGED  ${c.what}: core.js -> ${a}, server_export.jl -> ${b}`);
  else if (a !== c.want) fails.push(`WRONG     ${c.what}: both -> ${a}, expected ${c.want}`);
}

// `truthy` and `label` are used by both copies for the readout and the checkbox path.
for (const [v, want] of [[true, true], ['true', true], [1, true], ['1', true], [false, false], ['no', false]]) {
  if (live.truthy(v) !== want || stat.truthy(v) !== want)
    fails.push(`truthy(${JSON.stringify(v)}): core=${live.truthy(v)} export=${stat.truthy(v)} expected ${want}`);
}
if (live.label([1, 2]) !== stat.label([1, 2])) fails.push('label diverged on a pair');

// `_vmPiecewise` decides whether a replayed figure's colour scale is refitted to the slice on
// screen. Getting it wrong is not silent-total-failure — it is a mis-scaled legend — but it guards a
// deliberate authored `pieces` map from being quietly overwritten between control positions, which
// is the kind of thing nobody reports and everybody misreads.
{
  const body = objectLiteralAfter(core, 'function _vmPiecewise(', '_vmPiecewise in core.js');
  const vmPiecewise = new Function('vm', body);
  const cases = [
    [{ min: 0, max: 5 }, false],                       // continuous → refit
    [{ pieces: [{ value: 0 }] }, true],                // authored pieces → leave alone
    [{ type: 'piecewise' }, true],
    [[{ min: 0 }, { pieces: [] }], true],              // a LIST is piecewise if any entry is
    [[{ min: 0 }, { max: 9 }], false],
  ];
  for (const [vm, want] of cases) {
    const got = vmPiecewise(vm);
    if (got !== want) fails.push(`_vmPiecewise(${JSON.stringify(vm)}) → ${got}, expected ${want}`);
  }
}

if (fails.length) {
  console.error('replay_parity: ' + fails.length + ' failure(s)');
  for (const f of fails) console.error('  ' + f);
  process.exit(1);
}
console.log(`replay_parity: ${cases.length} cases agree across both copies`);
