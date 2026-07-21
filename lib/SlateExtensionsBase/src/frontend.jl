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

"""
    @pkg_asset(path) -> String

Read a file bundled in the CALLING package, resolved relative to its package root (`pkgdir`), as a
`String`. For shipping a front-end asset from `__init__` without embedding it in a Julia string:
`register_component!("stars", @pkg_asset("assets/stars.js"))`.
"""
macro pkg_asset(path)
    :(read(joinpath(pkgdir($(__module__)), $(esc(path))), String))
end

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

Extensible: as new package-registration seams are added (e.g. package-served asset directories), they
surface as additional fields here, carried by the same query — no new transport per feature.
"""
extension_manifest() =
    (; frontend = [(; id = k, js = v.js, esm = v.esm, kind = v.kind) for (k, v) in _FRONTEND])
