# Standalone tests for the durable declared-effect store (pure — stdlib TOML only).
using ReTest

include(joinpath(@__DIR__, "..", "src", "effectstore.jl"))

@testset "EffectStore" begin
    root = mktempdir()
    key = "abc123def"
    recs = [(; kind = :per_side, names = [:scale_add, :nsum], stmt_src = "@defop scale_add out = x")]

    @test EffectStore.load(root, key) === nothing            # nothing stored yet

    EffectStore.store!(root, key, recs)
    got = EffectStore.load(root, key)
    @test got !== nothing && length(got) == 1
    @test got[1].kind == :per_side
    @test got[1].names == [:scale_add, :nsum]
    @test occursin("scale_add", got[1].stmt_src)

    # Empty records REMOVE the stale file (the cell no longer declares anything).
    EffectStore.store!(root, key, [])
    @test EffectStore.load(root, key) === nothing

    # A hash-like key with filename-hostile characters still round-trips (sanitised stem).
    k2 = "-1234:xy/z"
    EffectStore.store!(root, k2, recs)
    @test EffectStore.load(root, k2) !== nothing

    # Multiple records preserve order + fields.
    multi = [(; kind = :per_side, names = [:a], stmt_src = "s1"),
             (; kind = :memoize,  names = Symbol[], stmt_src = "s2")]
    EffectStore.store!(root, "multi", multi)
    m = EffectStore.load(root, "multi")
    @test length(m) == 2 && m[1].kind == :per_side && m[2].kind == :memoize
    @test m[2].names == Symbol[] && m[2].stmt_src == "s2"
end
