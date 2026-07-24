"""
    StarRating

A sample Slate extension: a typed `@bind` star-rating control, built entirely against the lean
`SlateExtensionsBase` SDK (no KaimonSlate dependency). Use it in a Slate notebook:

```julia
using StarRating
@bind rating Stars(; max = 5, label = "How good?")
rating                             # an Int 0…max, reactive like any @bind
```

It doubles as a **testbed for the extension system**, exercising four SEB seams with no `__init__`:
- [`Stars`](@ref) + `to_widget` — a typed `@bind` control. Because its `default::Int`, Slate coerces
  browser values to `Int` automatically (with error-fallback). (Add `register_kind!("StarRating.Stars";
  domain = w -> 0:…)` only to clamp bounds.)
- `required_assets(::Type{Stars})` — the widget's front-end (a Preact/signals component in `assets/stars.js`,
  read with `@pkg_asset`). Slate loads it LAZILY the first time a `Stars` is bound — so only widgets a
  notebook actually uses load their JS.
- [`InsertStarsButton`](@ref) + `to_cell_action` — a per-cell TOOLBAR ACTION: a ★ button on every code
  cell that scaffolds a `@bind rating Stars()` snippet.
- An EDITOR extension — a CodeMirror keymap (Ctrl-Alt-8 inserts ★ on code cells).

The last two register from the package-global hook `__slate_frontend(slate_on)` (front-end shipped in
`assets/star_tools.js`), which Slate calls once per notebook that has StarRating loaded.
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

# ── Extension seams beyond the @bind widget ───────────────────────────────────────────────────────
# The `@bind` widget above needs no page-global front-end. These two do, so they register from the
# package-global hook `__slate_frontend(slate_on)` — Slate calls it once per notebook that has
# StarRating loaded (method-presence detection; no `__init__`, no boot cell).

"""
    InsertStarsButton(; icon, title, show, onclick)

A per-cell TOOLBAR ACTION (the toolbar counterpart of a `@bind` `Widget`): a ★ button Slate adds to
every code cell's header. Clicking it scaffolds a `@bind rating Stars()` snippet into that cell — the
front-end helper `window._starRatingInsert` (shipped in `assets/star_tools.js`) does the insert.
Authored the same way as a widget: a typed struct + a `to_cell_action` overload.
"""
Base.@kwdef struct InsertStarsButton
    icon::String    = "★"
    title::String   = "insert a Stars() rating control"
    show::String    = "cell.kind === 'code'"          # code cells only
    onclick::String = "window._starRatingInsert(cellId)"
end
SlateExtensionsBase.to_cell_action(b::InsertStarsButton) = auto_cell_action(b)

# The package-global front-end hook. `slate_on` (for JS→Julia RPC handlers) is unused here — this demo's
# extras are purely front-end — but the signature is fixed. Idempotent: `provide_frontend!` dedups by id
# and `register_cell_action!` by the action's id, so Slate can re-run it every drain safely.
function __slate_frontend(slate_on)
    # A page-global editor extension + the toolbar-action helper (one classic script).
    provide_frontend!(@pkg_asset("assets/star_tools.js"); id = "StarRating.tools")
    # A ★ button on every code cell's header toolbar.
    register_cell_action!(InsertStarsButton())
    return nothing
end

end # module
