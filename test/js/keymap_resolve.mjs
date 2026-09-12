// Asserts the chord layer of keymap.js: parsing, the two normal forms, display, what a KeyboardEvent
// resolves to, and which chords the browser will never hand over.
//
// This is the part of the keymap that has to be RIGHT rather than merely plausible, because everything
// else trusts it. The authored form (`Mod-Shift-k`) is what presets declare and what `keymap.json`
// stores, so a change in how it normalises silently rewrites everyone's saved keymap; the match form
// (`Meta-Shift-k`) is what the lookup index is keyed by AND what CodeMirror produces for the same
// chord, so a divergence means a binding works outside the editor and not inside it, or fires twice.
// Neither failure shows up in any Julia test, and in a browser both look like "that key sometimes
// doesn't work".
//
//   node test/js/keymap_resolve.mjs      # exit 0 = pass, 1 = mismatch, 2 = load failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const JS = join(here, '..', '..', 'src', 'assets', 'js');
const read = f => readFileSync(join(JS, f), 'utf8');

// Enough of a page for the three scripts to load: they register globals, attach one document listener
// and read localStorage. Nothing here fakes behaviour the test then asserts — the assertions all run
// against the real `window.slateKeymap`.
function loadKeymap(isMac) {
  const listeners = [];
  const win = {
    PLATFORM: { isMac, isWin: !isMac },
    addEventListener() {}, dispatchEvent() {},
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    fetch: () => Promise.reject(new Error('no server')),      // the boot-time GET, as in a static export
    setTimeout: () => 0, clearTimeout() {},
    CustomEvent: class { constructor(t) { this.type = t; } },
  };
  win.window = win;
  const doc = {
    addEventListener: (t, f, c) => listeners.push([t, f, c]),
    getElementById: () => null, querySelector: () => null,
    createElement: () => ({ style: {}, classList: { add() {}, remove() {} }, appendChild() {}, remove() {} }),
    body: { appendChild() {} },
  };
  const run = (src, name) => {
    try {
      new Function('window', 'document', 'localStorage', 'fetch', 'setTimeout', 'clearTimeout',
                   'CustomEvent', 'JSON', 'Set', 'Map', 'console', src)
        .call(win, win, doc, win.localStorage, win.fetch, win.setTimeout, win.clearTimeout,
              win.CustomEvent, JSON, Set, Map, console);
    } catch (e) {
      console.error('keymap_resolve: ' + name + ' failed to load: ' + e.message);
      process.exit(2);
    }
  };
  run(read('commands.js'), 'commands.js');
  run(read('keymaps.js'), 'keymaps.js');
  run(read('keymap.js'), 'keymap.js');
  if (!win.slateKeymap || !win.slateCmd) {
    console.error('keymap_resolve: the scripts loaded but published no slateKeymap/slateCmd');
    process.exit(2);
  }
  // A command is "available" when the function implementing it is on the page, and here none of them
  // are — this harness loads the three keyboard scripts, not the twenty that implement the actions. So
  // availability is forced on: what this file tests is chord resolution, and gating it on page shape
  // would just measure how much of the app the test happens to load.
  win.slateCmd.available = () => true;
  return win;
}

const fails = [];
const eq = (label, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) fails.push(`${label}: ${g} (expected ${w})`);
};
const ok = (label, cond) => { if (!cond) fails.push(label + ': expected true'); };

const mac = loadKeymap(true), pc = loadKeymap(false);
const M = mac.slateKeymap, P = pc.slateKeymap;

// ── The authored form ─────────────────────────────────────────────────────────
// Platform-neutral, one spelling per chord: `Mod-` stays `Mod-`, letters go lowercase and Shift is
// always explicit. That last rule is what stops `Mod-K` and `Mod-k` being two different bindings in a
// saved keymap — but it also means `Mod-K` is ⌘K, NOT ⌘⇧K, which is the trap worth pinning.
eq('canon Mod-K',        M.canon('Mod-K'), 'Mod-k');
eq('canon Shift-M',      M.canon('Shift-M'), 'Shift-m');
eq('canon shift-mod-k',  M.canon('shift-mod-k'), 'Mod-Shift-k');
eq('canon modifier order', M.canon('Shift-Alt-Ctrl-Mod-x'), 'Mod-Ctrl-Alt-Shift-x');
eq('canon named key case', M.canon('mod-arrowup'), 'Mod-ArrowUp');
// `-(?!$)` is CodeMirror's split, so a trailing `-` is the KEY rather than a dangling separator.
eq('canon trailing dash', M.canon('Mod-Shift--'), 'Mod-Shift--');
eq('canon is idempotent', M.canon(M.canon('Shift-Mod-K')), 'Mod-Shift-k');
eq('canon sequence',     M.canon('d  d'), 'd d');
// Each stroke normalises independently, and `Z` without a Shift modifier is the `z` key — the same
// rule as `Mod-K` above. Shift is never inferred from letter case.
eq('canon seq w/ mods',  M.canon('mod-k Z'), 'Mod-k z');
// A junk modifier invalidates the whole binding rather than being dropped — half a chord is worse than
// none, because it would bind something the author never asked for.
eq('canon rejects junk', M.canon('Hyper-k'), null);
eq('canon rejects empty', M.canon('   '), null);

// ── The match form ────────────────────────────────────────────────────────────
// `Mod` resolved per platform, modifiers in CodeMirror's Alt-Ctrl-Meta-Shift order. The index is keyed
// by this, so equality here IS "the same chord".
eq('match mac Mod',   M.match('Mod-k'), 'Meta-k');
eq('match pc Mod',    P.match('Mod-k'), 'Ctrl-k');
eq('match cm order',  M.match('Shift-Mod-Alt-Ctrl-x'), 'Alt-Ctrl-Meta-Shift-x');
eq('match pc order',  P.match('Mod-Shift-k'), 'Ctrl-Shift-k');
// Mod and Ctrl are DIFFERENT keys on a Mac (⌘ vs ⌃) and the same one elsewhere, which is exactly why
// presets are authored with Mod and only resolved here.
ok('mac Mod≠Ctrl', M.match('Mod-k') !== M.match('Ctrl-k'));
ok('pc Mod==Ctrl', P.match('Mod-k') === P.match('Ctrl-k'));

// ── What an event resolves to ────────────────────────────────────────────────
// The candidate list mirrors CodeMirror's own, in the same order, which is what makes a chord behave
// identically inside a cell editor and outside it.
const ev = o => Object.assign({ key: '', code: '', metaKey: false, ctrlKey: false,
                                altKey: false, shiftKey: false }, o);
const chords = (w, o) => w.slateKeymap.eventChords(ev(o));

eq('plain j', chords(mac, { key: 'j', code: 'KeyJ' }), ['j']);
// ⇧M arrives as key 'M'. `e.code` gives the unshifted 'm', so the stored form `Shift-m` is tried
// FIRST, with the literal 'M' kept as a fallback for a chord written that way.
eq('shift M', chords(mac, { key: 'M', code: 'KeyM', shiftKey: true }), ['Shift-m']);
eq('mod k', chords(mac, { key: 'k', code: 'KeyK', metaKey: true }), ['Meta-k']);
eq('mod shift k', chords(mac, { key: 'K', code: 'KeyK', metaKey: true, shiftKey: true }),
   ['Meta-Shift-k']);

// With Shift held, a bare (Shift-less) chord must NEVER be a candidate for a letter.
//
// `e.key` does not reliably carry the shifted character: Caps Lock inverts it, so ⇧Z arrives as `z`,
// and some layouts and browsers report the unshifted character whenever a modifier is down. When the
// bare form was emitted first, ⌘⇧Z matched the `Mod-z` binding and redo ran undo.
eq('caps-lock shift Z', chords(mac, { key: 'z', code: 'KeyZ', shiftKey: true }), ['Shift-z']);
eq('caps-lock mod shift Z', chords(mac, { key: 'z', code: 'KeyZ', metaKey: true, shiftKey: true }),
   ['Meta-Shift-z']);
ok('⌘⇧Z can never resolve to the ⌘Z binding',
   !chords(mac, { key: 'z', code: 'KeyZ', metaKey: true, shiftKey: true }).includes('Meta-z') &&
   !chords(mac, { key: 'Z', code: 'KeyZ', metaKey: true, shiftKey: true }).includes('Meta-z'));
// The same guarantee stated over the live index: undo and redo cannot answer to one another's chord.
for (const w of [mac, pc]) {
  for (const ev0 of [{ key: 'Z', code: 'KeyZ' }, { key: 'z', code: 'KeyZ' }]) {
    const mod = w === mac ? { metaKey: true } : { ctrlKey: true };
    const hits = c => w.slateKeymap.eventChords(ev(Object.assign({}, ev0, mod, c)))
      .flatMap(x => w.slateKeymap.lookup(x).map(t => t.id));
    const plain = hits({}), shifted = hits({ shiftKey: true });
    if (!plain.includes('nb.undo')) fails.push(`undo chord does not reach nb.undo (${JSON.stringify(ev0)})`);
    if (shifted.includes('nb.undo')) fails.push(`redo chord reaches nb.undo (${JSON.stringify(ev0)})`);
    if (!shifted.includes('nb.redo')) fails.push(`redo chord does not reach nb.redo (${JSON.stringify(ev0)})`);
  }
}
// A named key always carries Shift as a modifier — there is no shifted spelling of ⏎ or ↑.
eq('shift enter', chords(mac, { key: 'Enter', code: 'Enter', shiftKey: true }), ['Shift-Enter']);
eq('alt arrow', chords(mac, { key: 'ArrowUp', code: 'ArrowUp', altKey: true }), ['Alt-ArrowUp']);
// macOS turns ⌥M into `µ`, so without the `e.code` fallback `Alt-m` would be unreachable on a Mac.
eq('mac alt dead key', chords(mac, { key: 'µ', code: 'KeyM', altKey: true }), ['Alt-m', 'Alt-µ']);
// ⇧/ is `?`. Both spellings resolve, so a keymap may say either. The bare `?` stays a candidate here,
// unlike the letter case above, because it is a different CHARACTER rather than the same key in
// another case.
eq('shift slash', chords(mac, { key: '?', code: 'Slash', shiftKey: true }), ['Shift-/', 'Shift-?', '?']);
// Candidates come out in the index's normal form, so an uppercase letter is never emitted. A candidate
// the index could not possibly contain is dead weight, and `lookup` would disagree with dispatch.
ok('no uppercase letter candidates', !chords(mac, { key: 'K', code: 'KeyK', metaKey: true, shiftKey: true })
   .some(c => /-[A-Z]$|^[A-Z]$/.test(c)));
eq('space', chords(mac, { key: ' ', code: 'Space', ctrlKey: true }), ['Ctrl-Space']);
// Holding a modifier alone is not a chord — it must not consume the keypress or arm a sequence.
eq('bare modifier', chords(mac, { key: 'Shift', code: 'ShiftLeft', shiftKey: true }), []);

// The recorder's job is the inverse: an event in, the AUTHORED form out. ⌃ on a Mac stays Ctrl (it is
// its own modifier there); on Windows/Linux Ctrl IS Mod.
eq('record mac mod-shift-k', M.chordFromEvent(ev({ key: 'K', code: 'KeyK', metaKey: true, shiftKey: true })), 'Mod-Shift-k');
eq('record mac ctrl-a',      M.chordFromEvent(ev({ key: 'a', code: 'KeyA', ctrlKey: true })), 'Ctrl-a');
eq('record pc ctrl-shift-k', P.chordFromEvent(ev({ key: 'K', code: 'KeyK', ctrlKey: true, shiftKey: true })), 'Mod-Shift-k');
eq('record bare d',          M.chordFromEvent(ev({ key: 'd', code: 'KeyD' })), 'd');
eq('record arrow',           M.chordFromEvent(ev({ key: 'ArrowDown', code: 'ArrowDown', altKey: true })), 'Alt-ArrowDown');
// Round trip: whatever the recorder writes down must be what the dispatcher then matches.
for (const e of [{ key: 'K', code: 'KeyK', metaKey: true, shiftKey: true },
                 { key: 'M', code: 'KeyM', shiftKey: true },
                 { key: 'ArrowUp', code: 'ArrowUp', altKey: true },
                 { key: 'j', code: 'KeyJ' }]) {
  const written = M.match(M.chordFromEvent(ev(e)));
  ok('round trip ' + JSON.stringify(e), chords(mac, e).includes(written));
}

// ── Where a chord may fire ───────────────────────────────────────────────────
// A `global` binding is listened for everywhere, so a bare key there would eat ordinary typing. Escape
// and the function keys are the exceptions: neither produces text.
ok('Mod is global-safe', M.isGlobalSafe('Mod-k'));
ok('Alt is global-safe', M.isGlobalSafe('Alt-ArrowUp'));
ok('Escape is global-safe', M.isGlobalSafe('Escape'));
ok('F5 is global-safe', M.isGlobalSafe('F5'));
ok('bare j is NOT global-safe', !M.isGlobalSafe('j'));
ok('Shift-m is NOT global-safe', !M.isGlobalSafe('Shift-m'));
ok('sequence judged on its first stroke', !M.isGlobalSafe('d d'));

// ── Reserved and discouraged ─────────────────────────────────────────────────
// Reserved = the browser or OS takes it and `preventDefault` cannot get it back, so the panel refuses
// it outright; a warning would produce a binding that silently does nothing.
ok('Mod-t reserved', M.isReserved('Mod-t'));
ok('Mod-w reserved', M.isReserved('Mod-w'));
ok('Mod-1 reserved', M.isReserved('Mod-1'));
ok('mac ⌘M reserved', M.isReserved('Mod-m'));
ok('pc Ctrl-M not reserved', !P.isReserved('Mod-m'));     // ⌘M minimises on macOS only
ok('a sequence is judged on its first stroke', M.isReserved('Mod-t x'));
// Discouraged = bindable, because preventDefault works, but it shadows something the browser does.
// Slate itself takes ⌘F and ⌘K, so this has to be a warning and not a refusal.
ok('Mod-s warns', M.chordWarning('Mod-s').startsWith('shadows'));
ok('Mod-f warns', M.chordWarning('Mod-f').startsWith('shadows'));
ok('Mod-Shift-l is clean', M.chordWarning('Mod-Shift-l') === '');
ok('invalid chord is reported', M.chordWarning('Hyper-q') !== '');

// ── Display ──────────────────────────────────────────────────────────────────
// macOS glyph order is fixed by convention (⌃⌥⇧⌘) and is NOT the order chords are written in.
eq('format mac mod',      M.format('Mod-k'), '⌘K');
eq('format mac mod-shift', M.format('Mod-Shift-k'), '⇧⌘K');
eq('format mac all mods', M.format('Mod-Ctrl-Alt-Shift-x'), '⌃⌥⇧⌘X');
eq('format mac arrow',    M.format('Alt-ArrowUp'), '⌥↑');
eq('format mac enter',    M.format('Shift-Enter'), '⇧⏎');
// A letter in a chord reads uppercase, the way shortcuts are always written. A BARE command-mode key
// does not: `D` would read as ⇧D, and `dd` is two presses of the unshifted key.
eq('format bare letter',  M.format('d'), 'd');
eq('format mac sequence', M.format('d d'), 'd d');
eq('format shifted letter', M.format('Shift-m'), '⇧M');
eq('format pc mod-shift', P.format('Mod-Shift-k'), 'Ctrl+Shift+K');
eq('format pc enter',     P.format('Shift-Enter'), 'Shift+↵');

// ── Effective bindings, three layers deep ────────────────────────────────────
// Declared default → preset overlay → the user's overlay. A layer that MENTIONS a command replaces the
// one below, including with `[]`, which is how "deliberately unbound" differs from "inherit".
eq('default cell.delete', M.chordsFor('cell.delete'), ['d d']);
eq('default view.palette', M.chordsFor('view.palette'), ['Mod-k']);
eq('slate is the baseline', M.preset(), 'slate');

M.setPreset('jupyter');
// Jupyter takes ⌘↵ for "run this cell", so the preset has to UNBIND Slate's run-stale rather than
// leave two commands fighting over the chord. An empty list is the only way to say that.
eq('jupyter unbinds nb.runStale', M.chordsFor('nb.runStale'), []);
eq('jupyter cell.run', M.chordsFor('cell.run'), ['Mod-Enter']);
eq('jupyter interrupt', M.chordsFor('nb.cancel'), ['i i']);
// A command the preset says nothing about keeps the declared default.
eq('jupyter inherits cell.copy', M.chordsFor('cell.copy'), ['c']);
eq('source: preset', M.sourceOf('cell.run'), 'preset');
eq('source: default', M.sourceOf('cell.copy'), 'default');

M.setChords('cell.copy', ['Mod-Shift-c']);
eq('user overlay wins', M.chordsFor('cell.copy'), ['Mod-Shift-c']);
eq('source: custom', M.sourceOf('cell.copy'), 'custom');
ok('isCustom', M.isCustom('cell.copy'));
M.reset('cell.copy');
eq('reset falls back to the preset layer', M.chordsFor('cell.copy'), ['c']);
ok('no longer custom', !M.isCustom('cell.copy'));

M.setPreset('vim');
eq('vim yy copies', M.chordsFor('cell.copy'), ['y y']);
eq('vim unbinds cut', M.chordsFor('cell.cut'), []);
eq('vim u undoes', M.chordsFor('nb.undo'), ['u', 'Mod-z']);
M.setPreset('slate');
eq('back to slate', M.chordsFor('cell.copy'), ['c']);

// ── Which contexts a chord may serve ─────────────────────────────────────────
// `nb.undo` is bound in both `global` and `command`. ⌘Z is legal in both; a bare `z` — what the Jupyter
// preset wants — is legal in command mode only, and must be filtered OUT of `global` rather than
// rejected, or the preset could not express it at all.
const undo = mac.slateCmd.get('nb.undo');
eq('undo contexts', undo.ctx, ['global', 'command']);
eq('Mod-z serves both', M.contextsFor(undo, 'Mod-z'), ['global', 'command']);
eq('bare z is command-only', M.contextsFor(undo, 'z'), ['command']);

// ── Conflicts, and deliberate sharing ────────────────────────────────────────
// Two UNCONDITIONAL commands on one chord in one context is reported, not silently resolved, and the
// row that lost has to be able to say so.
M.setChords('cell.copy', ['x']);                       // `x` already cuts
const conflicts = M.conflicts();
ok('conflict detected', conflicts.some(c => c.ids.includes('cell.copy') && c.ids.includes('cell.cut')));
ok('the row knows', M.conflictsFor('cell.copy').length > 0);
M.reset('cell.copy');
eq('conflict clears', M.conflictsFor('cell.copy').length, 0);

// A SOFT command declines the key when it has nothing to do, so the chord falls through to the next
// claimant — which is how ⇧⌘G steps back through search hits with the find bar open and toggles the
// dependency graph without it. Sharing like that is deliberate, so it is NOT a conflict; and the soft
// one has to come first, because an unconditional handler never gives the key back.
const shared = M.lookup('Mod-Shift-g', 'global');
eq('both claim ⇧⌘G', shared.map(t => t.id), ['view.searchPrev', 'view.dag']);
eq('the soft one goes first', shared[0].soft, true);
eq('sharing is not a conflict', M.conflictsFor('view.dag').length, 0);

// A chord that is both a complete binding AND the prefix of a longer one cannot be both. The shorter
// wins immediately — waiting to see whether a second stroke arrives would make every press feel like a
// stall — and the collision is reported.
M.setChords('cell.copy', ['d']);                       // `d d` deletes
ok('prefix collision reported', M.conflicts().some(c => c.prefix));
M.reset('cell.copy');

// ── The editor's share ───────────────────────────────────────────────────────
// Only commands whose contexts include `editor`, and never an `inst` one: ⇧⏎ means "run the cell" in a
// code cell and "commit the source" in a markdown overlay, so the editor binds those itself and a
// generic binding here would shadow whichever one was right.
const specs = M.editorSpecs();
ok('editor specs include the docs chord', specs.some(s => s.id === 'view.docs' && s.key === 'Mod-Shift-k'));
ok('editor specs include comment toggle', specs.some(s => s.id === 'editor.comment'));
ok('editor specs exclude command-only', !specs.some(s => s.id === 'cell.copy'));
ok('editor specs exclude inst commands', !specs.some(s => s.id === 'cell.run'));
ok('every spec carries a runner', specs.every(s => typeof s.run === 'function'));

// ── Round trip through JSON ──────────────────────────────────────────────────
// What `keymap.json` holds. It has to survive the trip unchanged, since the file is also meant to be
// hand-edited and copied between machines.
M.setPreset('vscode');
M.setChords('cell.merge', ['Mod-Alt-m']);
const dump = M.toJSON();
eq('export carries the preset', dump.preset, 'vscode');
eq('export carries the overlay', dump.bindings['cell.merge'], ['Mod-Alt-m']);
M.resetAll(); M.setPreset('slate');
eq('reset clears the overlay', M.toJSON().bindings, {});
ok('import restores it', M.fromJSON(JSON.parse(JSON.stringify(dump))));
eq('imported preset', M.preset(), 'vscode');
eq('imported binding', M.chordsFor('cell.merge'), ['Mod-Alt-m']);
// Leave the keymap clean: the preset sweep below asserts what each preset ships, and an overlay left
// behind here would be attributed to whichever preset was selected at the time.
M.resetAll(); M.setPreset('slate');

// ── No preset may ship a chord the browser keeps ─────────────────────────────
// The whole point of shipping presets rather than telling people to build one is that ours are known
// to work. A reserved chord in a preset is a binding that does nothing, on both platforms.
for (const w of [mac, pc]) {
  const km = w.slateKeymap;
  for (const p of km.presets()) {
    km.setPreset(p.name);
    for (const c of w.slateCmd.all()) {
      for (const chord of km.chordsFor(c.id)) {
        if (km.isReserved(chord)) fails.push(`preset ${p.name} binds ${c.id} to the reserved ${chord}`);
        if (!km.canon(chord)) fails.push(`preset ${p.name} binds ${c.id} to the unparseable ${chord}`);
        // A `global` command with a bare chord would be filtered out of its own context and silently
        // never fire, which reads exactly like a broken keymap.
        if (c.ctx.length === 1 && c.ctx[0] === 'global' && !km.isGlobalSafe(chord)) {
          fails.push(`preset ${p.name} gives the global-only ${c.id} the bare chord ${chord}`);
        }
      }
    }
    // Every preset must be internally consistent — shipping one with a conflict would hand someone a
    // keymap where one of two commands silently loses.
    for (const k of km.conflicts()) {
      fails.push(`preset ${p.name} conflicts on ${k.chord} (${k.ctx}): ${k.ids.join(' vs ')}`);
    }
  }
}

// ── Every command is reachable and described ──────────────────────────────────
// The registry is what the Keyboard panel and the palette both render, so a command with no label or a
// duplicate id is a blank row in two places.
const all = mac.slateCmd.all();
ok('the registry is populated', all.length > 30);
eq('ids are unique', all.length, new Set(all.map(c => c.id)).size);
for (const c of all) {
  if (!c.label || c.label === c.id) fails.push(`${c.id} has no human label`);
  if (!c.group) fails.push(`${c.id} has no group`);
  if (!c.ctx.length) fails.push(`${c.id} declares no context`);
  for (const ctx of c.ctx) {
    if (!['global', 'command', 'editor'].includes(ctx)) fails.push(`${c.id} has the unknown context ${ctx}`);
  }
}

if (fails.length) { console.error('keymap_resolve FAIL:\n' + fails.join('\n')); process.exit(1); }
console.log('keymap_resolve OK (' + all.length + ' commands)');
