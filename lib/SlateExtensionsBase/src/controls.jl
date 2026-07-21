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

# Defaults: an unknown kind passes its browser value through untouched (so a string-valued custom
# widget needs no coercion), keeps the user's value across a re-run (the kind-changed reset is
# handled generically in `reconcile_bind`, so a per-kind reconciler only ever sees same-kind), and
# hands the raw value to the user.
_default_coerce(::Widget, v) = v
_default_reconcile(oldw::Widget, oldv, neww::Widget) = oldv
_default_wrap(::Widget, v) = v

"""
    register_kind!(kind; coerce, reconcile, wrap)

Register the value-lifecycle hooks for a control `kind`. Each is optional and falls back to a
default (pass-through coerce, keep-across-rerun reconcile, identity wrap). Pair with a front-end
`window.slateRegisterWidget("<kind>", …)` (see [`register_widget_js`](@ref)).

```julia
register_kind!("mathfield"; coerce = (w, v) -> String(v))
```
"""
function register_kind!(kind::AbstractString;
                        coerce = _default_coerce, reconcile = _default_reconcile, wrap = _default_wrap)
    _KINDS[String(kind)] = KindSpec(coerce, reconcile, wrap)
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
