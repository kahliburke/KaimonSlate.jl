// Preact migration entrypoint (no build — ESM + htm + signals).
//
// The signals state store (store.js) is the reactive source; notebook.js mounts the Preact
// <Notebook> into #nb and owns the cell rendering. Importing it here boots the whole UI.
import './notebook.js';
import './toc.js';       // Table of Contents — first island migrated off the classic scripts
