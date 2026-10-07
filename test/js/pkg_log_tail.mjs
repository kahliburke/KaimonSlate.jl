// `_lastPkgLines` (errors.js) picks the tail of Pkg's output for the blocking install modal, and the
// modal renders those lines through `slateAnsiHtml`. So the lines must come back with their ANSI
// INTACT, while the matching and trimming that selects them must look at the escape-stripped text:
// Pkg writes SGR around the package name and the counter, which is exactly where the patterns look.
//
// The real functions are read from source — a restated copy of either could agree with itself while
// the page showed `[32m` as text, which is the bug this pins.
//
//   node test/js/pkg_log_tail.mjs      # exit 0 = pass, 1 = mismatch, 2 = harness failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const js = n => readFileSync(join(root, 'src', 'assets', 'js', n), 'utf8');

let bad = 0;
const fail = m => { console.error('pkg_log_tail: ' + m); bad++; };
const eq = (got, want, m) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) fail(`${m}: got ${a}, want ${b}`);
};

globalThis.window = globalThis;
const escSrc = /window\.slateEscHtml\s*=[\s\S]*?;\n/.exec(js('esc.js'));
if (!escSrc) { console.error('pkg_log_tail: could not read slateEscHtml from esc.js'); process.exit(2); }
(0, eval)(escSrc[0]);
(0, eval)(js('ansi.js'));                       // slateAnsiText + slateAnsiHtml, the real ones

const errs = js('errors.js');
const m = /const _PKG_LOG_LINES[\s\S]*?\nfunction _lastPkgLines\(log, n\) \{[\s\S]*?\n\}/.exec(errs);
// (the slice above carries `_trimPkgMargin` and its two regexes with it)
if (!m) { console.error('pkg_log_tail: _lastPkgLines is gone from errors.js'); process.exit(2); }
let _PKG_LOG_LINES, _lastPkgLines;
try {
  ({ _PKG_LOG_LINES, _lastPkgLines } =
    (0, eval)('(function(){' + m[0] + '\nreturn { _PKG_LOG_LINES, _lastPkgLines }; })')());
} catch (e) { console.error('pkg_log_tail: could not evaluate _lastPkgLines: ' + e.message); process.exit(2); }

const E = '\x1b';
const dflt = _PKG_LOG_LINES;

// ── a real precompile tail: SGR around the names, box-drawing in the margin ────────────────────────
{
  const log = [
    'worker booted',
    `  ${E}[32m${E}[1mResolving${E}[22m${E}[39m package versions...`,
    `  ${E}[32m${E}[1mInstalled${E}[22m${E}[39m Example ─ v0.5.5`,
    `${E}[32m  ✓ ${E}[39mExample`,
    `${E}[32m  ✓ ${E}[39mSomethingElse`,
    `  ${E}[32m${E}[1m1 dependency${E}[22m${E}[39m successfully precompiled in 3 seconds`,
  ].join('\n');
  const out = _lastPkgLines(log);
  eq(out.length, dflt, 'returns the default number of lines');
  // The escapes survive: this is what makes the modal colour it instead of printing the codes.
  if (!out.every(l => l.includes(E))) fail('lines came back with their ANSI stripped');
  eq(window.slateAnsiText(out[0]), 'Installed Example ─ v0.5.5', 'first kept line, stripped');
  eq(window.slateAnsiText(out[1]), '✓ Example', 'a ✓ line matched despite an escape before the name');
  eq(window.slateAnsiText(out[3]), '1 dependency successfully precompiled in 3 seconds', 'last line');
  // …and rendering one yields spans, with no escape left as text.
  const h = window.slateAnsiHtml(out[1]);
  if (h.includes(E) || h.includes('[32m')) fail('rendered line still carries the escape: ' + h);
  if (!h.includes('<span')) fail('rendered line has no colour span: ' + h);
}

// ── selection: Pkg activity wins over unrelated worker chatter ─────────────────────────────────────
{
  const log = ['slate eval: ran cell', `${E}[36mResolving${E}[39m`, 'gate connect: reached worker',
               'slate eval: ran cell', '✓ Foo'].join('\n');
  eq(_lastPkgLines(log).map(l => window.slateAnsiText(l)), ['Resolving', '✓ Foo'],
     'non-Pkg lines are dropped even though they are more recent');
}

// ── nothing matched: fall back to the tail rather than showing an empty card ───────────────────────
{
  eq(_lastPkgLines('alpha\nbeta\ngamma\ndelta\nepsilon', 2).map(s => window.slateAnsiText(s)),
     ['delta', 'epsilon'], 'falls back to the last lines when no Pkg line matched');
  eq(_lastPkgLines(''), [], 'empty log');
  eq(_lastPkgLines(null), [], 'no log');
  eq(_lastPkgLines('\n  \n│ │\n'), [], 'a log of only blanks and box-drawing');
}

// ── the baseline that keeps an earlier log out of this install's window ────────────────────────────
// `startPkgInstall` slices the cumulative worker log from the last newline present when the modal
// opened. Pinned here because the slice point is what makes the card start empty: the lines already
// in the log are earlier work, and showing them reads as progress on an install that has not begun.
{
  const before = 'slate eval: ran cell\n✓ OldPackage\n';
  const baseOf = log => log.lastIndexOf('\n') + 1;
  eq(_lastPkgLines(before.slice(baseOf(before))), [], 'nothing new yet, so nothing is shown');
  const after = before + '  Resolving package versions...\n  ✓ NewPackage\n';
  eq(_lastPkgLines(after.slice(baseOf(before))).map(s => window.slateAnsiText(s)),
     ['Resolving package versions...', '✓ NewPackage'], 'only lines written after the baseline');
  // A partial trailing line at open is new content, not something to show from its middle.
  const partial = 'slate eval: ran cell\n  Resolv';
  const grown = partial + 'ing package versions...\n';
  eq(_lastPkgLines(grown.slice(baseOf(partial))).map(s => window.slateAnsiText(s)),
     ['Resolving package versions...'], 'a line in flight at open is shown whole, once');
}

// ── a line shorter than the window, and trimming ───────────────────────────────────────────────────
{
  const out = _lastPkgLines('  │ Installed Foo │  ');
  eq(out.length, 1, 'one line in, one line out');
  eq(window.slateAnsiText(out[0]), 'Installed Foo', 'margin whitespace and box-drawing trimmed');
}

if (!bad) console.log('pkg_log_tail: ok');
process.exit(bad ? 1 : 0);
