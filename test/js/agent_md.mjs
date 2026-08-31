// Asserts `mdLite` from agent.js — the chat panel's markdown renderer. It is DOM-free, so we
// slice it out of the source and eval it with the two escaping helpers it calls.
//
// The regression that motivates most of this: mdLite stashes code/math spans behind placeholders
// and restores them at the end. When those placeholders were bare digits, the restore pass matched
// every number in the prose too, so an agent's measurements came out as "undefined" (or, when the
// digits happened to be a live stash index, as some unrelated code span). Numbers surviving a
// round-trip is the property under test.
//
//   node test/js/agent_md.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'agent.js'), 'utf8');

// Slice a `function name(…) { … }` declaration by matching braces.
function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('agent_md: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('agent_md: unbalanced braces in ' + name); process.exit(2);
}
// Slice a single-line `const name = …;` arrow.
function sliceConst(name) {
  const m = new RegExp('^const ' + name + ' = .*$', 'm').exec(src);
  if (!m) { console.error('agent_md: could not locate const ' + name); process.exit(2); }
  return m[0];
}

const mdLite = new Function(`
  ${sliceConst('_esca')}
  ${sliceConst('_urlScheme')}
  const _safeHref = u => {
    const sc = _urlScheme(u);
    if (sc && !['http', 'https', 'mailto'].includes(sc)) return '#';
    return String(u).replace(/"/g, '%22').replace(/'/g, '%27');
  };
  ${sliceFn('mdLite')}
  return mdLite;
`)();

const fails = [];
const eq = (label, got, want) => { if (got !== want) fails.push(`${label}:\n  got  ${got}\n  want ${want}`); };
const has = (label, got, want) => { if (!got.includes(want)) fails.push(`${label}:\n  got  ${got}\n  want to contain ${want}`); };
const hasNot = (label, got, bad) => { if (got.includes(bad)) fails.push(`${label}:\n  got  ${got}\n  must not contain ${bad}`); };

// ── Numbers survive the stash/restore round-trip ─────────────────────────────
eq('plain number', mdLite('there are 42 rows'), '<p>there are 42 rows</p>');
eq('decimal', mdLite('took 4.35 s'), '<p>took 4.35 s</p>');
eq('a line that is only a number', mdLite('42'), '<p>42</p>');
// The original failure, in full: measurements interleaved with the code spans that fill the stash.
{
  const got = mdLite('at n=200 M, `include` 4.35 s, 1.9 GiB (~9.40 GiB at 800 M, out of 64)');
  hasNot('measurements have no undefined', got, 'undefined');
  has('measurements keep their digits', got, 'n=200 M, <code>include</code> 4.35 s, 1.9 GiB (~9.40 GiB at 800 M, out of 64)');
}
// Digits inside a URL are part of the rendered HTML the restore pass scans, so guard them too.
has('link url digits', mdLite('[d](https://example.com/v2/p?id=42)'), 'href="https://example.com/v2/p?id=42"');
// Text can't forge a placeholder: a NUL in the source is stripped before anything is stashed,
// so a hand-crafted "sentinel 0 sentinel" resolves to nothing rather than stealing stash[0].
{
  const NUL = String.fromCharCode(0);
  const got = mdLite('forged ' + NUL + '0' + NUL + ' then `real`');
  hasNot('forged placeholder is inert', got, 'undefined');
  eq('forged placeholder keeps its digit', got, '<p>forged 0 then <code>real</code></p>');
}

// ── The stashed spans themselves still round-trip ────────────────────────────
eq('inline code', mdLite('use `f(x)` now'), '<p>use <code>f(x)</code> now</p>');
eq('fence', mdLite('```julia\nx = 100\n```'), '<pre class="apcode"><code>x = 100</code></pre>');
has('math is left raw for katex', mdLite('cost $O(n^2)$ here'), '$O(n^2)$');
eq('two spans keep their identities', mdLite('`a` and `b`'), '<p><code>a</code> and <code>b</code></p>');

// ── Markdown basics ──────────────────────────────────────────────────────────
eq('bold', mdLite('**hi** there'), '<p><strong>hi</strong> there</p>');
eq('heading', mdLite('## Title'), '<div class="apmd-h">Title</div>');
eq('bullets', mdLite('- a 10\n- b 20'), '<ul><li>a 10</li><li>b 20</li></ul>');
eq('escaping', mdLite('a <script> & b'), '<p>a &lt;script&gt; &amp; b</p>');
eq('null input', mdLite(null), '');

// ── GFM pipe tables ──────────────────────────────────────────────────────────
eq('table', mdLite('| a | b |\n|---|---|\n| 1 | 2 |'),
   '<table class="apmd-t"><thead><tr><th>a</th><th>b</th></tr></thead>' +
   '<tbody><tr><td>1</td><td>2</td></tr></tbody></table>');
eq('table without outer pipes', mdLite('a | b\n--- | ---\n1 | 2'),
   '<table class="apmd-t"><thead><tr><th>a</th><th>b</th></tr></thead>' +
   '<tbody><tr><td>1</td><td>2</td></tr></tbody></table>');
has('table alignment', mdLite('| a | b |\n|:--|--:|\n| 1 | 2 |'), '<th style="text-align:right">b</th>');
has('table cells take inline markup', mdLite('| a |\n|---|\n| `x` |'), '<td><code>x</code></td>');
has('empty cell', mdLite('| a | b |\n|---|---|\n| 1 | |'), '<td></td>');
// A pipe inside a code span is already stashed, so it can't be read as a column separator.
eq('pipe in code is not a table', mdLite('use `a | b` here'), '<p>use <code>a | b</code> here</p>');
// A lone pipe with no delimiter row underneath stays prose.
eq('pipe without delimiter row', mdLite('a | b'), '<p>a | b</p>');
// Prose either side of a table is not swallowed by it.
{
  const got = mdLite('before\n\n| a |\n|---|\n| 1 |\n\nafter');
  has('table keeps leading prose', got, '<p>before</p><table');
  has('table keeps trailing prose', got, '</table><p>after</p>');
}

if (fails.length) { console.error('agent_md FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('agent_md OK');
