// HTML-escape a value for interpolation into markup. The ONE escaper: it had been written thirteen
// times across these files in three different coverages (`&<>`, `&<>"`, `&<>"'`), and the narrow ones
// were reached by call sites that interpolate into ATTRIBUTE positions, where an unescaped quote ends
// the attribute. Covers all five so one helper is correct in both text and attribute context, and
// treats null/undefined as empty rather than printing "null". On `window` so the ES-module islands
// can reach it too — a classic script's lexical `const` is invisible to them.
//
// Its own file because it is the one thing every page needs and the only thing some of them need.
// The operator status page renders a worker log and nothing else of the notebook, so loading core.js
// to reach this would bring 1,600 lines that read the notebook id out of a URL the page does not
// have. A copy carried in ansi.js would be the drift this file exists to prevent.
window.slateEscHtml = s => String(s == null ? '' : s).replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
