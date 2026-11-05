// The source-reload banner (panels.js) asks for a run of the cells a project-source change marked
// stale. A run answers it whoever makes it, so it closes once those cells have run, and, when it
// named no cells, after the first run that starts while it is up.
//
// The real functions are extracted and evaluated, with stand-ins for the DOM, `nbState` and the
// run-in-flight check.
//
//   node test/js/src_banner_close.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'panels.js'), 'utf8');

let bad = 0;
const eq = (got, want, m) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error(`src_banner_close: ${m}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    bad++;
  }
};
const grab = re => {
  const m = src.match(re);
  if (!m) { console.error('src_banner_close: panels.js no longer has ' + re); process.exit(2); }
  return m[0];
};
const body = [
  grab(/\nfunction hideSrcBanner\(\) \{.*\}/),
  grab(/\nlet _srcWatch = null;.*/),
  grab(/\nfunction _watchSrcBanner\(n\) \{[\s\S]*?\n\}/),
  grab(/\nwindow\.checkSrcBanner = function \(state\) \{[\s\S]*?\n\};/),
].join('\n');

const banner = { style: { display: 'flex' }, innerHTML: 'x' };
const document = { getElementById: () => banner };
const window = {};
let nbState = null, running = false;
window._runActive = () => running;
let watch;
try {
  watch = (0, eval)('(function (document, window, getState) { let nbState;' +
    body.replace(/\(typeof nbState !== 'undefined' && nbState && nbState\.cells\)/, '(getState() && getState().cells)') +
    '\nreturn _watchSrcBanner; })')(document, window, () => nbState);
} catch (e) {
  console.error('src_banner_close: could not evaluate the banner functions: ' + e.message);
  process.exit(2);
}
const cells = (...s) => ({ cells: s.map(([id, state]) => ({ id, kind: 'code', state })) });
const up = () => { banner.style.display = 'flex'; };
const shown = () => banner.style.display !== 'none';

// ── named cells: closes once they have all run, not before ───────────────────────────────────────
up(); nbState = cells(['a', 'stale'], ['b', 'stale'], ['c', 'fresh']);
watch(2);
window.checkSrcBanner(cells(['a', 'fresh'], ['b', 'stale'], ['c', 'fresh']));
eq(shown(), true, 'one marked cell still stale: the banner stays');
running = true;
window.checkSrcBanner(cells(['a', 'fresh'], ['b', 'fresh'], ['c', 'fresh']));
eq(shown(), true, 'not while the run is still going');
running = false;
window.checkSrcBanner(cells(['a', 'fresh'], ['b', 'fresh'], ['c', 'stale']));
eq(shown(), false, 'its cells have run: closed, whatever else is stale');

// ── no cells named: closes after a run that started while it was up ──────────────────────────────
up(); nbState = cells(['a', 'fresh']);
watch(0);
window.checkSrcBanner(cells(['a', 'fresh']));
eq(shown(), true, 'no run yet: the banner stays');
running = true; window.checkSrcBanner(cells(['a', 'running']));
running = false; window.checkSrcBanner(cells(['a', 'fresh']));
eq(shown(), false, 'a run started and settled: closed');

// ── closed by hand: nothing left watching ────────────────────────────────────────────────────────
up(); nbState = cells(['a', 'stale']);
watch(1);
document.getElementById().style.display = 'none';
window.checkSrcBanner(cells(['a', 'fresh']));   // hideSrcBanner again is harmless
eq(shown(), false, 'stays closed');

process.exit(bad ? 1 : 0);
