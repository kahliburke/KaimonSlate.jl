# Standalone tests for the report engine model + parser (no project deps).
# Run:  julia --startup-file=no test/report/test_engine.jl
using Test
import Logging

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine

const SAMPLE = """
#%% md id=intro
# My Report
Narrative **markdown** here.

#%% code id=load
using Statistics
data = [1, 2, 3]

#%% code id=calc
mean(data)
"""

@testset "ReportEngine" begin

    @testset "parse: kinds, ids, sources" begin
        r = parse_report(SAMPLE; title = "My Report")
        @test length(r.cells) == 3

        @test r.cells[1].kind == MARKDOWN
        @test r.cells[1].id == "intro"
        @test r.cells[1].source == "# My Report\nNarrative **markdown** here."

        @test r.cells[2].kind == CODE
        @test r.cells[2].id == "load"
        @test r.cells[2].source == "using Statistics\ndata = [1, 2, 3]"

        @test r.cells[3].kind == CODE
        @test r.cells[3].id == "calc"
        @test r.cells[3].source == "mean(data)"
    end

    @testset "parse: defaults (kind=code, auto id)" begin
        r = parse_report("#%%\nx = 1")
        @test length(r.cells) == 1
        @test r.cells[1].kind == CODE            # kind defaults to code
        @test !isempty(r.cells[1].id)            # auto-assigned
        @test r.cells[1].source == "x = 1"
    end

    @testset "hybrid: pure-Literate input (# = md, bare = code)" begin
        literate = """
        # # Title
        # Some prose.

        x = 1
        y = 2

        # Another note.

        z = 3
        """
        r = parse_report(literate)
        @test length(r.cells) == 4
        @test r.cells[1].kind == MARKDOWN
        @test r.cells[1].source == "# Title\nSome prose."   # `# ` stripped, md heading kept
        @test r.cells[2].kind == CODE
        @test r.cells[2].source == "x = 1\ny = 2"
        @test r.cells[3].kind == MARKDOWN
        @test r.cells[3].source == "Another note."
        @test r.cells[4].kind == CODE
        @test r.cells[4].source == "z = 3"
    end

    @testset "hybrid: bare leading text is code, # lines are markdown" begin
        r = parse_report("# a note\n\nbare_code()\n\n#%% code id=a\ny = 2")
        @test length(r.cells) == 3
        @test r.cells[1].kind == MARKDOWN
        @test r.cells[1].source == "a note"
        @test r.cells[2].kind == CODE
        @test r.cells[2].source == "bare_code()"
        @test r.cells[3].id == "a"
        @test r.cells[3].source == "y = 2"
    end

    @testset "hybrid: ## is code (comment), not a markdown heading" begin
        r = parse_report("## not markdown\nval = 1")
        @test length(r.cells) == 1
        @test r.cells[1].kind == CODE
        @test r.cells[1].source == "## not markdown\nval = 1"
    end

    @testset "explicit md cell body is raw (not # -prefixed)" begin
        r = parse_report("#%% md id=m\n## A heading\nplain prose")
        @test r.cells[1].kind == MARKDOWN
        @test r.cells[1].source == "## A heading\nplain prose"
    end

    @testset "parse: blank-only input yields no cells" begin
        @test isempty(parse_report("\n\n   \n").cells)
    end

    @testset "blank edges trimmed, interior preserved" begin
        r = parse_report("#%% code id=a\n\nline1\n\nline2\n\n")
        @test r.cells[1].source == "line1\n\nline2"
    end

    @testset "src_hash tracks content" begin
        a = Cell("a", CODE, "x = 1")
        b = Cell("a", CODE, "x = 1")
        c = Cell("a", CODE, "x = 2")
        @test a.src_hash == b.src_hash
        @test a.src_hash != c.src_hash
    end

    @testset "round-trip: parse ∘ serialize is stable" begin
        r1 = parse_report(SAMPLE)
        s1 = serialize_report(r1)
        r2 = parse_report(s1)
        s2 = serialize_report(r2)

        @test s1 == s2                            # serialization is a fixed point
        @test length(r1.cells) == length(r2.cells)
        for (c1, c2) in zip(r1.cells, r2.cells)
            @test c1.id == c2.id
            @test c1.kind == c2.kind
            @test c1.source == c2.source
        end
    end

    @testset "controls= layout: columns, groups, round-trip" begin
        # bare list ⇒ one single-control column each (a row); back-compatible
        r = parse_report("#%% code id=plot controls=freq,amp,phase\nplot(freq, amp)")
        @test r.cells[1].id == "plot"
        @test r.cells[1].controls == [["freq"], ["amp"], ["phase"]]
        @test r.cells[1].source == "plot(freq, amp)"

        # `[a,b]` groups stack vertically in one column
        rg = parse_report("#%% code id=p controls=[freq,amp],phase,[gain,q]\nf()")
        g = rg.cells[1]
        @test g.controls == [["freq", "amp"], ["phase"], ["gain", "q"]]

        # absent by default; header token order is flexible
        @test isempty(parse_report("#%% code id=a\nx = 1").cells[1].controls)
        @test parse_report("#%% code controls=[a,b],c id=z\nf()").cells[1].controls == [["a", "b"], ["c"]]

        # empty entries dropped (stray/trailing commas, empty groups)
        @test parse_report("#%% code id=a controls=x,,[y,],\nf()").cells[1].controls == [["x"], ["y"]]

        # serialize emits the grammar (bare singles, [..] groups) and round-trips
        s = serialize_report(rg)
        @test occursin("controls=[freq,amp],phase,[gain,q]", s)
        r2 = parse_report(s)
        @test r2.cells[1].controls == [["freq", "amp"], ["phase"], ["gain", "q"]]
        @test serialize_report(r2) == s              # fixed point

        # cells without controls emit no `controls=` token
        @test !occursin("controls=", serialize_report(parse_report("#%% code id=a\nx = 1")))
    end

    @testset "auto ids survive a round-trip" begin
        r1 = parse_report("#%% code\nz = 3")     # no explicit id
        id1 = r1.cells[1].id
        r2 = parse_report(serialize_report(r1))   # id now written explicitly
        @test r2.cells[1].id == id1
    end

    @testset "progress-logging bridge → cell meter" begin
        rec = NamedTuple[]   # (id, frac, msg, done)
        lg = ReportEngine._ProgressLogger(Logging.NullLogger(),
                                          (i, f, m, d) -> push!(rec, (id = i, frac = f, msg = m, done = d)))
        Logging.with_logger(lg) do
            Logging.@logmsg Logging.LogLevel(-1) "train" progress = 0.5 _id = :bar1
            Logging.@logmsg Logging.LogLevel(-1) "inner" progress = 0.25 _id = :bar2   # a SECOND scope id
            Logging.@logmsg Logging.LogLevel(-1) "train" progress = "done" _id = :bar1
            @info "ordinary log — not progress"        # must NOT reach the sink
        end
        @test length(rec) == 3
        @test rec[1] == (id = "bar1", frac = 0.5, msg = "train", done = false)
        @test rec[2] == (id = "bar2", frac = 0.25, msg = "inner", done = false)   # distinct bar id
        @test rec[3] == (id = "bar1", frac = 1.0, msg = "train", done = true)      # "done" → remove bar
        # fraction coercion helper
        @test ReportEngine._progress_frac("done") == 1.0
        @test ReportEngine._progress_frac(nothing) == 0.0
        @test ReportEngine._progress_frac(2.0) == 1.0          # clamped
        @test ReportEngine._progress_sink(Module(:Bare))("", 0.5, "x", false) === nothing   # no slate_progress → no-op
    end

end
