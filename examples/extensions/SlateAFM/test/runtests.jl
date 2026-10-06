using Test
using SlateAFM
using SlateExtensionsBase: SlateExtensionsBase, Widget

# SlateAFM's front end is an anywidget ES module, so most of this package can only be exercised in a
# browser. These cover the parts that decide what the browser is HANDED — the wire `Widget` an `afm`
# reflects into, the trait merge across a re-run, and the handle a bound widget presents to notebook
# code. All three are pure, and all three have been wrong before.

@testset "SlateAFM" begin

@testset "afm reflects into its wire Widget" begin
    a = afm("https://esm.sh/x.js"; id = "m1", css = "https://esm.sh/x.css", count = 0, height = 400)
    w = SlateExtensionsBase.to_widget(a)
    @test w.kind == SlateAFM.KIND
    @test w.default == Dict{String,Any}("count" => 0, "height" => 400)   # traits ARE the bound value
    @test w.params["src"] == "https://esm.sh/x.js"
    @test w.params["id"] == "m1"
    @test w.params["css"] == ["https://esm.sh/x.css"]                     # a bare string becomes a list

    # `id` and `css` are omitted when unset rather than sent empty — the host shim branches on their
    # presence, so an empty string is not the same as absent.
    plain = SlateExtensionsBase.to_widget(afm("u.js"; n = 1))
    @test !haskey(plain.params, "id") && !haskey(plain.params, "css")
    @test collect(keys(plain.params)) == ["src"]
end

@testset "a re-run keeps widget state and takes new config from the source" begin
    # The trait dict is BOTH config the author writes in the `@bind` source (`height`) and state the
    # widget mutates through `save_changes()` (`count`). Carrying the whole old value forward freezes
    # config, so editing `height` in the source would never take; carrying none of it loses the
    # widget's state on every re-run. The rule is per-trait: a trait still at its OLD default is
    # config and follows the source, a trait the widget moved is state and survives.
    oldw = SlateExtensionsBase.to_widget(afm("u.js"; count = 0, height = 400))
    neww = SlateExtensionsBase.to_widget(afm("u.js"; count = 0, height = 600))   # author edited height
    oldv = Dict{String,Any}("count" => 7, "height" => 400)                       # widget counted up

    merged = SlateAFM._afm_reconcile(oldw, oldv, neww)
    @test merged["count"] == 7      # widget state survives the re-run
    @test merged["height"] == 600   # edited config takes effect

    # A trait the new source introduces appears; one the widget added that the source never had is
    # kept, since it cannot have been config.
    oldw2 = SlateExtensionsBase.to_widget(afm("u.js"; a = 1))
    neww2 = SlateExtensionsBase.to_widget(afm("u.js"; a = 1, b = 2))
    merged2 = SlateAFM._afm_reconcile(oldw2, Dict{String,Any}("a" => 1, "z" => 9), neww2)
    @test merged2["b"] == 2 && merged2["z"] == 9 && merged2["a"] == 1

    # Nothing to merge against → the new default stands, rather than erroring or keeping a stale value.
    @test SlateAFM._afm_reconcile(oldw, nothing, neww) == neww.default
    @test SlateAFM._afm_reconcile(oldw, "not a dict", neww) == neww.default
end

@testset "AFMHandle is dict-like and carries its id and props" begin
    h = SlateAFM.AFMHandle("m1", Dict{String,Any}("count" => 3, "label" => "hi"))
    @test h["count"] == 3
    @test length(h) == 2 && Set(keys(h)) == Set(["count", "label"])
    @test h.id == "m1"
    @test h.traits["label"] == "hi"

    # Any other property reads the props bag, so a driver's metadata is queryable by name; an unknown
    # one is a KeyError rather than a silent `nothing` a caller would propagate.
    getfield(h, :props)[:n_atoms] = 1234
    @test h.n_atoms == 1234
    @test :n_atoms in propertynames(h)
    @test_throws KeyError h.not_a_prop
end

@testset "show collapses a bulky prop instead of dumping it" begin
    # A driver stashes whole structures in `props` (a PDB is tens of kilobytes). Rendering one at the
    # REPL should stay a summary.
    h = SlateAFM.AFMHandle("m1", Dict{String,Any}())
    getfield(h, :props)[:pdb] = "X"^5000
    out = sprint(show, MIME"text/plain"(), h)
    @test occursin("5000 chars", out) && !occursin("XXXXXXXXXX", out)
    @test length(out) < 200
    @test sprint(show, h) == "AFMHandle(\"m1\")"
end

end
