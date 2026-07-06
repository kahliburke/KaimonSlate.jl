# Reactivity tests: binding inference, dependency graph, staleness, pruned eval.
# Needs ExpressionExplorer:
#   julia --startup-file=no --project=/tmp/report-devenv test/report/test_deps.jl
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

@testset "ReportEngine deps" begin

    @testset "binding inference: reads / writes" begin
        c = Cell("c", CODE, "y = x + 1"); infer_bindings!(c)
        @test :y in c.writes
        @test :x in c.reads

        c = Cell("c", CODE, "function f(a); a + b; end"); infer_bindings!(c)
        @test :f in c.writes                 # funcdef name is a write
        @test :b in c.reads

        c = Cell("c", CODE, "const K = 10"); infer_bindings!(c)
        @test :K in c.writes
    end

    @testset "_BIND_CACHE is bounded (no unbounded growth on a long-lived server)" begin
        empty!(ReportEngine._BIND_CACHE)
        # Fill past the cap with distinct cell ids; correctness survives the eviction sweep —
        # inference is recomputed (cheap), not skipped or corrupted. One aggregate @test instead of
        # one per cell — thousands of near-identical assertions don't add diagnostic value here.
        n = ReportEngine._BIND_CACHE_MAX + 5
        cells = [Cell("c$i", CODE, "v$i = $i") for i in 1:n]
        foreach(infer_bindings!, cells)
        @test all(i -> Symbol("v$i") in cells[i].writes, 1:n)
        @test length(ReportEngine._BIND_CACHE) <= ReportEngine._BIND_CACHE_MAX
        empty!(ReportEngine._BIND_CACHE)   # don't leak into other testsets' cache-hit assumptions
    end

    @testset "mutation heuristics add a write (and read)" begin
        for (src, sym) in (("push!(data, 4)", :data),
                           ("data[i] = 5", :data),
                           ("obj.field = 7", :obj),
                           ("v .= 1", :v))
            c = Cell("c", CODE, src); infer_bindings!(c)
            @test sym in c.writes
            @test sym in c.reads
        end
    end

    @testset "graph: most-recent-prior-writer" begin
        r = parse_report("#%% code id=a\nx = 1\n#%% code id=b\ny = x\n" *
                         "#%% code id=c\nx = 2\n#%% code id=d\nz = x")
        build_dependencies!(r)
        @test findcell(r, "b").deps == Set(["a"])    # reads first x
        @test findcell(r, "d").deps == Set(["c"])    # reads redefined x
        @test isempty(findcell(r, "a").deps)
        @test dependents_of(r, Set(["a"])) == Set(["a", "b"])
        @test dependents_of(r, Set(["c"])) == Set(["c", "d"])
    end

    @testset "mutation creates edge to the mutating cell, not the definer" begin
        r = parse_report("#%% code id=a\ndata = [1,2,3]\n" *
                         "#%% code id=b\npush!(data, 4)\n#%% code id=c\nsum(data)")
        build_dependencies!(r)
        @test "b" in findcell(r, "c").deps           # c depends on the mutation
        @test "a" ∉ findcell(r, "c").deps
    end

    @testset "pruned recompute: only stale cells re-run (output identity)" begin
        src1 = "#%% code id=a\nbase = 10\n#%% code id=b\nderived = base * 2\n" *
               "#%% code id=c\nindependent = 99"
        r = parse_report(src1)
        build_dependencies!(r)
        eval_stale!(r)                               # first run: all stale → all eval
        @test findcell(r, "b").output.value_repr == "20"
        outA = findcell(r, "a").output
        outB = findcell(r, "b").output
        outC = findcell(r, "c").output

        # edit only cell `a`
        src2 = replace(src1, "base = 10" => "base = 11")
        update_source!(r, src2)
        @test findcell(r, "a").state == STALE
        @test findcell(r, "b").state == STALE        # dependent of a
        @test findcell(r, "c").state == FRESH        # independent
        @test findcell(r, "c").output === outC       # carried over, untouched

        eval_stale!(r)
        @test findcell(r, "a").output !== outA       # re-ran
        @test findcell(r, "b").output !== outB       # re-ran (dependent)
        @test findcell(r, "c").output === outC       # NOT re-run
        @test findcell(r, "b").output.value_repr == "22"   # recomputed value
        # `independent` is created by eval_stale! (Core.eval) inside this testset; ReTest runs the body
        # in a fixed world, so read it via invokelatest to see the just-defined binding (1.12 world-age).
        @test Base.invokelatest(getproperty, r.mod, :independent) == 99
    end

    @testset "wildcard using / include are barriers" begin
        # A plain `using X` pulls in unknowable exports, and `include` runs unseen code →
        # both must stay barriers (downstream conservatively depends).
        for src in ("using Statistics", "include(\"x.jl\")")
            c = Cell("c", CODE, src); infer_bindings!(c)
            @test :opaque in c.flags
        end
        r = parse_report("#%% code id=a\nx = 1\n#%% code id=setup\nusing Statistics\n" *
                         "#%% code id=b\ny = 2")
        build_dependencies!(r)
        @test :opaque in findcell(r, "setup").flags
        @test "setup" in findcell(r, "b").deps               # downstream depends on the using
        @test "b" in dependents_of(r, Set(["setup"]))        # editing it restales downstream
    end

    @testset "precise import binds names, is NOT a blanket barrier" begin
        # `import X` / `import X: a` / `using X: a` bring KNOWN names → recorded as writes, so a
        # self-contained import doesn't chain every cell below it (only cells that USE the name dep).
        for (src, name) in (("import Dates", :Dates), ("import Dates: now", :now),
                            ("using Dates: now", :now), ("import Dates as D", :D))
            c = Cell("c", CODE, src); infer_bindings!(c)
            @test !(:opaque in c.flags)
            @test name in c.writes
        end
        r = parse_report("#%% code id=imp\nimport Dates\n" *
                         "#%% code id=user\nDates.today()\n" *
                         "#%% code id=indep\nz = 1")
        build_dependencies!(r)
        @test !(:opaque in findcell(r, "imp").flags)
        @test "imp" in findcell(r, "user").deps               # a cell that USES Dates depends on the import
        @test isempty(findcell(r, "indep").deps)              # an unrelated cell does NOT
        @test !("indep" in dependents_of(r, Set(["imp"])))    # re-running the import won't restale it
    end

    @testset "opaque cell becomes a barrier" begin
        bad = Cell("bad", CODE, "x = (")             # parse error → opaque
        infer_bindings!(bad)
        @test :opaque in bad.flags

        r = parse_report("#%% code id=a\nx = 1\n#%% code id=bad\nx = (\n" *
                         "#%% code id=c\ny = 2")
        build_dependencies!(r)
        @test :opaque in findcell(r, "bad").flags
        @test "bad" in findcell(r, "c").deps         # everything after depends on the barrier
        @test "a" in findcell(r, "bad").deps         # barrier depends on everything before
    end

    @testset "progressive `using` refinement: barrier becomes a precise import after it runs" begin
        # A bare `using X` is an :opaque barrier for STATIC analysis (unknowable exports), but once the
        # cell has run, X is loaded and `refine_usings!` (called at the end of eval_stale!) resolves the
        # real export set and rebuilds deps precisely — downstream depends on it only if it uses a name
        # X brings in. `Dates` is a project dep, so `using Dates` actually loads here.
        empty!(ReportEngine._USING_EXPORTS); empty!(ReportEngine._USING_TRIED); empty!(ReportEngine._BIND_CACHE)
        r = parse_report("#%% code id=u\nusing Dates\n" *
                         "#%% code id=user\np = Day(3)\n" *
                         "#%% code id=indep\nz = 1 + 1")
        build_dependencies!(r)
        @test :opaque in findcell(r, "u").flags            # bare using → barrier BEFORE it runs
        @test "u" in findcell(r, "indep").deps             # conservative: even an unrelated cell depends on it

        eval_stale!(r)                                     # runs all cells, then refines the `using` barrier
        @test !(:opaque in findcell(r, "u").flags)         # refined → no longer a barrier
        @test :Day in findcell(r, "u").writes              # exports recorded as precise writes
        @test "u" in findcell(r, "user").deps              # a cell that USES `Day` depends on it
        @test isempty(findcell(r, "indep").deps)           # an unrelated cell no longer does
        @test !("indep" in dependents_of(r, Set(["u"])))   # editing the using won't restale it
        empty!(ReportEngine._USING_EXPORTS); empty!(ReportEngine._USING_TRIED); empty!(ReportEngine._BIND_CACHE)
    end

    @testset "blank cell inserted above an opaque cell doesn't perturb its deps" begin
        # Regression: an :opaque cell depends on every prior cell that DEFINES something. A
        # contentless (blank) cell defines nothing, so inserting one above an opaque cell must not
        # change that cell's deps — else `_commit_reorder!` restales the whole downstream tail and
        # re-runs the notebook on a no-op insert.
        r = parse_report("#%% code id=a\nx = 1\n#%% code id=op\nx = (\n#%% code id=d\ny = 2")
        build_dependencies!(r)
        deps_before = copy(findcell(r, "op").deps)
        @test :opaque in findcell(r, "op").flags
        @test "a" in deps_before

        # insert an empty code cell at the very top (above `a`, well above the opaque cell)
        insert!(r.cells, 1, Cell("blank", CODE, ""))
        build_dependencies!(r)
        @test isempty(findcell(r, "blank").writes)
        @test findcell(r, "op").deps == deps_before          # unchanged → no spurious restale
        @test !("blank" in findcell(r, "op").deps)
        @test dependents_of(r, Set(["blank"])) == Set(["blank"])   # nothing downstream of a blank cell
    end

    @testset "multidef: names defined in 2+ cells are flagged" begin
        r = parse_report("#%% code id=a\nx = 1\ng() = 1\n#%% code id=b\nx = 2\n#%% code id=c\nz = 3")
        build_dependencies!(r)
        md = r.meta["multidef"]
        @test "x" in md            # defined in cells a and b
        @test !("g" in md)         # single definer
        @test !("z" in md)         # single definer
        # single-cell notebook → nothing flagged
        r2 = parse_report("#%% code id=a\nx = 1\ny = 2")
        build_dependencies!(r2)
        @test isempty(r2.meta["multidef"])
        # LOCALS mutated in place (let-block / comprehension / loop locals) must NOT count as global
        # writes — two cells each mutating their OWN same-named local is not a collision.
        r3 = parse_report("#%% code id=a\nlet\n  acc = zeros(3)\n  acc[1] = 1\n  push!(acc, 0.0)\n  sum(acc)\nend\n" *
                          "#%% code id=b\nlet\n  acc = zeros(2)\n  acc[2] = 9\n  sum(acc)\nend")
        build_dependencies!(r3)
        @test isempty(r3.meta["multidef"])          # `acc` is local to each cell — no real collision
        # …but two cells mutating the SAME GLOBAL in place IS still a real multi-writer collision.
        r4 = parse_report("#%% code id=a\nbuf[1] = 1\n#%% code id=b\npush!(buf, 2)")
        build_dependencies!(r4)
        @test "buf" in r4.meta["multidef"]
        # `using X` in TWO cells is NOT a collision — re-importing the same exports is a no-op, not a
        # redefinition (the reported bug). Seed the resolved-exports cache (normally filled post-eval).
        lock(ReportEngine._USING_LOCK) do; ReportEngine._USING_EXPORTS["FakeMod"] = [:foo, :bar]; end
        r5 = parse_report("#%% code id=a\nusing FakeMod\n#%% code id=b\nusing FakeMod\nfoo()\n")
        build_dependencies!(r5)
        @test isempty(r5.meta["multidef"])                       # foo/bar are PROVIDED (imported), not defined
        @test :foo in findcell(r5, "a").writes                   # …still in `writes` (so readers get a dep edge)
        @test :foo in findcell(r5, "a").provides                 # …and marked as provided, not a definition
        # a genuine redefinition ALONGSIDE the import is still flagged; the import name is not
        lock(ReportEngine._USING_LOCK) do; ReportEngine._USING_EXPORTS["FakeMod2"] = [:baz]; end
        r6 = parse_report("#%% code id=a\nusing FakeMod2\nq = 1\n#%% code id=b\nq = 2\n")
        build_dependencies!(r6)
        @test "q" in r6.meta["multidef"] && !("baz" in r6.meta["multidef"])
    end

end
