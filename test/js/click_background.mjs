// Asserts `_isPageBackground` from keyboard.js — the predicate deciding whether a mousedown landed
// on the empty page rather than on something.
//
// It guards a browser behaviour rather than a handler: clicking a block that CONTAINS a
// `contenteditable` makes WebKit and Blink place the caret in the nearest editable text, so a click
// in the page margin level with a line of code focused that cell's editor and entered edit mode.
// The handler answers with `preventDefault`, which means the predicate decides where clicking is
// dead. Too wide and ordinary clicks — a button, output text you want to select, the editor — stop
// working, so the narrowness is the property worth pinning.
//
//   node test/js/click_background.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'keyboard.js'), 'utf8');

function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('click_background: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('click_background: unbalanced braces in ' + name); process.exit(2);
}

// Enough of a DOM for the predicate: identity of `document.body`, and `instanceof Element`.
class Element {
  constructor(id = '', classes = []) { this.id = id; this._c = new Set(classes); }
  get classList() { return { contains: c => this._c.has(c) }; }
}
const body = new Element('', ['dag-right', 'wrap-output']);
const document = { body };

const isPageBackground = new Function('document', 'Element', `${sliceFn('_isPageBackground')}
  return _isPageBackground;`)(document, Element);

const fails = [];
const eq = (label, got, want) => { if (got !== want) fails.push(`${label}: ${got} (expected ${want})`); };

// The page background — clicking here means "nothing", and must be neutralised.
eq('body', isPageBackground(body), true);
eq('#nb', isPageBackground(new Element('nb')), true);
eq('.page', isPageBackground(new Element('', ['page'])), true);

// Everything drawn ON the background is a real click and must be left alone. A false positive here
// makes the element unclickable, so this is the half that matters.
eq('the editor', isPageBackground(new Element('', ['cm-content'])), false);
eq('a cell', isPageBackground(new Element('cell-intro', ['cell'])), false);
eq('a button', isPageBackground(new Element('', ['run'])), false);
eq('cell output', isPageBackground(new Element('', ['output'])), false);
eq('the agent panel', isPageBackground(new Element('agentpanel')), false);
// A class merely CONTAINING "page" is not the page.
eq('.pagewide', isPageBackground(new Element('', ['pagewide'])), false);
// Non-elements reach it too (text nodes, document), and must not throw or match.
eq('null target', isPageBackground(null), false);
eq('a text node', isPageBackground({ nodeType: 3 }), false);

if (fails.length) { console.error('click_background FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('click_background OK');
