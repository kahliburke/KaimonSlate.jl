// Asserts there is ONE human byte formatter in the front end, and that the VALUE decides how it is
// rendered.
//
// It had been written eleven times across these files, each with its own cutoffs. Two of them
// collided on the global name `_fmtBytes`, so whichever script loaded last won and a panel rendered
// through a formatter its author never wrote; one floored at 1 KB, so 400 bytes read as bigger than
// it was; one spelled the unit `kB`. The rule they were all approximating is simply that the number
// picks the unit and the precision, so that is what the shared one does and what this pins.
//
//   node test/js/bytes_fmt.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const jsdir = join(here, '..', '..', 'src', 'assets', 'js');
let bad = 0;
const fail = m => { console.error('bytes_fmt: ' + m); bad++; };

// ── 1. Nobody rolls their own ────────────────────────────────────────────────────
// A hand-rolled one is recognisable by testing a raw power-of-1024 threshold next to a unit string.
// `core.js` is exempt: its `_bytes` is the `:bytes` TABLE COLUMN format, which takes its digit count
// from the author's column spec and is mirrored in Julia `format.jl` under a golden-fixture parity
// test (test/js/format_parity.mjs). Different contract, deliberately its own.
const HANDROLLED = /(1024|1048576|1073741824)[\s\S]{0,120}?['"`]\s*(B|KB|kB|MB|GB)\b/;
const offenders = [];
for (const f of readdirSync(jsdir).filter(f => f.endsWith('.js') && f !== 'cm6.bundle.js')) {
  if (f === 'core.js' || f === 'platform.js') continue;
  if (HANDROLLED.test(readFileSync(join(jsdir, f), 'utf8'))) offenders.push(f);
}
if (offenders.length) {
  fail(`byte sizes are formatted by hand in ${JSON.stringify(offenders)}; use window.slateBytes `
     + `(platform.js) — it is loaded by BOTH the front page and the notebook shell`);
}

// ── 2. It lives where every page can reach it ────────────────────────────────────
// The front page loads platform.js + its islands and NOT core.js, so a helper defined in core.js is
// reachable from the notebook shell alone. Two of the callers are front-page islands.
const platform = readFileSync(join(jsdir, 'platform.js'), 'utf8');
if (!/window\.slateBytes\s*=/.test(platform)) {
  console.error('bytes_fmt: window.slateBytes is not defined in platform.js'); process.exit(2);
}
for (const shell of ['index.html', 'notebook.html']) {
  const html = readFileSync(join(jsdir, '..', shell), 'utf8');
  if (!/assets\/js\/platform\.js/.test(html)) fail(`${shell} does not load platform.js`);
}

// ── 3. The value decides the unit and the precision ──────────────────────────────
const m = platform.match(/window\.slateBytes\s*=\s*(function[\s\S]*?\n};)/);
if (!m) { console.error('bytes_fmt: could not slice slateBytes'); process.exit(2); }
const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
const fmt = new Function('_SLATE_BYTE_UNITS',
  'const window = {};' + m[1].replace(/^function\s+slateBytes/, 'return function slateBytes'))(UNITS);

const cases = [
  [0, '0 B'], [512, '512 B'], [1023, '1023 B'],
  [1024, '1.0 KB'],                      // mantissa under 10 keeps a decimal
  [4300, '4.2 KB'],                      // 4.2 says something 4 does not
  [20480, '20 KB'],                      // mantissa over 10 does not
  [1048576, '1.0 MB'], [1073741824, '1.0 GB'],
  [5e12, '4.5 TB'],                      // beyond GB, which several copies could not reach
  [-2048, '-2.0 KB'],                    // signed
  [NaN, '0 B'], [null, '0 B'], [undefined, '0 B'],
];
for (const [input, want] of cases) {
  const got = fmt(input);
  if (got !== want) fail(`slateBytes(${String(input)}) === ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
// The dense variants differ only in spacing and unit width — never in the number.
if (fmt(4300, { compact: true }) !== '4.2KB') fail('compact should drop the space only');
if (fmt(4300, { letter: true }) !== '4.2K') fail('letter should shorten the unit only');
if (fmt(512, { letter: true }) !== '512B') fail('letter keeps B for whole bytes');
// A value never renders as a bare number with no unit, and a KB value never says `kB`.
for (const n of [0, 1, 1024, 1e9]) {
  if (!/[A-Z]B?$/.test(fmt(n))) fail(`slateBytes(${n}) has no unit: ${fmt(n)}`);
  if (/kB/.test(fmt(n))) fail(`slateBytes(${n}) uses the lowercase kB spelling`);
}

if (bad) { console.error(`bytes_fmt: ${bad} check(s) failed`); process.exit(1); }
console.log('bytes_fmt: ok');
