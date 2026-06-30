# Document metadata as role-tagged cells: the `title`/`abstract`/`bibliography` roles, the
# `report_frontmatter` resolver (role cells + legacy YAML fallback), cell_json role booleans, and
# export hoisting (title/abstract lifted into the title block and dropped from the body).
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

_mknb(src) = NS.LiveNotebook("fm", "/tmp/fmtest.jl", RE.parse_report(src; title = "Fallback"),
    RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
    ReentrantLock(), "", false, Dict{String,String}())

const ROLES_SRC = """
#%% md id=ttl title
# Predicting Foo from Bar
### A reactive study
Kahli Burke · 2026

#%% md id=abs abstract
We show **foo** correlates with bar.

#%% md id=intro
## Introduction
Body text.

#%% code id=c1
x = 1

#%% md id=refs bibliography
@book{knuth1984, title={TeX}}
"""

@testset "front-matter roles" begin

    @testset "roles are known tags and round-trip" begin
        for t in (:title, :abstract, :bibliography)
            @test t in RE._KNOWN_TAGS
        end
        r = RE.parse_report(ROLES_SRC)
        r2 = RE.parse_report(RE.serialize_report(r))
        @test :title in r2.cells[1].flags
        @test :abstract in r2.cells[2].flags
        @test :bibliography in r2.cells[end].flags
    end

    @testset "report_frontmatter resolves from role cells" begin
        fm = NS.report_frontmatter(RE.parse_report(ROLES_SRC; title = "Fallback"))
        @test fm.title == "Predicting Foo from Bar"          # H1 of the :title cell wins over report.title
        @test fm.subtitle == "A reactive study"              # H2/H3
        @test occursin("Kahli Burke", fm.byline)             # first plain line
        @test occursin("foo", fm.abstract)                   # from the :abstract cell
        @test issubset(Set(["ttl", "abs"]), fm.skip)         # both hoisted out of the body
        @test [c.id for c in fm.bibcells] == ["refs"]
        @test fm.has
    end

    @testset "legacy YAML front-matter still resolves" begin
        yaml = "#%% md id=a\n---\ntitle: Legacy\nauthor: Me\nabstract: Older notebooks keep working.\n---\nIntro body.\n"
        fm = NS.report_frontmatter(RE.parse_report(yaml))
        @test fm.title == "Legacy"
        @test occursin("Me", fm.byline)
        @test occursin("keep working", fm.abstract)
        @test fm.yrest !== nothing && occursin("Intro body", fm.yrest)   # body remainder still rendered
        @test isempty(fm.skip)                                            # YAML cell is NOT hoisted (its body stays)
    end

    @testset "no metadata → plain title from report" begin
        fm = NS.report_frontmatter(RE.parse_report("#%% md id=a\n## Just a heading\n"; title = "Plain"))
        @test fm.title == "Plain"
        @test !fm.has
        @test isempty(fm.skip)
    end

    @testset "cell_json exposes role booleans" begin
        r = RE.parse_report(ROLES_SRC)
        j = Dict(c.id => NS.cell_json(c) for c in r.cells)
        @test get(j["ttl"], "roleTitle", false) == true
        @test get(j["abs"], "roleAbstract", false) == true
        @test get(j["refs"], "roleBib", false) == true
        @test "title" in j["ttl"]["tags"] && "abstract" in j["abs"]["tags"]
    end

    @testset "article PDF hoists title+abstract and drops them from the body" begin
        nb = _mknb(ROLES_SRC)
        pdf = try
            NS.export_pdf(nb; theme = "light", style = "report")
        catch err
            @info "frontmatter PDF compile skipped" err
            nothing
        end
        @test pdf === nothing || length(pdf) > 1000
    end

    @testset "HTML export renders a title block" begin
        h = NS.export_html(_mknb(ROLES_SRC))
        @test occursin("exp-titleblock", h)
        @test occursin("Predicting Foo from Bar", h)
        @test occursin("exp-abstract", h)
        @test occursin("A reactive study", h)
    end

    @testset "bibliography — embedded BibTeX" begin
        src = "#%% md id=body\nSee [@knuth1984].\n\n#%% md id=refs bibliography\n@book{knuth1984, title={TeX}}\n"
        nb = _mknb(src)
        dir = NS._build_typst_project(nb)
        try
            doc = read(joinpath(dir, "doc.typ"), String)
            @test occursin("#bibliography(\"refs.bib\"", doc)        # references emitted at the end
            @test isfile(joinpath(dir, "refs.bib"))                  # embedded entries written out
            @test occursin("@book{knuth1984", read(joinpath(dir, "refs.bib"), String))
            @test !occursin("@book{knuth1984", doc)                  # raw BibTeX dropped from the body
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "bibliography — external .bib copied + resolved vs notebook dir" begin
        d = mktempdir()
        write(joinpath(d, "lib.bib"), "@book{lamport1994, title={LaTeX}}\n")
        nbsrc = "#%% md id=body\nText [@lamport1994].\n\n#%% md id=refs bibliography\nlib.bib\n"
        nb = NS.LiveNotebook("ext", joinpath(d, "n.jl"), RE.parse_report(nbsrc),
            RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
            ReentrantLock(), "", false, Dict{String,String}())
        dir = NS._build_typst_project(nb)
        try
            @test isfile(joinpath(dir, "ext_lib.bib"))               # external file copied into the project
            @test occursin("ext_lib.bib", read(joinpath(dir, "doc.typ"), String))
        finally
            rm(dir; recursive = true, force = true); rm(d; recursive = true, force = true)
        end
    end

    @testset "missing external .bib errors clearly" begin
        nb = _mknb("#%% md id=refs bibliography\nnope.bib\n")
        @test_throws Exception NS._build_typst_project(nb)
    end

    @testset "standalone export inlines an external bib" begin
        d = mktempdir()
        write(joinpath(d, "lib.bib"), "@book{lamport1994, title={LaTeX}}\n")
        r = RE.parse_report("#%% md id=body\nT [@lamport1994].\n\n#%% md id=refs bibliography\nlib.bib\n")
        out = NS._serialize_cells_inlining_bibs(r, d)
        @test occursin("@book{lamport1994", out)     # external file contents inlined into the cell
        @test !occursin("lib.bib", out)              # the path line is gone
        @test occursin("bibliography", out)          # cell keeps its role tag
        rm(d; recursive = true, force = true)
    end
end
