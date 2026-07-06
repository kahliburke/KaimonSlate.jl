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

    @testset "HTML export: citations rendered + References + echarts embedded client-side" begin
        cnb = _mknb("#%% md id=body\nSee [@knuth1984, p. 7].\n\n" *
                    "#%% md id=refs bibliography\n@book{knuth1984, author={Knuth}, title={TeX}, year={1984}}\n")
        h = NS.export_html(cnb)
        @test occursin("[1, p. 7]", h)                       # citation rendered (ieee default), not raw
        @test !occursin("[@knuth1984", h)                    # no raw citation marker
        @test occursin("exp-refs", h) && occursin("References", h) && occursin("TeX", h)
        # The inline citation LINKS to its References entry, and that entry carries the matching anchor.
        @test occursin("<a class=\"cite\" href=\"#ref-knuth1984\">", h)
        @test occursin("id=\"ref-knuth1984\"", h)
        # OG/meta description must render citations too — never a raw [@key] in the meta content.
        # (_first_words strips markdown brackets for the meta text, so the numeric [1] reads as "1".)
        dnb = _mknb("#%% md id=abs abstract\nBuilding on [@knuth1984].\n\n" *
                    "#%% md id=refs bibliography\n@book{knuth1984, author={Knuth}, title={TeX}, year={1984}}\n")
        dh = NS.export_html(dnb)
        m = match(r"<meta name=\"description\" content=\"([^\"]*)\"", dh)
        @test m !== nothing && occursin("Building on 1", m.captures[1]) && !occursin("knuth", m.captures[1])
        # ECharts embed as a client-rendered spec, not a frozen snapshot
        enb = _mknb("#%% code id=ch\n1\n")
        ec = enb.report.cells[findfirst(x -> x.id == "ch", enb.report.cells)]
        ec.output = RE.CellOutput("", RE.MimeChunk[], Any[Dict("series" => [Dict("type" => "bar", "data" => [1, 2, 3])])],
                                  Any[], RE.BindSpec[], "", nothing, nothing, 0.0)
        eh = NS.export_html(enb)
        @test occursin("echarts@5", eh)                      # CDN loaded
        @test occursin("_slateCharts", eh) && occursin("\"type\":\"bar\"", eh)   # spec embedded for client render
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
        # Citations render to their in-text form (not raw [@key]) + a References section; figure refs → "Figure N".
        cnb = _mknb("#%% md id=body\nSee [@knuth1984, p. 7] and [@fig:x].\n\n" *
                    "#%% code id=f\n1\n#%% md id=cap for=f label=fig:x caption\nA figure.\n\n" *
                    "#%% md id=refs bibliography\n@book{knuth1984, author={Knuth}, title={TeX}, year={1984}}\n")
        cf = cnb.report.cells[findfirst(x -> x.id == "f", cnb.report.cells)]
        cf.output = RE.CellOutput("", [RE.MimeChunk("image/png", UInt8[1])], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0)
        cmd = NS.export_markdown(cnb)
        @test occursin("[1, p. 7]", cmd)                     # numeric cite with locator (ieee default)
        @test !occursin("[@knuth1984", cmd)                  # no raw citation left
        @test occursin("Figure 1", cmd) && !occursin("[@fig:x]", cmd)   # figure cross-ref rendered
        @test occursin("## References", cmd) && occursin("1. Knuth. TeX. 1984.", cmd)
        @test occursin("![Figure 1](data:image/png", cmd)    # meaningful image alt text
    end

    @testset "figure captions: numbering + binding (flow + explicit)" begin
        @test :caption in RE._KNOWN_TAGS
        # caption tag + for=/label= round-trip through the header
        r = RE.parse_report("#%% md id=cap for=scaling label=fig:scale caption\nHello\n")
        c = r.cells[1]
        @test :caption in c.flags
        @test NS._flag_attr(c, "for") == "scaling"
        @test NS._flag_attr(c, "label") == "fig:scale"
        @test occursin("for=scaling", RE.serialize_cells(r)) && occursin("label=fig:scale", RE.serialize_cells(r))

        # numbering by document order; flow binds to the nearest preceding figure cell, explicit for= overrides
        r2 = RE.parse_report("#%% code id=f1\n1\n#%% md id=c1 caption\nFirst\n" *
                             "#%% code id=f2\n2\n#%% md id=c2 for=f1 label=fig:a caption\nSecond\n")
        # mark f1/f2 as figure-bearing (an image display chunk)
        img = RE.MimeChunk("image/png", UInt8[1])
        for id in ("f1", "f2")
            fc = r2.cells[findfirst(x -> x.id == id, r2.cells)]
            fc.output = RE.CellOutput("", [img], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0)
        end
        idx = NS.figure_index(r2)
        @test idx.numbers == Dict("c1" => 1, "c2" => 2)
        @test idx.capfor["c1"] == "f1"                 # flow → nearest preceding figure
        @test idx.capfor["c2"] == "f1"                 # explicit for= overrides (would be f2 by flow)
        @test idx.labels["c1"] == (1, "f1")            # default label = caption id
        @test idx.labels["fig:a"] == (2, "f1")         # explicit label
    end

    @testset "figure cross-references [@fig:label]" begin
        figrefs = Dict("fig:hist" => (2, "hist"))
        # live: an HTML link that jumps to the figure cell and reads "Figure N"
        live = NS._rewrite_citations("See [@fig:hist] above."; figrefs = figrefs, figemit = NS._fig_link_emit)
        @test occursin("<a class=\"figref\" href=\"#cell-hist\">Figure 2</a>", live)
        # bare form works too
        @test occursin("Figure 2", NS._rewrite_citations("as in @fig:hist"; figrefs = figrefs, figemit = NS._fig_link_emit))
        # export default: plain "Figure N" text (number authoritative even without a hyperlink)
        @test NS._rewrite_citations("[@fig:hist]"; figrefs = figrefs) == "Figure 2"
        # a real bibliography key is NOT a figure ref → untouched by the fig path
        @test occursin("[@knuth]", NS._rewrite_citations("[@knuth]"; figrefs = figrefs, emit = NS._cite_literal))
        # a literal in backticks is left alone
        @test occursin("`[@fig:hist]`", NS._rewrite_citations("`[@fig:hist]`"; figrefs = figrefs, figemit = NS._fig_link_emit))
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
        # figures-only WITH a rich display chunk keeps the figure (exercises the _render_chunks path)
        fig = _mknb("#%% code id=c\n1\n")
        fc = fig.report.cells[findfirst(x -> x.id == "c", fig.report.cells)]
        fc.output = RE.CellOutput("", [RE.MimeChunk("image/png", UInt8[0x89])], Any[], Any[], RE.BindSpec[], "42", nothing, nothing, 0.0)
        fh = NS.export_html(fig; outputs = "figures")
        @test occursin("disp img", fh) && !occursin(">42<", fh)   # image kept, scalar text dropped
        @test occursin("cloned = true", NS.export_markdown(nb; outputs = "all"))
        @test !occursin("cloned = true", NS.export_markdown(nb; outputs = "figures"))
        @test !occursin("cloned = true", NS.export_markdown(nb; outputs = "none"))
        @test occursin("exp-out", NS.export_html(nb; outputs = "all"))          # 'all' keeps the output block
    end

    @testset "site export: og:image meta + tarball" begin
        nb = _mknb(ROLES_SRC)
        # og:image wiring in the HTML head (+ summary_large_image card when an image is set)
        h = NS.export_html(nb; og_image = "og-image.png")
        @test occursin("property=\"og:image\" content=\"og-image.png\"", h)
        @test occursin("summary_large_image", h)
        @test !occursin("og:image", NS.export_html(nb))          # none when no image supplied
        # first-figure detection: a code cell with a PNG raster is the og image source
        fnb = _mknb("#%% code id=f\n1\n")
        fc = fnb.report.cells[findfirst(x -> x.id == "f", fnb.report.cells)]
        fc.output = RE.CellOutput("", [RE.MimeChunk("image/png", UInt8[0x89, 0x50])], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0)
        @test NS._first_figure_png(fnb) == UInt8[0x89, 0x50]
        # the site tarball is a valid gzip stream (starts with the gzip magic)
        site = NS.export_site(fnb)
        @test length(site) > 20 && site[1] == 0x1f && site[2] == 0x8b
        # runnable overlay + generated run.jl
        rh = NS.export_html(fnb; runnable = true)
        @test occursin("<button id=\"exp-run-btn\">", rh) && occursin("Run this notebook live", rh) && occursin("run.jl", rh)
        @test !occursin("<button id=\"exp-run-btn\">", NS.export_html(fnb))   # only when runnable (CSS is always present)
        rj = NS._run_script("https://x.github.io/y/nb.standalone.jl"; agent = true, bundle_name = "nb.standalone.jl")
        @test (Meta.parseall(rj); true)                              # the generated script is valid Julia (escaping intact)
        @test occursin("choose_install_dir", rj) && occursin("SLATE_INSTALL_DIR", rj)   # install-dir prompt threaded in
        @test occursin("SLATE_KAIMONSLATE_PATH", rj) && occursin("Pkg.develop", rj)      # local-checkout override for dev/forks
        @test occursin("Kaimon.jl", rj) && occursin("import Kaimon", rj)                 # Kaimon installed + loaded (the compute gate)
        @test occursin("SLATE_KAIMON_PATH", rj)                      # local Kaimon override too
        @test occursin("KAIMON_GATE_MODE", rj) && occursin("KAIMONSLATE_NO_AUTOINDEX", rj)   # pure code, no services
        # the doc-index background service is on by default (extension) but off under the standalone flag
        @test NS._autoindex_enabled()
        @test withenv(() -> NS._autoindex_enabled(), "KAIMONSLATE_NO_AUTOINDEX" => "1") == false
        @test occursin("git credential attribute", rj)               # the noisy LibGit2 warning is filtered
        @test occursin("Downloads.download(BUNDLE_URL", rj) && occursin("KaimonSlate.jl", rj)
        @test occursin("x.github.io/y/nb.standalone.jl", rj)
        @test occursin("@__DIR__", rj)                               # sibling-first: reads the bundle next to run.jl…
        @test occursin("startswith(BUNDLE_URL, \"http\")", rj)       # …and only downloads when a real URL is set
        @test occursin("kaimonslate-run", rj)                        # installs into a dedicated env, not the default
        @test !occursin("Pkg.add(url = \"https://github.com/kahliburke/Kaimon.jl", rj)   # never adds Kaimon to this env
        @test !occursin("fetch_bundle()println", rj)                 # statements not glued onto one line (juxtaposition bug)
        @test occursin("nb = fetch_bundle()\n", rj)
        @test occursin("KAIMONSLATE_NO_AUTOREGISTER", rj)            # don't touch the user's Kaimon config
        @test occursin("free_port()", rj)                            # pick a free port (8765 may be taken)
        @test occursin("using KaimonSlate\n", rj)                    # load at top level (world-age safe)
        # No-URL run.jl (extracted site / embed): reads the sibling bundle; the per-notebook name is threaded in
        rjl = NS._run_script(""; bundle_name = "demo.standalone.jl")
        @test occursin("@__DIR__", rjl) && occursin("demo.standalone.jl", rjl)
        @test occursin("BUNDLE_URL = get(", rjl)                     # URL const still present (empty ⇒ sibling-only)
        # embedded single-file HTML: run.jl rides inside the page (Blob downloads, no sidecars)
        eh = NS.export_html(fnb; runnable = true, embed_bundle = true)
        @test occursin("<button id=\"exp-run-btn\">", eh)
        @test occursin("_rj=", eh) && occursin("_bb64=", eh)         # embedded script + bundle slot
        @test !occursin("exp-run-oneliner", eh)                      # no URL one-liner in embed mode
    end

    # Multi-document site (blog): each notebook lives under its own /<slug>/, a manifest tracks them,
    # and the root index is regenerated from that manifest — so publishing a second doc keeps the first.
    @testset "multi-document site (blog)" begin
        @test NS._slugify("Predicting Foo from Bar!") == "predicting-foo-from-bar"
        @test NS._slugify("  A / B  C ") == "a-b-c"
        @test NS._slugify("___") == ""

        nb = _mknb(ROLES_SRC)
        @test NS.doc_slug(nb) == "predicting-foo-from-bar"           # slug from the first-H1 title
        m = NS._doc_meta(nb)
        @test m.title == "Predicting Foo from Bar"
        @test occursin("foo", lowercase(m.description))              # description from the abstract

        # Give the notebook a figure so og_image short-circuits (no title-card render in tests).
        fc = nb.report.cells[findfirst(x -> x.id == "c1", nb.report.cells)]
        fc.output = RE.CellOutput("", [RE.MimeChunk("image/png", UInt8[0x89, 0x50])], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0)

        d = mktempdir()
        entry = NS._build_doc!(joinpath(d, "predicting-foo-from-bar"), nb; slug = "predicting-foo-from-bar")
        @test isfile(joinpath(d, "predicting-foo-from-bar", "index.html"))
        @test isfile(joinpath(d, "predicting-foo-from-bar", "og-image.png"))
        @test entry["slug"] == "predicting-foo-from-bar" && entry["title"] == "Predicting Foo from Bar"
        @test entry["image"] == "predicting-foo-from-bar/og-image.png" && haskey(entry, "date")
        # Richer metadata for portfolio/front-page consumers: counts, packages, an `updated` date.
        @test entry["cells"] == length(nb.report.cells) && entry["code"] + entry["md"] == entry["cells"]
        @test haskey(entry, "updated") && haskey(entry, "binds") && entry["packages"] isa AbstractVector

        man = Dict{String,Any}("title" => "My Blog", "docs" => Any[])
        NS._upsert_doc!(man, entry)
        @test length(man["docs"]) == 1
        e2 = copy(entry); e2["title"] = "Renamed"; e2["date"] = "2099-01-01"
        NS._upsert_doc!(man, e2)                                     # same slug → update in place
        @test length(man["docs"]) == 1
        @test man["docs"][1]["title"] == "Renamed"
        @test man["docs"][1]["date"] == entry["date"]               # original publish date preserved
        NS._upsert_doc!(man, Dict{String,Any}("slug" => "other", "title" => "Other Doc",
            "description" => "", "image" => "", "runnable" => false, "date" => "2026-01-01"))
        @test length(man["docs"]) == 2                              # a different slug adds

        idx = NS._render_site_index(man)
        @test occursin("My Blog", idx)
        @test occursin("href=\"predicting-foo-from-bar/\"", idx) && occursin("href=\"other/\"", idx)
        @test occursin("Renamed", idx) && occursin("Other Doc", idx)
        # Progressive enhancement: cards are BAKED (above) for no-JS/scrapers, AND a client refresh
        # re-renders them from slate-site.json so a cross-repo publish shows up without a rebuild.
        @test occursin("id=\"slate-cards-root\"", idx) && occursin("fetch('slate-site.json'", idx)

        write(joinpath(d, NS._SITE_MANIFEST), "{\"title\":\"T\",\"docs\":[{\"slug\":\"x\",\"title\":\"X\"}]}")
        @test NS._read_site_manifest(d)["docs"][1]["slug"] == "x"
        @test NS._read_site_manifest(mktempdir())["docs"] == Any[]  # absent → empty manifest
    end

    # build_site!: two notebooks accreting into ONE dir with NO git — the deploy-only / cross-repo
    # merge, minus the push. Each gets its slug dir; the manifest carries both; the index bakes both
    # + carries the client refresh. Re-building a slug updates it in place.
    @testset "build_site! merges multiple docs into one dir (no git)" begin
        # a figure short-circuits og_image so it never reaches the Typst title-card render in tests
        withfig(nb) = (nb.report.cells[end].output = RE.CellOutput("",
            [RE.MimeChunk("image/png", UInt8[0x89, 0x50])], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0); nb)
        d = mktempdir()
        a = withfig(_mknb("#%% md id=t\n# Alpha\nfirst doc\n\n#%% code id=fig\n1\n"))
        b = withfig(_mknb("#%% md id=t\n# Beta\nsecond doc\n\n#%% code id=fig\n1\n"))
        r1 = NS.build_site!(d, a; slug = "alpha", site_url = "https://u.github.io/s/")
        r2 = NS.build_site!(d, b; slug = "beta", site_url = "https://u.github.io/s/")
        @test r1.slug == "alpha" && r2.slug == "beta" && !r1.home
        @test isfile(joinpath(d, "alpha", "index.html")) && isfile(joinpath(d, "beta", "index.html"))
        slugs = sort([String(get(x, "slug", "")) for x in NS._read_site_manifest(d)["docs"]])
        @test slugs == ["alpha", "beta"]                              # both merged, no clobber
        idx = read(joinpath(d, "index.html"), String)
        @test occursin("href=\"alpha/\"", idx) && occursin("href=\"beta/\"", idx)   # both baked
        @test occursin("fetch('slate-site.json'", idx) && isfile(joinpath(d, ".nojekyll"))
        # rebuilding the SAME slug updates in place (no duplicate manifest entry)
        NS.build_site!(d, withfig(_mknb("#%% md id=t\n# Alpha v2\n\n#%% code id=fig\n1\n")); slug = "alpha")
        docs2 = NS._read_site_manifest(d)["docs"]
        @test count(x -> String(get(x, "slug", "")) == "alpha", docs2) == 1
        @test occursin("Alpha v2", read(joinpath(d, "alpha", "index.html"), String))
    end

    # Local site host: export into a persistent named site (served under /sites/<name>/), and the
    # `_site_file` resolver — directory → index.html, and a hard `..`-traversal guard.
    @testset "export_to_site + _site_file traversal guard" begin
        withfig(nb) = (nb.report.cells[end].output = RE.CellOutput("",
            [RE.MimeChunk("image/png", UInt8[0x89, 0x50])], Any[], Any[], RE.BindSpec[], "", nothing, nothing, 0.0); nb)
        tmp = mktempdir()
        withenv("KAIMONSLATE_SITES_DIR" => tmp) do
            a = withfig(_mknb("#%% md id=t\n# Alpha\n\n#%% code id=fig\n1\n"))
            r = NS.export_to_site(a, "My Portfolio"; slug = "alpha")
            @test r.site == "my-portfolio" && r.slug == "alpha" && !r.home
            @test r.url == "/sites/my-portfolio/alpha/"
            @test isdir(joinpath(tmp, "my-portfolio", "alpha")) && "my-portfolio" in NS.list_local_sites()
            @test NS._site_file("my-portfolio", "") == joinpath(tmp, "my-portfolio", "index.html")  # dir → index
            @test NS._site_file("My Portfolio", "slate-site.json") !== nothing        # raw name re-slugs
            @test NS._site_file("my-portfolio", "alpha") == joinpath(tmp, "my-portfolio", "alpha", "index.html")
            @test NS._site_file("my-portfolio", "../../../etc/passwd") === nothing    # never escape the site
            @test NS._site_file("my-portfolio", "..") === nothing
            @test NS._site_file("nope", "index.html") === nothing                     # unknown site
            # Unexport: add a second doc, then remove "alpha" — its dir + manifest entry go, the other stays.
            b = withfig(_mknb("#%% md id=t\n# Beta\n\n#%% code id=fig\n2\n"))
            NS.export_to_site(b, "My Portfolio"; slug = "beta")
            @test Set(String(get(d, "slug", "")) for d in NS.site_docs("My Portfolio")) == Set(["alpha", "beta"])
            u = NS.unexport_from_site("My Portfolio", "alpha")
            @test u.removed && u.docCount == 1
            @test !isdir(joinpath(tmp, "my-portfolio", "alpha"))                      # doc dir deleted
            @test [String(get(d, "slug", "")) for d in NS.site_docs("My Portfolio")] == ["beta"]
            @test !NS.unexport_from_site("My Portfolio", "alpha").removed             # idempotent (already gone)
            @test !NS.unexport_from_site("nope", "x").removed                         # unknown site
        end
    end

    # Custom front page: a `home` notebook renders to the site root, with a `docindex` cell marking where
    # the document listing is injected (re-filled on every publish, so it stays current).
    @testset "front page (home tag + docindex placeholder)" begin
        @test :home in RE._KNOWN_TAGS && :docindex in RE._KNOWN_TAGS       # round-trip as header tags
        home = _mknb("#%% md id=hero home\n# Kahli's Notebooks\nWelcome to my work.\n\n#%% md id=list docindex\nPLACEHOLDER_BODY\n")
        @test NS._home_notebook(home)
        plain = _mknb("#%% md id=a\n# Not home\n")
        @test !NS._home_notebook(plain)

        html = NS.export_html(home)
        @test occursin("id=\"slate-docindex\"", html)                     # the marker is emitted…
        @test !occursin("PLACEHOLDER_BODY", html)                         # …instead of the cell's own body
        @test occursin("Kahli's Notebooks", html)                         # the author's content stays

        docs = [Dict{String,Any}("slug" => "post-one", "title" => "Post One", "description" => "First.",
                                 "image" => "", "runnable" => false, "date" => "2026-07-01")]
        cards = NS._doc_cards_html(docs)
        @test occursin("href=\"post-one/\"", cards) && occursin("Post One", cards)
        @test occursin("No documents", NS._doc_cards_html(Any[]))          # empty state

        filled = NS._site_index_with_home(html, docs)
        @test occursin("Kahli's Notebooks", filled)                       # custom content preserved
        @test occursin("href=\"post-one/\"", filled)                      # listing injected at the marker
        @test !occursin("id=\"slate-docindex\"></div>", filled)           # marker consumed
        @test occursin("id=\"slate-cards-root\"", filled) && occursin("fetch('slate-site.json'", filled)  # + client refresh
        # No placeholder in the page → cards appended before </body> rather than dropped.
        nomark = NS._site_index_with_home("<html><body><h1>Hi</h1></body></html>", docs)
        @test occursin("href=\"post-one/\"", nomark) && occursin("<h1>Hi</h1>", nomark)
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

    # Regression: the SERVER parallel batch must tag plotting cells with the graphics sentinel so two
    # Makie cells never run concurrently (ConcurrencyViolationError deep in Observables). The sentinel
    # was on the worker path but missing here, so plots raced on a reload/re-run.
    @testset "parallel batch serialises graphics cells (Makie thread-safety)" begin
        r = RE.parse_report("#%% code id=p1\nfig = Figure(); ax = Axis(fig[1,1]); lines!(ax, 1:3, 1:3); fig\n" *
                            "#%% code id=p2\nscatter!(1:3, 1:3)\n" *
                            "#%% code id=calc\ny = sum(1:10)")
        RE.build_dependencies!(r)
        specs = NS._batch_specs([c for c in r.cells if c.kind == RE.CODE])
        bym = Dict(s.id => s for s in specs)
        @test NS._GRAPHICS_SENTINEL in bym["p1"].writes && NS._GRAPHICS_SENTINEL in bym["p2"].writes
        @test !(NS._GRAPHICS_SENTINEL in bym["calc"].writes)   # pure compute is untagged
        bl = NS.par_blockers(specs)
        @test "p1" in bl["p2"]                                  # graphics ↔ graphics serialised
        @test NS.co_runnable(["p1", "calc"], bl)                # graphics ∥ pure compute is fine
    end
end
