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
