# Literate.jl dialect: a `.jl` with no Slate structure reads as Literate source, one cell per chunk,
# and writes back unchanged except for the cells that were edited.

using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

const LIT = """
# # Linear regression
#
# We start by **loading** data.

using Statistics
x = rand(100)

y = 2x .+ randn(100)   #src

# The slope is:
## a code comment
β = cov(x, y) / var(x)

#-
β

# A second paragraph,
# set off by a blank line.

#md # [![badge](https://example.com/badge.svg)](https://example.com)

#=
Block prose, read verbatim:
# not a heading prefix
=#
"""

kinds_sources(r) = [(c.kind, c.source) for c in r.cells]

@testset "literate: chunks become cells" begin
    r = RE.parse_literate(LIT)
    @test RE.is_literate(r)
    @test kinds_sources(r) == [
        (RE.MARKDOWN, "# Linear regression\n\nWe start by **loading** data."),
        (RE.CODE, "using Statistics\nx = rand(100)\n\ny = 2x .+ randn(100)   #src"),
        (RE.MARKDOWN, "The slope is:"),
        (RE.CODE, "# a code comment\nβ = cov(x, y) / var(x)"),
        (RE.CODE, "β"),
        (RE.MARKDOWN, "A second paragraph,\nset off by a blank line."),
        (RE.MARKDOWN, "[![badge](https://example.com/badge.svg)](https://example.com) <!-- #md -->"),
        (RE.MARKDOWN, "Block prose, read verbatim:\n# not a heading prefix"),
    ]
    # A blank line ends a markdown chunk, as in Literate.
    @test length(RE.parse_literate("# one\n\n# two\n").cells) == 2
    # Indented markdown is still markdown; `##` alone is an empty code comment.
    @test kinds_sources(RE.parse_literate("    # note\nf()\n##\n")) == [(RE.MARKDOWN, "note"), (RE.CODE, "f()\n#")]
end

@testset "literate: a filtered markdown line stays in its markdown cell" begin
    text = "# # Title\n#\n#md # [![](badge.svg)](@__NBVIEWER_ROOT_URL__/x.ipynb)\n#nb #\n# Body. #src\n#md x = 1\n"
    r = RE.parse_literate(text)
    @test kinds_sources(r) == [
        (RE.MARKDOWN, "# Title\n\n[![](badge.svg)](@__NBVIEWER_ROOT_URL__/x.ipynb) <!-- #md -->\n<!-- #nb -->\nBody. <!-- #src -->"),
        (RE.CODE, "#md x = 1"),
    ]
    @test first(RE.render_literate(r)) == text
    # An edited cell writes each filter in front of its line.
    r.cells[1].source = "Intro\n[badge] <!-- #md -->\nEnd <!-- #!nb -->"
    @test startswith(first(RE.render_literate(r)), "# Intro\n#md # [badge]\n#!nb # End\n")
end

@testset "literate: detection" begin
    @test RE.is_literate_source(LIT)
    @test RE.is_literate_source("x = 1\n")
    @test !RE.is_literate_source("")
    @test !RE.is_literate_source("\n  \n")
    @test !RE.is_literate_source("#%% code id=a\nx = 1\n")
    @test !RE.is_literate_source(RE._PREAMBLE * "\n")                       # a Slate notebook with no cells
    @test RE.is_literate_source(RE._PREAMBLE * " #hide\n# # Title\nx = 1\n")  # preamble in a Literate file
    @test !RE.is_literate_source("x = 1\n# ╔═╡ Slate.config\n# ╚═╡\n")
    @test RE.is_literate(RE.read_notebook_source(LIT))
    @test !RE.is_literate(RE.read_notebook_source("#%% code id=a\nx = 1\n"))
end

@testset "literate: an unedited notebook writes back byte for byte" begin
    for text in (LIT, rstrip(LIT), replace(LIT, "\n" => "\r\n"), "\n\n" * LIT * "\n\n",
                 "#!/usr/bin/env julia\n# hi\nx = 1\n#+\ny = 2\n")
        @test first(RE.render_literate(RE.parse_literate(text))) == text
    end
end

@testset "literate: an edit rewrites only that cell" begin
    r = RE.parse_literate(LIT)
    r.cells[3].source = "The slope, estimated:"
    r.cells[5].source = "# show it\nβ"
    text, _ = RE.render_literate(r)
    @test text == replace(LIT, "# The slope is:" => "# The slope, estimated:", "#-\nβ" => "#-\n## show it\nβ")
    # What was written reads back as the same cells.
    @test kinds_sources(RE.parse_literate(text)) == kinds_sources(r)
end

@testset "literate: new, moved and deleted cells" begin
    r = RE.parse_literate("# Intro\n\nx = 1\n\n# Outro\n")
    push!(r.cells, RE.Cell("new1", RE.CODE, "y = 2"))
    insert!(r.cells, 3, RE.Cell("new2", RE.CODE, "z = 3"))         # code after code needs a `#-`
    text, doc = RE.render_literate(r)
    @test text == "# Intro\n\nx = 1\n\n#-\n\nz = 3\n\n# Outro\n\ny = 2\n"
    @test kinds_sources(RE.parse_literate(text)) == kinds_sources(r)
    @test Set(keys(doc.spans)) == Set(c.id for c in r.cells)        # the next save knows every cell
    # Delete the middle code cell; an empty cell is left out of the file.
    r.meta["literate"] = doc
    deleteat!(r.cells, 3)
    push!(r.cells, RE.Cell("empty", RE.MARKDOWN, "  \n"))
    @test first(RE.render_literate(r)) == "# Intro\n\nx = 1\n\n# Outro\n\ny = 2\n"
end

@testset "literate: what a Literate file can't hold" begin
    r = RE.parse_literate("x = 1\n")
    push!(r.cells, RE.Cell("w", RE.WEB, "<b>hi</b>"))
    @test_throws RE.LiterateUnsupported RE.render_literate(r)
    r = RE.parse_literate("x = 1\n")
    r.cells[1].source = "x = 1\n#- not a break"
    @test_throws RE.LiterateUnsupported RE.render_literate(r)
    # Tags and controls stay in the session; the file is unchanged.
    r = RE.parse_literate("x = 1\n")
    push!(r.cells[1].flags, :collapsed)
    r.cells[1].controls = [["x"]]
    @test first(RE.render_literate(r)) == "x = 1\n"
end

@testset "literate: an external edit keeps the ids of unchanged cells" begin
    old = RE.parse_literate(LIT)
    old.cells[2].id = "session2"                  # ids a session assigned or kept
    old.cells[4].id = "session4"
    edited = replace(LIT, "# The slope is:" => "# The slope:", "#-\nβ" => "#-\nβ + 1")
    new = RE.parse_literate(edited)
    RE.adopt_literate_ids!(new, old)
    @test new.cells[2].id == "session2"
    @test new.cells[4].id == "session4"
    @test new.cells[1].id == old.cells[1].id
    @test new.cells[3].id != old.cells[3].id      # edited: a new cell
    @test allunique(c.id for c in new.cells)
    @test Set(keys(new.meta["literate"].spans)) == Set(c.id for c in new.cells)
    # The adopted layout writes the external text back unchanged.
    @test first(RE.render_literate(new)) == edited
end

@testset "literate: a live notebook saves in place and keeps its path identity" begin
    NS = KaimonSlate.NotebookServer
    p = joinpath(mktempdir(), "lit.jl"); write(p, LIT)
    nb = NS.LiveNotebook("lit", p, RE.read_notebook_source(LIT), RE.InProcessKernel(), 1, String[], String[],
        ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    nb.report.cells[3].source = "The slope, estimated:"
    NS._persist!(nb; source = "agent")
    @test read(p, String) == replace(LIT, "# The slope is:" => "# The slope, estimated:")
    sleep(NS._SETTLE_S + 0.05)
    @test !NS.sync_from_file!(nb)                                  # its own write is not an edit
    # A cell the file can't hold: nothing is written, and the notebook says why.
    before = read(p, String)
    push!(nb.report.cells, RE.Cell("w", RE.WEB, "<b>hi</b>"))
    NS._persist!(nb)
    @test read(p, String) == before
    @test occursin("web cell", get(nb.report.meta, "literate_unsaved", ""))
    pop!(nb.report.cells)
    NS._persist!(nb)
    @test !haskey(nb.report.meta, "literate_unsaved")
    # No id is minted for a file that can't carry one.
    @test NS._ensure_docid!(nb) == NS.doc_key(nb)
    @test !haskey(nb.report.meta, "docid")
end

@testset "literate: converting moves the history to the Slate notebook" begin
    NS = KaimonSlate.NotebookServer
    SHist = NS.SlateHistory
    p = joinpath(mktempdir(), "lit.jl"); write(p, LIT)
    nb = NS.LiveNotebook("lit", p, RE.read_notebook_source(LIT), RE.InProcessKernel(), 1, String[], String[],
        ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    h = NS.Hub(Dict("lit" => nb), nothing, "127.0.0.1", 0, ReentrantLock(), false, false, Dict{String,Any}())
    nb.report.cells[3].source = "The slope, estimated:"
    NS._persist!(nb)
    before = NS.nbdoc(nb)
    @test isdir(SHist._dir(before))
    out = NS.convert_literate!(h, nb)
    @test read(p, String) == replace(LIT, "# The slope is:" => "# The slope, estimated:")   # the Literate file stays
    newr = RE.read_notebook_source(read(out, String))
    @test !RE.is_literate(newr)
    @test [c.source for c in newr.cells] == [c.source for c in nb.report.cells]
    docid = get(newr.meta, "docid", "")
    @test !isempty(docid) && !haskey(nb.report.meta, "docid")
    after = SHist.Doc(NS.doc_key(out, newr.meta), out)
    @test isdir(SHist._dir(after)) && !isdir(SHist._dir(before))
    @test SHist.known_paths(after) == [abspath(out)]
    @test !haskey(h.notebooks, "lit")                               # the Literate session closed
end

@testset "literate: filtered lines and placeholder links render marked" begin
    md(src) = KaimonSlate.markdown_html(src)
    h = md("[![](b.svg)](@__NBVIEWER_ROOT_URL__/x.ipynb) <!-- #md -->\n\nBody.")
    @test occursin("<p><span class=\"litonly\"><span class=\"litph\" title=\"@__NBVIEWER_ROOT_URL__/x.ipynb\"><img", h)
    @test occursin("<span class=\"litout\">docs</span></p>", h)
    @test !occursin("<a href", h) && !occursin("<!--", h)
    # A line the notebook output keeps is tagged but not dimmed.
    h = md("one\nnotebook line <!-- #nb -->\nthree")
    @test occursin("notebook line <span class=\"litout\">notebook</span>", h) && !occursin("litonly", h)
    @test occursin("<li><span class=\"litonly\">item</span> <span class=\"litout\">docs · script</span></li>", md("- item <!-- #!nb -->"))
    @test !occursin("litout", md("text\n<!-- #md -->\n"))            # a filtered blank line shows nothing
    @test occursin("<a href=\"https://example.com\">", md("[x](https://example.com)"))
end
