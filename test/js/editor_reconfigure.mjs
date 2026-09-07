// Asserts that a live settings change reaches EVERY open editor — including the CSS and JS panes of
// a web cell, and a view built with no cell id at all.
//
// `window.editors` is a cell→view map: one entry per cell. A web cell mounts up to three CM6 views
// and registers only the first, and `mkFileEditor` registers none. So a settings loop written over
// that map recolours a third of a web cell and none of a file editor — the theme picker, the wrap
// toggle, the keymap and the completion delay each shipped with that bug, and the keymap acquired it
// months after the others because a new loop was written the same way.
//
// The two checks below are therefore about the SHAPE of the code, not one instance of the bug:
// enumeration happens at the single construction site, and no loop reads the lossy map.
//
//   node test/js/editor_reconfigure.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'editor.js'), 'utf8');
let bad = 0;
const fail = m => { console.error('editor_reconfigure: ' + m); bad++; };

// ── 1. No live-apply loop may read `window.editors` ──────────────────────────────
// This is the invariant the bug kept violating. `window.editors` keeps its real job (finding a given
// CELL's editor, for edited-state, measure and edText) — it just cannot answer "every editor".
const lossy = [...src.matchAll(/for\s*\([^)]*\bof\s+Object\.values\(\s*window\.editors/g)];
if (lossy.length) {
  fail(`${lossy.length} loop(s) iterate window.editors — a web cell's CSS/JS panes and any `
     + `cell-id-less view are invisible to them. Iterate _allViews() instead.`);
}

// ── 2. Enumeration is a registry filled at the construction site ─────────────────
// A union of whichever maps exist today (`window.editors` + `window.webEditors`) is the shape that
// let `mkFileEditor` slip through, so pin the registry rather than the union.
if (!/const\s+_views\s*=\s*new Set\(\)/.test(src)) fail('_views registry is gone');
if (!/_views\.add\(view\)/.test(src)) fail('mkEditor does not add its view to _views');
if (!/_views\.delete\(view\)/.test(src)) fail('a destroyed view is never removed from _views');
if (/_allViews\s*=\s*\(\)\s*=>\s*\{[\s\S]{0,400}?window\.webEditors/.test(src)) {
  fail('_allViews unions the cell/pane maps again — it should read the registry');
}

// Deregistration has to survive whoever calls destroy (a Preact effect cleanup, removePane, the
// file-editor close), so it must hang off the view's own destroy rather than each call site.
if (!/view\.destroy\s*=\s*\(\)\s*=>\s*\{[^}]*_views\.delete\(view\)/.test(src)) {
  fail('destroy is not wrapped to deregister — call sites would each have to remember');
}

// ── 3. Every settings surface actually loops ─────────────────────────────────────
// Named individually: a setting that silently stops applying live looks like nothing at all until a
// reader reloads the page and their theme changes under them.
for (const fn of ['setCompleteDelay', 'setEditorWrap', 'setEditorKeymap', 'setSyntaxTheme',
                  'slateRegisterEditorExtension']) {
  const at = src.indexOf(`window.${fn} =`);
  if (at < 0) { fail(`${fn} is gone`); continue; }
  if (!/for\s*\([^)]*\bof\s+_allViews\(\)/.test(src.slice(at, at + 700))) {
    fail(`${fn} does not apply over _allViews()`);
  }
}

// ── 4. Completion is rebuilt per editor, not from the Julia source ───────────────
// The delay slider used to rebuild every editor's completion from `_acompExt`, which is the Julia and
// markdown source — so moving it replaced an HTML pane's tag completion with Julia's and the pane
// then completed nothing. Each view carries a builder for the source it was constructed with.
if (!/view\._mkAcomp\s*=\s*mkAcomp/.test(src)) fail('views do not carry their own completion builder');
if (/acompComp\.reconfigure\(\s*_acompExt\(/.test(src)) {
  fail('a reconfigure still rebuilds completion from _acompExt — that is the Julia/markdown source');
}

if (bad) { console.error(`editor_reconfigure: ${bad} check(s) failed`); process.exit(1); }
console.log('editor_reconfigure: ok');
