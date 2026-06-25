// ── Settings modal ────────────────────────────────────────────────────────────
function openSettings() {
  const deb = document.getElementById('setdeb'), v = document.getElementById('setdebv');
  deb.value = updateMs; v.textContent = updateMs;
  deb.oninput = () => { updateMs = parseInt(deb.value, 10) || 0; v.textContent = updateMs; localStorage.setItem('slateUpdateMs', updateMs); };
  const wide = document.getElementById('setwide');
  wide.checked = document.body.classList.contains('fullwidth');
  wide.onchange = () => { document.body.classList.toggle('fullwidth', wide.checked); localStorage.setItem('slateFullWidth', wide.checked ? '1' : '0'); };
  // Per-notebook: pick up parent /src edits (Revise) and mark affected cells stale (default on).
  const hr = document.getElementById('sethotreload');
  hr.checked = !(nbState && nbState.hotreload === false);
  hr.onchange = () => api('POST', '/api/hotreload', { enabled: hr.checked }).catch(() => {});
  const th = document.getElementById('settheme');
  th.value = localStorage.getItem('slateTheme') || 'dark';
  th.onchange = () => localStorage.setItem('slateTheme', th.value);   // real themes land later
  // Editor syntax palette — live-applied across all editors via window.setSyntaxTheme (editor.js).
  const syn = document.getElementById('setsyntax');
  if (syn) {
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
  const switchSetting = async (sel, key, verb, noun) => {
    if (agentWorking && !await confirmDark('A turn is in progress — ' + verb + ' and stop it?', 'Switch & stop', 'danger')) {
      sel.value = localStorage.getItem(key) || '';   // back out → restore the prior selection
      return;
    }
    localStorage.setItem(key, sel.value);
    await reapAgent();
    _agentNote('⚙ ' + noun + ' → ' + _selText(sel) + ' · applies to your next message');
  };
  mdl.value = agentModel();
  mdl.onchange = () => switchSetting(mdl, 'slateAgentModel', 'switch the model', 'model');
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
      mdl.value = agentModel();   // re-apply: the saved choice may be one of these local models
    }).catch(() => {});
  };
  addLocalModels('/api/ollama-models', 'ollama', 'Ollama');
  addLocalModels('/api/vmlx-models', 'vmlx', 'vmlx');
  const perm = document.getElementById('setperm');
  perm.value = agentPerm();
  perm.onchange = () => switchSetting(perm, 'slateAgentPerm', 'change permissions', 'permissions');
  document.getElementById('setbg').classList.add('show');
}
// The chosen agent model ('' = server default = sonnet), sent with every chat turn.
function agentModel() { return localStorage.getItem('slateAgentModel') || ''; }
// The chosen permission preset ('' = lab default), sent with every chat turn.
function agentPerm() { return localStorage.getItem('slateAgentPerm') || ''; }
function closeSettings() { document.getElementById('setbg').classList.remove('show'); }
document.getElementById('setbg').addEventListener('mousedown', e => { if (e.target.id === 'setbg') closeSettings(); });

