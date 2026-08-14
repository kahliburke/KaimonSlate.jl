# Session tool calls as cell values (src/tools.jl): expansion, dispatch, and rendering.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

const RE = ReportEngine

@testset "session tool calls" begin

    @testset "@tool expands to a slate_tool call" begin
        ex = RE._tool_expand(:(start_job(target = "M.Widget", size = 4)))
        @test ex.head === :call
        @test ex.args[1] === :slate_tool
        @test ex.args[2] == "start_job"
        v = ex.args[3]
        # STRING keys, not keyword syntax: the macro is built inside the notebook module, so
        # hygiene would qualify a keyword NAME into `(thismodule).job_id` and the call would not
        # parse. Values are escaped so they evaluate at the call site.
        @test v.head === :vect
        @test Set(p.args[2] for p in v.args) == Set(["target", "size"])
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
        @test tc.args == ["a" => 1]
        # In this process there is no gate at all, so the error says THAT rather than listing the
        # tools you could have meant — which is the more useful message of the two branches here.
        @test occursin("gate", tc.error)
    end

    @testset "no gate loaded is reported, not crashed" begin
        # The engine process has no KaimonGate; only the worker does. Every accessor is guarded, so
        # the helpers degrade to an empty registry instead of an UndefVarError.
        @test RE._session_tools() == Any[]
        @test RE._gate_module() === nothing
        @test RE.slate_tools() isa AbstractString      # the "nothing registered" notice
    end

    @testset "the summary line skips a leading fenced signature" begin
        # A gate tool's docstring opens with a fenced signature, so a naive "first line" is a ```
        # fence and the next is the signature — the summary column came out empty.
        doc = "```julia\nstart_job(target; size) -> String\n```\n\nStart a job.\n"
        @test RE._first_prose_line(doc) == "Start a job."
        @test RE._first_prose_line("") == ""
        @test RE._first_prose_line("```\nonly a fence\n```") == ""
        @test RE._first_prose_line("plain first line\nsecond") == "plain first line"
    end

    @testset "result records render as fields" begin
        # `key=value` run listings and `key: value` reports are the two shapes gate tools return.
        f = RE._result_fields("a1b2c3d4  kind=build  status=completed  step=4")
        @test ("kind" => "build") in f
        @test ("status" => "completed") in f
        g = RE._result_fields("path: /tmp/run/metrics.jsonl")
        @test g == ["path" => "/tmp/run/metrics.jsonl"]
        # Prose is left alone rather than shredded into bogus fields — including prose that happens
        # to CONTAIN key=value fragments, which is what start_job's own reply looks like.
        @test isempty(RE._result_fields("started job 49765781, poll job_status for progress"))
        @test isempty(RE._result_fields(
            "started job 9fef1170 (kind=build, target=Main.NB.Widget). " *
            "Poll `job_status(job_id=\"9fef1170\")`; stop with `job_cancel(job_id=\"9fef1170\")`."))
        # A genuine multi-job listing still parses.
        @test length(RE._result_fields("a1 kind=build status=done\nb2 kind=check status=failed")) == 4
    end

    @testset "a reply's backticked calls become follow-ups" begin
        # A background tool cannot return its outcome, so it returns a handle and NAMES the call
        # that reads it. That sentence is the whole contract the panel needs.
        fs = RE._followups(
            "started job 9fef1170 (kind=build, target=Main.NB.Widget). " *
            "Poll `job_status(job_id=\"9fef1170\")`; stop with `job_cancel(job_id=\"9fef1170\")`.")
        @test [f.name for f in fs] == ["job_status", "job_cancel"]
        @test fs[1].args == ["job_id" => "9fef1170"]
        # Only the prose says which one tracks the work to completion.
        @test fs[1].poll && !fs[2].poll
        @test isempty(RE._followups("run stopped; nothing further."))
        # The same call named twice is one follow-up, not two buttons.
        @test length(RE._followups("`a_tool(id=\"x\")` and again `a_tool(id=\"x\")`")) == 1
        # Unquoted and multi-argument forms parse too.
        @test only(RE._followups("`t(a=1, b=\"two\")`")).args == ["a" => "1", "b" => "two"]
        # The poll marker is read from the CLAUSE, not a character window: a long first call must
        # not push "Poll" into reach of the second one and mark both.
        g = RE._followups("Poll `s(id=\"1\")`; stop with `c(id=\"1\")`.")
        @test g[1].poll && !g[2].poll
        h = RE._followups("Poll `a_very_much_longer_status_tool(id=\"1\")`; stop with `c(id=\"1\")`.")
        @test h[1].poll && !h[2].poll
        # A clause boundary is what separates them, so a newline works as well as a semicolon.
        n = RE._followups("Poll `s(id=\"1\")`\nOr cancel with `c(id=\"1\")`")
        @test n[1].poll && !n[2].poll
    end

    @testset "a poll result says whether to keep polling" begin
        @test RE._poll_state("run a1  kind=build  target=M.E  status=running") == "running"
        @test RE._poll_state("run a1  kind=build  target=M.E  status=completed") == "done"
        @test RE._poll_state("run a1  kind=build  target=M.E  status=failed") == "done"
        # A reply that never says where it got to is polled once, not chased on a timer forever.
        @test RE._poll_state("all quiet") == "unknown"
    end

    @testset "the handle is read off the follow-up, not the prose" begin
        tc = RE.ToolCall("start_job", Pair{String,Any}[], Dict{String,Any}[], "", true,
                         "started job 9fef1170. Poll `job_status(job_id=\"9fef1170\")`.",
                         "", 0.1, "00:00:00")
        @test RE.tool_handle(tc) == "9fef1170"
        # A call with nothing to track has no handle, and no follow-ups to render.
        plain = RE.ToolCall("list_jobs", Pair{String,Any}[], Dict{String,Any}[], "", true,
                            "no jobs", "", 0.1, "00:00:00")
        @test RE.tool_handle(plain) === nothing && isempty(plain.followups)
        # A failed call advertises nothing: its error text is not a contract.
        bad = RE.ToolCall("t", Pair{String,Any}[], Dict{String,Any}[], "", false, "",
                          "see `job_status(job_id=\"x\")`", 0.1, "00:00:00")
        @test isempty(bad.followups)
    end

    @testset "a tracked call renders follow-up buttons and polls" begin
        tc = RE.ToolCall("start_job", Pair{String,Any}[], Dict{String,Any}[], "", true,
                         "started job 9fef1170. Poll `job_status(job_id=\"9fef1170\")`; " *
                         "stop with `job_cancel(job_id=\"9fef1170\")`.",
                         "", 0.1, "00:00:00", "__tool:start_job")
        html = sprint(show, MIME("text/html"), tc)
        @test occursin("data-follow=\"job_status\"", html)
        @test occursin("data-follow=\"job_cancel\"", html)
        @test occursin("data-poll", html)                       # only the polled one is a timer
        @test occursin("&quot;job_id&quot;:&quot;9fef1170&quot;", html)   # args ride in an attribute
        @test occursin("setInterval", html)
        @test occursin("9fef1170", html)                        # the handle, held in the header
        # Without a channel there is nothing to call back on, so no dead buttons.
        inert = RE.ToolCall("start_job", Pair{String,Any}[], Dict{String,Any}[], "", true,
                            "started job 9fef1170. Poll `job_status(job_id=\"9fef1170\")`.",
                            "", 0.1, "00:00:00")
        @test !occursin("data-follow", sprint(show, MIME("text/html"), inert))
    end

    @testset "a parameter's declared type chooses its control" begin
        meta(kind; vals = nothing) = Dict{String,Any}("name" => "p", "required" => false,
            "type_meta" => vals === nothing ? Dict{String,Any}("kind" => kind) :
                           Dict{String,Any}("kind" => kind, "enum_values" => vals))
        @test occursin("type=\"number\" step=\"1\"", RE._arg_control("p", meta("integer"), nothing))
        @test occursin("type=\"number\" step=\"any\"", RE._arg_control("p", meta("number"), nothing))
        # A Bool is a choice, not a free-text box you can type "ture" into.
        b = RE._arg_control("p", meta("boolean"), true)
        @test occursin("<select", b) && occursin("value=\"true\" selected", b)
        e = RE._arg_control("p", meta("enum"; vals = ["cpu", "gpu"]), "gpu")
        @test occursin("value=\"gpu\" selected", e) && occursin("cpu", e)
        # An unsupplied optional keeps the empty option selected, which is how the call omits it.
        @test occursin("value=\"\" selected", RE._arg_control("p", meta("enum"; vals = ["a"]), nothing))
        @test occursin("<input", RE._arg_control("p", meta("string"), "x"))
        # An older gate (and a hand-built parameter) carries only the Julia type name.
        legacy = Dict{String,Any}("name" => "p", "type_meta" => Dict{String,Any}("julia_type" => "Int64"))
        @test occursin("type=\"number\"", RE._arg_control("p", legacy, nothing))
    end

    @testset "html rendering shows the call, its schema slots and the outcome" begin
        tc = RE.ToolCall("demo_tool", ["size" => 4],
                         [Dict{String,Any}("name" => "target", "required" => true,
                                           "type_meta" => Dict{String,Any}("julia_type" => "String")),
                          Dict{String,Any}("name" => "size", "required" => false,
                                           "type_meta" => Dict{String,Any}("julia_type" => "Int64"))],
                         "A demo tool.", true, "started job abc123", "", 0.25, "12:00:00")
        html = sprint(show, MIME("text/html"), tc)
        @test occursin("demo_tool", html)
        @test occursin("size", html)
        @test occursin("Int64", html)
        # A required parameter this call did NOT supply is called out, which is the whole reason
        # the panel lists the tool's declared surface and not just what was sent.
        @test occursin("target", html)
        @test occursin("missing", html)
        @test occursin("ok", html)
        # Themed from CSS variables, never hardcoded colours, so it follows the active palette.
        @test occursin("var(--border)", html)
        @test !occursin("#15171c", html)
    end

    @testset "browser values are recovered to literals" begin
        # A text input hands back strings; the gate's dispatcher coerces against the signature, so
        # only the literals text cannot carry need recovering here.
        @test RE._parse_arg("4") === 4
        @test RE._parse_arg("2.5") === 2.5
        @test RE._parse_arg("true") === true
        @test RE._parse_arg("false") === false
        @test RE._parse_arg("Main.NB.Widget") == "Main.NB.Widget"
        @test RE._parse_arg("lr=2e-3, tag=\"x\"") == "lr=2e-3, tag=\"x\""
        @test RE._parse_arg(7) === 7          # non-strings pass through untouched
    end

    @testset "a panel with a channel is invokable, without one is inert" begin
        params = [Dict{String,Any}("name" => "job_id", "required" => true,
                                   "type_meta" => Dict{String,Any}("julia_type" => "String"))]
        live = RE.ToolCall("t", ["job_id" => "abc"], params, "", true, "fine", "", 0.1,
                           "00:00:00", "__tool:t")
        inert = RE.ToolCall("t", ["job_id" => "abc"], params, "", true, "fine", "", 0.1, "00:00:00")
        lh, ih = sprint(show, MIME("text/html"), live), sprint(show, MIME("text/html"), inert)
        @test occursin("data-invoke", lh) && occursin("slateCall", lh)
        @test occursin("input data-arg=\"job_id\"", lh)
        # No channel (a hand-built call, or no gate) → a plain read-only panel, no dead button.
        @test !occursin("data-invoke", ih) && !occursin("slateCall", ih)
        @test occursin("abc", ih)
    end

    @testset "a recorded call is a panel, not a transcript" begin
        # An agent's call is observed after the fact, so nothing is dispatched — but it renders as
        # the panel a `@tool` cell renders, which is what lets it track the run it started.
        handlers = Dict{String,Any}()
        tc = RE.recorded_toolcall("start_job", Pair{String,Any}["size" => 4], true,
                                  "started job 9fef1170. Poll `job_status(job_id=\"9fef1170\")`.",
                                  0.42, "09:15:00"; handlers)
        @test tc.ok && tc.result == "started job 9fef1170. Poll `job_status(job_id=\"9fef1170\")`."
        @test RE.tool_handle(tc) == "9fef1170"
        @test tc.channel == "__tool:start_job"
        @test haskey(handlers, "__tool:start_job")     # the panel can call back
        @test occursin("data-follow=\"job_status\"", sprint(show, MIME("text/html"), tc))
        # A failed call keeps its text on the error side, and nowhere to call back is inert.
        bad = RE.recorded_toolcall("t", Pair{String,Any}[], false, "boom", 0.1, "09:15:00")
        @test !bad.ok && bad.error == "boom" && bad.channel == ""
    end

    @testset "a recorded call renders as re-runnable source" begin
        # The materialised cell has to be a call an author could have written, not a transcript,
        # or the reader cannot re-fire it.
        @test RE.toolcall_source("list_jobs", Pair{String,Any}[]) == "@tool list_jobs()"
        s = RE.toolcall_source("start_job",
                               Pair{String,Any}["target" => "M.Widget", "size" => 4])
        @test occursin("@tool start_job(", s)
        @test occursin("target = \"M.Widget\"", s)   # strings keep their quotes: it must parse
        @test occursin("size = 4", s)
        # Round-trips through `@tool`: parsing the source gives the macrocall, whose third argument
        # is the call `_tool_expand` rewrites.
        @test RE._tool_expand(Meta.parse(s).args[3]).args[2] == "start_job"
    end

    @testset "html escapes hostile content" begin
        # The argument needs a DECLARED parameter to be rendered at all — the panel shows the tool's
        # schema, not whatever was thrown at it — so the hostile value has to reach a real row.
        params = [Dict{String,Any}("name" => "a", "required" => false,
                                   "type_meta" => Dict{String,Any}("julia_type" => "String"))]
        tc = RE.ToolCall("x", ["a" => "<script>alert(1)</script>"], params, "",
                         false, "", "<img onerror=1>", 0.0, "00:00:00")
        html = sprint(show, MIME("text/html"), tc)
        @test !occursin("<script>", html)
        @test occursin("&lt;script&gt;", html)
        @test !occursin("<img onerror", html)
        @test occursin("&lt;img onerror=1&gt;", html)
        # And in a LIVE panel, where the value goes into a control's ATTRIBUTE — so the quote that
        # would break out of it has to be escaped too. (The panel carries its own wiring `<script>`,
        # which is why the check is on the value and not on the tag.)
        live = sprint(show, MIME("text/html"),
                      RE.ToolCall("x", ["a" => "\"><script>alert(1)</script>"], params, "",
                                  true, "ok", "", 0.0, "00:00:00", "__tool:x"))
        @test occursin("value=\"&quot;&gt;&lt;script&gt;", live)
        @test !occursin("\"><script>", live)
    end

end
