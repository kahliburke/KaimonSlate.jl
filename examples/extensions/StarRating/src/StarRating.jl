"""
    StarRating

A sample Slate extension: a typed `@bind` star-rating control, built entirely against the lean
`SlateExtensionsBase` SDK (no KaimonSlate dependency). Use it in a Slate notebook:

```julia
using StarRating
@bind rating Stars(; max = 5, label = "How good?")
rating                             # an Int 0…max, reactive like any @bind
```

The whole widget is **three dispatch methods, no `__init__`**:
- [`Stars`](@ref) + `to_widget` — a typed constructor with its own docstring/dispatch. Because its
  `default::Int`, Slate coerces browser values to `Int` automatically (with error-fallback) — no value-
  lifecycle code needed. (Add `register_kind!("StarRating.Stars"; domain = w -> 0:…)` only to clamp bounds.)
- `required_assets(::Type{Stars})` — the front-end (a Preact/signals component module in `assets/stars.js`,
  read with `@pkg_asset`). Slate loads it LAZILY the first time a `Stars` is bound, under the type-derived
  kind — so no `__init__`, and only widgets a notebook actually uses load their JS.
"""
module StarRating

using SlateExtensionsBase

export Stars

"""
    Stars(; max = 5, label = nothing, default = 0)

A star-rating `@bind` control that binds an `Int` in `0:max`. `label` names it in the UI.
"""
struct Stars
    max::Int
    label::Union{Nothing,String}
    default::Int
end
Stars(; max::Int = 5, label = nothing, default::Int = 0) =
    Stars(max, label === nothing ? nothing : String(label), clamp(default, 0, max))

# The `to_widget` seam: reflect the struct into its wire `Widget`. `auto_widget` uses `default` as the
# value and the other fields (`max`, and `label` when set) as params, under the type-derived, namespaced
# kind "StarRating.Stars" — no manual param bag, no hand-typed kind string.
SlateExtensionsBase.to_widget(s::Stars) = auto_widget(s)

# The front-end: a Preact/signals component module in `assets/stars.js`. Slate loads it LAZILY the first
# time a `Stars` is bound (dispatch on the type), registering it under the derived kind — so there's no
# `__init__`, and a package's widget JS loads only when a notebook actually uses that widget.
SlateExtensionsBase.required_assets(::Type{Stars}) = @pkg_asset("assets/stars.js")

end # module
