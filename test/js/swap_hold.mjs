// `_swapOutput` (view.js) holds an output at its old height while the new content lays out, and
// releases the hold when the new images have loaded. Two swaps can overlap: a fast slider starts a
// new swap while the images of the previous one still load. The release of the older swap must not
// clear the hold of a newer swap that has committed.
//
// The real function is extracted and evaluated, with stand-ins for the DOM, the timers and the
// helpers that it calls.
//
//   node test/js/swap_hold.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const VIEW = join(here, '..', '..', 'src', 'assets', 'js', 'view.js');

let bad = 0;
const fail = m => { console.error('swap_hold: ' + m); bad++; };
const eq = (got, want, m) => { if (got !== want) fail(`${m}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };

const src = readFileSync(VIEW, 'utf8');
const m = src.match(/\nfunction _swapOutput\(out, html, live, after\) \{[\s\S]*?\n\}/);
if (!m) { console.error('swap_hold: _swapOutput is gone from view.js'); process.exit(2); }

// Manual timers and animation frames, so that each test sets the order of events.
let timers = [], frames = [];
const setTimeout = (f) => { const t = { f }; timers.push(t); return t; };
const clearTimeout = (t) => { timers = timers.filter(x => x !== t); };
const requestAnimationFrame = (f) => { frames.push(f); };
const runTimers = () => { const ts = timers; timers = []; ts.forEach(t => t.f()); };
const runFrames = () => { const fs = frames; frames = []; fs.forEach(f => f()); };

// An image whose fetch stalls: `decode` never settles, so the swap commits at its deadline and the
// image is still loading when it is in the output. Call `onload` to finish the load.
const stalled = () => ({ tag: 'img', src: 'blob', complete: false, decode: () => new Promise(() => {}) });
const text = () => ({ tag: 'pre' });

// `document.createElement` gives the staging div. Its `innerHTML` setter takes the nodes that the
// test registered for that html string.
const pages = new Map();
const document = {
  createElement: () => {
    const stage = { childNodes: [] };
    Object.defineProperty(stage, 'innerHTML', { set(h) { stage.childNodes = pages.get(h); } });
    stage.querySelectorAll = sel => (sel === 'img' ? stage.childNodes.filter(n => n.tag === 'img') : []);
    return stage;
  },
};
const page = (html, ...nodes) => { pages.set(html, nodes); return nodes; };

let swap;
try {
  swap = (0, eval)('(function (document, setTimeout, clearTimeout, requestAnimationFrame, _carryMounted,' +
                   ' runScripts, mountOutputComponents) {' + m[0] + '\nreturn _swapOutput; })')(
    document, setTimeout, clearTimeout, requestAnimationFrame, () => () => {}, () => {}, () => {});
} catch (e) {
  console.error('swap_hold: could not evaluate _swapOutput: ' + e.message);
  process.exit(2);
}

function output() {
  const out = { style: {}, offsetHeight: 300, kids: [] };
  out.replaceChildren = (...n) => { out.kids = n; };
  out.querySelectorAll = sel => (sel === 'img' ? out.kids.filter(n => n.tag === 'img') : []);
  return out;
}

// ── an older swap's image loads after a newer swap has committed ──────────────────────────────────
{
  timers = []; frames = [];
  const out = output();
  const [a] = page('A', stalled());
  const [b] = page('B', stalled());
  swap(out, 'A', ''); runTimers();
  eq(out.style.minHeight, '300px', 'A holds the height while its image loads');
  swap(out, 'B', ''); runTimers();
  a.onload();
  eq(out.style.minHeight, '300px', 'A finishing its load leaves the hold of B');
  b.onload();
  eq(out.style.minHeight, '', 'B finishing its load releases the hold');
}

// ── an older text swap's animation frame runs after a newer swap has committed ────────────────────
{
  timers = []; frames = [];
  const out = output();
  page('T', text());
  const [b] = page('B2', stalled());
  swap(out, 'T', '');
  swap(out, 'B2', ''); runTimers();
  runFrames();
  eq(out.style.minHeight, '300px', 'the frame of the text swap leaves the hold of B');
  b.onload();
  eq(out.style.minHeight, '', 'B finishing its load releases the hold');
}

// ── a newer swap that has not committed yet does not own the hold ─────────────────────────────────
{
  timers = []; frames = [];
  const out = output();
  const [a] = page('A3', stalled());
  page('B3', stalled());
  swap(out, 'A3', ''); runTimers();
  swap(out, 'B3', '');                        // B waits for its image, so A is still on the page
  a.onload();
  eq(out.style.minHeight, '', 'A releases its own hold while B waits');
}

// ── a superseded swap that commits late does not leave a hold ─────────────────────────────────────
{
  timers = []; frames = [];
  const out = output();
  page('A4', stalled());
  page('T4', text());
  swap(out, 'A4', '');                        // A waits for its image
  swap(out, 'T4', ''); runFrames();           // T commits and releases at once
  runTimers();                                // the deadline of A fires, but T superseded A
  eq(out.style.minHeight, '', 'no hold after the superseded swap');
}

process.exit(bad ? 1 : 0);
