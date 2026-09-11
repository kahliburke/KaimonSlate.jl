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
// `cmCommands.simplifySelection` stands in for the selection rung. The real one collapses extra
// carets or a non-empty selection and returns false on a bare caret, which is what lets a plain
// Escape fall through to leaving the cell; `cursors > 1` models "there was something to collapse".
let cursors = 1, collapsed = 0;
const cmCommands = { simplifySelection: () => (cursors > 1 ? (collapsed++, cursors = 1, true) : false) };
const keydown = new Function('completionStatus', '_vimCM', '_vimState', 'vimApi', 'cmCommands', 'return function keydown(e, view) ' + body.slice(body.indexOf('{')) + ';')(
  () => completion,
  () => (vimState ? { state: { vim: vimState } } : null),
  () => vimState,
  vimApi,
  cmCommands,
);
const view = { state: {}, contentDOM: { blur: () => { blurred++; } } };
const esc = (over = {}) => Object.assign({ key: 'Escape', ctrlKey: false, metaKey: false, altKey: false }, over);

let bad = 0;
function check(what, got, want) {
  if (got !== want) { console.error(`vim_escape: ${what} — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); bad++; }
}
// One press under a given completion/vim state → {handled, blurred, acted}.
function press(ev, comp, vs, carets = 1) {
  completion = comp; vimState = vs; acted = null; cursors = carets;
  const before = blurred, wasCollapsed = collapsed;
  const handled = keydown(ev, view);
  return { handled, blurred: blurred > before, acted, collapsed: collapsed > wasCollapsed };
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

// Rung 4: a selection or an extra caret is inner to the cell itself, so Escape simplifies before it
// will give up the cell. This is defaultKeymap's Escape command, which the ladder pre-empts.
check('an extra caret collapses', press(esc(), 'none', OFF, 2).collapsed, true);
check('collapsing does not leave the cell', press(esc(), 'none', OFF, 2).blurred, false);
check('collapsing reports handled', press(esc(), 'none', OFF, 2).handled, true);
check('a bare caret is not a rung', press(esc(), 'none', OFF, 1).collapsed, false);
// The popup outranks the carets. Without this case the rung's position below rung 1 is unpinned,
// and an Escape meant to dismiss a completion would silently drop the extra carets instead.
check('an active completion outranks the carets', press(esc(), 'active', OFF, 2).collapsed, false);
check('an active completion is still handed on with carets present', press(esc(), 'active', OFF, 2).handled, false);
// This rung applies under vim TOO. Extra carets are a state you have to be able to leave, and Escape
// is the key everyone reaches for; skipping the rung under vim meant a vim user's only way back to
// one caret was the mouse. Safe because the rung is a no-op on a bare caret (below), so normal-mode
// `<Esc>` keeps its "assert the mode, then leave the cell" meaning whenever there is nothing to
// collapse. Vim's block cursor does not stand in the way — the plugin draws it as a decoration and
// leaves the selection empty, verified in a live editor.
check('vim normal mode collapses extra carets', press(esc(), 'none', NORMAL, 2).collapsed, true);
check('vim normal mode keeps the cell while collapsing', press(esc(), 'none', NORMAL, 2).blurred, false);
check('vim normal mode with ONE caret still leaves the cell', press(esc(), 'none', NORMAL, 1).blurred, true);
check('vim insert exits insert rather than collapsing', press(esc(), 'none', INSERT, 2).collapsed, false);
check('vim insert still does not leave the cell', press(esc(), 'none', INSERT, 2).blurred, false);
// Visual mode outranks it too: Escape leaves visual first, carets intact for the next press.
check('vim visual exits visual rather than collapsing', press(esc(), 'none', VISUAL, 2).collapsed, false);
// Emacs is modeless and binds no Escape, so `_vimState` is null for it and it collapses like the
// default keymap; the OFF cases above are exactly that path.

// Rung 5: nothing inner is live, so Escape means what it has always meant.
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
// `:w` resolves through the shared `_apply`, which has to cover all three kinds of editor. Each of
// these was a real silent no-op: an overlay cell has no run, and a whole-file editor has no cellId
// at all, so `:w` in the Files tab did nothing and ⌘S was the only way to save a file.
if (!/_run\s*=\s*cm\s*=>\s*_apply\(/.test(src)) {
  console.error('vim_escape: :w does not route through _apply'); bad++;
}
if (!/_apply\s*=\s*\(v,\s*id\)[\s\S]{0,200}_onSave\(\)/.test(src)) {
  console.error('vim_escape: _apply does not save a whole-file editor'); bad++;
}
if (!/_apply\s*=\s*\(v,\s*id\)[\s\S]{0,400}_overlayView\(v\)[\s\S]{0,60}commitSource/.test(src)) {
  console.error('vim_escape: _apply does not commit in the source overlay'); bad++;
}
if (!/_apply\s*=\s*\(v,\s*id\)[\s\S]{0,400}runCell/.test(src)) {
  console.error('vim_escape: _apply does not run a code cell'); bad++;
}
// The whole-file editor has to actually carry the callback `_apply` reaches for, or the branch above
// is unreachable and `:w` goes back to doing nothing in the Files tab.
if (!/view\._onSave\s*=\s*opts\.onSave/.test(src)) {
  console.error('vim_escape: mkFileEditor does not expose _onSave'); bad++;
}
// Emacs gets the same verb under its own chord. The emacs keymap ships no C-x prefix, so without
// this binding C-x C-s falls through to the browser.
if (!/key:\s*'Ctrl-x Ctrl-s'[\s\S]{0,120}_apply\(/.test(src)) {
  console.error('vim_escape: emacs C-x C-s is not bound to _apply'); bad++;
}
if (!/mode === 'emacs'[\s\S]{0,120}_emacsSave/.test(src)) {
  console.error('vim_escape: the emacs save chord is not added for emacs mode'); bad++;
}

// The keymap setting is a registry, not a vim flag — so a mode can't be half-added (bundled but
// unofferable, or offered but unbundled). `_KEYMAP_MODES` is the single list the extension builder,
// the current-mode reader and the Settings menu all read.
if (!/_KEYMAP_MODES\s*=\s*\{[^}]*\bvim\b[^}]*\bemacs\b[^}]*\}/.test(src)) {
  console.error('vim_escape: the keymap registry does not carry both vim and emacs'); bad++;
}
// Emacs rides the SAME Escape handler and must never trip its vim rungs: it is modeless, binds no
// Escape, and `_vimCM` returns null for it — so Escape leaves the cell, which is the `OFF` case
// asserted above. Anything that reads a mode off the editor has to go through `_vimCM` for that to
// hold; a direct `state.vim` peek elsewhere would quietly treat an emacs editor as a vim one.
if (/\.state\s*\.\s*vim\b/.test(src.replace(/const _vimState[^\n]*\n/, ''))) {
  console.error('vim_escape: vim state is read outside _vimCM/_vimState'); bad++;
}

if (bad) { console.error(`vim_escape: ${bad} check(s) failed`); process.exit(1); }
console.log('vim_escape: ok');
