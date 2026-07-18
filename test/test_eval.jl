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

    @testset "Slate execution context (task-local :slate_ctx)" begin
        # Pure builder: a region cell vs the main kernel. `emit` is the module's own slate_emit.
        m = Module(:_CtxFixture); Core.eval(m, :(const slate_emit = (c, v) -> (c, v)))
        ctx = ReportEngine._build_slate_ctx(m, "nb-7", "rega", ["rega", "regb"])
        @test ctx.region == :rega
        @test ctx.side == "rega"
        @test ctx.notebook == "nb-7"
        @test ctx.regions == [:rega, :regb]
        @test ctx.emit isa Function
        main = ReportEngine._build_slate_ctx(m, "nb-7", "", String[])
        @test main.region === nothing          # nothing on main so a region-only API errors helpfully
        @test main.side == "" && isempty(main.regions)

        # Integration: a region cell SEES the context mid-eval, and it's CLEARED once eval returns
        # (never leaks across cells sharing a task — the parallel batch reuses tasks).
        r = parse_report("#%% code id=x\nCTX = get(task_local_storage(), :slate_ctx, nothing)")
        ReportEngine.eval_capture(InProcessKernel(), r, r.cells[1].source, "cell:x";
                                  region = "rega", regions = ["rega", "regb"])
        got = Base.invokelatest(getfield, ReportEngine.report_module(r), :CTX)
        @test got !== nothing
        @test got.region == :rega
        @test got.notebook == r.id
        @test got.regions == [:rega, :regb]
        @test got.emit isa Function
        @test get(task_local_storage(), :slate_ctx, nothing) === nothing   # no leak after eval

        # A main-kernel cell (no region kwarg) still gets a context, with region = nothing.
        r2 = parse_report("#%% code id=y\nCTX2 = get(task_local_storage(), :slate_ctx, nothing)")
        ReportEngine.eval_capture(InProcessKernel(), r2, r2.cells[1].source, "cell:y")
        got2 = Base.invokelatest(getfield, ReportEngine.report_module(r2), :CTX2)
        @test got2 !== nothing && got2.region === nothing && got2.side == ""
    end

    @testset "cell-effects channel (declare → harvest → CellOutput.effects)" begin
        run1(src) = (r = parse_report("#%% code id=x\n" * src);
                     eval_report!(r); r.cells[1].output)

        # A bare declaration is harvested with its statement source as the replay unit.
        o = run1("slate_effect(:per_side; names=[:foo])")
        @test length(o.effects) == 1
        @test o.effects[1].kind == :per_side
        @test o.effects[1].names == [:foo]
        @test occursin("slate_effect", o.effects[1].stmt_src)

        # Per-statement attribution: the effect is tied to the statement that declared it, NOT the whole cell.
        o2 = run1("a = 1\nb = 2\nslate_perside(:bar)\nc = 3")
        @test length(o2.effects) == 1
        @test o2.effects[1].kind == :per_side && o2.effects[1].names == [:bar]
        @test occursin("slate_perside", o2.effects[1].stmt_src)
        @test !occursin("a = 1", o2.effects[1].stmt_src) && !occursin("c = 3", o2.effects[1].stmt_src)

        # `@perside <stmt>` runs the statement AND declares it per-side, attributed to that one statement.
        o3 = run1("@perside (q = 41)")
        @test any(e -> e.kind == :per_side, o3.effects)
        @test o3.value_repr == "41"        # the wrapped statement's value flows through

        # A cell that declares nothing harvests nothing; no task-local leak after eval.
        o4 = run1("1 + 1")
        @test isempty(o4.effects)
        @test get(task_local_storage(), :slate_effects, nothing) === nothing
        @test get(task_local_storage(), :slate_stmt, nothing) === nothing

        # Dedup: the same declaration on the same statement collapses to one record.
        o5 = run1("for _ in 1:3; slate_effect(:per_side; names=[:dup]); end")
        @test count(e -> e.kind == :per_side && e.names == [:dup], o5.effects) == 1

        # A recorded `:per_side` flag classifies the cell PER_SIDE (→ `_prime_namespace!` primes it on
        # every region worker) — the generic replacement for the import_scaffold/theme special-cases.
        rc = parse_report("#%% code id=z\n1 + 1"); zc = rc.cells[1]
        @test ReportEngine._cell_effect(zc) == ReportEngine.PURE
        push!(zc.flags, :per_side)
        @test ReportEngine._cell_effect(zc) == ReportEngine.PER_SIDE
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
        function ReportEngine.eval_capture(::RecordingKernel, rep, src::AbstractString, filename::AbstractString = "string";
                                           region::AbstractString = "", regions::AbstractVector = String[])
            push!(seen, src)
            return ReportEngine.eval_capture(InProcessKernel(), rep, src, filename; region = region, regions = regions)
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
        # impurity PROPAGATES: a cell downstream of a nocache/volatile producer is unkeyable — the key
        # digests upstream SOURCES, but an impure upstream's VALUE isn't a function of its source, so a
        # restore would silently resurrect results computed from a PREVIOUS run's values.
        imp = parse_report("#%% code id=src nocache\ndata = rand(3)\n\n#%% code id=fit\nm = sum(data)\n\n#%% code id=leaf\nm2 = m + 1")
        build_dependencies!(imp)
        @test ReportEngine._memo_key(imp, imp.cells[2]) == ""        # direct dependent of impure
        @test ReportEngine._memo_key(imp, imp.cells[3]) == ""        # transitive dependent of impure
        pure = parse_report("#%% code id=src\ndata = [1,2,3]\n\n#%% code id=fit\nm = sum(data)")
        build_dependencies!(pure)
        @test !isempty(ReportEngine._memo_key(pure, pure.cells[2]))  # pure upstream stays keyable
        # the `cache` tag opts IN regardless of runtime: the cell stays keyable, the flag round-trips,
        # and downstream cells are unaffected (a cache-tagged stage is still pure by declaration)
        ca = parse_report("#%% code id=stage cache\ncleaned = [1,2,3]\n\n#%% code id=use\nsum(cleaned)")
        build_dependencies!(ca)
        @test :cache in ca.cells[1].flags
        @test !isempty(ReportEngine._memo_key(ca, ca.cells[1]))
        @test !isempty(ReportEngine._memo_key(ca, ca.cells[2]))
        @test :cache in parse_report(serialize_report(ca)).cells[1].flags
        # a PURE `using` upstream does NOT poison the key, even while :opaque (pre-refinement):
        # its effect is (source, resolved env) — both already digested — unlike include()/eval.
        # This is what lets the boot-window memo carry compute keys BEFORE anything has run.
        us = parse_report("#%% code id=pkgs\nusing LinearAlgebra\n\n#%% code id=work cache\nv = [1.0, 2.0]; t = sum(v)")
        build_dependencies!(us)
        @test :opaque in us.cells[1].flags                            # unrefined — the carry-time state
        @test ReportEngine._memo_key(us, us.cells[1]) == ""           # the using cell itself: never memoized
        kw = ReportEngine._memo_key(us, us.cells[2])
        @test !isempty(kw)                                            # downstream stays keyable
        # …and the key is refinement-invariant: dropping :opaque (what the post-run macro
        # refinement does) must not change it, or carried entries would never match.
        delete!(us.cells[1].flags, :opaque)
        @test ReportEngine._memo_key(us, us.cells[2]) == kw
        # a MIXED opaque cell (using + arbitrary code) still poisons downstream
        mx = parse_report("#%% code id=inc\nusing LinearAlgebra; include(\"setup.jl\")\n\n#%% code id=work2\nw = 1 + 1")
        build_dependencies!(mx)
        if :opaque in mx.cells[1].flags
            @test ReportEngine._memo_key(mx, mx.cells[2]) == ""
        end
        @test !ReportEngine._is_pure_using("using A; f()")
        @test !ReportEngine._is_pure_using("f()")
        @test !ReportEngine._is_pure_using("")
        @test ReportEngine._is_pure_using("using A, B\nimport C.d\n# comment")
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

    @testset "WebPage renders self-contained HTML" begin
        w = ReportEngine.WebPage(css = "body{color:red}", html = "<h1>hi</h1>", js = "console.log(1)")
        h = sprint(show, MIME"text/html"(), w)
        @test h == "<style>body{color:red}</style><h1>hi</h1><script>console.log(1)</script>"
        # `</script>` / `</style>` in content are escaped so they can't close the tag early
        w2 = ReportEngine.WebPage(js = "a='</script>'", css = "x</style>")
        h2 = sprint(show, MIME"text/html"(), w2)
        @test occursin("<\\/script>", h2) && !occursin("'</script>'", h2)
        @test occursin("<\\/style>", h2)
        # obscure=true base64-wraps the JS behind a decode-and-run bootstrap (no raw source)
        w3 = ReportEngine.WebPage(js = "SECRET_TOKEN()", obscure = true)
        h3 = sprint(show, MIME"text/html"(), w3)
        @test !occursin("SECRET_TOKEN", h3) && occursin("atob(", h3)   # source is behind the curtain
    end

    @testset "@use import-map declarations" begin
        # `@use "name" => "url"` (or `@use "name" "url"`) is statically extracted into report.meta.
        r = parse_report("#%% code id=a\n@use \"d3\" => \"https://esm.sh/d3@7\"\n\n#%% code id=b\n@use \"three\" \"https://esm.sh/three\"\nx = 1")
        build_dependencies!(r)
        imps = r.meta["imports"]
        @test imps["d3"] == "https://esm.sh/d3@7"
        @test imps["three"] == "https://esm.sh/three"
        # a notebook with no @use → empty map (no importmap injected)
        r2 = parse_report("#%% code id=c\nx = 1")
        build_dependencies!(r2)
        @test isempty(r2.meta["imports"])
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
