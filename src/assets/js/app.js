// Preact migration entrypoint (no build — ESM + htm + signals).
//
// The signals state store (store.js) is the reactive source; notebook.js mounts the Preact
// <Notebook> into #nb and owns the cell rendering. Importing it here boots the whole UI.
import './notebook.js';
import './toc.js';       // Table of Contents — first island migrated off the classic scripts
import './health.js';    // Watchdog health badge + panel
import './mesh.js';      // Consent-gated region introduction popup (PEER_TUNNEL_PLAN §5.1)
import './allocnotice.js'; // Compute node about to be released, or already gone
import './regionprep.js'; // Prepare a region before this notebook's first worker on it
import './telemetry.js';  // Telemetry view — one worker's resource use over time, from the worker popup
import './workerbar.js';  // …with the worker's facts and restart/reap above the charts
import './extensions.js'; // Extensions gallery — browse + install from the curated registry
import './debugger.js';  // Cell debugger — the step controls under a cell, and the focus view
import './profiler.js';  // Cell profiler — compile, run and read a cell's profile against its code
import './keymap-ui.js';  // Settings → Keyboard — rebind any shortcut, switch keymap presets
