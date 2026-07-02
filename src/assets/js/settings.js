// ── Slate UI theme ──────────────────────────────────────────────────────────────
// Registry for the Settings → Theme dropdown. Each name (except "midnight", the bare default)
// has a matching `html[data-slate-theme="<name>"]` palette block in notebook.css. `dark` is
// advisory metadata. Keep this list in sync with those CSS blocks.
const SLATE_UI_THEMES = [
  { name: 'midnight', label: 'Midnight (default)', dark: true },
  { name: 'graphite', label: 'Graphite', dark: true },
  { name: 'nord', label: 'Nord', dark: true },
  { name: 'dracula', label: 'Dracula', dark: true },
  { name: 'solarized-dark', label: 'Solarized Dark', dark: true },
  { name: 'daylight', label: 'Daylight', dark: false },
  { name: 'solarized-light', label: 'Solarized Light', dark: false },
];
const _SLATE_THEME_NAMES = new Set(SLATE_UI_THEMES.map(t => t.name));
function curSlateTheme() {
  const n = localStorage.getItem('slateTheme');
  return (n && _SLATE_THEME_NAMES.has(n)) ? n : 'midnight';
}
function setSlateTheme(name) {
  if (!_SLATE_THEME_NAMES.has(name)) return;
  localStorage.setItem('slateTheme', name);
  if (name === 'midnight') delete document.documentElement.dataset.slateTheme;
  else document.documentElement.dataset.slateTheme = name;
}

// ── Settings modal ────────────────────────────────────────────────────────────
function openSettings() {
  const deb = document.getElementById('setdeb'), v = document.getElementById('setdebv');
  deb.value = updateMs; v.textContent = updateMs;
  deb.oninput = () => { updateMs = parseInt(deb.value, 10) || 0; v.textContent = updateMs; localStorage.setItem('slateUpdateMs', updateMs); };
  const wide = document.getElementById('setwide');
  wide.checked = document.body.classList.contains('fullwidth');
  wide.onchange = () => { document.body.classList.toggle('fullwidth', wide.checked); localStorage.setItem('slateFullWidth', wide.checked ? '1' : '0'); };
  // Wrap wide text output (default off → matrices/wide tables scroll horizontally instead of wrapping).
  const wrap = document.getElementById('setwrap');
  if (wrap) {
    wrap.checked = document.body.classList.contains('wrap-output');
    wrap.onchange = () => { document.body.classList.toggle('wrap-output', wrap.checked); localStorage.setItem('slateWrapOutput', wrap.checked ? '1' : '0'); };
  }
  // Per-notebook settings (hot-reload, parallel, threads, slides, bibstyle, agent-model override)
  // now live in the "🎚 Notebook config" panel (config.js) — a single view with effective value +
  // source badge + clear-override, instead of being scattered here.
  // Overall Slate UI theme — applied by toggling html[data-slate-theme] (palette in notebook.css),
  // persisted as `slateTheme`, and re-applied at load by the inline head script (no flash).
  const th = document.getElementById('settheme');
  th.innerHTML = SLATE_UI_THEMES.map(t => `<option value="${t.name}">${t.label}</option>`).join('');
  th.value = curSlateTheme();
  th.onchange = () => setSlateTheme(th.value);
  // Editor syntax theme — options come from the cm6 theme registry (window._syntaxThemes), so adding
  // a theme in entry.js surfaces here automatically. Live-applied across all editors (tokens + chrome)
  // via window.setSyntaxTheme (editor.js).
  const syn = document.getElementById('setsyntax');
  if (syn) {
    const themes = window._syntaxThemes || [{ name: 'dark-plus', label: 'Dark+ (default)' }];
    syn.innerHTML = themes.map(t => `<option value="${t.name}">${t.label}</option>`).join('');
    syn.value = localStorage.getItem('slateSyntaxTheme') || 'dark-plus';
    syn.onchange = () => { window.setSyntaxTheme && window.setSyntaxTheme(syn.value); };
  }
  const mdl = document.getElementById('setmodel'), mhint = document.getElementById('setmodelhint');
  // Model and permission both bind only at spawn — changing either reaps the running
  // agent (chat-kill keeps the transcript) so the next turn respawns on the new setting.
  const reapAgent = async () => { mhint.style.display = ''; try { await api('POST', '/api/chat-kill', {}); } catch (_) {} setWorking(false); };
  // Confirm if a turn is in flight (the reap interrupts it), persist, reap, and drop a
  // visible note in the chat. Reverts the <select> if the user backs out mid-turn.
  const _selText = sel => sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : sel.value;
  // Persist a setting `value` (labelled for the chat note), confirming/aborting if a turn is
  // in flight, then reap so the next message respawns on it. `revert` restores the prior UI.
  const commitSetting = async (key, value, label, verb, noun, revert) => {
    if (agentWorking && !await confirmDark('A turn is in progress — ' + verb + ' and stop it?', 'Switch & stop', 'danger')) {
      revert && revert();
      return;
    }
    localStorage.setItem(key, value);
    await reapAgent();
    _agentNote('⚙ ' + noun + ' → ' + label + ' · applies to your next message');
  };
  const switchSetting = (sel, key, verb, noun) =>
    commitSetting(key, sel.value, _selText(sel), verb, noun, () => { sel.value = localStorage.getItem(key) || ''; });
  // ── Agent model, with a free-text "Custom…" escape hatch ──────────────────────
  // The stored model is the exact string sent per turn (server → `claude --model`). A preset
  // (opus/haiku/local) is picked from the dropdown; anything else (an exact id/version like
  // `claude-opus-4-8`) is a custom value: the dropdown shows "Custom…" and the text input holds it.
  const crow = document.getElementById('setmodelcustomrow');
  const cinp = document.getElementById('setmodelcustom');
  const _isPreset = v => [...mdl.options].some(o => o.value === v && o.value !== '__custom__');
  const reflectModel = () => {                 // point the UI at the saved model (preset vs custom)
    const saved = agentModel();
    if (saved && !_isPreset(saved)) { mdl.value = '__custom__'; cinp.value = saved; crow.style.display = ''; }
    else { mdl.value = saved; crow.style.display = 'none'; }
  };
  const commitCustom = () => {
    const v = cinp.value.trim();
    if (!v || v === agentModel()) return;      // empty or unchanged → nothing to do
    commitSetting('slateAgentModel', v, 'custom · ' + v, 'switch the model', 'model', reflectModel);
  };
  reflectModel();
  mdl.onchange = () => {
    if (mdl.value === '__custom__') { crow.style.display = ''; cinp.focus(); return; }  // commit on input blur/⏎
    crow.style.display = 'none';
    switchSetting(mdl, 'slateAgentModel', 'switch the model', 'model');
  };
  cinp.onchange = commitCustom;                // fires on Enter / blur
  cinp.onkeydown = e => { if (e.key === 'Enter') cinp.blur(); };
  // Append locally-served models (Ollama, and vmlx — the MLX server for Apple Silicon).
  // Both need their server running + Kaimon's OllamaBackend, and are routed by prefix.
  // Rebuilt each open so the list stays fresh and never duplicates.
  const addLocalModels = (route, prefix, label) => {
    [...mdl.querySelectorAll('option[value^="' + prefix + ':"]')].forEach(o => o.remove());
    return api('GET', route).then(r => {
      (r && r.models || []).forEach(name => {
        const o = document.createElement('option');
        o.value = prefix + ':' + name; o.textContent = label + ' · ' + name + ' (local)'; mdl.appendChild(o);
      });
      reflectModel();   // re-apply: the saved choice may be one of these local models (else custom)
    }).catch(() => {});
  };
  addLocalModels('/api/ollama-models', 'ollama', 'Ollama');
  addLocalModels('/api/vmlx-models', 'vmlx', 'vmlx');
  const perm = document.getElementById('setperm');
  perm.value = agentPerm();
  perm.onchange = () => switchSetting(perm, 'slateAgentPerm', 'change permissions', 'permissions');
  document.getElementById('setbg').classList.add('show');
}
// Your GLOBAL agent-model default ('' = server default = sonnet).
function agentModel() { return localStorage.getItem('slateAgentModel') || ''; }
// Your GLOBAL permission preset ('' = lab default).
function agentPerm() { return localStorage.getItem('slateAgentPerm') || ''; }
// Per-notebook agent-permission memory. Kept LOCAL (localStorage keyed by notebook id) and never
// written to the .jl — a `bypass` preset must never ride a shared notebook. Empty → follow global.
function _nbId() { return (typeof nbState !== 'undefined' && nbState && nbState.id) || ''; }
function nbAgentPermKey() { return 'slatePerm:' + _nbId(); }
function nbAgentPerm() { return localStorage.getItem(nbAgentPermKey()) || ''; }
// EFFECTIVE values sent with each chat turn: per-notebook override wins, else the global default.
// Model override travels in the .jl (state_json → nbState.agentModel); permission is local-only.
function effectiveAgentModel() { return (typeof nbState !== 'undefined' && nbState && nbState.agentModel) || agentModel(); }
function effectiveAgentPerm() { return nbAgentPerm() || agentPerm(); }
function closeSettings() { document.getElementById('setbg').classList.remove('show'); }
document.getElementById('setbg').addEventListener('mousedown', e => { if (e.target.id === 'setbg') closeSettings(); });

