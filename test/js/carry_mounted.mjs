// `_carryMounted` (view.js) decides what a re-run KEEPS from the previous output: a `slate_render`
// component whose kind registers `update`, and any element marked `data-slate-keep`. Both pair a new
// element with a mounted one by POSITION among its peers, and position is exactly where this kind of
// code goes wrong, so the pairing rules are pinned here rather than left to a browser.
//
// The real function is extracted and evaluated, never restated: a stand-in would let view.js drift
// while this kept passing, which is the failure the whole file is about.
//
//   node test/js/carry_mounted.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { El, parse } from './minidom.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const VIEW = join(here, '..', '..', 'src', 'assets', 'js', 'view.js');

let bad = 0;
const fail = m => { console.error('carry_mounted: ' + m); bad++; };
const ok = (cond, m) => { if (!cond) fail(m); };

// ── the live implementation ───────────────────────────────────────────────────────────────────
// `_carryMounted` closes over `_componentDesc` and `window`, so it is evaluated inside a factory that
// supplies both. The body's nested braces are all indented; only the function's own closer sits at
// column 0, which is what bounds the match.
const src = readFileSync(VIEW, 'utf8');
const m = src.match(/\nfunction _carryMounted\(out, stage\) \{[\s\S]*?\n\}/);
if (!m) { console.error('carry_mounted: _carryMounted is gone from view.js'); process.exit(2); }
// `_carryMounted` hands everything it did NOT carry to `slateTeardownOutput`, so the real one is
// extracted too rather than stubbed: the delegation is the part most likely to rot, and a stub would
// let the two drift apart while this kept passing.
const td = src.match(/\nwindow\.slateTeardownOutput = function \(root, keep\) \{[\s\S]*?\n\};/);
if (!td) { console.error('carry_mounted: slateTeardownOutput is gone from view.js'); process.exit(2); }
let carry, installTeardown;
try {
  carry = (0, eval)('(function (window, _componentDesc) {' + m[0] + '\nreturn _carryMounted; })');
  installTeardown = (0, eval)('(function (window) {' + td[0] + ' })');
} catch (e) {
  console.error('carry_mounted: could not evaluate view.js sources — ' + e.message);
  process.exit(2);
}

// A component placeholder plus the sibling descriptor script the real `_componentDesc` reads. Here the
// descriptor is hung on the node, and `_componentDesc` is supplied to match.
function comp(kind, props = {}) {
  const el = new El('span', { class: 'slatecomponent' });
  el.dataset.component = kind;
  el._desc = { v: 1, component: kind, props };
  return el;
}
const descOf = el => el._desc || null;
const keep = (key, id) => new El('div', { 'data-slate-keep': key, id: id || key });
const wrap = (...kids) => { const r = new El('div'); kids.forEach(k => r.appendChild(k)); return r; };

// ── two kinds, one of them removed between runs ───────────────────────────────────────────────
// The old output is [plotly, cesium]; the new one drops the plotly and returns the cesium alone. A
// global index pairs the new cesium with the mounted PLOTLY, whose kind does not match, so nothing is
// kept and the viewer is rebuilt. Paired within its own kind, the cesium keeps its mount.
{
  const updated = [], destroyed = [];
  const reg = kind => ({
    update: (el, props) => updated.push([kind, el.id, props.n]),
    destroy: el => destroyed.push([kind, el.id]),
  });
  const win = { slateWidgets: { plotly: reg('plotly'), cesium: reg('cesium') } };
  installTeardown(win);

  const oldPlotly = comp('plotly'); oldPlotly.id = 'op'; oldPlotly._customWired = true;
  const oldCesium = comp('cesium'); oldCesium.id = 'oc'; oldCesium._customWired = true;
  const out = wrap(oldPlotly, oldCesium);
  const stage = wrap(comp('cesium', { n: 7 }));

  const apply = carry(win, descOf)(out, stage);
  apply();

  ok(stage.children[0] === oldCesium, 'the mounted cesium should have taken the new placeholder’s place');
  ok(JSON.stringify(updated) === JSON.stringify([['cesium', 'oc', 7]]),
     'the cesium should have been updated once with the new props, got ' + JSON.stringify(updated));
  ok(JSON.stringify(destroyed) === JSON.stringify([['plotly', 'op']]),
     'only the dropped plotly should have been destroyed, got ' + JSON.stringify(destroyed));
}

// ── a kept element inside another kept element ────────────────────────────────────────────────
// Keys are collected in document order, so the outer pair swaps first and takes the new inner element
// off the stage with it. The inner pass must not then pull the old inner element out of the outer one
// it has just kept, and must not tell it that it is being discarded.
{
  const win = { slateWidgets: {} };
  installTeardown(win);
  const oldInner = keep('inner', 'oi');
  const oldOuter = keep('outer', 'oo');
  oldOuter.appendChild(oldInner);
  const out = wrap(oldOuter);

  let discarded = [];
  oldInner.addEventListener('slate:discard', function () { discarded.push(this.id); });
  oldOuter.addEventListener('slate:discard', function () { discarded.push(this.id); });

  const newOuter = keep('outer', 'no');
  newOuter.appendChild(keep('inner', 'ni'));
  const stage = wrap(newOuter);

  carry(win, descOf)(out, stage);

  ok(stage.children[0] === oldOuter, 'the outer element should have been carried onto the stage');
  ok(oldOuter.children.length === 1 && oldOuter.children[0] === oldInner,
     'the carried outer element should still contain its own inner element');
  ok(oldInner.parentElement === oldOuter, 'the old inner element should not have moved');
  ok(discarded.length === 0, 'nothing was dropped, so nothing should have been told to discard; got ' +
     JSON.stringify(discarded));
}

// ── a key that really does go away still gets its discard ─────────────────────────────────────
// The guard above must not become a blanket exemption: an element the new output no longer asks for
// is still removed, and a script holding listeners on it still needs to hear about it.
{
  const win = { slateWidgets: {} };
  installTeardown(win);
  const gone = keep('gone', 'g');
  const stays = keep('stays', 's');
  const out = wrap(stays, gone);
  let discarded = [];
  gone.addEventListener('slate:discard', function () { discarded.push(this.id); });
  stays.addEventListener('slate:discard', function () { discarded.push(this.id); });

  const stage = wrap(keep('stays', 'ns'));
  carry(win, descOf)(out, stage);

  ok(JSON.stringify(discarded) === JSON.stringify(['g']),
     'only the dropped key should have been discarded, got ' + JSON.stringify(discarded));
  ok(stage.children[0] === stays, 'the surviving key should have been carried');
}

if (bad) { console.error(`carry_mounted: ${bad} check(s) failed`); process.exit(1); }
console.log('carry_mounted: ok');
