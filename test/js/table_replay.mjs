// A `@replay`-marked TABLE, driven end to end without a browser.
//
// A figure that follows its control offline and a table that doesn't is worse than neither: the knob
// sits above the table, moves four charts, and leaves the rows where they were — which reads as live
// and isn't. What closes that gap is three separate pieces of Julia and JavaScript agreeing:
//
//   1. the export writes the UNION of the control's positions as the table body, tagged `data-replay`
//   2. `_EXPORT_TABLE_JS` registers a row-order setter under that tag
//   3. `Slate.replay.wire` resolves the control's position and hands the shipped order to it
//
// None of the three fails loudly on its own. So this drives the real ones: the markup Julia emits, the
// enhancer Julia embeds, the shipped order Julia packed, and BOTH copies of `Slate.replay` — a static
// page runs the mirror in server_export.jl, and `wire` had no test at all before this.
//
//   node test/js/table_replay.mjs <fixture.json>
//
// The fixture is built by test_export.jl from `_run_replay_sweeps`, `_export_table_html` and
// `_export_control_html`. Hand-writing it would test a guess about what those produce.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, loadReplayCopies, rawJuliaConst } from './_replay_src.mjs';
import { makeDocument } from './minidom.mjs';

const fixturePath = process.argv[2];
if (!fixturePath) { console.error('usage: table_replay.mjs <fixture.json>'); process.exit(2); }
const fx = JSON.parse(readFileSync(fixturePath, 'utf8'));

const expSrc = readFileSync(join(ROOT, 'src', 'server_export.jl'), 'utf8');
const TABLE_JS = rawJuliaConst(expSrc, '_EXPORT_TABLE_JS');
const WIRE_JS = rawJuliaConst(expSrc, '_EXPORT_TABLE_REPLAY_JS');

if (fx.packed.dtype !== 'i16') {
  console.error(`table_replay: expected an i16 order, got ${fx.packed.dtype}`);
  process.exit(1);
}
// `Uint8Array.from` copies into a fresh, 2-byte-aligned buffer; a Buffer's own is a slice of a shared
// pool and may start at an odd offset, which `new Int16Array(buf.buffer, …)` refuses.
const u8 = Uint8Array.from(Buffer.from(fx.packed.b64, 'base64'));
// Exactly the shape `Slate.asset` resolves to for a packed array — `slice()` reads `.data` and nothing
// else, so a page and this test consume the same bytes the same way.
const packed = { data: new Int16Array(u8.buffer, 0, u8.byteLength / 2) };

const flush = () => new Promise(r => setTimeout(r, 0));
const fails = [];
let checks = 0;

for (const impl of ['live', 'stat']) {
  const note = m => fails.push(`[${impl}] ${m}`);
  const doc = makeDocument(fx.control.html + fx.tableHtml);
  // The rest of the page the mirror reaches for: the sweep routing table and the asset loader.
  const win = { __slateReplays: { [fx.sweep.id]: fx.sweep } };
  const env = k => k === impl
    ? { window: win, slate: { asset: () => Promise.resolve(packed) } }
    : {};
  const R = loadReplayCopies(doc, env)[impl];

  // The export's own table enhancer, verbatim, against that document.
  new Function('document', 'window', TABLE_JS)(doc, win);
  const setters = win.__slateTableReplay || {};
  checks++;
  if (!setters[fx.sweep.id]) {
    note(`the enhancer registered no row-order setter for ${fx.sweep.id} — data-replay is not reaching it`);
    continue;
  }

  win._slateTableMarks = [{ id: fx.sweep.id, control: fx.control.name }];
  new Function('window', 'Slate', '_slateTableMarks', 'document', WIRE_JS)(win, win.Slate, win._slateTableMarks, doc);
  await flush();

  const host = R.hosts(fx.control.name)[0];
  checks++;
  if (!host) { note('hosts() found no control — wire() skipped it'); continue; }
  // Every exported control renders disabled; `wire` enables the ones data actually shipped for. A table
  // that never enables is a page whose rows can't be changed, with nothing saying so.
  checks++;
  if (host.getAttribute('data-off') !== '0') note('wire() left the control disabled although the order shipped');

  const tbody = doc.querySelector('tbody');
  const shown = () => tbody.rows.map(tr => tr.cells[fx.col].textContent);
  const drive = async key => {
    R.mirror(host, key);
    R._inputs(host).forEach(i => i.dispatch('input'));
    await flush();
  };

  // The header the page was written with, in union order. A position's mask hides some of it.
  const heads = [...doc.querySelectorAll('thead th')];
  const visibleCols = () => heads.filter(th => !th.hidden).map(th => th.textContent);

  // The page is WRITTEN with the union of every position — that is what the order and the mask index
  // into — so `wire` has to apply the export-time position on load. Without that the reader's first
  // sight of the table is every row and every column any position can show, and only touching the
  // control brings it back to what was exported.
  if (fx.expectCols) {
    checks++;
    const at0 = visibleCols();
    if (JSON.stringify(at0) !== JSON.stringify(fx.expectCols[0]))
      note(`on load (before any input) the table shows columns ${JSON.stringify(at0)}, ` +
           `expected the export-time position ${JSON.stringify(fx.expectCols[0])}`);
  }

  for (let i = 0; i < fx.control.domain.length; i++) {
    await drive(fx.control.domain[i]);
    checks++;
    if (fx.expect) {
      const got = shown();
      // Compared as a SEQUENCE, not a set: what ships is an order, because a control that sorts its
      // table is as ordinary as one that filters it and a present/absent flag cannot express the first.
      if (JSON.stringify(got) !== JSON.stringify(fx.expect[i]))
        note(`position ${i} (${JSON.stringify(fx.control.domain[i])}) shows ` +
             `${JSON.stringify(got)}, expected ${JSON.stringify(fx.expect[i])}`);
    }
    // The other axis: which COLUMNS this position shows. The body is written once with every column
    // any position can show, and the mask hides the rest — header and every row's cells alike, or the
    // table draws a value under someone else's heading.
    if (fx.expectCols) {
      checks++;
      const got = visibleCols();
      if (JSON.stringify(got) !== JSON.stringify(fx.expectCols[i]))
        note(`position ${i} (${JSON.stringify(fx.control.domain[i])}) shows columns ` +
             `${JSON.stringify(got)}, expected ${JSON.stringify(fx.expectCols[i])}`);
      for (const tr of doc.querySelectorAll('tbody tr')) {
        const bad = [...tr.children].findIndex((td, ci) => !!td.hidden !== !!heads[ci].hidden);
        if (bad >= 0) { note(`position ${i}: cell ${bad} does not follow its header's visibility`); break; }
      }
    }
  }

  // Moving the control changes which rows EXIST, not what the reader was looking at. The filter box and
  // the sort are the reader's state and live in the same closure as the order; dropping either on every
  // move would make a replayed table unusable in exactly the case it is for — a long one.
  if (fx.filter) {
    const fi = doc.querySelector('.exp-tbl-filter');
    checks++;
    if (!fi) { note('no filter box — the enhancer did not build its chrome'); }
    else {
      const keep = fx.filter;
      fi.value = keep.text;
      fi.dispatch('input');
      await drive(fx.control.domain[keep.position]);
      const got = shown();
      checks++;
      if (JSON.stringify(got) !== JSON.stringify(keep.expect))
        note(`filter ${JSON.stringify(keep.text)} at position ${keep.position} shows ` +
             `${JSON.stringify(got)}, expected ${JSON.stringify(keep.expect)}`);
    }
  }
}

if (fails.length) {
  console.error(`table_replay: ${fails.length} failure(s)`);
  for (const f of fails) console.error('  ' + f);
  process.exit(1);
}
console.log(`table_replay: ${checks} checks, both copies of Slate.replay drive the table`);
