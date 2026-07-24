# ── Auto-registered front-end (no boot cell) ──────────────────────────────────
# A package declares its front-end from `__init__` instead of a notebook calling a boot function in a
# cell above the bind. The declaration is recorded in a process-global registry ([`frontend_scripts`](@ref)
# / [`extension_manifest`](@ref)); Slate PULLS that registry once per run drain and injects each script
# into the page — live and in a static export, deduped by id. Order-independent, no boot cell. A script
# may be a classic `<script>` (`register_widget!`) or an ES module (`register_component!`, the blessed
# path — it `import`s the Slate widget SDK and uses signals/htm).

# id => (; js, esm, kind): the front-end script, whether it's an ES module, and — for a COMPONENT —
# the widget kind whose default export Slate wraps + registers (`""` for a self-registering script).
# Process-global; a re-register by the same id REPLACES (a reload doesn't stack duplicates).
const _FRONTEND = Dict{String,@NamedTuple{js::String, esm::Bool, kind::String}}()

"""
    provide_frontend!(js; id="", esm=false, kind="")

Declare a front-end `<script>` to be injected into the page whenever this package is active in a
notebook — call it from your module's `__init__`. `id` dedups re-registration (a reload replaces the
entry rather than stacking duplicates); omit it to key on the script's content. `esm=true` marks `js`
an ES module. `kind` (non-empty) marks `js` a COMPONENT module: Slate wraps its `export default` and
registers it under `kind` (see [`register_component!`](@ref)); `""` ⇒ inject the script as-is (it
self-registers). The general form behind [`register_widget!`](@ref) / [`register_component!`](@ref).
Live and in a static export; no boot cell, no ordering.
"""
function provide_frontend!(js::AbstractString; id::AbstractString = "", esm::Bool = false,
                           kind::AbstractString = "")
    key = isempty(id) ? "fe:" * string(hash(js); base = 16) : String(id)
    _FRONTEND[key] = (js = String(js), esm = esm, kind = String(kind))
    return nothing
end

"""
    register_widget!(kind, js)

Auto-register a CLASSIC-script front-end renderer for a widget `kind` — call it from your module's
`__init__`; `js` should call `window.slateRegisterWidget("<kind>", …)`. For the higher-level, signals-
based component pattern, prefer [`register_component!`](@ref).
"""
register_widget!(kind::AbstractString, js::AbstractString) =
    provide_frontend!(js; id = "widget:" * String(kind), esm = false, kind = "")

"""
    register_component!(T::Type, js)
    register_component!(kind::AbstractString, js)

Auto-register a widget's front-end as a signals-based **component module** — the blessed authoring
pattern. Prefer the **type** form: the kind is derived from `T` (`SlateExtensionsBase.kind_for`), so
it's namespaced by your package and can't collide with another package's widget — and there's no kind
string to keep in sync with `to_widget`. `js` is a module that just `export default`s the component:

```js
import { html, useSignal } from "@slate/widget";
export default ({ value, set, params }) => html`…`;      // no kind string anywhere
```

Ship it as a file and read it with [`@pkg_asset`](@ref) so the JS lives in a real `.js`:

```julia
SlateExtensionsBase.to_widget(s::Stars) = Widget(Stars, s.default; max = s.max)
function __init__()
    register_component!(Stars, @pkg_asset("assets/stars.js"))
end
```

Slate injects `<script type="module">`, imports the module, and registers its default export under the
kind; `import`s resolve against the page's import map (Preact/htm/signals + `@slate/widget` are served,
offline-pinned). Live and in a static export. The string form takes an explicit (un-namespaced) kind —
an escape hatch.
"""
register_component!(kind::AbstractString, js::AbstractString) =
    provide_frontend!(js; id = "widget:" * String(kind), esm = true, kind = String(kind))
register_component!(::Type{T}, js::AbstractString) where {T} = register_component!(kind_for(T), js)

"""
    required_assets(::Type{W}) -> js | nothing

The front-end a widget TYPE `W` needs — return its component module JS (typically
`@pkg_asset("assets/x.js")`), or `nothing` (the default) for a type with no front-end. Slate calls this
**lazily**, the first time a `W` is bound or displayed, and registers the module under `kind_for(W)`:

```julia
SlateExtensionsBase.required_assets(::Type{Stars}) = @pkg_asset("assets/stars.js")
```

So a package needs **no `__init__`** — declaring the widget is pure dispatch (`to_widget` +
`required_assets`), and only widgets a notebook actually uses load their JS. A type with no method
contributes nothing, so this doubles as extension-detection.
"""
required_assets(::Type) = nothing

# Widget types whose assets we've already resolved this process (loaded, or confirmed none) — so the
# per-bind check is a set lookup and `required_assets` (which may read a file) runs once per type ever.
const _ASSET_CHECKED = Set{Any}()

"""
    ensure_widget_assets!(::Type{W})

Lazily load `W`'s front-end into the registry (once per process): the first time it's seen, call
[`required_assets`](@ref) and, if it returns a module, register it as a component under `kind_for(W)`.
Slate calls this from the `@bind`/display path — a no-op for built-ins and any type without a method.
"""
function ensure_widget_assets!(::Type{T}) where {T}
    T in _ASSET_CHECKED && return nothing
    push!(_ASSET_CHECKED, T)
    js = required_assets(T)
    js === nothing || register_component!(T, js)
    return nothing
end

# ── Package-global front-end (no bind to trigger it) ──────────────────────────
# Some front-end an extension ships isn't tied to any single widget bind — an EDITOR extension
# (`slateRegisterEditorExtension`, e.g. inline-math rendering in cells) and JS→Julia RPC HANDLERS
# (`slate_on(channel) do … end`) fire on "this package is in use in the notebook", not on a `@bind`.
# A package declares them from a named convention hook, `MyPkg.__slate_frontend(slate_on)`, instead of
# an `__init__` + a boot cell:
#
#   function GiacSlate.__slate_frontend(slate_on)
#       provide_frontend!(@pkg_asset("assets/inline_math_editor.js"); id = "GiacSlate.inline_math")
#       slate_on("giac_tex", a -> Dict("latex" => giac_src_to_tex(String(a.src))))
#       slate_on("giac_src", a -> Dict("src"   => mathjson_to_giac_src(String(a.mj))))
#   end
#
# Slate invokes it once per drain per loaded module (see `ensure_module_frontends!`), handing it the
# notebook's injected `slate_on` — so the FRONT-END side lands in the process-global `_FRONTEND` registry
# (pulled by the manifest) and the HANDLER side lands in THAT notebook's `__slate_handlers`. The hook must
# be cheap + idempotent: `provide_frontend!` dedups by id and `slate_on` replaces by channel, so re-running
# it each drain is a no-op that also self-heals a namespace rebuild (the handlers get re-installed).

# `(objectid(slate_on), module)` pairs whose hook has already run — so a package's `__slate_frontend`
# fires ONCE per notebook-namespace generation, even though Slate rescans loaded modules every drain (to
# catch a package a later cell `using`s). The scan is cheap; this guards the actual WORK (a file read +
# registration). Keyed on the namespace's injected `slate_on`, which is stable within a generation and
# FRESH after a rebuild — so a namespace reset (new `slate_on`) re-fires the hook, re-installing its
# handlers into the new `__slate_handlers`. (Contrast `_ASSET_CHECKED`: a widget's JS is process-global,
# so it's once-EVER; a module hook's handlers are per-namespace, so it's once-per-GENERATION.)
const _MODULE_FRONTEND_DONE = Set{Tuple{UInt,Module}}()

"""
    ensure_module_frontend!(m::Module, slate_on) -> Bool

Invoke module `m`'s package-global front-end hook, `m.__slate_frontend(slate_on)`, if it defines one and
it hasn't already run for this notebook-namespace generation (see [`ensure_module_frontends!`](@ref));
return whether the module *has* such a hook. A module without the method contributes nothing (returns
`false`), so — like [`required_assets`](@ref) — the method's presence doubles as extension-detection. A
throwing hook is isolated (caught) so one bad package can't break the manifest pull for the rest.
"""
function ensure_module_frontend!(m::Module, slate_on)
    isdefined(m, :__slate_frontend) || return false
    key = (objectid(slate_on), m)
    key in _MODULE_FRONTEND_DONE && return true          # already wired for this namespace generation
    push!(_MODULE_FRONTEND_DONE, key)
    try
        Base.invokelatest(getglobal(m, :__slate_frontend), slate_on)
    catch
        # A misbehaving package hook must not poison the whole manifest pull.
    end
    return true
end

"""
    ensure_module_frontends!(slate_on)

Invoke every loaded module's package-global front-end hook (see [`ensure_module_frontend!`](@ref)) — Slate
calls this once per run drain, handing it the notebook namespace's injected `slate_on` so a hook can
register both front-end scripts (via [`provide_frontend!`](@ref)) and JS→Julia handlers (via `slate_on`).
Hooks must be idempotent (they run every drain).
"""
function ensure_module_frontends!(slate_on)
    for m in Base.loaded_modules_array()
        ensure_module_frontend!(m, slate_on)
    end
    return nothing
end

"""
    @pkg_asset(path) -> String

Read a file bundled in the CALLING package, resolved relative to its package root (`pkgdir`), as a
`String`. For shipping a front-end asset from `__init__` without embedding it in a Julia string:
`register_component!("stars", @pkg_asset("assets/stars.js"))`.
"""
macro pkg_asset(path)
    :(read(joinpath(pkgdir($(__module__)), $(esc(path))), String))
end

# ── Package-vendored asset DIRECTORIES (served from disk, not inlined) ─────────
# `provide_frontend!` inlines ONE script's text into the page — fine for a component module, useless
# for a multi-file front-end library that can't be reduced to a single string (Cesium's Workers/Assets,
# echarts-gl, a lib that ships fonts/wasm). Such a library must be SERVED from disk: a package declares a
# directory, Slate serves its files from a stable package-scoped route (`/ext-assets/<pkg>/<sub>`) while
# the package is loaded, and the tree travels in a static export. Offline + pinned, no fork of Slate's
# `vendor.json`. The registry carries a package NAME → an ABSOLUTE dir on disk (the worker and the hub
# are co-located, so the hub reads the path directly; remote-worker file-shipping is a later seam).
const _ASSETS = Dict{String,String}()

# The package-scoped route prefix Slate serves vendored asset dirs under. This is the SDK-owned end of
# the CONTRACT — Slate's hub router (`/ext-assets/**`) and its static-export URL rewriter MUST match it.
const EXT_ASSET_PREFIX = "/ext-assets/"

"""
    pkg_key(m::Module) -> String

The stable, package-scoped key for a MODULE — its package root's name (e.g. `"GlobeSlate"`). The asset
analogue of [`kind_for`](@ref) for a widget type: a module-derived identity an author never hand-types
(and so never drifts on, nor clashes with another package's bare string). It's what a package's vendored
assets are served under — `/ext-assets/<pkg_key>/…`. Two packages can't share a name in one session, so
the key is unique per process. Pass `@__MODULE__` to [`provide_assets!`](@ref) / [`ext_asset_url`](@ref).
"""
pkg_key(m::Module) = string(nameof(Base.moduleroot(m)))

"""
    ext_asset_url(mod_or_pkg, sub = "") -> String

The URL a package-vendored asset (declared with [`provide_assets!`](@ref)) is served at:
`/ext-assets/<pkg>/<sub>`. Prefer the MODULE form — pass `@__MODULE__` and the package key is derived
([`pkg_key`](@ref)), so it can't drift from the string you passed to `provide_assets!`. The prefix is
owned by the SDK (Slate rewrites it to a page-local sibling in a static export); `sub=""` gives the base
URL for the package's tree.

```julia
_gl = ext_asset_url(@__MODULE__, "echarts-gl.min.js")   # "/ext-assets/GlobeSlate/echarts-gl.min.js"
```
"""
ext_asset_url(pkg::AbstractString, sub::AbstractString = "") =
    EXT_ASSET_PREFIX * String(pkg) * "/" * lstrip(String(sub), '/')
ext_asset_url(m::Module, sub::AbstractString = "") = ext_asset_url(pkg_key(m), sub)

"""
    provide_assets!(mod_or_pkg, dir) -> String

Declare a directory of front-end assets that Slate should SERVE while this package is loaded — call it
from your module's `__slate_frontend` hook (or `__init__`). Prefer the MODULE form: pass `@__MODULE__`
and the package key is derived ([`pkg_key`](@ref)) — the same module-scoped identity `kind_for` gives a
widget type — so there's no hand-typed string to keep in sync with your [`ext_asset_url`](@ref) calls.
The files are served at `/ext-assets/<pkg>/<subpath>` live and copied into a static export; `dir` is an
absolute directory, typically [`@pkg_dir`](@ref). Returns the package's base URL:

```julia
function __slate_frontend(slate_on)
    provide_assets!(@__MODULE__, @pkg_dir("assets"))
    # build urls with ext_asset_url(@__MODULE__, "echarts-gl/echarts-gl.min.js")
end
```

For a front-end LIBRARY too large or multi-file to inline as a `provide_frontend!` string (Cesium,
echarts-gl, anything shipping fonts/workers/wasm). A re-declaration of the same package replaces the dir.
The served files are pinned + offline-capable and travel in a static export. To inject a *single* script,
prefer [`provide_frontend!`](@ref)/[`register_component!`](@ref); use this to serve the files that script
(or a widget) then `fetch`es / `import`s / `<script src=>`s from `/ext-assets/<pkg>/…`.
"""
function provide_assets!(pkg::AbstractString, dir::AbstractString)
    _ASSETS[String(pkg)] = abspath(String(dir))
    return ext_asset_url(pkg)
end
provide_assets!(m::Module, dir::AbstractString) = provide_assets!(pkg_key(m), dir)

"""
    @provide_assets!(dir) -> String

[`provide_assets!`](@ref) for the CALLING package — the key is derived from the enclosing module
([`pkg_key`](@ref)), so there's no `@__MODULE__` to write and no string to keep in sync. Pair it with
[`@pkg_dir`](@ref) (or an `Artifacts`/`Scratch` dir):

```julia
@provide_assets!(@pkg_dir("assets"))
```
"""
macro provide_assets!(dir)
    :(provide_assets!($(__module__), $(esc(dir))))
end

"""
    @ext_asset_url(sub = "") -> String

[`ext_asset_url`](@ref) for the CALLING package — the key is derived from the enclosing module, so a
package builds its served-asset URLs with just the subpath, no key at all:

```julia
@ext_asset_url("echarts-gl/echarts-gl.min.js")   # "/ext-assets/GlobeSlate/echarts-gl/echarts-gl.min.js"
```
"""
macro ext_asset_url(sub = "")
    :(ext_asset_url($(__module__), $(esc(sub))))
end

"""
    @pkg_dir(path) -> String

Absolute path to a directory bundled in the CALLING package, resolved against its package root
(`pkgdir`) — the directory analogue of [`@pkg_asset`](@ref). For declaring a vendored asset tree:
`provide_assets!("GlobeSlate", @pkg_dir("assets/echarts-gl"))`.
"""
macro pkg_dir(path)
    :(abspath(joinpath(pkgdir($(__module__)), $(esc(path)))))
end

"""
    asset_dirs() -> Dict{String,String}

Every package-vendored asset directory declared by the loaded packages (`pkg => absolute dir`) — a copy,
so callers can't mutate the registry. See [`extension_manifest`](@ref) for what Slate pulls.
"""
asset_dirs() = copy(_ASSETS)

"""
    frontend_scripts() -> Dict{String,String}

Every front-end script declared by the loaded packages (`id => js`) — a copy, so callers can't mutate
the registry. See [`extension_manifest`](@ref) for the full record (incl. module-ness) that Slate pulls.
"""
frontend_scripts() = Dict{String,String}(k => v.js for (k, v) in _FRONTEND)

"""
    extension_manifest() -> NamedTuple

Everything this process's loaded packages have registered with Slate that the hub must mirror into the
page — Slate pulls it once per run drain and merges it into the notebook. Fields:
- `frontend`: the front-end scripts (`(; id, js, esm, kind)` each) from [`provide_frontend!`](@ref) /
  [`register_widget!`](@ref) / [`register_component!`](@ref). `esm=true` ⇒ inject as an ES module;
  a non-empty `kind` ⇒ a component (Slate wraps its `export default` and registers it under `kind`).
- `assets`: the package-vendored asset DIRECTORIES (`(; pkg, dir)` each) from [`provide_assets!`](@ref) —
  Slate serves each `dir` at `/ext-assets/<pkg>/…` while the package is loaded and copies it into a
  static export.

Extensible: as new package-registration seams are added they surface as additional fields here, carried
by the same query — no new transport per feature.
"""
extension_manifest() =
    (; frontend = [(; id = k, js = v.js, esm = v.esm, kind = v.kind) for (k, v) in _FRONTEND],
       assets = [(; pkg = k, dir = v) for (k, v) in _ASSETS])
