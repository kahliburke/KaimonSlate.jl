// Every client action that makes the SERVER rewrite a cell's source must rebaseline the open editor
// before rendering the reply.
//
// This is a call-site guard, not a behaviour test. `rebaseline_all.mjs` proves `rebaselineAll` does the
// right thing; what keeps going wrong is forgetting to call it from a new action. The bug has now been
// introduced three separate times — split and merge, then undo/redo/Replace All/timeline restore, then
// converting a cell's kind — and each time it reached a user before anyone noticed, because it only
// shows up when an editor happens to be open with uncommitted text.
//
// The failure mode: the reply carries a source matching neither the editor's buffer nor its stored
// baseline, which is exactly how notebook.js recognises an EXTERNAL edit, so the notebook accuses an
// agent, a file watcher or another tab of a change the user just asked for themselves.
//
// The routes below rewrite `cell.source` server-side. Anything reaching one of them has to pass the
// reply through `rebaselineAll`, or rebaseline the specific cell first (what split and merge do, since
// they know the exact text before the round trip).
//
//   node test/js/rebaseline_callsites.mjs      # exit 0 = pass, 1 = an unguarded call site
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const JS = join(here, '..', '..', 'src', 'assets', 'js');

// Route fragment → why it rewrites a source. Kept as fragments because the client builds the URL by
// concatenation (`'/api/cell-split/' + id`), so the literal in the source is the prefix.
const REWRITING_ROUTES = {
  '/api/cell-split/': 'splits one cell into two, so the original keeps only its first half',
  '/api/cell-merge/': 'folds the next cell in, so the target grows',
  '/api/cell-type/': 'set_kind! wraps into or unwraps out of a `@web(...)` skin',
  '/api/undo': 'restores a previous revision of every cell it touched',
  '/api/redo': 'the same, forwards',
  '/api/cells-replace': 'notebook-wide find and replace',
  '/api/history/restore': 'restores a recorded version of the whole notebook',
};

// A call site counts as guarded when one of these appears in the same statement.
const GUARDS = ['rebaselineAll', 'slateRebaselineAll', '_rebaseline', 'slateRebaseline'];

// Routes that hand back state WITHOUT having rewritten any source. Listed so the reader can see they
// were considered rather than missed: each changes ordering, header metadata or the whole document,
// none of which can put an editor at odds with its own cell.
//
//   /api/cell-move      reorders; sources untouched
//   /api/cell-delete    the cell and its editor go together
//   /api/cells-delete   likewise
//   /api/cell-flag      collapsed / hidecode / trace live in the header
//   /api/tags           header metadata
//   /api/controls       header metadata
//   /api/regions        header metadata
//   /api/cell-rename    reassigns an id; rewrites no source (rename_cell!)
//   /api/state          a fresh read, which is the path a genuine external edit arrives on
//
// The per-cell `hash` the browser diffs against is `_sha(c.source)` (server_history.jl), so a change
// that leaves every source alone cannot trigger the comparison at all.

// The body of the function containing line `i`. These are classic scripts written in one style, so
// the bound is the nearest `function` declaration at or near column 0 above, and the next one below.
// Falling back to the whole file would silently make the check vacuous, so an unbounded match returns
// a small window instead and the call site stays visible.
const FN_DECL = /^\s{0,2}(async\s+)?function\s/;
function enclosing(lines, i) {
  let from = -1;
  for (let j = i; j >= 0; j--) if (FN_DECL.test(lines[j])) { from = j; break; }
  if (from < 0) return lines.slice(Math.max(0, i - 6), i + 7).join('\n');
  let to = lines.length;
  for (let j = i + 1; j < lines.length; j++) if (FN_DECL.test(lines[j])) { to = j; break; }
  return lines.slice(from, to).join('\n');
}

const files = readdirSync(JS).filter(f => f.endsWith('.js') && f !== 'cm6.bundle.js');
const problems = [];
let checked = 0;

for (const f of files) {
  const src = readFileSync(join(JS, f), 'utf8');
  const lines = src.split('\n');
  for (const [route, why] of Object.entries(REWRITING_ROUTES)) {
    lines.forEach((line, i) => {
      if (!line.includes(route)) return;
      if (line.trim().startsWith('//') || line.trim().startsWith('*')) return;   // a mention in prose
      checked++;
      // Scoped to the ENCLOSING function, not a line window. The guard can sit on the call itself
      // (`renderAll(rebaselineAll(await api(…)))`), above it where the new text is known before the
      // round trip (`_rebaseline(id, before)` in splitCell), or below it where the reply is assigned
      // first (histRestore) — but it must be in the same function. A plain proximity window let
      // `toggleType` pass on the strength of `undoNb`'s guard eight lines further down.
      const window_ = enclosing(lines, i);
      if (GUARDS.some(g => window_.includes(g))) return;
      problems.push(`${f}:${i + 1} reaches ${route} without rebaselining\n` +
                    `      (${why})\n` +
                    `      ${line.trim()}`);
    });
  }
}

if (!checked) {
  console.error('rebaseline_callsites: found no call sites at all — the routes were probably renamed,\n' +
                'which makes this test vacuous. Update REWRITING_ROUTES.');
  process.exit(2);
}
if (problems.length) {
  console.error('rebaseline_callsites FAIL:\n  ' + problems.join('\n  ') +
                '\n\n  Pass the reply through `rebaselineAll(...)`, or `_rebaseline(id, text)` before the\n' +
                '  request when the new text is already known.');
  process.exit(1);
}
console.log(`rebaseline_callsites: ok (${checked} call sites)`);
