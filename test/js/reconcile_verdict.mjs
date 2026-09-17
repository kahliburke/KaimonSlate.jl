// Asserts `reconcileVerdict` from cellops.js — what a state push means for one cell's open editor.
//
// This decision is why an agent gets blamed for your own keystroke. It compares the incoming source
// against the editor's buffer and the baseline the editor was last in agreement with, and a divergence
// from BOTH is what it calls an external edit. Get it wrong in the safe direction and a genuine
// external change silently overwrites unsaved work; wrong in the other and the notebook accuses an
// agent, a file watcher or another tab of a change the user just asked for.
//
// It has been wrong three times, and until it was lifted out of the render effect no test could reach
// it. The cases below are the whole truth table, including the ones that only show up with a web cell,
// where the editor's text is three panes REASSEMBLED and so can differ from the stored source by
// nothing more than a section the panes drop.
//
//   node test/js/reconcile_verdict.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'cellops.js'), 'utf8');

// Brace counting has to start at the BODY, not at the first `{` in the file order: this function takes
// a destructured options object, so the first brace after its name opens the PARAMETER list and
// closing on it slices off the signature alone.
function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('reconcile_verdict: could not locate ' + name); process.exit(2); }
  let paren = 0, body = -1;
  for (let i = src.indexOf('(', start); i < src.length; i++) {
    if (src[i] === '(') paren++;
    else if (src[i] === ')' && --paren === 0) { body = src.indexOf('{', i); break; }
  }
  if (body < 0) { console.error('reconcile_verdict: no body for ' + name); process.exit(2); }
  let depth = 0;
  for (let i = body; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('reconcile_verdict: unbalanced braces in ' + name); process.exit(2);
}
const verdict = new Function(`${sliceFn('reconcileVerdict')} return reconcileVerdict;`)();

let bad = 0;
const is = (what, got, want) => {
  if (got !== want) { console.error(`reconcile_verdict: ${what}\n  got  ${got}\n  want ${want}`); bad++; }
};
// Trailing-whitespace-insensitive, the way the real caller compares: CM6 and the server disagree about
// a lone trailing newline, and that is not an edit.
const eq = (a, b) => String(a == null ? '' : a).replace(/\s+$/, '') === String(b == null ? '' : b).replace(/\s+$/, '');
const V = o => verdict({ eq, ...o });

// ── The server's source did not move ──────────────────────────────────────────
// Nothing to decide, whatever the editor holds. A cell with unsaved edits is left alone precisely so
// that typing does not fight the render loop.
is('unchanged, clean editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'a', hash: 'h1', mine: 'a', hasEditor: true }), 'idle');
is('unchanged, dirty editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'a', hash: 'h1', mine: 'a + typed', hasEditor: true }), 'idle');
// The hash is authoritative when both sides carry one. Equal hashes mean unmoved even if the strings
// differ, which is what keeps a cosmetic re-serialisation from reading as an edit.
is('equal hashes beat differing strings',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'a ', hash: 'h1', mine: 'a', hasEditor: true }), 'idle');

// ── It moved, and no editor is mounted ────────────────────────────────────────
// An unhydrated cell has no local edits by definition, so there is nothing to lose; only its preview
// text needs to keep up.
is('moved, no editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: null, hasEditor: false }), 'placeholder');

// ── It moved, and the editor was in agreement with the old source ─────────────
// The user has typed nothing, so adopting the change is free. This is the path an ordinary agent edit
// takes, and it must NOT be a conflict.
is('agent edit, clean editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: 'a', hasEditor: true }), 'forward');
is('clean editor differing only by trailing newline',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: 'a\n', hasEditor: true }), 'forward');

// ── It moved, and the editor already holds exactly the new text ───────────────
// The action that moved the server came from THIS tab and the editor was told first, which is what
// `rebaselineAll` arranges for undo, Replace All, a timeline restore and a kind change. Without this
// case those all read as conflicts, which is the bug that keeps coming back.
is('this tab already applied it',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: 'b', hasEditor: true }), 'settled');
is('…and trailing whitespace does not unsettle it',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: 'b\n', hasEditor: true }), 'settled');

// ── It moved, the editor has local edits, and they differ ─────────────────────
// The only genuine conflict: two sources of truth, and the user has to pick.
is('both changed',
   V({ prevSrc: 'a', prevHash: 'h1', source: 'b', hash: 'h2', mine: 'a + typed', hasEditor: true }), 'conflict');

// ── Web cells ─────────────────────────────────────────────────────────────────
// A web cell's editor text is its panes REASSEMBLED into an `@web(...)` skin, so `mine` can differ
// from the stored source by a whole section. An external edit that ADDS a pane is the case that
// matters: the editor is clean against its baseline, so it must fast-forward and let `edSetText`
// mount the new pane, not stop and ask.
const oneP = '@web(js"""\nORIGINAL\n""")';
const twoP = '@web(html"""\n<p>HI</p>\n""",\njs"""\nORIGINAL\n""")';
is('external edit adds a pane to a clean web cell',
   V({ prevSrc: oneP, prevHash: 'h1', source: twoP, hash: 'h2', mine: oneP, hasEditor: true }), 'forward');
is('external edit adds a pane while the user was typing',
   V({ prevSrc: oneP, prevHash: 'h1', source: twoP, hash: 'h2',
       mine: '@web(js"""\nTYPED\n""")', hasEditor: true }), 'conflict');
// A kind change into web now stores the skin the panes reassemble (`set_kind!`), so the editor and
// the source agree the instant it lands. Storing the body raw made this a conflict, and made the cell
// read as `edited` with nothing typed.
is('code → web, source stored as the skin the panes produce',
   V({ prevSrc: 'y = 2', prevHash: 'h1', source: '@web(html"""\ny = 2\n""")', hash: 'h2',
       mine: '@web(html"""\ny = 2\n""")', hasEditor: true }), 'settled');
is('code → web, source stored raw (the old behaviour) is a conflict',
   V({ prevSrc: 'y = 2', prevHash: 'h1', source: 'y = 2', hash: 'h2',
       mine: '@web(html"""\ny = 2\n""")', hasEditor: true }), 'conflict');

// ── States that should never be reachable, and must not throw ─────────────────
// A push carrying an empty source for a cell that has content would poison the baseline on the very
// next pass. Whether that can happen is unresolved; what is pinned here is that it reads as an
// ordinary move rather than as something quietly special.
is('empty incoming source against a clean editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: '', hash: 'h0', mine: 'a', hasEditor: true }), 'forward');
is('empty incoming source against a dirty editor',
   V({ prevSrc: 'a', prevHash: 'h1', source: '', hash: 'h0', mine: 'typed', hasEditor: true }), 'conflict');
// No hash on either side (a state from before the hash existed) falls back to the string compare.
is('no hashes, unchanged', V({ prevSrc: 'a', source: 'a', mine: 'a', hasEditor: true }), 'idle');
is('no hashes, moved, clean', V({ prevSrc: 'a', source: 'b', mine: 'a', hasEditor: true }), 'forward');
// One side missing a hash must not be read as "unchanged" — that would swallow a real edit.
is('only the incoming side has a hash',
   V({ prevSrc: 'a', prevHash: null, source: 'b', hash: 'h2', mine: 'a', hasEditor: true }), 'forward');
// A brand-new cell has no baseline at all.
is('no baseline yet', V({ prevSrc: undefined, source: 'new', mine: '', hasEditor: true }), 'forward');

if (bad) process.exit(1);
console.log('reconcile_verdict: ok');
