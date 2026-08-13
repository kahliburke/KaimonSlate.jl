# Out-of-band callback registries (src/eval.jl): concurrent registration must not corrupt them.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

const RE_R = ReportEngine

@testset "callback registries are concurrency-safe" begin

    @testset "concurrent registration does not corrupt the Dict" begin
        # The failure this guards against: two tasks in `setindex!` at once leave the Dict's
        # internal storage half-written, and the next unrelated lookup throws
        # `UndefRefError` from `ht_keyindex2_shorthash!`. It surfaces on whichever notebook
        # touches the registry next, so the report blames a bystander.
        n = 400
        ids = ["nb-$i" for i in 1:n]
        @sync for id in ids
            Threads.@spawn RE_R.register_userprog!(id, (f, m, i, d) -> nothing)
        end
        @test all(id -> RE_R._reg_get(RE_R._USERPROG_REGISTRY, id) !== nothing, ids)
        @sync for id in ids
            Threads.@spawn RE_R.unregister_userprog!(id)
        end
        @test all(id -> RE_R._reg_get(RE_R._USERPROG_REGISTRY, id) === nothing, ids)
    end

    @testset "interleaved register / lookup / unregister stays consistent" begin
        # Readers run concurrently with writers, since the pollers route worker traffic while
        # notebooks are still being wired.
        ids = ["mix-$i" for i in 1:200]
        @sync begin
            for id in ids
                Threads.@spawn RE_R.register_refresh!(id, vars -> nothing)
                Threads.@spawn RE_R._reg_get(RE_R._REFRESH_REGISTRY, id)
            end
        end
        @test all(id -> RE_R._reg_get(RE_R._REFRESH_REGISTRY, id) !== nothing, ids)
        foreach(RE_R.unregister_refresh!, ids)
        @test all(id -> RE_R._reg_get(RE_R._REFRESH_REGISTRY, id) === nothing, ids)
    end

    @testset "a run-batch announcement says whether it starts a run" begin
        # The frontend keeps a running completed-count so the pill stays monotonic while cells are
        # queued mid-run, and can only clear it when told a NEW run began. Its other reset is an
        # idle gap, which never arrives in a notebook that streams continuously — so without this
        # flag the counters climb across everything, and a 36-cell notebook reports "386/394".
        seen = Tuple{Int,Bool}[]
        RE_R.register_runbatch!("rb", (n, fresh) -> push!(seen, (n, fresh)))
        RE_R._emit_run_batch("rb", 5)              # default: a user asked for work
        RE_R._emit_run_batch("rb", 3, false)       # a reactive cascade continuing the run
        RE_R._emit_run_batch("rb", 2, true)
        @test seen == [(5, true), (3, false), (2, true)]
        RE_R.unregister_runbatch!("rb")
    end

    @testset "every registry goes through the lock helpers" begin
        # A registry added later that writes its Dict directly would reintroduce the bug silently,
        # so assert the pattern rather than trusting review.
        src = read(joinpath(@__DIR__, "..", "src", "eval.jl"), String)
        @test !occursin(r"_REGISTRY\[String\(", src)
        @test !occursin(r"delete!\(_\w+_REGISTRY", src)
        @test !occursin(r"\bget\(_\w+_REGISTRY", src)
    end

    @testset "a callback is invoked outside the lock" begin
        # Holding the lock across a handler would serialise every notebook's live updates behind
        # the slowest one; a handler that registers another callback would deadlock on a plain
        # lock. Re-entering from inside a callback must simply work.
        RE_R.register_refresh!("outer", function (vars)
            RE_R.register_refresh!("inner-from-callback", v -> nothing)
            return nothing
        end)
        RE_R._do_refresh("outer", [:x])
        @test RE_R._reg_get(RE_R._REFRESH_REGISTRY, "inner-from-callback") !== nothing
        RE_R.unregister_refresh!("outer")
        RE_R.unregister_refresh!("inner-from-callback")
    end

end
