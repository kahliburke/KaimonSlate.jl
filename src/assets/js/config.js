// ── Notebook config panel ───────────────────────────────────────────────────────
// One unified view of every DURABLE per-notebook override. The execution/slides/bibstyle/agent-model
// rows are server-backed via /api/config (registry-driven — they travel in the `.jl` Slate.config
// footer). The agent PERMISSION row is kept LOCAL (localStorage, per notebook) and is NEVER written
// to the file — a `bypass` preset must not ride a shared notebook. Each row shows its effective
// value, a source badge (notebook override / global / default), and a "follow global" clear.

let _configOpen = false;
function toggleConfig() {
  const p = document.getElementById('configpanel');
  p.classList.toggle('open');
  _configOpen = p.classList.contains('open');
  if (_configOpen) loadConfig();
}

function _cfgEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Reap the running agent so a model/permission change binds on the NEXT message (transcript kept).
// Returns false if the user backs out of stopping an in-flight turn.
async function _cfgReapAgent(noun, label) {
  if (typeof agentWorking !== 'undefined' && agentWorking &&
      !(await confirmDark('A turn is in progress — change the ' + noun + ' and stop it?', 'Change & stop', 'danger')))
    return false;
  try { await api('POST', '/api/chat-kill', {}); } catch (_) {}
  try { setWorking(false); } catch (_) {}
  try { _agentNote('⚙ ' + noun + ' → ' + label + ' · applies to your next message'); } catch (_) {}
  return true;
}

// The value a setting resolves to when the notebook doesn't override it.
function _cfgInherited(it) {
  if (it.key === 'agentmodel') return agentModel() || 'Sonnet (default)';   // the browser-global model
  return it.global != null && String(it.global) !== '' ? it.global : it.default;
}
function _cfgEffective(it) {
  if (it.overridden) return it.value;
  if (it.key === 'agentmodel') return agentModel();
  return it.global != null ? it.global : it.default;
}
function _cfgSource(it) {
  if (it.overridden) return { cls: 'override', txt: 'notebook' };
  if (it.key === 'agentmodel') return agentModel() ? { cls: 'global', txt: 'global' } : { cls: 'default', txt: 'default' };
  if (it.global != null && String(it.global) !== '' && String(it.global) !== String(it.default))
    return { cls: 'global', txt: 'global' };
  return { cls: 'default', txt: 'default' };
}

function _cfgControl(it, eff) {
  if (it.type === 'bool')
    return `<input type="checkbox" ${(eff === true || eff === 'true') ? 'checked' : ''} onchange="cfgSet('${it.key}', this.checked)"/>`;
  if (it.type === 'enum')
    return `<select onchange="cfgSet('${it.key}', this.value)">` +
      it.choices.map(c => `<option value="${_cfgEsc(c)}" ${String(eff) === c ? 'selected' : ''}>${_cfgEsc(c)}</option>`).join('') +
      `</select>`;
  if (it.type === 'int')
    return `<input class="cfgnum" type="number" min="1" max="6" value="${_cfgEsc(eff)}" onchange="cfgSet('${it.key}', this.value)"/>`;
  // string — show the override text (blank when inherited) with the inherited value as placeholder.
  const ph = it.key === 'agentmodel' ? (agentModel() || 'Sonnet (default)') : (it.key === 'threads' ? 'global (adaptive)' : String(it.default || ''));
  return `<input class="cfgtext" type="text" value="${it.overridden ? _cfgEsc(it.value) : ''}" placeholder="${_cfgEsc(ph)}" ` +
    `spellcheck="false" autocomplete="off" onchange="cfgSet('${it.key}', this.value)"/>`;
}

function _cfgRow(it) {
  const eff = _cfgEffective(it), src = _cfgSource(it);
  const clear = it.overridden
    ? `<button class="cfgclear" title="clear override — follow the global default" onclick="cfgClear('${it.key}')">✕</button>` : '';
  const sub = it.overridden ? '' : `<div class="cfgsub">follows ${src.txt}: ${_cfgEsc(_cfgInherited(it))}</div>`;
  return `<div class="cfgrow"><div class="cfglabel">${_cfgEsc(it.label)}<span class="cfgbadge ${src.cls}">${src.txt}</span>${sub}</div>` +
    `<div class="cfgctl">${_cfgControl(it, eff)}${clear}</div></div>`;
}

// Agent permission — CLIENT-ONLY, remembered per notebook (never in the file).
function _cfgPermRow() {
  const nb = nbAgentPerm();                          // '' = follow global
  const eff = nb || agentPerm() || 'lab';
  const src = nb ? { cls: 'override', txt: 'notebook' } : (agentPerm() ? { cls: 'global', txt: 'global' } : { cls: 'default', txt: 'default' });
  const opts = [['', 'Follow global'], ['lab', 'Lab (slate tools + edits)'], ['auto', 'Auto (self-governs)'],
                ['default', 'Default (edits only)'], ['bypass', 'Bypass (no checks)']];
  const sel = `<select onchange="cfgSetPerm(this.value)">` +
    opts.map(([v, t]) => `<option value="${v}" ${nb === v ? 'selected' : ''}>${_cfgEsc(t)}</option>`).join('') + `</select>`;
  return `<div class="cfggroup">Agent (local only)</div>` +
    `<div class="cfgrow"><div class="cfglabel">Agent permission<span class="cfgbadge ${src.cls}">${src.txt}</span>` +
    `<div class="cfgsub">local to this browser · never written to the file · effective: ${_cfgEsc(eff)}</div></div>` +
    `<div class="cfgctl">${sel}</div></div>`;
}

async function loadConfig() {
  const r = await api('GET', '/api/config') || {};
  const items = r.items || [];
  const groups = [];
  items.forEach(it => { let g = groups.find(x => x.name === it.group); if (!g) { g = { name: it.group, rows: [] }; groups.push(g); } g.rows.push(it); });
  let html = groups.map(g => `<div class="cfggroup">${_cfgEsc(g.name)}</div>` + g.rows.map(_cfgRow).join('')).join('');
  html += _cfgPermRow();                              // client-only permission row at the end
  document.getElementById('configlist').innerHTML = html;
  const n = items.filter(it => it.overridden).length + (nbAgentPerm() ? 1 : 0);
  document.getElementById('configstatus').textContent = n ? `${n} override${n === 1 ? '' : 's'}` : 'all defaults';
}

// Set a server-backed override (footer). agentmodel additionally reaps the agent so it rebinds.
async function cfgSet(key, value) {
  if (key === 'agentmodel' && !await _cfgReapAgent('model', String(value || '').trim() || 'global default')) { loadConfig(); return; }
  const s = await api('POST', '/api/config', { key, value });
  if (s && s.ok === false) { try { await alertDark('Could not set ' + key + ':\n' + (s.message || '?')); } catch (_) {} }
  else if (s) { try { renderAll(s); } catch (_) {} }
  loadConfig();
}
async function cfgClear(key) {
  if (key === 'agentmodel' && !await _cfgReapAgent('model', 'global default')) return;
  const s = await api('POST', '/api/config', { key, clear: true });
  if (s) { try { renderAll(s); } catch (_) {} }
  loadConfig();
}
// Set the per-notebook permission (local only). '' clears → follow global.
async function cfgSetPerm(v) {
  const label = v || ('global default (' + (agentPerm() || 'lab') + ')');
  if (!await _cfgReapAgent('permission', label)) { loadConfig(); return; }
  if (v) localStorage.setItem(nbAgentPermKey(), v); else localStorage.removeItem(nbAgentPermKey());
  loadConfig();
}
