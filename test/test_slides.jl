# Presentation / slideshow mode: slide segmentation, the `slide`/`notes` tags, the slide-deck
# config footer round-trip, cell_json flag exposure, and a Typst slide-deck compile smoke test.
# Loads the package (NotebookServer holds the segmentation + export), so it runs under Pkg.test.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

_mknb(src) = NS.LiveNotebook("deck", "/tmp/slidetest.jl", RE.parse_report(src),
    RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
    ReentrantLock(), "", false, Dict{String,String}())

@testset "slideshow mode" begin

    @testset "heading depth + rule splitting" begin
        @test NS._first_heading_depth("intro\n## Slide\nbody") == 2
        @test NS._first_heading_depth("# Title") == 1
        @test NS._first_heading_depth("no headings here") === nothing
        @test NS._first_heading_depth("```\n## fenced\n```\n### real") == 3   # fenced code skipped
        @test length(NS._split_md_rules("a\n---\nb\n---\nc")) == 3
        @test length(NS._split_md_rules("plain text, no rule")) == 1
        # A leading `---` is an ordinary thematic break now (no YAML front matter): break, then body.
        @test length(NS._split_md_rules("---\nbody")) == 2
    end

    @testset "segmentation: headings / slide tag / notes / collapsed" begin
        src = """
        #%% md id=title
        intro, no heading

        #%% md id=s1
        ## First
        body

        #%% code id=c1
        x = 1

        #%% md id=n1 notes
        speaker note

        #%% md id=s2
        ## Second

        #%% code id=expl slide
        y = 2
        """
        cells = RE.parse_report(src).cells
        segs = NS._slide_segments(cells; level = 2)
        ids(s) = [f[1].id for f in s.frags]
        @test length(segs) == 4
        @test ids(segs[1]) == ["title"]                 # pre-heading → title slide
        @test ids(segs[2]) == ["s1", "c1"]              # heading starts, code flows in
        @test [n.id for n in segs[2].notes] == ["n1"]   # notes attach to the current slide
        @test ids(segs[3]) == ["s2"]
        @test ids(segs[4]) == ["expl"]                  # explicit `slide` tag starts a slide
    end

    @testset "level controls the boundary" begin
        src = "#%% md id=a\n## two\n\n#%% md id=b\n### three\n"
        cells = RE.parse_report(src).cells
        @test length(NS._slide_segments(cells; level = 2)) == 1   # ### does not break at level 2
        @test length(NS._slide_segments(cells; level = 3)) == 2   # ### breaks at level 3
    end

    @testset "--- splits a markdown cell mid-cell" begin
        src = "#%% md id=s\n## Topic\n\npart one\n\n---\n\npart two\n"
        segs = NS._slide_segments(RE.parse_report(src).cells; level = 2)
        @test length(segs) == 2
        @test occursin("part one", segs[1].frags[1][2])
        @test occursin("part two", segs[2].frags[1][2])
    end

    @testset "a --- chunk resolves ITS OWN interpolations" begin
        # `_md_template` numbers a fragment's interpolations from 1, but `Cell.interp` is numbered
        # across the whole cell — so a chunk has to carry how many precede it or every chunk after the
        # first silently renders an earlier chunk's value. The fence matters: `_desugar_fences` turns
        # every tagged fence into an interpolation too, so counting `{{` would put the offset at 1 here
        # and still land on the wrong entry.
        src = "#%% md id=s\n## One\n\n```julia\nx = 1\n```\n\nalpha {{ a }}\n\n---\n\n## Two\n\nbeta {{ b }}\n"
        c = RE.parse_report(src).cells[end]
        out(v) = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], v, nothing, nothing, 1.0)
        c.interp = [out(""), out("111"), out("222")]        # slot 1 is the fence (no captured value)
        segs = NS._slide_segments([c]; level = 2)
        @test length(segs) == 2
        f1, f2 = segs[1].frags[1], segs[2].frags[1]
        @test (f1.interpbase, f2.interpbase) == (0, 2)
        m1 = NS._md_for_typst(c, f1.src; interpbase = f1.interpbase)
        m2 = NS._md_for_typst(c, f2.src; interpbase = f2.interpbase)
        @test occursin("111", m1) && !occursin("222", m1)
        @test occursin("222", m2) && !occursin("111", m2)
        @test occursin("x = 1", m1)                          # unclaimed fence still prints as code
        # The offset is what does the work. Drop it and chunk two reads slot 1 — here the fence, which
        # captured nothing — so `beta` renders with its value missing entirely rather than merely wrong.
        @test !occursin("222", NS._md_for_typst(c, f2.src; interpbase = 0))
    end

    @testset "dropping the hoisted H1 shifts the interpolation base" begin
        # The title cell's H1 is hoisted into the title block and removed from the body. Anything
        # interpolated in that line goes with it, so the body no longer starts at interpolation 1.
        src = "#%% md id=t\n# Report for {{ who }}\n\nbody says {{ what }}\n"
        c = RE.parse_report(src).cells[end]
        out(v) = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], v, nothing, nothing, 1.0)
        c.interp = [out("ACME"), out("hello")]
        body, base = NS._body_after_hoisted_h1(c)
        @test base == 1 && !occursin("Report for", body)
        md = NS._md_for_typst(c, body; interpbase = base)
        @test occursin("hello", md) && !occursin("ACME", md)
    end

    @testset "slide/notes are known tags and round-trip" begin
        @test :slide in RE._KNOWN_TAGS
        @test :notes in RE._KNOWN_TAGS
        r = RE.parse_report("#%% code id=a slide\nx=1\n\n#%% md id=b notes\nhi\n")
        @test :slide in r.cells[1].flags
        @test :notes in r.cells[2].flags
        r2 = RE.parse_report(RE.serialize_report(r))
        @test :slide in r2.cells[1].flags && :notes in r2.cells[2].flags
    end

    @testset "config footer round-trips slide prefs (typed)" begin
        r = RE.parse_report("#%% code id=a\nx=1\n")
        r.meta["slidelevel"] = 3
        r.meta["slidetransition"] = "slide"
        r.meta["slideratio"] = "4:3"
        r2 = RE.parse_report(RE.serialize_report(r))
        @test r2.meta["slidelevel"] === 3           # parsed back as an Int, not a String
        @test r2.meta["slidetransition"] == "slide"
        @test r2.meta["slideratio"] == "4:3"
    end

    @testset "cell_json exposes slide/notes flags" begin
        r = RE.parse_report("#%% code id=a slide\nx=1\n\n#%% md id=b notes\nhi\n")
        j1 = NS.cell_json(r.cells[1]); j2 = NS.cell_json(r.cells[2])
        @test get(j1, "slide", false) == true
        @test get(j2, "notes", false) == true
        @test "slide" in j1["tags"] && "notes" in j2["tags"]
    end

    @testset "slide-deck PDF compiles" begin
        nb = _mknb("#%% md id=t\n# Deck\nhi\n\n#%% md id=s\n## One\n\n- a\n- b\n")
        # Typst fetches registry packages on first compile; guard on network/availability so the
        # suite stays green offline — but assert real bytes whenever it does run.
        pdf = try
            NS.export_pdf(nb; layout = "slides", theme = "dark")
        catch err
            @info "slide PDF compile skipped" err
            nothing
        end
        @test pdf === nothing || length(pdf) > 1000
    end

    @testset "slide-deck with CITATIONS compiles (measure-in-isolation regression)" begin
        # A cite() inside the slide fit-scaler's measure() used to abort the whole deck with
        # "cannot format citation in isolation" — the measured copy must render citation
        # sentinels as a stand-in, while the real slide keeps the true citation. Gate on a PLAIN
        # deck compiling first (typst/packages/network available), so offline skips both but a
        # citation-specific failure can never hide behind the skip.
        plain = try
            NS.export_pdf(_mknb("#%% md id=s\n## One\n\nplain\n"); layout = "slides")
        catch
            nothing
        end
        if plain === nothing
            @info "cited slide PDF compile skipped (typst unavailable)"
            @test true
        else
            nb = _mknb("#%% md id=s\n## Cited slide\n\nSee [@knuth1984, p. 3].\n\n" *
                       "#%% md id=refs bibliography\n@book{knuth1984,\n  author = {Knuth, D.},\n" *
                       "  title = {The TeXbook},\n  publisher = {Addison-Wesley},\n  year = {1984}\n}\n")
            pdf = NS.export_pdf(nb; layout = "slides")   # a throw here IS the regression
            @test length(pdf) > 1000
        end
    end
end

@testset "deck markup" begin
    R = KaimonSlate.ReportRender
    @testset "fenced divs: columns, steps, incremental" begin
        h = R.markdown_html(":::: columns\n::: {.column width=\"40%\"}\nL\n:::\n::: column\nR\n:::\n::::\n\n" *
                            "::: {.step .zoom step=3}\nS\n:::\n\n::: incremental\n- a\n- b\n:::\n\nkeep {braces}")
        @test occursin("<div class=\"columns\">", h) && occursin("max-width:40%", h)
        @test occursin("class=\"step zoom\"", h) && occursin("step=\"3\"", h)
        @test occursin("<div class=\"incremental\">", h)
        @test occursin("keep {braces}", h)                  # prose braces are not attributes
    end
    @testset "pause marker" begin
        h = R.markdown_html("one\n\n. . .\n\ntwo")
        @test occursin("<div class=\"pause\"></div>", h)
        @test !occursin(". . .", h)
    end
    @testset "media from image syntax" begin
        v = R.markdown_html("![autoplay loop](clips/a.mp4){width=600}")
        @test occursin("<video src=\"clips/a.mp4\"", v)
        @test all(occursin(v), ("controls", "loop", "data-autoplay", "playsinline", "width:600px"))
        @test !occursin("muted", v)                                   # autoplay keeps its sound
        @test occursin(" muted", R.markdown_html("![autoplay muted](a.mp4)"))
        a = R.markdown_html("![nocontrols](sound.m4a)")
        @test occursin("<audio src=\"sound.m4a\"", a) && !occursin("controls", a)
        @test occursin("<img", R.markdown_html("![plot](fig.png)"))
    end
    @testset "print drops deck markup, keeps content" begin
        s = NS._strip_deck_markup("::: step\nA\n:::\n. . .\nB\n```\n:::\n```")
        @test s == "A\nB\n```\n:::\n```"                     # fenced code untouched
        @test NS._strip_deck_markup("plain") == "plain"
    end
    @testset "SlideSteps" begin
        w = RE.SlideSteps(4)
        @test w.kind == "slider" && w.params["slidesteps"] === true
        @test w.params["min"] == 0 && w.params["max"] == 4 && w.default == 0
        @test_throws ArgumentError RE.SlideSteps(0)
    end
    @testset "asset byte ranges" begin
        p = tempname(); write(p, collect(UInt8, 0:9))
        req(r) = NS.HTTP.Request("GET", "/n/x/asset/a.mp4", r === nothing ? [] : ["Range" => r])
        full = NS._asset_response(req(nothing), p)
        @test full.status == 200 && length(full.body) == 10
        part = NS._asset_response(req("bytes=2-4"), p)
        @test part.status == 206 && part.body == UInt8[2, 3, 4]
        @test NS.HTTP.header(part, "Content-Range") == "bytes 2-4/10"
        @test NS._asset_response(req("bytes=7-"), p).body == UInt8[7, 8, 9]
        @test NS._asset_response(req("bytes=-3"), p).body == UInt8[7, 8, 9]
        @test NS._asset_response(req("bytes=20-"), p).status == 416
    end
end

@testset "relative media resolves to the asset route" begin
    h = NS._asset_srcs("talk", "<img src=\"figs/a.png\"><video src=\"c.mp4\" poster=\"p.jpg\"></video>" *
                               "<img src=\"/n/x/asset/b.png\"><img src=\"https://x/y.png\"><img src=\"data:image/png;base64,AA\">")
    @test occursin("src=\"/n/talk/asset/figs/a.png\"", h) && occursin("poster=\"/n/talk/asset/p.jpg\"", h)
    @test occursin("src=\"/n/x/asset/b.png\"", h) && occursin("src=\"https://x/y.png\"", h) && occursin("src=\"data:", h)
    @test NS._asset_srcs("", "<img src=\"a.png\">") == "<img src=\"a.png\">"
end

@testset "column widths become flex widths" begin
    h = KaimonSlate.ReportRender.markdown_html(":::: columns\n::: {.column width=\"40%\"}\nL\n:::\n::: {.column width=60}\nR\n:::\n::::")
    @test occursin("style=\"flex:0 1 40%;max-width:40%\"", h)
    @test occursin("style=\"flex:0 1 60%;max-width:60%\"", h)
end

@testset "presentation math macros print as plain math" begin
    f = NS._plain_math_macros
    @test f(raw"$\term{x}{\ddot x} + \stepat{2}{\term{g}{\gamma}\dot x} = \hl{0}$") == raw"${\ddot x} + {{\gamma}\dot x} = {0}$"
    @test f(raw"\cancelat{3}{\omega^2 x}") == raw"\cancel{\omega^2 x}"
    @test f(raw"\termc{F}{red}{\step{F(t)}}") == raw"{{F(t)}}"
    @test f(raw"\termination{a} \text{b}") == raw"\termination{a} \text{b}"      # other commands untouched
    @test f(raw"\term{x}") == raw"\term{x}"                                       # missing argument: left alone
    @test f(raw"\braceat{2}{c\dot x}{friction}") == raw"\underbrace{c\dot x}_{\text{friction}}"
    @test f(raw"\obraceat{1}{m}{mass}") == raw"\overbrace{m}^{\text{mass}}"
    @test f(raw"\focusat{4}{0}") == raw"{0}"
    @test f(raw"x = 0 \qquad \note{divide by m}") == raw"x = 0 \qquad \text{divide by m}"
end

@testset "the slides template defines every helper shared output calls" begin
    pre = NS._typst_preamble_slides("T")
    for h in ("codeblock", "outblock", "valblock", "errblock", "figureimg", "notefig", "figcaption", "paramblock")
        @test occursin("#let $h(", pre)
    end
end

@testset "the API reference covers the deck" begin
    r = NS.slate_api_reference
    @test all(k -> occursin(k, r("cell tags")), ("layout=", "bg=", "transition=", "step", "morph=", "ghost", "column="))
    @test occursin("steps =", r("echart"))
    @test all(k -> occursin(k, r("markdown")), (":::", "columns", ". . .", "clip.mp4", "math slides"))
    @test all(k -> occursin(k, r("slides")), ("deckstyle", "settings(notebook)", "nocontrols", "recordings/"))
    @test occursin("deckstyle", r("settings"))
    @test all(k -> occursin(k, r("math slides")), ("\\term", "\\braceat", "\\note", "::: derive", "STEPS."))
end

@testset "slide_figure: stacked states and the shared palette" begin
    RE = KaimonSlate.ReportEngine
    sf = RE.SlideFigure(800, 400, UInt8[1], [(1, :png, UInt8[2], UInt8[]), (2, :mp4, UInt8[3], UInt8[4])])
    h = sprint(show, MIME("text/html"), sf)
    @test occursin("class=\"slidefig\"", h) && occursin("aspect-ratio:800/400", h)
    @test occursin("<img class=\"step fade sf-layer\" step=\"1\"", h)
    @test occursin("<video class=\"step fade sf-layer sf-anim\" step=\"2\"", h) && occursin("poster=\"data:image/png", h)
    # The figure palette is the one the slide math colours terms with (core.js SLATE_TERM_PALETTE).
    js = read(joinpath(@__DIR__, "..", "src", "assets", "js", "core.js"), String)
    for (k, v) in pairs(RE.SLATE_COLORS)
        @test occursin("$k: '$v'", js)
    end
    @test RE.slate_color(:red) == "#fc6255"
    @test RE._limits_at((0.0, 1.0, 0.0, 1.0), (2.0, 3.0, 2.0, 3.0), 1.0) == (2.0, 3.0, 2.0, 3.0)
end

@testset "print takes a slide_figure's finished state" begin
    RE = KaimonSlate.ReportEngine
    sf = RE.SlideFigure(10, 10, UInt8[1], [(1, :png, UInt8[2], UInt8[]), (2, :mp4, UInt8[3], UInt8[9])])
    out = (; display = [(; mime = "text/html", data = Vector{UInt8}(codeunits(sprint(show, MIME("text/html"), sf))))])
    @test NS._slidefig_final_png(out) == UInt8[9]          # the final clip's poster frame
    @test NS._slidefig_final_png((; display = [(; mime = "text/html", data = UInt8[0x3c])])) === nothing
end
