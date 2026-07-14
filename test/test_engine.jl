# Standalone tests for the report engine model + parser (no project deps).
# Run:  julia --startup-file=no test/report/test_engine.jl
using ReTest
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

    @testset "auto ids re-salt on a (forced) hash collision" begin
        # _auto_id's 24-bit space makes a real collision astronomically unlikely in a small test —
        # force one by pre-seeding `used` with the id _auto_id would otherwise return, and confirm
        # _unique_auto_id re-salts to something else instead of returning a duplicate.
        kind, src, idx = ReportEngine.CODE, "x = 1", 1
        collided = ReportEngine._auto_id(kind, src, idx)
        id2 = ReportEngine._unique_auto_id(kind, src, idx, Set([collided]))
        @test id2 != collided
        # parse_report itself never hands out a duplicate id, even across many same-content cells
        # (kind+source alone collide every time; idx breaks the tie unless idx ALSO collides, which
        # the salt loop now also guards against).
        src_body = "#%% code\nz = 1\n" ^ 20
        ids = [c.id for c in parse_report(src_body).cells]
        @test length(ids) == length(unique(ids))
    end

    @testset "ECharts DSL — clear ArgumentError on bad input" begin
        S = ReportEngine.series
        @test_throws ArgumentError S(:line, [1, 2, 3], [1, 2])       # mismatched x/y
        @test_throws ArgumentError S(:scatter, [1], [1, 2])
        @test_throws ArgumentError S(:pie, ["a", "b"], [1])
        @test_throws ArgumentError S(:boxplot, ["a"], [Float64[]])   # empty samples → no five-number summary
        @test_throws ArgumentError S(:heatmap, [1, 2, 3])            # not a matrix
        @test_throws ArgumentError S(:heatmap, zeros(0, 0))          # empty matrix
        @test S(:line, [1, 2, 3], [4, 5, 6]) !== nothing             # valid still builds
        # Wrong arity for a known ergonomic kind must raise too, not silently fall through to the
        # generic 1-arg/2-vector branches (which would misinterpret the args as raw `data`).
        @test_throws ArgumentError S(:line, [1, 2, 3])                # missing y
        @test_throws ArgumentError S(:pie, ["a", "b", "c"])           # missing values
        @test_throws ArgumentError S(:candlestick, ["10/1"])          # missing ohlc
        @test_throws ArgumentError S(:radar, ["Sales" => 1])          # missing values
        @test_throws ArgumentError S(:boxplot, ["a", "b"])            # missing data
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

@testset "runnable-notebook format (preamble + @md skin)" begin
    src = "#%% md id=intro\n# Head\nProse **bold** with {{ 1 + 1 }}.\n\n#%% code id=calc\nx = 6 * 7"
    r = parse_report(src)
    s = serialize_report(r)

    @testset "serialize emits the runnable skin" begin
        @test startswith(s, ReportEngine._PREAMBLE)          # standalone preamble is the first line
        @test occursin("@md\"\"\"", s)                         # markdown wrapped for a standalone run
        @test !occursin("@md\"\"\"\nx = 6 * 7", s)             # code cells are NOT wrapped
        # the stored (engine-facing) source is the BARE markdown, not the wrapper
        @test r.cells[1].source == "# Head\nProse **bold** with {{ 1 + 1 }}."
    end

    @testset "parse drops the preamble and unwraps @md" begin
        r2 = parse_report(s)
        @test length(r2.cells) == 2                            # no phantom preamble cell
        @test [c.id for c in r2.cells] == ["intro", "calc"]
        @test r2.cells[1].source == r.cells[1].source          # @md unwrapped back to bare markdown
        @test serialize_report(r2) == s                        # fixed point across the new format
    end

    @testset "old bare-prose markdown still reads; gains the skin on save" begin
        old = "#%% md id=m\n# Legacy\nno wrapper here\n\n#%% code id=c\ny = 1"   # no preamble, no @md
        ro = parse_report(old)
        @test ro.cells[1].kind == MARKDOWN
        @test ro.cells[1].source == "# Legacy\nno wrapper here"
        so = serialize_report(ro)
        @test startswith(so, ReportEngine._PREAMBLE)           # migration: preamble added
        @test occursin("@md\"\"\"\n# Legacy", so)              # migration: markdown wrapped
    end

    @testset "markdown containing triple-quotes falls back to bare form" begin
        rq = ReportEngine.Report("r", "")
        push!(rq.cells, ReportEngine.Cell("m", MARKDOWN, "a \"\"\" b"))
        sq = ReportEngine._cell_source(rq.cells[1])
        @test !occursin("@md", sq)                             # can't wrap safely → bare
        @test parse_report(serialize_report(rq)).cells[1].source == "a \"\"\" b"   # still round-trips
    end
end

@testset "standalone! injects the runnable contract" begin
    m = Module(:StandaloneContract)
    standalone!(m; dir = "/tmp")
    Core.eval(m, Meta.parse("v = 6 * 7"))
    Core.eval(m, Meta.parse("@bind n Slider(1:100; default=42)"))     # real bind path → widget default
    Core.eval(m, Meta.parse("@bind flag Checkbox()"))
    ec = Core.eval(m, Meta.parse("echart(:line, [1,2,3], [4,5,6])"))  # pure constructor builds an object
    md = Core.eval(m, Meta.parse("@md\"\"\"# H\n\nValue {{ v }}\"\"\""))
    noop = Core.eval(m, Meta.parse("(slate_emit(\"c\", 1), slate_progress(0.5), slate_refresh())"))

    @test Core.eval(m, :v) == 42                             # code runs
    @test Core.eval(m, :n) == 42                              # @bind yields the default, no browser
    @test Core.eval(m, :flag) == false
    @test nameof(typeof(ec)) == :EChart
    @test nameof(typeof(md)) == :MD && occursin("42", sprint(show, MIME("text/plain"), md))
    @test noop == (nothing, nothing, nothing)                # live-only features are no-ops
    @test Core.eval(m, :__slate_standalone) == true

    # idempotent: a second call (or the engine re-populating the same module) is a no-op
    @test (standalone!(m; dir = "/tmp"); Core.eval(m, :n)) == 42
end

@testset "Slate.config footer — per-notebook settings round-trip" begin
    r = parse_report("#%% code id=a\nx = 1")
    r.meta["parallel"] = true
    r.meta["threads"] = "8,1"
    r.meta["series"] = "Optics primer"
    s = serialize_report(r)
    @test occursin("Slate.config", s)
    r2 = parse_report(s)
    @test r2.meta["parallel"] === true          # bool round-trips
    @test r2.meta["threads"] == "8,1"           # string round-trips
    @test r2.meta["series"] == "Optics primer"  # series (spaces) round-trips
    @test length(r2.cells) == 1                 # cells parse fine (footer stripped, not a cell)
    @test findfirst(c -> c.id == "a", r2.cells) !== nothing

    # parallel=false also round-trips (not dropped)
    rf = parse_report("#%% code id=a\nx = 1"); rf.meta["parallel"] = false
    @test parse_report(serialize_report(rf)).meta["parallel"] === false

    # no settings → no config footer
    @test !occursin("Slate.config", serialize_report(parse_report("#%% code id=a\nx = 1")))

    # config + env footers coexist (env still parses, not polluted by config)
    re = parse_report("#%% code id=a\nx = 1")
    re.meta["env"] = [Dict{String,Any}("name" => "Foo", "version" => "1.2.3", "uuid" => "abc")]
    re.meta["threads"] = "4,1"
    rr = parse_report(serialize_report(re))
    @test rr.meta["threads"] == "4,1"
    @test rr.meta["env"][1]["name"] == "Foo"
end

@testset "slate_fingerprint: canonical isequal semantics" begin
    fp = ReportEngine.slate_fingerprint
    # deterministic + 64 hex chars
    @test fp([1, 2, 3]) == fp([1, 2, 3])
    @test occursin(r"^[0-9a-f]{64}$", fp(42))
    # Dict/Set order independence; Vector order dependence
    @test fp(Dict(:a => 1, :b => 2)) == fp(Dict(:b => 2, :a => 1))
    @test fp(Set([3, 1, 2])) == fp(Set([2, 3, 1]))
    @test fp([1, 2]) != fp([2, 1])
    # NaN ≡ NaN (any payload); -0.0 ≢ 0.0; Inf signs distinct
    @test fp(NaN) == fp(reinterpret(Float64, 0x7ff8000000000123))
    @test fp(-0.0) != fp(0.0)
    @test fp(Inf) != fp(-Inf)
    # numeric widening; but Int ≢ Float of same value
    @test fp(Int32(3)) == fp(3)
    @test fp(3) != fp(3.0)
    # missing / nothing distinct; string ≢ symbol; char ≢ 1-char string
    @test fp(missing) != fp(nothing)
    @test fp("a") != fp(:a)
    @test fp('a') != fp("a")
    # nested structures compose; multiple args ≡ tuple
    @test fp((a = 1, b = [Dict("x" => nothing)])) == fp((a = 1, b = [Dict("x" => nothing)]))
    @test fp(1, "two") == fp((1, "two"))
    # BigInt beyond Int64 range round-trips deterministically
    @test fp(big(2)^200) == fp(big(2)^100 * big(2)^100)
    # in-process kernels: memo-store queries degrade to empties (no Main.SlateWorker here)
    @test ReportEngine.slate_memo_stats().manifests == 0
    @test isempty(ReportEngine.slate_memo_entries())
end
