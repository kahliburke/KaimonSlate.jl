// CodeMirror 6 bundle for KaimonSlate — built with esbuild into src/assets/js/cm6.bundle.js (IIFE,
// global `CM6`). Exposes the CM6 primitives the editor wrapper (cm6compat.js) needs, plus a Julia
// LanguageSupport whose highlighting comes from @plutojl/lezer-julia's parser + a styleTags map.
import { EditorView, keymap, drawSelection, highlightActiveLine, highlightSpecialChars,
         crosshairCursor, Decoration, ViewPlugin, WidgetType } from "@codemirror/view";
import { EditorState, EditorSelection, Compartment, StateField, StateEffect, RangeSetBuilder, Transaction } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab, indentMore, indentLess,
         toggleComment, undoDepth, redoDepth } from "@codemirror/commands";
import { LRLanguage, LanguageSupport, syntaxHighlighting, HighlightStyle, indentNodeProp,
         foldNodeProp, foldInside, indentUnit, bracketMatching, indentOnInput, syntaxTree } from "@codemirror/language";
import { styleTags, tags as t } from "@lezer/highlight";
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap,
         completionStatus, snippet, startCompletion, acceptCompletion } from "@codemirror/autocomplete";
import { parser as juliaParser } from "@plutojl/lezer-julia";
// Web-cell section languages — an `html"…"`/`css"…"`/`js"…"` pane gets its native CM6 grammar.
// lang-html embeds lang-css + lang-javascript for `<style>`/`<script>` regions, so all three ride in.
import { html as htmlLang, htmlLanguage } from "@codemirror/lang-html";
import { css as cssLang, cssLanguage } from "@codemirror/lang-css";
import { javascript as jsLang, javascriptLanguage, scopeCompletionSource, localCompletionSource } from "@codemirror/lang-javascript";
import { parseMixed } from "@lezer/common";

// ── Embedded HTML/CSS in tagged template literals (htm / lit) ──────────────────────────────────
// A Preact/htm component writes its markup as `html`…`` inside the JS pane. Wrap the JS parser with
// parseMixed so a TemplateString tagged `html`/`css` is parsed by the HTML/CSS grammar — highlighting
// tags, attributes and properties — while `${…}` interpolations are carved back out and stay JS. The
// tag is the TaggedTemplateExpression's first child (`html`/`css`); anything else is left as a plain
// string. Falls back cleanly (returns null) when the shape isn't a recognized tagged template.
const _embeddedParser = (node, input) => {
  if (node.name !== "TemplateString") return null;
  const parent = node.node.parent;
  if (!parent || parent.name !== "TaggedTemplateExpression") return null;
  const tagNode = parent.firstChild;
  const tag = tagNode ? input.read(tagNode.from, tagNode.to) : "";
  const parser = tag === "html" ? htmlLanguage.parser : tag === "css" ? cssLanguage.parser : null;
  if (!parser) return null;
  // Overlay the embedded grammar only on the literal-text spans, leaving `${…}` holes to JS.
  const ranges = [];
  let from = node.from + 1;                       // skip the opening backtick
  const cur = node.node.cursor();
  if (cur.firstChild()) {
    do {
      if (cur.name === "Interpolation") {          // ${ … } — a hole the JS parser keeps
        if (cur.from > from) ranges.push({ from, to: cur.from });
        from = cur.to;
      }
    } while (cur.nextSibling());
  }
  const end = node.to - 1;                         // skip the closing backtick
  if (end > from) ranges.push({ from, to: end });
  return ranges.length ? { parser, overlay: ranges } : null;
};
const jsEmbedLanguage = javascriptLanguage.configure({ wrap: parseMixed(_embeddedParser) });
// A JS pane's LanguageSupport: the mixed parser + the html/css SUPPORT extensions (so the embedded
// regions get their completion/indent data too), reusing the base js support's own extensions.
const jsEmbed = () => new LanguageSupport(jsEmbedLanguage, [jsLang().support, htmlLang().support, cssLang().support]);

// Whole-module namespaces — the EDITOR-EXTENSION surface (window.CM6.cmView.MatchDecorator, …). A
// registered editor extension (slateRegisterEditorExtension) must build against the HOST's single CM6
// instance — @codemirror/state is a per-page singleton, so a plugin can't bundle its own. Exporting
// the full namespaces (not a curated subset) means a plugin can reach ANY primitive without forcing an
// entry.js edit + bundle rebuild. Alongside the flat exports the wrapper (editor.js) already uses.
import * as cmView from "@codemirror/view";
import * as cmState from "@codemirror/state";
import * as cmCommands from "@codemirror/commands";
import * as cmLanguage from "@codemirror/language";
import * as cmAutocomplete from "@codemirror/autocomplete";
import * as cmSearch from "@codemirror/search";
import * as cmHighlight from "@lezer/highlight";

// Map @plutojl/lezer-julia node names → highlight tags. Keyword nodes are the bare literals the
// grammar emits (for/while/end/function/…); operators are the *Op nodes; CallExpression/Identifier
// selects a call's callee so function names colour distinctly. Variables stay default.
const juliaTags = styleTags({
  "for while if elseif else end function struct mutable abstract primitive type module baremodule begin quote let try catch finally return break continue const global local export import using public do where in isa as outer macro": t.keyword,
  BoolLiteral: t.bool,
  "IntegerLiteral FloatLiteral": t.number,
  "StringLiteral NsStringLiteral": t.string,
  "CommandLiteral NsCommandLiteral": t.special(t.string),
  CharLiteral: t.character,
  "LineComment BlockComment": t.comment,
  EscapeSequence: t.escape,
  Symbol: t.atom,                                   // :symbol
  MacroIdentifier: t.macroName,                     // @macro
  Field: t.propertyName,
  "Operator TildeOp TypeComparisonOp UnaryOp UnaryPlusOp PowerOp BitshiftOp RationalOp TimesOp PlusOp EllipsisOp PipeRightOp PipeLeftOp ComparisonOp ArrowOp PairOp SubTypeOp LazyAndOp LazyOrOp AssignmentOp UpdateOp Colon": t.operator,
  "CallExpression/Identifier": t.function(t.variableName),
  "MacrocallExpression/MacroIdentifier": t.macroName,
  Identifier: t.variableName,
  "( )": t.paren, "[ ]": t.squareBracket, "{ }": t.brace,
});

const juliaLanguage = LRLanguage.define({
  name: "julia",
  parser: juliaParser.configure({
    props: [
      juliaTags,
      indentNodeProp.add({
        // Block bodies indent one unit; a line that *closes* the block (end/else/elseif/catch/
        // finally) dedents back to the block's own column. `cx.textAfter` is the text on the line
        // being indented — when it's a closing keyword, add 0 instead of a unit.
        "FunctionDefinition StructDefinition WhileStatement ForStatement IfStatement LetStatement TryStatement BeginStatement QuoteStatement ModuleDefinition MacroDefinition":
          (cx) => cx.baseIndent + (/^\s*(end|else|elseif|catch|finally)\b/.test(cx.textAfter) ? 0 : cx.unit),
      }),
      foldNodeProp.add({
        "FunctionDefinition StructDefinition ModuleDefinition LetStatement BeginStatement": foldInside,
      }),
    ],
  }),
  // `indentOnInput` re-indents the current line the moment one of these closing keywords is
  // completed, so typing `end` snaps it back to the block column (paired with the rule above).
  languageData: { commentTokens: { line: "#" }, indentOnInput: /^\s*(end|else|elseif|catch|finally)$/ },
});
const julia = () => new LanguageSupport(juliaLanguage);

// ── Code-highlight themes — the single source of truth for in-browser editor theming. ──────────
// Each entry is a COMPLETE theme: token colours (`tok`) AND editor chrome (`ui`). `editor.js`
// selects one via two Compartments (tokens + chrome) so a switch hot-swaps the whole look across
// every live editor, and `settings.js` builds the dropdown from `slateThemeMeta` (no hardcoded
// list). `tok.*`: kw keyword · com comment · num number/bool · str string/char · esc escape ·
// sym :symbol · mac @macro · op operator · fn function-call · prop field/property · vr variable.
// `ui.*`: bg editor background · fg base text · gutter gutter fg · sel selection · active active
// line tint · cursor caret · match matching-bracket.
const _mkStyle = (c) => HighlightStyle.define([
  { tag: t.keyword, color: c.kw },
  { tag: t.comment, color: c.com, fontStyle: "italic" },
  { tag: [t.number, t.bool], color: c.num },
  { tag: [t.string, t.special(t.string), t.character], color: c.str },
  { tag: t.escape, color: c.esc },
  { tag: t.atom, color: c.sym },
  { tag: t.macroName, color: c.mac },
  { tag: t.operator, color: c.op },
  { tag: t.function(t.variableName), color: c.fn },
  { tag: t.propertyName, color: c.prop },
  { tag: t.variableName, color: c.vr },
  // HTML / CSS tokens (web-cell panes + embedded html`…`/css`…` template literals). Reuses the
  // palette so the colours read as one system: tags/at-rules as macros, attributes/props as fields,
  // attribute + selector values as strings, brackets/operators as operators, units/colours as numbers.
  { tag: [t.tagName, t.standard(t.tagName)], color: c.mac },
  { tag: t.angleBracket, color: c.op },
  { tag: [t.attributeName, t.definitionKeyword], color: c.prop },
  { tag: [t.attributeValue, t.special(t.string)], color: c.str },
  { tag: t.className, color: c.fn },
  { tag: [t.unit, t.color], color: c.num },
]);
// Editor chrome from a `ui` palette. The cell container keeps its own background; the editor
// paints `ui.bg` so each theme reads as a coherent code panel. Selection selectors cover both
// CM6's drawn selection layer and the native ::selection fallback.
const _mkChrome = (u, dark) => EditorView.theme({
  "&": { backgroundColor: u.bg, color: u.fg },
  ".cm-content": { caretColor: u.cursor },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: u.cursor },
  "&.cm-focused .cm-cursor": { borderLeftColor: u.cursor },
  ".cm-gutters": { backgroundColor: u.bg, color: u.gutter, border: "none" },
  ".cm-activeLine": { backgroundColor: u.active },
  ".cm-activeLineGutter": { backgroundColor: u.active, color: u.fg },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
    { backgroundColor: u.sel },
  ".cm-matchingBracket, &.cm-focused .cm-matchingBracket":
    { backgroundColor: u.match, color: "inherit", outline: "1px solid " + u.gutter },
}, { dark });
// name → { label (Settings display), dark, tok, ui }. Order here is the dropdown order.
const _THEMES = {
  // VS Code "Dark+" — the original palette, matching the static export highlighter.
  "dark-plus": { label: "Dark+ (default)", dark: true,
    tok: { kw: "#c586c0", com: "#6a9955", num: "#b5cea8", str: "#ce9178", esc: "#d7ba7d",
      sym: "#d19a66", mac: "#569cd6", op: "#56b6c2", fn: "#dcdcaa", prop: "#9cdcfe", vr: "#d4d8e8" },
    ui: { bg: "#1e1e1e", fg: "#d4d8e8", gutter: "#858585", sel: "#264f78",
      active: "rgba(255,255,255,.04)", cursor: "#aeafad", match: "rgba(86,156,214,.30)" } },
  "monokai": { label: "Monokai", dark: true,
    tok: { kw: "#f92672", com: "#88846f", num: "#ae81ff", str: "#e6db74", esc: "#ae81ff",
      sym: "#fd971f", mac: "#a6e22e", op: "#f92672", fn: "#a6e22e", prop: "#66d9ef", vr: "#f8f8f2" },
    ui: { bg: "#272822", fg: "#f8f8f2", gutter: "#90908a", sel: "#49483e",
      active: "rgba(255,255,255,.04)", cursor: "#f8f8f0", match: "rgba(166,226,46,.25)" } },
  "dracula": { label: "Dracula", dark: true,
    tok: { kw: "#ff79c6", com: "#6272a4", num: "#bd93f9", str: "#f1fa8c", esc: "#ffb86c",
      sym: "#ffb86c", mac: "#50fa7b", op: "#ff79c6", fn: "#50fa7b", prop: "#8be9fd", vr: "#f8f8f2" },
    ui: { bg: "#282a36", fg: "#f8f8f2", gutter: "#6272a4", sel: "#44475a",
      active: "rgba(255,255,255,.04)", cursor: "#f8f8f2", match: "rgba(80,250,123,.25)" } },
  "nord": { label: "Nord", dark: true,
    tok: { kw: "#81a1c1", com: "#616e88", num: "#b48ead", str: "#a3be8c", esc: "#ebcb8b",
      sym: "#d08770", mac: "#88c0d0", op: "#81a1c1", fn: "#88c0d0", prop: "#8fbcbb", vr: "#d8dee9" },
    ui: { bg: "#2e3440", fg: "#d8dee9", gutter: "#4c566a", sel: "#434c5e",
      active: "rgba(255,255,255,.035)", cursor: "#d8dee9", match: "rgba(136,192,208,.25)" } },
  "tokyo-night": { label: "Tokyo Night", dark: true,
    tok: { kw: "#bb9af7", com: "#565f89", num: "#ff9e64", str: "#9ece6a", esc: "#e0af68",
      sym: "#ff9e64", mac: "#7aa2f7", op: "#89ddff", fn: "#7aa2f7", prop: "#73daca", vr: "#a9b1d6" },
    ui: { bg: "#1a1b26", fg: "#a9b1d6", gutter: "#3b4261", sel: "#28344a",
      active: "rgba(255,255,255,.04)", cursor: "#c0caf5", match: "rgba(122,162,247,.25)" } },
  "github-dark": { label: "GitHub Dark", dark: true,
    tok: { kw: "#ff7b72", com: "#8b949e", num: "#79c0ff", str: "#a5d6ff", esc: "#79c0ff",
      sym: "#ffa657", mac: "#d2a8ff", op: "#ff7b72", fn: "#d2a8ff", prop: "#7ee787", vr: "#c9d1d9" },
    ui: { bg: "#0d1117", fg: "#c9d1d9", gutter: "#484f58", sel: "#173a5e",
      active: "rgba(255,255,255,.03)", cursor: "#c9d1d9", match: "rgba(56,139,253,.25)" } },
  "gruvbox-dark": { label: "Gruvbox Dark", dark: true,
    tok: { kw: "#fb4934", com: "#928374", num: "#d3869b", str: "#b8bb26", esc: "#fe8019",
      sym: "#d3869b", mac: "#8ec07c", op: "#fe8019", fn: "#b8bb26", prop: "#83a598", vr: "#ebdbb2" },
    ui: { bg: "#282828", fg: "#ebdbb2", gutter: "#7c6f64", sel: "#504945",
      active: "rgba(255,255,255,.04)", cursor: "#ebdbb2", match: "rgba(250,189,47,.22)" } },
  "solarized-dark": { label: "Solarized Dark", dark: true,
    tok: { kw: "#859900", com: "#657b83", num: "#d33682", str: "#2aa198", esc: "#cb4b16",
      sym: "#cb4b16", mac: "#268bd2", op: "#268bd2", fn: "#268bd2", prop: "#b58900", vr: "#93a1a1" },
    ui: { bg: "#002b36", fg: "#93a1a1", gutter: "#586e75", sel: "#073642",
      active: "rgba(255,255,255,.03)", cursor: "#93a1a1", match: "rgba(38,139,210,.25)" } },
  // ── Light themes — the set spans light + dark. ──
  "one-light": { label: "One Light", dark: false,
    tok: { kw: "#a626a4", com: "#a0a1a7", num: "#986801", str: "#50a14f", esc: "#c18401",
      sym: "#986801", mac: "#4078f2", op: "#0184bc", fn: "#4078f2", prop: "#e45649", vr: "#383a42" },
    ui: { bg: "#fafafa", fg: "#383a42", gutter: "#9d9d9f", sel: "#d7e4f3",
      active: "rgba(0,0,0,.04)", cursor: "#526fff", match: "rgba(64,120,242,.20)" } },
  "solarized-light": { label: "Solarized Light", dark: false,
    tok: { kw: "#859900", com: "#93a1a1", num: "#d33682", str: "#2aa198", esc: "#cb4b16",
      sym: "#cb4b16", mac: "#268bd2", op: "#268bd2", fn: "#268bd2", prop: "#b58900", vr: "#586e75" },
    ui: { bg: "#fdf6e3", fg: "#586e75", gutter: "#93a1a1", sel: "#eee8d5",
      active: "rgba(0,0,0,.03)", cursor: "#586e75", match: "rgba(38,139,210,.20)" } },
};
// Compiled registry: name → { label, dark, style (HighlightStyle), chrome (EditorView.theme) }.
const slateThemes = Object.fromEntries(Object.entries(_THEMES).map(([k, v]) =>
  [k, { label: v.label, dark: v.dark, style: _mkStyle(v.tok), chrome: _mkChrome(v.ui, v.dark) }]));
// Settings dropdown metadata (name + label, in declared order) — kept tiny so settings.js needn't
// reach into the CM objects.
const slateThemeMeta = Object.entries(_THEMES).map(([k, v]) => ({ name: k, label: v.label }));
// Back-compat: name → HighlightStyle (token-only) and the default style.
const juliaThemes = Object.fromEntries(Object.entries(slateThemes).map(([k, v]) => [k, v.style]));
const juliaHighlightStyle = juliaThemes["dark-plus"];   // default / back-compat export

export {
  EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect, RangeSetBuilder, Transaction,
  keymap, drawSelection, highlightActiveLine, highlightSpecialChars, crosshairCursor, Decoration, ViewPlugin, WidgetType,
  defaultKeymap, history, historyKeymap, indentWithTab, indentMore, indentLess, toggleComment,
  undoDepth, redoDepth,
  indentUnit, bracketMatching, indentOnInput, syntaxTree,
  syntaxHighlighting, julia, juliaLanguage, juliaHighlightStyle, juliaThemes, slateThemes, slateThemeMeta,
  htmlLang, cssLang, jsLang, jsEmbed,   // web-cell section grammars (JS pane = jsEmbed: html`…`/css`…` highlighted)
  scopeCompletionSource, localCompletionSource,   // JS-pane completion: real globals + in-scope locals
  autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap, completionStatus, snippet,
  startCompletion, acceptCompletion,
  // Full module namespaces for editor extensions (see the import note above).
  cmView, cmState, cmCommands, cmLanguage, cmAutocomplete, cmSearch, cmHighlight,
};
