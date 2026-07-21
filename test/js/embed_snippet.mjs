// Asserts the PURE `_embedSnippet` function from files.js — the map from (file kind, editor syntax)
// to the reference string inserted on drag/drop / paste. It references only String/JSON, so we slice
// it out (balanced braces) and eval it in isolation, then check each syntax renders the right snippet.
//
//   node test/js/embed_snippet.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'files.js'), 'utf8');

const start = src.indexOf('function _embedSnippet(');
if (start < 0) { console.error('embed_snippet: could not locate _embedSnippet in files.js'); process.exit(2); }
// Slice the whole function body by matching braces (no braces appear inside its string literals).
let depth = 0, end = -1;
for (let i = src.indexOf('{', start); i < src.length; i++) {
  if (src[i] === '{') depth++;
  else if (src[i] === '}' && --depth === 0) { end = i + 1; break; }
}
if (end < 0) { console.error('embed_snippet: unbalanced braces'); process.exit(2); }
const _embedSnippet = new Function(src.slice(start, end) + '\nreturn _embedSnippet;')();

const U = '/n/x/asset/assets/a.png';               // a served/attach URL
const img = { kind: 'image', url: U, rel: 'assets/a.png', name: 'a.png' };
const txt = { kind: 'file', url: U, rel: 'assets/a.txt', name: 'a.txt' };
const aud = { kind: 'audio', url: U, rel: 'assets/a.mp3', name: 'a.mp3' };

const cases = [
  // Julia code cell → @asset (bytes for media, String for text); uses the project-relative rel
  [img, 'julia', '@asset bytes "assets/a.png"'],
  [txt, 'julia', '@asset "assets/a.txt"'],
  // web panes
  [img, 'css', 'url("' + U + '")'],
  [img, 'js', '"' + U + '"'],
  [img, 'html', '<img src="' + U + '" alt="a.png">\n'],
  [aud, 'html', '<audio controls src="' + U + '"></audio>\n'],
  // markdown (default)
  [img, 'markdown', '![a.png](' + U + ')\n'],
  [aud, 'markdown', '<audio controls src="' + U + '"></audio>\n'],
];

const fails = [];
for (const [it, syntax, expected] of cases) {
  const got = _embedSnippet(it, syntax);
  if (got !== expected) fails.push(`${it.kind}/${syntax} -> ${JSON.stringify(got)} (expected ${JSON.stringify(expected)})`);
}
if (fails.length) { console.error('embed_snippet FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log(`embed_snippet OK (${cases.length} cases)`);
