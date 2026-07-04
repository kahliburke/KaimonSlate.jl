# Design: first-class web assets in a notebook (HTML/CSS/JS with reactive tracking)

Status: **proposal / for review** — no code yet.
Author context: written after diagnosing the Portfolio.jl front page (`~/devel/Portfolio.jl/notebooks/portfolio.jl`).

## 1. Motivation — what's janky today

The portfolio front page assembles a custom HTML page in one cell:

```julia
asset(f) = read(joinpath(pkgdir(Portfolio), "src", f), String)
boot(js)  = "<img ... onload=\"Function(new TextDecoder().decode(
             Uint8Array.from(atob('<base64 of js>'),c=>c.charCodeAt(0))))()\"/>"
HTMLDoc(string("<style>", asset("portfolio.css"), "</style>",
               boot(asset("portfolio.js")), asset("portfolio.html")))
```

Three distinct problems:

1. **The `<img onload>`+base64 boot is unnecessary.** Its comment claims a plain
   `<script>` won't run under Slate's `innerHTML` injection. That is no longer true:
   `runScripts()` in `src/assets/js/view.js:580` already re-creates every `<script>`
   in a cell's output so it executes (and awaits `<script src>` bundles before inline
   init — it's how WGLMakie/Bonito figures boot). A cell can emit
   `<style>…</style><div>…</div><script>…</script>` directly.

2. **No dependency tracking (the real defect).** `asset(f)` reads the files at
   cell-run time; those files are invisible to Slate's reactivity. Editing
   `portfolio.js` does **not** mark the cell stale, so it isn't re-run — and a
   subsequent publish ships stale output. This is the bug we chased (the live site
   served old JS while the branch was current). `runScripts` does not help here.

3. **Hand-rolled per notebook.** Every notebook that wants custom HTML reinvents
   `asset()` + `boot()` + escaping. No reuse, no asset serving, no caching, no source maps.

## 2. Goals / non-goals

**Goals**
- A cell can include external asset files (JS/CSS/HTML, and arbitrary data files)
  with **reactive dependency tracking**: edit the file → the cell re-runs → the live
  page updates, with no manual re-run and no staleness.
- **Clean authoring** — no boot hack, minimal escaping burden.
- **Real asset URLs in the live view** (cacheable, debuggable, source maps).
- **Self-contained static export**, with a choice of packaging: real files (copied),
  plain inline, or **base64-obscured inline** ("curtains" — see §5.5). A single portable
  `index.html` with no external requests is a first-class supported output, because that's
  ideal for GitHub Pages and other static hosts.
- The dependency also invalidates the durable **memo** cache (no stale restore).

**Key reframing (separate two things the old boot hack conflated):**
- *Script execution* under Slate's live `innerHTML` injection — solved by `runScripts`
  (view.js). Needed only in the live view; a plain `<script>` now runs. Drop the `<img
  onload>` smuggling.
- *Self-contained + obscured output* — the base64 part. Genuinely useful; keep it as an
  explicit **export packaging mode**, not an authoring requirement. In a static exported
  page there is no `innerHTML` injection, so even the obscured form needs no image hack —
  a plain `<script>Function(atob('…'))()</script>` executes natively.

**Non-goals (for now)**
- A bundler/transpiler (TS/JSX). Assets are served/inlined verbatim.
- npm/module-graph resolution. `<script type=module>` + import maps are the user's call.
- Hot-module-replacement semantics beyond "re-run the cell".

## 3. Architecture — two composable pieces

- **(A) File-dependency tracking** — a runtime primitive: a cell reads a file *and*
  registers it as a reactive dependency. Generally useful (data files, templates,
  shaders, CSVs), and it is the piece that actually fixes the staleness bug.
- **(B) `WebPage` display + per-notebook asset route** — ergonomic sugar over (A) for
  the HTML/CSS/JS case, with context-dependent rendering (asset URLs live, inlined on export).

(A) is the foundation and ships first; (B) is built on it.

---

## 4. Piece A — file-dependency tracking

### 4.1 Author API

Primary form — a macro over a **literal** path:

```julia
@asset "portfolio.js"            # -> String; registers a STATIC file-dep on that path
@asset bytes "logo.png"          # -> Vector{UInt8}
```
Because the path is a string literal, the dependency is visible in the cell **source**, so
Slate's dependency analyzer can extract it **statically** (like `reads`/`writes`) — *without
running the cell*. That means the watcher can arm on open and the memo key is correct on
cold start, with **no persisted derived state and no `.jl` git noise** (resolves O2 for the
common case).

Runtime form — for computed paths:

```julia
Slate.readfile(path; bytes=false) -> String | Vector{UInt8}
Slate.depend(path)               # register a dep without reading (read by other means)
```
`readfile`/`depend` resolve relative to the **notebook's directory** unless absolute, and
register the dep at **run time** (discovered post-run — see §4.5 for the cold-start caveat
that only affects the dynamic form). Outside Slate, both degrade to a plain read/no-op.

Paths resolve relative to the notebook dir; `@__DIR__`-style project-relative access is
available via `@asset`'s macro expansion (it knows the notebook context).

### 4.2 Capture — how the dependency is recorded

The worker already tags each eval with `filename = "cell:<id>"` and captures a wire
NamedTuple (`binds`, `reads`, `writes`, `stdout`, …; see `worker.jl` `_eval_one`). Add:

- A task-local (or `_NS`-scoped) `Ref{Vector{String}}` "current cell's file deps",
  reset at the start of each `_eval_one`.
- `Slate.readfile` pushes the resolved absolute path into it.
- The wire capture gains a `filedeps::Vector{String}` field (absolute paths).

Server side (`eval.jl`/`server.jl`): store `cell.filedeps` (paths made **relative to the
notebook dir** for persistence + portability) after each run, alongside `reads`/`writes`.

### 4.3 Reactive re-run (watcher-driven — the live UX)

A worker-side watcher already exists (`slate hot-reload: watcher started`). Extend it to
watch declared asset files using **filesystem events** (`FileWatching.watch_file` /
`watch_folder`) — not mtime polling — so edits register immediately with no poll latency or
idle wakeups:

- Maintain the union of open cells' asset deps (statically-extracted `@asset` paths +
  runtime-discovered `readfile` paths) as the watch set; watch each file's containing
  directory (editors write via rename/replace, which a bare `watch_file` can miss — watch
  the dir and filter by basename).
- On a change to file `F`: emit a stream event (the gate stream already carries
  `slate_refresh` for async cells — reuse it) naming the changed file.
- Server maps `F → cells whose deps contain F`, marks them stale, and triggers the normal
  reactive recompute (`run_cell`) — which re-reads `F` and produces fresh output.

Result: edit `portfolio.js`, the page re-renders live. No manual re-run.

> O1 decided: **FS events via `FileWatching`** (watch the dir, filter by name — robust to
> editor rename-on-save), debounced (~50–100 ms) to coalesce multi-write saves.

### 4.4 Memo interplay (no stale restore on cold start)

`_memo_key` (`eval.jl`) currently folds: cell source + transitive upstream sources +
`@bind` values; the worker folds in `_src_digest` + `_manifest_digest`.

Add the cell's **file-dep content hashes** to the key, hashing the files' **current**
contents at key-computation time:

```
_memo_key = hash(source, trace, upstream_srcs, binds,
                 [(relpath, xxhash(read(abspath))) for relpath in cell.asset_deps])
```

Where `cell.asset_deps` comes from:
- **`@asset` (static):** extracted from the cell source by the dep analyzer — known before
  the first run, so the key is correct even on a cold reopen where the asset changed while
  closed. No persistence needed. **This is the recommended path.**
- **`readfile`/`depend` (dynamic):** discovered post-run, so on the very first run the key
  omits them (runs, records them); a later reopen re-hashes the recorded paths. If a dynamic
  path's file changes while closed *and* the cell hasn't recorded it yet, a stale restore is
  possible — the caveat that makes `@asset` preferable.

The **live** edit path never relies on memo (the watcher forces a real re-run), so this only
guards cold starts.

### 4.5 Persistence / footer

`cell.filedeps` (relative paths) persist with the cell (same bucket as other derived cell
metadata). They are *derived* (re-discovered on run), so losing them just costs one extra
run — acceptable. Keep them out of the visible `.jl` source if they add git noise; a
regenerated-on-run field is fine to omit from the file and recompute.

> Open question O2: persist filedeps in the `.jl` (so a fresh clone tracks deps before the
> first run) or treat as pure runtime state? Leaning runtime-only.

---

## 5. Piece B — `WebPage` display + asset serving

### 5.1 Author API

```julia
Slate.WebPage(; html="portfolio.html", css="portfolio.css", js="portfolio.js",
                files=String[],           # extra assets to make available (images, data)
                pack=:auto)               # static-export packaging: :files | :inline | :obscure | :auto
```
Each of `html`/`css`/`js` may be a **path** (tracked via `readfile`) or an inline
`String`. `files` are additional assets served/copied but not auto-injected. `pack`
selects the **static-export** packaging (§5.5); it does **not** affect the live view, which
always uses real asset URLs for debuggability. Returns a display object;
`show(::MIME"text/html", ::WebPage)` handles rendering. Registers every source file as a
cell file-dep (§4).

### 5.2 The representation problem — live vs. export differ

The live page should reference **real URLs** (`/n/<id>/asset/portfolio.js`); the exported
page must be **self-contained** (inlined or copied). A single frozen `text/html` string
can't serve both. So `WebPage` is a **structured display type**, not an opaque blob:

- The cell output carries a structured chunk (proposed MIME
  `application/x-slate-webpage+json`) holding `{html, css, js, files}` as
  `{kind: path|inline, value, hash}` entries — enough to render either form.
- A `text/html` chunk is *also* emitted as the **live** rendering (asset-URL form) so
  existing rendering paths and non-Slate viewers still show something.

Renderers:
- **Live** (`render.jl` / frontend `_swapOutput`): use the asset-URL `text/html`
  (`<link href="/n/<id>/asset/portfolio.css">`, `<script src="/n/<id>/asset/portfolio.js">`
  — `runScripts` revives + awaits it), plus the `<div>` content.
- **Export/publish** (`export_html`, `_assemble_site!`): detect the structured chunk and
  **re-render inlined** — read each source, emit `<style>…</style>` / `<script>…</script>`
  (splitting any literal `</script>`), so the static page is self-contained. For a *site*
  export we may instead **copy** assets to `<slug>/assets/` and reference them (better
  caching); single-file HTML export inlines. (Decision O3.)

> This structured-display approach is the crux; it's why we want the design signed off
> before coding. The alternative — capturing two complete html strings (live + inlined) —
> is simpler but bloats the stored output and duplicates content.

### 5.3 Per-notebook asset route (live serving)

New route in `server_complete.jl`, mirroring the `/sites/**` guard:

```
GET /n/{id}/asset/{path...}
```
Resolves `{path...}` under the notebook's **asset root** (default: the notebook's dir;
optionally a declared `assets/` subdir), with a `..`-traversal guard identical to
`_site_file`. Content-type by extension (reuse `_site_ctype`). Cache-Control short/no-store
in the live view so edits show immediately (the file changed → new bytes).

Security: only files under the asset root; never escape it. Same model as `/sites/**` and
`/api/{id}/output/{name}` which already guard traversal.

### 5.4 Export & publish

- `export_html` / `_assemble_site!`: when a cell output has the WebPage structured chunk,
  emit it per the chosen packaging mode (§5.5) so the published `index.html` needs no live
  server.
- The `<img onload>` boot is gone from exported pages regardless of mode (a static page runs
  `<script>` natively).
- Publish already inlines other rich output; this fits the same pass.

### 5.5 Static-export packaging modes (`pack`)

The live view always references real asset URLs (§5.3). The **static export** picks how the
assets travel, since "self-contained + a bit obscured" is a legitimate production choice for
GitHub Pages and friends — not just a workaround:

- **`:files`** — copy assets next to the page (`<slug>/assets/portfolio.js`) and reference
  them with real `<link>`/`<script src>`. Best caching + source maps; multiple files.
- **`:inline`** — inline verbatim: `<style>…</style>` + `<script>…</script>` (splitting any
  literal `</script>`). One self-contained file, source readable.
- **`:obscure`** — inline **base64-encoded** and executed via a tiny bootstrap
  (`<script>Function(new TextDecoder().decode(Uint8Array.from(atob('…'),c=>c.charCodeAt(0))))()</script>`
  for JS; CSS via a decoded `<style>` injection). One self-contained file; the source is
  behind "curtains" — trivial to peel, but it doesn't *spill the magic* to a casual View-Source.
  This is the useful half of today's technique, kept as an explicit opt-in.
- **`:auto`** — default. Single-file HTML export → `:inline`; multi-doc *site* export →
  `:files`. Never `:obscure` unless asked (obscuring should be intentional).

`pack` can be set per `WebPage`, and/or as a publish/export-dialog default (persisted in the
`Slate.config` footer, e.g. `assetpack = obscure`) so a whole site publishes consistently.
Encoding/obscuring is a **packaging transform at export time** — the source files on disk and
the live view stay plain and debuggable.

### 5.6 Piece C — notebook-level modules & import maps

To let notebook front-end JS `import` libraries by name (`import * as d3 from "d3"`), the
import map must be in the document `<head>` **before** any module runs — so it can't come
from cell output (injected via `innerHTML`, too late). It's a **notebook-level** resource.

We already have the pieces:
- `assets/notebook.html` ships a base `<script type="importmap">` (Preact/signals/htm).
- A vendor cache serves + pins third-party libs (`/assets/vendor/**`, `server_hub.jl`,
  `vendor.json`) so the notebook works offline after one warm load.

Design:
- **Author API** — declare extra map entries + optional module preloads at the notebook
  level, e.g.
  ```julia
  @use "d3"    => "https://esm.sh/d3@7"          # merges into the import map
  @use "three" => "https://esm.sh/three@0.160"
  ```
  or a `Slate.imports(Dict(...))` call / a `Slate.config` block. These register into
  **notebook metadata** (not cell output).
- **Live injection** — the `/n/{id}` handler already reads the static `_ASSET`
  (`notebook.html`); template it per notebook to **merge** the author entries into the base
  importmap `<head>` before serving. (One import map per document — merge, don't add a second.)
- **Export injection** — `export_html` emits the merged import map into the exported page's
  `<head>` too, so a published static page resolves the same bare specifiers.
- **Vendoring vs CDN** — entries may point at a CDN (esm.sh — simplest for exports) or be
  pulled into the local vendor cache (offline, pinned) via the existing mechanism. This is
  the same surface as the parked *notebook-frontend-resources* work (pinned JS/WASM manifest
  → `window.NB`), so Piece C should converge with / subsume it rather than duplicate it.
- **Caveat** — inline `type=module` cell-output scripts execute on insert but their *load*
  can't be reliably awaited (per `runScripts`); for anything order-sensitive, use an
  external module `src` (awaited) or a page-level module preload.
- **Reload-to-apply (accepted).** The import map is fixed at document load, so **adding or
  changing a `@use` entry needs a page reload** to take effect. That's fine: changing *which*
  libraries you import is structural and rare (unlike editing JS *content*, which stays
  instant via the Piece-A watcher). UX: on a `@use` change, regenerate the shell head and
  show a "new imports — reload to apply" nudge (or auto-reload the tab). (Newer browsers
  allow multiple/late import maps, but relying on that is version-fragile; reload is the
  safe universal behavior.)

This is a later phase (the portfolio needs none of it); it's specced here so the API for
`@asset`/`WebPage` doesn't paint us into a corner.

---

## 6. Portfolio migration (the proof)

The `page` cell becomes:

```julia
Slate.WebPage(css="../src/portfolio.css",
              js ="../src/portfolio.js",
              html="../src/portfolio.html")
```

- Editing any of the three files live-refreshes the page (§4.3).
- Publish inlines them (self-contained), and — because the file-dep hash is in the memo
  key and the cell actually re-ran — the "no changes / stale JS" class of bug is gone.
- The `<img onload>`/base64/`TextDecoder` scaffolding is deleted.

Keep the current cell working until the helper lands; migrate as the last step.

## 7. Decisions & remaining discussion

- **O1 — DECIDED.** Watcher uses **FS events** (`FileWatching`): watch the dir, filter by
  name (robust to editor rename-on-save), debounced. (§4.3)
- **O2 — RESOLVED via O5, one open thread.** `@asset "literal"` makes deps **static**
  (source-extracted) → no persisted state, no `.jl` git noise, correct cold-start memo.
  Dynamic `readfile` keeps a documented cold-start caveat. **To discuss:** should we *also*
  persist dynamic-dep paths in the external per-notebook derived-state store (the parked
  git-noise **sidecar**) so dynamic deps are cold-start-correct too? Leaning **no in v1** —
  steer authors to `@asset`.
- **O3 — DECIDED.** Self-contained on by default; the **export dialog** exposes the mode
  (incl. an "obscure / curtains" toggle) and **persists it as a notebook setting**
  (`Slate.config: assetpack = …`). Default `pack=:auto` (inline for single-file, files for
  site); `:obscure` opt-in.
- **O4 — DECIDED (yes, live + export).** Support ES modules + import maps at the
  **notebook level** (Piece C, §5.6). This is small because the shell already has the
  machinery: `assets/notebook.html` ships an `<script type="importmap">` (Preact/signals/htm)
  and a vendor cache (`/assets/vendor/*`, pinned in `vendor.json`). Author entries **merge**
  into that map — injected into the served shell `<head>` per notebook (before any module
  loads) and into the export `<head>`. Per-cell-output module scripts still work via
  `runScripts` (execution is fine; inline-module *completion* can't be awaited — documented).
- **O5 — DECIDED.** Primary API is the **`@asset` macro**; `readfile`/`depend` are the
  runtime escape hatch. `WebPage` name kept (bikeshed if desired).

## 8. Phased plan

1. **Piece A core** — `@asset` macro + static dep extraction (`reads`/`writes`-style),
   `readfile`/`depend` runtime forms, wire `filedeps`, store on cell, memo-key fold. (No
   watcher yet: edits invalidate on next run/reopen.) Unit-testable without the browser.
2. **Watcher re-run** — extend the hot-reload watcher (`FileWatching`, dir-watch + debounce)
   → live auto-refresh on asset edit.
3. **Asset route** — `GET /n/{id}/asset/**` with traversal guard.
4. **Piece B** — `WebPage` structured display; live asset-URL render + export packaging
   modes (`:auto`/`:inline`/`:files`/`:obscure`), export-dialog toggle + notebook setting.
5. **Migrate portfolio**; delete the boot hack; document the pattern.
6. **Piece C (later)** — notebook-level import map / modules: `@use` (or config), merge into
   the shell + export `<head>`, converge with the notebook-frontend-resources manifest.

Each phase is independently shippable and testable; (1) alone already kills the staleness
bug, and (6) can land whenever module authoring is wanted.
```
