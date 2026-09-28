# Doc bundles: a rendered notebook as files a Documenter build reads (server_docbundle.jl).
using ReTest
using KaimonSlate
import JSON
const RE = KaimonSlate.ReportEngine
const NS = KaimonSlate.NotebookServer

_out(; stdout = "", value = "", display = RE.MimeChunk[], echarts = Any[]) =
    RE.CellOutput(stdout, display, echarts, Any[], RE.BindSpec[], value, nothing, nothing, 1.0)

# A notebook on disk (the bundle key is the file's hash) with outputs filled in by hand, so the test
# needs no kernel.
function _fixture_nb(dir)
    src = """
    #%% md id=intro
    # Damped oscillator

    The period is {{ period }} seconds and the energy is \$E = \\frac{1}{2}kx^2\$.

    \$\$
    x(t) = e^{-\\gamma t}\\cos(\\omega t)
    \$\$

    #%% code id=setup
    period = 2.5

    #%% code id=show
    println("hello"); 42

    #%% code id=plot
    echart()

    #%% md id=fancy
    See [@knuth84] for more.
    """
    path = joinpath(dir, "oscillator.jl")
    write(path, src)
    rep = RE.parse_report(src; id = "osc")
    byid = Dict(c.id => c for c in rep.cells)
    byid["intro"].interp = [_out(value = "2.5")]
    byid["setup"].output = _out()
    byid["show"].output = _out(stdout = "hello\n", value = "42")
    byid["plot"].output = _out(echarts = Any[Dict{String,Any}("xAxis" => Dict("type" => "category"),
                                        "series" => Any[Dict{String,Any}("type" => "line", "data" => [1, 3, 2])])])
    return NS.LiveNotebook("osc", path, rep, RE.InProcessKernel(), 1, String[], String[], ReentrantLock(),
                           Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
end

@testset "doc bundle: Documenter math" begin
    m = NS._documenter_math("inline \$a+b\$ and \\(c\\), display:\n\$\$x^2\$\$\nand \\[y\\]")
    @test occursin("``a+b``", m) && occursin("``c``", m)
    @test occursin("```math\nx^2\n```", m) && occursin("```math\ny\n```", m)
    @test !occursin('$', m)
    # prose dollar amounts are escaped, since Julia's markdown reads a bare `$` as interpolation
    @test NS._documenter_math("it cost \$5 and \$10") == raw"it cost \$5 and \$10"
    @test NS._documenter_math("\$100k–\$750k, area \$a^2\$") == raw"\$100k–\$750k, area ``a^2``"
    @test NS._documenter_math("code `\$x` stays") == "code `\$x` stays"
end

@testset "doc bundle: manifest, payloads, runtime" begin
    mktempdir() do dir
        nb = _fixture_nb(dir)
        out = joinpath(dir, "docs", "slate", "oscillator")
        man = NS.export_doc_bundle(nb, out; render_info = Dict("by" => "test"))
        @test isfile(joinpath(out, "slate-bundle.json"))
        disk = JSON.parsefile(joinpath(out, "slate-bundle.json"))
        @test disk["schema"] == NS.DOC_BUNDLE_SCHEMA
        @test disk["key"] == NS.doc_bundle_key(nb.path) == man["key"]
        @test disk["rendered"]["kernel"] == "inprocess" && disk["rendered"]["by"] == "test"
        @test occursin("--bg:", disk["theme"]["light"]["vars"]) && occursin("--hl-kw:", disk["theme"]["dark"]["vars"])
        @test any(l -> get(l, "name", "") == "echarts", disk["libs"])   # a chart cell pulls ECharts in

        cells = Dict(c["id"] => c for c in disk["cells"])
        @test [c["id"] for c in disk["cells"]] == ["intro", "setup", "show", "plot", "fancy"]
        # Prose: values written in, maths in Documenter's spelling, and native.
        intro = cells["intro"]
        @test intro["native"] === true
        @test occursin("The period is 2.5 seconds", intro["markdown"])
        @test occursin("``E = \\frac{1}{2}kx^2``", intro["markdown"])
        @test occursin("```math", intro["markdown"])
        # A citation needs Slate's renderer, so that cell is embedded instead.
        @test cells["fancy"]["native"] === false && haskey(cells["fancy"], "file")
        # Code: source travels for the docs page to show; only cells with output get a payload.
        @test cells["setup"]["output"] === false && !haskey(cells["setup"], "file")
        @test cells["show"]["source"] == "println(\"hello\"); 42"
        @test cells["show"]["output"] === true

        show = JSON.parsefile(joinpath(out, cells["show"]["file"]))
        @test occursin("hello", show["html"]) && !occursin("exp-src", show["html"])   # no source in payloads
        plot = JSON.parsefile(joinpath(out, cells["plot"]["file"]))
        @test length(plot["charts"]) == 1
        cid, spec = plot["charts"][1]
        @test cid == "oscillator-chart-plot-1"                  # notebook-prefixed: two notebooks can share a page
        @test occursin("id=\"$cid\"", plot["html"])
        @test spec["series"][1]["data"] == [1, 3, 2]

        rt = read(joinpath(out, disk["runtime"]), String)
        @test occursin("customElements.define(\"slate-cell\"", rt)
        @test occursin("_slateMountCharts", rt) && occursin(".exp-table", rt)

        # Re-rendering replaces the bundle whole, and leaves no staging directory behind.
        write(joinpath(out, "stale.txt"), "x")
        NS.export_doc_bundle(nb, out)
        @test !isfile(joinpath(out, "stale.txt"))
        @test !any(startswith(".oscillator.tmp-"), readdir(dirname(out)))
    end
end

@testset "doc bundle: key follows the file, not its line endings" begin
    mktempdir() do dir
        a, b = joinpath(dir, "a.jl"), joinpath(dir, "b.jl")
        write(a, "#%% code id=x\n1\n"); write(b, "#%% code id=x\r\n1\r\n")
        @test NS.doc_bundle_key(a) == NS.doc_bundle_key(b)
        write(b, "#%% code id=x\n2\n")
        @test NS.doc_bundle_key(a) != NS.doc_bundle_key(b)
    end
end

@testset "doc bundle: default folder follows the nearest docs/make.jl" begin
    mktempdir() do root
        mk(p) = (mkpath(dirname(p)); write(p, ""); p)
        nbfor(path) = NS.LiveNotebook("x", path, RE.parse_report(""), RE.InProcessKernel(), 1, String[], String[],
                                      ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
        mk(joinpath(root, "docs", "make.jl"))
        # a notebook elsewhere in the package → the package's docs/slate
        a = nbfor(mk(joinpath(root, "examples", "tour.jl")))
        @test NS.doc_bundle_default_dir(a) == joinpath(root, "docs", "slate", "tour")
        @test NS.doc_bundle_name(a) == "tour"
        # a notebook inside docs/ → the docs dir it is in
        b = nbfor(mk(joinpath(root, "docs", "notebooks", "osc.jl")))
        @test NS.doc_bundle_default_dir(b) == joinpath(root, "docs", "slate", "osc")
    end
    # no docs/ and no project anywhere above → beside the notebook
    mktempdir() do root
        p = joinpath(root, "loose.jl"); write(p, "")
        nb = NS.LiveNotebook("x", p, RE.parse_report(""), RE.InProcessKernel(), 1, String[], String[],
                             ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
        Base.current_project(root) === nothing &&
            @test NS.doc_bundle_default_dir(nb) == joinpath(root, "docs", "slate", "loose")
    end
end
