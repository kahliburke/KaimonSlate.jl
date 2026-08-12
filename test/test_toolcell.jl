# The TOOL cell kind (src/engine.jl, src/deps.jl): parse, round-trip, and run semantics.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

const RE_T = ReportEngine

@testset "tool cells" begin

    @testset "the kind parses and round-trips" begin
        src = """
        #%% md id=a
        # heading

        #%% tool id=call1
        @tool list_jobs()

        #%% code id=b
        1 + 1
        """
        r = RE_T.parse_report(src)
        kinds = Dict(c.id => c.kind for c in r.cells)
        @test kinds["call1"] === RE_T.TOOL
        @test kinds["a"] === RE_T.MARKDOWN
        @test kinds["b"] === RE_T.CODE
        # Round-trip: the header must serialize back to `tool`, or reopening a notebook silently
        # demotes every tool call to a code cell and they start auto-running again.
        round = RE_T.parse_report(RE_T.serialize_report(r))
        @test Dict(c.id => c.kind for c in round.cells)["call1"] === RE_T.TOOL
        @test occursin("#%% tool id=call1", RE_T.serialize_report(r))
    end

    @testset "the kind survives every token mapping" begin
        # Three agent-facing surfaces collapsed everything non-markdown to "code", so a tool cell
        # read back as an ordinary code cell and the kind looked like it had not been applied.
        @test RE_T._kind_token(RE_T.TOOL) == "tool"
        @test RE_T._kind_token(RE_T.WEB) == "web"
        @test RE_T._kind_token(RE_T.MARKDOWN) == "md"
        @test RE_T._kind_token(RE_T.CODE) == "code"
    end

    @testset "a tool cell is code for evaluation purposes" begin
        @test RE_T.is_code_kind(RE_T.TOOL)
        @test RE_T.is_code_kind(RE_T.CODE)
        @test RE_T.is_code_kind(RE_T.WEB)
        @test !RE_T.is_code_kind(RE_T.MARKDOWN)
    end

    @testset "a tool cell is excluded from automatic runs" begin
        @test !RE_T.runs_automatically(RE_T.TOOL)
        @test RE_T.runs_automatically(RE_T.CODE)
        @test RE_T.runs_automatically(RE_T.MARKDOWN)

        # The property that matters: a full run leaves the tool cell alone while running its
        # neighbours. Otherwise reopening a notebook re-launches whatever the tool starts.
        r = RE_T.parse_report("""
        #%% code id=setup
        x = 41

        #%% tool id=call
        x + 1

        #%% code id=after
        x + 100
        """)
        RE_T.eval_stale!(r)
        st = Dict(c.id => c.state for c in r.cells)
        @test st["setup"] === RE_T.FRESH
        @test st["after"] === RE_T.FRESH
        @test st["call"] === RE_T.STALE          # untouched by the automatic run
    end

    @testset "a tool cell still runs when asked directly" begin
        r = RE_T.parse_report("""
        #%% code id=setup
        y = 7

        #%% tool id=call
        y * 6
        """)
        RE_T.eval_stale!(r)                       # brings `setup` up, leaves `call` stale
        cell = r.cells[findfirst(c -> c.id == "call", r.cells)]
        @test cell.state === RE_T.STALE
        RE_T.eval_cell!(r, cell, RE_T.InProcessKernel())
        @test cell.state === RE_T.FRESH
        @test occursin("42", RE_T.output_html(cell))
    end

end
