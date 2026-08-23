// The exported page's gzip path.
//
// A packed asset is gzipped before base64 when that wins, so inflating it in the browser is on the
// critical path for every `@replay` sweep big enough to compress — which is exactly the big ones,
// where a silent failure costs the most. Nothing exercised it before: the Julia tests don't run the
// front-end, and it only runs on a page that has actually been exported.
//
// Two properties: it round-trips a multi-chunk payload, and a browser without `DecompressionStream`
// is refused explicitly rather than handed bytes that would decode as plausible-looking garbage.
//
//   node test/js/asset_inflate.mjs      # exit 0 = ok, 1 = failure, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { ROOT } from './_replay_src.mjs';

const src = readFileSync(join(ROOT, 'src', 'server_export.jl'), 'utf8');

const START = 'function _slateInflate(u){';
const END = 'function _slateNdarray';
const si = src.indexOf(START), ei = src.indexOf(END, si);
if (si < 0 || ei < 0) {
  console.error('asset_inflate: could not locate _slateInflate in server_export.jl');
  process.exit(2);
}
const body = src.slice(si, ei);

const _slateInflate = new Function(body + '\nreturn _slateInflate;')();

// A payload big enough to arrive in several chunks, so the concatenation is actually exercised.
const raw = new Uint8Array(Float64Array.from({ length: 60_000 }, (_, i) => Math.sin(i)).buffer);
const gz = new Uint8Array(gzipSync(Buffer.from(raw)));

const got = new Uint8Array(await _slateInflate(gz));
let same = got.length === raw.length;
for (let k = 0; same && k < raw.length; k++) same = got[k] === raw[k];
if (!same) {
  console.error(`asset_inflate: round-trip mismatch (${raw.length} in, ${got.length} out)`);
  process.exit(1);
}

// A browser without the API must say so, not hand back garbage that decodes as plausible numbers.
const savedDS = globalThis.DecompressionStream;
delete globalThis.DecompressionStream;
let refused = false;
try { await new Function(body + '\nreturn _slateInflate;')()(gz); }
catch (e) { refused = /DecompressionStream/.test(String(e)); }
globalThis.DecompressionStream = savedDS;
if (!refused) {
  console.error('asset_inflate: a browser with no DecompressionStream must be rejected explicitly');
  process.exit(1);
}

console.log(`asset_inflate: gzip round-trip ok (${gz.length} -> ${got.length} bytes), ` +
            'missing-API path rejects');
