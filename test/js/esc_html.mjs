// Asserts there is ONE HTML escaper in the front end, and that it is correct for both text and
// attribute positions.
//
// It had been written thirteen times across these files in three coverages — `&<>`, `&<>"`, and
// `&<>"'` — and the narrow ones were reached by call sites that interpolate into ATTRIBUTE positions,
// where an unescaped `"` closes the attribute and everything after it is markup. The drift is the
// bug; a per-file copy is how the drift happens. So the check is structural: no module may define its
// own, and the shared one must cover all five characters and not print "null".
//
//   node test/js/esc_html.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadEscHtml } from './_esc_src.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const jsdir = join(here, '..', '..', 'src', 'assets', 'js');
let bad = 0;
const fail = m => { console.error('esc_html: ' + m); bad++; };

// ── 1. Exactly one definition, and it lives in core.js ───────────────────────────
// An escaper is recognisable by the entity it produces: nothing else in these files emits `&amp;`
// from a `replace`. cm6.bundle.js is vendored and not ours to police.
// Matched over the whole file, not line by line: a definition is routinely wrapped across two lines,
// and core.js's own is — a per-line test sees neither half and reports a clean sweep either way.
const DEFN = /replace\s*\([^;]{0,400}&amp;/;
const owners = [];
for (const f of readdirSync(jsdir).filter(f => f.endsWith('.js') && f !== 'cm6.bundle.js')) {
  if (DEFN.test(readFileSync(join(jsdir, f), 'utf8'))) owners.push(f);
}
const uniq = [...new Set(owners)];
if (uniq.length !== 1 || uniq[0] !== 'core.js') {
  fail(`HTML escaping is defined in ${JSON.stringify(uniq)}; it belongs only in core.js `
     + `(use window.slateEscHtml — see the note on its definition)`);
}

// ── 2. The shared one is correct ─────────────────────────────────────────────────
const escHtml = loadEscHtml();

const cases = [
  ['a & b', 'a &amp; b'],
  ['<script>', '&lt;script&gt;'],
  ['say "hi"', 'say &quot;hi&quot;'],       // attribute-terminating; the narrow copies missed this
  ["it's", 'it&#39;s'],                     // single-quoted attributes are used too
  ['plain', 'plain'],
  [null, ''],                               // not the literal "null"
  [undefined, ''],
  [42, '42'],
];
for (const [input, want] of cases) {
  const got = escHtml(input);
  if (got !== want) fail(`escHtml(${JSON.stringify(input)}) === ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}
// Escaping must be idempotent-safe in the sense that the ampersand goes FIRST — otherwise `<`
// becomes `&lt;` and then its own `&` is re-escaped into `&amp;lt;`, which renders as text.
if (escHtml('<') !== '&lt;') fail('ampersand is not replaced before the other entities');

if (bad) { console.error(`esc_html: ${bad} check(s) failed`); process.exit(1); }
console.log('esc_html: ok');
