// Scheduler options: the catalogue, and the rules for naming one.
//
// Two places let you set them — a sweep cell (`sweeps.js`) and a region (`remotes-focus.js`) — and
// they must agree about what a name MEANS, or the same setting typed in both places becomes two
// settings that emit the same flag. So the rules live here and each page draws its own rows: the
// markup differs (a cell panel, a form row), the vocabulary must not.
//
// The catalogue itself comes from the server (`/api/sched-options`, built from
// `Sweep.sched_options()`), not from a list in JS, so what the editor offers is what Slate types
// and validates. A CATALOGUE, not a permitted set: an unrecognised name warns and is still sent,
// because a scheduler has far more options than are worth naming and sites add their own. Refusing
// what we have not heard of would be the same mistake as silently dropping it.
//
// A CLASSIC script, like model.js and for the same reason: `sweeps.js` is a classic script, so a
// module could not promise to exist before it runs.
(function () {
  'use strict';

  let CATALOGUE = [];
  let loading = null;

  // One fetch per page, shared by every editor on it. Raw fetch: this list belongs to the MACHINE,
  // and the notebook page's `api()` would rewrite the path into a per-notebook namespace.
  function load() {
    if (CATALOGUE.length) return Promise.resolve(CATALOGUE);
    if (loading) return loading;
    loading = fetch('/api/sched-options').then(r => r.json())
      .then(d => { CATALOGUE = (d && d.options) || []; return CATALOGUE; })
      .catch(() => CATALOGUE)
      .finally(() => { loading = null; });
    return loading;
  }
  const all = () => CATALOGUE;

  // By either spelling: the stored key, or the flag a scheduler calls it. Typing `cpus-per-task`
  // has to land on the same entry as picking `cpus` from the list.
  const find = k => CATALOGUE.find(o => o.key === k || o.flag === k) || null;

  // What the user typed → the key it is STORED under. The catalogue lookup comes first, because
  // three of Slate's names differ from sbatch's; otherwise `-` becomes `_`, since a stored key must
  // match [A-Za-z][A-Za-z0-9_]* and no sbatch long option contains `_`.
  function toKey(s) {
    const t = String(s == null ? '' : s).trim().replace(/^-+/, '');
    const o = find(t) || find(t.replace(/-/g, '_'));
    return o ? o.key : t.replace(/-/g, '_');
  }

  // How a key is SPELLED for a scheduler. PBS has no single flag for most settings (they are chunk
  // fragments), so there the stored key is shown and the PBS form goes in the hint.
  const spellOf = (o, kind) => (kind === 'pbs' ? o.key : o.flag);
  // Can this scheduler say it at all? An empty spelling means it cannot, which an editor shows
  // rather than offering a setting whose only effect would be a rejected job.
  const availOf = (o, kind) => (kind === 'pbs' ? o.pbs !== '' : o.flag !== '');
  const hintOf = (o, kind) => (!availOf(o, kind) ? `no ${kind} equivalent — ${o.hint}`
                             : kind === 'pbs' && o.pbs ? `${o.pbs} — ${o.hint}` : o.hint);

  // What to say about a name as it is typed: nothing when it is catalogued and this scheduler can
  // say it, otherwise why it is worth a second look. Never an error — the name is sent either way.
  function warnFor(key, kind) {
    if (!key) return '';
    const o = find(key);
    if (!o) return 'unknown option';
    return availOf(o, kind) ? '' : `no ${kind} equivalent`;
  }

  // The options a scheduler can express, for a suggestion list. Unavailable ones are kept, with
  // their hint saying so: hiding them answers "why is it not offered?" with silence.
  const suggestions = (kind) => CATALOGUE.map(o => ({
    key: o.key, label: spellOf(o, kind), hint: hintOf(o, kind),
    available: availOf(o, kind), count: !!o.count,
  }));

  // What to offer for what has been typed so far.
  //
  // NOT a `<datalist>`, and the reason is in the sweep cell that learned it first: a datalist shows
  // the whole list the moment the box is focused, which buries the fields under it, and the browser
  // draws it so CSS cannot cap it. So: nothing until you type, filtered, and a handful at a time.
  //
  // Prefix before substring, so typing `mem` offers `mem` ahead of `mem-per-cpu` while `cpu` still
  // finds `cpus-per-task`. An option this scheduler cannot say is not offered at all — suggesting
  // one whose only effect would be a rejected job is worse than saying nothing.
  // Names the REGION FORM already has a box for. Suggesting one would offer a second way to say
  // something the form is already saying, and the request drops a duplicate anyway. The sweep cell
  // passes `[]`: there the options ARE the override of a cluster's defaults, so `mem` meaning "mem,
  // but for this cell" is the whole point.
  const FIELD_OWNED = ['cpus', 'mem', 'walltime', 'partition', 'account', 'gpus'];

  const MENU_MAX = 6;
  function matches(typed, kind, max, owned) {
    const skip = owned || [];
    const t = String(typed == null ? '' : typed).trim()
      .replace(/^-+/, '').replace(/_/g, '-').toLowerCase();
    if (!t) return [];
    const pre = [], mid = [];
    for (const o of CATALOGUE) {
      if (!availOf(o, kind)) continue;
      if (skip.includes(o.key)) continue;      // the form already has a box for it
      const f = String(spellOf(o, kind)).toLowerCase().replace(/_/g, '-');
      // An exact match is KEPT, and first. Dropping it meant typing `mem` in full left the menu
      // showing only `mem-per-cpu`, which reads as "mem is not an option" — the opposite of true.
      // Listed, it confirms the name is catalogued and picking it dismisses the menu.
      if (f === t) pre.unshift(o);
      else if (f.startsWith(t)) pre.push(o);
      else if (f.includes(t)) mid.push(o);
    }
    return [...pre, ...mid].slice(0, max || MENU_MAX);
  }

  const api = { load, all, find, toKey, spellOf, availOf, hintOf, warnFor, suggestions,
                matches, MENU_MAX, FIELD_OWNED };
  if (typeof window !== 'undefined') window.slateSchedOpts = api;
  if (typeof globalThis !== 'undefined') globalThis.slateSchedOpts = api;   // for the node tests
})();
