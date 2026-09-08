# App Mode

Slate's normal posture is an **authoring** environment: every cell is editable, the agent is a click
away, and the package tree is reachable from the Files panel. That is exactly wrong when the audience
is a domain expert who was handed a URL and told to use the tool. They need the controls and the
results — and nothing that can put the document into a state they can't recover from.

App mode is that second posture. The notebook still runs live: sliders move, fits recompute, figures
redraw. What's gone is everything that edits it.

![A notebook served as an app: title, prose, two sliders and the chart and table they drive, with no editors, no cell chrome and no toolbar](./assets/app-view.png)

## Serving an existing notebook as an app

App mode is a property of the **process**, not of the document. A hub started with `app = true`
serves its notebooks as applications and refuses the authoring API outright:

```julia
using KaimonSlate
hub = start_hub(; host = "127.0.0.1", port = 8080, app = true)
open_notebook!(hub, "notebooks/analysis.jl")
```

It is deliberately *not* a per-notebook footer flag. A document attribute is something an author
edits by accident, and "can this request mutate my notebook?" should not depend on a token inside the
file being served.

To preview the app view while authoring, append `?app=1` to a notebook URL on an ordinary hub. That
gives you the same **view** with none of the enforcement — useful for checking layout, not for
handing out.

## Shipping an app to someone else

[`export_app`](@ref) writes a self-contained folder you can copy to whichever machine will run it:

```julia
export_app(nb, "dist/band-deconvolution"; title = "band-deconvolution", port = 7373)
```

The folder holds the notebook's reproducible bundle plus launchers. The recipient needs only Julia
1.10+:

| | |
|---|---|
| macOS / Linux | `./run.sh` |
| Windows | double-click `run.bat` |
| any | `julia run.jl` |

The first run installs the application's packages and precompiles them — several minutes is normal.
Later starts are fast. Nothing waits on stdin, so it also runs unattended under systemd, in a
container, or as `nohup ./run.sh &`.

That first run needs network access. It fetches Slate itself into a shared environment and
instantiates the notebook's manifest. Once that has happened the app starts offline.

An app is not a separate export format. It **is** the standalone bundle; "app" is a posture the
launcher takes. Which is also why updating a deployed app is `export_app` again over the same folder
— the install detects that the bundle beside it has changed and refreshes in place, keeping whatever
the app accumulated next to it (its `datadir()`, saved results, caches).

### What ships

By default, the project's git-**tracked** files. That's the right default: it carries the source and
leaves out build output, scratch and stray artifacts.

`include` names extra project-relative paths to carry anyway. Reach for it when part of the app is
deliberately untracked — the common case being reference data under the notebook's `datadir()`, which
is git-ignored *by construction* (that directory self-ignores so a stray database is never
committed). An app whose samples live there arrives unable to load them:

```julia
export_app(nb, dir; include = ["assets/spectra"])
```

A project with **no commits** has no tracked files at all, so the bundle falls back to a partial copy.
`export_app` warns when it sees that, because the result looks fine until it is deployed.

### Cells that run on a region

A cell tagged `region=<name>` runs on a named compute target. The tag travels in the notebook, but
the *definition* — host, transport — lives in your region registry, and an app keeps its own state
home rather than reading yours. So `export_app` writes the definitions the notebook actually uses
into a `regions.json` beside the launcher, and `run.jl` seeds them into the app's home on first
start. Nothing else from your registry travels.

Two things follow, and `export_app` logs the hosts it embedded so neither is a surprise:

- **The host name is in the exported folder.** No keys or credentials travel, but if you hand the
  app to someone they can read where its region cells run. Untag the cells if that matters.
- **The app needs to reach that host itself**, over SSH, as whoever runs it. On your own machine
  that already works. Elsewhere it will not, and the cell reports that it could not be placed
  rather than appearing to hang.

An operator can point the app somewhere else: define the same region name in the app's own home and
it is used as-is — seeding only fills a home that has no registry of its own.

## Presentation defaults

[`app_defaults`](@ref) sets what a visitor sees *before* expressing a preference of their own:

```julia
export_app(nb, dir; appdefaults = app_defaults(theme = "midnight", pagewidth = 1400))
```

These are defaults, not enforcement. A visitor who has chosen keeps their choice — the app's settings
popover offers the same reader-facing subset (theme, page width, and the
[chart renderer](settings.md#Chart-renderer)), and `localStorage` still wins.

## Workbook mode

A course notebook is an app in every respect but one: some cells are the reader's to write. Workbook
mode opens exactly those cells and leaves the rest of the document read-only.

Mark a cell by adding the `workbook` tag to its header:

```julia
#%% code id=ex_double workbook
function double(x)
    missing
end

#%% code id=try_double workbook
double(21)

#%% code id=chk_double
isequal(double(21), 42)
```

The check cell carries no tag, so the reader cannot rewrite the test that grades them. It uses
`isequal` because an unimplemented stub returns `missing`.

There is no checkbox for `workbook` in the 🏷 tag popover. Type it into the `#%%` header, or add it
through the popover's "add custom tag" input.

### Serving one

Workbook mode is a property of the process, like app mode, and it is refused without it:

```julia
hub = start_hub(; port = 8080, app = true, workbook = true)
```

`workbook = true` on its own throws. A document can never turn an ordinary hub into a workbook by
carrying a tag.

To ship one, tick **Workbook** in the Export dialog's App format, or pass the keyword:

```julia
export_app(nb, "dist/exercises"; workbook = true)
```

Preview either posture while authoring by appending `?app=1` or `?app=1&workbook=1` to a notebook
URL. As with the app preview, that gives you the view and none of the enforcement.

![The same document served as a workbook: the read-only cells render as prose and output, while the exercise cells below them are editable](./assets/app-workbook.png)

### What the reader gets

Tagged cells come back as editors, framed and labelled "your turn". Each one has **Run** and
**Reset to the original**. Running an exercise also saves it, so the reader's work survives a reload.

![A workbook exercise cell: an accent-bordered frame labelled YOUR TURN, an editable stub function, its output, and Run and Reset to the original buttons](./assets/workbook-cell.png)

They also get a scratchpad for working out an answer before committing it (⌘⇧S, or the floating 🧪
launcher), which never touches the document. The command palette returns with a reader-only command
list: search the docs, settings, scratchpad, table of contents, run stale cells, jump to a cell.
Editor preferences (keymap, syntax theme, wrap) appear in the settings popover.

**Reset** restores the cell as the author shipped it. That original has to be stored separately,
because saving a workbook is the ordinary notebook save and the reader's answers overwrite the served
`.jl`. `export_app` writes a second pristine copy of the bundle into the folder and points the
launcher at it, which roughly doubles the exported folder's size. Serving a workbook by hand instead
of from an export needs the same copy, either at `SLATE_WORKBOOK_ORIGINAL` or as a sibling
`.<notebook>.jl.original`. Without one, Reset reports that it has no original on file.

### A workbook is not a sandbox

A workbook reader runs their own code in the notebook's Julia worker. That is the point of the
exercise, and it means the reader has arbitrary code execution with that process's filesystem,
network and credentials. The scratchpad grants the same thing with no cell check at all.

Combined with [there being no authentication](#Access-control) and `run.jl` binding `0.0.0.0` by
default, a workbook on a shared address is a remote shell for anyone who can reach the port.

There is also one document and one worker. Two readers on the same deployed workbook overwrite each
other's answers. The deployment this is built for is one bundle per reader, running on their own
machine, where they could equally well open a REPL.

## What a visitor cannot do

The lockdown is a server-side **allowlist** of `(method, path)` patterns, not a list of dangerous
routes to exclude. A denylist over ~130 routes is a standing invitation to a miss: every new
authoring endpoint would be reachable until someone remembered to exclude it, and the failure would be
silent. An allowlist fails the other way — a new route is unreachable in app mode until it is
deliberately added, which is the direction a lockdown should fail in.

So a visitor cannot edit a cell, install a package, reach the filesystem, talk to the agent, or
publish, because **those routes are not served at all** — not merely hidden in the UI.

A workbook widens that allowlist by seven routes: edit one cell, run, completions, the two scratchpad
routes, fetch a cell's original, and docstring lookup and search. Reaching a route is not authority to
use it. The cell id rides in the path, and the two routes that take one check it against the
document's `workbook` tags before doing anything. A request for an untagged cell is refused with a
403 naming the route.

The agent is off by default. Pass `agent = true` to `export_app` if an app's readers genuinely need
it. The Export dialog cannot turn it on, so that path is the Julia function only.

## Getting data in and out

[`FileUpload`](widgets.md) is how a reader gets data in: the file lands in the notebook's
[data directory](project-files.md#The-data-directory) and binds as a path your cells can read. It is
one of the few write paths app mode allows.

[`download_button`](live-updates.md#Writing-files-out) is how they leave with a result. An app's
reader has no cell to run and no filesystem to look in, so anything they are meant to keep needs an
explicit way out. It works live, in a static export, and on a published page.

## Access control

There is **no authentication**, at any bind address. Anything that can reach the port can drive the
app and read its results. Treat "who can reach this port" as the entire access-control story.

`run.jl` binds `0.0.0.0` by default — reachable from the whole network, which is the point of putting
it on a shared lab machine, and which also means nothing stands between the network and the app. Bind
it to one machine with:

```
./run.sh --host 127.0.0.1 --port 9000
```

| variable | what it does |
|---|---|
| `--port` / `SLATE_PORT` | the port to serve on |
| `--host` / `SLATE_HOST` | the address to bind |
| `SLATE_ALLOWED_HOSTS` | extra names people will type (a DNS alias, a proxy); this machine's own names are admitted automatically |
| `SLATE_INSTALL_DIR` | where to unpack the application (default: `.app` beside the launcher) |

## When something goes wrong

Open `/status` on the same address. The operator page shows whether the server and its worker process
are healthy, how long they've been up, how much memory they are using, any step that failed with its
error message, and the worker's log. It is one of the few non-notebook routes app mode serves, because
the person running the app is often not the person who wrote it.

## See also

- [Export](export.md) — static HTML, PDF and the standalone `.jl` bundle this builds on
- [Offline interactivity](replay.md) — keeping controls working with no server at all, which is the
  other way to hand someone a document they can drive
- [Publishing](publishing.md) — putting a rendered document on the web, for reading rather than use
- [Widgets & `@bind`](widgets.md) — the controls an app's visitor drives
