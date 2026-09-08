// Asserts src/assets/js/schedopts.js — the rules a scheduler option's NAME obeys.
//
// Two editors set these: a sweep cell and a region. They have to agree about what a name means, or
// the same setting typed in both places becomes two settings that emit one flag. The markup differs
// and the vocabulary must not, so the vocabulary lives in one file and this is what pins it.
//
//   node test/js/sched_opts.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'schedopts.js'), 'utf8');

let SO;
try { (0, eval)(src); SO = globalThis.slateSchedOpts; } catch (e) {
  console.error('sched_opts: could not evaluate schedopts.js —', e.message); process.exit(2);
}
if (!SO) { console.error('sched_opts: schedopts.js defined nothing'); process.exit(2); }

// The catalogue is served, so stand one in. Shapes match `Sweep.sched_options()`: a key, how each
// scheduler spells it (empty = it cannot), a hint, and whether it must be a number.
const CAT = [
  { key: 'cpus',       flag: 'cpus-per-task', pbs: 'select=…:ncpus', hint: 'CPUs per unit', count: true },
  { key: 'constraint', flag: 'constraint',    pbs: '',               hint: 'node features required', count: false },
  { key: 'qos',        flag: 'qos',           pbs: '-l qos',         hint: 'quality of service', count: false },
  { key: 'exclusive',  flag: 'exclusive',     pbs: '-l place',       hint: 'do not share the node', count: false },
  // The form has a box for this one, which is the whole point of the exclusion below.
  { key: 'mem',        flag: 'mem',           pbs: 'select=…:mem',   hint: 'memory per node', count: false },
];
globalThis.fetch = () => Promise.resolve({ json: () => Promise.resolve({ options: CAT }) });

const fails = [];
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fails.push(`${label}: got ${g}, want ${w}`);
};

await SO.load();
eq('the catalogue loads once', SO.all().length, CAT.length);

// ── naming ──────────────────────────────────────────────────────────────────────────────────────
{
  // Slate's key and the scheduler's spelling must land on the SAME stored key. Otherwise the two
  // editors store `cpus` and `cpus_per_task`, and both emit `--cpus-per-task`.
  eq('slate key', SO.toKey('cpus'), 'cpus');
  eq('sbatch spelling folds onto it', SO.toKey('cpus-per-task'), 'cpus');
  eq('leading dashes are not part of a name', SO.toKey('--constraint'), 'constraint');
  eq('and neither is surrounding space', SO.toKey('  qos  '), 'qos');
  // An uncatalogued name is kept, with `-` folded to `_`: a stored key has to match
  // [A-Za-z][A-Za-z0-9_]* and no sbatch long option contains `_`.
  eq('a site option survives', SO.toKey('my-site-flag'), 'my_site_flag');
  eq('nothing is nothing', SO.toKey(''), '');
  eq('null does not throw', SO.toKey(null), '');
}

// ── what an editor says about a name ─────────────────────────────────────────────────────────────
{
  // Catalogued and sayable: no comment.
  eq('a known slurm option is unremarkable', SO.warnFor('constraint', 'slurm'), '');
  // Catalogued but this scheduler cannot express it. Worth saying, because the job would be
  // submitted without it and nothing else would mention that.
  eq('constraint has no PBS spelling', SO.warnFor('constraint', 'pbs'), 'no pbs equivalent');
  eq('qos does have one', SO.warnFor('qos', 'pbs'), '');
  // Not catalogued: a warning, NEVER a refusal. Sites add their own options, and one silently
  // dropped is worse than one nobody suggested.
  eq('an unknown name warns', SO.warnFor('my_site_flag', 'slurm'), 'unknown option');
  eq('an empty name says nothing', SO.warnFor('', 'slurm'), '');
}

// ── spelling and hints ──────────────────────────────────────────────────────────────────────────
{
  const cpus = SO.find('cpus');
  eq('slurm shows its own flag', SO.spellOf(cpus, 'slurm'), 'cpus-per-task');
  // PBS has no single flag for most settings, so the stored key is shown and the PBS form is in
  // the hint — the box would otherwise hold something that is not a flag.
  eq('pbs shows the slate key', SO.spellOf(cpus, 'pbs'), 'cpus');
  eq('and puts its own form in the hint', SO.hintOf(cpus, 'pbs'), 'select=…:ncpus — CPUs per unit');
  const con = SO.find('constraint');
  eq('an unsayable option says so', SO.hintOf(con, 'pbs'), 'no pbs equivalent — node features required');
  eq('availability, slurm', SO.availOf(con, 'slurm'), true);
  eq('availability, pbs', SO.availOf(con, 'pbs'), false);
}

// ── suggestions ─────────────────────────────────────────────────────────────────────────────────
{
  const sug = SO.suggestions('pbs');
  eq('every option is offered', sug.length, CAT.length);
  // Including the ones this scheduler cannot say. Hiding them answers "why is it not offered?"
  // with silence; showing them with the reason answers it.
  const con = sug.find(o => o.key === 'constraint');
  eq('an unsayable one is still listed', !!con, true);
  eq('marked unavailable', con.available, false);
  eq('with the reason in its hint', /no pbs equivalent/.test(con.hint), true);
}

// ── the suggestion filter ───────────────────────────────────────────────────────────────────────
// Shared with the sweep cell, which learned the rules first: nothing until you type, prefix before
// substring, and never an option this scheduler cannot say.
{
  eq('nothing typed offers nothing', SO.matches('', 'slurm').length, 0);
  eq('whitespace is nothing', SO.matches('   ', 'slurm').length, 0);

  // Prefix wins over substring: typing `cpus` should reach `cpus-per-task` before anything that
  // merely contains it.
  const cpu = SO.matches('cpu', 'slurm').map(o => o.key);
  eq('cpu finds cpus-per-task', cpu.includes('cpus'), true);

  // A fully typed name stays in the list, at the top. It used to be dropped, which meant typing
  // `mem` in full showed only `mem-per-cpu` and read as though `mem` were not an option.
  eq('an exact name is still offered', SO.matches('mem', 'slurm').map(o => o.key), ['mem']);
  eq('and it comes first', SO.matches('cpus', 'slurm').map(o => o.key)[0], 'cpus');

  // Dashes and underscores are the same word, and leading dashes are not part of a name.
  eq('underscores match dashes', SO.matches('cpus_per', 'slurm').map(o => o.key), ['cpus']);
  eq('leading dashes are ignored', SO.matches('--constr', 'slurm').map(o => o.key), ['constraint']);

  // An option this scheduler cannot express is never offered: acting on the suggestion would only
  // produce a rejected job.
  eq('slurm offers constraint', SO.matches('constr', 'slurm').map(o => o.key), ['constraint']);
  eq('pbs does not', SO.matches('constr', 'pbs').map(o => o.key), []);

  // A name the region form already has a box for is not offered: it would be a second way to say
  // what the form is already saying, and the request drops the duplicate anyway.
  eq('mem has a box, so it is not suggested',
     SO.matches('me', 'slurm', 9, SO.FIELD_OWNED).map(o => o.key).includes('mem'), false);
  // The sweep cell passes no exclusions — there the options ARE the per-cell override of a
  // cluster's defaults, so `mem` meaning "mem, but here" is the point.
  eq('the cell still gets it', SO.matches('me', 'slurm', 9).map(o => o.key).includes('mem'), true);

  // Capped, because the menu sits on top of the fields under it.
  eq('the menu is bounded', SO.matches('', 'slurm', 2).length <= 2, true);
  eq('there is a default cap', typeof SO.MENU_MAX, 'number');
}

// Both editors resolve a name through this, so the same input has to give the same key whichever
// one is asking. Stated as a property rather than trusted.
for (const typed of ['cpus', 'cpus-per-task', '--cpus-per-task', ' cpus ']) {
  if (SO.toKey(typed) !== 'cpus') fails.push(`"${typed}" should store as cpus, got ${SO.toKey(typed)}`);
}

// ── the readers actually share it ───────────────────────────────────────────────────────────────
// `sweeps.js` filters through this file. It also keeps its own copy of the catalogue for its other
// helpers, and for a while it filled that copy with its OWN fetch — which left the shared one empty
// and the cell's suggestion menu silently offering nothing. Two copies of one list is the exact
// thing this file exists to prevent, so the sharing is asserted rather than assumed.
{
  const sw = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'sweeps.js'), 'utf8');
  // The property, not a spelling: there must be exactly ONE fetcher of the catalogue. When
  // sweeps.js fetched its own, the shared copy stayed empty and the cell's menu offered nothing.
  if (/fetch\(\s*['"`]\/api\/sched-options/.test(sw)) {
    fails.push('sweeps.js fetches the catalogue itself — the shared copy would stay empty');
  }
  if (!/slateSchedOpts/.test(sw)) {
    fails.push('sweeps.js does not go through the shared catalogue at all');
  }
  // Both pages have to ship it, or the reader on that page finds nothing.
  for (const page of ['notebook.html', 'index.html']) {
    const h = readFileSync(join(here, '..', '..', 'src', 'assets', page), 'utf8');
    if (!/js\/schedopts\.js/.test(h)) fails.push(page + ' does not load schedopts.js');
  }
}

if (fails.length) {
  console.error('sched_opts: ' + fails.length + ' failure(s)');
  for (const f of fails) console.error('  - ' + f);
  process.exit(1);
}
console.log('sched_opts: ok');
