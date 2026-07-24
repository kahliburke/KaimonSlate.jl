"""
    SlateAFM

Host **Anywidget Front-End Modules (AFM)** in a Slate notebook. An AFM is a framework-agnostic ES module
that `export default`s `{ initialize?, render? }`, driving a host-provided `model` (get/set/on/
save_changes/send) and rendering into an `HTMLElement`. This package implements the AFM host contract on
top of Slate's own seams — no fork of the server:

- `provide_frontend!` injects the **host shim** (`assets/afm-host.js`), which registers the `SlateAFM.AFM`
  widget kind via Slate's low-level `slateRegisterWidget` and adapts Slate's bound value into an AFM
  `model`, with `AbortSignal`-based cleanup.
- `provide_assets!` **serves** module files (and is how any multi-file AFM module ships).
- The bound value is the widget's **traits dict**; `model.save_changes()` commits it (reactive to reader
  cells), and a value pushed from Julia fires `change:<key>`.

The core API is just `afm(src; css, traits…)` where `src` is the URL of an AFM ES module. Where that URL
comes from is the "install" model (increasing power):

1. **A CDN/npm URL** — `afm("https://esm.sh/…")`. Zero install; the browser fetches it.
2. **A module served from a package** — `afm(ext_asset_url(SomePkg, "widget.js"))`, i.e. a package that
   `provide_assets!`es the ESM (this package's own demo modules work exactly this way).
3. **A local ESM file / a PyPI anywidget** (roadmap) — a helper that serves a `.js` you point it at, or,
   best-effort, shells out to a `pip`/`python` found on `PATH` to fetch a published anywidget's
   `_esm`/`_css`/trait-defaults into a served scratch dir. SlateAFM takes **no** Python/Conda dependency —
   an AFM module is plain JS; the system tools are an optional convenience with a manual fallback.

```julia
using SlateAFM
@bind st afm(ext_asset_url(SlateAFM, "examples/counter.js"); count = 0)   # a self-contained AFM counter
st                                                                        # → Dict("count" => n), reactive
```
"""
module SlateAFM

using SlateExtensionsBase
import JSON   # parse the `meta.json` an introspected PyPI widget writes (defaults/css) — see pypi.jl

# `ext_asset_url` (from SlateExtensionsBase) is the mechanism for pointing `afm` at a module served from a
# package's `provide_assets!` scope — re-exported so a notebook builds those URLs without a bespoke helper.
export AFM, afm, afm_on_msg, afm_emit, ext_asset_url, pypi_afm
export AFMHandle, molstar, load!, spin!, stream!

# The wire kind Slate registers the host shim under. A namespaced (dotted) kind renders as a generic
# `customwidget` container that delegates to the registered impl — exactly what an AFM module needs, since
# it owns its own DOM.
const KIND = "SlateAFM.AFM"

"""
    afm(src; traits...) -> AFM

An AFM widget bound to a **traits dict** (`traits...` seed it). `src` is the URL of the AFM ES module to
load — a package-served module via [`ext_asset_url`](@ref), or any CDN/ESM URL. `css` injects
stylesheet URL(s) some widgets assume the host loads. Bind it with `@bind`; the bound value is the trait
dict the module reads/writes via its `model`.
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

Register a handler to receive custom messages a widget sends via `model.send(content, cb, buffers)`. `f`
is called `f(content, buffers)` — `buffers::Vector{Vector{UInt8}}` are the widget's binary buffers (empty
when none) — or, for convenience, `f(content)` if it takes a single argument. `id` is the widget's message
id — bind it with `afm(src; id = "…")`.
"""
afm_on_msg(f, id::AbstractString) = (_MSG["SlateAFM.msg:" * String(id)] = f; nothing)

# Coerce an emit buffer to raw bytes: a byte vector rides as-is; anything else is `Vector{UInt8}`-converted.
_as_bytes(b::Vector{UInt8}) = b
_as_bytes(b::AbstractVector{UInt8}) = collect(b)
_as_bytes(b) = Vector{UInt8}(b)

const _MID = Ref(0)   # message-id counter, correlating a content frame with its trailing binary buffers

"""
    afm_emit(id, content; buffers = ())

Send `content` TO a widget — received by its `model.on("msg:custom", (content, buffers) => …)`. `buffers`
is an iterable of byte buffers (each `Vector{UInt8}`), delivered to the widget as `ArrayBuffer`s. Call from
a cell (or from an [`afm_on_msg`](@ref) handler, to reply). No buffers ⇒ a single plain content frame.
"""
function afm_emit(id::AbstractString, content; buffers = ())
    ch = "SlateAFM.msg:" * String(id)
    bufs = Vector{UInt8}[_as_bytes(b) for b in buffers]
    n = length(bufs)
    if n == 0
        slate_emit(ch, (content = content,))   # fast path: no buffers, no message id
        return nothing
    end
    # A buffered message rides N+1 frames on one channel, correlated by a message id: a JSON `content` frame
    # (carrying the buffer count) followed by one binary frame per buffer (a UInt8 `SlateBinary` whose meta
    # tags it with the message id + index). The host shim reassembles them in its `slateOnStream` handler.
    mid = (_MID[] += 1)
    slate_emit(ch, (content = content, mid = mid, nbuf = n))
    for (i, b) in enumerate(bufs)
        slate_emit(ch, SlateBinary(b, Dict{String,Any}("mid" => mid, "bi" => i - 1, "nbuf" => n)))
    end
    return nothing
end

# ── A bound-widget HANDLE ─────────────────────────────────────────────────────────────────────────────
# `@bind name afm(...)` binds `name` to one of these (via the kind's `wrap`), NOT a bare trait dict. It
# stays dict-like for reading traits (`name["count"]` still works), but also carries the widget's message
# `id` — so `afm_emit(name, …)` needs no magic string — and a mutable `props` bag a driver can stash
# structure metadata into for later querying (`mol.n_atoms`, since Julia built the molecule it knows).
struct AFMHandle <: AbstractDict{String,Any}
    id::String
    traits::Dict{String,Any}
    props::Dict{Symbol,Any}
end
_as_traits(d::AbstractDict) = Dict{String,Any}(String(k) => v for (k, v) in d)
_as_traits(v) = Dict{String,Any}("value" => v)   # a scalar-valued AFM widget
AFMHandle(id, traits) = AFMHandle(String(id), _as_traits(traits), Dict{Symbol,Any}())

# Dict-like over the traits, so an AFMHandle is a drop-in for the old bare-dict bound value.
Base.getindex(h::AFMHandle, k) = getfield(h, :traits)[String(k)]
Base.get(h::AFMHandle, k, d) = get(getfield(h, :traits), String(k), d)
Base.haskey(h::AFMHandle, k) = haskey(getfield(h, :traits), String(k))
Base.keys(h::AFMHandle) = keys(getfield(h, :traits))
Base.length(h::AFMHandle) = length(getfield(h, :traits))
Base.iterate(h::AFMHandle, s...) = iterate(getfield(h, :traits), s...)

# `h.id`/`h.traits`/`h.props` are the fields; any OTHER property reads the stashed props bag (`h.n_atoms`),
# so a driver's metadata is queryable by name.
function Base.getproperty(h::AFMHandle, s::Symbol)
    (s === :id || s === :traits || s === :props) && return getfield(h, s)
    p = getfield(h, :props)
    haskey(p, s) ? p[s] : throw(KeyError(s))
end
Base.propertynames(h::AFMHandle) = (:id, :traits, :props, keys(getfield(h, :props))...)

# Render a value compactly — a long string (a whole PDB stashed in `props`) collapses to a size, so
# `show` stays a tidy summary instead of dumping kilobytes.
_briefval(v::AbstractString) = length(v) > 40 ? string("⟨", length(v), " chars⟩") : repr(v)
_briefval(v::AbstractVector) = string(typeof(v), "(", length(v), ")")
_briefval(v) = repr(v)
_briefpairs(io, d) = join(io, (string(k, "=", _briefval(v)) for (k, v) in d), ", ")

Base.show(io::IO, h::AFMHandle) = print(io, "AFMHandle(", repr(getfield(h, :id)), ")")
function Base.show(io::IO, ::MIME"text/plain", h::AFMHandle)
    t = getfield(h, :traits); p = getfield(h, :props)
    print(io, "AFMHandle ", repr(getfield(h, :id)))
    isempty(t) || (print(io, "\n  traits: "); _briefpairs(io, t))
    isempty(p) || (print(io, "\n  props:  "); _briefpairs(io, p))
end

"""
    afm_emit(h::AFMHandle, content; buffers = ())

Send to the widget the handle refers to — the handle carries its own message `id`, so a driver never
re-types the id string.
"""
afm_emit(h::AFMHandle, content; buffers = ()) = afm_emit(h.id, content; buffers = buffers)

# ── Viewer verbs ──────────────────────────────────────────────────────────────────────────────────────
"""
    load!(h::AFMHandle, structure; op = "load", key = "pdb", props...)

Send a `structure` (e.g. a PDB string) to a viewer widget and stash it — plus any `props…` (say
`n_atoms = …`) — on the handle for later querying. The widget receives `{op, <key>: structure}` on its
`msg:custom` channel.
"""
function load!(h::AFMHandle, structure; op = "load", key = "pdb", props...)
    afm_emit(h, Dict("op" => op, key => structure))
    p = getfield(h, :props); p[Symbol(key)] = structure
    for (k, v) in props; p[k] = v; end
    return h
end

"""    spin!(h::AFMHandle, on = true) — toggle a viewer's auto-rotation."""
spin!(h::AFMHandle, on::Bool = true) = (afm_emit(h, Dict("op" => "spin", "on" => on)); h)

"""
    stream!(h::AFMHandle, frames; dt = 0.05, op = "load", key = "pdb", meta = nothing)

Stream a SEQUENCE of structures into a viewer over time — a growing / morphing animation. `frames` is any
iterable (each element a structure); `dt` is the pause between frames; `meta(i)` (optional) returns the
props to stash for frame `i`. Runs on the caller, so an `@onclick` handler streams the frames as it goes.
"""
function stream!(h::AFMHandle, frames; dt::Real = 0.05, op = "load", key = "pdb", meta = nothing)
    p = getfield(h, :props)
    for (i, f) in enumerate(frames)
        afm_emit(h, Dict("op" => op, key => f))
        p[Symbol(key)] = f
        meta === nothing || merge!(p, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(meta(i))))
        sleep(dt)
    end
    return h
end

"""
    molstar(; id, height = 440, css = <pdbe-molstar cdn>, traits...) -> AFM

A live PDBe Mol* viewer widget (the `molstar_live.js` module). Bind it — `@bind mol molstar(id = "mol")`
— and drive it with [`load!`](@ref) / [`stream!`](@ref) / [`spin!`](@ref); `mol` is an [`AFMHandle`](@ref),
not a string. `id` names its message channel (needed so a driver can reach it after a re-run).
"""
const _MOLSTAR_CSS = "https://cdn.jsdelivr.net/npm/pdbe-molstar@3.3.2/build/pdbe-molstar.css"
molstar(; id::AbstractString = "mol", height = 440, css = _MOLSTAR_CSS, traits...) =
    afm(ext_asset_url(@__MODULE__, "examples/molstar_live.js");
        id = id, css = css, height = height, traits...)

# Persistence policy when a bind cell RE-RUNS with the same kind. The default reconciler keeps the whole
# old value — wrong for AFM, whose trait dict is BOTH config (`height`, `min`) set in the `@bind` source
# AND state (`count`, `value`) the widget mutates via `save_changes()`. Keeping everything freezes a config
# trait (edit `height = 600` in the source and it never takes). So MERGE: start from the new source's
# traits (config follows the source), then re-overlay only the traits the widget itself changed away from
# its OLD default (state survives a re-run). Non-dict values fall back to the new default.
function _afm_reconcile(oldw::Widget, oldv, neww::Widget)
    nd = neww.default
    (oldv isa AbstractDict && oldw.default isa AbstractDict && nd isa AbstractDict) || return nd
    od = oldw.default
    merged = Dict{String,Any}(String(k) => v for (k, v) in nd)   # new source config
    for (k, v) in oldv
        ks = String(k)
        # a trait the widget mutated (differs from its old default) is live state → preserve it; a trait
        # still at its old default is config → let the new source's value stand.
        (!haskey(od, ks) || od[ks] != v) && (merged[ks] = v)
    end
    return merged
end

# Package front-end: serve the bundled asset tree (host shim + example modules) and inject the host shim,
# which self-registers the `SlateAFM.AFM` widget kind. Both are idempotent per drain.
function __slate_frontend(slate_on)
    # Authored web assets (host shim + example modules) — served under `/ext-assets/SlateAFM/…`.
    provide_assets!(@__MODULE__, @pkg_dir("assets"))
    register_widget!(KIND, @pkg_asset("assets/afm-host.js"))
    # Make `@bind name afm(...)` bind `name` to a rich AFMHandle (id + dict-like traits + props bag)
    # instead of a bare trait dict — the wire/memo side still sees the bare dict (this only lifts the
    # user-facing value). Idempotent: re-registering just replaces the kind's hooks.
    register_kind!(KIND; wrap = (w, v) -> AFMHandle(get(w.params, "id", ""), v),
                   reconcile = _afm_reconcile)
    # PyPI-provisioned widgets are kept STRICTLY SEPARATE: a distinct served root (the deploy dir) under a
    # distinct key (`_PYPI_KEY`), so fetched third-party modules never mingle with the package's own assets.
    provide_assets!(_PYPI_KEY, (mkpath(_served_root()); _served_root()))
    # JS→Julia custom messages (a widget's `model.send`): route by channel to a registered handler.
    # NB: `slate_on` is `(channel, f)` — pass the handler as the 2nd argument, NOT via `do` (a do-block
    # would bind the closure as the FIRST arg, registering under the closure's name instead of the channel).
    slate_on("SlateAFM.msg", function (a)
        ch = _afmfield(a, :ch)
        ch === nothing && return nothing
        h = get(_MSG, String(ch), nothing)
        h === nothing && return nothing
        content = _afmfield(a, :content)
        # `model.send` buffers arrive as native binary WS frames, decoded by Slate into
        # `args.__slate_buffers::Vector{Vector{UInt8}}` — real bytes, no base64.
        raw = _afmfield(a, :__slate_buffers)
        buffers = raw === nothing ? Vector{UInt8}[] : Vector{UInt8}[Vector{UInt8}(b) for b in raw]
        # Prefer a 2-arg handler `(content, buffers)`; fall back to a 1-arg `(content)` handler.
        applicable(h, content, buffers) ? Base.invokelatest(h, content, buffers) :
                                          Base.invokelatest(h, content)
        return nothing
    end)
    return nothing
end

include("pypi.jl")   # pypi_afm: host a published anywidget from PyPI (system pip, no Python dep)

end # module
