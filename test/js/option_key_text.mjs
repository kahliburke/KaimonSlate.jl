// A keyed option widget (`_norm_options` in widgets.jl) holds `#opt:` keys in place of option
// values that the page cannot send back as text. The value mirror and the controls palette show the
// label of each key (`_keyText`, `_ctrlValLabel` in view.js), and every other value stays as before.
//
// The real functions are extracted and evaluated, with a stand-in for the bind-spec lookup.
//
//   node test/js/option_key_text.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'view.js'), 'utf8');

let bad = 0;
const eq = (got, want, m) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error(`option_key_text: ${m}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    bad++;
  }
};

const grab = re => {
  const m = src.match(re);
  if (!m) { console.error('option_key_text: view.js no longer has ' + re); process.exit(2); }
  return m[0];
};
const body = [
  grab(/\nconst _showVal = .*;/),
  grab(/\nconst _isKey = .*;/),
  grab(/\nconst _hasKey = .*;/),
  grab(/\nfunction _keyText\(p, v\) \{[\s\S]*?\n\}/),
  grab(/\nfunction _ctrlValLabel\(el, v, p\) \{[\s\S]*?\n\}/),
].join('\n');

const P = { options: [{ value: '#opt:a', label: 'Cat' }, { value: "#opt:a'", label: 'Cat 2' },
                      { value: '#opt:b', label: 'Dog' }] };
let keyText, ctrlValLabel;
try {
  [keyText, ctrlValLabel] = (0, eval)('(function (_bindSpec) {' + body + '\nreturn [_keyText, _ctrlValLabel]; })')(
    (id, name) => (id === 'ctl' && name === 'pick' ? { params: P } : null));
} catch (e) {
  console.error('option_key_text: could not evaluate the view.js functions: ' + e.message);
  process.exit(2);
}
const el = widget => ({ dataset: { widget, bind: 'ctl', name: 'pick' } });

// ── a key shows its label; a list of keys shows the labels in order ──────────────────────────────
eq(keyText(P, '#opt:b'), 'Dog', 'one key');
eq(keyText(P, "#opt:a'"), 'Cat 2', 'the key of a second equal value');
eq(keyText(P, ['#opt:b', '#opt:a']), 'Dog, Cat', 'a list of keys');
eq(keyText(P, '#opt:gone'), '#opt:gone', 'a key of no option shows as itself');

// ── any other value is unchanged, so a plain widget looks as before ──────────────────────────────
eq(keyText(P, 30), 30, 'a number');
eq(keyText(P, ['a', 'b']), ['a', 'b'], 'a list of plain values');
eq(keyText(undefined, 'nord'), 'nord', 'a string, with no params');

// ── the value mirror: the label of a key, also when the caller has no params ─────────────────────
eq(ctrlValLabel(el('select'), '#opt:b'), 'Dog', 'mirror of a select, params from the bind spec');
eq(ctrlValLabel(el('multicheck'), ['#opt:a', '#opt:b'], P), 'Cat, Dog', 'mirror of a multi-check');
eq(ctrlValLabel(el('multiselect'), ['x', 'y']), 'x, y', 'mirror of a plain multi-select');
eq(ctrlValLabel(el('slider'), 7), 7, 'mirror of a slider');

if (bad) { console.error(`option_key_text: ${bad} check(s) failed`); process.exit(1); }
console.log('option_key_text: ok');
