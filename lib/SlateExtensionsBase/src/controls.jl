# ── The @bind control contract ────────────────────────────────────────────────
# A `Widget` is the wire spec a `@bind` control reduces to: a UI `kind`, display `params`,
# and a `default` value. The Slate engine only ever consumes `(kind, params, default)` — the
# struct itself never crosses a process boundary — so this lean, dependency-free definition is
# the entire contract an extension needs to build against.

"""
    Widget(kind, params, default)

A `@bind` control's spec: its UI `kind::String`, display `params::Dict{String,Any}`, and
`default` value. Build one directly for a custom control kind — pair it with a front-end
`window.slateRegisterWidget("<kind>", …)` renderer — or return one from [`to_widget`](@ref) on
your own type.
"""
struct Widget
    kind::String
    params::Dict{String,Any}
    default::Any
end
Widget(kind::AbstractString, default = ""; params...) =
    Widget(String(kind), Dict{String,Any}(String(k) => v for (k, v) in params), default)

# NamedTuple params — the ergonomic authoring form (`Widget(kind, (; max = 5), 0)`); stored as the wire
# `Dict{String,Any}` bag. The 3-arg shape is unambiguous vs the 2-arg `Widget(kind, default)`.
Widget(kind::AbstractString, params::NamedTuple, default) =
    Widget(String(kind), Dict{String,Any}(String(k) => v for (k, v) in pairs(params)), default)

"""
    kind_for(T::Type) -> String

The wire `kind` derived for a widget TYPE — its module-qualified name (e.g. `"StarRating.Stars"`).
Because it's namespaced by the defining package, two packages can each ship a `Stars` widget without
their kinds colliding. Used by `Widget(T, …)` and [`register_component!`](@ref) so a type-based widget
never hand-types (and so never clashes on) a bare kind string.
"""
kind_for(::Type{T}) where {T} = string(parentmodule(T), '.', nameof(T))

"""
    Widget(T::Type, default=""; params...)

Build a `Widget` whose `kind` is derived from the widget TYPE `T` (see [`kind_for`](@ref)) — the
namespaced form. Use it in `to_widget` so the kind matches the one [`register_component!`](@ref)
registers, with no shared string to keep in sync:

```julia
SlateExtensionsBase.to_widget(s::Stars) = Widget(Stars, s.default; max = s.max)
```
"""
Widget(T::Type, default = ""; params...) = Widget(kind_for(T), default; params...)

"""
    auto_widget(x; value = :default, exclude = ()) -> Widget

Build a [`Widget`](@ref) by REFLECTING a struct's fields into `params` — the ergonomic `to_widget`
body when a widget's fields *are* its UI params. The `value` field (default `:default`) becomes the
`Widget`'s bound value (not a param); `nothing`-valued fields are skipped (so an unset `Union{Nothing,…}`
option is omitted); `exclude` drops named fields. The kind is `kind_for(typeof(x))`.

```julia
struct Stars; max::Int; label::Union{Nothing,String}; default::Int; end
SlateExtensionsBase.to_widget(s::Stars) = auto_widget(s)     # params = {max[, label]}, value = default
```

Opt-in on purpose — Slate never reflects a struct unless you ask, so an arbitrary value isn't silently
turned into a control, and you keep full control (write `Widget(kind_for(T), (;…), val)` by hand, or use
`exclude`, when not every field is a param).
"""
function auto_widget(x; value::Symbol = :default, exclude = ())
    T = typeof(x)
    value in fieldnames(T) || throw(ArgumentError(
        "auto_widget($T): no `$value` field to use as the bound value — name the value field `$value`, " *
        "pass `value = :yourfield`, or build the Widget explicitly (`Widget(kind_for($T), (; …), val)`)."))
    ex = (value, exclude...)
    params = Dict{String,Any}(String(f) => getfield(x, f)
                              for f in fieldnames(T) if f ∉ ex && getfield(x, f) !== nothing)
    return Widget(kind_for(T), params, getfield(x, value))
end

"""
    to_widget(x) -> Widget

Turn `x` into a [`Widget`](@ref). `@bind name x` calls this, so an extension can define its own
type and overload `to_widget` to get a typed, documented constructor (instead of a bare
`Widget("kind", …)`):

```julia
struct Mathfield; label::String; end
SlateExtensionsBase.to_widget(m::Mathfield) = Widget("mathfield", ""; label = m.label)
```

The identity method means an existing `Widget` (or a built-in constructor's result) passes
through unchanged.
"""
to_widget(w::Widget) = w
to_widget(x) = throw(ArgumentError(
    "@bind expected a Widget (or a value with a `SlateExtensionsBase.to_widget` method); got $(typeof(x))"))

# ── Choice / Selection — labeled-option value semantics ───────────────────────
# What a labeled option widget (Radio/Select/MultiSelect built from `value => label` pairs)
# binds to: it carries BOTH the selected value and its display label, but behaves like the value
# for comparison, display, hashing and interpolation — so `pick == "a"`, `Dict(opts)[pick]` and
# `"$(pick)"` all use the value, while `pick.label` gives the rendered text.

"""
    Choice(value, label, index = 0)

A labeled option's bound value: `.value`/`.v` is the real value, `.label`/`.l` the display
text, `.index`/`.i` its 1-based position. Compares, hashes, prints and converts as its value.
"""
struct Choice{V}
    value::V
    label::String
    index::Int            # 1-based position in the widget's option list (0 = unknown)
end
Choice(value, label) = Choice(value, label, 0)
Base.getproperty(c::Choice, s::Symbol) = s === :v ? getfield(c, :value) : s === :l ? getfield(c, :label) :
                                         s === :i ? getfield(c, :index) : getfield(c, s)
Base.propertynames(::Choice) = (:value, :label, :index, :v, :l, :i)
Base.show(io::IO, c::Choice) = show(io, getfield(c, :value))
Base.print(io::IO, c::Choice) = print(io, getfield(c, :value))
Base.string(c::Choice) = string(getfield(c, :value))
Base.:(==)(a::Choice, b::Choice) = getfield(a, :value) == getfield(b, :value)
Base.:(==)(a::Choice, b) = getfield(a, :value) == b
Base.:(==)(a, b::Choice) = a == getfield(b, :value)
# Both hash forms defer to the value, so a Choice is transparent as a dict KEY — including a
# Symbol value, whose one-arg `hash(::Symbol)` differs from `hash(sym, 0x0)` and is the form Dict
# indexes with (the two-arg method alone would mis-slot a Symbol-keyed lookup).
Base.hash(c::Choice) = hash(getfield(c, :value))
Base.hash(c::Choice, h::UInt) = hash(getfield(c, :value), h)
Base.isequal(a::Choice, b::Choice) = isequal(getfield(a, :value), getfield(b, :value))
# Transparent in CONVERT/INDEX contexts too — typed struct fields, typed local assignment,
# typed collections, indexing, and explicit numeric construction — so a labeled option's Choice
# flows wherever its bare value would through a `convert`. Restricted to SCALAR targets so it
# can't shadow the Choice→Choice conversion that `Choice[…]` collections depend on.
Base.convert(::Type{T}, c::Choice) where {T<:Union{Number,AbstractString,AbstractChar,Symbol}} =
    convert(T, getfield(c, :value))
(::Type{T})(c::Choice) where {T<:Number} = T(getfield(c, :value))
Base.to_index(c::Choice) = Base.to_index(getfield(c, :value))

"""
    Selection(items::Vector{Choice})

A multi-selection: an ordered, read-only `value => label` dict. `keys` → values, `values` →
labels, `sel[v]` → label, `haskey`, iteration yields `value => label`; [`indices`](@ref) gives
each pick's 1-based position in the original option list.
"""
struct Selection <: AbstractDict{Any,String}
    items::Vector{Choice}
end
Base.length(s::Selection) = length(s.items)
Base.iterate(s::Selection, i = 1) = i > length(s.items) ? nothing : (s.items[i].value => s.items[i].label, i + 1)
function Base.getindex(s::Selection, k)
    for c in s.items
        isequal(c.value, k) && return c.label
    end
    throw(KeyError(k))
end
Base.haskey(s::Selection, k) = any(c -> isequal(c.value, k), s.items)

"""
    indices(sel::Selection) -> Vector{Int}

Each selected option's 1-based position in the widget's original option list.
"""
indices(s::Selection) = Int[c.index for c in s.items]

# ── Per-kind behaviour registry ───────────────────────────────────────────────
# The value lifecycle of a control kind has three hooks; a kind registers whichever it needs and
# falls back to a sensible default for the rest. This is the SAME seam Slate's built-in kinds use
# (once core is wired onto this package), so a third-party kind is a first-class citizen.
#
#   coerce(w, v)              — a raw browser value (JSON number/string/bool/array) → the Julia value
#   reconcile(oldw, oldv, w)  — re-running a bind cell: keep the user's value unless it no longer fits
#   wrap(w, v)                — the registry value → the user-facing value (e.g. a Choice for labeled opts)

struct KindSpec
    coerce::Any       # (w::Widget, v) -> value
    reconcile::Any    # (oldw::Widget, oldv, neww::Widget) -> value
    wrap::Any         # (w::Widget, v) -> user-facing value
end

const _KINDS = Dict{String,KindSpec}()

"""
    coerce_value(::Type{T}, v) -> T

Coerce a raw browser value `v` (arriving as a JSON number / string / bool) to a control's VALUE TYPE
`T` — the type of its [`Widget`](@ref)'s `default`. Slate applies this automatically, with error-
fallback to the default, for any control that registers no custom `coerce` — so a typed widget (a
`Stars` whose `default::Int`) gets `Int`-safe values for free, no lifecycle code. Add a method for
your own value type to teach Slate how to coerce it:

```julia
SlateExtensionsBase.coerce_value(::Type{RGB}, v) = parse(RGB, string(v))
```

The fallback passes an unrecognised type through untouched (so a Dict/NamedTuple-valued widget is
unaffected). Built-in scalar coercions: Integer (rounds/parses), AbstractFloat, Bool, String, Symbol.
"""
coerce_value(::Type, v) = v                                        # unknown value type → pass through
coerce_value(::Type{T}, v) where {T<:Integer} =
    v isa Integer ? T(v) : v isa Number ? round(T, v) : parse(T, strip(string(v)))
coerce_value(::Type{T}, v) where {T<:AbstractFloat} =
    v isa Number ? T(v) : parse(T, strip(string(v)))
coerce_value(::Type{Bool}, v) = v === true || v == 1 || v == "true"
coerce_value(::Type{T}, v) where {T<:AbstractString} = T(string(v))
coerce_value(::Type{Symbol}, v) = Symbol(string(v))

# Defaults. `coerce` is TYPE-DRIVEN: coerce the browser value to the type of `w.default` via
# `coerce_value`, falling back to the default if that throws (a bad/unparseable value never errors the
# cell) — so a typed widget needs no `register_kind!` at all. `reconcile` keeps the user's value across
# a re-run (the kind-changed reset is generic, in `reconcile_bind`, so a per-kind reconciler only ever
# sees same-kind); `wrap` hands the raw value to the user.
_default_coerce(w::Widget, v) = try coerce_value(typeof(w.default), v) catch; w.default end
_default_reconcile(oldw::Widget, oldv, neww::Widget) = oldv
_default_wrap(::Widget, v) = v

# Derive coerce + reconcile from a declared DOMAIN (`domain(w)` → a numeric range or a collection of
# allowed values). Coerce = value-type-coerce, then restrict INTO the domain (clamp a range, else
# fall back to the default for a non-member); reconcile keeps the value only while it's still in the
# (possibly changed) domain. Lets a bounded widget declare WHAT its values are, not the clamp/round.
_restrict(d::AbstractRange, v, default) = clamp(v, first(d), last(d))
_restrict(d, v, default) = v in d ? v : default
_domain_coerce(domain) = (w::Widget, v) -> begin
    d = domain(w)
    cv = try coerce_value(eltype(d), v) catch; return w.default end
    _restrict(d, cv, w.default)
end
_domain_reconcile(domain) = (ow::Widget, ov, nw::Widget) -> (ov in domain(nw) ? ov : nw.default)

"""
    register_kind!(kind; coerce, reconcile, wrap, domain)

Register the value-lifecycle hooks for a control `kind`. **Everything is optional** — with none, Slate
uses a type-driven default: it coerces the browser value to the type of the widget's `default` (see
[`coerce_value`](@ref), with error-fallback) and keeps the value across a re-run. So a typed widget
often needs no call at all. Pass:

- `domain = w -> 0:w_max` — a numeric range or allowed-value collection; Slate derives `coerce`
  (coerce to the domain's type, then clamp/restrict into it) and `reconcile` (reset when out of domain).
- `coerce` / `reconcile` / `wrap` — raw closures, for a fully custom value lifecycle (e.g. a labeled
  option's index → `Choice`). An explicit hook wins over `domain`.

```julia
register_kind!("stars"; domain = w -> 0:Int(get(w.params, "max", 5)))   # bounds; or omit entirely
```
"""
function register_kind!(kind::AbstractString;
                        coerce = nothing, reconcile = nothing, wrap = _default_wrap, domain = nothing)
    co = coerce    !== nothing ? coerce    : domain !== nothing ? _domain_coerce(domain)    : _default_coerce
    re = reconcile !== nothing ? reconcile : domain !== nothing ? _domain_reconcile(domain) : _default_reconcile
    _KINDS[String(kind)] = KindSpec(co, re, wrap)
    return nothing
end

"Registered control kinds (built-ins once core is wired on, plus any extension kinds)."
widget_kinds() = sort!(collect(keys(_KINDS)))

_kind(kind::AbstractString) = get(_KINDS, String(kind), nothing)

"""
    coerce_bind(w::Widget, v)

Coerce a raw browser value against `w`'s registered kind (identity for an unregistered kind).
"""
coerce_bind(w::Widget, v) = (k = _kind(w.kind); k === nothing ? _default_coerce(w, v) : k.coerce(w, v))

"""
    reconcile_bind(oldw::Widget, oldv, neww::Widget)

The persistence policy when a bind cell re-runs: a changed widget kind always resets to the new
default; otherwise keep the user's value unless the new widget's kind rejects it (per-kind
reconciler, or keep-as-is for an unregistered kind).
"""
function reconcile_bind(oldw::Widget, oldv, neww::Widget)
    oldw.kind == neww.kind || return neww.default          # widget type changed → reset
    k = _kind(neww.kind)
    k === nothing ? _default_reconcile(oldw, oldv, neww) : k.reconcile(oldw, oldv, neww)
end

"""
    wrap_value(w::Widget, v)

The registry value → the user-facing value (e.g. a [`Choice`](@ref) for a labeled option).
Identity for an unregistered kind.
"""
wrap_value(w::Widget, v) = (k = _kind(w.kind); k === nothing ? _default_wrap(w, v) : k.wrap(w, v))
