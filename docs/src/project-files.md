# Project Files

A notebook usually sits inside a Julia project, and most of the work around it is in that project's
other files: the package source your cells call, the data they read, the JavaScript a web cell
loads. The **📁 Files** panel puts those in the browser beside the notebook.

Open it from the **📁 Files** button in the top bar, or by clicking the notebook's title. There is no
keyboard shortcut.

![The Files panel: the project tree on the left with folders and file sizes, and the file pane on the right](./assets/files-panel.png)

## What the tree shows

The root is the **enclosing project**: the directory holding the nearest `Project.toml`, found by
walking up from the notebook's own file. A notebook at `myproj/notebooks/analysis.jl` gets a tree
rooted at `myproj/`, with `notebooks/` as one folder inside it.

That is the same root `@asset` and `datadir()` resolve against, so what you see here is what those
reach.

### The data directory

`datadir()` returns the notebook's own data directory, and `@sfile "flights.csv"` is a path into it
that you can read from and write to. Using them instead of a hardcoded path keeps the notebook
portable between machines.

The directory ignores itself in git by construction, so a stray database is never committed. It is
where a [`FileUpload`](widgets.md) puts a reader's file, it travels with an exported
[app](app-mode.md), and a [region](regions.md) can repoint it with its own data root.

A notebook with no enclosing project has no source to browse, and the panel says so.

Some things are never listed: `.git`, `.julia`, `node_modules`, `compiled`, `build`, `.cache`,
`__pycache__`, `.vscode`, `.claude`, `.ipynb_checkpoints`, and `.DS_Store` / `Thumbs.db` /
`.gitkeep`. Dotfiles are hidden until you press the `·` button, which remembers your choice per
notebook. The tree does not read `.gitignore`, so an ignored file that is not on that list still
appears.

Two conveniences above the tree: a filter box that matches loosely against the whole path, so
`srvcmp` finds `src/server_complete.jl`, and a strip listing every notebook the hub is currently
serving, with error counts, for jumping between them.

`.jl` files that look like notebooks are marked with 📓 and can be opened as notebooks from the
right-click menu.

## Reading a file

Click a file to open it on the right.

| Kind | What you get |
| --- | --- |
| Text | A full editor with line numbers, find and replace (⌘F), bracket matching, ⌘/ to comment, and Julia autocompletion |
| Image | A preview with its pixel dimensions |
| Audio, video | A player |
| Anything else | "Binary file, not shown", with a download link |

Classification is by filename. Around 60 extensions are treated as text, plus common
extensionless names like `Dockerfile`, `Makefile`, `LICENSE` and `README`. A binary file and an
`.svg` both offer **≡ Open as text** if you want to see the bytes anyway.

![A Julia file open in the Files panel: the filter narrowed to one match, the file's path, Open as notebook and Download actions, and the source with line numbers and syntax highlighting](./assets/files-editor.png)

Syntax highlighting covers the four grammars the editor bundles: CSS, HTML, JavaScript and Julia.
Julia's grammar is reused for Python, R, TOML, YAML and shell, which share its comment character and
read acceptably. C, Rust, Go, Lua, SQL and TeX open without highlighting.

Files over 4 MB will not open in the editor, and a file that is not valid UTF-8 is refused rather
than mangled.

Your cursor and scroll position in each file are remembered while the notebook is open.

## Editing and saving

Save with ⌘S. There is no confirmation.

Slate records the modification time when you open a file and sends it back when you save. If the
file changed on disk in between, the save is refused and you get a choice of **Reload from disk**,
**Overwrite**, or cancel. Switching to another file with unsaved changes offers to save first, and so
does closing the browser tab.

While the panel is open, Slate re-checks the open file whenever the window regains focus. A clean
buffer is quietly replaced with the new contents. A dirty one gets a **changed on disk** badge and
waits for you to decide at save time.

**New file** and **New folder** are in the right-click menu. A new folder stays invisible in the tree
until it has something in it.

### What a save does

Saving writes to disk. Nothing re-runs on its own.

If the file is package source that the notebook's worker has loaded, Revise picks it up, and Slate
marks stale every cell that reads a name the edit changed, plus everything downstream of those. A
banner tells you how many cells are affected. You choose when to run them. If your edit does not
parse, the banner says that instead.

This is on by default and can be turned off per notebook. See
[Editing project source](hot-reload.md), which also covers the edits it will not catch.

Saving a file a cell reads through `@asset` is different: those cells recompute immediately, because
that is what `@asset` is for.

!!! warning "Editing the notebook's own file"
    The tree marks the notebook's own `.jl` and will not let you rename or delete it, but it will let
    you open and save it. Doing so writes the file underneath the running notebook, which then
    re-parses it. Use the notebook itself to edit its cells.

## Rearranging

Right-click any row for the menu, or use the tree's keyboard shortcuts: arrows to move and
expand, Enter to open, **F2** to rename, **⌫** to delete, `/` to jump to the filter.

- **Rename** also moves. Type a name to rename in place, or a path with `/` in it to move within the
  project. It never overwrites an existing file.
- **Duplicate** works on files only, auto-naming `thing-copy.jl`, then `-copy2`, and so on.
- **Delete** asks first, counting the contents for a folder. Deleting a folder needs you to confirm
  the recursive delete, and is refused if the notebook's own file is inside it.
- **New folder** creates intermediate directories as needed.
- **Copy path** puts the absolute path on your clipboard.

Deletes are permanent. There is no trash, and the notebook's own undo history does not cover them.

## Adding files

Drag files from your desktop onto a folder row to put them there, or onto empty space in the tree to
put them in the project root. Dropping without a target folder lands them in `assets/`.

Names are sanitised, an upload identical to a file already there is reused rather than duplicated,
and a name clash with different contents is uniquified. The limit is 64 MB per file.

## With a remote worker

The tree is always your own machine's filesystem. There is no remote browser.

For package source this works out, because Slate rsyncs the project's `src/` (and any dev'd path
dependencies) to the remote as it changes, so a save hot-reloads on the remote worker the same way it
does locally.

Files outside `src/` are not carried by that. Data files reach a remote worker through a separate
mechanism that syncs the notebook's data directory at run time. A `.js` or `.csv` sitting elsewhere in
the project has no sync path at all.

## Access

Every path is confined to the project root. A path that tries to escape, by any spelling, is
rejected before anything is read or written.

That confinement is the only restriction. There is **no authentication**, so anything that can reach
the hub's port can read, write and delete anywhere in the project directory. The hub binds
`127.0.0.1` by default, which is what makes this reasonable. Binding it to `0.0.0.0` exposes your
project's files to the whole network. There is a Host and Origin check that stops a hostile web page
in your own browser from reaching the hub, but it does not stop a direct request.

[App mode](app-mode.md) does not serve any of these routes, so a visitor to an app or a
[workbook](app-mode.md#Workbook-mode) has no file access at all.

## See also

- [Notebook Basics](notebook-basics.md) for the notebook itself
- [Live Updates](live-updates.md) for `@asset` and cells that react to a file
- [Front-end Extensions](frontend-extensions.md) for keeping web-cell JavaScript and CSS in real files
- [Editing project source](hot-reload.md) for what happens after you save package source
- [Packages](packages.md) for the project's environment
