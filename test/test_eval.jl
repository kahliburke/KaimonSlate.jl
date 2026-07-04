# Standalone tests for isolated-module evaluation (Base only, no session).
# Run:  julia --startup-file=no test/report/test_eval.jl
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine

# Real-source fixture module (docstrings register normally, unlike a hand-built Expr).
module _DocFixture
export fixture_fn
"Return `x` unchanged — a documented fixture function."
fixture_fn(x) = x
end

@testset "ReportEngine eval" begin

    @testset "cross-cell state sharing (warm namespace)" begin
        r = parse_report("#%% code id=a\ndata = [1, 2, 3]\n\n#%% code id=b\nsum(data)")
        eval_report!(r)
        @test r.cells[1].state == FRESH
        @test r.cells[2].state == FRESH
        @test r.cells[2].output.value_repr == "6"
    end

    @testset "quiet cells: trailing ; suppresses the value (stdout still shows)" begin
        r = parse_report("#%% code id=loud\n5 + 5\n\n#%% code id=quiet\nprint(\"side\"); 5 + 5;")
        eval_report!(r)
        @test r.cells[1].output.value_repr == "10"            # loud → value shown
        @test r.cells[2].output.value_repr == ""              # quiet → value suppressed
        @test r.cells[2].output.stdout == "side"              # but stdout still shows
        @test ReportEngine._is_quiet_cell("x = 1; # note")    # inline comment after ;
        @test !ReportEngine._is_quiet_cell("y = \"a#b\"")      # # inside a string, no ;
        @test ReportEngine._is_quiet_cell("foo(\"#\");")       # # inside a string, trailing ;
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

    @testset "backtraces name their source cell (cross-cell error jump)" begin
        # `f` defined in cell `a`, called from cell `b`: b's backtrace must name BOTH cells, so a
        # frame can jump to the cell that owns it. The eval filename is `cell:<id>`.
        r = parse_report("#%% code id=a\nf() = error(\"kaboom\")\n\n#%% code id=b\nf()")
        eval_report!(r)
        bt = r.cells[2].output.backtrace
        @test bt !== nothing
        @test occursin("cell:a:", bt)                 # the frame where f errors (defining cell)
        @test occursin("cell:b:", bt)                 # the call site (this cell)
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

    @testset "docstring harvest" begin
        recs = ReportEngine.harvest_module_docs(@__MODULE__, ["_DocFixture"])
        @test !isempty(recs)
        ff = findfirst(r -> r["name"] == "fixture_fn", recs)
        @test ff !== nothing
        @test occursin("documented fixture", recs[ff]["doc"]) && recs[ff]["module"] == "_DocFixture"
        @test all(r -> haskey(r, "module") && haskey(r, "name") && haskey(r, "doc"), recs)
        @test isempty(ReportEngine.harvest_module_docs(@__MODULE__, ["NoSuchModule"]))
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
        ReportEngine.assign_bind!(::RecordingKernel, rep, n::Symbol, v) =
            Base.invokelatest(getfield(ReportEngine.report_module(rep), :__slate_set_bind), n, v)
        function ReportEngine.eval_capture(::RecordingKernel, rep, src::AbstractString, filename::AbstractString = "string")
            push!(seen, src)
            return ReportEngine.eval_capture(InProcessKernel(), rep, src, filename)
        end

        r2 = parse_report("#%% code id=a\nx = 4\n\n#%% md id=m\n# hi\n\n#%% code id=b\nx + 1")
        eval_report!(r2; kernel = RecordingKernel())
        @test seen == ["x = 4", "x + 1"]                 # only code cells, in order
        @test r2.cells[3].output.value_repr == "5"        # capture still works
    end

    @testset "memoization key invalidates correctly" begin
        # The durable-cache key must be a TOTAL function of what affects the result, or a stale
        # restore serves wrong data after an edit. (src/Manifest digests are folded in worker-side.)
        r = parse_report("#%% code id=a\nx = 2\n\n#%% code id=b\nx + 1")
        build_dependencies!(r)
        a, b = r.cells
        k0 = ReportEngine._memo_key(r, b)
        @test !isempty(k0)
        @test ReportEngine._memo_key(r, b) == k0                 # stable across recomputation
        b.source = "x + 2"; b.src_hash = hash(b.source)
        @test ReportEngine._memo_key(r, b) != k0                 # own-source edit invalidates
        b.source = "x + 1"; b.src_hash = hash(b.source)
        @test ReportEngine._memo_key(r, b) == k0                 # reverting restores the key
        a.source = "x = 3"; a.src_hash = hash(a.source)
        @test ReportEngine._memo_key(r, b) != k0                 # UPSTREAM edit invalidates (transitive)
        # a control-DECLARING cell or an import barrier is never memoized
        op = parse_report("#%% code id=c\nusing LinearAlgebra")
        build_dependencies!(op)
        @test :opaque in op.cells[1].flags
        @test ReportEngine._memo_key(op, op.cells[1]) == ""
        # the `nocache` header tag opts a cell out, and round-trips through serialization
        nc = parse_report("#%% code id=d nocache\nrand()")
        build_dependencies!(nc)
        @test :nocache in nc.cells[1].flags
        @test ReportEngine._memo_key(nc, nc.cells[1]) == ""
        @test occursin("nocache", serialize_report(nc))
        @test :nocache in parse_report(serialize_report(nc)).cells[1].flags
    end

    @testset "@asset file deps: static extraction + memo invalidation" begin
        # `@asset "path"` is a source literal, so the analyzer records it as a file input (cell.inputs)
        # WITHOUT running the cell; the memo key folds the file's content hash, so editing the asset
        # invalidates the entry.
        dir = mktempdir()
        f = joinpath(dir, "a.js"); write(f, "console.log(1)")
        r = parse_report("#%% code id=a\nhtml = @asset \"a.js\"")
        build_dependencies!(r)
        c = r.cells[1]
        @test c.inputs == ["a.js"]                        # statically extracted literal path
        @test !(:opaque in c.flags)                       # an @asset cell stays memoizable
        r.meta["assetbase"] = dir
        k0 = ReportEngine._memo_key(r, c)
        @test !isempty(k0)
        @test ReportEngine._memo_key(r, c) == k0          # stable while the file is unchanged
        write(f, "console.log(2)")
        @test ReportEngine._memo_key(r, c) != k0          # editing the asset invalidates the key
        write(f, "console.log(1)")
        @test ReportEngine._memo_key(r, c) == k0          # reverting the content restores it
        # `@asset bytes "x"` and non-literal paths: bytes form still extracts; a plain code cell has none.
        rb = parse_report("#%% code id=b\nlogo = @asset bytes \"logo.png\"")
        build_dependencies!(rb)
        @test rb.cells[1].inputs == ["logo.png"]
        rp = parse_report("#%% code id=c\nx = 1 + 1")
        build_dependencies!(rp)
        @test isempty(rp.cells[1].inputs)                 # no @asset → no file inputs (key unchanged vs before)
    end

    @testset "@asset macro reads the file at runtime" begin
        dir = mktempdir()
        write(joinpath(dir, "x.js"), "HELLO")
        write(joinpath(dir, "logo.bin"), UInt8[1, 2, 3])
        r = parse_report("#%% code id=a\nx = 1")
        r.meta["assetbase"] = dir                         # base for relative @asset resolution
        m = ReportEngine.report_module(r)                 # populates the namespace (incl. @asset) w/ assetbase
        @test Base.invokelatest(Core.eval, m, :(@asset "x.js")) == "HELLO"
        @test Base.invokelatest(Core.eval, m, :(@asset bytes "logo.bin")) == UInt8[1, 2, 3]
        @test Base.invokelatest(Core.eval, m, :(readfile("x.js"))) == "HELLO"   # runtime form
        # absolute paths bypass the base
        abspath_js = joinpath(dir, "x.js")
        @test Base.invokelatest(Core.eval, m, :(@asset $abspath_js)) == "HELLO"
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
        @test r.tables isa Vector && isempty(r.tables)
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

    @testset "oversized output is capped (not shipped/rendered whole)" begin
        cap = ReportEngine._MAX_OUT_CHARS
        # A giant printed stream is truncated with a notice.
        rs = run_capture(Module(:CapStdout), "print('x' ^ $(cap * 3))")
        @test length(rs.stdout) < cap + 200 && occursin("truncated", rs.stdout)
        # …and its FULL result is saved to a temp file (for the open-in-tab/editor/download bar).
        ovf = first(e for e in rs.overflow if e.kind == "stdout")
        @test isfile(ovf.path) && ovf.bytes > cap && !ovf.clipped
        # A giant value repr stays bounded (Julia's :limit/:displaysize and/or our hard cap).
        rv = run_capture(Module(:CapVal), "'y' ^ $(cap * 3)")
        @test length(rv.value_repr) < cap + 200
        # The hard backstop itself: truncates with a notice past the limit, leaves small text alone.
        @test length(ReportEngine._cap_text("z"^(cap + 50))) < cap + 200
        @test occursin("truncated", ReportEngine._cap_text("z"^(cap + 50)))
        @test ReportEngine._cap_text("small") == "small"
        # A small value is untouched.
        ro = run_capture(Module(:CapSmall), "\"hello\"")
        @test ro.value_repr == "\"hello\""
        # An over-limit text/html chunk becomes a notice, not multi-MB of markup.
        big = ReportEngine._MAX_HTML_BYTES + 5000
        rh = run_capture(Module(:CapHtml), """
        struct H end
        Base.show(io::IO, ::MIME"text/html", ::H) = write(io, '<' * 'a' ^ $(big))
        H()
        """)
        html = String(copy(first(t for t in rh.mime if t[1] == "text/html")[2]))
        @test length(html) < 1000 && occursin("too large", html)
    end

    @testset "REPL soft-scope: top-level loop assigns a global without `local`" begin
        # Cells eval with REPL soft-scope semantics (not file `include_string`), so a top-level
        # `for`/`while` can update an existing global — the behaviour users expect from a notebook.
        r = run_capture(Module(:SoftScope), "total = 0\nfor i in 1:4\n    total += i\nend\ntotal")
        @test r.exception === nothing
        @test r.value_repr == "10"

        # world age across statements in one cell: `using`/`struct`+use stay visible.
        r2 = run_capture(Module(:SoftScope2), "struct Pt; x; end\nPt(7).x")
        @test r2.exception === nothing && r2.value_repr == "7"

        # a genuine parse error still surfaces as a captured exception (not a crash).
        r3 = run_capture(Module(:SoftScope3), "for i in")
        @test r3.exception !== nothing
    end

    @testset "stderr / @warn is captured (separate from stdout, cell still succeeds)" begin
        r = run_capture(Module(:Warns), "@warn \"heads up\"\n6 * 7")
        @test r.exception === nothing           # a warning is not an error
        @test r.value_repr == "42"
        @test occursin("heads up", r.stderr)
        @test isempty(r.stdout)                 # the warning went to stderr, not stdout
        # a clean cell has empty stderr
        @test isempty(run_capture(Module(:NoWarns), "1 + 1").stderr)
    end

    @testset "markdown {{ }} interpolation: reads, deps, reactive capture" begin
        r = parse_report("#%% code id=a\nx = 21 * 2\n\n#%% md id=m\nThe answer is {{x}}.")
        build_dependencies!(r)
        mi = findfirst(c -> c.id == "m", r.cells)
        @test :x in r.cells[mi].reads            # md cell reads the interpolated var
        @test "a" in r.cells[mi].deps            # …and depends on the cell that writes it
        eval_stale!(r)
        @test length(r.cells[mi].interp) == 1
        @test r.cells[mi].interp[1].value_repr == "42"
        # editing the producer restales + re-resolves the md cell
        update_source!(r, "#%% code id=a\nx = 100\n\n#%% md id=m\nThe answer is {{x}}.")
        eval_stale!(r)
        mi = findfirst(c -> c.id == "m", r.cells)
        @test r.cells[mi].interp[1].value_repr == "100"
        # a plain md cell (no interps) stays inert
        r2 = parse_report("#%% md id=m\njust text")
        eval_stale!(r2)
        @test isempty(r2.cells[1].interp)
    end

    @testset "markdown {{ }} brace-balanced + string-aware scan" begin
        ME = ReportEngine._md_interp_exprs
        @test ME("a {{ Dict(:x=>1) }} b") == ["Dict(:x=>1)"]                 # no braces
        @test ME("{{ NamedTuple{(:a,)}((1,)) }}") == ["NamedTuple{(:a,)}((1,))"]  # balanced { }
        @test ME("x {{ L\"\\frac{a}{b}\" }}") == ["L\"\\frac{a}{b}\""]       # braces inside a string
        @test ME("{{x}} then {{ y }}") == ["x", "y"]
        tmpl, ex = ReportEngine._md_template("v = {{ a }}.")
        @test ex == ["a"] && occursin("xslateinterp", tmpl) && !occursin("{{", tmpl)
    end

end
