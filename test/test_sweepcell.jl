# The `#%% sweep` cell kind: parse/serialize round-trip and the kind predicates that decide how the
# engine treats it. The lifecycle and the renderer are separate; this is the plumbing that has to be
# right before either can be built, because it is what every notebook file on disk depends on.
using ReTest
import KaimonSlate
const RE = KaimonSlate.ReportEngine

findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

@testset "sweep cell kind" begin
    @testset "parses from the header token" begin
        r = RE.parse_report("""
        #%% sweep id=scan
        @sweep(grid, target) do p
            work(p)
        end
        """)
        c = findcell(r, "scan")
        @test c.kind === RE.SWEEP
        @test occursin("@sweep", c.source)
    end

    @testset "round-trips through serialization" begin
        src = """
        #%% md id=intro
        # A sweep

        #%% sweep id=scan
        @sweep(grid, target) do p
            work(p)
        end

        #%% code id=after
        summary = length(scan)
        """
        r = RE.parse_report(src)
        out = RE.serialize_report(r)
        @test occursin("#%% sweep id=scan", out)
        r2 = RE.parse_report(out)
        @test [c.kind for c in r2.cells] == [c.kind for c in r.cells]
        @test findcell(r2, "scan").kind === RE.SWEEP
        @test findcell(r2, "after").kind === RE.CODE
    end

    @testset "header tags survive alongside the kind" begin
        # Target and resources ride in the header so the tag editor can drive them without the
        # author editing Julia.
        r = RE.parse_report("""
        #%% sweep id=scan collapsed
        @sweep(grid, target) do p; work(p); end
        """)
        c = findcell(r, "scan")
        @test c.kind === RE.SWEEP
        @test :collapsed in c.flags
        @test occursin("#%% sweep id=scan", RE.serialize_report(r))
        @test occursin("collapsed", RE.serialize_report(r))
    end

    @testset "is evaluated, and participates in the graph, exactly like code" begin
        # This is what buys full DAG integration for free: deps, capture, staleness, memoization.
        @test RE.is_code_kind(RE.SWEEP)
        @test RE.is_code_kind(RE.CODE)
        @test !RE.is_code_kind(RE.MARKDOWN)
    end

    @testset "runs automatically, unlike a tool call" begin
        # Evaluating a sweep cell RECONCILES (reads the store and the scheduler); it does not submit.
        # That is what makes reopening a notebook safe, so unlike TOOL it is not excluded from
        # automatic runs — otherwise a reopened notebook could never show progress on its own.
        @test RE.runs_automatically(RE.SWEEP)
        @test !RE.runs_automatically(RE.TOOL)
    end

    @testset "dependencies are inferred from the body" begin
        # A plain call, not the `@sweep` macro: expanding an unknown macro needs a kernel
        # (`resolve_macros!`), which is an orthogonal mechanism Slate already has. What is being
        # checked here is that the KIND participates in the graph at all.
        r = RE.parse_report("""
        #%% code id=g
        grid = [1, 2, 3]

        #%% sweep id=scan
        results = run_sweep(grid, tgt)

        #%% code id=plot
        total = sum(results)
        """)
        RE.build_dependencies!(r)
        @test :grid in findcell(r, "scan").reads
        @test :results in findcell(r, "plot").reads
        @test "scan" in findcell(r, "plot").deps
    end
end
