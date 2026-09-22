// Asserts src/assets/js/sweeptip.js — what a sweep grid's tile says, and which chunk it belongs to.
//
// The binning is the thing to pin. The grid is patched by INDEX, so the tile a reader points at is
// described by whichever units this file thinks tile `i` covers. Julia's `_tile_spans` is the one
// definition of that mapping; if these two ever drift, the panel confidently describes the wrong
// units and nothing about it looks wrong.
//
//   node test/js/sweep_tile_panel.mjs      # exit 0 = pass, 1 = mismatch, 2 = load failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadEscHtml } from './_esc_src.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const jsdir = join(here, '..', '..', 'src', 'assets', 'js');

globalThis.window = globalThis;
globalThis.document = { createElement: () => ({ style: {}, addEventListener() {} }),
                        body: { appendChild() {} }, addEventListener() {} };
window.slateEscHtml = loadEscHtml();
// The REAL byte formatter, for the same reason: this compares rendered text, and a stand-in with
// its own cutoffs would report a mismatch that does not exist.
(0, eval)(readFileSync(join(jsdir, 'platform.js'), 'utf8'));
(0, eval)(readFileSync(join(jsdir, 'sweeptip.js'), 'utf8'));

const T = window.slateSweepTip && window.slateSweepTip._test;
if (!T) { console.error('sweep_tile_panel: sweeptip.js exposed no test surface'); process.exit(2); }

const fails = [];
const eq = (got, want, what) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) fails.push(`${what}: got ${a}, want ${b}`);
};
const has = (h, txt, what) => { if (String(h).indexOf(txt) < 0) fails.push(`${what}: no ${txt} in ${h}`); };

// ── The binning, against Julia's ────────────────────────────────────────────────────────────
// `_tile_spans(n)`: per = max(1, cld(n, 600)); tile t covers ((t-1)*per+1) … min(t*per, n).
eq(T.span(0, 6), { lo: 1, hi: 1 }, 'one unit per tile below the budget');
eq(T.span(5, 6), { lo: 6, hi: 6 }, 'the last tile of a small sweep');
eq(T.span(0, 1200), { lo: 1, hi: 2 }, 'two units per tile at twice the budget');
eq(T.span(599, 1200), { lo: 1199, hi: 1200 }, 'the last tile of a binned sweep');
// A grid that does not divide evenly: the final tile is short, never long.
eq(T.span(599, 1199), { lo: 1199, hi: 1199 }, 'the short final tile');
eq(T.span(0, 1), { lo: 1, hi: 1 }, 'a one-unit sweep');

// ── Which chunk a tile is over ──────────────────────────────────────────────────────────────
const status = { total: 6, tiles: ['#30363d'], rings: '......',
                 chunks: [['swA', 1, 2, 'done'], ['swB', 3, 4, 'running'], ['swC', 5, 6, 'pending']] };
eq(T.chunkOf(status, 3, 3)[0], 'swB', 'a unit inside a chunk');
eq(T.chunkOf(status, 5, 6)[0], 'swC', 'the last chunk');
// A tile straddling two chunks names the one holding its earliest unit: the click opens ONE log.
eq(T.chunkOf(status, 2, 3)[0], 'swA', 'a straddling tile takes the first');
eq(T.chunkOf(status, 9, 9), null, 'a tile past every chunk names none');

// ── Measured durations ──────────────────────────────────────────────────────────────────────
// Not the card's ETA format: that rounds to "~2m" because it is a guess, and these are reported.
eq(T.ran(0), '', 'nothing to say about a unit that has not run');
eq(T.ran(412), '412 ms', 'sub-second stays in milliseconds');
eq(T.ran(1400), '1.40 s', 'seconds keep two digits while the mantissa is small');
eq(T.ran(23400), '23.4 s', '…and one when it is not');
eq(T.ran(65000), '1m 05s', 'past a minute the seconds are padded');

// ── What the panel says ─────────────────────────────────────────────────────────────────────
const one = T.body({ lo: 3, hi: 3, units: [{ i: 3, params: 'n = 3', status: 'ok', ms: 412,
                                             at: 1_700_000_000, bytes: 2100, node: 'c07' }] });
has(one, 'n = 3', 'the parameter point is the tile\'s identity');
has(one, '412 ms', 'how long it took');
has(one, 'on c07', 'where it ran');
has(one, '2.1 KB', 'how much it produced, through the shared formatter');

// A failure is why anyone points at a red tile, so the error itself is in the panel.
const bad = T.body({ lo: 9, hi: 9, units: [{ i: 9, params: 'n = 9', status: 'error', ms: 12,
                                             err: 'BoundsError: attempt to access <8>' }] });
has(bad, 'BoundsError', 'the error text');
has(bad, '&lt;8&gt;', 'and it is escaped, not interpolated as markup');

// A binned tile counts instead, and still shows the failures inside it.
const many = T.body({ lo: 1, hi: 4, units: [
  { i: 1, params: 'a', status: 'ok', ms: 100 }, { i: 2, params: 'b', status: 'ok', ms: 300 },
  { i: 3, params: 'c', status: 'error', ms: 50, err: 'died' }, { i: 4, params: 'd', status: '' }] });
has(many, '2 ok · 1 failed · 1 pending', 'the bucket\'s counts');
has(many, 'unit 3', 'the failing unit is named');
has(many, 'died', 'and its error carried');

// Nothing landed is a sentence, not an empty panel.
has(T.body({ units: [] }), 'nothing landed', 'an empty tile says so');

// The chunk footer names the chunk and what the scheduler is doing with it.
has(T.foot(['sw65da7a721463dbd9', 1, 2, 'running']), 'sw65da7a72', 'the chunk, short');
has(T.foot(['swA', 1, 2, 'running']), 'running', 'its scheduler state');
has(T.foot(['swA', 1, 2, 'pending']), 'queued', '…in the reader\'s words, not the plan\'s');
eq(T.foot(null), '', 'a tile with no chunk has no footer');

if (fails.length) { fails.forEach(f => console.error('sweep_tile_panel:', f)); process.exit(1); }
console.log('sweep_tile_panel: ok');
