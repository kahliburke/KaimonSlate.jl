# Writing an Extension

An **extension** is an ordinary Julia package that teaches Slate something new: a `@bind` control
of your own, a rich rendering for your types, a front-end library, a toolbar button, a JS↔Julia
channel. Notebook authors just `using YourPackage` — everything else wires itself up.

Extensions build against **`SlateExtensionsBase`** (SEB), a small SDK in the General registry that
depends on nothing but `Base` and stdlib. Your package depends on SEB, *not* on KaimonSlate:

```julia-repl
pkg> add SlateExtensionsBase
```

That split is the point. KaimonSlate is a server, a hub, a worker pool and a browser front-end;
none of it belongs in the dependency tree of a package that only wants to describe a widget. SEB
is the contract, KaimonSlate is the implementation — the same relationship
`AbstractPlutoDingetjes` has with Pluto. A `@bind` control is already reduced to
`(kind, params, default)` by the time it crosses a process boundary, so the contract is all your
package needs.

!!! note "No boot cells"
    Everything here registers by **dispatch** (defining a method) or from your module's `__init__`.
    A notebook never calls a setup function in a cell above the thing that needs it, and nothing
    depends on cell order.

## A complete extension

Here is a whole working extension — a star-rating control. It ships in this repository as
[`examples/extensions/StarRating`](https://github.com/kahliburke/KaimonSlate.jl/tree/main/examples/extensions/StarRating).

```julia
module StarRating

using SlateExtensionsBase
export Stars

struct Stars
    max::Int
    label::Union{Nothing,String}
    default::Int
end
Stars(; max::Int = 5, label = nothing, default::Int = 0) =
    Stars(max, label === nothing ? nothing : String(label), clamp(default, 0, max))

# Reflect the struct into its wire Widget: `default` becomes the bound value, the other
# fields become display params, under the type-derived kind "StarRating.Stars".
SlateExtensionsBase.to_widget(s::Stars) = auto_widget(s)

# The control's front-end. Slate loads it lazily, the first time a `Stars` is bound.
SlateExtensionsBase.required_assets(::Type{Stars}) = @pkg_asset("assets/stars.js")

end
```

with `assets/stars.js`:

```js
import { html, useSignal } from "@slate/widget";

export default ({ value, set, params }) => {
  const max = params.max ?? 5;
  const hover = useSignal(0);
  const lit = i => i < (hover.value || value.value);
  return html`
    <span style="display:inline-flex;gap:2px;cursor:pointer;font-size:1.4rem"
          onMouseLeave=${() => (hover.value = 0)}>
      ${Array.from({ length: max }, (_, i) => html`
        <span onMouseEnter=${() => (hover.value = i + 1)} onClick=${() => set(i + 1)}>
          ${lit(i) ? "★" : "☆"}
        </span>`)}
    </span>`;
};
```

A notebook then does:

```julia
using StarRating
@bind rating Stars(; max = 5, label = "How good?")
rating          # an Int in 0:5, reactive like any @bind
```

Two methods and a JS file. No `__init__`, no registration call, no kind string written twice.

## Controls (`@bind`)

### The wire spec

`@bind name x` calls [`to_widget`](@ref)`(x)`, which must return a `Widget` — a UI `kind`, a bag
of display `params`, and a `default` value. You can build one by hand:

```julia
SlateExtensionsBase.to_widget(m::Mathfield) = Widget(Mathfield, ""; label = m.label)
```

Passing the **type** rather than a string derives the kind from `Module.Type`
([`kind_for`](@ref)), so two packages can each ship a `Stars` without colliding, and there is no
string to keep in sync with your front-end registration.

When your struct's fields simply *are* its params, [`auto_widget`](@ref) reflects them: the
`default` field becomes the bound value, the rest become params, `nothing`-valued fields are
skipped. It is opt-in on purpose — Slate never reflects a struct into a control unless you ask.

### Values coming back

Browser values arrive as JSON. By default Slate coerces them to the type of your widget's
`default` and falls back to that default if coercion throws — so a `Stars` whose `default::Int`
gets `Int`-safe values with no lifecycle code at all. Teach it your own value type by adding a
[`coerce_value`](@ref) method:

```julia
SlateExtensionsBase.coerce_value(::Type{RGB}, v) = parse(RGB, string(v))
```

For bounds, declare a **domain** and let Slate derive both coercion and re-run behaviour:

```julia
register_kind!("StarRating.Stars"; domain = w -> 0:Int(get(w.params, "max", 5)))
```

[`register_kind!`](@ref) also takes raw `coerce` / `reconcile` / `wrap` closures for a fully
custom value lifecycle. Every argument is optional, and most typed widgets need none of them.

### The front-end contract

A component module default-exports a function of `{ value, set, params }`:

- `value` — a signal; read `value.value`.
- `set(v)` — commit a new value (this is what makes dependent cells re-run).
- `params` — the `params` bag from your `Widget`.

`import`s resolve against the page's import map, which serves Preact, htm, signals and
`@slate/widget` — pinned and offline-capable, so there is no build step and no CDN.

Prefer [`required_assets`](@ref) (lazy, dispatch-driven, shown above). The eager alternative is
[`register_component!`](@ref) from `__init__`, which is what you want if the front-end is not tied
to one widget type. For a plain `<script>` that calls `window.slateRegisterWidget` itself, use
[`register_widget!`](@ref).

## Rich output

To render one of your types richly when a cell *returns* it, define [`slate_render`](@ref). It
returns either a component descriptor or an HTML fragment:

```julia
SlateExtensionsBase.slate_render(v::MyView) = component(MyView; value = v.x, max = v.max)
SlateExtensionsBase.slate_render(r::Report) = html_fragment("<div class='report'>…</div>")
```

This deliberately does **not** hijack `text/html`, so your type still degrades to a sensible
representation in the REPL, IJulia or VS Code. The presence of a non-`nothing` method is the
detection — Slate's display capture prefers these over `text/html` and `text/plain`.

Returning a [`WebPage`](@ref) is the blunter option: CSS, HTML and JS strings composed into one
self-contained `text/html` output, identical live and in a static export.

## Shipping assets

| You have | Use |
|---|---|
| One component module for a widget type | [`required_assets`](@ref) |
| One script, not tied to a widget | [`provide_frontend!`](@ref) / [`register_component!`](@ref) |
| A directory — a library with workers, fonts, wasm | [`provide_assets!`](@ref) |
| A large blob shared across outputs, **live only** | [`provide_served_asset!`](@ref) |

Read files off disk rather than embedding JS in Julia strings, so your front-end stays a real
`.js` file you can lint and debug: [`@pkg_asset`](@ref) for a file, [`@pkg_dir`](@ref) for a
directory.

A vendored directory is served at `/ext-assets/<YourPackage>/…` while your package is loaded, and
is copied into static exports. Build the URLs with [`@ext_asset_url`](@ref) so they cannot drift
from what you declared:

```julia
function __init__()
    @provide_assets!(@pkg_dir("assets"))
end

const GL_URL = @ext_asset_url("echarts-gl/echarts-gl.min.js")
```

[`provide_served_asset!`](@ref) is for the other case: a big runtime that many outputs share. It
registers bytes at a content-addressed URL and returns the path. The bytes stay in the worker; the
hub fetches them once, by hash, and caches them immutably. That is how a multi-megabyte JS runtime
is served once per page instead of being inlined into every figure.

!!! warning "A served asset is live-only"
    Unlike the three mechanisms above it, `provide_served_asset!` has **no export path**. Its URL is
    answered by the running hub (`/n/<id>/served/<hash>`), which fetches the bytes from the live
    worker; a frozen export has neither, so the URL 404s in an exported or published page.

    That is a deliberate fit for its intended user — a session-bound output ([`slate_live_render`](@ref),
    e.g. a Bonito figure) is re-rendered per browser connection and never replayed into a static page
    anyway, so the runtime it loads has nothing to be exported *for*. But if your output is
    self-contained and you want it to survive an export, ship the bytes with [`provide_assets!`](@ref)
    instead: a vendored directory is rewritten to page-local siblings for a published site and inlined
    as `data:` URLs for a standalone page.

If a vendored library is far larger than what you use of it, [`js_bundle`](@ref) tree-shakes an ES
entry module with esbuild. It returns `nothing` on any failure — no node, no network, a bad entry
— so always keep a fallback. A smaller asset is an optimisation, and an export must not fail
because an optimisation was unavailable.

## Talking to the browser

Two symmetric calls, both no-ops outside a cell so package code can call them unconditionally:

```julia
slate_emit("ticks", data)              # Julia → JS; received by window.slateOnStream("ticks", …)
slate_on("compute", a -> f(a.x))       # JS → Julia; invoked by window.slateCall("compute", …)
```

For numeric streams, [`SlateBinary`](@ref) sends packed binary frames rather than JSON.

Register a per-cell resource's teardown with [`slate_on_cleanup`](@ref) — it runs before the cell
re-evaluates, when it is deleted, and before a namespace rebuild. The callback runs later, outside
any cell eval, so it must close over what it needs rather than reading the context:

```julia
sess = open_session()
slate_on_cleanup(() -> close(sess))
```

The rest of the context is readable through [`slate_context`](@ref) and its accessors —
[`slate_region`](@ref), [`slate_notebook`](@ref), [`slate_side`](@ref). Outside a Slate eval they
return `nothing` or empty values, which is what makes an SEB-based package testable with plain
`Test` and no server running.

## Package-global registration

Some things are not tied to a `@bind` or a returned value: an editor extension, a toolbar button,
an RPC handler. Those go in the `__slate_frontend` hook, which Slate calls once per notebook that
has your package loaded:

```julia
function __slate_frontend(slate_on)
    provide_frontend!(@pkg_asset("assets/tools.js"); id = "MyPkg.tools")
    register_cell_action!(InsertSnippetButton())
    slate_on("mypkg_convert", a -> Dict("out" => convert_it(String(a.src))))
end
```

Note that it takes `slate_on` as an argument: front-end scripts are process-global, but handlers
belong to a specific notebook's namespace. The hook must be **cheap and idempotent** — it runs
every drain, which is what lets it self-heal after a namespace rebuild. `provide_frontend!` dedups
by `id` and `slate_on` replaces by channel, so re-running it is a no-op.

Defining the method is also how Slate detects your package as an extension; a module without one
contributes nothing.

## Toolbar buttons

A per-cell toolbar button is authored exactly like a widget — a typed struct plus a
[`to_cell_action`](@ref) overload:

```julia
Base.@kwdef struct InsertSnippetButton
    icon::String    = "➕"
    title::String   = "insert a snippet"
    show::String    = "cell.kind === 'code'"
    onclick::String = "window._myPkgInsert(cellId)"
end
SlateExtensionsBase.to_cell_action(b::InsertSnippetButton) = auto_cell_action(b)
```

`show` and `onclick` are raw JavaScript your extension owns — `show` a boolean expression over
`cell`, `onclick` statements with `cellId`, `cell` and `event` in scope. The id is derived from
the type, so it is namespaced to your package.

## Lifecycle hooks

Long-lived state needs to know when the ground shifts underneath it:

- [`on_live_reset`](@ref) — a new browser page attached to the same worker (a reload, a second
  tab). Reset per-page state so the re-render starts clean.
- [`on_worker_reset`](@ref) — the worker was replaced or its namespace rebuilt. Everything the
  extension established in the old process is gone.
- [`slate_live_render`](@ref) — mark a value whose content lives in a per-browser session rather
  than in captured HTML, so Slate re-renders it for each page that connects instead of replaying a
  stored fragment.

## Publishing

Nothing about an extension is special to Pkg — it is a normal package. If you register it in
General, a user needs only `pkg> add YourPackage`. Extensions that aren't public can go in a
private repository and a registry of their own; see [Installation](installation.md#Extension-packages).

For a `[compat]` entry, pin the SDK:

```toml
[compat]
SlateExtensionsBase = "0.9"
```

## Worked examples

Three extensions ship in this repository, in rough order of complexity:

- **StarRating** — a typed `@bind` control, a lazily-loaded component, a toolbar action and an
  editor extension. The one to read first.
- **SlateAFM** — domain data rendering.
- **BonitoSlate** — the deep end: a live, session-bound output (WGLMakie over Slate's own
  WebSocket) using `slate_live_render`, `on_live_reset` and `provide_served_asset!`.
