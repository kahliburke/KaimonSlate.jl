// A class styled in only ONE of the two stylesheets, used by code that runs on both pages.
//
// The home page and a notebook do not share CSS: the notebook links notebook.css, the home page
// carries its own inline <style>, and shared.css is the only sheet both load. So a component used
// by both renders unstyled on one of them unless its classes live in shared.css — which is not a
// visible failure, just a control in the wrong place or a spinner that never appears.
//
// Both directions, since either sheet can be the one holding a class hostage.
import fs from 'fs';
import path from 'path';

const A = path.join(path.dirname(new URL(import.meta.url).pathname), '..', '..', 'src', 'assets');
const read = f => fs.readFileSync(path.join(A, f), 'utf8');

// Every js file a page pulls in, following same-directory imports so an island's helpers count.
function reachable(entry) {
  const seen = new Set(), queue = [...entry];
  while (queue.length) {
    const f = queue.shift();
    if (seen.has(f) || !fs.existsSync(path.join(A, 'js', f))) continue;
    seen.add(f);
    for (const m of read(path.join('js', f)).matchAll(/from\s+'\.\/([\w.-]+\.js)'/g)) queue.push(m[1]);
  }
  return seen;
}
const scriptsOf = html => [...read(html).matchAll(/src="\/assets\/js\/([\w.-]+\.js)"/g)].map(m => m[1]);

function classesUsed(files) {
  const used = new Set();
  for (const f of files) {
    const src = read(path.join('js', f));
    for (const m of src.matchAll(/class(?:Name)?\s*=\s*[$]?\{?\s*['"`]([^'"`]+)['"`]/g))
      m[1].split(/\s+/).forEach(c => c && used.add(c));
    for (const m of src.matchAll(/class="([^"]+)"/g)) m[1].split(/\s+/).forEach(c => c && used.add(c));
    for (const m of src.matchAll(/classList\.(?:add|toggle|remove)\(\s*['"]([\w-]+)/g)) used.add(m[1]);
  }
  return used;
}
const classesIn = txt => new Set([...txt.matchAll(/\.([a-zA-Z][\w-]*)/g)].map(m => m[1]));

const idx = read('index.html');
const homeInline = classesIn(idx.slice(idx.indexOf('<style>'), idx.lastIndexOf('</style>')));
const nbCss = classesIn(read('notebook.css'));
const shared = classesIn(read('shared.css'));

const problems = [];
for (const [label, files, only, missingFrom] of [
  ['home page', reachable(scriptsOf('index.html')), nbCss, 'notebook.css'],
  ['notebook', reachable(scriptsOf('notebook.html')), homeInline, "the home page's inline <style>"],
]) {
  for (const c of [...classesUsed(files)].sort()) {
    if (only.has(c) && !shared.has(c) && !(label === 'home page' ? homeInline : nbCss).has(c))
      problems.push(`  .${c} — used by ${label} js, styled only in ${missingFrom}`);
  }
}

if (problems.length) {
  console.log('classes styled where the page using them cannot see:\n' + problems.join('\n'));
  console.log('\nMove them to src/assets/shared.css, which both pages load.');
  process.exit(1);
}
console.log('shared styles: every class a shared component uses is visible to both pages');
