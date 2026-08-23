// Extensions gallery — browse and install Slate extension packages from the curated registry.
//
// A Preact island (imported by app.js): the catalog payload is a signal, the modal is a component
// derived from it, so a fetch or an install just assigns the signal and the UI follows. Opened from
// ⌘K ("Extensions…") or the ☰ menu via window.openExtensions.
//
// The list serves both browsing and managing: an installed extension is the SAME card with a
// different action, so there's no separate "installed" screen to keep in sync. Listings vary a lot
// in richness — most carry only a harvested description, a few have screenshots and a snippet — so
// the detail pane is built to look deliberate at every tier rather than leaving holes where a
// screenshot would be.
import { html, render } from 'htm/preact';
import { signal, computed } from '@preact/signals';

const open = signal(false);
const data = signal(null);          // the /api/catalog payload, or null before the first load
const loading = signal(false);
const error = signal('');
const selected = signal('');        // name of the entry shown in the detail pane
const query = signal('');
const category = signal('');        // '' = all
const busy = signal('');            // name of the extension currently installing ('' = none)
const zoom = signal('');            // screenshot URL shown full-screen ('' = none)

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const entries = computed(() => (data.value && data.value.entries) || []);
// A view over the same list, not a separate screen: browsing and managing what's already here are
// the same question asked with a different filter, so an installed extension is one card in one
// place. `updates` is the one worth surfacing on its own — it's the only state that's actionable
// without the user going looking for it.
const view = signal('all');            // 'all' | 'installed' | 'updates'
const isInstalled = (e) => e.installed || e.inParent;
const shown = computed(() => {
  const q = query.value.trim().toLowerCase(), cat = category.value, v = view.value;
  return entries.value.filter((e) => {
    if (v === 'installed' && !isInstalled(e)) return false;
    if (v === 'updates' && !e.updatable) return false;
    if (cat && !(e.categories || []).includes(cat)) return false;
    if (!q) return true;
    return [e.name, e.title, e.tagline, e.description, ...(e.categories || [])]
      .some((f) => f && String(f).toLowerCase().includes(q));
  });
});
const current = computed(() => entries.value.find((e) => e.name === selected.value) || shown.value[0] || null);

async function load(force) {
  loading.value = true; error.value = '';
  try {
    const r = await window.api('GET', '/api/catalog' + (force ? '?refresh=1' : ''));
    data.value = r || null;
    if (r && r.meta && r.meta.error && r.meta.source !== 'published') {
      // Degraded, not broken: say which copy is on screen rather than showing a raw fetch error.
      error.value = r.meta.source === 'local'
        ? 'Showing the local registry only — the catalog could not be fetched, so descriptions are unavailable.'
        : 'Showing a cached copy — the catalog could not be refreshed.';
    }
  } catch (e) {
    error.value = 'Could not load the catalog: ' + e.message;
  } finally { loading.value = false; }
}

window.openExtensions = function () {
  open.value = true;
  if (!data.value) load(false);
};
function close() { open.value = false; zoom.value = ''; }

// `thenInsert` is the "Install & add starter cell" path. Installing is a long, blocking operation
// (resolve, precompile, re-run), so it is never escalated into silently — the button says which of
// the two things it does, and the confirm names both.
async function install(e, thenInsert = false) {
  const d = data.value || {};
  if (!d.manageable) { window.alertDark && window.alertDark('This notebook has no project to install into.'); return; }
  // Adding the registry is depot-GLOBAL — it affects every project on this machine — so it gets its
  // own sentence in the confirm rather than happening silently inside "Install".
  const needsRegistry = !d.registryInstalled;
  const msg = `Install ${e.title || e.name} into this notebook's project?` +
    (needsRegistry ? `\n\nThis also adds the ${d.registryName} registry to your Julia depot, which affects every project on this machine.` : '') +
    '\n\nThe package is installed (it may precompile) and the notebook re-runs.' +
    (thenInsert ? '\n\nA starter cell is added afterwards.' : '');
  const verb = needsRegistry ? 'Add registry & install' : (thenInsert ? 'Install & add cell' : 'Install');
  if (!(await window.confirmDark(msg, verb))) return;

  busy.value = e.name;
  const stop = window.startPkgInstall ? window.startPkgInstall('Installing <b>' + esc(e.name) + '</b>') : () => {};
  try {
    const r = await window.api('POST', '/api/catalog/install', { name: e.name });
    stop();
    if (r && r.ok === false) {
      window._pkgInstallFail ? window._pkgInstallFail(r.message) : window.alertDark('Install failed:\n' + (r.message || '?'));
    } else {
      window.hidePkgInstalling && window.hidePkgInstalling();
      await load(false);
      // `thenInsert` already asked, so don't ask twice — just add the cell.
      if (e.snippet) thenInsert ? insertSnippet(e) : offerSnippet(e);
    }
  } catch (err) {
    stop();
    window.alertDark && window.alertDark('Install failed:\n' + err.message);
  } finally { busy.value = ''; }
}

async function update(e) {
  const to = e.version ? ` to ${e.version}` : '';
  if (!(await window.confirmDark(
    `Update ${e.title || e.name}${to}?\n\nCurrently ${e.installedVersion || 'unknown'}. ` +
    'The package is upgraded (it may precompile) and the notebook re-runs.', 'Update'))) return;
  busy.value = e.name;
  const stop = window.startPkgInstall ? window.startPkgInstall('Updating <b>' + esc(e.name) + '</b>') : () => {};
  try {
    // An extension inherited from the enclosing project has to be updated THERE — updating the
    // notebook's own env can't move a version it doesn't own.
    const r = await window.api('POST', '/api/catalog/update',
                               { name: e.name, target: (!e.installed && e.inParent) ? 'project' : 'notebook' });
    stop();
    if (r && r.ok === false) {
      window._pkgInstallFail ? window._pkgInstallFail(r.message) : window.alertDark('Update failed:\n' + (r.message || '?'));
    } else {
      window.hidePkgInstalling && window.hidePkgInstalling();
      await load(false);
    }
  } catch (err) {
    stop();
    window.alertDark && window.alertDark('Update failed:\n' + err.message);
  } finally { busy.value = ''; }
}

// Installing a package doesn't make it ACTIVE — the notebook still needs a `using`. Offering the
// starter snippet right after the install is what closes that gap; declining leaves a working
// install, so this is an offer rather than a step.
async function offerSnippet(e) {
  if (!(await window.confirmDark(
    `Add a starter cell for ${e.title || e.name}?\n\n${e.snippet}`, 'Add cell'))) return;
  insertSnippet(e);
}
// The starter cell is named after the package (`starrating`, `globeslate`, …), deduped by
// addCellWithSource — a notebook that adds several extensions then reads as a list of named steps
// rather than cell_1, cell_2. Source is committed server-side, so it survives the editor-mount race
// and runs immediately, which is what actually activates the extension.
async function insertSnippet(e) {
  const snippet = typeof e === 'string' ? e : e.snippet;
  const name = typeof e === 'string' ? '' : (e.name || '');
  close();
  try {
    await window.addCellWithSource(window.slateSelectedId ? window.slateSelectedId() : '', snippet, name);
  } catch (err) {
    window.toast && window.toast('Could not add the cell: ' + err.message, 4000);
  }
}

// ── styles ────────────────────────────────────────────────────────────────────
// Injected once, so notebook.css stays untouched (same approach as the health panel).
const style = document.createElement('style');
style.textContent = `
  .extbg{display:none;position:fixed;inset:0;z-index:70;background:rgba(6,8,16,.72);}
  .extbg.show{display:flex;align-items:center;justify-content:center;}
  .extmodal{width:min(1100px,94vw);height:min(720px,88vh);background:#0f1320;border:1px solid #2a2e40;
    border-radius:14px;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 24px 70px rgba(0,0,0,.6);}
  .exthdr{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid #232739;}
  .exthdr h2{margin:0;font-size:.95rem;color:#e6e9f5;font-weight:600;}
  .extsub{color:#6a7090;font-size:.74rem;}
  .extclose{margin-left:auto;cursor:pointer;color:#8a90a8;font-size:1.1rem;line-height:1;padding:2px 6px;}
  .extclose:hover{color:#e6e9f5;}
  .extbody{display:flex;min-height:0;flex:1;}
  .extleft{width:320px;flex:0 0 320px;border-right:1px solid #232739;display:flex;flex-direction:column;min-height:0;}
  .extsearch{padding:10px 12px;border-bottom:1px solid #232739;display:flex;flex-direction:column;gap:8px;}
  .extsearch input{width:100%;background:#171b2b;border:1px solid #2a2e40;border-radius:8px;color:#dfe3f0;
    padding:7px 10px;font-size:.8rem;box-sizing:border-box;}
  .extsearch input:focus{outline:none;border-color:#3f6fd0;}
  .extcats{display:flex;flex-wrap:wrap;gap:5px;}
  .extcat{font-size:.68rem;padding:2px 8px;border-radius:9px;cursor:pointer;color:#8a90a8;
    background:#171b2b;border:1px solid #2a2e40;}
  .extcat.on{color:#7cc0ff;border-color:rgba(124,192,255,.45);background:rgba(124,192,255,.1);}
  .extlist{overflow-y:auto;flex:1;min-height:0;}
  .extitem{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;cursor:pointer;
    border-bottom:1px solid rgba(35,39,57,.7);}
  .extitem:hover{background:rgba(124,192,255,.05);}
  .extitem.on{background:rgba(124,192,255,.1);}
  .exticon{flex:0 0 30px;height:30px;border-radius:7px;background:#1b2033;display:flex;align-items:center;
    justify-content:center;font-size:1rem;color:#9aa2c0;overflow:hidden;}
  .exticon img{width:100%;height:100%;object-fit:cover;}
  .extmeta{min-width:0;flex:1;}
  .extname{color:#dfe3f0;font-size:.82rem;font-weight:600;display:flex;align-items:center;gap:6px;}
  .extitem .extblurb{color:#7b8199;font-size:.72rem;line-height:1.35;margin-top:2px;
    display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;}
  .extpill{font-size:.62rem;padding:1px 6px;border-radius:8px;font-weight:600;}
  .extpill.installed{color:#56d364;background:rgba(86,211,100,.13);border:1px solid rgba(86,211,100,.3);}
  .extpill.parent{color:#8a90a8;background:rgba(138,144,168,.12);border:1px solid rgba(138,144,168,.28);}
  .extpill.update{color:#e8a13f;background:rgba(232,161,63,.14);border:1px solid rgba(232,161,63,.32);}
  .extviews{display:flex;gap:4px;}
  .extview{flex:1;text-align:center;font-size:.7rem;padding:4px 6px;border-radius:7px;cursor:pointer;
    color:#8a90a8;background:#171b2b;border:1px solid #2a2e40;user-select:none;}
  .extview:hover{color:#dfe3f0;}
  .extview.on{color:#dfe3f0;border-color:#3f6fd0;background:rgba(63,111,208,.14);}
  .extview b{font-weight:700;opacity:.85;}
  .extview.has{color:#e8a13f;border-color:rgba(232,161,63,.32);}
  .extview.has.on{color:#e8a13f;border-color:#e8a13f;background:rgba(232,161,63,.14);}
  .extright{flex:1;min-width:0;overflow-y:auto;padding:18px 22px;}
  .extempty{color:#6a7090;font-size:.8rem;padding:40px 0;text-align:center;}
  .exttitle{display:flex;align-items:center;gap:10px;margin-bottom:2px;}
  .exttitle h3{margin:0;font-size:1.05rem;color:#e6e9f5;}
  .extver{color:#6a7090;font-size:.74rem;font-family:Menlo,monospace;}
  .exttag{color:#aab1c9;font-size:.84rem;margin:6px 0 14px;line-height:1.45;}
  /* Screenshots fill the pane: a card's picture is the point of the card, and these are notebook
     captures — legible at full width, useless as thumbnails. Click to zoom for the fine detail. */
  .extshots{display:grid;gap:10px;margin-bottom:16px;}
  /* Height-capped so a full-page notebook capture reads as a banner instead of burying the Install
     button below the fold; cropped from the TOP, which is where a notebook's title and first output
     are. The zoom shows the whole image. */
  .extshots img{width:100%;max-height:380px;object-fit:cover;object-position:top;display:block;
    border-radius:9px;border:1px solid #2a2e40;cursor:zoom-in;background:#0b0e18;}
  .extshots img:hover{border-color:#3f6fd0;}
  /* Extra bottom padding leaves room for the hint line, which would otherwise sit on top of a
     full-height image. */
  .extzoom{position:fixed;inset:0;z-index:90;background:rgba(4,6,12,.9);display:flex;
    align-items:center;justify-content:center;cursor:zoom-out;padding:24px 24px 46px;overflow:auto;}
  .extzoom img{max-width:100%;max-height:100%;border-radius:10px;border:1px solid #2a2e40;
    box-shadow:0 24px 70px rgba(0,0,0,.6);}
  .extzoomhint{position:fixed;bottom:16px;left:0;right:0;text-align:center;color:#6a7090;font-size:.72rem;}
  /* Full width, like the screenshots, and capped to the same height so a card with a video and a
     card with a still read the same. preload="none" plus a poster means opening a card fetches the
     poster image only — the video downloads when the user presses play, not before.
     NB: no backticks in this comment. The whole block is a template literal, so one would end the
     string and the rest of the stylesheet would be parsed as JavaScript. */
  .extvideo{width:100%;max-height:380px;display:block;margin-bottom:16px;border-radius:9px;
    border:1px solid #2a2e40;background:#0b0e18;object-fit:cover;object-position:top;}
  .extdesc{color:#c2c8dd;font-size:.8rem;line-height:1.55;margin-bottom:16px;white-space:pre-wrap;}
  .extsection{color:#6a7090;font-size:.68rem;text-transform:uppercase;letter-spacing:.06em;margin:16px 0 7px;}
  .extprov li{color:#c2c8dd;font-size:.78rem;line-height:1.5;}
  .extsnip{background:#0b0e18;border:1px solid #232739;border-radius:9px;padding:10px 12px;color:#cdd3e6;
    font-family:Menlo,monospace;font-size:.72rem;white-space:pre-wrap;overflow-x:auto;}
  .extactions{display:flex;align-items:center;gap:10px;margin:18px 0 6px;flex-wrap:wrap;}
  .extbtn{font-size:.78rem;padding:6px 14px;border-radius:8px;cursor:pointer;border:1px solid transparent;
    background:#2f6feb;color:#fff;font-weight:600;}
  .extbtn:hover{background:#3b7bf5;}
  .extbtn[disabled]{opacity:.55;cursor:default;}
  .extbtn.ghost{background:transparent;border-color:#2a2e40;color:#aab1c9;font-weight:500;}
  .extbtn.ghost:hover{border-color:#3a4058;color:#dfe3f0;}
  .extlink{color:#7cc0ff;font-size:.75rem;text-decoration:none;}
  .extlink:hover{text-decoration:underline;}
  .extnote{color:#6a7090;font-size:.72rem;line-height:1.5;margin-top:10px;}
  .extwarn{color:#e8a13f;background:rgba(232,161,63,.1);border:1px solid rgba(232,161,63,.28);
    border-radius:8px;padding:8px 11px;font-size:.73rem;margin:0 16px 10px;}
  .extfoot{padding:8px 16px;border-top:1px solid #232739;display:flex;align-items:center;gap:10px;
    color:#6a7090;font-size:.7rem;}
`;
document.head.appendChild(style);

// ── components ────────────────────────────────────────────────────────────────
// A link to the demo notebook an author declared with `example` — a repo-relative path, so it's
// resolved against the source repo (through its subdirectory, for a package inside a monorepo).
// Null unless we can build a real URL; a broken link is worse than no link.
function exampleUrl(e) {
  const ex = e.example, repo = (e.repo || '').replace(/\.git$/, '');
  if (!ex || !repo) return null;
  if (/^https?:/.test(ex)) return ex;
  const m = repo.match(/github\.com[:/]([^/]+)\/(.+?)$/);
  if (!m) return null;
  const path = e.subdir ? `${e.subdir}/${ex}` : ex;
  return `https://github.com/${m[1]}/${m[2]}/blob/HEAD/${path}`;
}

const Icon = ({ e }) => {
  const ic = e.icon || '';
  if (ic && /^https?:/.test(ic)) return html`<div class="exticon"><img src=${ic} alt="" /></div>`;
  return html`<div class="exticon">${ic || (e.name || '?')[0]}</div>`;
};

function Item({ e }) {
  const on = current.value && current.value.name === e.name;
  return html`
    <div class=${'extitem' + (on ? ' on' : '')} onClick=${() => (selected.value = e.name)}>
      <${Icon} e=${e} />
      <div class="extmeta">
        <div class="extname">
          <span>${e.title || e.name}</span>
          ${e.updatable ? html`<span class="extpill update">update</span>`
            : e.installed ? html`<span class="extpill installed">installed</span>`
            : e.inParent ? html`<span class="extpill parent">in project</span>` : null}
        </div>
        <div class="extblurb">${e.tagline || e.description || 'No description yet.'}</div>
      </div>
    </div>`;
}

function Detail({ e }) {
  if (!e) return html`<div class="extright"><div class="extempty">No extension matches that search.</div></div>`;
  const d = data.value || {};
  const shots = e.screenshots || [];
  // With a video, the first screenshot becomes its poster — so the video downloads nothing until
  // the user presses play, and that image isn't also shown a second time in the strip below.
  const stills = e.video ? shots.slice(1) : shots;
  const provides = e.provides || [];
  const installing = busy.value === e.name;
  return html`
    <div class="extright">
      <div class="exttitle">
        <${Icon} e=${e} />
        <h3>${e.title || e.name}</h3>
        <span class="extver">${e.version || ''}</span>
        ${e.updatable ? html`<span class="extpill update">${e.installedVersion} → ${e.version}</span>`
          : e.installed ? html`<span class="extpill installed">installed${e.installedVersion ? ' ' + e.installedVersion : ''}</span>`
          : e.inParent ? html`<span class="extpill parent">in project${e.installedVersion ? ' ' + e.installedVersion : ''}</span>` : null}
      </div>
      ${e.tagline ? html`<div class="exttag">${e.tagline}</div>` : null}
      ${e.video ? html`
        <video class="extvideo" src=${e.video} poster=${shots[0] || ''} preload="none"
               controls loop muted playsinline></video>` : null}
      ${stills.length ? html`<div class="extshots">${stills.map((s) => html`
        <img src=${s} alt="" loading="lazy" title="click to zoom" onClick=${() => (zoom.value = s)} />`)}</div>` : null}
      ${e.description ? html`<div class="extdesc">${e.description}</div>` : null}
      ${!e.description && !e.tagline ? html`
        <div class="extdesc" style="color:#6a7090">This extension hasn't published a description yet.</div>` : null}

      <div class="extactions">
        ${e.updatable
          ? html`<button class="extbtn" disabled=${installing || !d.manageable}
                    onClick=${() => update(e)}>${installing ? 'Updating…' : `Update to ${e.version}`}</button>`
          : isInstalled(e)
          ? html`<button class="extbtn ghost" disabled>${e.installed ? 'Installed' : 'In project'}</button>`
          : html`<button class="extbtn" disabled=${installing || !d.manageable}
                    onClick=${() => install(e)}>${installing ? 'Installing…' : 'Install'}</button>`}
        ${e.snippet ? (isInstalled(e)
            ? html`<button class="extbtn ghost" onClick=${() => insertSnippet(e)}>Insert starter cell</button>`
            : html`<button class="extbtn ghost" disabled=${installing || !d.manageable}
                      onClick=${() => install(e, true)}>Install & add starter cell</button>`) : null}
        ${exampleUrl(e) ? html`<a class="extlink" href=${exampleUrl(e)} target="_blank" rel="noopener">Example notebook ↗</a>` : null}
        ${e.docs ? html`<a class="extlink" href=${e.docs} target="_blank" rel="noopener">Documentation ↗</a>` : null}
        ${e.repo ? html`<a class="extlink" href=${e.repo.replace(/\.git$/, '')} target="_blank" rel="noopener">Source ↗</a>` : null}
      </div>
      ${!d.manageable ? html`<div class="extnote">This notebook has no project of its own, so extensions can't be installed into it.</div>` : null}

      ${provides.length ? html`
        <div class="extsection">Provides</div>
        <ul class="extprov">${provides.map((p) => html`<li>${p}</li>`)}</ul>` : null}

      ${e.snippet ? html`
        <div class="extsection">Getting started</div>
        <div class="extsnip">${e.snippet}</div>` : null}

      <div class="extsection">Package</div>
      <div class="extnote">
        ${e.name}${e.version ? ' v' + e.version : ''}${e.julia ? ' · julia ' + e.julia : ''}
        ${e.deps && e.deps.length ? html`<br />Depends on ${e.deps.slice(0, 8).join(', ')}${e.deps.length > 8 ? ', …' : ''}` : null}
      </div>
    </div>`;
}

// Full-screen view of one screenshot. Rendered above the modal rather than inside it, so a capture
// wider than the detail pane isn't clipped by it.
function Zoom() {
  if (!zoom.value) return null;
  return html`
    <div class="extzoom" onMouseDown=${() => (zoom.value = '')}>
      <img src=${zoom.value} alt="" />
      <div class="extzoomhint">click anywhere, or press Esc, to close</div>
    </div>`;
}

function Modal() {
  if (!open.value) return null;
  const d = data.value || {};
  const cats = d.categories || [];
  return html`
    <div class="extbg show" onMouseDown=${(ev) => { if (ev.target.classList.contains('extbg')) close(); }}>
      <div class="extmodal">
        <div class="exthdr">
          <h2>Extensions</h2>
          <span class="extsub">${d.registryName || ''}${entries.value.length ? ' · ' + entries.value.length + ' available' : ''}</span>
          <span class="extclose" onClick=${close}>✕</span>
        </div>
        ${error.value ? html`<div class="extwarn">${error.value}</div>` : null}
        <div class="extbody">
          <div class="extleft">
            <div class="extsearch">
              <input placeholder="Search extensions…" value=${query.value}
                     onInput=${(ev) => (query.value = ev.target.value)} autofocus />
              <div class="extviews">
                ${[['all', 'All', entries.value.length],
                   ['installed', 'Installed', d.installedCount || 0],
                   ['updates', 'Updates', d.updatableCount || 0]].map(([k, label, n]) => html`
                  <span class=${'extview' + (view.value === k ? ' on' : '') + (k === 'updates' && n ? ' has' : '')}
                        onClick=${() => (view.value = k)}>${label}${n ? html` <b>${n}</b>` : ''}</span>`)}
              </div>
              ${cats.length ? html`
                <div class="extcats">
                  <span class=${'extcat' + (category.value === '' ? ' on' : '')}
                        onClick=${() => (category.value = '')}>all</span>
                  ${cats.map((c) => html`
                    <span class=${'extcat' + (category.value === c ? ' on' : '')}
                          onClick=${() => (category.value = category.value === c ? '' : c)}>${c}</span>`)}
                </div>` : null}
            </div>
            <div class="extlist">
              ${loading.value && !entries.value.length ? html`<div class="extempty">Loading…</div>`
                : shown.value.length ? shown.value.map((e) => html`<${Item} key=${e.name} e=${e} />`)
                : html`<div class="extempty">${emptyNote()}</div>`}
            </div>
          </div>
          <${Detail} e=${current.value} />
        </div>
        <div class="extfoot">
          <span>${sourceNote(d)}</span>
          <button class="extbtn ghost" style="margin-left:auto" disabled=${loading.value}
                  onClick=${() => load(true)}>${loading.value ? 'Checking…' : 'Check for updates'}</button>
        </div>
      </div>
    </div>`;
}

// An empty list means different things per view — "you have none installed" is not the same news as
// "your search matched nothing", and "everything is current" is good news, not an absence.
function emptyNote() {
  const filtered = query.value.trim() || category.value;
  if (filtered) return 'Nothing matches.';
  if (view.value === 'updates') return 'Every installed extension is up to date.';
  if (view.value === 'installed') return 'No extensions installed in this notebook yet.';
  return 'No extensions available.';
}

// Where the listing came from, in the user's terms — this is the difference between "there are no
// extensions" and "I couldn't reach the catalog", which otherwise look identical.
function sourceNote(d) {
  const m = (d && d.meta) || {};
  if (!d.registryInstalled) return 'The registry isn\'t installed yet — installing an extension adds it.';
  if (m.source === 'published') return 'Catalog fetched just now.';
  if (m.source === 'cache') return 'Cached catalog.';
  if (m.source === 'local') return 'Local registry only.';
  return '';
}

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${Modal} /><${Zoom} />`, host);

// Esc closes, matching every other modal in the app — innermost first, so escaping a zoomed
// screenshot returns you to the gallery rather than dumping you out of both.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  if (zoom.value) { e.preventDefault(); zoom.value = ''; return; }
  if (open.value) { e.preventDefault(); close(); }
});
