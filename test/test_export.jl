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
