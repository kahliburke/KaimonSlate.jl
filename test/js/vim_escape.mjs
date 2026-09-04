// Asserts the Escape ladder from editor.js — the arbitration between vim's modes and the cell's.
//
// Escape is the one key three layers all want: the completion popup closes on it, vim leaves insert
// on it, and Slate leaves the cell on it. The handler resolves that by dismissing only the innermost
// live layer and handing the key on (returning false) when an inner layer should get it. Every rung
// is a behaviour someone notices when it's wrong — a swallowed Escape, an editor you can't leave, or
// falling out of a cell when you only meant to leave insert — so each is pinned here.
//
//   node test/js/vim_escape.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'editor.js'), 'utf8');

// Slice a brace-balanced block starting at `open` (the index of its `{`).
function block(open, what) {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(open, i + 1);
  }
  console.error('vim_escape: unbalanced braces in ' + what); process.exit(2);
}
function methodBody(sig) {
  const at = src.indexOf(sig);
  if (at < 0) { console.error('vim_escape: could not locate ' + sig); process.exit(2); }
  return block(src.indexOf('{', at), sig);
}

// The handler in isolation, with its collaborators injected: what the completion popup is doing, and
// the vim adapter (null = vim off). `vimApi` records which transition was asked for, because the
// point of this handler is that it PERFORMS the mode change rather than delegating it.
const body = methodBody('keydown(e, view) {');
let completion = 'none', vimState = null, blurred = 0, acted = null;
const vimApi = {
  exitInsertMode: () => { acted = 'insert'; },
  exitVisualMode: () => { acted = 'visual'; },
  handleKey: (_cm, key) => { acted = 'key:' + key; },
};
const keydown = new Function('completionStatus', '_vimCM', 'vimApi', 'return function keydown(e, view) ' + body.slice(body.indexOf('{')) + ';')(
  () => completion,
  () => (vimState ? { state: { vim: vimState } } : null),
  vimApi,
);
const view = { state: {}, contentDOM: { blur: () => { blurred++; } } };
const esc = (over = {}) => Object.assign({ key: 'Escape', ctrlKey: false, metaKey: false, altKey: false }, over);

let bad = 0;
function check(what, got, want) {
  if (got !== want) { console.error(`vim_escape: ${what} — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); bad++; }
}
// One press under a given completion/vim state → {handled, blurred, acted}.
function press(ev, comp, vs) {
  completion = comp; vimState = vs; acted = null;
  const before = blurred;
  const handled = keydown(ev, view);
  return { handled, blurred: blurred > before, acted };
}

const OFF = null, INSERT = { insertMode: true, visualMode: false };
const NORMAL = { insertMode: false, visualMode: false }, VISUAL = { insertMode: false, visualMode: true };
const PENDING_OP = { insertMode: false, visualMode: false, inputState: { keyBuffer: ['d'] } };

// Rung 1 — an on-screen completion list outranks everything: hand the key on so CM6 closes the
// popup and leaves the cursor where it is.
check('active completion is handed on', press(esc(), 'active', OFF).handled, false);
check('active completion does not leave the cell', press(esc(), 'active', NORMAL).blurred, false);
// A merely PENDING completion (query in flight, nothing rendered) must NOT count as rung 1.
check('pending completion still leaves the cell', press(esc(), 'pending', OFF).blurred, true);

// Rung 2 — vim owns Escape while it has a mode to leave, and this handler must PERFORM the exit
// rather than returning false to let vim's own handler do it. Deferring is not equivalent:
// `closeCompletion` sits between the two and claims Escape while a completion is merely pending, so
// a deferred keypress vanished for as long as the completion query was in flight. These two cases —
// insert/visual WITH a pending completion — are the regression.
check('insert exits insert', press(esc(), 'none', INSERT).acted, 'insert');
check('insert is handled here', press(esc(), 'none', INSERT).handled, true);
check('insert does not leave the cell', press(esc(), 'none', INSERT).blurred, false);
check('insert exits even while a completion is pending', press(esc(), 'pending', INSERT).acted, 'insert');
check('insert is handled even while a completion is pending', press(esc(), 'pending', INSERT).handled, true);
check('visual exits visual', press(esc(), 'none', VISUAL).acted, 'visual');
check('visual does not leave the cell', press(esc(), 'none', VISUAL).blurred, false);
check('visual exits even while a completion is pending', press(esc(), 'pending', VISUAL).acted, 'visual');

// Rung 3 — a half-typed operator is cancelled rather than costing you the cell.
check('a pending operator is cancelled', press(esc(), 'none', PENDING_OP).acted, 'key:<Esc>');
check('a pending operator does not leave the cell', press(esc(), 'none', PENDING_OP).blurred, false);

// Rung 4 — nothing inner is live, so Escape means what it has always meant.
check('normal mode leaves the cell', press(esc(), 'none', NORMAL).blurred, true);
check('normal mode reports handled', press(esc(), 'none', NORMAL).handled, true);
check('normal mode does not touch vim', press(esc(), 'none', NORMAL).acted, null);
check('vim off leaves the cell', press(esc(), 'none', OFF).blurred, true);

// Ctrl is excluded so vim's own `<C-[>` insert-exit can never fall through to leaving the cell —
// that's the key for asserting normal mode without risking losing the cell.
check('Ctrl-Escape never leaves the cell', press(esc({ ctrlKey: true }), 'none', NORMAL).blurred, false);
check('Ctrl-Escape is not handled', press(esc({ ctrlKey: true }), 'none', NORMAL).handled, false);
// Other keys pass straight through — this handler outranks the whole keymap, so anything it claims
// by accident stops working everywhere.
check('a non-Escape key is ignored', press(esc({ key: 'a' }), 'none', NORMAL).handled, false);
check('a non-Escape key does not leave the cell', press(esc({ key: 'a' }), 'none', NORMAL).blurred, false);

// The ex commands a notebook cell needs. Slate has no save separate from execution, so `:w` runs;
// `:q!` is the only way to abandon an edit in one action and must key off the bang, not the name
// (vim parses `q!` as command `q` with argString `!`).
for (const [name, short] of [['write', 'w'], ['wq', 'wq'], ['xit', 'x'], ['quit', 'q']]) {
  const re = new RegExp(`defineEx\\(\\s*'${name}'\\s*,\\s*'${short}'`);
  if (!re.test(src)) { console.error(`vim_escape: :${short} (${name}) is not registered`); bad++; }
}
if (!/argString[\s\S]{0,80}===\s*'!'[\s\S]{0,80}_discard/.test(src)) {
  console.error('vim_escape: :q! does not discard on the bang'); bad++;
}
// `:q` without the bang keeps the buffer, so discard must be reached only through that guard.
if ((src.match(/_discard\(cm\)/g) || []).length !== 1) {
  console.error('vim_escape: _discard is reachable from more than the bang guard'); bad++;
}
// A md / @bind cell edits in the `.srcedit` overlay, which has no run — `:w` must commit there
// instead, or it silently does nothing on exactly the cells whose source you opened deliberately.
if (!/_overlay\(v\)[\s\S]{0,60}commitSource/.test(src)) {
  console.error('vim_escape: :w does not commit in the source overlay'); bad++;
}

if (bad) { console.error(`vim_escape: ${bad} check(s) failed`); process.exit(1); }
console.log('vim_escape: ok');
