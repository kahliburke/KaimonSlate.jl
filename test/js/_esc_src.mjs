// Shared loader for the front end's one HTML escaper, `window.slateEscHtml` in core.js.
//
// Two tests need it: `esc_html.mjs` asserts it is correct and that nothing else defines one, and
// `agent_md.mjs` evaluates a slice of agent.js that calls it. Neither should be the place that knows
// how to dig it out of the source, and neither should hand-roll a stand-in — a stand-in would let the
// real one drift while the tests kept passing, which is the failure this whole area is about.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const CORE = join(here, '..', '..', 'src', 'assets', 'js', 'core.js');

// The live implementation, evaluated. Exits 2 (extraction failure, not a test failure) if it has
// moved or been renamed — that is a broken harness, not a broken escaper.
export function loadEscHtml() {
  const src = readFileSync(CORE, 'utf8');
  const m = src.match(/window\.slateEscHtml\s*=\s*([\s\S]*?);\n/);
  if (!m) { console.error('_esc_src: window.slateEscHtml is gone from core.js'); process.exit(2); }
  try { return (0, eval)('(' + m[1] + ')'); }
  catch (e) { console.error('_esc_src: could not evaluate slateEscHtml — ' + e.message); process.exit(2); }
}
