// Asserts the DAG edge spline, extracted from the two renderItems that each carried a copy of it.
//
// The copies were identical to the character apart from two arrowhead-size constants, and the region
// one's comment said so ("mirrors the cell-edge spline"). Nothing about a Catmull-Rom basis is
// self-evident on reading, so a divergence between them would not be noticed — it would show up as
// edges that curve slightly differently in one pane than the other, which no test and no glance would
// catch. Hence: one implementation, and the numbers pinned here.
//
// The expected values below are the output of the ORIGINAL INLINE CODE, captured before the
// extraction. They are not what the new helper happens to produce — they are what it has to match.
//
//   node test/js/dag_spline.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'dag.js'), 'utf8');
let bad = 0;
const fail = m => { console.error('dag_spline: ' + m); bad++; };

// Slice a `function name(…) { … }` by matching braces.
function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('dag_spline: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('dag_spline: unbalanced braces in ' + name); process.exit(2);
}
const spline = new Function(sliceFn('_dagSplineShapes') + '; return _dagSplineShapes;')();
const scale = new Function(sliceFn('_dagArrowScale') + '; return _dagArrowScale;')();

// ── 1. Byte-for-byte agreement with the pre-extraction output ────────────────────
const GOLDEN = [
  { pts: [[0, 0], [10, 20], [30, 25], [50, 60]], end: [45, 55], segs: [
    { x1: 0, y1: 0, cpx1: 0, cpy1: 0, cpx2: 0, cpy2: 0, x2: 1.6666666666666667, y2: 3.3333333333333335 },
    { x1: 1.6666666666666667, y1: 3.3333333333333335, cpx1: 3.3333333333333335, cpy1: 6.666666666666667, cpx2: 6.666666666666667, cpy2: 13.333333333333334, x2: 11.666666666666666, y2: 17.5 },
    { x1: 11.666666666666666, y1: 17.5, cpx1: 16.666666666666668, cpy1: 21.666666666666668, cpx2: 23.333333333333332, cpy2: 23.333333333333332, x2: 29.166666666666668, y2: 29.166666666666668 },
    { x1: 29.166666666666668, y1: 29.166666666666668, cpx1: 35, cpy1: 35, cpx2: 40, cpy2: 45, x2: 42.5, y2: 50 },
    { x1: 42.5, y1: 50, cpx1: 45, cpy1: 55, cpx2: 45, cpy2: 55, x2: 45, y2: 55 },
  ] },
  { pts: [[0, 0], [5, 5], [10, 0]], end: [9, 1], segs: [
    { x1: 0, y1: 0, cpx1: 0, cpy1: 0, cpx2: 0, cpy2: 0, x2: 0.8333333333333334, y2: 0.8333333333333334 },
    { x1: 0.8333333333333334, y1: 0.8333333333333334, cpx1: 1.6666666666666667, cpy1: 1.6666666666666667, cpx2: 3.3333333333333335, cpy2: 3.3333333333333335, x2: 4.833333333333333, y2: 3.5 },
    { x1: 4.833333333333333, y1: 3.5, cpx1: 6.333333333333333, cpy1: 3.6666666666666665, cpx2: 7.666666666666667, cpy2: 2.3333333333333335, x2: 8.333333333333334, y2: 1.6666666666666667 },
    { x1: 8.333333333333334, y1: 1.6666666666666667, cpx1: 9, cpy1: 1, cpx2: 9, cpy2: 1, x2: 9, y2: 1 },
  ] },
  { pts: [[3, 7], [3, 40], [80, 40], [80, 90], [120, 90]], end: [118, 88], segs: [
    { x1: 3, y1: 7, cpx1: 3, cpy1: 7, cpx2: 3, cpy2: 7, x2: 3, y2: 12.5 },
    { x1: 3, y1: 12.5, cpx1: 3, cpy1: 18, cpx2: 3, cpy2: 29, x2: 15.833333333333334, y2: 34.5 },
    { x1: 15.833333333333334, y1: 34.5, cpx1: 28.666666666666668, cpy1: 40, cpx2: 54.333333333333336, cpy2: 40, x2: 67.16666666666667, y2: 48.333333333333336 },
    { x1: 67.16666666666667, y1: 48.333333333333336, cpx1: 80, cpy1: 56.666666666666664, cpx2: 80, cpy2: 73.33333333333333, x2: 86.33333333333333, y2: 81.33333333333333 },
    { x1: 86.33333333333333, y1: 81.33333333333333, cpx1: 92.66666666666667, cpy1: 89.33333333333333, cpx2: 105.33333333333333, cpy2: 88.66666666666667, x2: 111.66666666666667, y2: 88.33333333333333 },
    { x1: 111.66666666666667, y1: 88.33333333333333, cpx1: 118, cpy1: 88, cpx2: 118, cpy2: 88, x2: 118, y2: 88 },
  ] },
];
const near = (a, b) => Math.abs(a - b) < 1e-12;
for (const g of GOLDEN) {
  const got = spline(g.pts, g.end);
  if (got.length !== g.segs.length) {
    fail(`${JSON.stringify(g.pts)} → ${got.length} segments, want ${g.segs.length}`);
    continue;
  }
  got.forEach((s, i) => {
    for (const k of ['x1', 'y1', 'cpx1', 'cpy1', 'cpx2', 'cpy2', 'x2', 'y2']) {
      if (!near(s[k], g.segs[i][k])) fail(`segment ${i} ${k}: got ${s[k]}, want ${g.segs[i][k]}`);
    }
  });
}

// ── 2. Properties that must hold whatever the points ─────────────────────────────
const pts = [[3, 7], [3, 40], [80, 40], [80, 90], [120, 90]], end = [118, 88];
const segs = spline(pts, end);
// Starts ON the source and ENDS at the arrow base, so the stroke neither floats off the node nor
// runs under a semi-transparent arrowhead.
if (!near(segs[0].x1, 3) || !near(segs[0].y1, 7)) fail('the curve does not start at the source point');
const last = segs[segs.length - 1];
if (!near(last.x2, end[0]) || !near(last.y2, end[1])) fail('the curve does not end at the arrow base');
// Contiguous: each segment starts where the previous ended, or the edge is drawn with visible breaks.
for (let i = 1; i < segs.length; i++) {
  if (!near(segs[i].x1, segs[i - 1].x2) || !near(segs[i].y1, segs[i - 1].y2)) fail(`gap before segment ${i}`);
}
// A two-point edge is drawn as a straight line by the callers, so the chain is only asked for 3+.
if (spline([[0, 0], [1, 1], [2, 2]], [2, 2]).some(s => Object.values(s).some(v => !isFinite(v)))) {
  fail('collinear points produce a non-finite control point');
}

// ── 3. The arrowhead scale is clamped ────────────────────────────────────────────
const api = k => ({ coord: p => [p[0] * k, p[1] * k] });
if (scale(api(1)) !== 1) fail('unit zoom should scale by 1');
if (scale(api(0.01)) !== 0.85) fail('zoomed far out, the head should clamp at 0.85 rather than vanish');
if (scale(api(100)) !== 3.2) fail('zoomed far in, the head should clamp at 3.2 rather than balloon');

// ── 4. Neither renderItem kept a copy ────────────────────────────────────────────
// The basis is recognisable by its knot weights; they should now appear once, in the helper.
const weights = (src.match(/4 \* a2\[0\]/g) || []).length;
if (weights !== 1) fail(`the Catmull-Rom knot appears ${weights} times in dag.js; it belongs only in _dagSplineShapes`);
const scales = (src.match(/Math\.min\(3\.2/g) || []).length;
if (scales !== 1) fail(`the arrowhead zoom clamp appears ${scales} times; it belongs only in _dagArrowScale`);

if (bad) { console.error(`dag_spline: ${bad} check(s) failed`); process.exit(1); }
console.log('dag_spline: ok');
