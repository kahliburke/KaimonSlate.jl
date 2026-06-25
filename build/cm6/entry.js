// CodeMirror 6 bundle for KaimonSlate — built with esbuild into src/assets/js/cm6.bundle.js (IIFE,
// global `CM6`). Exposes the CM6 primitives the editor wrapper (cm6compat.js) needs, plus a Julia
// LanguageSupport whose highlighting comes from @plutojl/lezer-julia's parser + a styleTags map.
import { EditorView, keymap, drawSelection, highlightActiveLine, highlightSpecialChars,
         crosshairCursor, Decoration, ViewPlugin } from "@codemirror/view";
import { EditorState, EditorSelection, Compartment, StateField, StateEffect, RangeSetBuilder } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab, indentMore, indentLess,
         toggleComment } from "@codemirror/commands";
import { LRLanguage, LanguageSupport, syntaxHighlighting, HighlightStyle, indentNodeProp,
         foldNodeProp, foldInside, indentUnit, bracketMatching, indentOnInput, syntaxTree } from "@codemirror/language";
import { styleTags, tags as t } from "@lezer/highlight";
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap,
         completionStatus, snippet, startCompletion, acceptCompletion } from "@codemirror/autocomplete";
import { parser as juliaParser } from "@plutojl/lezer-julia";

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

// Syntax palettes. Each maps the same tag set to a colour scheme; `editor.js` selects one via a
// Compartment (Settings → Editor syntax). All are tuned for a dark editor background. `c.*` keys:
// kw keyword · com comment · num number/bool · str string/char · esc escape · sym :symbol ·
// mac @macro · op operator · fn function-call · prop field/property · vr variable.
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
]);
const juliaThemes = {
  // VS Code "Dark+" — the original palette, matching the static export highlighter.
  "dark-plus": _mkStyle({ kw: "#c586c0", com: "#6a9955", num: "#b5cea8", str: "#ce9178", esc: "#d7ba7d",
    sym: "#d19a66", mac: "#569cd6", op: "#56b6c2", fn: "#dcdcaa", prop: "#9cdcfe", vr: "#d4d8e8" }),
  "monokai": _mkStyle({ kw: "#f92672", com: "#88846f", num: "#ae81ff", str: "#e6db74", esc: "#ae81ff",
    sym: "#fd971f", mac: "#a6e22e", op: "#f92672", fn: "#a6e22e", prop: "#66d9ef", vr: "#f8f8f2" }),
  "dracula": _mkStyle({ kw: "#ff79c6", com: "#6272a4", num: "#bd93f9", str: "#f1fa8c", esc: "#ffb86c",
    sym: "#ffb86c", mac: "#50fa7b", op: "#ff79c6", fn: "#50fa7b", prop: "#8be9fd", vr: "#f8f8f2" }),
  "nord": _mkStyle({ kw: "#81a1c1", com: "#616e88", num: "#b48ead", str: "#a3be8c", esc: "#ebcb8b",
    sym: "#d08770", mac: "#88c0d0", op: "#81a1c1", fn: "#88c0d0", prop: "#8fbcbb", vr: "#d8dee9" }),
};
const juliaHighlightStyle = juliaThemes["dark-plus"];   // default / back-compat export

export {
  EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect, RangeSetBuilder,
  keymap, drawSelection, highlightActiveLine, highlightSpecialChars, crosshairCursor, Decoration, ViewPlugin,
  defaultKeymap, history, historyKeymap, indentWithTab, indentMore, indentLess, toggleComment,
  indentUnit, bracketMatching, indentOnInput, syntaxTree,
  syntaxHighlighting, julia, juliaLanguage, juliaHighlightStyle, juliaThemes,
  autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap, completionStatus, snippet,
  startCompletion, acceptCompletion,
};
