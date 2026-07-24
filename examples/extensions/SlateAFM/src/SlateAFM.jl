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

# Package front-end: serve the bundled asset tree (host shim + example modules) and inject the host shim,
# which self-registers the `SlateAFM.AFM` widget kind. Both are idempotent per drain.
function __slate_frontend(slate_on)
    # Authored web assets (host shim + example modules) — served under `/ext-assets/SlateAFM/…`.
    provide_assets!(@__MODULE__, @pkg_dir("assets"))
    register_widget!(KIND, @pkg_asset("assets/afm-host.js"))
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
