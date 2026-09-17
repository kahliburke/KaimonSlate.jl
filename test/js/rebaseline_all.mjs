// Asserts `rebaselineAll` from cellops.js — what undo, redo, Replace All and a timeline restore do
// to open editors before the new state lands.
//
// Each of those rewrites cell sources and hands back the whole notebook. The per-cell diff in
// notebook.js then compares the incoming source against the editor's buffer and its stored
// baseline, and a divergence from both is exactly the shape of an EXTERNAL edit — so pressing ⌘Z
// with an uncommitted edit open accused an agent, a file watcher or another tab of having changed
// the cell. The fix is to tell the editor what it is about to become, which is what this does.
//
// Two properties, and the second is the one that makes it safe:
//   · a cell the action REWROTE ends with srcMap, the editor and the incoming source in agreement,
//     so the diff takes its fast-forward branch and the conflict branch is unreachable;
//   · a cell the action did NOT rewrite is left completely alone, so unrelated uncommitted work
//     survives and still reconciles properly if something external does land on it.
//
//   node test/js/rebaseline_all.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'cellops.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('rebaseline_all: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('rebaseline_all: unbalanced braces in ' + name); process.exit(2);
}

// The two functions under test, with the globals they reach for supplied as locals.
const setText = [];        // every edSetText call, in order
const cleared = [];        // every clearEdited call, in order
const srcMap = { a: 'OLD A', b: 'OLD B', c: 'OLD C' };
const editors = { a: {}, b: {} };                       // `c` has no editor open
const win = {
  edSetText: (id, s) => setText.push([id, s]),
  slateStore: { clearEdited: id => cleared.push(id) },
};

const run = new Function('srcMap', 'editors', 'window', `
  ${sliceFn('_rebaseline')}
  ${sliceFn('rebaselineAll')}
  return rebaselineAll;
`)(srcMap, editors, win);

// `a` was rewritten by the action; `b` was not; `c` was, but has no editor open.
const state = { cells: [{ id: 'a', source: 'NEW A' },
                        { id: 'b', source: 'OLD B' },
                        { id: 'c', source: 'NEW C' }] };
run(state);

let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.error(`rebaseline_all: ${what}\n  got  ${g}\n  want ${w}`); bad++; }
};

// The rewritten cells are now in agreement, which is what disarms the conflict branch.
eq('srcMap.a', srcMap.a, 'NEW A');
eq('srcMap.c', srcMap.c, 'NEW C');
// …and the untouched one keeps its old baseline, so an uncommitted edit there is still an edit.
eq('srcMap.b', srcMap.b, 'OLD B');

// Only the cell with BOTH a move and an open editor is written to.
eq('edSetText calls', setText, [['a', 'NEW A']]);
// `edited` is cleared for every cell that moved, editor open or not.
eq('clearEdited calls', cleared, ['a', 'c']);

if (bad) process.exit(1);
console.log('rebaseline_all: ok');
