"""
    SlateAFM

Host **Anywidget Front-End Modules (AFM)** in a Slate notebook. An AFM is a framework-agnostic ES module
that `export default`s `{ initialize?, render? }`, driving a host-provided `model` (get/set/on/
save_changes/send) and rendering into an `HTMLElement`. This package implements the AFM host contract on
top of Slate's own seams — no fork of the server:

- `provide_frontend!` injects the **host shim** (`assets/afm-host.js`), which registers the `SlateAFM.AFM`
  widget kind via Slate's low-level `slateRegisterWidget` and adapts Slate's bound value into an AFM
  `model`, with `AbortSignal`-based cleanup.
- `provide_assets!` **serves** the bundled example modules (and is how any multi-file AFM module ships).
- The bound value is the widget's **traits dict**; `model.save_changes()` commits it (reactive to reader
  cells), and a value pushed from Julia fires `change:<key>`.

```julia
using SlateAFM
@bind st afm(afm_example("counter.js"); count = 0)   # a self-contained AFM counter
st                                                    # → Dict("count" => n), reactive
```
"""
module SlateAFM

using SlateExtensionsBase

export AFM, afm, afm_example, afm_on_msg, afm_emit

# The wire kind Slate registers the host shim under. A namespaced (dotted) kind renders as a generic
# `customwidget` container that delegates to the registered impl — exactly what an AFM module needs, since
# it owns its own DOM.
const KIND = "SlateAFM.AFM"

"""
    afm(src; traits...) -> AFM

An AFM widget bound to a **traits dict** (`traits...` seed it). `src` is the URL of the AFM ES module to
load — a served asset ([`afm_example`](@ref) / [`ext_asset_url`](@ref)) or any CDN/ESM URL. Bind it with
`@bind`; the bound value is the trait dict the module reads/writes via its `model`.
"""
struct AFM
    src::String
    id::String
    css::Vector{String}
    traits::Dict{String,Any}
end
# `css` = stylesheet URL(s) the host injects before render (many anywidgets assume their CSS is host-loaded).
afm(src::AbstractString; id::AbstractString = "", css = String[], traits...) =
    AFM(String(src), String(id), css isa AbstractString ? [String(css)] : String[String(c) for c in css],
        Dict{String,Any}(String(k) => v for (k, v) in traits))

# Reflect an AFM handle into its wire `Widget`: the bound value is the trait dict; the module URL (and an
# optional message `id` / `css`) ride as params. (No hand-typed kind — it's this package's constant.)
function SlateExtensionsBase.to_widget(a::AFM)
    p = Dict{Symbol,Any}(:src => a.src)
    isempty(a.id)  || (p[:id]  = a.id)
    isempty(a.css) || (p[:css] = a.css)
    Widget(KIND, a.traits; p...)
end

# ── Custom messages: the AFM `model.send` / `on("msg:custom")` half, over Slate's slate_on/slate_emit ──
const _MSG = Dict{String,Any}()   # "SlateAFM.msg:<id>" -> Julia handler(content)

_afmfield(a, k) = a isa AbstractDict ? get(a, String(k), get(a, k, nothing)) :
                  (hasproperty(a, Symbol(k)) ? getproperty(a, Symbol(k)) : nothing)

"""
    afm_on_msg(f, id)

Register `f(content)` to receive custom messages a widget sends via `model.send(content)`. `id` is the
widget's message id — bind it with `afm(src; id = "…")`.
"""
afm_on_msg(f, id::AbstractString) = (_MSG["SlateAFM.msg:" * String(id)] = f; nothing)

"""
    afm_emit(id, content)

Send `content` TO a widget (received by its `model.on("msg:custom", cb)`). Call from a cell.
"""
afm_emit(id::AbstractString, content) = slate_emit("SlateAFM.msg:" * String(id), (content = content,))

"""
    afm_example(name) -> String

The served URL of a bundled example AFM module under `assets/examples/<name>` (e.g. `"counter.js"`),
via this package's `provide_assets!` scope.
"""
afm_example(name::AbstractString) = ext_asset_url(@__MODULE__, "examples/" * name)

# Package front-end: serve the bundled asset tree (host shim + example modules) and inject the host shim,
# which self-registers the `SlateAFM.AFM` widget kind. Both are idempotent per drain.
function __slate_frontend(slate_on)
    provide_assets!(@__MODULE__, @pkg_dir("assets"))
    register_widget!(KIND, @pkg_asset("assets/afm-host.js"))
    # JS→Julia custom messages (a widget's `model.send`): route by channel to a registered handler.
    slate_on("SlateAFM.msg") do a
        ch = _afmfield(a, :ch)
        ch === nothing && return nothing
        h = get(_MSG, String(ch), nothing)
        h === nothing || Base.invokelatest(h, _afmfield(a, :content))
        return nothing
    end
    return nothing
end

end # module
