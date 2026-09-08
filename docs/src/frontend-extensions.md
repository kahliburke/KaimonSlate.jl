# Front-end Extensions

A Slate notebook is a live web page, and you can extend it with your own front-end code: ship
JavaScript, CSS, and ES modules, call Julia from the browser (and stream results back), and add
custom `@bind` widgets or editor behaviour. Everything here behaves the same in the live notebook
and in an [exported or published](export.md) page — the script is revived on load, and imports and
assets travel with the file.

## Delivering front-end code

### Web cells — HTML, CSS, and JS with live interpolation

A **web cell** is a first-class cell kind (alongside code and markdown) for writing a piece of the
page directly. It has three panes — **HTML**, **CSS**, and **JS** — and pulls in live notebook values
with `{{ }}` interpolation, the same as a markdown cell:

```julia
#%% web
@web(
    html"""<div id="wave">frequency {{ freq }}</div>""",
    css"""#wave { font: 600 1.5rem system-ui; color: {{ color }} }""",
    js"""
      const f = {{ freq }};                 // interpolated as a JSON literal
      root.querySelector("#wave").textContent = `frequency ${f}`;
    """,
)
```

The JS pane runs with three things of its own:

- **`root`** — the cell's own output element. Query and append inside it, so two cells running the
  same code cannot reach into each other.
- **`echo(…)`** — print a line into the cell and the browser console.
- **top-level `await`** — `await import(…)`, `await window.slateCall(…)`.

An error thrown or a promise rejected in the pane renders onto the cell.

![A web cell with its HTML, CSS and JS panes stacked above the rendered output: interpolated notebook values, a root.querySelector call, an echo line, and the bar chart the JS drew](./assets/web-cell.png)

- **It's reactive.** The variables inside `{{ }}` are the cell's inputs, so the web cell re-renders
  whenever they change — drag a `@bind freq` slider and the markup updates live, with no `slateCall`
  needed for a simple readout.
- **Interpolation is escaped per pane**, so a value can't break out of its context: HTML values are
  entity-escaped, CSS values are reduced to a safe token, and JS values become a JSON literal (safe
  even inside `<script>`). `$` and `${…}` stay literal in the JS pane.
- On disk the cell is a runnable `@web(html"…", css"…", js"…")` skin (serialized under `#%% web`) that
  **evaluates to a `WebPage`** — so it behaves the same live and in an [export](export.md). The JS pane
  uses the same `window.slate*` API as the rest of this page to call Julia, stream values, or register
  widgets.

### `WebPage` — build the same output from Julia

`WebPage` is the value a web cell produces, and you can also construct it directly and return it from
a **code** cell — handy when the markup is assembled programmatically or loaded from `@asset` files:

```julia
WebPage(; html = "", css = "", js = "", obscure = false)
```

```julia
#%% code id=clock
WebPage(
    html = """<div id="clock" style="font: 600 2rem system-ui"></div>""",
    js   = """
      const el = document.getElementById("clock");
      setInterval(() => el.textContent = new Date().toLocaleTimeString(), 1000);
    """,
)
```

The `<script>` runs live (revived by the front end) and in a static export (natively, no external
requests) — the output is identical either way. Empty `css`/`js` sections are omitted. `obscure =
true` base64-packs the JS so it isn't visible in a casual View-Source (trivially reversible; the
files on disk stay plain).

!!! tip "Keep the source on disk"
    Pass the pieces via `@asset` so the JS/CSS/HTML stay in real files — tracked, debuggable, and
    re-run when you edit them:
    ```julia
    WebPage(css = @asset("app.css"), js = @asset("app.js"), html = @asset("app.html"))
    ```

### `@asset` — ship a tracked file

`@asset "path"` reads a file relative to the notebook's project dir and returns its **contents** as a
`String` (`@asset bytes "path"` → `Vector{UInt8}` for binaries). Because the path is a source
literal, the file is a first-class reactive input: edit it on disk and the reading cell re-runs. See
[Live updates → Reacting to files](live-updates.md#Reacting-to-files-—-@asset). For a *computed* path,
use `readfile(path)` (not statically tracked — no cache-fold, no watcher).

### `@use` — import an ES module

`@use "name" => "url"` (or `@use "name" "url"`) declares a browser ES-module import, merged into the
page's single import map. Your front-end JS can then `import` the bare specifier — live and in
exports:

```julia
#%% code id=confetti
@use "canvas-confetti" => "https://esm.sh/canvas-confetti@1"
```
```julia
#%% code id=celebrate
WebPage(js = """
  import("canvas-confetti").then(m => m.default());
""")
```

Use dynamic `import()`, not a top-level `import` statement. A notebook's JS runs as a classic
script, so a static import is a syntax error and the cell renders an error block instead. The import
map resolves the bare specifier either way. A web cell's JS pane supports top-level await, so there
you can write `const confetti = (await import("canvas-confetti")).default;`.

`@use` is a no-op at runtime — only the literal string pair is extracted, so both arguments must be
literals. Adding a **new** specifier reaches an already-open page, because the import map is extended
in place. Re-pointing a specifier the page has already declared needs a reload: once declared, a
specifier cannot be redefined. Editing the JS that uses it is instant either way.

## Talking to Julia from the browser

Two channels connect your front-end JS to the running notebook: a request/reply call, and a one-way
stream. Both ride one persistent, auto-reconnecting WebSocket per notebook, and both are
region-transparent.

### Call Julia and get a value back — `slateCall` / `slate_on`

Register a handler in Julia with `slate_on`, then call it from JS with `window.slateCall`:

```julia
#%% code id=stats
slate_on("stats") do args          # args is a NamedTuple: (n = 1000,)
    xs = randn(args.n)
    (mean = sum(xs) / length(xs), max = maximum(xs))
end
```
```js
const r = await window.slateCall("stats", { n: 1000 });
// r === { mean: …, max: … }
```

- The handler receives the JS args **decoded to a `NamedTuple`** (Symbol keys; arrays become
  `Vector`s), and whatever it returns is JSON-encoded back — return a `NamedTuple`, `Dict`, `Vector`,
  or scalar and read it as a plain JS value.
- `slateCall` returns a `Promise` that resolves to that value and **rejects** if the handler throws,
  the channel isn't registered, the call times out (35 s), or the socket drops (just call again — it
  reconnects).
- Handlers run on the worker's interactive thread, so they stay responsive during a compute batch.
  One handler per channel; re-running the cell replaces it.
- A fourth argument sends **raw binary**: `slateCall(channel, args, onProgress, buffers)` ships each
  `ArrayBuffer` or typed array in `buffers` as a binary WebSocket frame ahead of the call, and the
  handler reads them as `args.__slate_buffers`, a `Vector{Vector{UInt8}}`. No base64 anywhere.
  Going the other way, `slate_emit` of a `SlateBinary` arrives at the `slateOnStream` handler as
  `{…meta, d: TypedArray, dims}`.

### Stream progress during a call

For a long call, report progress *while it runs*. Give `slate_on` a **two-parameter** handler — it
receives a `progress` closure alongside the args — and pass an `onProgress` callback as the third
argument to `slateCall`. Each `progress(…)` is delivered to that callback, correlated to this exact
call; the `Promise` still resolves with the final return value.

```julia
#%% code id=region_stat
slate_on("region_stat") do args, progress
    n = 20
    for i in 1:n
        progress((done = i, of = n))     # streamed to onProgress during this call
        sleep(0.1)
    end
    (mean = 0.5, max = 0.99)             # the resolved value
end
```
```js
const r = await window.slateCall("region_stat", { region: "gpu" }, p => {
  bar.style.width = `${(100 * p.done / p.of).toFixed(0)}%`;   // p === each progress((done, of))
});
// r === { mean: …, max: … }
```

The one-argument handler form (`slate_on("ch", args -> …)`) keeps working unchanged; the second
parameter is opt-in. `onProgress` is optional on the JS side, and any progress frames that arrive
after the reply (or a timeout) are ignored.

### `slateTask` — a call with progress and status, as one signal

`slateTask` wraps a progress-reporting call in a small state machine so the UI can render it
directly, and **supersedes** an in-flight run when you start a new one (the last run wins). It's the
ergonomic layer over `slateCall(channel, args, onProgress)`.

It is not built in. It ships as a small module with the examples, which you copy into your notebook's
project directory and import:

```js
const { slateTask } = await import(location.pathname + "/asset/webassets/slatetask.js");

const t = slateTask("region_stat");   // one task, reused across runs
await t.run({ region: "gpu" });       // start (or restart, superseding any in-flight run)
```

`t.state` is a single signal holding the whole state, so one subscription covers every transition:

```js
t.state.value.status     // "idle" | "loading" | "done" | "error"
t.state.value.progress   // the latest payload from progress(…), or null
t.state.value.result     // the resolved value once status is "done"
t.state.value.error      // the error string once status is "error"
```

Reach for `slateTask` when a control should kick off a Julia computation and show live progress then
a result (a "run" button, a region probe); use bare `slateCall` for a plain request/reply.

### Push values into the page — `slate_emit` / `slateOnStream`

`slate_emit` pushes values from Julia to the browser with no cell recompute — a broadcast stream,
independent of any call:

```julia
#%% code id=ticker
for i in 1:100
    slate_emit("tick", (i = i, v = rand()))
    sleep(0.1)
end
```
```js
const stop = window.slateOnStream("tick", d => {
  console.log(d.i, d.v);            // d is the emitted NamedTuple
});
// stop();                          // or window.slateOffStream("tick")
```

Pass any JSON-serializable value (a `NamedTuple`/`Dict`/`Vector`/scalar) — the value itself, not a
pre-encoded JSON string. `slateOnStream` returns an unsubscribe function; one handler per channel, so
a re-rendered cell re-registers and replaces the previous one. For bulk data, publish it as an asset
rather than emitting it.

### Shipping generated data to the browser

`save_asset(name, data)` in Julia publishes generated bytes, a numeric array, or any JSON-able value
as a cell asset and returns a ref. The browser reads it back with `await Slate.asset(ref)`, where a
numeric array comes back as a decoded typed array with its shape, or resolves a file's URL with
`Slate.assetUrl("webassets/foo.js")`. Both work live and in a static export, where the bytes ride
along inside the page. See [Live Updates](live-updates.md#Writing-files-out).

## Extending the UI

### Custom `@bind` widgets — `slateRegisterWidget`

Register a JavaScript implementation for a widget `kind`, then bind it from Julia like any built-in
control:

```julia
#%% code id=answer
@bind answer custom_widget("mathfield"; label = "your answer")   # default ""; kwargs → params
```

```js
window.slateRegisterWidget("mathfield", {
  // Build the control's DOM in `el`; push values to the bound variable via `api`.
  wire(el, api) {
    const input = document.createElement("input");
    input.value = api.value ?? "";                        // the value at mount time
    input.oninput  = () => { api.mirror(input.value); api.schedule(input.value); };   // throttled
    input.onchange = () => api.flush(input.value);                                    // send now
    el.appendChild(input);
  },
  // Reflect a value pushed from elsewhere (another control, a re-run). Optional.
  sync(el, value) { const i = el.querySelector("input"); if (i && i.value !== value) i.value = value; },
  // Free resources before the element is discarded. Optional.
  destroy(el) { el.innerHTML = ""; },
});
```

`wire(el, api)` owns `el` entirely (no built-in input wiring is added). The `api` object gives you:

| `api` field | |
| --- | --- |
| `value` | the control's value at mount — build the initial DOM from it |
| `push(v)` / `flush(v)` | send `v` to the `@bind` variable **now** (dependent cells recompute) |
| `schedule(v)` | send `v` **throttled** (coalesced — one recompute per interval, for drags/typing) |
| `params` | the widget's params (the `custom_widget` kwargs) |
| `name` / `bindId` | the bound variable name and its bind cell id |
| `mirror(v)` | update the value-mirror text beside the control |

Register the widget at notebook load (in a `WebPage` or an `@asset`ed script). Any `custom_widget`
whose `kind` matches picks it up, and reading `answer` in another cell recomputes it when the widget
pushes a new value.

### Cell toolbar buttons — `slateRegisterCellAction`

```js
window.slateRegisterCellAction({
  id: "mypkg-convert",
  icon: "⇄",
  title: "Convert this cell",
  show: cell => cell.kind === "code",
  onClick: (cellId, cell, event) => { /* … */ },
});
```

Adds a button to every cell's action strip. `id` deduplicates, so re-registering replaces rather than
stacks; `show(cell)` gates it per cell. Package authors have a Julia wrapper,
[`register_cell_action!`](extensions.md).

### Editor extensions — `slateRegisterEditorExtension`

Add a CodeMirror 6 extension to every cell editor:

```js
window.slateRegisterEditorExtension(ctx => {
  if (ctx.markdown || ctx.lang) return [];         // ctx = { markdown, cellId, lang } — Julia cells only
  return window.CM6.keymap.of([
    { key: "Ctrl-Alt-l", run: view => { console.log(ctx.cellId, view.state.doc.length); return true; } },
  ]);
});
```

`fn(ctx)` returns one CM6 extension or an array (a returned keymap takes precedence over the
defaults). `window.CM6` is the bundled CodeMirror surface (`keymap`, `EditorView`, `Decoration`,
`StateField`, …). Register before cells hydrate; editors that open later pick it up, and already-open
editors reconfigure immediately.

Every editor is consulted, a web cell's HTML, CSS and JS panes included. `ctx.lang` is how you tell
them apart: it names the pane's language and is undefined for a Julia cell editor, so the check above
is what "Julia source only" looks like. A pane carries no cell id.

## See also

- [Widgets & @bind](widgets.md) — the built-in controls that `custom_widget` extends.
- [Live updates](live-updates.md) — `@reactive`, `@onclick`, and `@asset` file watching.
- [Export](export.md) — how `WebPage`, `@use`, and `@asset` travel in a self-contained page.
