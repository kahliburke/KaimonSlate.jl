// Asserts every Slate palette tells ECharts whether it is dark.
//
// Labels without an explicit colour (graph, scatter, pie, ...) are coloured for contrast against the
// background ECharts infers from `backgroundColor`. The Slate theme's background is 'transparent',
// which ECharts reads as light, so on a dark palette those labels need the theme's `darkMode` to come
// out light-on-dark. Both theme builders are checked: the live one in core.js and its mirror in
// server_export.jl, which static exports use.
//
//   node test/js/echarts_dark_labels.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', 'src');
const core = readFileSync(join(root, 'assets', 'js', 'core.js'), 'utf8');
const exportSrc = readFileSync(join(root, 'server_export.jl'), 'utf8');
const css = readFileSync(join(root, 'assets', 'notebook.css'), 'utf8');
let bad = 0;
const fail = m => { console.error('echarts_dark_labels: ' + m); bad++; };
const die = m => { console.error('echarts_dark_labels: ' + m); process.exit(2); };

// Slice a `function name(…) { … }` by matching braces.
function sliceFn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) die('could not locate ' + name);
  let depth = 0;
  for (let i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  die('unbalanced braces in ' + name);
}

// The live builder, with the two module-level values it reads stubbed out.
const live = new Function(
  'const _SLATE_VIRIDIS = []; const _slateValueFormatter = v => v;\n' +
  ['_slateAxisTheme', '_slateIsDark', '_slateEchartsThemeFrom'].map(n => sliceFn(core, n)).join('\n') +
  '\nreturn { isDark: _slateIsDark, theme: _slateEchartsThemeFrom };')();

// The export mirror, run against a stubbed document whose computed style serves one palette.
const m = /const _EXPORT_ECHARTS_THEME_JS = raw"""\n([\s\S]*?)\n"""/.exec(exportSrc);
if (!m) die('could not locate _EXPORT_ECHARTS_THEME_JS in server_export.jl');
const exported = new Function('getComputedStyle', 'document',
  m[1] + '\nreturn { isDark: _slateIsDark, theme: _slateExportTheme };');
function exportTheme(vars) {
  const cs = { getPropertyValue: n => vars[n] || '' };
  return exported(() => cs, { documentElement: {} }).theme();
}

// ── 1. The colour test itself ────────────────────────────────────────────────────
const CASES = [
  ['#000', true], ['#fff', false], ['#15171c', true], ['#fdf6e3', false], ['#ffffff80', false],
  ['rgb(250, 250, 250)', false], ['rgba(0,0,0,0.5)', true], [' #0d1120 ', true],
  ['transparent', null], ['', null], ['var(--x)', null],
];
for (const impl of [['core.js', live.isDark], ['server_export.jl', exported(() => ({}), {}).isDark]]) {
  for (const [c, want] of CASES) {
    const got = impl[1](c);
    if (got !== want) fail(`${impl[0]} _slateIsDark(${JSON.stringify(c)}) = ${got}, want ${want}`);
  }
}

// ── 2. Every shipped palette gets an explicit, correct darkMode from both builders ─
const LIGHT = new Set(['daylight', 'solarized-light']);
const palettes = [];
for (const b of css.matchAll(/(:root|html\[data-slate-theme="([^"]+)"\])\s*\{([^}]*)\}/g)) {
  const bg = /--bg:\s*([^;]+);/.exec(b[3]);
  if (bg) palettes.push({ name: b[2] || 'midnight', bg: bg[1].trim() });
}
if (palettes.length < 7) die(`found only ${palettes.length} palettes in notebook.css`);
for (const { name, bg } of palettes) {
  const want = !LIGHT.has(name);
  const V = (n, d) => (n === '--bg' ? bg : d);
  const lt = live.theme(V), et = exportTheme({ '--bg': bg });
  if (lt.darkMode !== want) fail(`core.js theme for ${name} (--bg ${bg}): darkMode ${lt.darkMode}, want ${want}`);
  if (et.darkMode !== want) fail(`export theme for ${name} (--bg ${bg}): darkMode ${et.darkMode}, want ${want}`);
}

// ── 3. An unreadable background leaves ECharts' own 'auto' in charge ──────────────
if ('darkMode' in live.theme((n, d) => (n === '--bg' ? 'var(--nope)' : d))) fail('core.js set darkMode for an unparseable --bg');
if ('darkMode' in exportTheme({ '--bg': 'var(--nope)' })) fail('export theme set darkMode for an unparseable --bg');

if (bad) process.exit(1);
console.log(`echarts_dark_labels: ok (${palettes.length} palettes)`);
