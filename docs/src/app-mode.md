# App Mode

Slate's normal posture is an **authoring** environment: every cell is editable, the agent is a click
away, and the package tree is reachable from the Files panel. That is exactly wrong when the audience
is a domain expert who was handed a URL and told to use the tool. They need the controls and the
results — and nothing that can put the document into a state they can't recover from.

App mode is that second posture. The notebook still runs live: sliders move, fits recompute, figures
redraw. What's gone is everything that edits it.

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

## Presentation defaults

[`app_defaults`](@ref) sets what a visitor sees *before* expressing a preference of their own:

```julia
export_app(nb, dir; appdefaults = app_defaults(theme = "midnight", pagewidth = 1400))
```

These are defaults, not enforcement. A visitor who has chosen keeps their choice — the app's settings
popover offers the same reader-facing subset, and `localStorage` still wins.

## What a visitor cannot do

The lockdown is a server-side **allowlist** of `(method, path)` patterns, not a list of dangerous
routes to exclude. A denylist over ~130 routes is a standing invitation to a miss: every new
authoring endpoint would be reachable until someone remembered to exclude it, and the failure would be
silent. An allowlist fails the other way — a new route is unreachable in app mode until it is
deliberately added, which is the direction a lockdown should fail in.

So a visitor cannot edit a cell, install a package, reach the filesystem, talk to the agent, or
publish, because **those routes are not served at all** — not merely hidden in the UI.

The agent is off by default for the same reason; pass `agent = true` to `export_app` if an app's
readers genuinely need it.

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
- [Publishing](publishing.md) — putting a rendered document on the web, for reading rather than use
- [Widgets & `@bind`](widgets.md) — the controls an app's visitor drives
