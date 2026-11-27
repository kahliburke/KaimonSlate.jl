// Yjs and its CodeMirror binding for writing a notebook together (see src/assets/js/collab.js), built
// with esbuild into src/assets/js/collab.bundle.js (IIFE, global `SlateY`). Loaded only when a notebook
// joins a room. @codemirror/state and /view resolve to cm6.bundle.js's (window.CM6, see the
// package's aliases), so the binding works on the editors Slate already builds.
import * as Y from "yjs";
import { yCollab, ySyncFacet, ySyncAnnotation, yUndoManagerKeymap } from "y-codemirror.next";
import * as awareness from "y-protocols/awareness";
import * as sync from "y-protocols/sync";
import * as encoding from "lib0/encoding";
import * as decoding from "lib0/decoding";

export { Y, yCollab, ySyncFacet, ySyncAnnotation, yUndoManagerKeymap, awareness, sync, encoding, decoding };
