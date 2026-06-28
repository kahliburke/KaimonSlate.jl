// ── Agent chat ────────────────────────────────────────────────────────────────
// Consumer of Kaimon's agent service (see Kaimon/AGENT_SESSION_SERVICE_PLAN.md):
// send a turn → POST /api/<id>/chat; the agent's streamed events arrive over SSE as
// "agent:<json>" envelopes ({kind, turn, data}) and the agent edits cells via the
// slate.* tools (so the cells update through the normal SSE path).
let agentMsgs = [];   // {role:'user'|'assistant'|'tool'|'err', text, done?}
let agentWorking = false, agentT0 = 0, _agentTick = null, _stopArmed = false;
let _chatTarget = null;   // per-cell ✨: chat turns scoped to this cell id (+ its dep cone)
function toggleAgent() {
  const p = document.getElementById('agentpanel'); p.classList.toggle('open');
  const open = p.classList.contains('open');
  document.body.classList.toggle('agent-open', open);   // slide cells left of the panel
  if (open) { document.getElementById('apin').focus(); setWorking(agentWorking); }
}
// Show/hide the agent's streamed thinking (.apmsg.think) — a persisted view preference.
// Pure CSS class toggle on the panel; the think bubbles stay in the transcript, just hidden.
function applyThinkPref() {
  const p = document.getElementById('agentpanel');
  if (p) p.classList.toggle('hide-think', localStorage.getItem('slateHideThink') === '1');
}
function toggleThink() {
  const hidden = localStorage.getItem('slateHideThink') === '1';
  localStorage.setItem('slateHideThink', hidden ? '0' : '1');
  applyThinkPref();
}
applyThinkPref();   // apply saved preference at load (before the panel is first opened)
// Per-cell ✨ — scope chat turns to a cell; the server sends its source/output + upstream
// dependency cone to the agent. Persists until cleared, so follow-ups stay focused.
function askCell(id) {
  _chatTarget = id;
  document.getElementById('agentpanel').classList.contains('open') || toggleAgent();
  _updateChatTarget();
  document.getElementById('apin').focus();
}
function clearChatTarget() { _chatTarget = null; _updateChatTarget(); }
function _updateChatTarget() {
  const el = document.getElementById('chattarget'); if (!el) return;
  if (_chatTarget) {
    el.style.display = '';
    el.innerHTML = '↳ focused on cell <b>' + _esca(_chatTarget) + '</b><span class="x" onclick="clearChatTarget()" title="unfocus">✕</span>';
  } else { el.style.display = 'none'; el.innerHTML = ''; }
}
// Drive the breathing "working" indicator + elapsed timer. Pulses the closed
// pane's 💬 button so activity is visible even when the panel isn't open.
function setWorking(on) {
  if (on && !_agentTick) _agentTick = setInterval(renderAgentMsgs, 1000);
  if (!on && _agentTick) { clearInterval(_agentTick); _agentTick = null; }
  if (on && !agentWorking) agentT0 = Date.now();
  if (!on) _stopArmed = false;     // turn ended → reset STOP escalation
  agentWorking = on;
  const b = document.getElementById('agentbtn');
  const open = document.getElementById('agentpanel').classList.contains('open');
  if (b) b.classList.toggle('pulse', on && !open);
  renderAgentMsgs();
}
const _esca = s => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
// Deterministic hue per crew label so each agent gets a stable lane color.
function _crewHue(name) { let h = 0; for (const c of String(name)) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
// A small colored chip naming the speaking crew member (omitted for the solo agent).
function _crewBadge(crew) {
  if (!crew) return '';
  const h = _crewHue(crew);
  return `<span class="crewbadge" style="--ch:${h}">${_esca(crew)}</span>`;
}
// Turn a raw tool identifier (e.g. "mcp__kaimon__slate_add_cell") into a friendly,
// icon-prefixed label for the chat. Known tools get a hand-picked icon + name; any
// other tool falls back to its prefix-stripped, de-underscored form.
const _TOOL_LABEL = {
  slate_read:'📖 read notebook', slate_add_cell:'➕ add cell', slate_edit_cell:'✏️ edit cell',
  slate_run:'▶ run cell', slate_delete_cell:'🗑 delete cell', slate_view:'🖼 view figure',
  slate_search_docs:'🔎 search docs', slate_index_docs:'📇 index docs',
  slate_acquire_floor:'🔒 acquire floor', slate_release_floor:'🔓 release floor',
  slate_inspect:'🔬 inspect cell', slate_diag:'🩺 diagnostics', slate_eval_js:'🧩 eval JS', slate_export_pdf:'📄 export PDF',
  slate_list:'📚 list notebooks', slate_open:'📂 open notebook', slate_close:'📕 close notebook',
  ex:'λ eval', qdrant_search_code:'🔎 search code', goto_definition:'↪ goto def',
  search_methods:'🔎 search methods', format_code:'✨ format', run_tests:'✅ run tests',
  Read:'📄 read file', Edit:'✏️ edit file', Write:'📝 write file', Bash:'⌨ shell',
  Grep:'🔎 grep', Glob:'🔎 glob', TodoWrite:'📋 todo', WebFetch:'🌐 fetch', WebSearch:'🌐 web',
};
function _prettyTool(name) {
  let s = String(name || 'tool').replace(/^mcp__[a-z0-9_]+__/i, '');   // drop the MCP server prefix
  if (_TOOL_LABEL[s]) return _TOOL_LABEL[s];
  // Already-friendly title (has a space / capital) → keep as-is; else de-snake_case it.
  if (/[ A-Z]/.test(s) && !s.includes('_')) return s;
  return s.replace(/_/g, ' ');
}
// Lightweight, safe markdown → HTML for agent responses: fenced/inline code, bold/italic, links,
// headers, lists, paragraphs. Code and math ($…$, $$…$$, \(…\), \[…\]) are stashed BEFORE any
// markdown processing so they survive verbatim — math is left escaped-but-raw for KaTeX, which
// typeset() runs over the pane after render. Everything is HTML-escaped throughout (XSS-safe).
function mdLite(src) {
  src = String(src == null ? '' : src);
  const stash = [];
  const keep = h => { stash.push(h); return '' + (stash.length - 1) + ''; };
  src = src.replace(/```(\w*)\r?\n?([\s\S]*?)```/g, (_, _l, code) =>
    keep('<pre class="apcode"><code>' + _esca(code.replace(/\s+$/, '')) + '</code></pre>'));
  // math spans — kept as escaped raw text (delimiters intact) for KaTeX, NOT markdown-processed
  src = src.replace(/\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\$[^$\n]+?\$|\\\([^\n]+?\\\)/g, m => keep(_esca(m)));
  src = src.replace(/`([^`]+)`/g, (_, c) => keep('<code>' + _esca(c) + '</code>'));
  const inline = s => _esca(s)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*\n]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  let html = '', para = [], list = null;
  const fp = () => { if (para.length) { html += '<p>' + para.map(inline).join('<br>') + '</p>'; para = []; } };
  const fl = () => { if (list) { html += `<${list.t}>` + list.items.map(i => '<li>' + inline(i) + '</li>').join('') + `</${list.t}>`; list = null; } };
  for (const ln of src.split('\n')) {
    const ph = ln.match(/^(\d+)$/), h = ln.match(/^(#{1,6})\s+(.*)$/);
    const ul = ln.match(/^\s*[-*]\s+(.*)$/), ol = ln.match(/^\s*\d+\.\s+(.*)$/);
    if (ph) { fp(); fl(); html += stash[+ph[1]]; }
    else if (h) { fp(); fl(); html += '<div class="apmd-h">' + inline(h[2]) + '</div>'; }
    else if (ul) { fp(); if (!list || list.t !== 'ul') { fl(); list = { t: 'ul', items: [] }; } list.items.push(ul[1]); }
    else if (ol) { fp(); if (!list || list.t !== 'ol') { fl(); list = { t: 'ol', items: [] }; } list.items.push(ol[1]); }
    else if (!ln.trim()) { fp(); fl(); }
    else { fl(); para.push(ln); }
  }
  fp(); fl();
  return html.replace(/(\d+)/g, (_, i) => stash[+i]);   // restore spans that landed inline
}
let _suppressAgentRender = false;   // set during bulk replay (loadAgentLog) → render once at the end
function renderAgentMsgs() {
  if (_suppressAgentRender) return;   // skip per-event re-renders during a replay (O(n²) markdown+KaTeX)
  const el = document.getElementById('apmsgs');
  let html = agentMsgs.map(m => {
    const lane = m.crew ? ` lane` : '';
    const tag = m.crew ? `style="--ch:${_crewHue(m.crew)}"` : '';
    return (
      m.role === 'img'  ? `<div class="apmsg img${lane}" ${tag}>${_crewBadge(m.crew)}<img src="${m.src}" alt="agent image"></div>`
    : m.role === 'tool' ? `<div class="apmsg tool${lane}" ${tag}>${_crewBadge(m.crew)}${_esca(m.text)}${m.code ? `<pre class="toolcode">${_esca(m.code)}</pre>` : ''}${m.result ? `<pre class="toolresult${m.resultErr ? ' err' : ''}">${_esca(m.result)}</pre>` : ''}</div>`
    : m.role === 'assistant' ? `<div class="apmsg assistant apmd${lane}" ${tag}>${_crewBadge(m.crew)}${mdLite(m.text)}</div>`
    :                     `<div class="apmsg ${m.role}${lane}" ${tag}>${_crewBadge(m.crew)}${_esca(m.text)}</div>`);
  }).join('');
  if (agentWorking) {
    const s = Math.max(0, Math.floor((Date.now() - agentT0) / 1000));
    html += `<div class="apworking"><span class="dots"><i></i><i></i><i></i></span>working… ${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}` +
      `<button class="apstop" style="margin-left:10px;cursor:pointer" onclick="agentStop()">${_stopArmed ? '⛔ Force stop' : '⏹ Stop'}</button></div>`;
  }
  el.innerHTML = html;
  // Render LaTeX in the assistant replies (math was stashed verbatim through mdLite). typeset is
  // idempotent over already-rendered KaTeX, so re-running each delta only touches new text nodes.
  if (window.typeset) el.querySelectorAll('.apmd').forEach(m => { try { typeset(m); } catch (_) {} });
  el.scrollTop = el.scrollHeight;
}
// Replay the buffered conversation after a page reload (in-memory agentMsgs is
// gone, but the server kept every relayed envelope). Idempotent — clears first.
async function loadAgentLog() {
  try {
    const r = await api('GET', '/api/agent-log');
    if (!r || !r.events || !r.events.length) return;
    agentMsgs = []; setWorking(false);
    // Replay the whole log building agentMsgs, but render the DOM only ONCE at the end — otherwise
    // each of the hundreds of events triggers a full markdown+KaTeX re-render (was ~7.5s on a big log).
    _suppressAgentRender = true;
    try { for (const line of r.events) { try { agentEvent(JSON.parse(line)); } catch (_) {} } }
    finally { _suppressAgentRender = false; }
    renderAgentMsgs();
  } catch (_) {}
}
const agentStatus = s => { document.getElementById('apstatus').textContent = s || ''; };
// A centered, dim system line in the transcript (e.g. "⚙ model → … applies next message").
function _agentNote(text) { agentMsgs.push({ role: 'note', text }); renderAgentMsgs(); }
// Surface an action driven into the page OUTSIDE the in-notebook agent stream — e.g. an external
// (MCP) agent's `slate.eval_js` running JS in this tab — as a tool entry in the chat panel, so the
// user can SEE what's being done to their notebook. Returns the message object so the caller can
// flip `done`/`text` (then re-render) once it resolves.
function logAgentAction(text, code) {
  const m = { role: 'tool', text, code: code || '', done: false };
  agentMsgs.push(m); renderAgentMsgs();
  return m;
}
window.logAgentAction = logAgentAction;
// STOP escalates: first press interrupts the in-flight turn (graceful); if the agent
// is wedged and still working, a second press hard-kills it (terminates the process,
// clears the agent — the next message spawns a fresh one).
async function agentStop() {
  if (!_stopArmed) {
    _stopArmed = true; agentStatus('stopping…'); renderAgentMsgs();
    try { await api('POST', '/api/chat-interrupt', {}); } catch (_) {}
    return;
  }
  agentStatus('killing…');
  try { await api('POST', '/api/chat-kill', {}); } catch (_) {}
  setWorking(false); agentStatus('stopped');
  agentMsgs.push({ role: 'err', text: '⛔ agent stopped' }); renderAgentMsgs();
}
// Wipe the whole conversation (memory + disk) and stop the agent. The next message
// starts fresh on the current model/permission settings.
async function clearChat() {
  if (!await confirmDark("Clear this notebook's chat history and stop the agent?", 'Clear', 'danger')) return;
  try { await api('POST', '/api/chat-clear', {}); } catch (_) {}
  agentMsgs = []; setWorking(false); agentStatus(''); renderAgentMsgs();
}
async function agentSend() {
  const inp = document.getElementById('apin'), text = inp.value.trim(); if (!text) return;
  inp.value = ''; _stopArmed = false; agentMsgs.push({ role: 'user', text }); agentStatus('thinking…'); setWorking(true);
  try {
    const r = await api('POST', '/api/chat', { text, target: _chatTarget || '', model: agentModel(), permission: agentPerm() });
    if (r && r.ok === false) { agentMsgs.push({ role: 'err', text: r.error || 'agent unavailable' }); agentStatus(''); setWorking(false); }
  } catch (e) { agentMsgs.push({ role: 'err', text: 'agent service unavailable' }); agentStatus(''); setWorking(false); }
}
// Map a Kaimon agent event ({kind,turn,data}) — shapes per AGENT_SESSION_SERVICE_STATUS.md
// — onto the chat transcript. Text streams as complete messages (not token deltas).
// Tolerant-extract the field being written from a (possibly truncated) partial-JSON
// args blob — the first of these keys present, decoding string escapes as far as the
// buffer goes. Lets the agent's code render as it streams in.
function _extractCode(s) {
  const ESC = { n: '\n', t: '\t', r: '\r', '"': '"', '\\': '\\', '/': '/' };
  for (const key of ['source', 'code', 'new_string', 'content', 'command', 'text']) {
    const i = s.indexOf('"' + key + '"'); if (i < 0) continue;
    let j = s.indexOf(':', i + key.length + 1); if (j < 0) continue;
    j++; while (j < s.length && /\s/.test(s[j])) j++;
    if (s[j] !== '"') continue;
    let out = '', p = j + 1;
    while (p < s.length) {
      const ch = s[p];
      if (ch === '\\') { const n = s[p + 1]; out += n in ESC ? ESC[n] : (n || ''); p += 2; }
      else if (ch === '"') break;
      else { out += ch; p++; }
    }
    return out;
  }
  return '';
}
function agentEvent(env) {
  if (!env) return;
  const d = env.data || {};
  const k = env.kind;
  const crew = env.crew || '';   // crew label of the speaking agent ('' = solo/default)
  if (k === 'assistant_text' || k === 'thought') {
    // Streaming: delta:true chunks APPEND live; the final delta:false copy REPLACES
    // the streamed block (self-healing any dropped delta). Non-streaming services
    // send only complete blocks → the else branch (back-compat).
    const role = k === 'thought' ? 'think' : 'assistant';
    const txt = (d.content && d.content.text) || '';
    let last = agentMsgs[agentMsgs.length - 1];
    const openSame = last && last.role === role && !last.done;
    if (d.delta === true) {
      if (!txt) return;
      if (!openSame) { last = { role, text: '', streamed: true, crew }; agentMsgs.push(last); }
      last.text += txt; last.streamed = true;
    } else if (openSame && last.streamed) {
      last.text = txt; last.done = true;                 // authoritative copy
    } else {
      if (!txt) return;
      agentMsgs.push({ role, text: txt, done: true, crew });
    }
  } else if (k === 'tool_use') {
    // Upsert by toolCallId — `tool_use` fires at call-begin (in_progress) and may
    // be re-emitted; don't duplicate. Authoritative input (if present) wins.
    const c = d.call || {};
    let tm = agentMsgs.find(m => m.role === 'tool' && m.id === c.toolCallId);
    if (!tm) { tm = { role: 'tool', id: c.toolCallId, title: '', inputBuf: '', code: '', done: false, crew }; agentMsgs.push(tm); }
    tm.title = _prettyTool(c.title || c.kind || tm.title || 'tool');
    tm.text = tm.title;
    if (c.rawInput) tm.code = _extractCode(JSON.stringify(c.rawInput)) || tm.code;
  } else if (k === 'tool_input_delta') {
    // The call's arguments stream as raw JSON fragments — concatenate, then
    // tolerant-extract the field being written (source/code/new_string/…) so the
    // agent's code "types in" live. (Liveness only; not buffered for replay.)
    const tm = agentMsgs.find(m => m.role === 'tool' && m.id === d.toolCallId);
    if (tm) { tm.inputBuf = (tm.inputBuf || '') + (d.partialJson || ''); tm.code = _extractCode(tm.inputBuf); }
  } else if (k === 'tool_result') {
    // Every tool_result is terminal — Kaimon rides the authoritative input as a 2nd
    // `tool_use` (rawInput), not an in_progress tool_result (consumed in tool_use
    // above). So finalize the call and surface any image blocks.
    const u = d.update || {};
    const tm = agentMsgs.find(m => m.role === 'tool' && m.id === u.toolCallId && !m.done);
    if (tm) { tm.done = true; if (u.status === 'failed') tm.role = 'err'; }
    for (const b of (u.content || [])) {
      const inner = b && b.content;
      if (inner && inner.type === 'image' && inner.data)
        agentMsgs.push({ role: 'img', src: `data:${inner.mimeType || 'image/png'};base64,${inner.data}`, crew });
    }
  } else if (k === 'plan') {
    const lines = (d.entries || []).map(e => `• ${e.content}${e.status === 'completed' ? ' ✓' : ''}`).join('\n');
    if (lines) agentMsgs.push({ role: 'tool', text: '📋 plan\n' + lines, done: true, crew });
  } else if (k === 'status') {
    agentStatus(d.status === 'working' ? 'working…' : (d.status || ''));
    return;
  } else if (k === 'turn_started') {
    agentStatus('working…'); setWorking(true); return;
  } else if (k === 'result') {
    const last = agentMsgs[agentMsgs.length - 1]; if (last && last.role === 'assistant') last.done = true;
    agentStatus(''); setWorking(false);
  } else if (k === 'error') {
    agentMsgs.push({ role: 'err', text: d.message || 'error' }); agentStatus(''); setWorking(false);
  } else { return; }
  renderAgentMsgs();
}
// ── @id mention autocomplete (chat input) ─────────────────────────────────────
// Typing `@` in the chat offers the notebook's cell ids; picking one inserts `@id `.
// The server expands each @id mention into that cell's source + result (_mention_context),
// so you can point the agent at specific cells without it surveying the whole notebook.
let _mention = { open: false, items: [], sel: 0, start: -1 };
function _mentionBox() {
  let b = document.getElementById('mentionbox');
  if (!b) { b = document.createElement('div'); b.id = 'mentionbox'; b.className = 'mentionbox'; document.body.appendChild(b);
    b.addEventListener('mousedown', e => { const li = e.target.closest('li'); if (li) { e.preventDefault(); _insertMention(+li.dataset.i); } }); }
  return b;
}
function _closeMention() { _mention.open = false; const b = document.getElementById('mentionbox'); if (b) b.style.display = 'none'; }
// The `@word` token immediately left of the caret (no whitespace), or null.
function _mentionToken(ta) {
  const m = ta.value.slice(0, ta.selectionStart).match(/@([A-Za-z0-9_]*)$/);
  return m ? { start: ta.selectionStart - m[0].length, prefix: m[1] } : null;
}
function updateMention() {
  const ta = document.getElementById('apin'), tok = _mentionToken(ta), box = _mentionBox();
  if (!tok) { _closeMention(); return; }
  const p = tok.prefix.toLowerCase();
  const ids = cellIds().filter(id => id.toLowerCase().startsWith(p)).slice(0, 8);
  if (!ids.length) { _closeMention(); return; }
  _mention = { open: true, items: ids, sel: 0, start: tok.start };
  _paintMention();
  const r = ta.getBoundingClientRect();
  box.style.left = r.left + 'px'; box.style.width = r.width + 'px';
  box.style.display = 'block';
  box.style.top = (r.top - box.offsetHeight - 6) + 'px';   // float just above the textarea
}
function _paintMention() {
  _mentionBox().innerHTML = '<ul>' + _mention.items.map((id, i) =>
    `<li class="${i === _mention.sel ? 'on' : ''}" data-i="${i}">@${_escc(id)}</li>`).join('') + '</ul>';
}
function _insertMention(i) {
  const ta = document.getElementById('apin'), id = _mention.items[i]; if (!id) return;
  const v = ta.value, c = ta.selectionStart;
  ta.value = v.slice(0, _mention.start) + '@' + id + ' ' + v.slice(c);
  const np = _mention.start + id.length + 2;
  _closeMention(); ta.focus(); ta.setSelectionRange(np, np);
}
document.getElementById('apin').addEventListener('input', updateMention);
document.getElementById('apin').addEventListener('blur', () => setTimeout(_closeMention, 150));
document.getElementById('apin').addEventListener('keydown', e => {
  if (_mention.open) {                                  // mention menu intercepts nav keys
    if (e.key === 'ArrowDown') { e.preventDefault(); _mention.sel = Math.min(_mention.sel + 1, _mention.items.length - 1); _paintMention(); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); _mention.sel = Math.max(_mention.sel - 1, 0); _paintMention(); return; }
    if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); _insertMention(_mention.sel); return; }
    if (e.key === 'Escape') { e.preventDefault(); _closeMention(); return; }
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); agentSend(); }
});

