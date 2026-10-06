// `slateTeardownOutput` (view.js) is the one place that tells package code its output is going away.
// Three owners must hear it: a `@bind` control widget, a `slate_render` component OUTPUT, and an
// element marked `data-slate-keep`.
//
// The component output is the case worth pinning. The widget contract promises `destroy` before the
// DOM is orphaned, but the only caller used to select `.customwidget[data-bind]` — so a figure
// RETURNED from a cell never got it, and one that makes a WebGL context per run walks the page into
// the browser's per-page limit, blanking unrelated figures. A silent regression here looks like
// someone else's bug, so it is asserted rather than left to a browser.
//
//   node test/js/teardown_output.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { El } from './minidom.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const VIEW = join(here, '..', '..', 'src', 'assets', 'js', 'view.js');

let bad = 0;
const fail = m => { console.error('teardown_output: ' + m); bad++; };
const ok = (c, m) => { if (!c) fail(m); };

// The live implementation, evaluated against a stub `window`. Only its own closer sits at column 0.
const src = readFileSync(VIEW, 'utf8');
const m = src.match(/\nwindow\.slateTeardownOutput = function \(root, keep\) \{[\s\S]*?\n\};/);
if (!m) { console.error('teardown_output: slateTeardownOutput is gone from view.js'); process.exit(2); }

function build(widgets) {
  const win = { slateWidgets: widgets };
  const fn = (0, eval)('(function (window) {' + m[0] + '\nreturn window.slateTeardownOutput; })')(win);
  return fn;
}

const wrap = (...kids) => { const r = new El('div'); kids.forEach(k => r.appendChild(k)); return r; };
function widget(kind, id) {
  const el = new El('div', { class: 'customwidget', 'data-bind': 'b1' });
  el.dataset.widget = kind; el.id = id; el._customWired = true;
  return el;
}
function component(kind, id) {
  const el = new El('span', { class: 'slatecomponent' });
  el.dataset.component = kind; el.id = id; el._customWired = true;
  return el;
}

// ── every owner hears it ──────────────────────────────────────────────────────────────────────
{
  const destroyed = [];
  const reg = { destroy: el => destroyed.push(el.id) };
  const teardown = build({ slider: reg, plotly: reg });

  const marked = new El('div', { 'data-slate-keep': 'fig' }); marked.id = 'mk';
  let discarded = [];
  marked.addEventListener('slate:discard', function () { discarded.push(this.id); });

  teardown(wrap(widget('slider', 'w'), component('plotly', 'c'), marked));

  ok(destroyed.includes('w'), 'a @bind control widget should have been destroyed');
  ok(destroyed.includes('c'), 'a RETURNED component output should have been destroyed — the gap this fixes');
  ok(JSON.stringify(discarded) === JSON.stringify(['mk']),
     'a data-slate-keep element should have heard slate:discard, got ' + JSON.stringify(discarded));
}

// ── `keep` is honoured ────────────────────────────────────────────────────────────────────────
// A carried element is still mounted, so it must not be destroyed or told to discard.
{
  const destroyed = [];
  const teardown = build({ plotly: { destroy: el => destroyed.push(el.id) } });
  const kept = component('plotly', 'keep');
  const gone = component('plotly', 'gone');
  const markedKept = new El('div', { 'data-slate-keep': 'f' }); markedKept.id = 'mkeep';
  let discarded = [];
  markedKept.addEventListener('slate:discard', function () { discarded.push(this.id); });

  teardown(wrap(kept, gone, markedKept), new Set([kept, markedKept]));

  ok(JSON.stringify(destroyed) === JSON.stringify(['gone']),
     'only the non-kept component should have been destroyed, got ' + JSON.stringify(destroyed));
  ok(discarded.length === 0, 'a kept marked element should not have been told to discard');
}

// ── an unwired element, and a kind with no destroy, are both no-ops ───────────────────────────
// A component whose kind has not registered yet never wired, so there is nothing to tear down and
// calling into an absent impl would throw across the whole sweep.
{
  const teardown = build({ nodestroy: {} });
  const unwired = component('plotly', 'u'); unwired._customWired = false;
  let threw = false;
  try { teardown(wrap(unwired, component('nodestroy', 'n'), component('unregistered', 'x'))); }
  catch (e) { threw = true; }
  ok(!threw, 'tearing down unwired / destroy-less / unregistered elements should not throw');
}

// ── one owner throwing does not strand the rest ───────────────────────────────────────────────
// These call into third-party code. If the first one throws, everything after it still leaks.
{
  const destroyed = [];
  const teardown = build({
    bad: { destroy: () => { throw new Error('boom'); } },
    good: { destroy: el => destroyed.push(el.id) },
  });
  const err = console.error; console.error = () => {};
  try { teardown(wrap(component('bad', 'b'), component('good', 'g'))); }
  finally { console.error = err; }
  ok(JSON.stringify(destroyed) === JSON.stringify(['g']),
     'a throwing destroy must not stop the others, got ' + JSON.stringify(destroyed));
}

if (bad) { console.error(`teardown_output: ${bad} check(s) failed`); process.exit(1); }
console.log('teardown_output: ok');
