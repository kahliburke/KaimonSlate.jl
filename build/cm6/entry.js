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
         completionStatus, snippet, startCompletion } from "@codemirror/autocomplete";
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
        "FunctionDefinition StructDefinition WhileStatement ForStatement IfStatement LetStatement TryStatement BeginStatement QuoteStatement ModuleDefinition MacroDefinition":
          (cx) => cx.baseIndent + cx.unit,
      }),
      foldNodeProp.add({
        "FunctionDefinition StructDefinition ModuleDefinition LetStatement BeginStatement": foldInside,
      }),
    ],
  }),
  languageData: { commentTokens: { line: "#" } },
});
const julia = () => new LanguageSupport(juliaLanguage);

// One-Dark-ish palette matching the static export highlighter.
const juliaHighlightStyle = HighlightStyle.define([
  { tag: t.keyword, color: "#c586c0" },
  { tag: t.comment, color: "#6a9955", fontStyle: "italic" },
  { tag: [t.number, t.bool], color: "#b5cea8" },
  { tag: [t.string, t.special(t.string), t.character], color: "#ce9178" },
  { tag: t.escape, color: "#d7ba7d" },
  { tag: t.atom, color: "#d19a66" },                 // :symbols
  { tag: t.macroName, color: "#569cd6" },
  { tag: t.operator, color: "#56b6c2" },
  { tag: t.function(t.variableName), color: "#dcdcaa" },
  { tag: t.propertyName, color: "#9cdcfe" },
  { tag: t.variableName, color: "#d4d8e8" },
]);

export {
  EditorView, EditorState, EditorSelection, Compartment, StateField, StateEffect, RangeSetBuilder,
  keymap, drawSelection, highlightActiveLine, highlightSpecialChars, crosshairCursor, Decoration, ViewPlugin,
  defaultKeymap, history, historyKeymap, indentWithTab, indentMore, indentLess, toggleComment,
  indentUnit, bracketMatching, indentOnInput, syntaxTree,
  syntaxHighlighting, julia, juliaLanguage, juliaHighlightStyle,
  autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap, completionStatus, snippet, startCompletion,
};
