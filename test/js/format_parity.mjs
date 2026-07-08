// JS half of the table-formatter parity check. Extracts the PURE formatter functions from core.js
// (the region between the "── Cell formatter" and "── end cell formatter" markers — they reference
// only each other, no DOM), then asserts `fmtCell` against the SAME golden fixture the Julia test
// uses (test/fixtures/format_cases.json). This is what keeps the two implementations in lock-step.
//
//   node test/js/format_parity.mjs      # exit 0 = parity, 1 = divergence, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const core = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'core.js'), 'utf8');

const START = '// ── Cell formatter';
const END = '// ── end cell formatter';
const si = core.indexOf(START), ei = core.indexOf(END);
if (si < 0 || ei < 0) {
  console.error('format_parity: could not locate formatter markers in core.js');
  process.exit(2);
}

// Evaluate the extracted region in an isolated scope and hand back `fmtCell`.
const fmtCell = new Function(core.slice(si, ei) + '\nreturn fmtCell;')();

const cases = JSON.parse(readFileSync(join(here, '..', 'fixtures', 'format_cases.json'), 'utf8'));
const fails = [];
for (const c of cases) {
  const got = fmtCell(c.value, c.format);
  if (got !== c.expected) {
    fails.push(`${JSON.stringify(c.value)} ${JSON.stringify(c.format)} -> ${JSON.stringify(got)} (expected ${JSON.stringify(c.expected)})`);
  }
}
if (fails.length) {
  console.error('format_parity FAIL:\n' + fails.join('\n'));
  process.exit(1);
}
console.log(`format_parity OK (${cases.length} cases)`);
