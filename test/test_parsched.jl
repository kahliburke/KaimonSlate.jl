# Unit tests for the pure parallel-readiness core (src/parsched.jl).
using Test
include(joinpath(@__DIR__, "..", "src", "parsched.jl"))

pc(id; deps = String[], reads = Symbol[], writes = Symbol[], opaque = false) =
    ParCell(id, Set(deps), Set(reads), Set(writes), opaque)

@testset "parsched" begin
    @testset "independent cells don't block each other" begin
        cells = [pc("a"; writes = [:x]), pc("b"; writes = [:y]), pc("c"; writes = [:z])]
        bl = par_blockers(cells)
        @test bl["a"] == Set{String}()
        @test bl["b"] == Set{String}()
        @test bl["c"] == Set{String}()
        @test co_runnable(["a", "b", "c"], bl)            # all three can run together
    end

    @testset "data dependency serializes a chain" begin
        cells = [pc("a"; writes = [:x]),
                 pc("b"; deps = ["a"], reads = [:x], writes = [:y]),
                 pc("c"; deps = ["b"], reads = [:y], writes = [:z])]
        bl = par_blockers(cells)
        @test bl["b"] == Set(["a"])
        @test bl["c"] == Set(["b"])
        @test !co_runnable(["a", "b"], bl)
    end

    @testset "reads-what-it-writes is a dependency even without explicit deps" begin
        cells = [pc("a"; writes = [:data]), pc("b"; reads = [:data], writes = [:out])]
        bl = par_blockers(cells)
        @test bl["b"] == Set(["a"])
    end

    @testset "write-write conflict serializes by document order" begin
        cells = [pc("a"; writes = [:x]), pc("b"; writes = [:x])]   # both define x
        bl = par_blockers(cells)
        @test bl["b"] == Set(["a"])                                # later waits for earlier
    end

    @testset "an opaque cell is a two-way barrier" begin
        cells = [pc("a"; writes = [:x]),
                 pc("u"; opaque = true),                            # e.g. `using Foo`
                 pc("b"; writes = [:y])]
        bl = par_blockers(cells)
        @test bl["u"] == Set(["a"])                                # waits for everything before
        @test bl["b"] == Set(["u"])                                # waits for the barrier (which already waits for a)
        @test !co_runnable(["u", "b"], bl)                         # so b is transitively after a too
    end

    @testset "run_scheduled: order recorded, every cell evaluated" begin
        cells = [pc("a"; writes = [:x]),
                 pc("b"; deps = ["a"], reads = [:x], writes = [:y]),
                 pc("c"; deps = ["b"], reads = [:y], writes = [:z])]
        order = String[]
        lk = ReentrantLock()
        res = run_scheduled(cells, 4, id -> (lock(lk) do; push!(order, id); end; "ran:$id"))
        @test res == Dict("a" => "ran:a", "b" => "ran:b", "c" => "ran:c")
        @test order == ["a", "b", "c"]                    # a strict chain runs in order
    end

    @testset "run_scheduled: independent cells actually overlap" begin
        # Three independent cells, pool of 3: they must run CONCURRENTLY (peak ≥ 2),
        # not one-at-a-time. Each holds its slot briefly so overlap is observable.
        cells = [pc("a"; writes = [:x]), pc("b"; writes = [:y]), pc("c"; writes = [:z])]
        active = Threads.Atomic{Int}(0)
        peak = Threads.Atomic{Int}(0)
        evalfn = function (_id)
            Threads.atomic_max!(peak, Threads.atomic_add!(active, 1) + 1)
            sleep(0.05)
            Threads.atomic_sub!(active, 1)
            return _id
        end
        run_scheduled(cells, 3, evalfn)
        @test peak[] >= 2                                 # genuine overlap (not serialized)
    end

    @testset "run_scheduled: a chain never overlaps" begin
        # a → b → c by data dependency: at no point may two run together, whatever the pool size.
        cells = [pc("a"; writes = [:x]),
                 pc("b"; deps = ["a"], reads = [:x], writes = [:y]),
                 pc("c"; deps = ["b"], reads = [:y], writes = [:z])]
        active = Threads.Atomic{Int}(0)
        peak = Threads.Atomic{Int}(0)
        evalfn = function (_id)
            Threads.atomic_max!(peak, Threads.atomic_add!(active, 1) + 1)
            sleep(0.03)
            Threads.atomic_sub!(active, 1)
            return _id
        end
        run_scheduled(cells, 8, evalfn)
        @test peak[] == 1                                 # serialized despite an 8-wide pool
    end

    @testset "run_scheduled: a thrown cell is captured, batch still drains" begin
        cells = [pc("a"; writes = [:x]), pc("b"; writes = [:y])]
        res = run_scheduled(cells, 2, id -> id == "a" ? error("boom") : "ok")
        @test res["a"] isa Exception                      # the throw became this cell's result
        @test res["b"] == "ok"                            # the other cell still completed
    end

    @testset "run_scheduled: ondone fires once per cell with its result" begin
        cells = [pc("a"; writes = [:x]), pc("b"; deps = ["a"], reads = [:x])]
        seen = Tuple{String,Any}[]
        lk = ReentrantLock()
        run_scheduled(cells, 2, id -> "v:$id", (id, r) -> (lock(lk) do; push!(seen, (id, r)); end))
        @test Set(seen) == Set([("a", "v:a"), ("b", "v:b")])
    end

    @testset "mixed: independent pair after a shared dependency" begin
        # base → (left, right) independent → join
        cells = [pc("base"; writes = [:v]),
                 pc("left"; deps = ["base"], reads = [:v], writes = [:l]),
                 pc("right"; deps = ["base"], reads = [:v], writes = [:r]),
                 pc("join"; deps = ["left", "right"], reads = [:l, :r], writes = [:j])]
        bl = par_blockers(cells)
        @test bl["left"] == Set(["base"]) && bl["right"] == Set(["base"])
        @test co_runnable(["left", "right"], bl)                   # the fork runs in parallel
        @test bl["join"] == Set(["left", "right"])
        @test !co_runnable(["left", "join"], bl)
    end
end
