// Asserts `window.slateAnsiHtml` (ansi.js) against the shared fixture in `ansi_cases.json`.
//
// The same corpus is asserted against `ReportRender._ansi_html` by test_render.jl, which is the
// whole point: the two renderers are deliberate mirrors — same class names, same xterm-256 mapping,
// same handling of malformed parameters — because ONE palette in the stylesheet has to style output
// coloured in Julia (a finished cell) and output coloured in the browser (a cell still running, the
// build log, the worker log). Nothing in either file forces that correspondence, so a fixture both
// sides must reproduce is what keeps them from drifting apart a colour at a time.
//
// The corpus has no apostrophes in it on purpose: `slateEscHtml` escapes `'` and render.jl's `_esc`
// does not. Both are safe in text and attribute context, so this is a difference nobody has to care
// about — but it would fail an exact comparison for a reason that has nothing to do with ANSI.
//
//   node test/js/ansi_html.mjs      # exit 0 = pass, 1 = mismatch, 2 = harness failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadEscHtml } from './_esc_src.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');

globalThis.window = globalThis;
// The real helper, not restated: this test compares ESCAPED output, so a stand-in that escaped
// differently would report a mismatch that does not exist. Where it lives is the loader's business,
// and knowing that here is how this file broke when it moved.
window.slateEscHtml = loadEscHtml();
(0, eval)(readFileSync(join(root, 'src', 'assets', 'js', 'ansi.js'), 'utf8'));

if (typeof window.slateAnsiHtml !== 'function') {
  console.error('ansi_html: ansi.js did not define slateAnsiHtml'); process.exit(2);
}

const cases = JSON.parse(readFileSync(join(here, 'ansi_cases.json'), 'utf8'));
if (!cases.length) { console.error('ansi_html: empty fixture'); process.exit(2); }

const fails = [];
for (const c of cases) {
  const got = window.slateAnsiHtml(c.in);
  if (got !== c.html) {
    fails.push(`input ${JSON.stringify(c.in)}\n    want ${JSON.stringify(c.html)}\n    got  ${JSON.stringify(got)}`);
  }
}

// `slateAnsiText` is the plain-text twin and has no Julia mirror, so it is pinned here: what it
// returns must be the fixture HTML with the markup gone, i.e. it strips exactly what the renderer
// turns into spans and nothing else.
const unesc = s => s.replace(/<[^>]*>/g, '')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&amp;/g, '&');
for (const c of cases) {
  const got = window.slateAnsiText(c.in);
  const want = unesc(c.html);
  if (got !== want) {
    fails.push(`slateAnsiText ${JSON.stringify(c.in)}\n    want ${JSON.stringify(want)}\n    got  ${JSON.stringify(got)}`);
  }
}

if (fails.length) {
  console.error(`ansi_html FAIL (${fails.length}):\n  ` + fails.join('\n  '));
  process.exit(1);
}
console.log(`ansi_html: ok (${cases.length} cases)`);
