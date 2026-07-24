# ── Rich output via the Slate display MIMEs ───────────────────────────────────
# A value RETURNED from a cell renders Slate-rich WITHOUT hijacking `text/html` — so it still degrades to
# a plain representation in the REPL / IJulia / VS Code. An extension defines ONE dispatch method,
# `slate_render(x)`, returning either a COMPONENT DESCRIPTOR (mounts a registered front-end component) or
# an HTML fragment (the escape hatch); SEB owns the `show`/`showable` plumbing and Slate's display capture
# prefers these over `text/html`/`text/plain` via a priority `showable` scan.

"""
    SlateComponentMIME  ·  SlateHtmlMIME

The two frozen Slate display MIMEs (IANA vendor tree; the suffix matches the payload format). The
descriptor VERSION lives in the payload (`{v, …}`), not the MIME string — one evolving contract.
- `application/vnd.kaimonslate.component+json` — a JSON component descriptor `{v, component, props}`; the
  front-end mounts the registered component by name. The blessed path.
- `application/vnd.kaimonslate.html+html` — a self-contained HTML fragment; the clean escape hatch that
  replaces a hand-rolled `Base.show(::MIME"text/html")`.
"""
const SlateComponentMIME = MIME"application/vnd.kaimonslate.component+json"
const SlateHtmlMIME      = MIME"application/vnd.kaimonslate.html+html"

# An HTML-fragment escape-hatch payload — `slate_render` returns one of these to render raw HTML through
# the `html+html` MIME instead of a component. `component(...)` (a Dict) is the blessed path.
struct SlateHtml
    html::String
end

"""
    html_fragment(html) -> SlateHtml

Wrap a self-contained HTML string as a `slate_render` result — the escape hatch for output that isn't a
registered component. Prefer [`component`](@ref) when a front-end component exists.
"""
html_fragment(html::AbstractString) = SlateHtml(String(html))

"""
    component(kind; props...) -> Dict
    component(kind, props) -> Dict

Build the frozen COMPONENT DESCRIPTOR `{v: 1, component: kind, props: {…}}` — what [`slate_render`](@ref)
returns for a value that should mount a registered front-end component (the SAME `{component, props}` a
bound widget mounts, so returned + bound values render through identical machinery). `props` must be
JSON-safe (Dicts/Vectors/numbers/strings/bools/nothing — the shapes the descriptor writer emits).

```julia
SlateExtensionsBase.slate_render(v::MyView) = component(kind_for(MyView); value = v.x, max = v.max)
```
"""
component(kind::AbstractString; props...) =
    component(kind, Dict{String,Any}(String(k) => v for (k, v) in props))
component(kind::AbstractString, props) =
    Dict{String,Any}("v" => 1, "component" => String(kind), "props" => _props_dict(props))
component(::Type{T}, args...; kw...) where {T} = component(kind_for(T), args...; kw...)

_props_dict(p::AbstractDict) = Dict{String,Any}(String(k) => v for (k, v) in p)
_props_dict(p::NamedTuple)   = Dict{String,Any}(String(k) => v for (k, v) in pairs(p))
_props_dict(p)               = p   # already a plain container the descriptor writer handles

"""
    slate_render(x) -> Dict | SlateHtml | Nothing

An extension's rich-output hook: return a [`component`](@ref) descriptor, an [`html_fragment`](@ref), or
`nothing` (the default — `x` isn't Slate-renderable). Its presence is the detection: `showable` reports the
Slate MIME iff a non-`nothing` method exists, so Slate's display capture picks it over `text/html` /
`text/plain`.
"""
slate_render(::Any) = nothing

"""
    slate_live_render(x) -> Bool

Whether `x` is a SESSION-BOUND (live) output — one whose rendered content lives in a per-browser
runtime session (e.g. a WGLMakie figure whose scene + interaction handlers run in a live Bonito
session), rather than being fully self-contained in the captured HTML. Default `false`.

Slate uses this to know a cell's output must be RE-RENDERED for each browser page that connects (a
reload, a second tab, a reconnect) instead of replaying the stored fragment — the same way a Bonito
server serves a fresh session per page load. An extension opts a value in by adding a method:

```julia
SlateExtensionsBase.slate_live_render(::MyLiveThing) = true
```
"""
slate_live_render(::Any) = false

# `showable` == "a slate_render method returns something of this flavour". Cheap enough: capture calls it
# once per candidate MIME while choosing the richest representation.
Base.showable(::SlateComponentMIME, x) = (r = slate_render(x); r !== nothing && !(r isa SlateHtml))
Base.showable(::SlateHtmlMIME, x)      = slate_render(x) isa SlateHtml

Base.show(io::IO, ::SlateComponentMIME, x) = _write_json(io, slate_render(x))
Base.show(io::IO, ::SlateHtmlMIME, x)      = print(io, (slate_render(x)::SlateHtml).html)

# ── Minimal JSON writer for the descriptor ────────────────────────────────────
# SEB stays Base+stdlib only, so it can't lean on JSON.jl. The descriptor payload is small and its props
# are the extension's responsibility to keep JSON-safe, so a tiny writer for the JSON value shapes
# (Dict/Vector/String/Symbol/Number/Bool/Nothing) is all that's needed; anything else stringifies.
function _write_json_string(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"';      print(io, "\\\"")
        elseif c == '\\'; print(io, "\\\\")
        elseif c == '\n'; print(io, "\\n")
        elseif c == '\r'; print(io, "\\r")
        elseif c == '\t'; print(io, "\\t")
        elseif c < ' ';   print(io, "\\u", lpad(string(UInt16(c); base = 16), 4, '0'))
        else              print(io, c)
        end
    end
    print(io, '"')
end

_write_json(io::IO, ::Nothing)          = print(io, "null")
_write_json(io::IO, ::Missing)          = print(io, "null")
_write_json(io::IO, b::Bool)            = print(io, b ? "true" : "false")
_write_json(io::IO, n::Integer)         = print(io, n)
_write_json(io::IO, x::AbstractFloat)   = print(io, isfinite(x) ? string(Float64(x)) : "null")
_write_json(io::IO, n::Real)            = print(io, isfinite(n) ? string(n) : "null")
_write_json(io::IO, s::AbstractString)  = _write_json_string(io, s)
_write_json(io::IO, s::Symbol)          = _write_json_string(io, String(s))
function _write_json(io::IO, d::AbstractDict)
    print(io, '{'); first = true
    for (k, v) in d
        first || print(io, ','); first = false
        _write_json_string(io, string(k)); print(io, ':'); _write_json(io, v)
    end
    print(io, '}')
end
function _write_json(io::IO, v::Union{AbstractVector,Tuple})
    print(io, '['); first = true
    for x in v
        first || print(io, ','); first = false
        _write_json(io, x)
    end
    print(io, ']')
end
_write_json(io::IO, x) = _write_json_string(io, string(x))   # unknown leaf → its string form
