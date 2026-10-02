// The scheduler options a region or a machine carries, as rows of name and value. One table for both
// forms, so the same setting reads and is spelled the same wherever it is set. The catalogue, the
// spelling and the warnings are `schedopts.js` (`window.slateSchedOpts`), shared with the sweep cell.
import { html } from 'htm/preact';

// Rows ([{k, v}]) and the row whose suggestion menu is open are the caller's signals.
export function OptionsTable(rowsSig, menuSig, kind) {
  const SO = window.slateSchedOpts;
  if (SO) SO.load();
  const rows = rowsSig.value.length ? rowsSig.value : [{ k: '', v: '' }];
  const setRow = (i, patch) => {
    const next = rows.map((r, j) => (j === i ? { ...r, ...patch } : r));
    // Keep exactly one trailing blank row to type into, and drop the others.
    rowsSig.value = next.filter((r, j) => (r.k || '').trim() || (r.v || '').trim() || j === next.length - 1);
  };
  const addRow = () => { rowsSig.value = [...rows, { k: '', v: '' }]; };
  const delRow = i => { rowsSig.value = rows.filter((_, j) => j !== i); };
  return html`<div class="rppopts">
    ${rows.map((r, i) => {
      const key = SO ? SO.toKey(r.k) : (r.k || '');
      const warn = SO ? SO.warnFor(key, kind) : '';
      const hits = (SO && menuSig.value === i) ? SO.matches(r.k, kind, SO.MENU_MAX, SO.FIELD_OWNED) : [];
      const pick = o => { setRow(i, { k: SO.spellOf(o, kind) }); menuSig.value = -1; };
      return html`<div class=${'rppoptrow' + (warn ? ' unknown' : '')}>
        <input class="rppoptk" autocomplete="off" spellcheck="false" placeholder="option"
               value=${r.k}
               onInput=${ev => { setRow(i, { k: ev.target.value }); menuSig.value = i; }}
               onFocus=${() => menuSig.value = i}
               onBlur=${() => setTimeout(() => { if (menuSig.value === i) menuSig.value = -1; }, 120)}/>
        <input class="rppoptv" autocomplete="off" spellcheck="false" placeholder="value"
               title="leave blank for a switch such as exclusive"
               value=${r.v} onInput=${ev => setRow(i, { v: ev.target.value })}/>
        <button type="button" class="rppoptdel" title="remove this option" tabindex="-1"
                onClick=${() => delRow(i)}>✕</button>
        ${warn ? html`<span class="rppoptwarn">${warn}</span>` : null}
        ${hits.length ? html`<div class="rppoptmenu">
          ${hits.map(o => html`<div class="rppoptmi"
              onMouseDown=${ev => { ev.preventDefault(); pick(o); }}>
            <span class="rppoptminame">${SO.spellOf(o, kind)}</span>
            <span class="rppoptmihint">${SO.hintOf(o, kind)}</span></div>`)}
        </div>` : null}</div>`;
    })}
    <button type="button" class="rppoptadd" onClick=${addRow}>+ option</button>
  </div>`;
}

// Rows → the stored map. A row with no name is a half-typed one and is dropped; a row with a name and
// no value is a switch (`--exclusive`) and is kept.
export function optionsMap(rows) {
  const SO = window.slateSchedOpts, out = {};
  for (const r of rows) {
    const k = SO ? SO.toKey(r.k) : String(r.k || '').trim();
    if (k) out[k] = String(r.v == null ? '' : r.v).trim();
  }
  return out;
}
export const optionRows = map => Object.keys(map || {}).sort().map(k => ({ k, v: (map || {})[k] }));
