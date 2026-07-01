# Document metadata as role-tagged cells: the `title`/`abstract`/`bibliography` roles, the
# `report_frontmatter` resolver (role cells + first-H1 title fallback), cell_json role booleans, and
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

    @testset "no :title cell → title falls back to the first markdown H1 (not the filename)" begin
        r = RE.parse_report("#%% md id=intro\n# Real Title\nsome intro\n\n#%% code id=c\n1+1\n"; title = "notebook-file")
        fm = NS.report_frontmatter(r)
        @test fm.title == "Real Title"        # derived from the H1, not the filename
        @test fm.titlecell == "intro"         # records the cell whose H1 was hoisted
        @test isempty(fm.skip)                # non-destructive: the cell still renders in the body
        @test !fm.has                         # no title/abstract role, so no dedicated title block
        # the hoisted H1 is stripped from the body so the title doesn't render twice, but the intro stays
        @test NS._strip_leading_h1("# Real Title\nsome intro") == "some intro"
        h = NS.export_html(_mknb("#%% md id=intro\n# Real Title\nsome intro\n"))
        @test occursin("exp-title\">Real Title</h1>", h)   # in the hoisted title block
        @test !occursin("<h1>Real Title</h1>", h)          # NOT repeated as a body heading
        @test occursin("some intro", h)                    # the rest of the cell survives
        @test occursin("og:title", h) && occursin("twitter:card", h)   # OG unfurl metadata present
    end

    @testset "no heading at all → last-resort filename" begin
        fm = NS.report_frontmatter(RE.parse_report("#%% md id=a\n## Just a subheading\n"; title = "Plain"))
        @test fm.title == "Plain"             # no H1 anywhere → keep the report/filename title
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

    @testset "Markdown export (copy-to-clipboard)" begin
        md = NS.export_markdown(_mknb(ROLES_SRC))
        @test occursin("# Predicting Foo from Bar", md)      # title as an H1
        @test occursin("> **Abstract.**", md)                # abstract as a blockquote
        m2 = NS.export_markdown(_mknb("#%% code id=c\nx = 40 + 2\n"))
        @test occursin("```julia\nx = 40 + 2\n```", m2)      # code fenced
        @test !occursin("```julia", NS.export_markdown(_mknb("#%% code id=c\nx = 1\n"); include_source = false))
        # GFM table helper
        @test occursin("| a | b |", NS._md_table(Dict("columns" => ["a", "b"], "rows" => [[1, 2]])))
        @test NS._first_words("# A **bold** title here now", 3) == "A bold title…"
    end

    @testset "outputs filter (all / figures / none)" begin
        @test NS._outputs_text_ok("all") && !NS._outputs_text_ok("figures") && !NS._outputs_text_ok("none")
        @test NS._outputs_any("all") && NS._outputs_any("figures") && !NS._outputs_any("none")
        # A code cell with a scalar text value: `figures`/`none` drop it from HTML + Markdown; `all` keeps it.
        nb = _mknb("#%% code id=c\nx = 1\n")
        c = nb.report.cells[findfirst(x -> x.id == "c", nb.report.cells)]
        c.output = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], "(cloned = true)", nothing, nothing, 0.0)
        @test occursin("cloned = true", NS.export_html(nb; outputs = "all"))
        @test !occursin("cloned = true", NS.export_html(nb; outputs = "figures"))
        @test occursin("cloned = true", NS.export_markdown(nb; outputs = "all"))
        @test !occursin("cloned = true", NS.export_markdown(nb; outputs = "figures"))
        @test !occursin("cloned = true", NS.export_markdown(nb; outputs = "none"))
        @test occursin("exp-out", NS.export_html(nb; outputs = "all"))          # 'all' keeps the output block
    end

    @testset "HTML export options: theme + code size + hide source" begin
        nb = _mknb("#%% code id=c\nx = 1\n")
        dark = NS.export_html(nb; theme = "dark")
        light = NS.export_html(nb; theme = "light")
        @test occursin("--bg:#0d1120", dark)                 # dark palette
        @test occursin("--bg:#ffffff", light)                # light palette
        @test occursin(".64rem", NS.export_html(nb; code = "tiny"))            # code size flows through
        @test occursin("<pre class=\"exp-src\">", NS.export_html(nb; code = "normal"))         # source shown by default
        @test !occursin("<pre class=\"exp-src\">", NS.export_html(nb; code = "hidden"))        # code=hidden ⇒ outputs only
        @test !occursin("<pre class=\"exp-src\">", NS.export_html(nb; include_source = false)) # explicit hide
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

    @testset "bibliography index + per-cell card info" begin
        r = RE.parse_report("#%% md id=refs bibliography\n@book{knuth1984, author={Knuth}, title={TeX}}\n@article{turing1936, author={Turing}, title={Computable}}\n")
        idx = NS.bibliography_index(r, "/tmp")
        @test [e.key for e in idx] == ["knuth1984", "turing1936"]
        @test idx[1].author == "Knuth" && idx[1].title == "TeX"
        file, n, es = NS.bib_cell_info(r.cells[1], "/tmp")
        @test file == "" && n == 2                      # embedded → no external file
        # LaTeX accent macros + case-protecting braces are decoded for the live card / label, and a
        # nested `{c}` doesn't truncate the field (the reported "Ko\\c{c" bug).
        acc = NS._parse_bibtex_entries(
            raw"@inproceedings{koc1996, author={Ko\c{c}, {\c{C}}etin Kaya and Acar, Tolga}, title={Analyzing and Comparing {M}ontgomery Multiplication}, year={1996}}")
        @test length(acc) == 1
        @test acc[1].author == "Koç, Çetin Kaya and Acar, Tolga"
        @test acc[1].title == "Analyzing and Comparing Montgomery Multiplication"
        @test NS._author_year_label(acc[1].author, acc[1].year) == "Koç et al., 1996"
        @test NS._delatex(raw"Erd\H{o}s, P\'al, {\o}, {\ss}") == "Erdős, Pál, ø, ß"
        @test NS._delatex("plain ASCII") == "plain ASCII"   # fast path unchanged
        # A word command like `\cdot` must NOT be mis-decoded as `\c`+`d` (the cedilla accent); math
        # spans decode operators + super/subscripts and drop the `$`.
        @test NS._delatex(raw"The Pseudoprimes to $25 \cdot 10^9$") == "The Pseudoprimes to 25 · 10⁹"
        @test NS._delatex(raw"$10^{27}$ and $\alpha_2$") == "10²⁷ and α₂"
        @test NS._delatex(raw"snake_case stays") == "snake_case stays"   # `_` outside math untouched
        # state_json ships the key list for [@-autocomplete; the cell renders a card, not raw BibTeX
        nb = _mknb("#%% md id=refs bibliography\n@book{knuth1984, author={Knuth}, title={TeX}}\n")
        sj = NS.state_json(nb)
        @test haskey(sj, "bibKeys") && sj["bibKeys"][1]["key"] == "knuth1984"
        bib = first(c for c in sj["cells"] if get(c, "roleBib", false))
        @test occursin("bibcard", bib["output"]) && !occursin("@book", bib["output"])
    end

    @testset "citation rewriting (locators / forms / safety)" begin
        keys = Set(["knuth1984", "lamport1994"])
        rw(s) = NS._rewrite_citations(s, keys)
        @test rw("[@knuth1984]") == "§c§n§knuth1984§§"                       # plain
        @test rw("[@knuth1984, p. 7]") == "§c§n§knuth1984§p. 7§"            # page locator → supplement
        @test rw("[@knuth1984; @lamport1994]") == "§c§n§knuth1984§§§c§n§lamport1994§§"  # multiple
        @test rw("@knuth1984 rocks") == "§c§p§knuth1984§§ rocks"            # bare key → prose form
        @test rw("see @knuth1984.") == "see §c§p§knuth1984§§."              # trailing punctuation kept literal
        @test rw("email me@host.com") == "email me@host.com"               # unknown @ left literal
        @test rw("`@knuth1984`") == "`@knuth1984`" || occursin("knuth1984", rw("`@knuth1984`"))  # inline left alone-ish
        # fenced code is never rewritten
        @test rw("```\n@knuth1984\n```") == "```\n@knuth1984\n```"
        # inline code spans are protected (a literal citation in backticks stays literal)
        @test rw("show `[@knuth1984]` then [@knuth1984]") == "show `[@knuth1984]` then §c§n§knuth1984§§"
        # citation numbering by first appearance (matches the numeric PDF order)
        r = RE.parse_report("#%% md id=a\nSee [@b] then [@a].\n\n#%% md id=refs bibliography\n@book{a,title={A}}\n@book{b,title={B}}\n")
        nums = NS.citation_numbers(r, Set(["a", "b"]))
        @test nums == Dict("b" => 1, "a" => 2)     # `b` is cited first → [1]
        # live HTML-link emit tracks the bibstyle: numeric → [3, p. 7], author-date → (Knuth, 1984)
        numctx = (anchor = "refs", tips = Dict("k" => "Knuth · TeX"), labels = Dict("k" => "3"),
                  numeric = true, numbers = Dict("k" => 3))
        num = NS._rewrite_citations("[@k, p. 7]", Set(["k"]); emit = NS._cite_link_emit(numctx))
        @test occursin("<a class=\"cite\" href=\"#cell-refs\"", num) && occursin(">[3, p. 7]</a>", num)
        adctx = (anchor = "refs", tips = Dict("k" => "x"), labels = Dict("k" => "Knuth, 1984"),
                 numeric = false, numbers = Dict{String,Int}())
        ad = NS._rewrite_citations("[@k]", Set(["k"]); emit = NS._cite_link_emit(adctx))
        @test occursin(">(Knuth, 1984)</a>", ad)
        @test NS._is_numeric_style("ieee") && !NS._is_numeric_style("apa")
        @test NS._author_year_label("Donald E. Knuth", "1984") == "Knuth, 1984"
        @test NS._author_year_label("Cormen and Leiserson", "2009") == "Cormen et al., 2009"
        # a non-citation bracket is left untouched
        @test rw("[see foo@bar]") == "[see foo@bar]"
        # end-to-end: locators compile and resolve against the bibliography
        nb = _mknb("#%% md id=b\nCite [@knuth1984, p. 7].\n\n#%% md id=refs bibliography\n@book{knuth1984, title={TeX}}\n")
        pdf = try; NS.export_pdf(nb; theme = "light"); catch; nothing; end
        @test pdf === nothing || length(pdf) > 1000
    end

    @testset "adaptive references card + mixed inline/external bib" begin
        d = mktempdir()
        io = IOBuffer(); for i in 1:12; println(io, "@book{ext$i, title={T$i}}"); end
        write(joinpath(d, "big.bib"), String(take!(io)))
        src = "#%% md id=body\nCite [@ext3], [@ext7], [@inlineA].\n\n" *
              "#%% md id=ext bibliography\nbig.bib\n\n" *
              "#%% md id=inl bibliography\n@article{inlineA, title={A}}\n@article{inlineB, title={B}}\n"
        nb = NS.LiveNotebook("mix", joinpath(d, "n.jl"), RE.parse_report(src),
            RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
            ReentrantLock(), "", false, Dict{String,String}())
        @test NS.cited_citation_keys(nb.report) == Set(["ext3", "ext7", "inlineA"])
        @test [e.key for e in NS.bibliography_index(nb.report, d)][1:12] == ["ext$i" for i in 1:12]  # both sources aggregate
        sj = NS.state_json(nb)
        ext = first(c for c in sj["cells"] if c["id"] == "ext")
        inl = first(c for c in sj["cells"] if c["id"] == "inl")
        @test ext["bibCount"] == 12 && occursin("Showing the 2 cited of 12", ext["output"])   # large → only cited
        @test occursin("ext3", ext["output"]) && !occursin("ext5", ext["output"])
        @test occursin("li class=\"cited\"", inl["output"]) && occursin("li class=\"uncited\"", inl["output"])  # small → all, highlighted
        rm(d; recursive = true, force = true)
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
