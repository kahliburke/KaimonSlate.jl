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
  // Per-notebook: pick up parent /src edits (Revise) and mark affected cells stale (default on).
  const hr = document.getElementById('sethotreload');
  hr.checked = !(nbState && nbState.hotreload === false);
  hr.onchange = () => api('POST', '/api/hotreload', { enabled: hr.checked }).catch(() => {});
  // Per-notebook: run independent cells concurrently in the worker (default off — the serial path).
  const par = document.getElementById('setparallel');
  if (par) {
    par.checked = !!(nbState && nbState.parallel === true);
    par.onchange = () => api('POST', '/api/parallel', { enabled: par.checked }).catch(() => {});
  }
  // Per-notebook worker thread override. Blank = global. Apply POSTs /threads, which restarts the
  // worker (warm namespace is lost), so it's a button, not live-on-change.
  const thr = document.getElementById('setthreads'), thrApply = document.getElementById('setthreadsapply'),
        thrEff = document.getElementById('setthreadseff');
  if (thr) {
    thr.value = (nbState && nbState.threads) || '';
    if (thrEff) thrEff.textContent = nbState && nbState.threadsEffective ? `now: ${nbState.threadsEffective}` : '';
    const applyThreads = async () => {
      try { renderAll(await api('POST', '/api/threads', { threads: thr.value.trim() })); } catch (_) {}
    };
    thrApply && (thrApply.onclick = applyThreads);
    thr.onkeydown = e => { if (e.key === 'Enter') applyThreads(); };
  }
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

