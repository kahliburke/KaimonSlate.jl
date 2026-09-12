// ── Keymap: chords in, commands out ───────────────────────────────────────────
// One resolver owns every keyboard shortcut in the notebook. It replaces three parallel if/else
// ladders: command-mode keys in keyboard.js, ⌘-chords in palette.js, in-editor bindings in editor.js.
// Each had its own idea of what counted as "in a field", its own modal check, and its own hand-written
// copy of the chord for the palette to display.
//
// ── Three contexts ─────────────────────────────────────────────────────────────
//
//   command   a cell is selected and you are NOT editing it. Bare keys live here (j, dd, m) because
//             no editor has focus, so they cannot swallow typing.
//   global    anywhere outside a cell editor. A chord here must carry ⌘/⌃/⌥ or be a function key,
//             since a bare global key would eat every keystroke in the document.
//   editor    inside a CodeMirror editor, dispatched by CM6's own keymap rather than from here, so a
//             binding can out-rank the editor's text-editing defaults. editor.js asks for the specs.
//
// A command that is `global` AND `editor` (⌘K, ⌘⇧K, ⌘F) is installed in CM6 as well as on the
// document. The document listener stays out of the editor's way structurally: an event originating
// inside `.cm-editor` returns immediately, leaving those chords to CM6.
//
// ── Chord notation ─────────────────────────────────────────────────────────────
// CodeMirror's own normal form, so the same string works for the editor context:
//
//   Mod-Shift-k     ⌘⇧K on macOS, Ctrl+Shift+K elsewhere   (Mod = ⌘ on mac, Ctrl otherwise)
//   Alt-ArrowUp     ⌥↑
//   d d             a two-stroke sequence (the `dd` delete generalised)
//   Mod-k z         a sequence whose first stroke carries a modifier
//
// Single letters are always lowercase with an explicit `Shift-`: `Shift-m`, never `M`.
//
// A chord has two forms. `Mod-Shift-k` is the AUTHORED form, what presets declare, `keymap.json`
// stores and the UI shows; it is platform-neutral so a keymap moves between machines. `Meta-Shift-k`
// is the MATCH form, with Mod resolved for this platform, and is what the lookup index is keyed by.

(function () {
  const MAC = !!(window.PLATFORM && window.PLATFORM.isMac);

  // Named (non-printing) keys, lowercase → canonical casing. A chord may be authored in any casing;
  // the index only ever sees the canonical spelling.
  const NAMED = {};
  for (const n of ['Enter', 'Escape', 'Tab', 'Space', 'Backspace', 'Delete', 'Insert',
                   'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
                   'Home', 'End', 'PageUp', 'PageDown',
                   'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12']) {
    NAMED[n.toLowerCase()] = n;
  }

  // ── Parsing ────────────────────────────────────────────────────────────────
  // `-(?!$)` is CodeMirror's split: it leaves a trailing `-` as the key, so `Mod-Shift--` (⌘⇧ and the
  // minus key) parses the way it reads.
  function parseChord(spec) {
    const parts = String(spec == null ? '' : spec).trim().split(/-(?!$)/);
    let base = parts[parts.length - 1];
    if (!base) return null;
    const m = { mod: false, meta: false, ctrl: false, alt: false, shift: false };
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (/^mod$/i.test(p)) m.mod = true;
      else if (/^(cmd|meta|m)$/i.test(p)) m.meta = true;
      else if (/^(c|ctrl|control)$/i.test(p)) m.ctrl = true;
      else if (/^a(lt|ption)?$/i.test(p)) m.alt = true;
      else if (/^s(hift)?$/i.test(p)) m.shift = true;
      else return null;                                    // an unrecognised modifier is not a chord
    }
    if (base.length === 1) {
      // A letter is stored lowercase and Shift is always explicit, so `Mod-K` means ⌘K (not ⌘⇧K) and
      // there is exactly one spelling of every chord. Uppercase-without-Shift would otherwise be a
      // second, silently-different way to write the same thing.
      if (/[A-Za-z]/.test(base)) base = base.toLowerCase();
    } else {
      base = NAMED[base.toLowerCase()] || base;
    }
    m.base = base;
    return m;
  }

  const _join = (parts, base) => parts.length ? parts.join('-') + '-' + base : base;

  // The authored form — `Mod-` left unresolved, so this is what gets stored and displayed.
  function canonChord(spec) {
    const m = parseChord(spec);
    if (!m) return null;
    const p = [];
    if (m.mod) p.push('Mod');
    if (m.meta) p.push('Meta');
    if (m.ctrl) p.push('Ctrl');
    if (m.alt) p.push('Alt');
    if (m.shift) p.push('Shift');
    return _join(p, m.base);
  }

  // The match form — `Mod` resolved for this platform, modifiers in CodeMirror's order. Two chords
  // are the same chord exactly when their match forms are equal.
  function matchChord(spec) {
    const m = parseChord(spec);
    if (!m) return null;
    if (m.mod) { MAC ? (m.meta = true) : (m.ctrl = true); }
    const p = [];
    if (m.alt) p.push('Alt');
    if (m.ctrl) p.push('Ctrl');
    if (m.meta) p.push('Meta');
    if (m.shift) p.push('Shift');
    return _join(p, m.base);
  }

  // A binding may be a SEQUENCE of chords (`d d`, `Mod-k z`). Both forms map over the strokes.
  const _seq = (spec, f) => {
    const out = [];
    for (const s of String(spec == null ? '' : spec).trim().split(/\s+/)) {
      if (!s) continue;
      const c = f(s);
      if (!c) return null;                                 // one bad stroke invalidates the binding
      out.push(c);
    }
    return out.length ? out.join(' ') : null;
  };
  const canon = spec => _seq(spec, canonChord);
  const match = spec => _seq(spec, matchChord);

  // Does this chord carry a modifier that makes it safe to listen for everywhere? Escape and the
  // function keys qualify: neither produces text.
  function isGlobalSafe(spec) {
    const first = String(spec || '').trim().split(/\s+/)[0];
    const m = parseChord(first);
    if (!m) return false;
    if (m.mod || m.meta || m.ctrl || m.alt) return true;
    return m.base === 'Escape' || /^F\d+$/.test(m.base);
  }

  // ── Display ────────────────────────────────────────────────────────────────
  const GLYPH_MAC = { Enter: '⏎', Escape: '⎋', Tab: '⇥', Space: '␣', Backspace: '⌫', Delete: '⌦',
                      ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→',
                      Home: '↖', End: '↘', PageUp: '⇞', PageDown: '⇟' };
  const GLYPH_PC = { Enter: '↵', Escape: 'Esc', Tab: 'Tab', Space: 'Space', Backspace: '⌫',
                     Delete: 'Del', ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→',
                     Home: 'Home', End: 'End', PageUp: 'PgUp', PageDown: 'PgDn' };

  function formatChord(spec) {
    const m = parseChord(spec);
    if (!m) return String(spec || '');
    const G = MAC ? GLYPH_MAC : GLYPH_PC;
    // A letter in a CHORD is shown uppercase, the way every keyboard shortcut is written (⌘K, ⇧⌘Z).
    // A bare command-mode key is shown as typed, because there uppercase would be a lie — `D` reads as
    // ⇧D, and `dd` is two presses of the unshifted key.
    const anyMod = m.mod || m.meta || m.ctrl || m.alt || m.shift;
    const base = m.base.length === 1 ? (anyMod ? m.base.toUpperCase() : m.base) : (G[m.base] || m.base);
    if (MAC) {
      // The macOS order is fixed by convention: ⌃⌥⇧⌘, then the key, with no separators.
      let s = '';
      if (m.ctrl) s += '⌃';
      if (m.alt) s += '⌥';
      if (m.shift) s += '⇧';
      if (m.meta || m.mod) s += '⌘';
      return s + base;
    }
    const p = [];
    if (m.mod || m.ctrl) p.push('Ctrl');
    if (m.meta) p.push('Meta');
    if (m.alt) p.push('Alt');
    if (m.shift) p.push('Shift');
    p.push(base);
    return p.join('+');
  }
  // A sequence reads as its strokes, space-separated: `d d`, `⌘K Z`.
  const format = spec => String(spec == null ? '' : spec).trim().split(/\s+/)
    .filter(Boolean).map(formatChord).join(' ');

  // ── A KeyboardEvent's candidate chords ─────────────────────────────────────
  // One event can legitimately match several written forms, and CodeMirror tries them in this same
  // order, which is why the editor and the document agree about what a key "is". `e.code` gives the
  // UNSHIFTED character, which is how ⇧M is recognised as `Shift-m` rather than as the literal `M`,
  // and how macOS's ⌥M — which arrives as `µ` in `e.key` — is still recognised as `Alt-m`.
  const CODE_BASE = { Comma: ',', Period: '.', Slash: '/', Semicolon: ';', Quote: "'",
                      BracketLeft: '[', BracketRight: ']', Backslash: '\\', Backquote: '`',
                      Minus: '-', Equal: '=' };
  function baseChar(e) {
    const c = e.code || '';
    if (/^Key[A-Z]$/.test(c)) return c.slice(3).toLowerCase();
    if (/^Digit[0-9]$/.test(c)) return c.slice(5);
    if (/^Numpad[0-9]$/.test(c)) return c.slice(6);
    return CODE_BASE[c] || '';
  }
  const MODIFIER_KEYS = { Shift: 1, Control: 1, Alt: 1, Meta: 1, CapsLock: 1, AltGraph: 1 };

  function eventChords(e) {
    const k = e.key;
    if (!k || MODIFIER_KEYS[k]) return [];
    const name = k === ' ' ? 'Space' : k;
    const isChar = name.length === 1;
    const bc = baseChar(e);
    const out = [];
    // Candidates are emitted in the index's own normal form, so a letter is lowercased here exactly as
    // `matchChord` lowercases it. Without that, `Meta-Z` would be produced for ⌘⇧Z and could never
    // match anything (every index key spells letters lowercase), while `lookup` — which does normalize
    // — would claim it resolved to the ⌘Z binding. Same spelling on both sides, or the two disagree.
    const add = (raw, shift) => {
      if (!raw) return;
      const base = raw.length === 1 && /[A-Za-z]/.test(raw) ? raw.toLowerCase() : raw;
      const p = [];
      if (e.altKey) p.push('Alt');
      if (e.ctrlKey) p.push('Ctrl');
      if (e.metaKey) p.push('Meta');
      if (shift) p.push('Shift');
      const s = _join(p, base);
      if (out.indexOf(s) < 0) out.push(s);
    };
    if (!isChar) { add(name, e.shiftKey); return out; }
    // The unshifted character for this physical key. `e.code` normally supplies it; failing that, a
    // letter's own lowercase form will do.
    const base = bc || (/[A-Za-z]/.test(name) ? name.toLowerCase() : '');
    if (e.shiftKey) {
      // With Shift held, ONLY Shift-bearing forms are candidates. `e.key` does not always carry the
      // shifted character: Caps Lock inverts it, and some layouts and browsers report the unshifted
      // one whenever a modifier is down. Emitting the bare form here made ⌘⇧Z match the `Mod-z`
      // binding, so redo ran undo.
      add(base, true);
      add(name, true);
      // The exception is a key whose shifted form is a DIFFERENT character (⇧/ is `?`) rather than the
      // same letter in another case, since writing the chord as that character is legitimate.
      if (base && base.toLowerCase() !== name.toLowerCase()) add(name, false);
      return out;
    }
    // Physical key first, then the literal character, so a chord written as `µ` still resolves while
    // macOS's ⌥M — which arrives as `µ` — is still recognised as `Alt-m`.
    if (base && base !== name) add(base, false);
    add(name, false);
    return out;
  }

  // The authored chord for a captured event — what the Keyboard panel writes down when you press a
  // key at it. Ctrl on macOS is a modifier in its own right (⌃) and is never folded into Mod.
  function chordFromEvent(e) {
    const k = e.key;
    if (!k || MODIFIER_KEYS[k]) return null;
    const name = k === ' ' ? 'Space' : k;
    const isChar = name.length === 1;
    const bc = baseChar(e);
    const base = isChar ? (bc || name.toLowerCase()) : (NAMED[name.toLowerCase()] || name);
    const p = [];
    if (MAC) {
      if (e.metaKey) p.push('Mod');
      if (e.ctrlKey) p.push('Ctrl');
    } else {
      if (e.ctrlKey) p.push('Mod');
      if (e.metaKey) p.push('Meta');
    }
    if (e.altKey) p.push('Alt');
    if (e.shiftKey) p.push('Shift');
    return _join(p, base);
  }

  // ── Keymap state ───────────────────────────────────────────────────────────
  // Effective bindings are three layers deep: each command's declared `keys` (the Slate preset), then
  // the chosen preset's sparse overlay, then the user's own overlay. The user layer is sparse rather
  // than a flat snapshot, so "reset this row" has something to fall back to and a preset change still
  // moves every binding that was not customised.
  const PRESETS = window.SLATE_KEYMAP_PRESETS || [{ name: 'slate', label: 'Slate', bindings: {} }];
  const presetByName = n => PRESETS.find(p => p.name === n) || PRESETS[0];

  const LS_KEY = 'slate.keymap';
  let _preset = 'slate';
  let _user = {};                    // id → [authored chords]; `[]` means deliberately unbound
  let _synced = false;               // has the server copy been read (or definitively failed)?
  let _dirty = false;                // has anything been changed in this page since load?

  // ── Reserved / discouraged ─────────────────────────────────────────────────
  const _reservedSet = (() => {
    const r = window.SLATE_KEYS_RESERVED || { all: [] };
    const s = new Set();
    for (const spec of [].concat(r.all || [], MAC ? (r.mac || []) : (r.other || []))) {
      const m = matchChord(spec);
      if (m) s.add(m);
    }
    return s;
  })();
  const _discouraged = (() => {
    const d = window.SLATE_KEYS_DISCOURAGED || {};
    const out = new Map();
    for (const spec of Object.keys(d)) { const m = matchChord(spec); if (m) out.set(m, d[spec]); }
    return out;
  })();

  // Why this chord can't (or shouldn't) be used, or '' when it's fine. The first stroke of a sequence
  // is what the browser sees, so that is what gets checked.
  function chordWarning(spec) {
    const first = String(spec || '').trim().split(/\s+/)[0];
    const mk = matchChord(first);
    if (!mk) return 'Not a valid chord.';
    if (_reservedSet.has(mk)) return 'reserved';
    if (_discouraged.has(mk)) return 'shadows ' + _discouraged.get(mk);
    return '';
  }
  const isReserved = spec => chordWarning(spec) === 'reserved';

  // ── Effective bindings ─────────────────────────────────────────────────────
  // Chords for one command, as authored strings. A layer that mentions the command REPLACES the layer
  // below it — including with `[]`, which is how a preset says "unbound here" and how the UI clears a
  // row. That is why the lookup checks for the KEY's presence rather than for a truthy value.
  function chordsFor(id) {
    const p = presetByName(_preset).bindings || {};
    const src = Object.prototype.hasOwnProperty.call(_user, id) ? _user[id]
              : Object.prototype.hasOwnProperty.call(p, id) ? p[id]
              : (window.slateCmd.get(id) || {}).keys || [];
    const out = [];
    for (const c of src || []) { const k = canon(c); if (k && out.indexOf(k) < 0) out.push(k); }
    return out;
  }
  // Where a chord came from, for the badge in the Keyboard panel.
  function sourceOf(id) {
    if (Object.prototype.hasOwnProperty.call(_user, id)) return 'custom';
    if (Object.prototype.hasOwnProperty.call(presetByName(_preset).bindings || {}, id)) return 'preset';
    return 'default';
  }

  // Which of a command's contexts may actually use this chord. A bare key is legal in `command` (no
  // editor has focus there) and in `editor` (CodeMirror owns the keystroke anyway), but never in
  // `global`, where it would swallow ordinary typing. Filtering here rather than refusing the binding
  // means `nb.undo` can hold ⌘Z globally AND a bare `z` in command mode — which is exactly what the
  // Jupyter preset wants.
  function contextsFor(cmd, chord) {
    const safe = isGlobalSafe(chord);
    return cmd.ctx.filter(c => c !== 'global' || safe);
  }

  // ── The lookup index ───────────────────────────────────────────────────────
  // Chord → an ORDERED CHAIN of command ids. A command may DECLINE a keypress (`slateCmd.run`
  // returning false) when it has nothing to do right now, and the dispatcher then offers the key to
  // the next claimant. ⌘⇧G steps back through search hits while the find bar is open and toggles the
  // dependency graph when it is not.
  //
  // A command that can decline declares `soft: true`, and softs sort to the FRONT of the chain: an
  // unconditional handler never gives the key back, so anything behind it would be unreachable. That
  // also defines a real conflict precisely, as two UNCONDITIONAL commands on one chord, so the panel's
  // warning does not fire on every deliberate fall-through.
  //
  // Rebuilt whenever the keymap or the command set changes. It is small enough (~90 entries) that a
  // rebuild is cheaper than patching it, and a rebuild cannot drift.
  const IDX = { global: new Map(), command: new Map(), editor: new Map() };
  const PRE = { global: new Set(), command: new Set(), editor: new Set() };
  let _conflicts = [];

  const _soft = id => !!(window.slateCmd.get(id) || {}).soft;

  function rebuild() {
    for (const k of Object.keys(IDX)) { IDX[k].clear(); PRE[k].clear(); }
    _conflicts = [];
    for (const cmd of window.slateCmd.all()) {
      for (const chord of chordsFor(cmd.id)) {
        const mk = match(chord);
        if (!mk) continue;
        for (const ctx of contextsFor(cmd, chord)) {
          let chain = IDX[ctx].get(mk);
          if (!chain) { chain = []; IDX[ctx].set(mk, chain); }
          if (chain.indexOf(cmd.id) < 0) {
            cmd.soft ? chain.unshift(cmd.id) : chain.push(cmd.id);
          }
          // Every proper prefix of a sequence, so the dispatcher knows to wait for the next stroke.
          const strokes = mk.split(' ');
          for (let i = 1; i < strokes.length; i++) PRE[ctx].add(strokes.slice(0, i).join(' '));
        }
      }
    }
    for (const ctx of Object.keys(IDX)) {
      for (const [mk, chain] of IDX[ctx]) {
        const hard = chain.filter(id => !_soft(id));
        if (hard.length > 1) _conflicts.push({ chord: mk, ctx, ids: hard });
      }
      // A chord that is BOTH a complete binding and the prefix of a longer one can only be one of the
      // two. The shorter binding wins immediately — waiting to see whether a second stroke arrives
      // would make every press of it feel like a stall — and the longer one is reported as a conflict.
      for (const pre of Array.from(PRE[ctx])) {
        if (!IDX[ctx].has(pre)) continue;
        for (const [mk, chain] of IDX[ctx]) {
          if (mk !== pre && mk.startsWith(pre + ' ')) {
            _conflicts.push({ chord: mk, ctx, ids: IDX[ctx].get(pre).concat(chain), prefix: true });
          }
        }
        PRE[ctx].delete(pre);
      }
    }
    window.dispatchEvent(new CustomEvent('slate:keymap-changed'));
  }

  // ── Dispatch ───────────────────────────────────────────────────────────────
  // A sequence in progress. The 650ms window is the one the old `dd` handler used; it is short enough
  // that a stray `d` doesn't sit armed while you think, and long enough for a deliberate two-stroke.
  const SEQ_MS = 650;
  let _pending = '', _pendingCtx = '', _pendingTimer = 0;
  function clearPending() {
    _pending = ''; _pendingCtx = '';
    if (_pendingTimer) { clearTimeout(_pendingTimer); _pendingTimer = 0; }
    _paintPending();
  }
  function armPending(prefix, ctx) {
    _pending = prefix; _pendingCtx = ctx;
    if (_pendingTimer) clearTimeout(_pendingTimer);
    _pendingTimer = setTimeout(clearPending, SEQ_MS);
    _paintPending();
  }
  // Show the half-typed sequence. Without it, the first press of `dd` gives no feedback at all and
  // reads as a key that sometimes does nothing.
  function _paintPending() {
    let el = document.getElementById('kmpending');
    if (!_pending) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = 'kmpending'; el.className = 'kmpending';
      document.body.appendChild(el);
    }
    el.textContent = format(_pending) + ' …';
  }

  const _isField = t => !!(t && t.closest && (t.closest('.cm-editor') ||
    /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || '') || t.isContentEditable));
  const _inEditor = t => !!(t && t.closest && t.closest('.cm-editor'));
  // Any open dialog owns the keyboard: its own handlers drive it, and a command-mode key firing
  // behind it would act on a cell the reader can't see. Global chords still work — ⌘K has to be able
  // to dismiss the palette it opened.
  const _modalOpen = () => !!document.querySelector('.modal-bg.show, .modal-bg.shown');

  // Try one context's index for this event. Returns true when the key was consumed — which a command
  // can decline (see `slateCmd.run`), leaving the key for whatever else is listening.
  function tryContext(ctx, cands, e) {
    for (const cand of cands) {
      const full = _pending && _pendingCtx === ctx ? _pending + ' ' + cand : cand;
      const chain = IDX[ctx].get(full);
      if (chain) {
        for (const id of chain) {
          if (!window.slateCmd.available(window.slateCmd.get(id))) continue;  // not in this page
          if (!window.slateCmd.run(id, e)) continue;        // declined — offer the key to the next one
          clearPending();
          e.preventDefault(); e.stopPropagation();
          return true;
        }
      }
      if (PRE[ctx].has(full)) { e.preventDefault(); armPending(full, ctx); return true; }
    }
    return false;
  }

  // While the Keyboard panel is RECORDING a chord it needs the keyboard to itself, and stopping
  // propagation cannot get it there: this listener is on `document` in the capture phase and
  // registered first, so it would already have run. The panel suspends dispatch instead.
  let _suspended = false;

  document.addEventListener('keydown', e => {
    if (_suspended || e.defaultPrevented || e.isComposing) return;
    const cands = eventChords(e);
    if (!cands.length) return;
    const t = e.target;
    // Inside a cell editor, CodeMirror owns the keyboard: it has the state a binding needs and its
    // keymap can out-rank the text-editing defaults. So `global` is the document's context only
    // OUTSIDE an editor, and a command meant to work in both (⌘K, ⌘⇧K, ⌘F) declares `editor` as well
    // and is installed into CM6 by `editorSpecs`. That single rule replaces the old arrangement, where
    // each such chord was bound twice and the double-fire was caught afterwards with a timestamp.
    if (_inEditor(t)) return;
    // Command mode: no field focused and no dialog over the page. Tried before `global` because it is
    // the more specific context; in practice the two barely overlap, since a global chord carries a
    // modifier and a command-mode key usually does not.
    if (!_isField(t) && !_modalOpen() && tryContext('command', cands, e)) return;
    if (tryContext('global', cands, e)) return;
    // Nothing matched, so a half-typed sequence is over (`armPending` returns above, so reaching here
    // means this keystroke did not extend one).
    if (_pending) clearPending();
  }, true);

  // ── The editor's share ─────────────────────────────────────────────────────
  // CM6 binding specs for every command whose contexts include `editor`. editor.js installs these in
  // a Compartment and reconfigures on `slate:keymap-changed`, so a rebind reaches editors that are
  // already open. Chords go out in AUTHORED form — CM6 does its own normalization, including `Mod`.
  function editorSpecs() {
    const out = [];
    for (const cmd of window.slateCmd.all()) {
      if (cmd.ctx.indexOf('editor') < 0) continue;
      // `inst` commands are bound by the editor itself, per instance — ⇧⏎ means "run the cell" in one
      // kind of editor and "commit the source overlay" in another, so only the editor knows the
      // implementation. Emitting a second, generic binding for the same chord would shadow it.
      if (cmd.inst) continue;
      if (!window.slateCmd.available(cmd)) continue;
      for (const chord of chordsFor(cmd.id)) {
        out.push({ key: chord, id: cmd.id, run: view => window.slateCmd.run(cmd.id, view) });
      }
    }
    return out;
  }

  // ── Persistence ────────────────────────────────────────────────────────────
  // localStorage first and synchronously, so keys work on the very first keystroke rather than after
  // a round trip; then the server copy, which is authoritative because it is the one that follows you
  // between browsers. A static export or an app-mode page has no `/api/keymap` and simply keeps the
  // local copy — the fetch failing is an expected outcome there, not an error.
  function _loadLocal() {
    try {
      const raw = JSON.parse(localStorage.getItem(LS_KEY) || '{}');
      if (raw && typeof raw === 'object') {
        if (typeof raw.preset === 'string') _preset = raw.preset;
        if (raw.bindings && typeof raw.bindings === 'object') _user = raw.bindings;
      }
    } catch (_) {}
  }
  function _saveLocal() {
    try { localStorage.setItem(LS_KEY, JSON.stringify({ preset: _preset, bindings: _user })); } catch (_) {}
  }
  function _push() {
    _dirty = true;
    _saveLocal();
    if (!_synced) return;                     // the PUT waits for the GET; see `_pull`
    try {
      fetch('/api/keymap', { method: 'PUT', headers: { 'Content-Type': 'application/json' },
                             body: JSON.stringify({ preset: _preset, bindings: _user }) })
        .catch(() => {});
    } catch (_) {}
  }
  // The server copy wins on load — it is the one that follows you between browsers — but only if the
  // page hasn't already been edited. Rebinding a key in the first second after load is rare and would
  // otherwise be silently reverted by a GET that was already in flight, so an edit before the pull
  // lands makes the LOCAL copy authoritative and pushes it instead.
  function _pull() {
    const settle = () => {
      if (_synced) return;
      _synced = true;
      if (_dirty) _push();
    };
    try {
      fetch('/api/keymap', { headers: { Accept: 'application/json' } })
        .then(r => (r.ok ? r.json() : null))
        .then(d => {
          const adopt = d && typeof d === 'object' && !_dirty;
          settle();
          if (!adopt) return;
          const pre = typeof d.preset === 'string' ? d.preset : _preset;
          const b = d.bindings && typeof d.bindings === 'object' ? d.bindings : {};
          if (pre === _preset && JSON.stringify(b) === JSON.stringify(_user)) return;
          _preset = pre; _user = b; _saveLocal(); rebuild();
        })
        .catch(settle);
    } catch (_) { settle(); }
  }

  // ── Public API ─────────────────────────────────────────────────────────────
  window.slateKeymap = {
    // Chord helpers — also the unit-testable surface (test/js/keymap_resolve.mjs).
    canon, match, format, formatChord, eventChords, chordFromEvent, isGlobalSafe,
    chordWarning, isReserved, parseChord,

    presets: () => PRESETS.map(p => ({ name: p.name, label: p.label, about: p.about || '' })),
    preset: () => _preset,
    setPreset(name) {
      _preset = presetByName(name).name;
      rebuild(); _push();
      return _preset;
    },
    chordsFor, sourceOf, contextsFor,
    conflicts: () => _conflicts.slice(),
    // Conflicts involving one command, so a row can show its own trouble.
    conflictsFor: id => _conflicts.filter(c => c.ids.indexOf(id) >= 0),

    // Replace a command's chords. `null` restores the layer below (preset, then the declared default);
    // `[]` unbinds it deliberately. Returns the effective chords.
    setChords(id, chords) {
      if (chords == null) delete _user[id];
      else {
        const out = [];
        for (const c of chords) { const k = canon(c); if (k && out.indexOf(k) < 0) out.push(k); }
        _user[id] = out;
      }
      rebuild(); _push();
      return chordsFor(id);
    },
    addChord(id, chord) {
      const k = canon(chord);
      if (!k) return chordsFor(id);
      const cur = chordsFor(id);
      return this.setChords(id, cur.indexOf(k) >= 0 ? cur : cur.concat([k]));
    },
    removeChord(id, chord) {
      const k = canon(chord);
      return this.setChords(id, chordsFor(id).filter(c => c !== k));
    },
    reset(id) { return this.setChords(id, null); },
    resetAll() { _user = {}; rebuild(); _push(); },
    isCustom: id => Object.prototype.hasOwnProperty.call(_user, id),

    // What claims this chord right now, per context — the "already taken by" line in the panel. A
    // chord may have several claimants; they are returned in the order the dispatcher tries them.
    lookup(chord, ctx) {
      const mk = match(chord);
      if (!mk) return [];
      const out = [];
      for (const c of (ctx ? [ctx] : Object.keys(IDX))) {
        for (const id of IDX[c].get(mk) || []) out.push({ ctx: c, id, soft: _soft(id) });
      }
      return out;
    },

    editorSpecs,
    // Hand the keyboard to the Keyboard panel while it records a chord, and take it back after.
    suspend(on) { _suspended = !!on; if (!on) clearPending(); },
    suspended: () => _suspended,
    // Whole-keymap import/export, for sharing one or moving it by hand.
    toJSON: () => ({ preset: _preset, bindings: JSON.parse(JSON.stringify(_user)) }),
    fromJSON(d) {
      if (!d || typeof d !== 'object') return false;
      if (typeof d.preset === 'string') _preset = presetByName(d.preset).name;
      _user = d.bindings && typeof d.bindings === 'object' ? d.bindings : {};
      rebuild(); _push();
      return true;
    },
    rebuild,
  };

  _loadLocal();
  rebuild();
  _pull();
})();
