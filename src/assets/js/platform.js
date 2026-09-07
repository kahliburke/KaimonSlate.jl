// ── Host-OS conventions: keyboard glyphs & path separators ────────────────────
// Every keyboard hint in the UI is authored in macOS glyphs (⌘ ⌥ ⇧) — the design
// language of the developers' machines. On a Windows/Linux host those read wrong
// (there is no ⌘ key), so on a non-Mac browser we rewrite them to Ctrl/Alt/Shift.
// The key HANDLERS already accept `metaKey || ctrlKey`, so behaviour is identical
// across platforms — this only fixes what the user is TOLD to press. Loaded early
// (before the app modules) so `window.PLATFORM` / `window.kbd` are available to all.
(function () {
  const uaData = navigator.userAgentData;
  const plat = (uaData && uaData.platform) || navigator.platform || '';
  const ua = navigator.userAgent || '';
  const isMac = /mac/i.test(plat) || (/iP(hone|ad|od)/.test(ua) && !/Windows/.test(ua));
  const isWin = /win/i.test(plat) || /Windows/.test(ua);

  // ⌘ ⌥ ⇧ → platform names. ⇧ (U+21E7) is an ISO/IEC 9995-7 standard also used on
  // Windows/Linux keyboards, so we KEEP that glyph; only ⌘/⌥ (Mac-only) are spelled out.
  const NAME = { '⌘': 'Ctrl', '⌥': 'Alt', '⇧': '⇧' };
  const GLYPH = /[⌘⌥⇧]/;

  // Rewrite a run of modifier glyphs (+ its trailing key char, if any) into the host's
  // convention: Ctrl/Alt spelled out, `+`-joined. No-op on Mac (glyphs are native there).
  //   ⌘K → Ctrl+K   ⌘⇧P → Ctrl+⇧+P   ⇧⏎ → ⇧+⏎   (a lone "hold ⌘" → "hold Ctrl")
  function kbd(s) {
    if (isMac || !s) return s;
    // [^\s+]? (not [^\s]?): never swallow a `+` a prior pass already inserted —
    // re-running kbd() on already-converted text must be a true no-op.
    return s.replace(/[⌘⌥⇧]+[^\s+]?/g, chord => {
      const parts = []; let key = '';
      for (const c of chord) { if (NAME[c]) parts.push(NAME[c]); else key += c; }
      if (key) parts.push(key);
      return parts.join('+');
    });
  }

  // Skip user content — a markdown cell or code editor may legitimately contain a
  // ⌘ glyph, and rewriting inside CodeMirror would corrupt its DOM. Chrome only.
  const SKIP = ['md', 'output', 'out', 'cm-editor'];
  function inUserContent(node) {
    for (let el = node.parentNode; el && el !== document.body; el = el.parentNode)
      if (el.classList && SKIP.some(c => el.classList.contains(c))) return true;
    return false;
  }

  // Rewrite glyphs across `root` (default: the whole document). Idempotent — once a
  // glyph is gone nothing matches, so it's safe to re-run after every render.
  function applyGlyphs(root) {
    if (isMac) return;
    root = root || document.body; if (!root) return;
    const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const hits = [];
    for (let n = walk.nextNode(); n; n = walk.nextNode())
      if (GLYPH.test(n.nodeValue) && !inUserContent(n)) hits.push(n);
    // Only touch nodeValue when the conversion actually changes something — ⇧ is
    // deliberately kept as-is (see NAME above), so a converted node still matches
    // GLYPH and gets revisited on every rescan. An unconditional reassignment here
    // is itself a text mutation, which re-fires the MutationObserver below,
    // scheduling another rescan of the same node forever — and each pass's regex
    // can re-swallow the very "+" it just inserted, corrupting the string further
    // (the "Ctrl+⇧+++…" runaway). Skipping no-op writes breaks that feedback loop.
    hits.forEach(n => {
      const next = kbd(n.nodeValue);
      if (next !== n.nodeValue) n.nodeValue = next;
    });
    // title / placeholder are always UI chrome, so rewrite them everywhere.
    root.querySelectorAll('[title],[placeholder]').forEach(el => {
      for (const a of ['title', 'placeholder']) {
        const v = el.getAttribute(a);
        if (v && GLYPH.test(v)) {
          const next = kbd(v);
          if (next !== v) el.setAttribute(a, next);
        }
      }
    });
  }

  // ── Path conventions ────────────────────────────────────────────────────────
  // The open box accepts and displays paths with the host separator. Helpers below
  // are separator-agnostic (recognise both / and \) so a pasted Windows path works.
  const sep = isWin ? '\\' : '/';
  const isDirPath = p => /[\/\\]$/.test(p || '');            // ends at a directory boundary
  const dirOf = p => (p || '').replace(/[^\/\\]*$/, '');     // dirname, keeping trailing sep
  const baseOf = p => (p || '').replace(/^.*[\/\\]/, '');    // final path segment

  window.PLATFORM = { isMac, isWin, sep, kbd, applyGlyphs, isDirPath, dirOf, baseOf };
  window.kbd = kbd;

  // Rewrite static HTML on load, then keep dynamic chrome (cells, palette, dialogs)
  // in sync via a debounced observer. Nothing to do on Mac.
  if (!isMac) {
    let pending = false;
    const rescan = () => { pending = false; applyGlyphs(document.body); };
    const obs = new MutationObserver(() => {
      if (pending) return; pending = true; requestAnimationFrame(rescan);
    });
    const boot = () => {
      applyGlyphs();
      if (document.body) obs.observe(document.body, { childList: true, subtree: true, characterData: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
    else boot();
  }
})();

// ── Byte sizes ────────────────────────────────────────────────────────────────
// One human byte formatter for the whole UI. It was written TEN times across these files, each with
// its own cutoffs: two of them collided on the global name `_fmtBytes` (whichever script loaded last
// won, so a panel rendered through a formatter its author never wrote), one floored at 1 KB so a
// small value read as bigger than it was, and one spelled the unit `kB`.
//
// The value picks both the unit and the precision, which is what every copy was approximating: the
// unit is the largest that leaves a mantissa below 1024, and a mantissa under 10 keeps one decimal
// (4.2 KB says something 4 KB does not) while a larger one does not (317 KB, not 317.4 KB). Whole
// bytes are never fractional.
//
//   slateBytes(4300)                    → '4.2 KB'
//   slateBytes(4300, {compact: true})   → '4.2KB'      dense rows, no space
//   slateBytes(4300, {letter: true})    → '4.2K'       the monitor's narrowest columns
//
// Lives HERE, not in core.js, because the front page loads only platform.js + its islands; a helper
// in core.js is reachable from the notebook shell alone. (core.js keeps its own `_bytes`: that is the
// `:bytes` TABLE COLUMN format, which takes its digit count from the author's column spec and is
// mirrored in Julia `format.jl` under a golden-fixture parity test. Different contract, not a copy.)
const _SLATE_BYTE_UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
window.slateBytes = function slateBytes(n, opts) {
  const o = opts || {};
  let v = +n;
  if (!isFinite(v)) v = 0;
  const sign = v < 0 ? '-' : '';
  v = Math.abs(v);
  let i = 0;
  while (v >= 1024 && i < _SLATE_BYTE_UNITS.length - 1) { v /= 1024; i++; }
  const num = i === 0 ? String(Math.round(v)) : v.toFixed(v < 10 ? 1 : 0);
  const unit = o.letter ? (i === 0 ? 'B' : _SLATE_BYTE_UNITS[i][0]) : _SLATE_BYTE_UNITS[i];
  return sign + num + ((o.compact || o.letter) ? '' : ' ') + unit;
};
