# Command Palette & Help

Two keyboard-driven tools make everything in the notebook reachable without hunting through
menus: the **command palette** (⌘K) for actions, and the **help dock** (⌘⇧K) for
documentation.

## Command palette — ⌘K

Press **⌘K** (or click the **⌘K** hint in the top bar) to open a searchable list of *every* action,
each with its keyboard shortcut. Type to filter, **↑/↓** to move, **↵** to run. Filtering matches the
words in a command's label, so type what the command is called rather than an abbreviation of it.
Recently used commands come first.

![The command palette: a fuzzy-searchable list of every action with its shortcut](./assets/command-palette.png)

It's not just commands — entries are tagged so the palette doubles as an insert menu and a
navigator:

- **Cell actions** — add / move / delete / convert / split / merge, run stale, show a cell's
  dependency chain.
- **Panels** — Packages, Worker log, History (the [Timeline](history.md)), Extensions.
- **Export & publish** — one *Export…* entry covering HTML, publication PDF, Markdown, a
  self-contained `.jl` and an app folder, plus *Export PDF (slides)* and Publish (see
  [Export](export.md) and [Publishing](publishing.md)).
- **`@bind` snippets** — insert any widget (`Slider`, `Toggle`, `Select`, …) as a ready-to-edit
  snippet.
- **Recipes** — drop in a starter chart or table cell.
- **Jump to cell** — every cell id is listed; pick one to scroll to and select it.
- **VS Code / project** — open the notebook or its project in your editor; open Settings; jump
  back to the notebook index.

Single-letter and ⇧-shortcuts are *command-mode* (a cell is selected and you're not editing
it); ⌘-shortcuts work globally, including from inside the editor.

## Help & docs search — ⌘⇧K

Press **⌘⇧K** to open the **help dock**. With the cursor on a symbol it opens that symbol's
documentation directly; otherwise it's a search box over the notebook's package docs (a hybrid
semantic + full-text query). It runs shortly after you stop typing, and **↵** runs it immediately.

The search half needs Kaimon's documentation index, which harvests and embeds packages in the
background as they load. Without that backend, and in a standalone or exported run where
auto-indexing is off, search returns nothing. Direct `?name` lookup still works.

![The help dock: a docstring with clickable signature types, an exports grid, and a related-items rail](./assets/help-docs.png)

The dock is built for *drilling in*, not just one lookup:

- **Clickable references** — type names in a signature (`Vector`, `Float64`, …) and inline
  `` `code` `` names in the docstring become links; click to open that symbol's help.
- **Exports grid** — looking up a module lists its exports as chips, colour-coded by kind;
  click to dive into any of them.
- **Related rail** — neighbouring/related items are offered alongside the doc.
- **Slate's own API** — Slate's helpers (`@bind`, `Slider`, `echart`, `slate_table`, …) and ECharts
  option paths such as `yAxis.type` resolve from Slate's own registries, so they look up like any
  package symbol even though they have no package docstring.
- **Back / forward** — **‹ ›** walk your lookup history; **esc** dismisses the dock.
- **Open** — **↵** opens the selected result's documentation.
- **Insert** — double-click a result to drop the bare name at the selected cell's cursor (or copy
  the qualified name if no cell is focused).

Because it reads the *notebook's* environment, the help reflects exactly the package versions
loaded in this notebook — including packages you added through the [Packages](packages.md)
panel.
