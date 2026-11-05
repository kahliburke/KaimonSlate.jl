// A figure's `@replay` marks on one control move together or not at all (`Slate.replay.wire`). Run
// against BOTH copies, core.js and the server_export.jl mirror, with stand-in controls and assets.
//
//   node test/js/replay_figure.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { loadReplayCopies } from './_replay_src.mjs';

let bad = 0;
const fail = m => { console.error('replay_figure: ' + m); bad++; };
const eq = (got, want, m) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) fail(`${m}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
};
const settle = () => new Promise(r => setTimeout(r, 0));

// A slider host as `hosts()` finds it: the node carries `data-name` and `data-widget`, and is itself
// the input.
function slider(name, value) {
  const attrs = { 'data-name': name, 'data-widget': 'slider', 'data-off': '1' }, l = {};
  return {
    value: String(value), disabled: true, parentElement: null,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: k => { delete attrs[k]; },
    matches: sel => sel === 'input,select',
    querySelector: () => null, querySelectorAll: () => [],
    addEventListener(t, f) { (l[t] = l[t] || []).push(f); },
    drag(v) { this.value = String(v); (l.input || []).forEach(f => f({})); },
  };
}
const docWith = host => ({ querySelectorAll: () => [host] });

// Two marks on `k` with the same domain; each sweep ships one number per position.
const DOM = [1, 2, 3, 4];
const sweep = (asset, domain = DOM) => ({ domain, slice: [1], asset });
const packed = vals => ({ data: Float64Array.from(vals) });

async function run(impl, { table, assets, value = 3 }) {
  const host = slider('k', value);
  const warns = [];
  const cw = console.warn; console.warn = (...a) => warns.push(a.join(' '));
  const env = () => ({
    window: { __slateReplays: table },
    slate: { asset: name => (name in assets ? Promise.resolve(packed(assets[name])) : Promise.reject(new Error('gone'))) },
  });
  const R = loadReplayCopies(docWith(host), env)[impl];
  const applied = [];
  R.wire([{ id: 'a', control: 'k' }, { id: 'b', control: 'k' }], (slice, m, i) => applied.push([m.id, i, slice[0]]));
  await settle(); await settle();
  console.warn = cw;
  return { host, applied, warns };
}

for (const impl of ['live', 'stat']) {
  // Every mark has data over one domain: the control enables, and each move applies one index to both.
  {
    const r = await run(impl, { table: { a: sweep('A'), b: sweep('B') }, assets: { A: [10, 20, 30, 40], B: [1, 2, 3, 4] } });
    eq(r.host.disabled, false, `${impl}: the control enables once both marks' data loaded`);
    eq(r.applied, [['a', 2, 30], ['b', 2, 3]], `${impl}: the export-time position is applied to both`);
    r.applied.length = 0; r.host.drag(1);
    eq(r.applied, [['a', 0, 10], ['b', 0, 1]], `${impl}: a move applies the same index to both`);
  }
  // One mark has no sweep: the figure is left alone, the control is not enabled by it, and it says so.
  {
    const r = await run(impl, { table: { a: sweep('A') }, assets: { A: [10, 20, 30, 40] } });
    eq(r.applied, [], `${impl}: a figure with a mark missing its data does not move`);
    eq(r.host.disabled, true, `${impl}: and does not enable the control`);
    eq(r.warns.length === 1 && r.warns[0].includes('no data shipped for b'), true, `${impl}: the warning names the mark`);
  }
  // Marks exported at different strides name different positions: the figure is left alone.
  {
    const r = await run(impl, { table: { a: sweep('A'), b: sweep('B', [1, 3]) }, assets: { A: [10, 20, 30, 40], B: [1, 3] } });
    eq(r.applied, [], `${impl}: marks over different positions do not move the figure`);
    eq(r.warns.length === 1 && r.warns[0].includes('different positions'), true, `${impl}: and it says why`);
  }
  // One mark's data does not load: nothing is applied, and the control stays disabled.
  {
    const r = await run(impl, { table: { a: sweep('A'), b: sweep('B') }, assets: { A: [10, 20, 30, 40] } });
    eq(r.applied, [], `${impl}: a mark whose data failed to load keeps the figure still`);
    eq(r.host.disabled, true, `${impl}: and the control disabled`);
    eq(r.warns.length === 1 && r.warns[0].includes('did not load'), true, `${impl}: and it says so`);
  }
  // Inline sweeps (prose) need no asset and wire the same way.
  {
    const r = await run(impl, { table: { a: { domain: DOM, values: ['w', 'x', 'y', 'z'] }, b: { domain: DOM, values: ['W', 'X', 'Y', 'Z'] } }, assets: {} });
    eq(r.applied, [['a', 2, 'y'], ['b', 2, 'Y']], `${impl}: inline sweeps apply together`);
  }
}

process.exit(bad ? 1 : 0);
