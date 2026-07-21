# ── Auto-registered front-end (no boot cell) ──────────────────────────────────
# A package declares its front-end from `__init__` instead of a notebook calling a boot function in
# a cell above the bind. Two things happen:
#   1. the script is recorded in a process-global registry ([`frontend_scripts`](@ref)) so Slate can
#      pick it up at any page build (including after the package was already loaded), and
#   2. if we're inside a Slate cell eval (the `using MyPkg` runs there, and `__init__` with it), it's
#      declared over the cell-effects channel so the hub injects it into the LIVE page immediately.
# Slate injects each script once (deduped by id), live and in a static export. This is the automatic,
# order-independent equivalent of returning `register_widget_js(kind, js)` from a boot cell.

const _FRONTEND = Dict{String,String}()   # id => js (process-global; a re-register replaces, not duplicates)

"""
    provide_frontend!(js; id="")

Declare a front-end `<script>` to be injected into the page whenever this package is active in a
notebook — call it from your module's `__init__`. `id` dedups re-registration (a reload replaces the
entry rather than stacking duplicates); omit it to key on the script's content. This is the general
form behind [`register_widget!`](@ref). Live and in a static export; no boot cell, no ordering.
"""
function provide_frontend!(js::AbstractString; id::AbstractString = "")
    key = isempty(id) ? "fe:" * string(hash(js); base = 16) : String(id)
    _FRONTEND[key] = String(js)
    _declare_frontend(key, String(js))   # inject NOW if we're inside a cell eval (else picked up at page build)
    return nothing
end

"""
    register_widget!(kind, js)

Auto-register the front-end renderer for a widget `kind` — the boot-cell-free counterpart to
[`register_widget_js`](@ref). Call it from your module's `__init__`; `js` should call
`window.slateRegisterWidget("<kind>", …)`.

```julia
function __init__()
    register_widget!("stars", read(joinpath(pkgdir(@__MODULE__), "assets", "stars.js"), String))
end
```
"""
register_widget!(kind::AbstractString, js::AbstractString) =
    provide_frontend!(js; id = "widget:" * String(kind))

"""
    frontend_scripts() -> Dict{String,String}

Every front-end script declared by the loaded packages (`id => js`) — Slate queries this at page
build to inject them (a copy, so callers can't mutate the registry).
"""
frontend_scripts() = copy(_FRONTEND)

# Declare a front-end script over Slate's cell-effects channel, IF we're inside a cell eval — the
# hub harvests `:frontend` effects and injects the script into the page. A no-op outside a Slate cell
# (e.g. local tests, a plain `using`), where the process-global registry is the pickup path instead.
function _declare_frontend(id::AbstractString, js::AbstractString)
    f = _ctx_field(:effect)
    f === nothing && return nothing
    try
        f(:frontend; id = id, js = js)
    catch
    end
    return nothing
end
