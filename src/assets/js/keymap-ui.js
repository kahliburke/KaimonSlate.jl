// ── Settings → Keyboard: the shortcut editor ───────────────────────────────────
//
// Every command in the registry, one row each, with its chords as removable chips and a preset picker
// over the top. A Preact island (imported by app.js): the keymap is the source of truth and this is a
// view of it, so a rebind made here, from a preset switch, or by another tab writing the config file,
// all land the same way — the `slate:keymap-changed` event bumps a signal and the table re-renders.
//
// It gets its own dialog rather than a block inside the Settings modal. Fifty-odd rows with chord
// chips, a context column and a conflict line do not fit the Settings column's label-on-the-left
// layout, and squeezing them in would produce the kind of shortcuts panel people give up on. Settings
// keeps the row that OPENS this, beside the editor-keymap picker where someone looking for keyboard
// preferences will actually be.
//
// ── Recording a chord ──────────────────────────────────────────────────────────
// Click a chip (or +) and the next keys you press ARE the binding. Two things make that work:
// `slateKeymap.suspend` takes the keyboard away from the dispatcher for the duration (otherwise
// pressing `d` would delete a cell while you were trying to bind it), and strokes ACCUMULATE, so
// pressing `d` twice records the sequence `d d` rather than `d` twice. A short idle commits, which is
// how a sequence recorder has to behave: there is no other way to tell "that was one chord" from "a
// second stroke is coming".
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';

const open = signal(false);
const query = signal('');
const rev = signal(0);              // bumped on every keymap change, to re-derive everything below
// The row being recorded into: {id, strokes:[]} or null. One at a time — two open recorders would be
// racing for the same keystrokes.
const rec = signal(null);
const notice = signal('');          // a transient line under the header (import/export/reset results)

const KM = () => window.slateKeymap;
const CMD = () => window.slateCmd;

// ── Rows ──────────────────────────────────────────────────────────────────────
// Derived from the registry, not stored: a command registered by an extension after this panel first
// rendered appears the next time the signal changes, with nothing to refresh by hand.
const CTX_LABEL = { command: 'cell selected', global: 'anywhere', editor: 'in the editor' };
const CTX_TITLE = {
  command: 'Fires when a cell is selected and you are NOT editing it — where single keys are safe.',
  global: 'Fires anywhere outside a cell editor. Needs a ⌘/⌃/⌥ modifier, or Escape or a function key.',
  editor: 'Fires inside a cell editor, ahead of CodeMirror’s own text-editing keys.',
};

const rows = computed(() => {
  rev.value;                                          // subscribe: re-derive on any keymap change
  const km = KM(), cmd = CMD();
  if (!km || !cmd) return [];
  return cmd.all()
    .filter(c => cmd.available(c))
    .map(c => ({
      id: c.id,
      label: c.label,
      group: c.group,
      ctx: c.ctx,
      ext: c.ext,
      chords: km.chordsFor(c.id),
      source: km.sourceOf(c.id),
      custom: km.isCustom(c.id),
      conflicts: km.conflictsFor(c.id),
    }));
});

// Group order follows registration order, which is the order commands.js declares them — running,
// navigating, cells, panels, editor. A sorted list would scatter related actions alphabetically.
const groups = computed(() => {
  const q = query.value.trim().toLowerCase();
  const hit = r => !q || r.label.toLowerCase().includes(q) || r.id.toLowerCase().includes(q) ||
    r.group.toLowerCase().includes(q) ||
    r.chords.some(c => (c + ' ' + KM().format(c)).toLowerCase().includes(q));
  const out = [];
  const byName = new Map();
  for (const r of rows.value) {
    if (!hit(r)) continue;
    let g = byName.get(r.group);
    if (!g) { g = { name: r.group, rows: [] }; byName.set(r.group, g); out.push(g); }
    g.rows.push(r);
  }
  return out;
});

const conflictCount = computed(() => { rev.value; return KM() ? KM().conflicts().length : 0; });

window.addEventListener('slate:keymap-changed', () => { rev.value++; });

// ── Recording ─────────────────────────────────────────────────────────────────
// Two phases, because a chord that is already spoken for is a DECISION, not something to resolve on
// the user's behalf:
//
//   phase 'record'    keys are being captured; the chord builds up stroke by stroke
//   phase 'confirm'   the chord clashes; nothing has been written yet and the buttons decide
//
// Taking the chord silently would not surface until the displaced shortcut failed to work later, by
// which time you have to work out what it used to be and put it back by hand. So the clash is shown
// before anything changes, Cancel leaves the keymap untouched, and Reassign chains straight into
// recording a replacement for what was displaced.
//
// `replace` is the chord being edited (so re-recording a chip swaps it in place rather than
// appending); null means "add a new one". `queue` carries the commands still waiting for a
// replacement chord after a Reassign.
const COMMIT_MS = 800;
let _commitTimer = 0;

function startRec(id, replace, queue) {
  cancelRec();
  rec.value = { phase: 'record', id, strokes: [], replace: replace || null,
                warn: '', taken: null, queue: queue || [] };
  listen(true);
}
// The keyboard is only held during 'record'. In 'confirm' it goes back, so the buttons can be reached
// with Tab and Escape can mean "cancel this decision".
function listen(on) {
  document.removeEventListener('keydown', onRecKey, true);
  KM().suspend(false);
  if (!on) return;
  KM().suspend(true);
  document.addEventListener('keydown', onRecKey, true);
}
function cancelRec() {
  if (_commitTimer) { clearTimeout(_commitTimer); _commitTimer = 0; }
  listen(false);
  rec.value = null;
}
function onRecKey(e) {
  const r = rec.value;
  if (!r || r.phase !== 'record') return;
  // Escape is not recordable: the panel's own window-capture handler takes it first and cancels, so it
  // never reaches here. It is the one key a dialog cannot also offer as a binding without trapping you
  // in it.
  e.preventDefault(); e.stopPropagation();
  const stroke = KM().chordFromEvent(e);
  if (!stroke) return;                                // a bare modifier — keep waiting for the key
  const strokes = r.strokes.concat([stroke]);
  const chord = strokes.join(' ');
  // Warned about as you type, before anything is written: a reserved chord can never work, and a
  // clash is about to become a question.
  const warn = KM().chordWarning(chord);
  const taken = clashesWith(r.id, chord);
  rec.value = { ...r, strokes, warn, taken: taken.length ? taken : null };
  if (_commitTimer) clearTimeout(_commitTimer);
  // Reserved chords never settle — there is nothing to save that would work. Everything else settles
  // on a pause, so `d` is one binding and `d d` is a sequence.
  if (warn !== 'reserved') _commitTimer = setTimeout(settle, COMMIT_MS);
}

// Which other commands would actually be broken by giving `chord` to `id`.
//
// Scoped to the CONTEXTS the new binding would occupy, not to the chord alone: `b` in command mode
// and `b` inside the editor are different keys as far as the dispatcher is concerned, and reporting
// them as a clash would send people renaming bindings that never collided.
//
// `soft` claimants are excluded too. They decline a keypress when they have nothing to do and hand
// the chord on (⇧⌘G is search-previous with the find bar open, the DAG without it), so sharing with
// one is the designed arrangement rather than a collision to resolve.
function clashesWith(id, chord) {
  const km = KM(), cmd = CMD().get(id);
  if (!cmd) return [];
  const mine = new Set(km.contextsFor(cmd, chord));
  const seen = new Set([id]);
  const out = [];
  for (const t of km.lookup(chord)) {
    if (!mine.has(t.ctx) || t.soft || seen.has(t.id)) continue;
    seen.add(t.id);
    out.push(t.id);
  }
  return out;
}

// The chord is settled. Clean → write it. Clashing → ask, having written nothing.
function settle() {
  const r = rec.value;
  if (!r || r.phase !== 'record' || !r.strokes.length) { cancelRec(); return; }
  const chord = r.strokes.join(' ');
  if (KM().chordWarning(chord) === 'reserved') return;
  const owners = clashesWith(r.id, chord);
  if (!owners.length) { apply(r, chord, [], false); return; }
  listen(false);
  rec.value = { ...r, phase: 'confirm', pending: chord, owners };
}

const _label = id => (CMD().get(id) || {}).label || id;

// Write the decision. `displaced` lose the chord; `reassign` then walks them one at a time so each
// gets a replacement recorded immediately, rather than being left silently unbound.
function apply(r, chord, displaced, reassign) {
  const km = KM();
  const cur = km.chordsFor(r.id);
  // Re-recording a chip swaps it in place, so the row's order doesn't shuffle under the cursor. If the
  // chip has gone in the meantime (the row was reset from elsewhere), append rather than lose the edit.
  const next = r.replace && cur.indexOf(r.replace) >= 0
    ? cur.map(c => (c === r.replace ? chord : c))
    : cur.concat([chord]);
  for (const id of displaced) km.removeChord(id, chord);
  km.setChords(r.id, next.filter((c, i) => next.indexOf(c) === i));

  const queue = (r.queue || []).concat(reassign ? displaced : []);
  cancelRec();

  if (queue.length) {
    // Show the row being asked about. It is probably filtered out by whatever was searched for to get
    // here, and the recorder would then be armed on a row that is not on screen.
    const nextId = queue[0];
    query.value = _label(nextId);
    notice.value = `${_label(nextId)} lost ${km.format(chord)} — press a new shortcut for it, or Escape to leave it unbound.`;
    setTimeout(() => startRec(nextId, null, queue.slice(1)), 0);
    return;
  }
  notice.value = displaced.length
    ? `${km.format(chord)} taken from ${displaced.map(_label).join(', ')}, which ${displaced.length === 1 ? 'is' : 'are'} now unbound.`
    : '';
}

// ── Import / export ───────────────────────────────────────────────────────────
// A keymap is text worth being able to move: paste it to a colleague, keep it in dotfiles, diff it.
function exportKeymap() {
  const json = JSON.stringify(KM().toJSON(), null, 2);
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  a.download = 'slate-keymap.json';
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 4000);
}
function importKeymap() {
  const inp = document.createElement('input');
  inp.type = 'file'; inp.accept = '.json,application/json';
  inp.onchange = async () => {
    const f = inp.files && inp.files[0];
    if (!f) return;
    try {
      const ok = KM().fromJSON(JSON.parse(await f.text()));
      notice.value = ok ? 'Keymap imported.' : 'That file is not a Slate keymap.';
    } catch (e) { notice.value = 'Could not read that file: ' + e.message; }
  };
  inp.click();
}

async function resetAll() {
  const ok = window.confirmDark
    ? await window.confirmDark('Discard every customised shortcut and go back to the ' +
        KM().presets().find(p => p.name === KM().preset()).label + ' preset?')
    : true;
  if (!ok) return;
  KM().resetAll();
  notice.value = 'All shortcuts reset to the preset.';
}

window.openKeymapEditor = function () { open.value = true; notice.value = ''; };
function close() { cancelRec(); open.value = false; }

// ── Markup ────────────────────────────────────────────────────────────────────
function Chip({ row, chord }) {
  const km = KM();
  const warn = km.chordWarning(chord);
  const cls = 'kmchip' + (warn === 'reserved' ? ' bad' : warn ? ' warn' : '');
  const title = warn === 'reserved' ? 'The browser keeps this chord — it will never reach the page.'
              : warn ? 'Works, but ' + warn + ' while this page has focus.'
              : 'Click to re-record · ✕ to remove';
  return html`<span class=${cls} title=${title}>
    <button class="kmchipk" onClick=${() => startRec(row.id, chord)}>${km.format(chord)}</button>
    <button class="kmchipx" title="Remove this shortcut"
            onClick=${() => km.removeChord(row.id, chord)}>✕</button>
  </span>`;
}

function Recorder() {
  const r = rec.value;
  const km = KM();
  const chord = r.strokes.join(' ');
  return html`<span class="kmrec">
    <span class="kmreck">${chord ? km.format(chord) : 'press a chord…'}</span>
    ${r.warn === 'reserved'
      ? html`<span class="kmrecbad">the browser keeps this one — try another</span>`
      : r.warn ? html`<span class="kmrecwarn">${r.warn}</span>` : null}
    ${r.taken ? html`<span class="kmrecwarn">${'already used by ' + r.taken.map(_label).join(', ') +
      ' — you’ll be asked'}</span>` : null}
    <span class="kmrechint">Escape cancels${chord ? ' · pause to save · press again for a sequence' : ''}</span>
  </span>`;
}

// The clash decision. Nothing has been written at this point, so Cancel leaves everything as it was.
//
// Four buttons for four different intentions: keep the old binding, let both have the chord, take it
// and leave the other unbound, or take it and fix the other now. Reassign comes first because it is
// the one that leaves nothing unbound.
function Confirm({ r }) {
  const km = KM();
  const chord = km.format(r.pending);
  const who = r.owners.map(_label).join(', ');
  return html`<span class="kmconf">
    <span class="kmconfmsg"><b>${chord}</b> is already used by <b>${who}</b> in the same context.</span>
    <span class="kmconfacts">
      <button class="kmconfgo" title=${'Give ' + chord + ' to this command, then record a replacement for ' + who}
              onClick=${() => apply(r, r.pending, r.owners, true)}>Reassign…</button>
      <button title=${'Give ' + chord + ' to this command and leave ' + who + ' unbound'}
              onClick=${() => apply(r, r.pending, r.owners, false)}>Take it</button>
      <button title="Bind both commands to this chord. The one listed first in the panel wins; the rest are flagged as a conflict."
              onClick=${() => apply(r, r.pending, [], false)}>Keep both</button>
      <button title="Change nothing" onClick=${cancelRec}>Cancel</button>
    </span>
  </span>`;
}

function Row({ row }) {
  const r = rec.value && rec.value.id === row.id ? rec.value : null;
  const confirming = !!r && r.phase === 'confirm';
  return html`<div class=${'kmrow' + (r ? ' on' : '')}>
    <div class="kmlabel">
      <span>${row.label}</span>
      <span class="kmctx">${row.ctx.map(c => html`<span class="kmctxb" title=${CTX_TITLE[c]}>${CTX_LABEL[c] || c}</span>`)}</span>
    </div>
    <div class="kmkeys">
      ${row.chords.map(c => html`<${Chip} row=${row} chord=${c} />`)}
      ${!row.chords.length && !r ? html`<span class="kmnone">unbound</span>` : null}
      ${confirming ? html`<span class="kmreck">${KM().format(r.pending)}</span>`
        : r ? html`<${Recorder} />`
        : html`<button class="kmadd" title="Record a shortcut for this command"
                       onClick=${() => startRec(row.id, null)}>+</button>`}
    </div>
    <div class="kmmeta">
      ${row.conflicts.length ? html`<span class="kmbadge conflict" title="Two commands want the same chord in the same context; the one listed first here gets it and the other never fires.">conflict</span>` : null}
      ${row.custom ? html`<button class="kmreset" title="Back to the preset’s binding"
                                  onClick=${() => KM().reset(row.id)}>↺</button>` : null}
      ${row.ext ? html`<span class="kmbadge ext" title="Contributed by a package">${row.ext}</span>` : null}
    </div>
    ${confirming ? html`<${Confirm} r=${r} />` : null}
  </div>`;
}

function Panel() {
  if (!open.value) return null;
  const km = KM();
  if (!km) return null;
  const presets = km.presets();
  const cur = presets.find(p => p.name === km.preset()) || presets[0];
  return html`<div class="kmbg show" onMouseDown=${e => { if (e.target.classList.contains('kmbg')) close(); }}>
    <div class="kmmodal">
      <div class="kmhdr">
        <h2>Keyboard shortcuts</h2>
        <label class="kmpreset">Keymap
          <select value=${km.preset()} onChange=${e => { km.setPreset(e.target.value); notice.value = ''; }}>
            ${presets.map(p => html`<option value=${p.name}>${p.label}</option>`)}
          </select>
        </label>
        <input class="kmsearch" type="search" placeholder="Search commands and keys…"
               value=${query.value} onInput=${e => { query.value = e.target.value; }}
               autocomplete="off" spellcheck="false" />
        <button class="kmx" title="Close" onClick=${close}>✕</button>
      </div>
      <div class="kmsub">
        <span class="kmabout">${cur.about}</span>
        <span class="kmacts">
          <button onClick=${importKeymap} title="Load a keymap from a JSON file">Import…</button>
          <button onClick=${exportKeymap} title="Save this keymap as JSON">Export</button>
          <button onClick=${resetAll} title="Discard every customised shortcut">Reset all</button>
        </span>
      </div>
      ${notice.value ? html`<div class="kmnotice">${notice.value}</div>` : null}
      ${conflictCount.value ? html`<div class="kmnotice warn">${conflictCount.value}
        ${conflictCount.value === 1 ? 'chord is' : 'chords are'} claimed by more than one command in the
        same context — the marked rows lose. Remove or re-record one of each pair.</div>` : null}
      <div class="kmbody">
        ${groups.value.map(g => html`
          <div class="kmgroup" key=${g.name}>
            <div class="kmgname">${g.name}</div>
            ${g.rows.map(r => html`<${Row} row=${r} key=${r.id} />`)}
          </div>`)}
        ${!groups.value.length ? html`<div class="kmempty">No command matches “${query.value}”.</div>` : null}
      </div>
      <div class="kmfoot">
        <span class="kmdim">Shortcuts are stored per person, not per notebook — in
          <code>keymap.json</code> under your Slate config directory, so they follow you between
          browsers. Text editing inside a cell (word motion, indent, brackets, and ⌘/ for comments)
          comes from the editor keymap in Settings → Editing — default, vim or emacs — so a row in the
          Editor group below adds a chord alongside that keymap’s own rather than replacing it.</span>
        <button class="primary" onClick=${close}>Done</button>
      </div>
    </div>
  </div>`;
}

// Styles injected here rather than added to notebook.css, the same way the extensions gallery and the
// health panel do it: this panel's chrome is used nowhere else, so it travels with its own island.
//
// Every colour is a THEME VARIABLE with no hardcoded fallback. Slate ships light themes as well as
// dark ones (notebook.css `:root` and its `[data-theme]` blocks), so a literal `#0f1320` or an
// `rgba(255,255,255,.05)` overlay looks right in one theme and wrong in the rest. A misspelt variable
// name resolves to its fallback without warning, so there are no fallbacks here. The palette is
// `--bg/--bg2/--bg3`, `--border`, `--text`, `--dim`, `--accent`, `--red`, `--gold`.
//
// `select` and `input` need styling explicitly, since a browser's native control ignores the
// surrounding colours. The rules mirror `.setmodal select` / `.setmodal input.settext` so this
// dialog's fields look like the ones in Settings.
const style = document.createElement('style');
style.textContent = `
.kmbg{display:none;position:fixed;inset:0;z-index:72;background:rgba(5,8,16,.66);
  backdrop-filter:blur(3px);-webkit-backdrop-filter:blur(3px);}
.kmbg.show{display:flex;align-items:center;justify-content:center;}
.kmmodal{width:min(920px,94vw);height:min(760px,90vh);background:var(--bg2);
  border:1px solid var(--border);border-radius:12px;display:flex;flex-direction:column;
  overflow:hidden;box-shadow:0 16px 48px rgba(0,0,0,.55);color:var(--text);}
.kmmodal select,.kmmodal input{background:var(--bg3);color:var(--text);border:1px solid var(--border);
  border-radius:6px;padding:4px 8px;font:inherit;font-size:.82rem;}
.kmmodal input:focus,.kmmodal select:focus{outline:none;border-color:var(--accent);}
/* Font only — the colour is set per button class below, so this cannot out-specify the shared
   .primary style the Done button uses. (No backticks in here: this is a template literal, and one
   inside a CSS comment ends the string and turns the rest of the stylesheet into JavaScript.) */
.kmmodal button{font:inherit;}
/* The header must never overflow: the title and the preset picker keep their size, the search field
   absorbs whatever is left. Without min-width:0 a flex item refuses to shrink below its content and
   pushes the row off the left edge. */
.kmhdr{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--border);}
.kmhdr h2{margin:0;font-size:1rem;font-weight:600;flex:0 0 auto;}
.kmpreset{display:flex;align-items:center;gap:6px;flex:0 0 auto;font-size:.78rem;color:var(--dim);}
.kmsearch{flex:1 1 auto;min-width:0;}
.kmx{background:none;border:none;color:var(--dim);font-size:1rem;cursor:pointer;padding:2px 6px;flex:0 0 auto;}
.kmx:hover{color:var(--text);}
.kmsub{display:flex;align-items:center;gap:12px;padding:8px 16px;font-size:.76rem;
  color:var(--dim);border-bottom:1px solid var(--border);}
.kmabout{flex:1;min-width:0;}
.kmacts{display:flex;gap:6px;flex:0 0 auto;}
.kmacts button{background:var(--bg3);border:1px solid var(--border);border-radius:6px;
  font-size:.74rem;padding:3px 9px;cursor:pointer;}
.kmacts button:hover{border-color:var(--accent);}
.kmnotice{padding:7px 16px;font-size:.76rem;background:var(--bg3);color:var(--text);
  border-bottom:1px solid var(--border);border-left:3px solid var(--accent);}
.kmnotice.warn{border-left-color:var(--gold);}
.kmbody{flex:1;overflow:auto;padding:0 0 12px;}
.kmgname{position:sticky;top:0;z-index:1;padding:8px 16px 6px;font-size:.68rem;font-weight:600;
  text-transform:uppercase;letter-spacing:.08em;color:var(--dim);
  background:var(--bg2);border-bottom:1px solid var(--border);}
.kmrow{display:grid;grid-template-columns:1fr auto auto;gap:10px;align-items:center;
  padding:5px 16px;border-bottom:1px solid var(--border);}
.kmrow:hover{background:var(--bg3);}
.kmrow.on{background:var(--bg3);box-shadow:inset 3px 0 0 var(--accent);}
.kmlabel{display:flex;flex-direction:column;gap:2px;min-width:0;font-size:.83rem;color:var(--text);}
.kmctx{display:flex;gap:4px;}
.kmctxb{font-size:.62rem;color:var(--dim);border:1px solid var(--border);
  border-radius:3px;padding:0 4px;cursor:help;}
.kmkeys{display:flex;align-items:center;gap:5px;flex-wrap:wrap;justify-content:flex-end;}
.kmchip{display:inline-flex;align-items:center;border:1px solid var(--border);border-radius:5px;
  background:var(--bg3);overflow:hidden;}
.kmchip.warn{border-color:var(--gold);}
.kmchip.bad{border-color:var(--red);}
.kmchipk{background:none;border:none;color:var(--text);font-size:.76rem;
  font-family:'Cascadia Code',ui-monospace,SFMono-Regular,Menlo,monospace;padding:2px 6px;cursor:pointer;}
.kmchip.bad .kmchipk{text-decoration:line-through;opacity:.7;}
.kmchipx{background:none;border:none;border-left:1px solid var(--border);
  color:var(--dim);font-size:.64rem;padding:3px 5px;cursor:pointer;}
.kmchipx:hover{color:var(--red);}
.kmadd{background:none;border:1px dashed var(--border);border-radius:5px;
  color:var(--dim);font-size:.78rem;line-height:1;padding:3px 7px;cursor:pointer;}
.kmadd:hover{color:var(--text);border-color:var(--accent);}
.kmnone{font-size:.72rem;color:var(--dim);font-style:italic;}
/* The clash decision spans the whole row rather than squeezing into the keys column, which is too
   narrow for a sentence plus four buttons. */
.kmconf{grid-column:1 / -1;display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  margin:6px 0 2px;padding:8px 10px;border:1px solid var(--gold);border-radius:7px;background:var(--bg);}
.kmconfmsg{flex:1 1 260px;font-size:.78rem;color:var(--text);line-height:1.45;}
.kmconfacts{display:flex;gap:6px;flex:0 0 auto;}
.kmconfacts button{background:var(--bg3);color:var(--text);border:1px solid var(--border);
  border-radius:6px;font-size:.74rem;padding:4px 10px;cursor:pointer;}
.kmconfacts button:hover{border-color:var(--accent);color:var(--accent);}
.kmconfacts .kmconfgo{border-color:var(--accent);color:var(--accent);font-weight:600;}
.kmconfacts .kmconfgo:hover{background:var(--accent);color:var(--bg);}
.kmrec{display:inline-flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end;}
.kmreck{font-family:'Cascadia Code',ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;
  padding:2px 8px;border-radius:5px;border:1px solid var(--accent);background:var(--bg);color:var(--text);}
.kmrechint,.kmrecwarn,.kmrecbad{font-size:.68rem;}
.kmrechint{color:var(--dim);}
.kmrecwarn{color:var(--gold);}
.kmrecbad{color:var(--red);}
.kmmeta{display:flex;align-items:center;gap:5px;min-width:56px;justify-content:flex-end;}
.kmbadge{font-size:.62rem;border-radius:3px;padding:1px 5px;border:1px solid var(--border);}
.kmbadge.conflict{color:var(--gold);border-color:var(--gold);}
.kmbadge.ext{color:var(--dim);}
.kmreset{background:none;border:none;color:var(--dim);font-size:.8rem;cursor:pointer;padding:0 3px;}
.kmreset:hover{color:var(--accent);}
.kmempty{padding:24px 16px;text-align:center;color:var(--dim);font-size:.82rem;}
.kmfoot{display:flex;align-items:flex-end;gap:16px;padding:10px 16px;
  border-top:1px solid var(--border);}
.kmdim{flex:1;font-size:.7rem;color:var(--dim);line-height:1.5;}
.kmdim code{font-size:.68rem;}
/* The shared .primary rule is scoped to .modal, and this panel is its own surface — so the Done
   button is styled here to match the one in Settings rather than rendering unstyled beside it. */
.kmfoot .primary{flex:0 0 auto;background:var(--accent);color:var(--bg);border:1px solid var(--accent);
  border-radius:7px;padding:7px 16px;font-size:.85rem;font-weight:600;cursor:pointer;}
`;
document.head.appendChild(style);

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Panel} />`, host);

// Escape, innermost first: cancel a recording or a clash decision, then close the panel.
//
// On `window` in the CAPTURE phase, which is ahead of every `document` listener. This panel is usually
// opened from Settings and sits on top of it, and Settings claims Escape on `document` capture with a
// `stopPropagation` — so a handler anywhere below that would never run, and Escape would close the
// dialog UNDERNEATH the one you are looking at. Stopping the event here also means Settings keeps its
// Escape for the next press, once this panel is out of the way.
window.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || !open.value) return;
  e.preventDefault(); e.stopPropagation();
  if (rec.value) cancelRec();          // a half-typed chord, or a clash waiting on an answer
  else close();
}, true);
