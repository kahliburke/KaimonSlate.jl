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
    return s.replace(/[⌘⌥⇧]+[^\s]?/g, chord => {
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
    hits.forEach(n => { n.nodeValue = kbd(n.nodeValue); });
    // title / placeholder are always UI chrome, so rewrite them everywhere.
    root.querySelectorAll('[title],[placeholder]').forEach(el => {
      for (const a of ['title', 'placeholder']) {
        const v = el.getAttribute(a);
        if (v && GLYPH.test(v)) el.setAttribute(a, kbd(v));
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
