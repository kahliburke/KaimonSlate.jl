# The notebook namespace's shared registries, and why they are not plain `Dict`s.
#
# `__slate_handlers` (`slate_on` → a JS→Julia handler) and `__slate_cleanups` (per-cell teardown
# callbacks) are WRITTEN while a cell evaluates and READ from the WebSocket dispatch task at the
# same moment. A `Dict` is not safe under that, and the failure is not a clean error: a write during
# a rehash leaves a slot marked full whose key is undefined, and the next lookup throws
# `UndefRefError` from inside `ht_keyindex2_shorthash!` — reported from a sweep registering its
# status channel, nowhere near the code responsible.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine

@testset "a registry two tasks may touch at once" begin
    @testset "it is still a Dict to everyone who uses it" begin
        # Several call sites only know they were handed "some dict" (`_run_cell_cleanups!` takes an
        # `::AbstractDict`; the call route checks `hs isa AbstractDict`). Swapping the type in must
        # not change what any of them can do.
        s = RE.SyncDict{Any}()
        s["a"] = 1; s["b"] = 2
        @test s isa AbstractDict
        @test s["a"] == 1
        @test get(s, "missing", :none) === :none
        @test haskey(s, "b") && length(s) == 2
        @test sort(String.(keys(s))) == ["a", "b"]
        @test sort([k for (k, _) in s]) == ["a", "b"]
        delete!(s, "b")
        @test !haskey(s, "b")
        @test get!(s, "c", 3) == 3 && s["c"] == 3
        empty!(s)
        @test isempty(s)
    end

    @testset "pop! takes, so a cleanup cannot run twice" begin
        # `_run_cell_cleanups!` used to read the callbacks and then delete them. A cell can be torn
        # down from more than one direction at once (a re-run, a delete broadcast, a namespace
        # rebuild), and in the gap both callers got the same list — releasing one resource twice.
        s = RE.SyncDict{Vector{Any}}()
        s["cell"] = Any[() -> nothing]
        @test pop!(s, "cell", nothing) !== nothing
        @test pop!(s, "cell", nothing) === nothing
    end

    @testset "concurrent readers and writers do not corrupt it" begin
        # The reported crash, reproduced: on a plain `Dict` this raises; here it must not. Kept
        # modest so it stays quick, and asserted as ONE count rather than per-iteration.
        s = RE.SyncDict{Any}()
        bad = Threads.Atomic{Int}(0)
        ts = [Threads.@spawn (for i in 1:4000
                  try
                      s["k$(mod(i, 128))"] = i
                      get(s, "k$(mod(i, 64))", nothing)
                      haskey(s, "k$(mod(i, 32))")
                  catch
                      Threads.atomic_add!(bad, 1)
                  end
              end) for _ in 1:max(4, Threads.nthreads())]
        foreach(wait, ts)
        @test bad[] == 0
        @test length(s) == 128
    end

    @testset "the namespace really uses it" begin
        # The point is not that a synchronised dict exists, but that these two registries ARE one.
        # A future edit that puts a plain `Dict` back would pass every test above.
        src = read(joinpath(@__DIR__, "..", "src", "widgets.jl"), String)
        @test occursin("slate_handlers = SyncDict{Any}()", src)
        @test occursin("const __slate_cleanups = \$(SyncDict{Vector{Any}}())", src)
    end
end
