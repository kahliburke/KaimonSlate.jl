// Asserts `_setMessage` from dialogs.js — how a confirm/alert turns one string into the dialog body.
//
// Every destructive action in the app goes through this: release a node, reap a worker, delete a
// region, archive to a permanent DOI. The message is assembled by string concatenation at the call
// site and carries a region or notebook name the user chose, so two things have to hold. The
// question has to be separable from the small print (they used to render at one size, so "Release
// the node held for gpu?" and the consequences carried equal weight). And a name has to reach the
// DOM as TEXT, whatever it is spelled with.
//
//   node test/js/dialog_message.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'dialogs.js'), 'utf8');

const start = src.indexOf('function _fillText');
const end = src.indexOf('function dlg(');
if (start < 0 || end < 0 || end < start) {
  console.error('dialog_message: could not locate _fillText/_setMessage in dialogs.js');
  process.exit(2);
}

// The smallest DOM these two functions touch: createElement, createTextNode, textContent,
// appendChild, className. Deliberately NOT a real DOM — a fake that records structure is what lets
// the assertions below talk about elements and text nodes separately, which is the whole point.
class El {
  constructor(tag) { this.tag = tag; this.className = ''; this.children = []; this._text = ''; }
  set textContent(v) { this._text = String(v); this.children = []; }
  get textContent() {
    return this.children.length ? this.children.map(c => c.textContent).join('') : this._text;
  }
  appendChild(c) { this.children.push(c); return c; }
}
globalThis.document = {
  createElement: (t) => new El(t),
  createTextNode: (t) => { const e = new El('#text'); e.textContent = t; return e; },
};

let _setMessage;
try {
  _setMessage = new Function(src.slice(start, end) + '\nreturn _setMessage;')();
} catch (e) {
  console.error('dialog_message: could not evaluate —', e.message);
  process.exit(2);
}

const fails = [];
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fails.push(`${label}: got ${g}, want ${w}`);
};
const build = (msg) => { const el = new El('div'); _setMessage(el, msg); return el; };
const kids = (el, cls) => el.children.filter(c => c.className === cls);

// ── question and consequences are separate elements ─────────────────────────────────────────────
{
  const el = build('Release the node held for `gpu`?\nIts workers are reaped and the node goes back to the scheduler.');
  eq('one question', kids(el, 'modalq').length, 1);
  eq('the question is the first line', kids(el, 'modalq')[0].textContent,
     'Release the node held for gpu?');
  eq('one explanation', kids(el, 'modalp').length, 1);
  eq('the explanation is the rest', kids(el, 'modalp')[0].textContent,
     'Its workers are reaped and the node goes back to the scheduler.');
}

// Callers write the separator both ways and mean the same thing by it.
{
  const one = build('Do it?\nA consequence.\nAnother consequence.');
  const two = build('Do it?\n\nA consequence.\n\nAnother consequence.');
  eq('single newlines split paragraphs', kids(one, 'modalp').length, 2);
  eq('blank lines do the same', kids(two, 'modalp').length, 2);
  eq('and produce the same text',
     kids(one, 'modalp').map(p => p.textContent), kids(two, 'modalp').map(p => p.textContent));
  eq('a trailing newline adds no empty paragraph', kids(build('Do it?\nWhy.\n'), 'modalp').length, 1);
}

// A one-line message has no hierarchy to show and must not grow a heading it never had.
{
  const el = build('Restart this notebook’s worker?');
  eq('no question element', kids(el, 'modalq').length, 0);
  eq('no paragraph element', kids(el, 'modalp').length, 0);
  eq('just the text', el.textContent, 'Restart this notebook’s worker?');
}

// ── names ───────────────────────────────────────────────────────────────────────────────────────
{
  // Backticks mark the name and are consumed: the delimiter is a styling instruction, not content.
  const q = kids(build('Delete region `my gpu`?\nGone for good.'), 'modalq')[0];
  eq('the name element is a code span', q.children.filter(c => c.tag === 'code').length, 1);
  eq('it holds the name alone', q.children.find(c => c.tag === 'code').textContent, 'my gpu');
  eq('it is styled as a name', q.children.find(c => c.tag === 'code').className, 'modalname');
  eq('the backticks are gone from the text', q.textContent, 'Delete region my gpu?');

  // Two names in one sentence, and text on both sides of each.
  const p = kids(build('Ask?\nMoving `a` into `b` now.'), 'modalp')[0];
  eq('both names are code', p.children.filter(c => c.tag === 'code').map(c => c.textContent), ['a', 'b']);
  eq('the sentence still reads', p.textContent, 'Moving a into b now.');

  // An unmatched backtick is content, not the start of a name that never ends.
  eq('a lone backtick stays text', kids(build('Ask?\nA ` lone tick.'), 'modalp')[0].textContent,
     'A ` lone tick.');
}

// ── a name is never markup ──────────────────────────────────────────────────────────────────────
{
  // Region and notebook names are user-chosen and land here by concatenation. Whatever they are
  // spelled with, they arrive as TEXT: this is the reason the body is built rather than assigned.
  const nasty = '<img src=x onerror=alert(1)>';
  const q = kids(build('Delete region `' + nasty + '`?\nGone.'), 'modalq')[0];
  const code = q.children.find(c => c.tag === 'code');
  eq('the name is one text-bearing element', code.textContent, nasty);
  eq('and no element was created from it', code.children.length, 0);

  // The same outside a name, where it is a plain text node.
  const p = kids(build('Ask?\n' + nasty), 'modalp')[0];
  eq('plain text stays plain', p.textContent, nasty);
  eq('and creates no elements', p.children.every(c => c.tag === '#text'), true);
}

if (fails.length) {
  console.error('dialog_message: ' + fails.length + ' failure(s)');
  for (const f of fails) console.error('  - ' + f);
  process.exit(1);
}
console.log('dialog_message: ok');
