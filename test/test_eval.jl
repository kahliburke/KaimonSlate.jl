# Standalone tests for isolated-module evaluation (Base only, no session).
# Run:  julia --startup-file=no test/report/test_eval.jl
using Test

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine

@testset "ReportEngine eval" begin

    @testset "cross-cell state sharing (warm namespace)" begin
        r = parse_report("#%% code id=a\ndata = [1, 2, 3]\n\n#%% code id=b\nsum(data)")
        eval_report!(r)
        @test r.cells[1].state == FRESH
        @test r.cells[2].state == FRESH
        @test r.cells[2].output.value_repr == "6"
    end

    @testset "rich capture of an in-notebook-defined show method (world age)" begin
        # A cell defines a type + its text/latex `show`; a later cell returns an
        # instance. The capture must see the just-defined method on FIRST eval and
        # on RE-EVAL in the same warm module (the "empty until Rebuild" regression).
        src = "#%% code id=def\nstruct TXW; s::String; end\n" *
              "Base.show(io::IO, ::MIME\"text/latex\", t::TXW) = print(io, t.s)\n" *
              "#%% code id=val\nTXW(\"HELLO\")\n"
        r = parse_report(src); build_dependencies!(r)
        k = InProcessKernel()
        eval_stale!(r, k)
        o1 = r.cells[2].output
        @test !isempty(o1.display)
        @test o1.display[1].mime == "text/latex"
        @test String(copy(o1.display[1].data)) == "HELLO"
        # re-eval the value cell in the SAME (warm) module
        r.cells[2].state = STALE
        eval_stale!(r, k)
        o2 = r.cells[2].output
        @test !isempty(o2.display) && String(copy(o2.display[1].data)) == "HELLO"
    end

    @testset "value repr of a trailing assignment" begin
        r = parse_report("#%% code id=a\nx = 5")
        eval_report!(r)
        @test r.cells[1].output.value_repr == "5"
    end

    @testset "stdout is captured" begin
        r = parse_report("#%% code id=a\nprintln(\"hello world\")")
        eval_report!(r)
        @test occursin("hello world", r.cells[1].output.stdout)
        @test r.cells[1].output.value_repr == ""      # println returns nothing
        @test r.cells[1].state == FRESH
    end

    @testset "errors are captured, not propagated" begin
        r = parse_report("#%% code id=a\nerror(\"boom\")\n\n#%% code id=b\n1 + 1")
        eval_report!(r)                               # must not throw
        @test r.cells[1].state == ERRORED
        @test r.cells[1].output.exception !== nothing
        @test occursin("boom", r.cells[1].output.exception)
        @test r.cells[1].output.backtrace !== nothing
        @test r.cells[2].state == FRESH               # later cells still run
        @test r.cells[2].output.value_repr == "2"
    end

    @testset "markdown cells are inert" begin
        r = parse_report("#%% md id=m\n# A heading")
        eval_report!(r)
        @test r.cells[1].state == FRESH
        @test r.cells[1].output === nothing
    end

    @testset "reset_module! rebuilds clean" begin
        r = parse_report("#%% code id=a\nx = 5")
        eval_report!(r)
        m1 = r.mod
        reset_module!(r)
        @test r.cells[1].state == STALE
        @test r.cells[1].output === nothing
        @test r.mod !== m1                            # fresh namespace
        eval_report!(r)
        @test r.cells[1].state == FRESH
    end

    @testset "reports are isolated from each other" begin
        r1 = parse_report("#%% code id=a\nsecret = 111")
        r2 = parse_report("#%% code id=a\nsecret")     # same id, different module
        eval_report!(r1)
        eval_report!(r2)
        @test r1.cells[1].state == FRESH
        @test r2.cells[1].state == ERRORED             # `secret` undefined here
        @test occursin("secret", r2.cells[1].output.exception)
    end

    @testset "MIME capture: rich return value (text/html)" begin
        r = parse_report("""
        #%% code id=h
        struct H end
        Base.show(io::IO, ::MIME"text/html", ::H) = print(io, "<b>rich</b>")
        H()
        """)
        eval_report!(r)
        disp = r.cells[1].output.display
        i = findfirst(c -> c.mime == "text/html", disp)
        @test i !== nothing
        @test String(disp[i].data) == "<b>rich</b>"
    end

    @testset "MIME capture: binary image bytes (image/png)" begin
        r = parse_report("""
        #%% code id=p
        struct P end
        Base.show(io::IO, ::MIME"image/png", ::P) = write(io, UInt8[0x89,0x50,0x4e,0x47])
        P()
        """)
        eval_report!(r)
        disp = r.cells[1].output.display
        i = findfirst(c -> c.mime == "image/png", disp)
        @test i !== nothing
        @test disp[i].data == UInt8[0x89, 0x50, 0x4e, 0x47]   # PNG magic
    end

    @testset "MIME capture: explicit display()" begin
        r = parse_report("""
        #%% code id=d
        struct H end
        Base.show(io::IO, ::MIME"text/html", ::H) = print(io, "<i>shown</i>")
        display(H())
        nothing
        """)
        eval_report!(r)
        disp = r.cells[1].output.display
        @test any(c -> c.mime == "text/html", disp)
        @test r.cells[1].state == FRESH
    end

    @testset "Kernel seam" begin
        # Explicit InProcessKernel matches the default.
        r = parse_report("#%% code id=a\n6 * 7")
        eval_report!(r; kernel = InProcessKernel())
        @test r.cells[1].state == FRESH
        @test r.cells[1].output.value_repr == "42"

        # A custom kernel routes every cell through the four-method interface,
        # proving the engine touches execution only through `Kernel`.
        seen = String[]
        struct RecordingKernel <: ReportEngine.Kernel end
        ReportEngine.prepare!(::RecordingKernel, rep) = ReportEngine.report_module(rep)
        ReportEngine.reset!(::RecordingKernel, rep) = ReportEngine.reset_module!(rep)
        ReportEngine.assign!(::RecordingKernel, rep, n::Symbol, v) =
            Core.eval(ReportEngine.report_module(rep), Expr(:(=), n, v))
        function ReportEngine.eval_capture(::RecordingKernel, rep, src::AbstractString)
            push!(seen, src)
            return ReportEngine.eval_capture(InProcessKernel(), rep, src)
        end

        r2 = parse_report("#%% code id=a\nx = 4\n\n#%% md id=m\n# hi\n\n#%% code id=b\nx + 1")
        eval_report!(r2; kernel = RecordingKernel())
        @test seen == ["x = 4", "x + 1"]                 # only code cells, in order
        @test r2.cells[3].output.value_repr == "5"        # capture still works
    end

    @testset "run_capture wire form" begin
        # The wire form is the contract the gate worker returns and the server
        # deserializes — primitives only, no MimeChunk/CellOutput struct identity.
        m = Module(:WireTest)
        r = run_capture(m, "print(\"hi\"); 6 * 7")
        @test r isa NamedTuple
        @test r.stdout == "hi"
        @test r.value_repr == "42"
        @test r.mime isa Vector{Tuple{String,Vector{UInt8}}} && isempty(r.mime)
        @test r.echarts isa Vector && isempty(r.echarts)
        @test r.exception === nothing && r.backtrace === nothing
        @test r.duration_ms isa Float64

        # Rich MIME rides back as (mime, bytes) tuples.
        rr = run_capture(Module(:WireTest2), """
        struct W end
        Base.show(io::IO, ::MIME"image/png", ::W) = write(io, UInt8[0x89, 0x50])
        W()
        """)
        @test any(t -> t[1] == "image/png" && t[2] == UInt8[0x89, 0x50], rr.mime)

        # Errors are captured, not thrown.
        re = run_capture(Module(:WireTest3), "error(\"boom\")")
        @test re.exception !== nothing && occursin("boom", re.exception)
    end

end
