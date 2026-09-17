// Asserts `_keepFocus` from notebook.js — a control rebuild must not take the control away from the
// person using it.
//
// A cell's `@bind` rows are rebuilt by replacing the host's innerHTML, which destroys the focused node.
// Focus then falls to <body>, and command mode binds BARE LETTERS, so everything typed after that is
// read as commands: typing a filter into a `@bind TextField` converted the cell to a web cell on the
// `w`. The rebuild is not spurious — a `Select` whose options come from another bind genuinely changes
// structure on every keystroke — so the rebuild has to happen AND the caret has to survive it.
//
// The keyboard guard is not the fix and could not be: by the time `w` arrives the focus really is on
// <body>, and widening the guard to cover that would disable command mode everywhere.
//
//   node test/js/keep_focus.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'notebook.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('keep_focus: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('keep_focus: unbalanced braces in ' + name); process.exit(2);
}

// A DOM small enough to reason about: a host with children found by `data-name`, a document with one
// focused element, and inputs that carry a selection.
function makeDom() {
  const doc = { activeElement: null };
  const mk = (name, opts = {}) => {
    const node = {
      tagName: opts.tag || 'INPUT',
      _name: name,
      selectionStart: opts.start === undefined ? 0 : opts.start,
      selectionEnd: opts.end === undefined ? 0 : opts.end,
      getAttribute: k => (k === 'data-name' ? name : null),
      focus() { doc.activeElement = node; node.focused = true; },
      setSelectionRange(s, e) { node.selectionStart = s; node.selectionEnd = e; },
    };
    if (opts.noSelection) {                       // a checkbox/range: reading a selection throws
      Object.defineProperty(node, 'selectionStart', { get() { throw new TypeError('no selection'); } });
      Object.defineProperty(node, 'selectionEnd', { get() { throw new TypeError('no selection'); } });
      delete node.setSelectionRange;
    }
    return node;
  };
  const host = {
    children: [],
    contains(n) { return this.children.includes(n) || n === this; },
    querySelector(sel) {
      const m = /\[data-name="(.*)"\]/.exec(sel);
      return m ? (this.children.find(c => c._name === m[1]) || null) : null;
    },
  };
  return { doc, host, mk };
}

const fails = [];
// Compared by VALUE: some assertions below check a [start, end] pair, and a reference compare would
// report two identical arrays as different.
const is = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fails.push(`${what}: ${g} (expected ${w})`);
};

// `_keepFocus` reaches for `document`, `window` and `CSS`; supply them.
function run(doc, host, rebuild) {
  const win = {};                                  // no CSS.escape → exercises the fallback path
  const fn = new Function('document', 'window', 'CSS', `${sliceFn('_keepFocus')} return _keepFocus;`)(doc, win, undefined);
  fn(host, rebuild);
}

// ── The reported bug ──────────────────────────────────────────────────────────
{
  const { doc, host, mk } = makeDom();
  const before = mk('filter_text', { start: 3, end: 3 });
  host.children = [mk('wiki_url'), before, mk('show_system')];
  before.focus();
  // The rebuild replaces every node, exactly as innerHTML does.
  run(doc, host, () => { host.children = [mk('wiki_url'), mk('filter_text'), mk('show_system')]; });
  const after = host.querySelector('[data-name="filter_text"]');
  is('focus returns to the same control', doc.activeElement === after, true);
  is('it is the NEW node, not the destroyed one', doc.activeElement === before, false);
  is('the caret is put back', after.selectionStart, 3);
  is('…both ends', after.selectionEnd, 3);
}

// A selection, not just a caret.
{
  const { doc, host, mk } = makeDom();
  const f = mk('q', { start: 2, end: 6 });
  host.children = [f];
  f.focus();
  run(doc, host, () => { host.children = [mk('q')]; });
  const after = host.querySelector('[data-name="q"]');
  is('a selected range survives', [after.selectionStart, after.selectionEnd], [2, 6]);
}

// ── Nothing was focused, or focus was elsewhere ───────────────────────────────
// Stealing focus INTO a rebuilt control would be its own bug: a background cell re-rendering while
// you type somewhere else must not pull the caret across the document.
{
  const { doc, host, mk } = makeDom();
  host.children = [mk('a')];
  const outside = mk('somewhere-else');
  doc.activeElement = outside;
  run(doc, host, () => { host.children = [mk('a')]; });
  is('focus elsewhere is left alone', doc.activeElement === outside, true);
}
{
  const { doc, host, mk } = makeDom();
  host.children = [mk('a')];
  doc.activeElement = null;
  run(doc, host, () => { host.children = [mk('a')]; });
  is('nothing focused stays nothing', doc.activeElement, null);
}

// ── The control does not come back ────────────────────────────────────────────
// Its bind was removed by the very edit that caused the rebuild. There is nothing to restore, and it
// must not throw on the way out.
{
  const { doc, host, mk } = makeDom();
  const f = mk('gone', { start: 1, end: 1 });
  host.children = [f];
  f.focus();
  let threw = false;
  try { run(doc, host, () => { host.children = [mk('other')]; }); } catch (_) { threw = true; }
  is('a removed control does not throw', threw, false);
}

// ── Controls with no selection API ────────────────────────────────────────────
// A checkbox or a range input throws on `selectionStart`. Focus still has to be restored.
{
  const { doc, host, mk } = makeDom();
  const box = mk('flag', { noSelection: true });
  host.children = [box];
  box.focus();
  let threw = false;
  try { run(doc, host, () => { host.children = [mk('flag', { noSelection: true })] ; }); } catch (_) { threw = true; }
  const after = host.querySelector('[data-name="flag"]');
  is('a checkbox does not throw', threw, false);
  is('a checkbox still regains focus', doc.activeElement === after, true);
}

// ── The rebuild always runs ───────────────────────────────────────────────────
// Whatever happens with focus, the structural update itself is not optional.
{
  const { doc, host, mk } = makeDom();
  host.children = [mk('a')];
  doc.activeElement = null;
  let ran = 0;
  run(doc, host, () => { ran++; host.children = [mk('a'), mk('b')]; });
  is('rebuild ran', ran, 1);
  is('rebuild took effect', host.children.length, 2);
}

if (fails.length) { console.error('keep_focus FAIL:\n  ' + fails.join('\n  ')); process.exit(1); }
console.log('keep_focus: ok');
