using StarRating
using SlateExtensionsBase
using Test

@testset "StarRating extension (SDK end-to-end, Julia side)" begin
    # to_widget = auto_widget: reflects the struct under a TYPE-DERIVED, namespaced kind — `default` is
    # the value, other fields are params, an unset `label` is skipped.
    w = to_widget(Stars(; max = 5, label = "Rate it"))
    @test w isa Widget
    @test w.kind == "StarRating.Stars"                                # namespaced by the package, no collision
    @test w.params["max"] == 5 && w.params["label"] == "Rate it" && w.default == 0
    @test !haskey(w.params, "default")                                # the value isn't duplicated into params
    @test to_widget(Stars(; max = 5, default = 3)).default == 3
    @test to_widget(Stars(; max = 5, default = 12)).default == 5      # default clamped into range (by Stars ctor)
    @test !haskey(to_widget(Stars()).params, "label")                 # label omitted when absent

    # No register_kind!: Slate infers the Int value type from `Stars`'s default and coerces to it.
    @test coerce_bind(w, 3.4) == 3 && coerce_bind(w, 3.4) isa Int      # JSON float → rounded Int
    @test coerce_bind(w, 7) == 7                                       # no domain declared ⇒ no clamp
    @test coerce_bind(w, "x") == 0                                     # unparseable → error-fallback to default

    # reconcile keeps the rating across a bind-cell re-run; a changed kind resets to the new default.
    @test reconcile_bind(w, 4, to_widget(Stars(; max = 5))) == 4
    @test reconcile_bind(w, 4, Widget("slider", 0)) == 0              # kind changed → new default (generic)

    # Front-end is declared by `required_assets(::Type{Stars})` and loaded LAZILY (no __init__): it's the
    # component module in assets/stars.js, registered only once Slate sees a `Stars`.
    id = "widget:StarRating.Stars"
    js = required_assets(Stars)
    @test occursin("export default", js)               # bare component module — no kind string in the JS
    @test occursin("@slate/widget", js)                # imports the widget SDK
    @test !occursin("registerComponent(", js)          # the author never names the kind; Slate wraps it

    # ensure_widget_assets! (what Slate's bind path calls) registers it under the namespaced kind, as a module.
    ensure_widget_assets!(Stars)
    stars = only(e for e in extension_manifest().frontend if e.id == id)
    @test stars.js == js && stars.esm == true && stars.kind == "StarRating.Stars"
end
