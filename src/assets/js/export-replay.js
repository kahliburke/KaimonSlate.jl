// Export step 2 — the `@replay` resolution dialog. A Preact island owning #exreplaybg.
//
// This is a SECOND screen rather than a row on the export form, because it is a different kind of
// decision. The first screen is about how the page is rendered; this one is about work that has to be
// COMPUTED and data that will be carried, per variable. A notebook with no `@replay` marks never sees
// it — `openReplayStep` exports straight away.
//
// Preact rather than the vanilla DOM building the rest of dialogs.js uses: each row carries real state
// (a power-of-two slider and an exact-value field that must agree with each other, with the running
// totals, and with what gets persisted), and rebuilding an HTML string on every input event is exactly
// what signals exist to replace.
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';

const NB = decodeURIComponent((location.pathname.match(/^\/n\/([^\/]+)/) || ['', ''])[1]);
const _api = p => '/api/' + NB + p;

// id → {control, cell, values, kind, strideable, bytes_per_value?, seconds_per_value?, slice?}.
// `bytes_per_value` is MEASURED — the plan evaluates one real value per mark — so every size shown here
// is a fact about this notebook, not a guess. It is absent when that trial evaluation threw, and the row
// then shows its value count alone rather than a number it can't stand behind.
const plan = signal({});
const strides = signal({});          // id → n (>1 only; 1 is the default and is never stored)
const busy = signal(false);
const shown = signal(false);

const strideOf = id => +(strides.value[id] || 1);
// A slider's domain is an ordered sweep of one quantity, so dropping positions costs resolution and
// nothing else. A Select/Radio/Checkbox is categorical — every value is a distinct thing the reader can
// ask for — so it always ships whole.
const valuesOf = (id, p) => p.strideable ? Math.ceil((p.values || 0) / strideOf(id)) : (p.values || 0);

const totals = computed(() => {
  let bytes = 0, evals = 0, secs = 0, measured = true;
  for (const [id, p] of Object.entries(plan.value)) {
    const n = valuesOf(id, p);
    evals += n;
    if (p.bytes_per_value) { bytes += p.bytes_per_value * n; secs += (p.seconds_per_value || 0) * n; }
    else measured = false;
  }
  return { bytes, evals, secs, measured };
});

function fmtBytes(b) {
  return b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : b >= 1024 ? (b / 1024).toFixed(0) + ' kB' : b + ' B';
}
function fmtSecs(s) { return s < 1 ? '<1s' : s < 60 ? s.toFixed(0) + 's' : (s / 60).toFixed(1) + 'm'; }

// `<id>:<n>` pairs, ids percent-encoded (a mark id is `<cell>:<control>` and a control may be non-ASCII).
// Only coarsened marks travel, so a notebook that leaves everything at full resolution stores nothing.
export function strideQS() {
  return Object.keys(strides.value).filter(k => strides.value[k] > 1)
    .map(k => encodeURIComponent(k) + ':' + strides.value[k]).join(',');
}

// Parse the same spelling back. Split on the LAST colon: the id contains one, and splitting on the first
// would cut it in half and silently apply the stride to nothing.
function parseStrides(s) {
  const out = {};
  String(s || '').split(',').filter(Boolean).forEach(p => {
    const i = p.lastIndexOf(':');
    if (i <= 0) return;
    const n = +p.slice(i + 1);
    if (n > 1) out[decodeURIComponent(p.slice(0, i))] = n;
  });
  return out;
}

// Resolution is a property of the NOTEBOOK: it records how much detail this document's controls need to
// carry, which is an authoring judgement that should travel with the `.jl` and read the same for every
// collaborator. Persisted through the per-notebook config footer, not the browser.
function persist() {
  fetch(_api('/config'), { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key: 'replaystrides', value: strideQS() }) }).catch(() => {});
}

function setStride(id, n) {
  n = Math.max(1, Math.round(+n || 1));
  const next = { ...strides.value };
  n === 1 ? delete next[id] : (next[id] = n);
  strides.value = next;
  persist();
}

function Row({ id, p }) {
  const st = strideOf(id);
  const n = valuesOf(id, p);
  const bytes = p.bytes_per_value ? p.bytes_per_value * n : 0;
  // Two ways in, because they suit different intents. The SLIDER halves at each notch — 1, 2, 4, 8 …
  // — which is how the decision is actually made ("about half the data"), and every notch is a real
  // change rather than a barely-different number. The FIELD is for a domain with structure the powers of
  // two miss: 100 positions divide evenly by 5, not by 4.
  const pow = Math.max(0, Math.round(Math.log2(st)) || 0);
  return html`
    <div class="exrp-row">
      <div class="exrp-name">
        <b>${p.control}</b>
        <span class="exrp-cell">${p.cell}</span>
        <span class="exrp-kind">${p.kind}${p.slice ? ' · ' + p.slice.join('×') : ''}</span>
      </div>
      <div class="exrp-cost">
        <span>${n} value${n === 1 ? '' : 's'}</span>
        ${bytes ? html`<b>${fmtBytes(bytes)}</b>` : html`<em class="exrp-noest">unmeasured</em>`}
      </div>
      ${p.strideable ? html`
        <div class="exrp-ctl">
          <input type="range" min="0" max="6" step="1" value=${pow}
                 title="each notch halves the stored values"
                 onInput=${e => setStride(id, Math.pow(2, +e.target.value))}/>
          <span class="exrp-every">${st === 1 ? 'every value' : 'every ' + st + 'th'}</span>
          <input type="number" min="1" max=${p.values || 1} value=${st}
                 title="exact stride"
                 onChange=${e => setStride(id, e.target.value)}/>
        </div>`
        : html`<div class="exrp-ctl exrp-all">all options</div>`}
    </div>`;
}

function Dialog() {
  if (!shown.value) return null;
  const ids = Object.keys(plan.value).sort();
  const t = totals.value;
  return html`
    <div class="modal setmodal exrp">
      <div class="msg"><strong>Replay data</strong>
        <span class="exrp-sub">— precomputed for the exported file</span></div>
      <div class="exrp-intro">
        Each control's values are computed at export and stored in the page. Sizes are measured.
        Reducing a slider's resolution stores fewer values; menu options are always stored in full.</div>
      <div class="exrp-list">${ids.map(id => html`<${Row} key=${id} id=${id} p=${plan.value[id]}/>`)}</div>
      <div class="exrp-total">
        ${ids.length} control${ids.length === 1 ? '' : 's'} · ${t.evals} evaluation${t.evals === 1 ? '' : 's'}
        ${t.bytes ? html` · <b>${fmtBytes(t.bytes)}</b> of data` : null}
        ${t.secs > 1 ? html` · ≈ ${fmtSecs(t.secs)} to compute` : null}
        ${!t.measured ? html` · <em class="exrp-noest">some sizes unmeasured</em>` : null}
      </div>
      <div class="row">
        <button onClick=${back}>← Back</button>
        <button class="primary" onClick=${go}>Export</button>
      </div>
    </div>`;
}

function close() { shown.value = false; const bg = document.getElementById('exreplaybg'); if (bg) bg.style.display = 'none'; }
function back() { close(); window.openExportModal && window.openExportModal(); }
function go() { close(); window.exportHtml && window.exportHtml(true); }

// Called by dialogs.js when HTML export is confirmed. Fetches the plan (cheap: a registry read plus one
// trial value per mark) and shows the step only if this notebook actually has marks — otherwise it hands
// straight back, so a notebook that never uses `@replay` sees no extra screen at all.
export async function openReplayStep() {
  if (busy.value) return;
  busy.value = true;
  let p = {};
  try { p = (await (await fetch(_api('/replay-plan'))).json()).replays || {}; } catch (_) { p = {}; }
  busy.value = false;
  plan.value = p;
  if (!Object.keys(p).length) { window.exportHtml && window.exportHtml(true); return; }
  // Seed from the notebook's own config so a resolution chosen earlier — by anyone — is what shows.
  try {
    const cfg = (window.nbState && window.nbState.config) || {};
    const items = cfg.items || [];
    const it = items.find ? items.find(x => x.key === 'replaystrides') : null;
    strides.value = parseStrides(it ? it.value : cfg.replaystrides);
  } catch (_) { strides.value = {}; }
  const bg = document.getElementById('exreplaybg');
  if (!bg) { window.exportHtml && window.exportHtml(true); return; }
  bg.style.display = 'flex';
  shown.value = true;
}

const bg = document.getElementById('exreplaybg');
if (bg) {
  render(html`<${Dialog}/>`, bg);
  bg.addEventListener('mousedown', e => { if (e.target === bg) back(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && shown.value) back(); });
}
// The vanilla export flow in dialogs.js hands over here; `strideQS` feeds the export URL.
window.openReplayStep = openReplayStep;
window.__replayStrideQS = strideQS;
