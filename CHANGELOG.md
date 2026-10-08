# Changelog

Notable changes to KaimonSlate, newest first. Each entry is the release notes for that version, so
the wording is the one published at the time rather than a later summary.

`SlateExtensionsBase` lives in `lib/` and versions separately, with its own
[changelog](lib/SlateExtensionsBase/CHANGELOG.md); where a release requires a particular version of
it, the entry below says so.

Entries for 1.3.0, 1.3.1, 1.5.2 and 1.10.0 were reconstructed from their commits, because no notes
were written when they went out. They are marked.

## [Unreleased]

## [1.11.1] - 2026-10-08

### Changed

- A control runs its readers only when its value changes. A select sends its value on input and
  again on change, and each send re-ran every cell reading it. A button is exempt: pressing it is
  the change.
- The package-install modal shows the last few lines of Pkg's own output, in its colour, starting
  from the point the install began rather than from whatever the worker log already held.

### Fixed

- A figure that imports a module from `/ext-assets/` no longer stays blank when it shows before the
  notebook declares the package.
- A cell whose HTML output imports a module from `/ext-assets/` now draws in a static HTML export,
  opened from disk or from a site below the host root. A standalone page carries each such module
  once. (#63, @disberd)
- A vendored module is carried into a static export uncompressed. The browser's own loader has no
  inflate step, so a compressed one did not load at all.
- A static export resolves its vendored asset directories itself, so one taken before a notebook's
  first run finishes no longer ships a page pointing at a route it has no server for.
- A cell's own run is no longer reported back to it as an external edit, so blank lines the server
  trims and typing during a run do not raise the conflict prompt.
- An edit survives a run that never reaches the server. The baseline used to advance anyway, and the
  next update then overwrote the edit the run was committing.

## [1.11.0] - 2026-10-06

### Added

- A record field holding rows of the same shape, a vector of NamedTuples sharing their keys, draws
  as a stack of cards with the first row face-up. A click fans them out over the page in a cards or
  table view, and the field header names the row count and the column types.

### Changed

- A cell's duration reads in a unit that fits its length: milliseconds under a second, seconds under
  a minute, then minutes with seconds and hours with minutes. The clock of a running cell uses the
  same format. (#50, @haakon-e)

### Fixed

- A record's collection field shows its contents rather than its type signature.
- A control reports its live value after a memo restore replays its `@bind`. A cell that declares a
  control without reading it was restored for every value of that control and then reported the
  stored one, so a reader computed with one value and cached its output under the key of another.
  (#58, @disberd)
- An output keeps its height hold when a newer swap supersedes an older one, so a figure no longer
  collapses while its images load. (#59, @disberd)

### Performance

- Naming a byte asset takes a plain SHA-256 instead of the general fingerprint, about 9x faster.
  Each byte asset gets a new filename once, so a published site gets copies under the new names on
  its next publish. (#61, @disberd)

## [1.10.0] - 2026-10-05

*Reconstructed; no notes were published with the release.*

### Changed

- Speaker notes are presenter-only. A `notes` cell no longer appears in the reading view, the table
  of contents, or an HTML or Markdown export, omitted rather than hidden so the text is not in the
  published page's source. It stays visible while authoring, and the presenter window and PDF notes
  appendix are unaffected. A `slide`-tagged cell shows a `slide` chip, and both expose
  `.cell-notes` / `.slide-start` for styling.
- Requires SlateExtensionsBase 0.11.

### Added

- A package's render can save a cell asset (`slate_save_asset`), so bulk data travels as bytes
  beside the markup instead of a literal inside it: content-addressed, memo-carried, export-inlined.
- A returned output gets `destroy` on every path that discards it. An extension holding a WebGL
  context can release it rather than the page walking into the browser's per-page limit and blanking
  unrelated figures.
- A workspace member's deps reach the memo key. The manifest lookup missed a workspace root and a
  versioned manifest, so the key did not move when a dependency changed version and a restart
  restored results computed by the old one. (#49, @disberd)
- A returned output can stay mounted across runs (`update`, `keepMounted`, `data-slate-keep`).
  (#45, @disberd)

### Fixed

- An app's failure banner names the failing step under a `column=N` layout instead of falling back
  to "Something didn't finish".
- `Slate.asset` rejects a failed fetch. A pruned blob's 404 body was returned as data, and an asset
  with a `dtype` reinterpreted it as a typed array.
- A live output's saved assets survive a page reconnect, on both kernels.
- A `.jl` bundle's frozen preview carries its asset bytes, not only its figures. A bundle opened on
  another machine resolved nothing for any widget reading `Slate.asset`.
- An asset saved while interpolating markdown reaches the page. Echarts and tables from the same
  interpolations were already carried; assets were dropped at the JSON boundary.
- ECharts take their dark mode from the Slate palette background.
- A slide's cells stay on the stage when they re-run, so a knob works in present mode.
  (#48, @disberd)
- A stored render no longer outranks a live payload while a notebook hydrates. (#43, @disberd)

### Performance

- Fingerprinting a numeric array no longer allocates per element: roughly 977 MiB to 0.1 MiB on an
  8 MB vector, about 2.3x faster. Byte-identical, so no memo is invalidated.
- The durable blob store is held to a disk budget (`KAIMONSLATE_BLOB_CACHE_MB`, default 2048) with
  least-recently-used eviction, which bounds the blobs of notebooks closed long ago.

## [1.9.0] - 2026-09-25

- **Pick a point, region or path by clicking a figure.** `PickPoint`, `PickRegion` and `PickPath`
  read data coordinates off a Makie axis, log and reversed axes included. `pick_on!(fig, control)`
  aims one at a figure.
- `snapto` restricts a pick to a named set of points and returns the nearest, measured across the
  axis rather than in data units. A snapped pick enumerates for static export.
- A widget kind registered from outside Slate can declare its own replay domain, so an extension's
  control is exportable.
- **A PDF export captures all of its HTML cells in one browser round-trip**, rendered under the
  export's palette rather than the reader's.
- A PDF export reports when it fell back to text because no browser was available.
- The deck follows the presenter window when it navigates. (#42, @disberd)
- The remotes panel stays inside the window, and only the default host is marked in gold.

## [1.8.7] - 2026-09-24

- **A standalone notebook gets its own package environment.** A notebook outside a project resolves
  packages in an environment of its own, not the hub's. `Pkg.status()` and the Packages panel
  describe the notebook, and adding a package affects only it.
- A cell whose value is a NamedTuple renders as a grid of fields: five significant figures, units
  and uncertainties set apart, and a quantity in SI base units read back in its named unit.
- A matrix field shows as a thumbnail and opens its `slate_matrix` rendering on click.
- Clicking a field's name highlights the source that produced it.
- **Settings → Display → NamedTuple as plain text** switches the grid back to Julia's text.
- A cell that raised an error can be captured again by `slate.view` and PDF export.
- A leading `~` expands with the platform's own separator on Windows.

## [1.8.6] - 2026-09-22

- `include` works in a notebook cell: the file is evaluated into the cell namespace, a literal path
  is tracked as a cell input, and the definitions it makes join the dependency graph.
- A notebook with no enclosing project resolves `@asset`, `readfile` and `include` beside the `.jl`
  itself when its project dir has no such file.
- Vim keymap fixes (#36): Escape inside a cell no longer exits the dep-focus or zen view, and a
  chord that types a character is no longer installed into the cell editor.

## [1.8.5] - 2026-09-20

Windows fixes.

- `~` paths now resolve. `Base.expanduser` does nothing on Windows, so opening a notebook by a tilde
  path failed with an empty error.
- ssh runs unmuxed. Win32-OpenSSH has no connection multiplexing, and ControlMaster made every
  remote call fail before it ran.
- Cross-cell error jump, `vscode://file` source links, and exported page asset urls all handle
  Windows paths.
- The export check for an `include` the bundle cannot carry compares against `git ls-files` output,
  which is forward-slashed; on Windows it matched nothing and reported no gaps.
- A depot package is no longer misread as a dev checkout.
- The embedded Kaimon host is redirected into its private location on Windows too. It reads
  APPDATA/LOCALAPPDATA there and ignored the XDG vars, so an exported app used, and wrote to, the
  real user config.

## [1.8.4] - 2026-09-17

Requires Tachikoma 2.6.2, which fixes Windows console input for the notebook TUI: arrow keys and
Esc reached the TUI as stray characters and mouse movement produced spurious keypresses.

## [1.8.3] - 2026-09-15

### Fixed

- A cell could bind a global while the dependency analysis reported it bound nothing, leaving its
  readers with a stale value shown as up to date, with no error and no stale marker. Two causes,
  both fixed:
  - `global x = …` where `x` was also bound earlier in the same scope, as in
    `let; v, _ = f(); global v = g(v); end`. ExpressionExplorer reads the earlier line as
    introducing a local; Julia binds the global, because one `global v` makes every `v` in that
    scope the global.
  - `eval(:(x = 1))`, `@eval x = 1` and `Core.eval(m, ex)`, which assemble the expression at run
    time. These now make a cell a barrier, as `include` already did. Macro-generated names
    (`@enum`, `Base.@kwdef`) were already resolved precisely by the macro-aware pass and are
    unaffected.

  The visible symptom was either a reader silently showing an old value, or an `UndefVarError` about
  a binding "too new" on a notebook's first run that a re-run cleared.

## [1.8.2] - 2026-09-14

### Fixed

- `bind_observable` threw `UndefVarError: Observables not defined in Main.SlateWorker` on the gate
  worker, where notebooks normally run (#34). It worked in standalone Slate, which is why it passed
  its own tests. The package is now resolved by the code that uses it, from the notebook's own
  manifest, so a notebook with Makie has it without naming it.
- A cell that defines a documented function no longer warns `Replacing docs for …` every time it
  re-runs. Re-running is the normal operation in a reactive notebook, and the one case the warning
  could have flagged, the same function documented in two cells, the cell header already reports.

## [1.8.1] - 2026-09-14

### Fixed

- Output from a running cell appears as it is printed, instead of only when the cell finishes.
  Terminal progress meters work as a result: `ProgressMeter`'s `@showprogress` renders as one line
  that updates while the loop runs, the way it does in a terminal, rather than a new line per redraw
  after the fact. Anything that redraws in place gets the same treatment, with no API to call.
- `printstyled`, `@warn`, stacktraces and `Pkg` output keep their colour instead of arriving as
  literal escape codes. Exports follow: an HTML export carries the colour, PDF and Markdown take the
  plain text.
- Undo, redo, Replace All, a split or merge, and a timeline restore no longer raise the "changed on
  disk" dialog for the user's own edit.
- Typing in a `@bind` text control no longer fires command-mode shortcuts, so typing `w` no longer
  converts the cell to a web cell.
- A control keeps its caret and selection when its row is rebuilt.
- The Files tree's arrow keys, Enter and F2 no longer reach the notebook behind it.
- Live cell updates take the same render path as the rest of the app, so an external edit landing on
  unsaved work is raised as a conflict rather than applied silently.
- A downloaded bundle no longer reads as a second copy of the notebook it installed.
- A published page resolves its build settings from one place, and a published bundle carries the id
  of the document it came from.

### Changed

- Move up / move down have left the cell header for a rail in the margin beside the cell, shown when
  the pointer is near its top-left corner.
- The agent panel has a settings button that opens Settings on the Agent section.

## [1.8.0] - 2026-09-13

### Rebindable keyboard shortcuts

Every shortcut in the notebook is now a named command resolved through one keymap, and the whole set
is editable under **Settings → Keyboard**. Search the list, click a chord to re-record it, remove
one, add a second, or reset a row to its default.

Four presets ship: **Slate** (the existing bindings), **VS Code**, **Jupyter / Colab**, and a
**vim-flavoured** set that puts vim motions over the cells. Customisations sit on top of the chosen
preset, so switching preset only moves the bindings you have not changed.

- Bindings can be multi-stroke (`dd`, `gg`, `⌘K Z`). The half-typed sequence shows on screen while
  it is armed.
- Chords the browser keeps for itself are refused outright. Chords it merely uses are flagged with
  what they shadow.
- Recording a chord another command already holds opens a prompt: reassign, take it, keep both, or
  cancel. Nothing is written until you answer, and reassign chains straight into recording a
  replacement for whatever was displaced.
- Shortcuts are saved in `keymap.json` under the Slate config directory, so they follow you between
  browsers. Import and export as JSON.
- An extension's palette command gets a row too, and the `key` it declares is its default binding
  rather than a display hint.

Text editing inside a cell still comes from the editor keymap in Settings → Editing (default, vim
or emacs).

Also in this release: a structural edit made from inside a cell editor no longer reports your own
keystroke back to you as an external change.

## [1.7.0] - 2026-09-12

### Controls that drive a figure without rebuilding it

Reading a `@bind` variable makes a cell a reader, so every change reruns it. For an expensive cell,
or a figure whose state is the point, like an interactive scene with a camera you have positioned,
that is the wrong shape: the work is redone and the state is lost.

- **`bind_observable(:name)`** hands the control over as an `Observable` instead. The name is quoted,
  so it is data rather than a read and the cell never restales; the value is pushed in and the figure
  updates in place. The Observable is cell-local, a fresh one per run, released when the cell reruns,
  which is what makes an ordinary `lift` on top of it safe.
- **`hidden(Widget(…))`** declares a control the notebook does not draw: no row in its `@bind` cell,
  no entry in a surfaced strip, not offered by the palette. It is otherwise completely normal. It
  holds a value, coerces it, fires `@onchange`, feeds `bind_observable`, and stays a parameter in a
  static export. For when something else is drawing the control and you want one control rather than
  two copies that can drift.

Extensions reach the same controls through the execution context, added in SlateExtensionsBase
0.10.5: `slate_bind_widget`, `slate_bind_value`, `slate_bind_names`, `slate_on_bind` and
`slate_bind_observable`, plus the `window.slateSetBind` / `window.slateBindValue` globals for
writing a change back the way a native control does.

### Fixed

- A live re-render no longer wipes a cell's controls. The re-render wire carries no bind specs, and
  mirroring them unconditionally deleted the controls of any cell that both declares `@bind`s and
  returns a session-bound output. They vanished the moment a browser connected.
- Cell callbacks and cleanups are invoked at the latest world age, so teardown registered by a
  package loaded mid-session actually runs instead of failing silently and leaking.
- The in-process kernel gained `rerender_live`, `get_served_asset` and `notify_worker_reset`, which
  only the worker path had. Standalone notebooks with session-bound output previously hung on a
  placeholder.
- Axis backgrounds follow the Slate theme rather than being transparent.
- Tested on Julia 1.13 as well as 1.12. (#32)

## [1.6.0] - 2026-09-11

### Editor

**Multiple cursors.** `⌥`-click or `⌘⌥↑`/`⌘⌥↓` to add carets, and `⌘D` to select the word under the
caret and then each next occurrence. Extra carets type together. `Esc` collapses back to a single
caret under every keymap, vim included. (#29, @haakon-e)

**Optional editor chrome.** Line numbers, indent guides and code folding, each off by default and
each applying live from Settings without a reload. Julia folding covers `function`, `struct`,
`module`, `macro`, `if`, `for`, `while`, `try`, `let`, `begin`, `quote` and `do`, and a folded block
keeps its own header line and its `end`. (#30, @haakon-e)

**Find and replace across every cell.** `⌘F` opens one find bar for the whole notebook rather than a
panel inside the focused cell. `Enter` and `⌘G` step across cell boundaries, and cells you have not
scrolled to still contribute to the count. Whole-word matching is decided by character category
rather than `\b`, so it behaves correctly for the Unicode names Julia encourages. (#31, @haakon-e)

**Replace All is a single undoable action.** It applies as one operation, so one `⌘Z` reverses the
whole rewrite and the timeline records one labelled checkpoint you can restore later. It also
rewrites markdown and `@bind` cells, which were silently skipped before.

**Saving under the vim and emacs keymaps.** `:w`, `:wq`, `:x` and `C-x C-s` apply the buffer
wherever you are: running a code cell, committing a markdown or `@bind` cell's source, or writing a
file in the Files tab.

### Appearance

**The matching-word highlight is a setting.** Selecting a word tints its other occurrences in that
cell. It can now be turned off, and its colour chosen from a swatch row. The default follows the
notebook theme's accent, so it recolours with the theme.

**Error and warning colours follow the theme.** Output washes, the editor's error lines and app-mode
errors carried fixed colours that disagreed with every theme but the default.

**An open panel highlights the button that opened it.** Files, Controls, Agent, Contents, DAG,
Worker log, History and Scratchpad.

### Other

**`slate --ai`** starts an isolated Kaimon host, which is what enables remote workers and lets a CLI
agent drive the notebook.

Fixes: the find bar reports `5000+` instead of a truncated total that read as exact; the history
store resolves from Slate's cache home; a worker is reaped only when its hub is actually gone; and a
run location this hub cannot honour is reported rather than ignored.

## [1.5.2] - 2026-09-09

*Reconstructed; no notes were published with the release.*

- The completion popup is parented on the document body, and closes when a cell key runs the cell.
- A module's dotted completion leads with its own names.
- The docs search box completes names.
- The in-process kernel takes the same environment model as a worker.

## [1.5.1] - 2026-09-08

### Fixed

- The worker and hub log directory in `/tmp` was shared between users, and is now namespaced per
  user (#27). (#26, @mcontim)
- Echarts rendered as black on black in Firefox (#25).

## [1.5.0] - 2026-09-08

Workbook mode: serve a notebook as an app whose `workbook`-tagged cells the reader fills in, with
reset from a pristine copy the export ships alongside the launcher. Editors mount only where the
reader owns the cell, so a large document opens quickly.

Chart renderer: a reader setting chooses how ECharts rasterise. Some browser and driver combinations
composite a canvas as a blank rectangle, and the SVG renderer avoids that path. Static exports
honour a renderer query parameter.

Settings and the notebook config panel are now one dialog with a scope switch. Settings that existed
in both surfaces, once as a global default and once as a per-notebook override, appear once.

Web cells reconfigure their CSS and JS panes with the rest of the editors (#22, @haakon-e).

Requires Tachikoma 2.6.1. Earlier versions ship a build script that hung `app add` (#28). Accepts
SHA 1 on Julia 1.13.

## [1.4.9] - 2026-09-05

Emacs mode for the cell editor, alongside vim, under Settings → Editing → Editor keymap. Modeless,
so Escape still leaves the cell; `M-;` toggles comments and `C-g` cancels.

Background evaluation semantics are documented properly: promotion to a background job at ~30s is
automatic, so `background=true` is for when you don't want the result yet and have other work for
that window. Three tools (`api`, `run_on`, `edit_cell`) had been shipping with empty MCP
descriptions and now carry them again.

## [1.4.8] - 2026-09-04

Vim mode for the cell editor, under Settings → Editing → Editor keymap, off by default.

Escape steps out one level at a time: completion popup, insert/visual mode, a half-typed operator,
then the cell. `Ctrl-[` only ever leaves insert. Shift-Enter still runs the cell in every mode; `:w`
runs it, `:q` leaves it, `:q!` discards the edit. CodeMirror panels (the ex line and the Files-tab
find/replace) now follow the Slate theme.

## [1.4.7] - 2026-09-04

**Apps can run region cells.** An app keeps its own state home, which meant four separate failures
between a `region=` cell and the worker it names: no region registry in the app (an export now
carries the definitions its cells use, and `run.jl` seeds them), a memo store the hub resolved
differently from the worker, an ssh multiplex `ControlPath` longer than `sun_path`, which ssh
refuses outright and which reads as an unreachable host, and a routing failure that aborted the run
instead of landing on the cell. The last two are not app-specific: any pinned state home hit them.

**An export won't silently ship a package it has broken.** Exports carry git-tracked files, so a
source file that was never committed but is `include`d leaves the app unable to load, failing on the
target machine minutes after an export that reported success. That is now caught at export, naming
the files.

**Worker panel.** One tab per worker, severity-ranked with overflow, so comparing them is a click
rather than a re-navigation. Each carries host, transport, ports, environment and whether it was
adopted warm. `/status` serves logs per worker rather than only the main one.

**A remote worker is judged by its wire**, not by a local process handle it never had. It was
reporting "not running" beside its own live CPU and memory.

Also: the shared-document notice no longer reaches an app, where it named a path from the machine
the app was built on.

## [1.4.6] - 2026-09-03

**Worker lifecycle is one tool.** `reap_worker`, `remote_workers` and `whereis` become
`worker(action="status"|"list"|"restart"|"reap")`, and `restart` joins them: the browser has always
had it, the tool surface never exposed it. Where a worker runs is no longer part of the interface.
Every action takes the same arguments and routes to the local or remote machinery itself.

Reaping a local worker now actually reaps it, and reaping reports what happened rather than assuming
success.

**Clicking the empty page clears the selection** instead of entering edit mode. WebKit and Blink
place the caret in the nearest `contenteditable` when you click a block containing one, so a click
in the margin level with a line of code focused that cell's editor.

## [1.4.5] - 2026-09-02

**Julia workspaces.** A notebook in a project that is a `[workspace]` member now resolves its
environment the way the loader does. A member has no manifest beside its `Project.toml` and inherits
the workspace root's `[sources]`, so seeding an environment from the member alone dropped both, and
an unregistered dependency that resolved fine in place failed elsewhere with "expected package X to
be registered". Manifest path deps are also resolved relative to the manifest's own directory, which
for a member is the workspace root.

**Dependency graph.** `!x` no longer counts as mutating `x`. The `f!` mutation convention also
matched the negation operators, so any cell negating a value claimed to define it, chaining
unrelated cells and raising phantom multi-def conflicts.

**Math.** `\(…\)` and `\[…\]` now typeset in both the notebook and the PDF. CommonMark was dropping
the backslash before KaTeX saw it, and Typst's markdown renderer only recognizes the dollar forms.

**Saved files.** Prose containing LaTeX no longer breaks the `.jl` as a runnable script. Cells whose
text carries a backslash command Julia does not recognize as an escape (`\sum`, `\int`) are written
with a raw literal; every other cell keeps the existing skin, so current notebooks are untouched.

**Docs.** The two raw-Typst markers (`raw-typst`, `typst-begin-exclude`) are documented, and
`examples/typst_print.jl` demonstrates the print-formatting surface.

## [1.4.4] - 2026-09-01

Numeric arrays stream to the browser as `Int8`, `UInt16`, `UInt32`, `Int64`, `UInt64`, `Bool` and
`Float16` as well as the previous five types. `Int64` is the one that mattered, Julia's default
integer, previously rejected outright; it maps to `BigInt64Array` rather than narrowing. The dtype
table now lives in one place, `SlateExtensionsBase.DTYPES`, and generates the frame encoder, the
asset packer and both browser decoders, which were four hand-kept copies. Needs
SlateExtensionsBase 0.10.4.

Markdown and web cells can host `@bind` controls: drag-to-host accepts any cell with a control
strip, and surfacing one from outside the browser no longer needs a reload.

A notebook copied from another shares one document with its original: history, chat and preview.
Those stores are keyed by document id now, and "Split from copy…" gives a copy its own.

## [1.4.3] - 2026-08-31

Fixes the agent chat pane eating numbers. `mdLite` stashed code spans behind bare decimal
placeholders and restored them with a global digit scan, so every number in an agent's prose was
swallowed too: a measurement rendered as `undefined`, or silently as an unrelated code span when the
digits fell inside the stash's range. Transcripts were never damaged, only their rendering; reloading
a notebook re-renders existing history correctly.

Also renders GFM tables in the chat pane, which previously came through as raw pipe soup.

## [1.4.2] - 2026-08-28

### Fixed

- **Math renders in the docs pane.** The help viewer (⌘⇧K) and the autocomplete documentation card
  showed a docstring's `$…$` and `$$…$$` as raw delimiters instead of typesetting them.
- **A cell's edit mode is visible again.** The edit-mode ring was erased by the first keystroke, so
  the chrome claimed command mode while the keyboard was still in the editor. Mode is now part of the
  cell's rendered state, and it is cleared correctly when an editor is torn down.
- **Escape leaves the editor on the first press.** It was being swallowed whenever a completion query
  was still in flight with nothing yet on screen, which is most of the time while typing.
- **Escape no longer discards a markdown cell's edits.** It leaves edit mode and keeps the text; a
  second Escape closes the source overlay, committing a changed source rather than dropping it.
- Makie's in-figure widgets are themed.
- Docs search answers from the whole docstring.

### Changed

- A cell's ring colour now means one thing: purple for command mode, teal for edit mode, with an
  `✎ edit` chip in the header. Green is left to the run-state stripe.

## [1.4.0] - 2026-08-25

A static HTML export follows its controls further. `@replay` already carried a chart's numbers and a
table's rows into a page with no Julia behind it; this release adds the two axes that were missing,
so a frozen page can change its columns, its prose and its images as the reader moves a control.

### A replayed table can change its columns

A control that chooses which columns a table shows used to be refused: rows were matched by their
whole vector, so a row with a column dropped matched nothing. The two axes are now swept separately.
The page carries every column any position can show, plus a short mask per position, in the same
slice as the row order.

```julia
#%% code id=overview controls=groups
keep = [c for c in names(df) if !(c in OPTIONAL) || wanted(c, groups)]
slate_table(df[!, keep])
```

Cases that cannot be expressed this way say so with the reason rather than shipping a page whose
cells sit under the wrong headings: a control that moves rows *and* columns together, a column whose
values also change with the control, and positions that disagree about column order.

### Prose follows its control

A markdown cell's `{{ }}` now replays. Before this, a sentence beside a replayed figure kept its
export-time numbers while the figure moved, so a page could state something the chart next to it
contradicted. The strings ride inline in the routing table, which for a KPI line is a couple of
kilobytes against the hundreds a single figure's sweep costs.

### Interpolated image URLs

`![alt](frame_{{ n }}.png)` works, in the live notebook and in an export. Previously the
interpolation was substituted with its `<span>`, which wrote markup into the attribute and broke the
tag.

In an export, every position's URL is resolved and its asset inlined, so all of them ship. Picking a
picture from a slider is now one line of markdown instead of a web cell with hand-written
JavaScript.

### Fixed

- A `MultiCheckBox` exported as a `<select multiple>`, where a plain click clears every other
  choice. It renders as the checkbox list it is live, so the control takes the same gestures in both.
- A table wider than the content column had nowhere to scroll: the export stylesheet clamped the box
  without setting `overflow-x`, leaving the far columns unreachable.
- A control driven by the page's own JavaScript never updated its printed value.
  `Slate.replay.relabel` now handles it, and fires before a caller's own handler so a custom readout
  still wins.
- A replayed table opened showing the union of every position. `Slate.replay.wire` applies the
  export-time position on load.

### Compatibility

Nothing breaks, and no notebook needs changing. A notebook that interpolates into an image URL
requires 1.4.0, since earlier versions render that tag broken.

## [1.3.1] - 2026-08-24

*Reconstructed; no notes were published with the release.*

- A registry's repo url is read from the field Pkg actually has.
- The extension screenshot is framed on rendered output, and its re-run is fixed.

## [1.3.0] - 2026-08-24

*Reconstructed; no notes were published with the release.*

- An extension catalog and gallery.
- `@replay` works for every control with a finite domain.
- A table can follow its control in a static export, and a published page's replay data is written
  beside it.
- An exported slider is drawn rather than left to the browser.
- Surfaced controls render where they were surfaced, and animation can be turned off.
- What a cell rendered is kept when snapshotting its values.
- An extension's video shows behind its screenshot.
- Requires SlateExtensionsBase 0.10.2.

## [1.2.3] - 2026-08-22

### Which Slate is running is now visible

The version was unanswerable from anywhere a report comes from: not the front page, not the TUI, not
an app's operator page. It matters most in the case it was missing from. `slate` attaches to whatever
hub is already up, normally Kaimon's extension, which after an update is a **different install** from
the launcher. A hub still serving the copy that was replaced looked exactly like everything working.

- The `slate` TUI has a **Version** row. Attached to an external hub it reports that hub's version
  and calls out a mismatch: *"hub is v1.2.2, this slate is v1.2.3 — Kaimon is serving a different
  install"*. A hub with no `/api/version` can only be an older build, and is described that way.
- `GET /api/version`, served in both postures, and reachable in app mode.
- The app `/status` page names the serving version, and the front-page chip links to its release.
- Re-pointing a registration left behind by an update no longer announces itself as a first-time
  registration; it says what moved, and that a running Kaimon reloads within seconds
  (Kaimon ≥ 2.6.1).

### Upgrading

Documented in the README and the installation page, because the second step is easy to miss:

```julia-repl
pkg> registry update
pkg> app up KaimonSlate
```

```sh
slate
```

Running `slate` once is what points Kaimon at the new install.

## [1.2.2] - 2026-08-22

### Extension registration survives an update

A Pkg-installed KaimonSlate lives at `packages/KaimonSlate/<slug>`, and the slug follows each
version's tree hash, so an upgrade lands in a **new directory** while Kaimon's `extensions.json`
goes on naming the old one. Nothing errored, because the old slug survives until a `Pkg.gc`: Kaimon
simply kept loading the version that had been replaced, and the update appeared to have done nothing.

The `slate` app now re-points a registration it has outgrown. Deliberately narrow: it acts only when
the registered path is gone, or when both it and the running package are Pkg copies under different
slugs. Two genuine checkouts are left alone, so loading from a git worktree still cannot repoint the
config, and `enabled` / `auto_start` are carried across so repairing a path cannot re-enable an
extension that was turned off.

### The running version is visible

Previously it appeared nowhere, not the front page and not the hub log. Now it shows beside the title
on the front page and in the hub's startup line. Read from the loaded package, so it cannot go stale.

## [1.2.1] - 2026-08-22

### Fixed

An extension's declared module imports now extend the open page's import map, so a
`using YourExtension` in a live notebook makes `import "spec"` resolve without a page reload, the
same way a front-end script is injected.

Re-pointing a specifier the page has *already* declared still needs a reload, since a document
cannot redefine a specifier something may already have resolved against.

## [1.2.0] - 2026-08-22

### App mode

A notebook can now be served as a finished **application**: prose, results, figures and live
controls, with the authoring API refused server-side rather than merely hidden in the UI. Readers
cannot edit a cell, install a package, reach the filesystem, talk to the agent, or publish. Those
routes are not served at all.

- `export_app(nb, dir)` writes a self-contained folder with launchers (`run.sh` / `run.bat` /
  `run.jl`); a recipient needs only Julia 1.10+.
- `start_hub(; app = true)` serves an existing hub's notebooks in that posture. It is a property of
  the process, not a flag inside the document.
- `app_defaults(...)` sets the presentation a visitor gets before choosing their own.
- `/status` is an operator page: worker vitals, uptime, failures, logs.
- There is **no authentication** at any bind address; who can reach the port is the whole access
  story.

See the [App Mode](https://kahliburke.github.io/KaimonSlate.jl/dev/app-mode) page.

### Windows

`app add` on Windows could not start a worker at all: the worker's infra environment substituted an
unescaped Windows path into a TOML basic string, so `C:\Users\...` was read as a unicode escape and
the generated `Project.toml` failed to parse. Fixed, with a round-trip regression test.

### Reactive state and caching

- Memo entries are keyed on the state a cell actually reads, so a cell reading only reactives no
  longer serves output computed from values that have since moved.
- An entry that would define nothing is no longer served in place of a cell that defines something.
- Control changes answer with a receipt instead of the whole notebook.
- Every cell payload carries a revision, so a stale payload cannot overwrite a newer one.
- Charts replace their series rather than merging by index.

### Other

- Re-exporting over a deployed app's folder now actually updates it.
- A worker whose environment fails to build reports the build failure instead of naming a package.
- A silent worker is logged once and shown as degraded, rather than once per sweep.
- Requires SlateExtensionsBase 0.10.

## [1.1.0] - 2026-08-14

### Added

- Tool calls are a first-class cell kind. `slate_tool` / `@tool` / `slate_tools` expose a session's
  tool calls as cell values, tool calls are recorded as TOOL cells, and the tool panel is an
  interface rather than a readout.
- Cell runs can be promoted to background jobs, with progress surfaced in the cell.
- `animate` takes a displayed size and is capped by default.
- Files panel: hidden files, file operations, and a lost-update guard on save.

### Fixed

- A worker that dies during boot is reported as a crash instead of an unreachable gate (#18). The
  connect retry surfaced only its last socket error, so a worker that exited during boot was
  reported as "not reachable (connection refused or timed out)", a network condition it never got far
  enough to have, after waiting out the full connect deadline. The retry now stops as soon as the
  process is gone, and the error carries the worker's own failure plus its log path. A kernel with no
  process of its own (attached or remote) is unaffected.
- An extension's `slate_render` runs one time for each display rather than 2-3 (#19, requires
  SlateExtensionsBase 0.9.1; older versions keep working and log a warning). (@disberd)
- A worker port is probed before it is handed out. The port counter is module state, so an extension
  restart rewound it while warm workers survived, and the next spawns walked over ports those workers
  still held. A hub-dialed stream port then landed on another worker's PUB and the notebook silently
  lost every stream frame.
- Exporting a front end follows its imports, so a widget split across several ES modules no longer
  ships with files missing.
- A notebook's own packages are restored when its environment is rebuilt, and
  `[weakdeps]` / `[extras]` carry into a forked notebook env.
- Watcher loops stop when a notebook closes.

## [1.0.0] - 2026-08-04

First release in General.

- Fix Kaimon detection on Windows: `_kaimon_dir()` matches `kaimon_config_dir()`. (#1, @mthelm85)
- A `+` between cells inserts a cell before or after. (#3, @s-celles)
- A wide `slate_table` scrolls horizontally instead of clipping columns. (#4, @mthelm85)
- A per-cell toolbar action extension point: `slateRegisterCellAction` and
  `register_cell_action!`. (#8, @s-celles)
- BonitoSlate: live WGLMakie and Bonito over Slate's own transport (#7). (#9)
- `KAIMONSLATE_PORT` is read at run time rather than captured at precompile time, so a launcher can
  pin the hub port (#6).

[Unreleased]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.11.1...HEAD
[1.11.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.10.0...v1.11.0
[1.10.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.7...v1.9.0
[1.8.7]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.6...v1.8.7
[1.8.6]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.5...v1.8.6
[1.8.5]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.4...v1.8.5
[1.8.4]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.5.2...v1.6.0
[1.5.2]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.9...v1.5.0
[1.4.9]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.8...v1.4.9
[1.4.8]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.7...v1.4.8
[1.4.7]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.6...v1.4.7
[1.4.6]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.5...v1.4.6
[1.4.5]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.4.0...v1.4.2
[1.4.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kahliburke/KaimonSlate.jl/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kahliburke/KaimonSlate.jl/releases/tag/v1.0.0
