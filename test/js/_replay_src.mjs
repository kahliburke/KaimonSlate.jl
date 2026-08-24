// Shared loader for the two copies of `Slate.replay`: the one in src/assets/js/core.js (the live
// shell, and any page that can load it) and the hand-mirrored one inside a Julia string in
// src/server_export.jl (a static page, which cannot). Both `replay_parity.mjs` and
// `export_contract.mjs` need them, and neither should be the place that knows how to dig them out.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Take the object literal starting at the `{` that follows `marker`, brace-matched. A plain regex
// can't do this (the body is full of braces) and neither can a naive counter (the body is also full
// of string literals containing `[`, `"` and `/`), so quotes and comments are tracked as it scans.
export function objectLiteralAfter(src, marker, label) {
  const at = src.indexOf(marker);
  if (at < 0) { console.error(`no ${label} — marker ${JSON.stringify(marker)} not found`); process.exit(2); }
  const open = src.indexOf('{', at);
  let depth = 0, quote = null, line = false, block = false;
  for (let i = open; i < src.length; i++) {
    const c = src[i], n = src[i + 1];
    if (line) { if (c === '\n') line = false; continue; }
    if (block) { if (c === '*' && n === '/') { block = false; i++; } continue; }
    if (quote) { if (c === '\\') i++; else if (c === quote) quote = null; continue; }
    if (c === '/' && n === '/') { line = true; i++; continue; }
    if (c === '/' && n === '*') { block = true; i++; continue; }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return src.slice(open, i + 1); }
  }
  console.error(`unterminated object literal for ${label}`);
  process.exit(2);
}

// The mirror lives inside a Julia `"""…"""` literal, so what reaches the browser is the string AFTER
// Julia has processed its escapes: a `\"` written for JS is consumed by Julia and emitted as a bare
// quote. Checking the raw source therefore checks something that is never served — and passes on a
// page whose script won't parse, which is exactly how `querySelectorAll("input[type=\"checkbox\"]")`
// once shipped as `("input[type="checkbox"]")` and took the whole shim down with a SyntaxError.
export function unescapeJuliaString(s) {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== '\\') { out += s[i]; continue; }
    const n = s[++i];
    out += n === 'n' ? '\n' : n === 't' ? '\t' : n === 'r' ? '\r' : n;   // \\, \", \$ → the bare char
  }
  return out;
}

// The body of a `const NAME = raw"""…"""` in a Julia source. `raw` means Julia does NOT process the
// escapes, so unlike the `Slate.replay` mirror this text IS what the browser receives.
export function rawJuliaConst(src, name) {
  const m = new RegExp('const\\s+' + name + '\\s*=\\s*raw"""([\\s\\S]*?)"""').exec(src);
  if (!m) { console.error(`no raw"""…""" constant named ${name}`); process.exit(2); }
  return m[1];
}

// Both copies refer to themselves — core.js as `window.Slate.replay`, the export mirror as
// `Slate.replay`. Binding one object under both names lets either style resolve unchanged, so
// neither is edited to be testable. `doc` becomes the copy's `document`.
//
// `env.window` / `env.slate` let a caller supply the REST of the page: `wire()` reaches for
// `window.__slateReplays` and `Slate.asset`, so a test that drives a whole route rather than one
// matching function has to hand those in. The window object is used as given, not copied, so a script
// run outside this sandbox (the table enhancer) and the copy inside it see the same globals.
export function instantiate(objText, label, doc = undefined, env = {}) {
  try {
    return new Function('document', 'env', `
      "use strict";
      const Slate = Object.assign({ isLive: function () { return false; } }, env.slate || {});
      const window = env.window || {};
      window.Slate = Slate;
      Slate.replay = ${objText};
      return Slate.replay;
    `)(doc, env);
  } catch (e) {
    console.error(`${label} does not parse as JavaScript — ${e.message}`);
    if (/input\[type="checkbox"\]/.test(objText))
      console.error('  (looks like a Julia-consumed \\" — use single quotes inside the JS string)');
    process.exit(2);
  }
}

// Both implementations, ready to run. `doc` is the `document` each should see; `env` the rest of the
// page (see `instantiate`). Each copy gets its OWN env, or the two would share one `window`.
export function loadReplayCopies(doc = undefined, env = () => ({})) {
  const core = readFileSync(join(ROOT, 'src', 'assets', 'js', 'core.js'), 'utf8');
  const exp = readFileSync(join(ROOT, 'src', 'server_export.jl'), 'utf8');
  return {
    live: instantiate(objectLiteralAfter(core, 'window.Slate.replay =', 'core.js copy'),
                      'core.js copy', doc, env('live')),
    stat: instantiate(unescapeJuliaString(objectLiteralAfter(exp, 'Slate.replay={',
                                                             'server_export.jl mirror')),
                      'server_export.jl mirror (after Julia string escapes)', doc, env('stat')),
  };
}
