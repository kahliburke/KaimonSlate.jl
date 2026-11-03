// Asserts what a copied formula's LaTeX source is cleaned to: phantoms removed with balanced braces,
// and the alignment row they leave behind removed with them, while visible rows stay as written.
//
//   node test/js/copymath.mjs      # exit 0 = pass, 1 = mismatch
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'copymath.js'), 'utf8');
const window = {};
new Function('window', src)(window);
const clean = window.slateCleanTex;

let bad = 0;
const eq = (got, want, what) => {
  if (got !== want) { console.error(`copymath: ${what}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`); bad++; }
};

eq(clean('x^2 + 1'), 'x^2 + 1', 'plain source is unchanged');
eq(clean('a + \\phantom{b} c'), 'a +  c', 'a phantom is removed');
eq(clean('\\hphantom{\\frac{1}{\\left\\{x\\right\\}}}y'), 'y', 'nested and escaped braces balance');
eq(clean('\\begin{aligned}\\hphantom{\\begin{matrix}A \\\\ B\\end{matrix}} & \\hphantom{{} = 1} \\\\[-1.5em] A &= 1 \\\\ B &= 2\\end{aligned}'),
   '\\begin{aligned} A &= 1 \\\\ B &= 2\\end{aligned}', 'the phantom alignment row goes with its phantoms');
eq(clean('\\begin{aligned} A &= 1 \\\\ & \\\\ B &= 2\\end{aligned}'),
   '\\begin{aligned} A &= 1 \\\\ B &= 2\\end{aligned}', 'an emptied row between rows goes');
eq(clean('\\begin{bmatrix}1 & 2 \\\\ 3 & 4\\end{bmatrix}'), '\\begin{bmatrix}1 & 2 \\\\ 3 & 4\\end{bmatrix}',
   'a matrix keeps its separators');
eq(clean('x \\vphantom{\\int} y'), 'x  y', 'a vertical phantom is removed');

process.exit(bad ? 1 : 0);
