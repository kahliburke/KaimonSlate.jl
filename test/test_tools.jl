# Session tool calls as cell values (src/tools.jl): expansion, dispatch, and rendering.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

const RE = ReportEngine

@testset "session tool calls" begin

    @testset "@tool expands to a slate_tool call" begin
        ex = RE._tool_expand(:(start_job(experiment = "M.Widget", max_epochs = 4)))
        @test ex.head === :call
        @test ex.args[1] === :slate_tool
        @test ex.args[2] == "start_job"
        v = ex.args[3]
        # STRING keys, not keyword syntax: the macro is built inside the notebook module, so
        # hygiene would qualify a keyword NAME into `(thismodule).run_id` and the call would not
        # parse. Values are escaped so they evaluate at the call site.
        @test v.head === :vect
        @test Set(p.args[2] for p in v.args) == Set(["experiment", "max_epochs"])
        @test all(p -> p.args[3] isa Expr && p.args[3].head === :escape, v.args)
    end

    @testset "the vector form is the same call as the keyword form" begin
        a = RE.slate_tool("no_such_tool_xyz"; alpha = 1, beta = "two")
        b = RE.slate_tool("no_such_tool_xyz", ["alpha" => 1, "beta" => "two"])
        @test a.args == b.args == ["alpha" => 1, "beta" => "two"]
    end

    @testset "@tool rejects what it cannot express" begin
        @test_throws ErrorException RE._tool_expand(:(not_a_call))
        # Positional arguments are refused rather than guessed at: a gate tool's parameters are
        # named, and silently binding by position is how a call ends up on the wrong argument.
        @test_throws ErrorException RE._tool_expand(:(job_status("a1b2c3d4")))
    end

    @testset "an unknown tool is a value, not an exception" begin
        # A failed call still renders: the panel is how you SEE what went wrong, so throwing here
        # would defeat the point of writing the call down as a cell.
        tc = RE.slate_tool("no_such_tool_xyz"; a = 1)
        @test tc isa RE.ToolCall
        @test !tc.ok
        @test occursin("no_such_tool_xyz", tc.error)
        @test tc.args == ["a" => 1]
    end

    @testset "no gate loaded is reported, not crashed" begin
        # The engine process has no KaimonGate; only the worker does. Every accessor is guarded, so
        # the helpers degrade to an empty registry instead of an UndefVarError.
        @test RE._session_tools() == Any[]
        @test RE._gate_module() === nothing
        @test RE.slate_tools() isa AbstractString      # the "nothing registered" notice
    end

    @testset "result records render as fields" begin
        # `key=value` run listings and `key: value` reports are the two shapes gate tools return.
        f = RE._result_fields("a1b2c3d4  kind=train  status=completed  epoch=4")
        @test ("kind" => "train") in f
        @test ("status" => "completed") in f
        g = RE._result_fields("path: /tmp/run/metrics.jsonl")
        @test g == ["path" => "/tmp/run/metrics.jsonl"]
        # Prose is left alone rather than shredded into bogus fields.
        @test isempty(RE._result_fields("started run 49765781, poll job_status for progress"))
    end

    @testset "html rendering shows the call, its schema slots and the outcome" begin
        tc = RE.ToolCall("demo_tool", ["max_epochs" => 4],
                         [Dict{String,Any}("name" => "experiment", "required" => true,
                                           "type_meta" => Dict{String,Any}("julia_type" => "String")),
                          Dict{String,Any}("name" => "max_epochs", "required" => false,
                                           "type_meta" => Dict{String,Any}("julia_type" => "Int64"))],
                         "A demo tool.", true, "started run abc123", "", 0.25, "12:00:00")
        html = sprint(show, MIME("text/html"), tc)
        @test occursin("demo_tool", html)
        @test occursin("max_epochs", html)
        @test occursin("Int64", html)
        # A required parameter this call did NOT supply is called out, which is the whole reason
        # the panel lists the tool's declared surface and not just what was sent.
        @test occursin("experiment", html)
        @test occursin("missing", html)
        @test occursin("ok", html)
        # Themed from CSS variables, never hardcoded colours, so it follows the active palette.
        @test occursin("var(--border)", html)
        @test !occursin("#15171c", html)
    end

    @testset "html escapes hostile content" begin
        tc = RE.ToolCall("x", ["a" => "<script>alert(1)</script>"], Dict{String,Any}[], "",
                         false, "", "<img onerror=1>", 0.0, "00:00:00")
        html = sprint(show, MIME("text/html"), tc)
        @test !occursin("<script>", html)
        @test occursin("&lt;script&gt;", html)
        @test !occursin("<img onerror", html)
    end

end
