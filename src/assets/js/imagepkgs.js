// What a region's sysimage holds: the modal a Prepare opens before it builds one (regionprep.js).
//
// The list belongs to the region: every notebook that prepares it builds the same image, and the
// next Prepare starts from it. This notebook's packages, and its project's, are offered beside it at
// the versions it resolves; a package from a path (the project itself, a checkout) is not offered,
// since it loads normally on top of the image and its edits have to be seen. A version chosen here
// that differs from a notebook's makes that notebook start without the image: Julia loads a package
// from the image whatever its environment asks for.
import { html } from 'htm/preact';
import { render } from 'preact';
import { signal, effect } from '@preact/signals';
import { lockScroll } from './scrolllock.js';

const modal    = signal(null);   // {region, host, onConfirm} while it is up
const data     = signal(null);   // GET /api/sysimage-packages payload, or {error}
const incl     = signal([]);     // [{name, uuid, version, path}] — version "" = the notebook's
const picked   = signal({ in: [], av: [] });   // selected names in each list
const dirty    = signal(false);
const versions = signal({});     // name → {versions, yanked} | {loading}
const query    = signal('');
const hits     = signal([]);
const hitAt    = signal(-1);
const pathIn   = signal('');
const pathMsg  = signal('');     // why the last path was not added
const busy     = signal('');     // 'path' | 'save' while a request is out
let hitSeq = 0;

const nbVersion = name => ((data.value && data.value.candidates) || []).find(c => c.name === name)?.version || '';
const included = name => incl.value.some(p => p.name === name);
const byName = (a, b) => a.name.localeCompare(b.name);

function loadVersions(name) {
  if (versions.value[name]) return;
  versions.value = { ...versions.value, [name]: { loading: true } };
  window.api('GET', '/api/pkg-versions?name=' + encodeURIComponent(name))
    .then(d => { versions.value = { ...versions.value, [name]: d && d.ok ? d : { versions: [], yanked: [] } }; })
    .catch(() => { versions.value = { ...versions.value, [name]: { versions: [], yanked: [] } }; });
}

/** Open the modal for `region`; `onConfirm` runs once its list is kept. */
export function openImagePackages({ region, host, onConfirm }) {
  modal.value = { region, host, onConfirm };
  data.value = null; dirty.value = false; query.value = ''; hits.value = []; hitAt.value = -1;
  picked.value = { in: [], av: [] }; pathIn.value = ''; pathMsg.value = ''; busy.value = '';
  window.api('GET', '/api/sysimage-packages?region=' + encodeURIComponent(region)).then(d => {
    if (!d || !d.ok) { data.value = { error: (d && d.error) || 'unavailable' }; return; }
    data.value = d;
    const first = !(d.listed && d.listed.length);
    // A region that never kept a list starts from this notebook's packages, at its versions.
    incl.value = first ? (d.candidates || []).map(c => ({ ...c, version: '' })) : d.listed.map(p => ({ ...p }));
    dirty.value = first;
    incl.value.filter(p => !p.path).forEach(p => loadVersions(p.name));   // so a newer release shows at once
  }).catch(() => { data.value = { error: 'request failed' }; });
}
const close = () => { modal.value = null; };

function confirm() {
  const m = modal.value; if (!m || busy.value) return;
  const go = () => { close(); m.onConfirm && m.onConfirm(); };
  if (!dirty.value) return go();
  busy.value = 'save';
  window.api('POST', '/api/sysimage-packages', { region: m.region, packages: incl.value })
    .then(d => { busy.value = ''; if (d && d.ok) { dirty.value = false; go(); } else pathMsg.value = (d && d.error) || 'could not keep the list'; })
    .catch(() => { busy.value = ''; pathMsg.value = 'request failed'; });
}

function add(names) {
  const cands = (data.value && data.value.candidates) || [];
  const fresh = names.filter(n => !included(n)).map(n => {
    const c = cands.find(x => x.name === n);
    return c ? { ...c, version: '' } : { name: n, uuid: '', version: '', path: '' };
  });
  if (!fresh.length) return;
  incl.value = [...incl.value, ...fresh].sort(byName);
  fresh.filter(p => !p.path).forEach(p => loadVersions(p.name));
  picked.value = { in: [], av: [] }; dirty.value = true;
}
function remove(names) {
  incl.value = incl.value.filter(p => !names.includes(p.name));
  picked.value = { in: [], av: [] }; dirty.value = true;
}
function setVersion(name, v) { incl.value = incl.value.map(p => p.name === name ? { ...p, version: v } : p); dirty.value = true; }
function toggle(side, name, ev) {
  const cur = picked.value[side];
  const next = cur.includes(name) ? cur.filter(n => n !== name) : (ev && (ev.shiftKey || ev.metaKey) ? [...cur, name] : [name]);
  picked.value = { ...picked.value, [side]: next };
}

function search(q) {
  query.value = q; hitAt.value = -1;
  const seq = ++hitSeq;
  if (q.trim().length < 2) { hits.value = []; return; }
  window.api('GET', '/api/pkg-complete?q=' + encodeURIComponent(q.trim()))
    .then(d => { if (seq === hitSeq) hits.value = ((d && d.names) || []).filter(n => !included(n)).slice(0, 8); })
    .catch(() => {});
}
function pickHit(n) { add([n]); query.value = ''; hits.value = []; hitAt.value = -1; }
function searchKey(e) {
  const n = hits.value.length;
  if (e.key === 'ArrowDown' && n) { e.preventDefault(); hitAt.value = (hitAt.value + 1) % n; }
  else if (e.key === 'ArrowUp' && n) { e.preventDefault(); hitAt.value = (hitAt.value - 1 + n) % n; }
  else if (e.key === 'Enter' && n) { e.preventDefault(); pickHit(hits.value[Math.max(0, hitAt.value)]); }
}

// A package at a path on the machine, read there: the name comes from its Project.toml.
function addPath() {
  const m = modal.value, p = pathIn.value.trim();
  if (!m || !p || busy.value) return;
  busy.value = 'path'; pathMsg.value = '';
  window.api('GET', '/api/sysimage-path?region=' + encodeURIComponent(m.region) + '&path=' + encodeURIComponent(p))
    .then(d => {
      busy.value = '';
      if (!d || !d.ok) { pathMsg.value = (d && d.error) || 'not a package'; return; }
      incl.value = [...incl.value.filter(x => x.name !== d.name),
                    { name: d.name, uuid: d.uuid || '', version: '', path: d.path }].sort(byName);
      pathIn.value = ''; dirty.value = true;
    })
    .catch(() => { busy.value = ''; pathMsg.value = 'request failed'; });
}

// The names a drag carries: the selection when the dragged row is part of it, else the row alone.
const dragged = (side, name) => (picked.value[side].includes(name) ? picked.value[side] : [name]);
function onDrop(target, ev) {
  ev.preventDefault();
  let d; try { d = JSON.parse(ev.dataTransfer.getData('text/plain')); } catch (_) { return; }
  if (!d || d.side === target) return;
  target === 'in' ? add(d.names) : remove(d.names);
}

function VersionPick({ p }) {
  const nb = nbVersion(p.name), v = versions.value[p.name], list = (v && v.versions) || [];
  const newest = list[0] || '', chosen = p.version || nb;
  return html`${newest && chosen && newest !== chosen ? html`<span class="ipnew" title="the newest release">newer ${newest}</span>` : null}
    ${p.version && nb && p.version !== nb ? html`<span class="ipwarn" title="this notebook resolves another version, so it starts without the image">notebook has ${nb}</span>` : null}
    <select class="ipver" value=${p.version} onMouseDown=${e => { e.stopPropagation(); loadVersions(p.name); }}
        onChange=${e => setVersion(p.name, e.target.value)} onClick=${e => e.stopPropagation()}>
      <option value="">${nb ? 'as the notebook · ' + nb : 'newest'}</option>
      ${list.map((x, i) => html`<option value=${x}>${x}${i === 0 ? ' · newest' : ''}${(v.yanked || []).includes(x) ? ' · withdrawn' : ''}</option>`)}
      ${p.version && !list.includes(p.version) ? html`<option value=${p.version}>${p.version}</option>` : null}
    </select>`;
}

// A package in the image, on the right: its version, or the path it comes from, and a remove.
function ImageRow({ p }) {
  const sel = picked.value.in.includes(p.name);
  return html`<div class=${'iprow' + (sel ? ' sel' : '')} draggable="true"
      onClick=${e => toggle('in', p.name, e)}
      onDragStart=${e => e.dataTransfer.setData('text/plain', JSON.stringify({ side: 'in', names: dragged('in', p.name) }))}>
    <span class="ipname">${p.name}</span>
    ${p.path ? html`<span class="ipsrc" title=${p.path}>path</span><span class="ipver ippath" title=${p.path}>${p.path}</span>`
             : html`<${VersionPick} p=${p}/>`}
    <button class="ipdel" title="remove from the image" onClick=${e => { e.stopPropagation(); remove([p.name]); }}>✕</button>
  </div>`;
}

// A package of the notebook's or its project's, on the left. Adding copies it into the image; it
// stays here, marked, so this side always reads as what the notebook has.
function SourceRow({ p }) {
  const inImage = included(p.name), sel = picked.value.av.includes(p.name);
  return html`<div class=${'iprow' + (sel ? ' sel' : '') + (inImage ? ' inimg' : '')} draggable=${!inImage}
      onClick=${e => inImage || toggle('av', p.name, e)}
      onDblClick=${() => inImage || add([p.name])}
      onDragStart=${e => e.dataTransfer.setData('text/plain', JSON.stringify({ side: 'av', names: dragged('av', p.name) }))}>
    <span class="ipname">${p.name}</span>
    <span class="ipver ipfixed">${p.version}</span>
    ${inImage ? html`<span class="ipin" title="in the image">✓</span>` : null}
  </div>`;
}

function ImageModal() {
  const m = modal.value;
  if (!m) return null;
  const d = data.value;
  const cands = d && !d.error ? (d.candidates || []) : [];
  const group = (label, xs) => xs.length
    ? html`<div class="ipgroup">${label}</div>${xs.map(p => html`<${SourceRow} p=${p}/>`)}` : null;
  return html`<div class="anbg ipbg" onMouseDown=${e => { if (e.target.classList.contains('ipbg')) close(); }}>
    <div class="ancard ipcard" role="dialog" aria-modal="true">
      <div class="rphead">Sysimage for 🖧 ${m.region}</div>
      <div class="pddim rpsub">${m.host}</div>
      ${!d ? html`<div class="pddim">reading the region's sysimage…</div>`
        : d.error ? html`<div class="rppsyswarn">${d.error}</div>`
        : html`<div class="ipbody">
          <div class="iplists">
            <div class="iplist" onDragOver=${e => e.preventDefault()} onDrop=${e => onDrop('av', e)}>
              <div class="ipsub">Packages of this notebook</div>
              ${group('notebook', cands.filter(c => c.from !== 'project'))}
              ${group('project', cands.filter(c => c.from === 'project'))}
              ${cands.length ? null : html`<div class="ipempty">none</div>`}
            </div>
            <div class="ipmid">
              <button class="anbtn" title="add the selected packages to the image" disabled=${!picked.value.av.length}
                      onClick=${() => add(picked.value.av)}>›</button>
            </div>
            <div class="iplist ipimage" onDragOver=${e => e.preventDefault()} onDrop=${e => onDrop('in', e)}>
              <div class="ipsub">In the image <span class="ipcount">${incl.value.length}</span></div>
              ${incl.value.map(p => html`<${ImageRow} p=${p}/>`)}
              ${incl.value.length ? null : html`<div class="ipempty">drag packages here</div>`}
            </div>
          </div>
          <div class="ipadd">
            <input placeholder="add a registered package" value=${query.value}
                   onInput=${e => search(e.target.value)} onKeyDown=${searchKey}/>
            ${hits.value.length ? html`<div class="pkgsug ipsug">${hits.value.map((n, i) =>
                html`<div class=${i === hitAt.value ? 'on' : ''} onMouseDown=${e => { e.preventDefault(); pickHit(n); }}>${n}</div>`)}</div>` : null}
          </div>
          <div class="ipadd">
            <input placeholder=${'add a package from a path on ' + (m.host || 'the machine')} value=${pathIn.value}
                   onInput=${e => { pathIn.value = e.target.value; pathMsg.value = ''; }}
                   onKeyDown=${e => { if (e.key === 'Enter') addPath(); }}/>
            <button class="anbtn" disabled=${!pathIn.value.trim() || busy.value === 'path'} onClick=${addPath}>${busy.value === 'path' ? 'Reading…' : 'Add'}</button>
          </div>
          ${pathMsg.value ? html`<div class="rppsyswarn ipmsg">${pathMsg.value}</div>` : null}
          <div class="pddim ipalways">always in the image: ${(d.always || []).join(', ')}</div>
        </div>`}
      <div class="rpbtns">
        <button class="anbtn" onClick=${close}>Back</button>
        <button class="anbtn primary" disabled=${!d || !!d.error || busy.value === 'save'} onClick=${confirm}>${busy.value === 'save' ? 'Keeping…' : 'Prepare'}</button>
      </div>
    </div></div>`;
}

effect(() => lockScroll('imagepkgs', !!modal.value));

const host = document.createElement('div');
document.body.appendChild(host);
render(html`<${ImageModal} />`, host);

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && modal.value) { e.stopImmediatePropagation(); close(); }
}, true);
