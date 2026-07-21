using StarRating
using SlateExtensionsBase
using Test

@testset "StarRating extension (SDK end-to-end, Julia side)" begin
    # to_widget: the typed constructor produces the wire Widget of kind "stars".
    w = to_widget(Stars(; max = 5, label = "Rate it"))
    @test w isa Widget
    @test w.kind == "stars" && w.params["max"] == 5 && w.params["label"] == "Rate it" && w.default == 0
    @test to_widget(Stars(; max = 5, default = 3)).default == 3
    @test to_widget(Stars(; max = 5, default = 12)).default == 5      # default clamped into range
    @test !haskey(to_widget(Stars()).params, "label")                 # label omitted when absent

    # register_kind! (run by __init__): coerce clamps + rounds the browser value into 0:max.
    @test coerce_bind(w, 3.4) == 3
    @test coerce_bind(w, 99) == 5
    @test coerce_bind(w, -2) == 0
    @test coerce_bind(w, "x") == 0                                     # non-number → 0

    # reconcile keeps an in-range rating across a bind-cell re-run; resets when it no longer fits.
    @test reconcile_bind(w, 4, to_widget(Stars(; max = 5))) == 4
    @test reconcile_bind(w, 4, to_widget(Stars(; max = 3))) == 0       # 4 > new max → default
    @test reconcile_bind(w, 4, Widget("slider", 0)) == 0              # kind changed → new default (generic)

    # register_widget_js: the boot value renders a <script> that registers the front-end.
    s = sprint(show, MIME"text/html"(), stars_boot())
    @test occursin("slateRegisterWidget(\"stars\"", s)
    @test startswith(s, "<script>")
end
