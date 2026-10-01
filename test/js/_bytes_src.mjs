// Shared loader for the front end's one byte formatter, `window.slateBytes` in platform.js.
//
// Two tests need it: `bytes_fmt.mjs` asserts it is correct, and `sweep_tile_panel.mjs` compares the
// text that `sweeptip.js` renders through it. Neither may evaluate the whole of platform.js, because
// off macOS that file watches the page through a `MutationObserver`, which Node does not have.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const PLATFORM = join(here, '..', '..', 'src', 'assets', 'js', 'platform.js');

// The live implementation, evaluated with the unit table it reads. Exits 2 (extraction failure, not
// a test failure) if either has moved or been renamed.
export function loadSlateBytes() {
  const src = readFileSync(PLATFORM, 'utf8');
  const units = src.match(/const _SLATE_BYTE_UNITS\s*=\s*(\[[^\]]*\]);/);
  const fn = src.match(/window\.slateBytes\s*=\s*(function[\s\S]*?\n});/);
  if (!units || !fn) { console.error('_bytes_src: window.slateBytes is gone from platform.js'); process.exit(2); }
  try { return new Function('_SLATE_BYTE_UNITS', 'return ' + fn[1])((0, eval)(units[1])); }
  catch (e) { console.error('_bytes_src: could not evaluate slateBytes: ' + e.message); process.exit(2); }
}
