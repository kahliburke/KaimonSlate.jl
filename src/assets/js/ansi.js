// ANSI colour → spans, for the surfaces the BROWSER renders itself: the hydrating banner's build
// log (prepare.js), the worker log popup (workers.js), and a running cell's streaming output.
// Cell output that arrives as finished HTML is coloured server-side instead — render.jl's
// `_ansi_html`, which this mirrors. Class names and the xterm-256 mapping are identical on both
// sides, so one palette in notebook.css styles everything.
//
// SGR (`\e[…m`) is the ONLY escape family handled here, deliberately. Cursor movement and erasure
// are replayed in Julia (termcook.jl) before text reaches the page, so there is one cooker rather
// than two — a JS reimplementation of the screen model is exactly the kind of thing that drifts.
// Anything else that slips through is dropped rather than shown, so a log written by a process we
// don't control can't spray escape codes into the panel.
(function () {
  // esc.js, which every page carrying this file loads first. A page that skipped it used to fail
  // silently: the converter still defined itself and threw on first use, inside the caller's try,
  // leaving the page on its placeholder forever.
  const esc = window.slateEscHtml;

  const hex2 = v => v.toString(16).padStart(2, '0');
  const rgbHex = (r, g, b) => '#' + hex2(r) + hex2(g) + hex2(b);
  // xterm-256: 16–231 is a 6×6×6 colour cube, 232–255 a grey ramp. 0–15 are themed by class.
  const CUBE = [0, 95, 135, 175, 215, 255];
  function xtermHex(n) {
    if (n >= 232) { const v = 8 + (n - 232) * 10; return rgbHex(v, v, v); }
    const i = n - 16;
    return rgbHex(CUBE[(i / 36) | 0], CUBE[((i % 36) / 6) | 0], CUBE[i % 6]);
  }

  const BOLD = 1, DIM = 2, ITALIC = 4, UNDERLINE = 8, REVERSE = 16, STRIKE = 32;
  const PLAIN = { fg: -1, bg: -1, flags: 0 };

  // One SGR parameter string applied to an attribute state. Unknown parameters are ignored rather
  // than treated as a reset, matching `_tc_sgr` in termcook.jl.
  function applySgr(a, par) {
    const f = par === '' ? [''] : par.split(';');
    let fg = a.fg, bg = a.bg, flags = a.flags;
    for (let i = 0; i < f.length; i++) {
      const n = f[i] === '' ? 0 : parseInt(f[i], 10);
      if (isNaN(n)) continue;
      if (n === 0) { fg = -1; bg = -1; flags = 0; }
      else if (n === 1) flags |= BOLD;
      else if (n === 2) flags |= DIM;
      else if (n === 3) flags |= ITALIC;
      else if (n === 4) flags |= UNDERLINE;
      else if (n === 7) flags |= REVERSE;
      else if (n === 9) flags |= STRIKE;
      else if (n === 22) flags &= ~(BOLD | DIM);
      else if (n === 23) flags &= ~ITALIC;
      else if (n === 24) flags &= ~UNDERLINE;
      else if (n === 27) flags &= ~REVERSE;
      else if (n === 29) flags &= ~STRIKE;
      else if (n >= 30 && n <= 37) fg = n - 30;
      else if (n >= 90 && n <= 97) fg = n - 90 + 8;
      else if (n >= 40 && n <= 47) bg = n - 40;
      else if (n >= 100 && n <= 107) bg = n - 100 + 8;
      else if (n === 39) fg = -1;
      else if (n === 49) bg = -1;
      else if (n === 38 || n === 48) {
        const mode = parseInt(f[i + 1], 10);
        if (mode === 5 && i + 2 < f.length) {
          const idx = parseInt(f[i + 2], 10);
          if (idx >= 0 && idx <= 255) { if (n === 38) fg = idx; else bg = idx; }
          i += 2;
        } else if (mode === 2 && i + 4 < f.length) {
          const r = Math.min(255, Math.max(0, parseInt(f[i + 2], 10) || 0));
          const g = Math.min(255, Math.max(0, parseInt(f[i + 3], 10) || 0));
          const b = Math.min(255, Math.max(0, parseInt(f[i + 4], 10) || 0));
          const packed = 256 + (r << 16) + (g << 8) + b;
          if (n === 38) fg = packed; else bg = packed;
          i += 4;
        }
      }
    }
    return { fg: fg, bg: bg, flags: flags };
  }

  // A colour field → [class, css]. Exactly one is non-empty; -1 yields neither.
  function colorOf(v, which) {
    if (v < 0) return ['', ''];
    if (v < 16) return ['ansi-' + which + '-' + v, ''];
    if (v < 256) return ['', xtermHex(v)];
    const rgb = v - 256;
    return ['', '#' + (rgb >>> 0).toString(16).padStart(6, '0')];
  }

  function attrsOf(a) {
    const classes = [], styles = [];
    if (a.flags & BOLD) classes.push('ansi-bold');
    if (a.flags & DIM) classes.push('ansi-dim');
    if (a.flags & ITALIC) classes.push('ansi-italic');
    if (a.flags & UNDERLINE) classes.push('ansi-underline');
    if (a.flags & REVERSE) classes.push('ansi-reverse');
    if (a.flags & STRIKE) classes.push('ansi-strike');
    const fg = colorOf(a.fg, 'fg'), bg = colorOf(a.bg, 'bg');
    if (fg[0]) classes.push(fg[0]); else if (fg[1]) styles.push('color:' + fg[1]);
    if (bg[0]) classes.push(bg[0]); else if (bg[1]) styles.push('background-color:' + bg[1]);
    return [classes.join(' '), styles.join(';')];
  }

  function runHtml(text, a) {
    if (!text) return '';
    const at = attrsOf(a), cls = at[0], style = at[1];
    if (!cls && !style) return esc(text);
    return '<span' + (cls ? ' class="' + cls + '"' : '') +
           (style ? ' style="' + style + '"' : '') + '>' + esc(text) + '</span>';
  }

  // Every escape sequence: OSC/DCS-style string payloads, CSI, and two-byte escapes.
  const ANY_ESC = /\x1b[\]P^_X][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b\[[0-9;:?<>=!]*[\x40-\x7e]|\x1b[\x40-\x5f]/g;
  const isSgr = m => m.charAt(1) === '[' && m.charAt(m.length - 1) === 'm';
  // Drop everything that is NOT SGR — a safety net for text that reached the page without going
  // through the Julia cooker (a log file written by another process, say). Decided per match rather
  // than by a character class: CSI final bytes are the whole range \x40-\x7e minus `m`, which is
  // fiddly enough to write as a class that an earlier attempt here silently also excluded `B`.
  const stripNonSgr = s => s.replace(ANY_ESC, m => (isSgr(m) ? m : ''));

  // Text (SGR-only, already cooked) → escaped HTML with a span per colour run.
  window.slateAnsiHtml = function (text) {
    let s = String(text == null ? '' : text);
    if (s.indexOf('\x1b') < 0) return esc(s);
    s = stripNonSgr(s);
    let out = '', attr = PLAIN, pos = 0, m;
    const re = /\x1b\[([0-9;:]*)m/g;
    while ((m = re.exec(s)) !== null) {
      if (m.index > pos) out += runHtml(s.slice(pos, m.index), attr);
      attr = applySgr(attr, m[1]);
      pos = m.index + m[0].length;
    }
    if (pos < s.length) out += runHtml(s.slice(pos), attr);
    return out;
  };

  // Plain-text twin: what the text reads as with all styling removed. For a summary line, a
  // tooltip, or anywhere the markup would be noise.
  window.slateAnsiText = function (text) {
    return String(text == null ? '' : text).replace(ANY_ESC, '');
  };
})();
