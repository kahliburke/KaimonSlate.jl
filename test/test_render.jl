# Renderer tests. Needs OteraEngine + CommonMark, so run against the dev env:
#   julia --startup-file=no --project=/tmp/report-devenv test/report/test_render.jl
using Test

const HERE = @__DIR__
include(joinpath(HERE, "..", "src", "engine.jl")); using .ReportEngine
include(joinpath(HERE, "..", "src", "render.jl")); using .ReportRender

@testset "ReportRender" begin
    src = """
    #%% md id=intro
    # Title
    **bold** text

    | a | b |
    |---|---|
    | 1 | 2 |

    #%% code id=c
    s = "<b>not evil</b>"

    #%% code id=err
    error("boom")
    """
    r = parse_report(src; title = "T")
    eval_report!(r)
    html = render_html(r)

    @testset "page shell + title" begin
        @test occursin("<!DOCTYPE html>", html)
        @test occursin("<title>T</title>", html)
    end

    @testset "markdown via CommonMark" begin
        @test occursin("<strong>bold</strong>", html)
        @test occursin("<table>", html)              # table extension enabled
    end

    @testset "error cell is styled and captured" begin
        @test occursin("class=\"cell errored\"", html)
        @test occursin("boom", html)
    end

    @testset "autoescape: untrusted cell text is escaped, not raw" begin
        @test occursin("&lt;b&gt;not evil&lt;/b&gt;", html)   # escaped form present
        @test !occursin("<b>not evil</b>", html)              # raw form absent
    end

    @testset "rich output embedding (image + html)" begin
        r2 = parse_report("""
        #%% code id=img
        struct P end
        Base.show(io::IO, ::MIME"image/png", ::P) = write(io, UInt8[0x89,0x50,0x4e,0x47])
        P()
        #%% code id=tbl
        struct T end
        Base.show(io::IO, ::MIME"text/html", ::T) = print(io, "<table><tr><td>x</td></tr></table>")
        T()
        """)
        eval_report!(r2)
        h = render_html(r2)
        @test occursin("data:image/png;base64,", h)            # image embedded
        @test occursin("<table><tr><td>x</td></tr></table>", h) # trusted html injected
    end
end
