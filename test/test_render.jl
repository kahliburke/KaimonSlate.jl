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
        # Render AGAIN: chunk bytes must survive (String(copy) not String steal).
        h_again = render_html(r2)
        @test occursin("data:image/png;base64,", h_again)
        @test occursin("<table><tr><td>x</td></tr></table>", h_again)
    end

    @testset "LaTeX math: preserved through markdown for KaTeX" begin
        # Inline + display math survives CommonMark byte-for-byte (backslash-escapes
        # like \, are NOT eaten), and emphasis chars inside math stay literal.
        m = markdown_html(raw"Euler $e^{i\pi}+1=0$ and $$\int_0^1 x^2\,dx$$ and **bold**.")
        @test occursin(raw"$e^{i\pi}+1=0$", m)        # inline kept verbatim
        @test occursin(raw"$$\int_0^1 x^2\,dx$$", m)  # \, preserved (CommonMark would drop it)
        @test occursin("<strong>bold</strong>", m)    # ordinary markdown still works
        @test !occursin("xslatemathx", m)             # no leftover placeholders
        @test occursin("<em>", markdown_html(raw"$a_i+b$ then _real emphasis_")) &&
              occursin(raw"$a_i+b$", markdown_html(raw"$a_i+b$ then _real emphasis_"))
    end

    @testset "text/latex output chunk → KaTeX div" begin
        r3 = parse_report(raw"""
        #%% code id=tex
        struct L end
        Base.show(io::IO, ::MIME"text/latex", ::L) = print(io, "\$\\sqrt{x}\$")
        L()
        """)
        eval_report!(r3)
        h = render_html(r3)
        @test occursin("class=\"disp latex\"", h)
        @test occursin(raw"\sqrt{x}", h)
        # Re-render must not blank the latex (the String-steal regression that
        # made every cell go empty on the 2nd /state poll).
        h_again = render_html(r3)
        @test occursin(raw"\sqrt{x}", h_again)
        @test occursin(raw"\sqrt{x}", output_html(r3.cells[1]))   # output_html path too
    end
end
