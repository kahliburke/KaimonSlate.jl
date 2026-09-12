// ── Agent chat ────────────────────────────────────────────────────────────────
// Consumer of Kaimon's agent service (see Kaimon/AGENT_SESSION_SERVICE_PLAN.md):
// send a turn → POST /api/<id>/chat; the agent's streamed events arrive over SSE as
// "agent:<json>" envelopes ({kind, turn, data}) and the agent edits cells via the
// slate.* tools (so the cells update through the normal SSE path).
let agentMsgs = [];   // {role:'user'|'assistant'|'tool'|'err', text, done?}
let agentWorking = false, agentT0 = 0, _agentTick = null, _stopArmed = false;
let _chatTarget = null;   // per-cell ✨: chat turns scoped to this cell id (+ its dep cone)
// The agent service lives in Kaimon — a standalone hub (slate --own / serve_notebook) has none.
// The topbar button is disabled via updateChrome; these guards cover every other entry point
// (per-cell ✨, keyboard, palette) with an explanation instead of a dead panel.
function agentAvailable() { return !(typeof nbState !== 'undefined' && nbState && nbState.agentAvailable === false); }
function _agentUnavailableNotice() {
  toast('Agent chat needs Kaimon — this hub is running standalone. Start Kaimon and open the notebook from its hub (the `slate` command attaches automatically).', 6500);
}
function toggleAgent() {
  const p = document.getElementById('agentpanel');
  if (!p.classList.contains('open') && !agentAvailable()) { _agentUnavailableNotice(); return; }   // block opening only — closing always works
  p.classList.toggle('open');
  const open = p.classList.contains('open');
  document.body.classList.toggle('agent-open', open);   // slide cells left of the panel
  // Sized on OPEN, not only at load: `scrollHeight` is 0 while the panel is hidden, so a draft
  // left in the box would come back the wrong height until the first keystroke.
  _publishAgentWidth();
  if (open) { document.getElementById('apin').focus(); apAutoGrow(); setWorking(agentWorking); }
}
// The panel's real width, as a CSS variable on <body>. Read from the element rather than assumed,
// so maximizing (or a narrow viewport clamping it) moves everything that sits clear of it.
function _publishAgentWidth() {
  const p = document.getElementById('agentpanel'); if (!p) return;
  document.body.style.setProperty('--agentw', Math.round(p.getBoundingClientRect().width) + 'px');
}
window.addEventListener('resize', _publishAgentWidth);
// Maximize / restore the agent panel — a wide near-fullscreen view for reading detailed replies.
function toggleAgentMax() {
  const max = document.getElementById('agentpanel').classList.toggle('maximized');
  const b = document.getElementById('apmaxbtn');
  if (b) { b.textContent = max ? '🗗' : '⛶'; b.title = max ? 'restore the panel' : 'maximize the panel'; }
  _publishAgentWidth();
}
window.toggleAgentMax = toggleAgentMax;
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
  if (!agentAvailable()) { _agentUnavailableNotice(); return; }
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
const _esca = s => window.slateEscHtml(s);
// URL guards for agent-authored content (LLM/tool text can reflect untrusted repo data): detect the
// scheme the way a browser would — after stripping control/whitespace chars, so `java\tscript:` can't
// slip past — and block anything but the allowlisted schemes, then neutralize quotes so a crafted
// link/image can't break out of the href/src attribute.
const _urlScheme = s => { const m = String(s == null ? '' : s).replace(/[\x00-\x20]+/g, '').match(/^([a-z][a-z0-9+.-]*):/i); return m ? m[1].toLowerCase() : ''; };
const _safeHref = u => {   // arrives already HTML-escaped from _esca; only the scheme remains to check
  const sc = _urlScheme(u);
  if (sc && !['http', 'https', 'mailto'].includes(sc)) return '#';
  return String(u).replace(/"/g, '%22').replace(/'/g, '%27');
};
const _safeImgSrc = u => {
  const sc = _urlScheme(u);
  if (sc && !['http', 'https', 'data'].includes(sc)) return '';
  return window.slateEscHtml(u);
};
// Deterministic hue per crew label so each agent gets a stable lane color.
function _crewHue(name) { let h = 0; for (const c of String(name)) h = (h * 31 + c.charCodeAt(0)) % 360; return h; }
// A small colored chip naming the speaking agent. The notebook's own agent is named too, now that
// it is not the only voice: with a specialist and a reviewer both talking, the UNLABELLED one is
// the ambiguous one, and "which of them said this" is the first thing you need to know.
//
// It is KAIMON, shown as 開門 — the mark Kaimon already carries in its own TUI, where the same two
// characters identify a session as Kaimon's. One mark, one meaning, in both places. `debugger` and
// `checker` stay lowercase Latin because they are JOBS; the difference in script says which of the
// three is a participant with a name and which two are roles, without anyone explaining it.
//
// Not the model it happens to be running on: that changes without it becoming a different
// participant in the conversation.
const SOLO_NAME = 'Kaimon';
const SOLO_MARK = '開門';
const _crewName = crew => crew || SOLO_NAME;
const _crewMark = crew => crew || SOLO_MARK;
function _crewBadge(crew) {
  return `<span class="crewbadge" style="--ch:${_crewHue(_crewName(crew))}"` +
         ` title="${_esca(_crewName(crew))}" aria-label="${_esca(_crewName(crew))}">` +
         `${_esca(_crewMark(crew))}</span>`;
}
// The same name as a block heading rather than an inline chip — for a grouped run of actions,
// where it is said once for the whole block.
function _crewLabel(crew) {
  return `<span class="crewlabel" style="--ch:${_crewHue(_crewName(crew))}"` +
         ` title="${_esca(_crewName(crew))}" aria-label="${_esca(_crewName(crew))}">` +
         `${_esca(_crewMark(crew))}</span>`;
}
// Marks a tool call driven into this notebook from OUTSIDE its chat — an external MCP agent
// (or one Kaimon spawned for another notebook) reaching the slate.* tools directly.
function _extBadge(on) {
  return on ? `<span class="extbadge" title="a tool call from an external agent, outside this notebook's chat">⚡ external</span>` : '';
}
// Turn a raw tool identifier (e.g. "mcp__kaimon__slate_add_cell") into a friendly,
// icon-prefixed label for the chat. Known tools get a hand-picked icon + name; any
// other tool falls back to its prefix-stripped, de-underscored form.
// Keyed on the BARE verb, not the full tool name: a gate serves under a namespace, so the same
// verb arrives as `slate_read` in one install and `slate_dbg_read` in another. Keying on the full
// name meant every tool from a non-default namespace missed and rendered as "slate dbg dbg eval".
const _TOOL_LABEL = {
  read:'📖 read notebook', add_cell:'➕ add cell', edit_cell:'✏️ edit cell',
  run:'▶ run cell', delete_cell:'🗑 delete cell', view:'🖼 view figure', surface:'🎛 surface controls',
  search_docs:'🔎 search docs', index_docs:'📇 index docs',
  acquire_floor:'🔒 acquire floor', release_floor:'🔓 release floor',
  inspect:'🔬 inspect cell', diag:'🩺 diagnostics', eval:'λ scratch eval', eval_js:'🧩 eval JS', export_pdf:'📄 export PDF',
  list:'📚 list notebooks', open:'📂 open notebook', close:'📕 close notebook',
  rename_cell:'🏷 rename cell', pkg:'📦 packages', request_file_access:'🔑 ask for file access',
  dbg_start:'🐞 start debugging', dbg_step:'👣 step', dbg_frame:'🧾 frame',
  dbg_eval:'🔬 look at a value', dbg_break:'⏹ breakpoint', dbg_watch:'📈 watch',
  dbg_summon:'🐞 summon debugger', dbg_wait:'⏳ wait for specialist', dbg_tell:'💬 tell specialist',
  dbg_ask:'❓ ask', dbg_choose:'❓ offer a choice', dbg_answer:'✔ answer', dbg_done:'✓ finish debugging',
  check_ok:'✔ checked', check_flag:'⚑ flagged',
  ex:'λ eval', qdrant_search_code:'🔎 search code', search_code:'🔎 search code', goto_definition:'↪ goto def',
  search_methods:'🔎 search methods', format_code:'✨ format', run_tests:'✅ run tests',
  Read:'📄 read file', Edit:'✏️ edit file', Write:'📝 write file', Bash:'⌨ shell',
  Grep:'🔎 grep', Glob:'🔎 glob', TodoWrite:'📋 todo', WebFetch:'🌐 fetch', WebSearch:'🌐 web',
};
// The bare verb behind a namespaced tool name, or the name itself when it isn't one.
function _bareTool(name) {
  let s = String(name || 'tool').replace(/^mcp__[a-z0-9_]+__/i, '');   // drop the MCP server prefix
  // Drop leading segments until one is a verb we know. `slate_dbg_dbg_eval` → `dbg_eval`, which
  // stops there rather than going on to `eval` and calling a frame probe a scratch eval.
  let t = s;
  while (!_TOOL_LABEL[t] && t.includes('_')) t = t.slice(t.indexOf('_') + 1);
  return _TOOL_LABEL[t] ? t : s;
}
function _prettyTool(name) {
  const s = _bareTool(name);
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
  src = String(src == null ? '' : src).replace(/\u0000/g, '');
  const stash = [];
  // A placeholder must not be a bare index: the restore pass at the end scans the whole rendered
  // string, so plain digits would also match numbers in the prose and swap them for stash[n]:
  // undefined, or an unrelated stashed span when n happens to be in range. NUL-delimit them; NULs
  // are stripped from the source above, so text can never forge one.
  const keep = h => { stash.push(h); return '\u0000' + (stash.length - 1) + '\u0000'; };
  src = src.replace(/```(\w*)\r?\n?([\s\S]*?)```/g, (_, _l, code) =>
    keep('<pre class="apcode"><code>' + _esca(code.replace(/\s+$/, '')) + '</code></pre>'));
  // math spans — kept as escaped raw text (delimiters intact) for KaTeX, NOT markdown-processed
  src = src.replace(/\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\$[^$\n]+?\$|\\\([^\n]+?\\\)/g, m => keep(_esca(m)));
  src = src.replace(/`([^`]+)`/g, (_, c) => keep('<code>' + _esca(c) + '</code>'));
  const inline = s => _esca(s)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*\n]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, txt, url) => `<a href="${_safeHref(url)}" target="_blank" rel="noopener">${txt}</a>`);
  let html = '', para = [], list = null;
  const fp = () => { if (para.length) { html += '<p>' + para.map(inline).join('<br>') + '</p>'; para = []; } };
  const fl = () => { if (list) { html += `<${list.t}>` + list.items.map(i => '<li>' + inline(i) + '</li>').join('') + `</${list.t}>`; list = null; } };
  // GFM pipe tables. Agents report measurements as tables constantly, and without this they
  // render as raw pipe soup. Splitting a row on '|' is safe because code spans are already
  // stashed by this point, so a pipe inside `code` can't be taken for a column separator.
  const isDelim = t => /^[\s|:-]+$/.test(t) && t.includes('-') && t.includes('|');
  const cells = row => row.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(x => x.trim());
  const lines = src.split('\n');
  for (let li = 0; li < lines.length; li++) {
    const ln = lines[li];
    const ph = ln.match(/^\u0000(\d+)\u0000$/), h = ln.match(/^(#{1,6})\s+(.*)$/);
    const ul = ln.match(/^\s*[-*]\s+(.*)$/), ol = ln.match(/^\s*\d+\.\s+(.*)$/);
    if (!ph && !h && ln.includes('|') && isDelim(lines[li + 1] || '')) {
      fp(); fl();
      const al = cells(lines[li + 1]).map(d =>
        d.startsWith(':') && d.endsWith(':') ? 'center' : d.endsWith(':') ? 'right' : '');
      const cell = (v, i, t) => `<${t}${al[i] ? ` style="text-align:${al[i]}"` : ''}>` + inline(v) + `</${t}>`;
      const head = cells(ln).map((v, i) => cell(v, i, 'th')).join('');
      let body = '', j = li + 2;
      for (; j < lines.length && lines[j].trim() && lines[j].includes('|'); j++)
        body += '<tr>' + cells(lines[j]).map((v, i) => cell(v, i, 'td')).join('') + '</tr>';
      html += `<table class="apmd-t"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
      li = j - 1;
    }
    else if (ph) { fp(); fl(); html += stash[+ph[1]]; }
    else if (h) { fp(); fl(); html += '<div class="apmd-h">' + inline(h[2]) + '</div>'; }
    else if (ul) { fp(); if (!list || list.t !== 'ul') { fl(); list = { t: 'ul', items: [] }; } list.items.push(ul[1]); }
    else if (ol) { fp(); if (!list || list.t !== 'ol') { fl(); list = { t: 'ol', items: [] }; } list.items.push(ol[1]); }
    else if (!ln.trim()) { fp(); fl(); }
    else { fl(); para.push(ln); }
  }
  fp(); fl();
  return html.replace(/\u0000(\d+)\u0000/g, (_, i) => stash[+i] ?? '');   // restore spans that landed inline
}
let _suppressAgentRender = false;   // set during bulk replay (loadAgentLog) → render once at the end
// Pretty-print a tool call's args for the expandable detail (capped so a giant source doesn't bloat the pane).
function _argsPretty(a) {
  let s; try { s = JSON.stringify(a, null, 1); } catch (_) { s = String(a); }
  return s.length > 2000 ? s.slice(0, 1999) + '…' : s;
}
function _agentMsgHtml(m) {
  const lane = m.crew ? ` lane` : '';
  const tag = m.crew ? `style="--ch:${_crewHue(m.crew)}"` : '';
  if (m.role === 'tool') {
    const cidChip = m.cid ? ` <span class="toolnav" data-cid="${_esca(m.cid)}" title="go to cell ${_esca(m.cid)}">→ ${_esca(m.cid)}</span>` : '';
    const codePre = m.code ? `<pre class="toolcode">${_esca(m.code)}</pre>` : '';
    // Terse rows (e.g. "ToolSearch") show only a name; stash the full args + result behind a click.
    const argsStr = m.args != null ? _argsPretty(m.args) : '';
    const resStr = m.resultText || m.result || '';
    const hasDetail = !!(argsStr || resStr);
    const detail = hasDetail ? `<div class="tooldetail">` +
      (argsStr ? `<div class="tdlabel">args</div><pre class="toolargs">${_esca(argsStr)}</pre>` : '') +
      (resStr ? `<div class="tdlabel">result</div><pre class="toolresult${m.resultErr ? ' err' : ''}">${_esca(resStr)}</pre>` : '') +
      `</div>` : '';
    return `<div class="apmsg tool${lane}${m.external ? ' ext' : ''}${hasDetail ? ' expandable' : ''}" ${tag}>${_crewBadge(m.crew)}${_extBadge(m.external)}` +
      `${hasDetail ? '<span class="toolcaret">▸</span>' : ''}${_esca(m.text)}${cidChip}${codePre}${detail}</div>`;
  }
  if (m.role === 'toolrun') {
    // The crew once, at the top, then the calls as a list. Each line keeps its own expandable
    // args/result — the compaction is of the repeated chrome, not of the detail.
    const lines = m.items.map(x => {
      const cid = x.cid ? ` <span class="toolnav" data-cid="${_esca(x.cid)}">→ ${_esca(x.cid)}</span>` : '';
      const a = x.args != null ? _argsPretty(x.args) : '';
      const r = x.resultText || x.result || '';
      const detail = (a || r) ? `<div class="tooldetail">` +
        (a ? `<div class="tdlabel">args</div><pre class="toolargs">${_esca(a)}</pre>` : '') +
        (r ? `<div class="tdlabel">result</div><pre class="toolresult${x.resultErr ? ' err' : ''}">${_esca(r)}</pre>` : '') +
        `</div>` : '';
      return `<div class="toolline${(a || r) ? ' expandable' : ''}${x.resultErr ? ' err' : ''}">` +
             `${_extBadge(x.external)}${_esca(x.text)}${cid}${detail}</div>`;
    }).join('');
    return `<div class="apmsg toolrun${lane}" ${tag}>` +
      `<div class="toolrunh">${_crewLabel(m.crew)}<span class="toolrunn">${m.items.length} actions</span></div>` +
      `<div class="toolrunlist">${lines}</div></div>`;
  }
  if (m.role === 'finding') {
    const f = m.f;
    const v = f.verdict ? `<span class="apfindv ${_esca(f.verdict)}">${_esca(f.verdict)}</span>` : '';
    const gap = (f.unread_upstream || []).length
      ? `<div class="apfindgap">never looked at ${_esca(f.unread_upstream.join(', '))} — which produce its inputs</div>` : '';
    const why = f.verdict_why ? `<div class="apfindwhy">${_esca(f.verdict_why)}</div>` : '';
    const dec = f.decision ? `<span class="apfinddec">${f.decision === 'go' ? '✓ approved'
      : f.decision === 'no' ? '✕ declined' : '✎ ' + _esca(f.decision)}</span>` : '';
    const plan = f.plan ? `<div class="apfindplan">plan: ${_esca(f.plan)}${dec}</div>` : '';
    return `<div class="apmsg finding ${_esca(f.verdict || 'open')}">` +
      `<div class="apfindh"><span class="apfindc">${_esca(f.cell || '(no cell named)')}</span>${v}</div>` +
      `<div class="apfindclaim">${_esca(f.claim)}</div>` +
      (f.evidence ? `<div class="apfindev">${_esca(f.evidence)}</div>` : '') +
      gap + why + plan + `</div>`;
  }
  if (m.role === 'ask') {
    // Answered only. While it is open the card above the page owns it — the live controls being in
    // two places at once is how you end up answering the same question twice.
    if (m.answered == null) return `<div class="apmsg note">… waiting on your answer above</div>`;
    return `<div class="apmsg ask answered"><div class="apaskq">${_esca(m.text)}</div>` +
           `<div class="apaskdone">✓ ${_esca(m.answeredLabel || m.answered)}</div></div>`;
  }
  return (
      m.role === 'img'  ? `<div class="apmsg img${lane}" ${tag}>${_crewBadge(m.crew)}<img src="${_safeImgSrc(m.src)}" alt="agent image"></div>`
    : m.role === 'assistant' ? `<div class="apmsg assistant apmd${lane}" ${tag}>${_crewBadge(m.crew)}${mdLite(m.text)}</div>`
    :                     `<div class="apmsg ${m.role}${lane}${m.external ? ' ext' : ''}" ${tag}>${_crewBadge(m.crew)}${_extBadge(m.external)}${_esca(m.text)}</div>`);
}
// Consecutive tool calls by the same agent, as ONE block: the crew named once as a heading, then a
// line per call. They do not have to be the same tool — a debugging specialist's run is watch,
// breakpoint, step, frame, eval, and as separate rows that is six repetitions of its own name down
// the left of a 368px panel, with the sentences on either side pushed apart.
//
// A call carrying code keeps its own row: the code is the content, and folding it into a list would
// hide the thing worth reading.
const _RUN_MIN = 2;
function _collapseRuns(msgs) {
  const out = [];
  for (let i = 0; i < msgs.length; i++) {
    const m = msgs[i];
    if (m.role !== 'tool' || m.code) { out.push(m); continue; }
    let j = i;
    while (j + 1 < msgs.length && msgs[j + 1].role === 'tool' && !msgs[j + 1].code &&
           (msgs[j + 1].crew || '') === (m.crew || '')) j++;
    const n = j - i + 1;
    if (n < _RUN_MIN) { for (let k = i; k <= j; k++) out.push(msgs[k]); }
    else out.push({ role: 'toolrun', crew: m.crew, items: msgs.slice(i, j + 1),
                    done: msgs.slice(i, j + 1).every(x => x.done) });
    i = j;
  }
  return out;
}
const _nodeFromHtml = h => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content.firstChild; };
function renderAgentMsgs() {
  if (_suppressAgentRender) return;   // skip per-event re-renders during a replay (O(n²) markdown+KaTeX)
  const el = document.getElementById('apmsgs');
  // Stick to the bottom ONLY if you're already near it — so you can scroll up to read a streaming
  // reply without it yanking you back down. Scroll to the bottom and it resumes auto-following.
  const stick = (el.scrollHeight - el.scrollTop - el.clientHeight) < 80;
  // Reconcile per-message: only (re)build a message node whose content changed, so EARLIER messages
  // keep their live DOM — and the scroll position inside a tool-output/code block isn't reset to the
  // top every streaming delta. Completed-and-rendered messages are skipped entirely (cheap streaming).
  el.querySelectorAll(':scope > .apworking').forEach(n => n.remove());   // drop indicator → indices align
  // Reconcile against the COLLAPSED list, not agentMsgs: a run of repeated calls is one node, so
  // the index a node sits at is its position here rather than in the raw transcript.
  const view = _collapseRuns(agentMsgs);
  const changed = [];
  for (let i = 0; i < view.length; i++) {
    const m = view[i], node = el.children[i];
    if (node && m.done && node.dataset.done === '1') continue;          // immutable completed msg → leave it
    const html = _agentMsgHtml(m);
    if (!node) { const n = _nodeFromHtml(html); n.dataset.h = html; n.dataset.done = m.done ? '1' : '0'; el.appendChild(n); changed.push(n); }
    else if (node.dataset.h !== html) { const n = _nodeFromHtml(html); n.dataset.h = html; n.dataset.done = m.done ? '1' : '0'; el.replaceChild(n, node); changed.push(n); }
    else node.dataset.done = m.done ? '1' : '0';
  }
  while (el.children.length > view.length) el.removeChild(el.lastChild);   // drop trailing extras
  if (agentWorking) {
    const s = Math.max(0, Math.floor((Date.now() - agentT0) / 1000));
    const w = _nodeFromHtml(`<div class="apworking"><span class="dots"><i></i><i></i><i></i></span>working… ${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}` +
      `<button class="apstop" style="margin-left:10px;cursor:pointer" onclick="agentStop()">${_stopArmed ? '⛔ Force stop' : '⏹ Stop'}</button></div>`);
    el.appendChild(w);
  }
  // Typeset LaTeX only in the message nodes we just (re)built — completed ones keep their rendered math.
  if (window.typeset) changed.forEach(n => { if (n.classList && n.classList.contains('apmd')) { try { typeset(n); } catch (_) {} } });
  if (stick) el.scrollTop = el.scrollHeight;
}
// Click the "→ id" chip on an agent tool message → jump to the cell it added/edited/ran.
(() => { const el = document.getElementById('apmsgs'); if (!el) return;
  el.addEventListener('click', e => {
    const nav = e.target.closest('.toolnav');
    if (nav && nav.dataset.cid) { try { window.selectCell && window.selectCell(nav.dataset.cid, true); } catch (_) {} return; }
    const line = e.target.closest('.toolline.expandable');   // one call inside a grouped run
    if (line) { line.classList.toggle('expanded'); return; }
    const tool = e.target.closest('.apmsg.tool.expandable'); if (tool) tool.classList.toggle('expanded');   // reveal full args/result
  });
})();
// Replay the buffered conversation after a page reload (in-memory agentMsgs is
// gone, but the server kept every relayed envelope). Idempotent — clears first.
async function loadAgentLog() {
  // An app ships without the agent (export_app defaults `agent=false`) and its server refuses the
  // route outright, so there is no conversation to replay — only a 403 on every load.
  if (typeof SLATE_IS_APP !== 'undefined' && SLATE_IS_APP) return;
  try {
    const r = await api('GET', '/api/agent-log');
    if (!r || !r.events || !r.events.length) return;
    agentMsgs = []; setWorking(false);
    // Replay the whole log building agentMsgs, but render the DOM only ONCE at the end — otherwise
    // each of the hundreds of events triggers a full markdown+KaTeX re-render (was ~7.5s on a big log).
    _suppressAgentRender = true;
    try { for (const line of r.events) { try { agentEvent(JSON.parse(line)); } catch (_) {} } }
    finally { _suppressAgentRender = false; }
    // A STOPPED turn leaves the transcript ending at `turn_started` with no `result` — replay would
    // leave the "working…" indicator flashing forever. A stop reaps the crew, so if we replayed into a
    // working state but there are NO live agents, the turn is over → clear the stale indicator. (A turn
    // that's genuinely still running keeps its agents, so this doesn't touch a real in-flight reload.)
    if (agentWorking && !Object.keys(r.agents || {}).length) setWorking(false);
    renderAgentMsgs();
  } catch (_) {}
}
// A blocked question from the notebook's OWN agent (no specialist role), so it belongs in the
// chat rather than the debugger's pane: its turn is stopped mid-tool-call waiting for the answer,
// and the transcript is where its last sentence already is.
(window.slateSpecialistSubs ||= []).push(p => {
  if (!p) return;
  // A finding outlives the session that produced it — signing off CLOSES the session, which shuts
  // the debugging workspace, so the pane that shows findings is gone at the moment one appears.
  // The chat is where it lasts, and where the proposal about it arrives.
  if (p.finding) { _agentFinding(p.finding); return; }
  if (p.role) return;                       // everything below is the notebook agent's own
  if (p.ask) _agentAsk(p.ask);
  // The full list arrives when one is cleared. An ask that is gone but still has buttons here was
  // answered somewhere else, or timed out — either way it is no longer a question.
  if (p.asks !== undefined) {
    const live = new Set((p.asks || []).map(a => a.id));
    let dirty = false;
    for (const m of agentMsgs) {
      if (m.role === 'ask' && m.answered == null && !live.has(m.id)) { m.answered = 'withdrawn'; m.answeredLabel = 'no longer waiting'; dirty = true; }
    }
    if (dirty) { renderAgentMsgs(); renderAsks(); }
  }
});
// One finding, updated in place as a verdict and then a decision land on it. Keyed by id rather
// than appended, or the same conclusion stacks up three times — which is the thing the record
// exists to stop.
function _agentFinding(f) {
  const i = agentMsgs.findIndex(m => m.role === 'finding' && m.id === f.id);
  if (i < 0) agentMsgs.push({ role: 'finding', id: f.id, f });
  else agentMsgs[i] = { role: 'finding', id: f.id, f };
  renderAgentMsgs();
}
function _agentAsk(a) {
  if (!a || agentMsgs.some(m => m.role === 'ask' && m.id === a.id)) return;
  agentMsgs.push({ role: 'ask', id: a.id, text: a.text, options: a.options || [] });
  renderAgentMsgs(); renderAsks();
}

// A blocked question, as a card floating over the page rather than a block inside the transcript.
//
// It is NOT a modal in the usual sense: no backdrop, nothing dimmed, nothing blocked. A proposal
// arrives at the end of a long investigation and the first thing you want is to scroll back through
// what led to it — so the panel behind has to stay readable and scrollable while the question sits
// there waiting.
function _askCard() {
  let el = document.getElementById('apaskcard');
  if (!el) { el = document.createElement('div'); el.id = 'apaskcard'; document.body.appendChild(el); }
  return el;
}
function renderAsks() {
  const el = _askCard();
  const open = agentMsgs.filter(m => m.role === 'ask' && m.answered == null);
  if (!open.length) { el.innerHTML = ''; el.classList.remove('show'); return; }
  el.innerHTML = open.map(m => {
    const opts = (m.options || []).map(o =>
      `<button class="apaskb" onclick="agentAnswerAsk('${_esca(m.id)}','${_esca(o.value)}')">${_esca(o.label)}</button>`).join('');
    return `<div class="apaskcardbody" data-id="${_esca(m.id)}">
      <div class="apaskq">${mdLite(m.text)}</div>
      <textarea class="apasknote" rows="1" placeholder="add a comment (optional) — it goes with your answer"></textarea>
      <div class="apaskbtns">${opts}</div></div>`;
  }).join('');
  el.classList.add('show');
  const ta = el.querySelector('.apasknote'); if (ta) ta.focus();
}
async function agentAnswerAsk(id, value) {
  const m = agentMsgs.find(x => x.role === 'ask' && x.id === id);
  if (!m || m.answered != null) return;
  const box = _askCard().querySelector(`.apaskcardbody[data-id="${CSS.escape(id)}"] .apasknote`);
  const note = box ? box.value.trim() : '';
  const opt = (m.options || []).find(o => o.value === value);
  m.answered = value; m.answeredLabel = (opt ? opt.label : value) + (note ? ' — ' + note : '');
  renderAsks(); renderAgentMsgs();
  // The choice on the first line, the comment under it. "Yes, but not that part" is the answer a
  // person most often wants to give, and a pair of buttons alone cannot express it.
  try { await api('POST', '/api/debug/answer', { id, text: note ? value + '\n' + note : value }); }
  catch (e) { m.answered = null; renderAsks(); renderAgentMsgs(); }
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
// Is the current UI theme a dark one? (Sent on chat so the agent's plot-theme hint matches.)
function _uiThemeDark() {
  try {
    const n = (typeof curSlateTheme === 'function') ? curSlateTheme() : 'midnight';
    const t = (typeof SLATE_UI_THEMES !== 'undefined') && SLATE_UI_THEMES.find(x => x.name === n);
    return t ? !!t.dark : true;
  } catch (_) { return true; }
}
// Grow the box to fit what is in it, up to a cap.
//
// A textarea cannot do this from CSS: its height is a fixed number of rows, so a fixed height was
// a box you type past rather than into. Measuring needs the height reset to `auto` first —
// `scrollHeight` reports the CONTENT height only when the element is not already constraining it,
// so reading it without that returns whatever it was last set to and the box never shrinks again.
const AP_MAX_H = 320;
function apAutoGrow() {
  const el = document.getElementById('apin'); if (!el) return;
  el.style.height = 'auto';
  const want = Math.min(el.scrollHeight, AP_MAX_H);
  el.style.height = want + 'px';
  // Past the cap it scrolls; below it, a scrollbar over empty space is noise.
  el.style.overflowY = el.scrollHeight > AP_MAX_H ? 'auto' : 'hidden';
}

async function agentSend() {
  const inp = document.getElementById('apin'), text = inp.value.trim(); if (!text) return;
  inp.value = ''; apAutoGrow();     // back to one line, or a sent paragraph leaves a hole
  _stopArmed = false; agentMsgs.push({ role: 'user', text }); agentStatus('thinking…'); setWorking(true);
  try {
    const r = await api('POST', '/api/chat', { text, target: _chatTarget || '', model: effectiveAgentModel(), permission: effectiveAgentPerm(), dark: _uiThemeDark() });
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
// Cell id a cell-tool call targets, from its args — for the click-to-navigate chip.
function _argCid(args) {
  if (!args || typeof args !== 'object') return '';
  for (const k of ['cell', 'newid', 'id', 'after']) {
    const v = args[k];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return '';
}
function agentEvent(env) {
  if (!env) return;
  // The debugger's focus view keeps its OWN transcript of the specialist working, rendered for a
  // debugging session rather than for chat. It reads the same envelopes; the panel below is
  // unaffected either way, so a crew member appears in both places without either owning it.
  try { window.onDebugAgentEvent && window.onDebugAgentEvent(env); } catch (e) {}
  const d = env.data || {};
  const k = env.kind;
  const crew = env.crew || '';   // crew label of the speaking agent ('' = solo/default)
  if (k === 'assistant_text' || k === 'thought') {
    // Streaming: delta:true chunks APPEND live; the final delta:false copy REPLACES
    // the streamed block (self-healing any dropped delta). Non-streaming services
    // send only complete blocks → the else branch (back-compat).
    const role = k === 'thought' ? 'think' : 'assistant';
    const txt = (d.content && d.content.text) || '';
    // The open block for THIS crew, not whatever is last in the list. Two agents stream at once now
    // — a specialist working while a reviewer reads — and matching on role alone appended one
    // agent's sentence into the other's paragraph. Searching back rather than taking the tail also
    // keeps a block whole when the other agent's tool row lands in the middle of it.
    let last = null;
    for (let i = agentMsgs.length - 1; i >= 0; i--) {
      const m = agentMsgs[i];
      if (m.role === role && (m.crew || '') === crew && !m.done) { last = m; break; }
      // Only look past the other agent's rows. This crew's own completed block ends the search:
      // past it lies an earlier turn, and appending there would rewrite history.
      if ((m.crew || '') === crew) break;
    }
    if (d.delta === true) {
      if (!txt) return;
      if (!last) { last = { role, text: '', streamed: true, crew }; agentMsgs.push(last); }
      last.text += txt; last.streamed = true;
    } else if (last && last.streamed) {
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
    if (env.external) tm.external = true;   // a tool call from OUTSIDE this notebook's chat (an external agent)
    tm.title = _prettyTool(c.title || c.kind || tm.title || 'tool');
    tm.text = tm.title;
    if (c.rawInput) { tm.code = _extractCode(JSON.stringify(c.rawInput)) || tm.code; tm.args = c.rawInput; const cc = _argCid(c.rawInput); cc && (tm.cid = cc); }
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
    if (tm) { tm.done = true; if (env.external) tm.external = true; if (u.status === 'failed') tm.role = 'err'; }
    for (const b of (u.content || [])) {
      const inner = b && b.content;
      if (inner && inner.type === 'image' && inner.data)
        agentMsgs.push({ role: 'img', src: `data:${inner.mimeType || 'image/png'};base64,${inner.data}`, crew });
      else if (tm && inner && inner.type === 'text' && inner.text) {
        tm.resultText = (tm.resultText ? tm.resultText + '\n' : '') + String(inner.text);   // full result → expand
        // The cell tools return "added id=X" / "edited id=X" / "renamed a → b" — the authoritative
        // affected/created cell id; prefer it over the args guess for the navigate-to-cell chip.
        const m2 = String(inner.text).match(/\bid=(\w+)|renamed \w+ → (\w+)/);
        if (m2) tm.cid = m2[1] || m2[2];
      }
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
    // This crew's open block, not the tail: one agent finishing must not close another's, which
    // would strand the still-streaming one and make its next chunk start a second bubble.
    for (let i = agentMsgs.length - 1; i >= 0; i--) {
      const m = agentMsgs[i];
      if ((m.crew || '') !== crew) continue;
      if (m.role === 'assistant') m.done = true;
      break;
    }
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
document.getElementById('apin').addEventListener('input', apAutoGrow);
// Pasting fires `input`, but a programmatic set (a draft restored, a template inserted) does not —
// so size it once at load too, rather than leaving a prefilled box the wrong height.
apAutoGrow();
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

