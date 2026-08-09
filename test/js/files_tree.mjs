// Asserts the PURE tree logic from files.js — `_fuzzy` (the filter box's subsequence match) and
// `_visibleRows` (expansion + filter → the rows actually rendered). Both are DOM-free, so we slice
// them out of the source and eval them alongside the two module-level values they read
// (`_filesFilter`, `_openDirs`).
//
//   node test/js/files_tree.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'files.js'), 'utf8');

// Slice a `function name(…) { … }` declaration by matching braces.
function sliceFn(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) { console.error('files_tree: could not locate ' + name); process.exit(2); }
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  console.error('files_tree: unbalanced braces in ' + name); process.exit(2);
}
// Slice a single-line `const name = …;` arrow.
function sliceConst(name) {
  const m = new RegExp('^const ' + name + ' = .*$', 'm').exec(src);
  if (!m) { console.error('files_tree: could not locate const ' + name); process.exit(2); }
  return m[0];
}

const mod = new Function(`
  let _filesFilter = '';
  const _openDirs = new Set();
  ${sliceFn('_fuzzy')}
  ${sliceConst('_dirHasMatch')}
  ${sliceFn('_visibleRows')}
  return {
    fuzzy: _fuzzy,
    rows: (tree, filter, open) => { _filesFilter = filter; _openDirs.clear();
      for (const d of open) _openDirs.add(d); return _visibleRows(tree, 0, []); },
  };
`)();

const file = (name, path) => ({ name, path, dir: false, kind: 'text' });
const dir = (name, path, children) => ({ name, path, dir: true, children });
const TREE = [
  dir('src', 'src', [file('server_complete.jl', 'src/server_complete.jl'), file('worker.jl', 'src/worker.jl')]),
  dir('assets', 'assets', [dir('js', 'assets/js', [file('files.js', 'assets/js/files.js')])]),
  file('Project.toml', 'Project.toml'),
];
const paths = rows => rows.map(r => r.n.path);

const fails = [];
const eq = (label, got, want) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) fails.push(`${label}: ${a} (expected ${b})`);
};

// _fuzzy: subsequence over the path, case-insensitive; an empty needle matches everything.
eq('fuzzy empty', mod.fuzzy('src/worker.jl', ''), true);
eq('fuzzy substring', mod.fuzzy('src/worker.jl', 'work'), true);
eq('fuzzy scattered', mod.fuzzy('src/server_complete.jl', 'srvcmp'), true);
eq('fuzzy case', mod.fuzzy('src/Worker.jl', 'worker'), true);
eq('fuzzy order matters', mod.fuzzy('src/worker.jl', 'krow'), false);
eq('fuzzy miss', mod.fuzzy('src/worker.jl', 'zzz'), false);

// No filter: only expanded directories contribute children.
eq('collapsed', paths(mod.rows(TREE, '', [])), ['src', 'assets', 'Project.toml']);
eq('one open', paths(mod.rows(TREE, '', ['src'])),
   ['src', 'src/server_complete.jl', 'src/worker.jl', 'assets', 'Project.toml']);
eq('nested needs both', paths(mod.rows(TREE, '', ['assets'])), ['src', 'assets', 'assets/js', 'Project.toml']);
eq('nested open', paths(mod.rows(TREE, '', ['assets', 'assets/js'])),
   ['src', 'assets', 'assets/js', 'assets/js/files.js', 'Project.toml']);

// A filter force-expands every directory on a matching path and prunes the rest — no clicking.
eq('filter expands', paths(mod.rows(TREE, 'files.js', [])), ['assets', 'assets/js', 'assets/js/files.js']);
eq('filter prunes dirs', paths(mod.rows(TREE, 'worker', [])), ['src', 'src/worker.jl']);
eq('filter matches root file', paths(mod.rows(TREE, 'toml', [])), ['Project.toml']);
eq('filter no match', paths(mod.rows(TREE, 'nothinghere', [])), []);

if (fails.length) { console.error('files_tree FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('files_tree OK');
