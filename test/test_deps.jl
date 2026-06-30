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
    end

end
