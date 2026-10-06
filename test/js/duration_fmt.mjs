// Asserts that cell durations are written by the one duration formatter, and that the value picks the
// unit. A cell header used to print raw milliseconds, so a half-minute run read as "32512 ms".
//
//   node test/js/duration_fmt.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const jsdir = join(here, '..', '..', 'src', 'assets', 'js');
let bad = 0;
const fail = m => { console.error('duration_fmt: ' + m); bad++; };

// ── 1. No cell duration is written by hand ───────────────────────────────────────
// The hand-written form appended the unit to the raw number: `c.duration + ' ms'` for a finished cell,
// and `Math.round(now() - t) + ' ms'` for the clock of a running one.
const HANDROLLED = /(\.duration|now\(\)\s*-\s*\w+\))\s*\)?\s*\+\s*['"`]\s*ms\b/;
const offenders = [];
for (const f of readdirSync(jsdir).filter(f => f.endsWith('.js') && f !== 'cm6.bundle.js')) {
  if (HANDROLLED.test(readFileSync(join(jsdir, f), 'utf8'))) offenders.push(f);
}
if (offenders.length) {
  fail(`cell durations are formatted by hand in ${JSON.stringify(offenders)}; use window.slateDuration `
     + `(platform.js)`);
}

// ── 2. The value picks the unit and the precision ────────────────────────────────
const platform = readFileSync(join(jsdir, 'platform.js'), 'utf8');
const m = platform.match(/window\.slateDuration\s*=\s*(function[\s\S]*?\n};)/);
if (!m) { console.error('duration_fmt: could not slice slateDuration from platform.js'); process.exit(2); }
const fmt = new Function(m[1].replace(/^function\s+slateDuration/, 'return function slateDuration'))();

const cases = [
  [0, '0 ms'], [12, '12 ms'], [999, '999 ms'],
  [999.6, '1.0 s'],                      // rounds into the next unit rather than printing 1000 ms
  [4230, '4.2 s'],                       // under ten seconds keeps a decimal
  [9949, '9.9 s'], [9950, '10 s'],
  [32512, '33 s'],                       // the header that read "32512 ms"
  [59499, '59 s'], [59500, '1m 00s'],    // a minute is never "60 s"
  [125000, '2m 05s'],                    // seconds keep two digits, so a running clock keeps its width
  [3599499, '59m 59s'], [3599500, '1h 00m'],
  [3720000, '1h 02m'],
  [-5, '0 ms'], [NaN, '0 ms'], [null, '0 ms'], [undefined, '0 ms'],
];
for (const [input, want] of cases) {
  const got = fmt(input);
  if (got !== want) fail(`slateDuration(${String(input)}) === ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
// Every form fits the reserved width of the header's time slot (`.cdur`, 9ch) below 100 minutes.
for (const ms of [999, 9949, 59499, 5999000]) {
  if (fmt(ms).length > 9) fail(`slateDuration(${ms}) is wider than the time slot: ${fmt(ms)}`);
}

if (bad) { console.error(`duration_fmt: ${bad} check(s) failed`); process.exit(1); }
console.log('duration_fmt: ok');
