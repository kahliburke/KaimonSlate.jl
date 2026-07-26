# Session-bound ("live") outputs: outputs whose HTML is a view onto state that lives in the WORKER
# (a WGLMakie scene and its socket), not a self-contained artifact. Core must know WHICH outputs those
# are WITHOUT inspecting the rendered HTML for a renderer's marker class — that couples core to one
# extension's markup and misses every other live renderer. The fact rides on `CellOutput.live`, set at
# capture from the value's `SlateExtensionsBase.slate_live_render` opt-in.
#
# The rendering rule these tests pin down: a full-state payload serves a live output as a non-booting
# PLACEHOLDER (its stored HTML belongs to a browser session that no longer exists), while the `celldone`
# push serves the real thing — and each says which it is, so a page that has already booted the live
# output doesn't get it blanked by the next run's full-state reply.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

_mknb(src) = NS.LiveNotebook("live", "/tmp/livetest.jl", RE.parse_report(src; title = "T"),
    RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
    ReentrantLock(), "", false, Dict{String,String}())

const SRC = """
#%% code id=fig
plot_it()

#%% code id=plain
1 + 1
"""

# An output carrying `html` as its rich display chunk, marked live or not.
_out(html; live::Bool) = RE.CellOutput("", RE.MimeChunk[RE.MimeChunk("text/html", Vector{UInt8}(html))],
    Any[], Any[], RE.BindSpec[], "", nothing, nothing, 1.0, Any[], "", Any[], Any[], "", "", Any[], Any[], live)

const FIG_HTML = "<div class=\"some-renderer-card\"><canvas></canvas></div>"

@testset "live (session-bound) outputs" begin

    @testset "CellOutput.live defaults false through the back-compat ladder" begin
        # Every shorter constructor rung delegates to the assets-arity one, so a caller that predates the
        # field still builds a valid output — and an output is never live unless the capture said so.
        rungs = (RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0),
                 RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0,
                               Any[], "", Any[], Any[], "", "", Any[], Any[]))
        @test all(o -> o.live === false, rungs)
    end

    @testset "the wire's `live` flag reaches CellOutput" begin
        wire = (stdout = "", mime = [("text/html", Vector{UInt8}(FIG_HTML))], echarts = Any[], tables = Any[],
                binds = NamedTuple[], value_repr = "", exception = nothing, backtrace = nothing,
                duration_ms = 0.0, trace = Any[], stderr = "", overflow = NamedTuple[],
                animations = Any[], effects = Any[], assets = Any[], live = true)
        @test RE._wire_to_output(wire).live === true
        # A wire from before the field existed (or a plain output) is simply not live.
        @test RE._wire_to_output(Base.structdiff(wire, NamedTuple{(:live,)})).live === false
    end

    @testset "cell_json marks which of the two renderings it carries" begin
        r = RE.parse_report(SRC)
        fig, plain = r.cells[1], r.cells[2]
        fig.output   = _out(FIG_HTML; live = true)
        plain.output = _out(FIG_HTML; live = false)

        # `celldone` path: the real, live-for-this-session output, labelled so the browser records it.
        done = NS.cell_json(fig)
        @test done["live"] == "render"
        @test occursin("some-renderer-card", done["output"])

        # Full-state path: a non-booting stand-in, labelled so the browser can decline to mount it over
        # a live output it has already booted.
        held = NS.cell_json(fig; live_placeholder = true)
        @test held["live"] == "placeholder"
        @test !occursin("some-renderer-card", held["output"])
        @test occursin("slate-live-placeholder", held["output"])

        # Liveness is the CellOutput flag, never the markup: byte-identical HTML that didn't opt in is
        # left completely alone on both paths.
        for j in (NS.cell_json(plain), NS.cell_json(plain; live_placeholder = true))
            @test j["live"] == ""
            @test occursin("some-renderer-card", j["output"])
        end
    end

    @testset "state_json placeholders only the live cells" begin
        nb = _mknb(SRC)
        nb.report.cells[1].output = _out(FIG_HTML; live = true)
        nb.report.cells[2].output = _out(FIG_HTML; live = false)
        cells = Dict(c["id"] => c for c in NS.state_json(nb)["cells"])
        @test cells["fig"]["live"] == "placeholder" && !occursin("canvas", cells["fig"]["output"])
        @test cells["plain"]["live"] == "" && occursin("canvas", cells["plain"]["output"])
    end
end
