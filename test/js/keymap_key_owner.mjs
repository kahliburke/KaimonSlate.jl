// Asserts `_ownsKeys` from keymap.js — whether a keystroke belongs to a control or to the notebook.
//
// Command mode puts whole commands on BARE letters: `w` converts a cell to a web cell, `d d` deletes
// it, `m` and `y` change its kind. So this predicate is the only thing standing between typing into a
// widget and silently restructuring the document. It answered with a tag-name test at first, which was
// wrong the moment a widget was not an `<input>`: MultiSelect renders a focusable `div[role=listbox]`,
// and typing `w` in one converted the cell.
//
// The other half matters just as much and pulls the opposite way. An interactive chart is given
// `tabindex="-1"` and focused on click (settings.js `pointerdown`), so a predicate written as "is this
// focusable" would swallow every command-mode key for the rest of the session after one click on a
// plot. What is asked instead is whether the target sits inside a CONTROL REGION.
//
// A region does not cover everything, so an element can also claim its keys with `data-slate-keys`.
// The Files tree is the case that needed it: a focusable `div` with arrow-key navigation, in no
// control region, so ↑/↓ moved the notebook's cell selection behind it and Enter opened a cell editor.
// Its own `stopPropagation` cannot prevent that, because the keymap listens on `document` in the
// capture phase and the tree's handler is an inline `onkeydown` that runs afterwards.
//
//   node test/js/keymap_key_owner.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'keymap.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('keymap_key_owner: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('keymap_key_owner: unbalanced braces in ' + name); process.exit(2);
}
// `_ownsKeys` reads two consts declared beside it; take them from the source too rather than restating
// them here, so the test cannot drift from the list the app actually uses.
const grabConst = name => {
  const m = new RegExp('const ' + name + ' = ([^;]+);').exec(src);
  if (!m) { console.error('keymap_key_owner: could not read ' + name); process.exit(2); }
  return `const ${name} = ${m[1]};`;
};

const ownsKeys = new Function(`
  ${grabConst('_FIELD_TAGS')}
  ${grabConst('_CONTROL_REGION')}
  ${sliceFn('_ownsKeys')}
  return _ownsKeys;
`)();
// The event-level form, which the view-state listeners (dep-focus, zen) use — same predicate plus
// "someone already handled it".
const ownsKeyEvent = new Function(`
  ${grabConst('_FIELD_TAGS')}
  ${grabConst('_CONTROL_REGION')}
  ${sliceFn('_ownsKeys')}
  ${grabConst('ownsKeyEvent')}
  return ownsKeyEvent;
`)();

// Enough of a DOM for the predicate: a tag, a class, an optional marker attribute, a parent chain, and
// a `closest` that understands the two selector forms the region list is written in — `.class` and
// `[attr]`. Parsed from the real selector rather than restated, so a new entry in it is exercised here
// without the test being edited.
function el(tag, cls, parent, attrs) {
  const node = {
    tagName: tag, className: cls || '', isContentEditable: false, parentElement: parent || null,
    _attrs: attrs || {},
    closest(sel) {
      const want = sel.split(',').map(s => s.trim());
      for (let n = node; n; n = n.parentElement) {
        const classes = (n.className || '').split(/\s+/).filter(Boolean);
        for (const w of want) {
          if (w.startsWith('.') && classes.includes(w.slice(1))) return n;
          const a = /^\[([^\]=]+)\]$/.exec(w);
          if (a && n._attrs && n._attrs[a[1]] !== undefined) return n;
        }
      }
      return null;
    },
  };
  return node;
}

const fails = [];
const is = (what, got, want) => { if (got !== want) fails.push(`${what}: ${got} (expected ${want})`); };

// ── Controls own their keys ───────────────────────────────────────────────────
is('a text input', ownsKeys(el('INPUT', '')), true);
is('a textarea', ownsKeys(el('TEXTAREA', '')), true);
is('a select', ownsKeys(el('SELECT', '')), true);
is('a button', ownsKeys(el('BUTTON', 'actionbtn')), true);
const ce = el('DIV', ''); ce.isContentEditable = true;
is('a contenteditable', ownsKeys(ce), true);

// The reported bug: MultiSelect is a focusable div, and it lives in a bind row.
const binds = el('DIV', 'binds', el('DIV', 'cell'));
is('a MultiSelect listbox', ownsKeys(el('DIV', 'mslist', el('DIV', 'widget', binds))), true);
// Anything else a widget might render, including something a package contributed.
is('a tableselect grid', ownsKeys(el('DIV', 'tablesel slatetable', el('DIV', 'widget', binds))), true);
is('an extension custom widget', ownsKeys(el('CANVAS', '', el('SPAN', 'customwidget', binds))), true);
is('a bare span inside a bind row', ownsKeys(el('SPAN', 'optlbl', el('DIV', 'widget', binds))), true);
// A control surfaced into a cell's strip is the same widget in a different place.
const strip = el('DIV', 'controls', el('DIV', 'cell'));
is('a control in a surfaced strip', ownsKeys(el('DIV', 'mslist', el('DIV', 'control', strip))), true);
// The cell editor.
is('the code editor', ownsKeys(el('DIV', 'cm-content', el('DIV', 'cm-editor', el('DIV', 'cell')))), true);

// ── An element that claims its keys outright ──────────────────────────────────
// The Files tree: a focusable div with its own arrow-key navigation, in no control region. Without
// the marker, ↑/↓ moved the notebook's cell selection behind it and Enter opened a cell editor.
const tree = el('DIV', 'filestree', el('DIV', 'filesbody', el('ASIDE', 'filespanel')), { 'data-slate-keys': 'own' });
is('the Files tree', ownsKeys(tree), true);
is('a row inside it', ownsKeys(el('DIV', 'ftrow', tree)), true);
// The marker is what does it, not the class name — so a panel a package adds is covered too.
is('any marked element', ownsKeys(el('DIV', 'somepanel', null, { 'data-slate-keys': 'own' })), true);
// An unmarked sibling in the same panel does NOT claim them: the panel's chrome is not its tree.
is('an unmarked part of the same panel', ownsKeys(el('DIV', 'filesbody', el('ASIDE', 'filespanel'))), false);

// ── The notebook owns everything else ─────────────────────────────────────────
// A false positive here is worse than the bug it guards: it silently disables command mode.
is('the page background', ownsKeys(el('BODY', '')), false);
is('a cell body', ownsKeys(el('DIV', 'cell', el('DIV', 'page'))), false);
is('cell output', ownsKeys(el('DIV', 'output', el('DIV', 'cell'))), false);
// An interactive chart is FOCUSABLE (tabindex=-1, focused on click) and must still leave the keys to
// command mode. This is why the predicate does not ask about focusability.
is('a focused chart', ownsKeys(el('DIV', 'echart', el('DIV', 'output', el('DIV', 'cell')))), false);
is('an inline chart in markdown', ownsKeys(el('CANVAS', '', el('DIV', 'ichart', el('DIV', 'md')))), false);
is('a cell header', ownsKeys(el('DIV', 'cellhead', el('DIV', 'cell'))), false);
is('rendered markdown', ownsKeys(el('P', '', el('DIV', 'md', el('DIV', 'cell')))), false);
// Non-elements reach it too (a text node, null) and must not throw or match.
is('null', ownsKeys(null), false);
is('a text node', ownsKeys({ nodeType: 3 }), false);

// ── The event form: which Escapes a view-state listener may act on ───────────
// The dep-focus view and zen exit on Escape, from listeners that are not commands and so do not go
// through the dispatcher. Escape inside a cell editor belongs to the editor — it leaves the editor,
// and under vim it leaves insert mode — so those listeners have to decline it, or one press both
// exits insert mode and drops the view (reported as issue #36).
const ev = (target, over = {}) => Object.assign({ key: 'Escape', target, defaultPrevented: false }, over);
const editorNode = el('DIV', 'cm-content', el('DIV', 'cm-editor', el('DIV', 'cell')));
is('Escape from a cell editor is not the view’s', ownsKeyEvent(ev(editorNode)), true);
is('Escape from a bind control is not the view’s', ownsKeyEvent(ev(el('INPUT', '', el('DIV', 'binds')))), true);
// Handled by something inner (CM6 returns true from its Escape ladder, which preventDefaults).
is('an already-handled Escape', ownsKeyEvent(ev(el('BODY', ''), { defaultPrevented: true })), true);
// …and from the notebook itself it IS the view's, which is the whole point of the view binding.
is('Escape from the page', ownsKeyEvent(ev(el('BODY', ''))), false);
is('Escape from a cell body', ownsKeyEvent(ev(el('DIV', 'cell', el('DIV', 'page')))), false);
is('no event at all', ownsKeyEvent(null), false);

if (fails.length) { console.error('keymap_key_owner FAIL:\n  ' + fails.join('\n  ')); process.exit(1); }
console.log('keymap_key_owner: ok');
