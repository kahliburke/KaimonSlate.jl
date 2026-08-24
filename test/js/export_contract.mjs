// The contract between the two halves of `@replay`, checked end to end without a browser.
//
// Julia decides two things independently: what markup a control renders as in a static export
// (`_export_control_html`) and what values it can take (`bind_domain`). The browser then has to look
// at that markup, read the control's position back, and find it in that domain. Nothing checked that
// those three agreed — and when they disagree the failure is silent: the page renders, the control
// moves, and the figure does not, with nothing logged.
//
// So: for EVERY control kind, drive the control to EVERY position in its own domain, read it back,
// and require the resolved index to be the position we set. Run against BOTH copies of
// `Slate.replay`, because a static page runs the mirror and a hosted one runs core.js.
//
//   node test/js/export_contract.mjs <fixture.json>
//
// The fixture is written by the Julia side (test_bind.jl), which is the only thing that can produce
// real markup and real domains — that is the point, not an implementation detail.
import { readFileSync } from 'node:fs';
import { loadReplayCopies } from './_replay_src.mjs';
import { makeDocument } from './minidom.mjs';

const fixturePath = process.argv[2];
if (!fixturePath) { console.error('usage: export_contract.mjs <fixture.json>'); process.exit(2); }
const controls = JSON.parse(readFileSync(fixturePath, 'utf8'));

const fails = [];
const note = (c, impl, msg) => fails.push(`${c.kind}/${c.name} [${impl}] ${msg}`);
let checks = 0;

for (const c of controls) {
  for (const impl of ['live', 'stat']) {
    // A fresh document per implementation: mirroring MUTATES the control, and the two copies must
    // each be shown the untouched markup rather than one inheriting the other's edits.
    let doc, R;
    try {
      doc = makeDocument(c.html);
      R = loadReplayCopies(doc)[impl];
    } catch (e) { note(c, impl, `could not build DOM: ${e.message}`); continue; }

    const hosts = R.hosts(c.name);
    if (!hosts.length) {
      // A control the page cannot even find is one `wire()` skips entirely — it renders, stays
      // disabled, and reads as a page that simply has no interactivity.
      note(c, impl, 'hosts() found nothing — wire() would skip this control');
      continue;
    }
    const h = hosts[0];

    // Enabling is what tells a reader the control is live. It is also the only thing standing
    // between "disabled because no data shipped" and "disabled because the wiring broke".
    R.enable(h, true);
    if (h.getAttribute('data-off') === '1') note(c, impl, 'enable() left data-off=1');
    for (const i of doc.querySelectorAll('input,select'))
      if (i.disabled) note(c, impl, `enable() left <${i.tag}> disabled`);
    checks++;

    // The round trip, at every position the control can take.
    for (let i = 0; i < c.domain.length; i++) {
      const key = c.domain[i];
      try { R.mirror(h, key); } catch (e) { note(c, impl, `mirror(${JSON.stringify(key)}) threw: ${e.message}`); break; }
      let got;
      try { got = R.read(h); } catch (e) { note(c, impl, `read() threw after ${JSON.stringify(key)}: ${e.message}`); break; }
      // The interval a range slider SHOWS has to follow the interval it holds. The thumbs are native
      // inputs and move themselves; the filled span between them is ours to redraw, and if it isn't
      // the control displays a range it no longer has — which is worse than showing nothing.
      if (R.kind(h) === 'rangeslider' && Array.isArray(key)) {
        R.paint(h);
        const fill = h.querySelector('.rsfill');
        const min = Number(h.querySelector('.exp-rs-lo').min);
        const max = Number(h.querySelector('.exp-rs-lo').max);
        const want = ((key[0] - min) / ((max - min) || 1) * 100) + '%';
        checks++;
        if (!fill) note(c, impl, 'paint: no .rsfill to draw the interval on');
        else if (fill.style.left !== want)
          note(c, impl, `paint: fill left is ${fill.style.left}, expected ${want} for ${JSON.stringify(key)}`);
      }

      const at = R.index(c.domain, got);
      checks++;
      if (at !== i) {
        note(c, impl, `position ${i} (${JSON.stringify(key)}) read back as ` +
                      `${JSON.stringify(got)} → index ${at}`);
        break;                                  // one failure per control is enough to act on
      }
    }

    // `listen` is how a control is driven at all, and it is not one mechanism: an input fires
    // `input`/`change`, while a table select has no input — its ROWS are the control and a click on
    // one is the event. Nothing else in the suite touches that path, and a table select whose rows
    // don't listen is a table that renders perfectly and does nothing when you click it.
    {
      let fired = 0;
      R.listen(h, () => { fired++; });
      if (R.kind(h) === 'tableselect') {
        const rows = h.querySelectorAll('tbody tr');
        checks++;
        if (!rows.length) note(c, impl, 'listen: table select has no rows to click');
        else {
          rows[1].click();                       // row 2 → wire value 2 (0 means "nothing selected")
          if (fired !== 1) note(c, impl, `listen: a row click fired ${fired} handlers, expected 1`);
          const at = R.index(c.domain, R.read(h));
          if (at !== 2) note(c, impl, `listen: clicking row 2 resolved to index ${at}, expected 2`);
          // A disabled control must not be drivable — that is what `data-off` is for.
          R.enable(h, false);
          const before = fired;
          rows[0].click();
          if (fired !== before) note(c, impl, 'listen: a disabled table select still fired');
          R.enable(h, true);
        }
      } else {
        const inputs = doc.querySelectorAll('input,select');
        checks++;
        if (!inputs.length) note(c, impl, 'listen: no input to subscribe to');
        else {
          inputs[0].dispatch('input');
          if (fired < 1) note(c, impl, 'listen: an input event fired no handler');
        }
      }
    }

    // A control surfaced beside several figures renders ONCE PER CELL, and `wire` drives every copy
    // and mirrors the mover's state onto the others. Until that existed only the first copy worked:
    // the reader dragged a strip and nothing happened. Two copies of the same markup is exactly what
    // the page holds, so assert `hosts` finds both and that a mirrored copy reads back identically.
    let two;
    try { two = makeDocument(c.html + c.html); } catch (e) { note(c, impl, `dup DOM: ${e.message}`); continue; }
    const R2 = loadReplayCopies(two)[impl];
    const pair = R2.hosts(c.name);
    checks++;
    if (pair.length !== 2) {
      note(c, impl, `hosts() found ${pair.length} of 2 copies — surfaced strips would go dead`);
    } else {
      const key = c.domain[c.domain.length - 1];
      R2.mirror(pair[0], key);
      R2.mirror(pair[1], key);
      const a = R2.index(c.domain, R2.read(pair[0])), b = R2.index(c.domain, R2.read(pair[1]));
      if (a !== b) note(c, impl, `copies disagree after mirror: ${a} vs ${b}`);
      checks++;
    }

    // Striding is the export dialog's size lever: ship every n-th position of a one-number control
    // and let the page snap to the nearest that shipped. The rendered control keeps its ORIGINAL
    // step, so most of its track has no exact column — without snapping it is simply dead there.
    if (c.strided) {
      let doc3, R3;
      try { doc3 = makeDocument(c.html); R3 = loadReplayCopies(doc3)[impl]; }
      catch (e) { note(c, impl, `stride DOM: ${e.message}`); continue; }
      const h3 = R3.hosts(c.name)[0];
      for (const key of c.domain) {
        R3.mirror(h3, key);
        const at = R3.index(c.strided, R3.read(h3));
        checks++;
        if (at < 0 || at >= c.strided.length) {
          note(c, impl, `strided: position ${JSON.stringify(key)} resolves to ${at} — dead control`);
          break;
        }
      }
    }
  }
}

if (fails.length) {
  console.error(`export_contract: ${fails.length} failure(s) across ${controls.length} controls`);
  for (const f of fails) console.error('  ' + f);
  process.exit(1);
}
console.log(`export_contract: ${controls.length} controls, ${checks} round-trips, both copies agree`);
