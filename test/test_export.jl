# Static-site export: the manifest-driven card index and its series grouping (pure render
# functions, no live hub needed).
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer

# A minimal manifest doc entry.
_doc(slug, date; series = nothing) = begin
    d = Dict{String,Any}("slug" => slug, "title" => uppercase(slug), "date" => date, "cells" => 3)
    series === nothing || (d["series"] = series)
    d
end
_pos(needle, hay) = first(findfirst(needle, hay))

@testset "site export — series grouping" begin
    @testset "_series_groups buckets & ordering" begin
        docs = [_doc("a", "2026-01-01"; series = "Optics"),
                _doc("b", "2026-03-01"; series = "Chaos"),
                _doc("c", "2026-02-01"; series = "Optics"),
                _doc("loose", "2026-04-01")]
        g = NS._series_groups(docs)
        # ungrouped bucket first, then series by newest doc desc (Chaos 03-01 > Optics 02-01)
        @test String[p.first for p in g] == ["", "Chaos", "Optics"]
        @test String[String(d["slug"]) for d in g[1].second] == ["loose"]      # ungrouped holds the loose doc
        optics = g[findfirst(p -> p.first == "Optics", g)].second
        @test String[String(d["slug"]) for d in optics] == ["c", "a"]          # within a series: newest first
    end

    @testset "no series ⇒ flat grid (back-compat)" begin
        flat = NS._cards_grid_html([_doc("x", "2026-01-01"), _doc("y", "2026-02-01")])
        @test occursin("slate-cards", flat) && !occursin("series-hd", flat)
        @test _pos("Y", flat) < _pos("X", flat)                                 # newest first
    end

    @testset "series ⇒ headings; ungrouped headingless & first" begin
        grouped = NS._cards_grid_html([_doc("a", "2026-01-01"; series = "Optics"),
                                       _doc("loose", "2026-03-01")])
        @test occursin("<h2 class=\"series-hd\">Optics</h2>", grouped)
        @test _pos("LOOSE", grouped) < _pos("series-hd", grouped)              # loose card before any heading
    end

    @testset "empty + manifest round-trip" begin
        @test occursin("No documents published", NS._cards_grid_html(Any[]))
        m = Dict{String,Any}("docs" => Any[])
        NS._upsert_doc!(m, Dict{String,Any}("slug" => "a", "title" => "A", "date" => "2026-01-01", "series" => "Optics"))
        @test String(m["docs"][1]["series"]) == "Optics"
    end

    @testset "series is wired into the footer whitelist + config panel" begin
        @test "series" in KaimonSlate.ReportEngine._CONFIG_KEYS       # persists to the .jl Slate.config footer
        it = NS._config_item("series")                                # exposed in the Notebook config panel
        @test it !== nothing && it.type === :string && it.group == "Publishing"
    end

    @testset "full index assembles grouped baked grid + refresh script" begin
        manifest = Dict{String,Any}("title" => "S", "docs" => Any[
            _doc("a", "2026-01-01"; series = "Optics"), _doc("loose", "2026-03-01")])
        html = NS._render_site_index(manifest)
        @test occursin("<h2 class=\"series-hd\">Optics</h2>", html)   # baked grouped grid
        @test occursin("id=\"slate-cards-root\"", html)              # JS mount point
        @test occursin("var buckets", html) && occursin("series-hd", html)   # the grouping refresh script is embedded
        @test _pos("LOOSE", html) < _pos("<h2 class=\"series-hd\">", html)   # ungrouped card renders before the heading
    end
end

@testset "HTML export — table formatting + interactivity" begin
    spec = Dict{String,Any}(
        "columns" => Any[
            Dict{String,Any}("name" => "Product", "type" => "string", "align" => "left", "format" => nothing),
            Dict{String,Any}("name" => "Revenue", "type" => "float", "align" => "right",
                             "format" => Dict{String,Any}("kind" => "currency", "digits" => 2, "sep" => true, "prefix" => "\$", "suffix" => "")),
            Dict{String,Any}("name" => "Margin", "type" => "float", "align" => "right",
                             "format" => Dict{String,Any}("kind" => "percent", "digits" => 1, "sep" => false, "prefix" => "", "suffix" => "")),
        ],
        "rows" => Any[Any["Widget", 45999.5, 0.324]],
        "opts" => Dict{String,Any}("nrows" => 3, "ncols" => 3),   # nrows > shown rows ⇒ truncation note
    )
    html = NS._export_table_html(spec)
    @test occursin("exp-tblwrap", html)                 # wrapper the enhancer hydrates
    @test occursin("class=\"num align-right\"", html)   # numeric column: right-aligned + tabular
    @test occursin("data-v=\"45999.5\"", html)          # raw value for numeric client-side sort
    @test occursin("\$45,999.50", html)                 # currency formatting applied server-side
    @test occursin("32.4%", html)                       # percent formatting applied
    @test occursin("Showing 1 of 3 rows", html)         # never a silent truncation

    # The self-contained enhancer is present with its controls.
    @test occursin("exp-tbl-filter", NS._EXPORT_TABLE_JS)
    @test occursin("querySelectorAll('table.exp-table')", NS._EXPORT_TABLE_JS)
end

@testset "Typst export — table align/format/zebra/repeat/truncation" begin
    spec = Dict{String,Any}(
        "columns" => Any[
            Dict{String,Any}("name" => "Product", "type" => "string", "align" => "left", "format" => nothing),
            Dict{String,Any}("name" => "Revenue", "type" => "float", "align" => "right",
                             "format" => Dict{String,Any}("kind" => "currency", "digits" => 2, "sep" => true, "prefix" => "\$", "suffix" => "")),
            Dict{String,Any}("name" => "Margin", "type" => "float", "align" => "right",
                             "format" => Dict{String,Any}("kind" => "percent", "digits" => 1, "sep" => false, "prefix" => "", "suffix" => "")),
        ],
        "rows" => Any[Any["Widget", 45999.5, 0.324]],
        "opts" => Dict{String,Any}("nrows" => 250, "ncols" => 3),   # only 1 row shipped ⇒ note vs the true total
    )
    typ = NS._typst_table(spec; theme = "light")
    @test occursin("align: (left, right, right)", typ)     # per-column alignment
    @test occursin("\$45,999.50", typ)                     # formatted currency (numbers no longer stringified)
    @test occursin("32.4%", typ)                           # formatted percent
    @test occursin("table.header(repeat: true", typ)       # header repeats across page breaks
    @test occursin("calc.odd(row)", typ)                   # zebra striping
    @test occursin("249 more rows (250 total)", typ)       # accurate truncation from opts.nrows
    @test occursin("#align(center)[", typ)                 # tables centered on the page
end

@testset "table export — in-cell viz + export_rows cap" begin
    spec = Dict{String,Any}(
        "columns" => Any[
            Dict{String,Any}("name" => "n", "type" => "int", "align" => "right", "format" => nothing,
                             "viz" => "bar", "domain" => Any[0.0, 100.0]),
            Dict{String,Any}("name" => "h", "type" => "int", "align" => "right", "format" => nothing,
                             "viz" => "heat", "domain" => Any[0.0, 100.0]),
        ],
        "rows" => Any[Any[50, 25], Any[100, 75], Any[0, 100]],
        "opts" => Dict{String,Any}("nrows" => 3, "ncols" => 2, "export_rows" => 2),
    )
    html = NS._export_table_html(spec)
    @test occursin("linear-gradient(to right,rgba(88,166,255,.20) 50.0%", html)   # :bar scaled 50/100
    @test occursin("background:rgba(88,166,255,", html)                            # :heat shade
    @test occursin("Showing 2 of 3 rows", html)                                    # export_rows cap (not silent)
    @test occursin("data-v=\"100\"", html) && !occursin("data-v=\"0\"", html)      # only the first 2 rows emitted

    typ = NS._typst_table(spec; theme = "light")
    @test occursin("table.cell(fill: gradient.linear", typ)                        # :bar per-cell gradient
    @test occursin("table.cell(fill: rgb(\"#58a6ff\").transparentize", typ)        # :heat per-cell fill
end

# Interim-render preview travelling with an EXPORT: externalized blob URLs must re-inline to
# self-contained data URIs (the blob-serving server isn't there when the .jl is reopened elsewhere),
# subject to the size caps; heavy animation manifests are dropped.
@testset "preview blob re-inline (export travel)" begin
    nbid = "previewtest_ci"
    png = vcat(UInt8[0x89, 0x50, 0x4e, 0x47], rand(UInt8, 96))     # a small figure blob in the durable store
    h = string(hash(png); base = 16)
    NS._blob_put_durable!(string(nbid, "/", h), "image/png", png)

    cells = [Dict{String,Any}("id" => "a",
                              "output" => "<img src=\"/api/$nbid/blob/$h\" width=\"12\">",
                              "animations" => Any[Dict{String,Any}("frames" => 3)])]
    NS._inline_preview_blobs!(nbid, cells)
    @test occursin("data:image/png;base64,", cells[1]["output"])  # URL → self-contained data URI
    @test !occursin("/blob/", cells[1]["output"])                 # no server-dependent URL left
    @test cells[1]["animations"] == Any[]                         # heavy frame stacks dropped from the preview

    # A total budget of 0 embeds nothing — every asset is left as a URL (recomputes on hydrate).
    cells0 = [Dict{String,Any}("id" => "z", "output" => "<img src=\"/api/$nbid/blob/$h\">")]
    NS._inline_preview_blobs!(nbid, cells0; budget = 0)
    @test occursin("/blob/$h", cells0[1]["output"])

    # The running total caps embedding: with room for exactly one asset, the first inlines and a
    # second distinct asset is left as a URL.
    png2 = vcat(UInt8[0x89, 0x50], rand(UInt8, 160)); h2 = string(hash(png2); base = 16)
    NS._blob_put_durable!(string(nbid, "/", h2), "image/png", png2)
    cells2 = [Dict{String,Any}("id" => "d",
                               "output" => "<img src=\"/api/$nbid/blob/$h\"><img src=\"/api/$nbid/blob/$h2\">")]
    NS._inline_preview_blobs!(nbid, cells2; budget = length(png))  # room for exactly the first
    @test occursin("data:image/png;base64,", cells2[1]["output"])  # first inlined
    @test occursin("/blob/$h2", cells2[1]["output"])               # second left — budget exhausted

    # A blob absent from the store is left untouched (no crash).
    cells3 = [Dict{String,Any}("id" => "e", "output" => "<img src=\"/api/$nbid/blob/deadbeef\">")]
    NS._inline_preview_blobs!(nbid, cells3)
    @test occursin("/blob/deadbeef", cells3[1]["output"])
end
