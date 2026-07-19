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

@testset "web-cell export importmap (Preact/htm/signals)" begin
    ui = NS._slate_ui_imports()
    # the bare specifiers a web-cell fragment imports, mapped to pinned-version CDN modules
    for k in ("preact", "preact/hooks", "@preact/signals", "@preact/signals-core", "htm", "htm/preact")
        @test haskey(ui, k)
        @test startswith(ui[k], "https://")
    end
    @test occursin("preact@10.24.3", ui["preact"])         # version pinned in vendor.json
    @test occursin("htm@3.1.1/preact", ui["htm/preact"])
    # rendered as a <script type="importmap"> carrying those specifiers
    tag = NS._export_importmap(ui)
    @test occursin("type=\"importmap\"", tag)
    @test occursin("htm/preact", tag) && occursin("@preact/signals", tag)
    @test isempty(NS._export_importmap(nothing))           # no imports ⇒ no tag
end

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

# A geo echart references its map by a server URL (`registerMap`). A static page has no server, so the
# export must carry the map itself — INLINE for a standalone HTML, a PAGE-LOCAL sibling file for a
# published page. Build a notebook holding one geo spec and check both modes.
const _RE = KaimonSlate.ReportEngine
# A notebook whose one code cell renders `spec` as its only echart output (no live hub needed).
_nb_with_echart(spec, id) = begin
    out = _RE.CellOutput("", _RE.MimeChunk[], Any[spec], Any[], _RE.BindSpec[], "", nothing, nothing, 1.0)
    rep = _RE.parse_report("#%% md id=t title\n# $id\n\n#%% code id=c\nechart(1)\n")
    rep.cells[end].output = out
    NS.LiveNotebook(id, "/tmp/$id.jl", rep, _RE.InProcessKernel(), 1, String[], String[],
        ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
end

@testset "geo map assets in export" begin
    _geo_spec() = Dict{String,Any}(
        "registerMap" => Dict{String,Any}("name" => "world", "url" => "/assets/maps/world.json"),
        "__size" => Dict{String,Any}("height" => 640),
        "geo" => Dict{String,Any}("map" => "world"),
        "series" => [Dict{String,Any}("type" => "scatter", "coordinateSystem" => "geo",
                     "data" => [Dict{String,Any}("name" => "ATL", "value" => [-84.4, 33.6, 12.0])])])
    _geo_nb() = _nb_with_echart(_geo_spec(), "geo")

    # Spec-level helpers: recognise the request, resolve the vendored file, rewrite to a page-local path.
    @test NS._spec_geomaps(_geo_spec()) == [("world", "/assets/maps/world.json")]
    @test NS._geo_map_file("/assets/maps/world.json") !== nothing        # vendored world map resolves
    @test NS._geo_map_file("https://cdn.example/x.json") === nothing     # external URL isn't a local asset
    @test NS._geo_asset_path("/assets/maps/world.json") == "assets/maps/world.json"

    # Standalone: the GeoJSON is INLINED (registered before setOption), no server URL is fetched, and the
    # chart div takes the spec's height rather than the 340px default.
    standalone = NS.export_html(_geo_nb(); inline_assets = true)
    @test occursin("var _slateMaps=", standalone) && occursin("\"world\":", standalone)
    @test occursin("_slateEnsureMaps", standalone)                       # registers maps before setOption
    @test occursin("height:640px", standalone)                           # honours the spec height

    # Published: no inline map (fetched instead), the `registerMap` URL is rewritten page-relative (no
    # leading slash), and the map file is written as a page-local sibling.
    published = NS.export_html(_geo_nb(); inline_assets = false)
    @test occursin("var _slateMaps={};", published)
    @test occursin("\"assets/maps/world.json\"", published) && !occursin("/assets/maps/world.json", published)

    dir = mktempdir()
    try
        @test NS._write_page_assets!(dir, _geo_nb()) == 1
        world = joinpath(dir, "assets", "maps", "world.json")
        @test isfile(world) && filesize(world) > 100_000                 # the vendored world GeoJSON landed
    finally
        rm(dir; recursive = true, force = true)
    end

    # A notebook with no geo chart writes no assets and inlines no maps.
    plain = _nb_with_echart(Dict{String,Any}("series" => [Dict{String,Any}("type" => "line", "data" => [1, 2, 3])]), "plain")
    @test NS._write_page_assets!(mktempdir(), plain) == 0
    @test occursin("var _slateMaps={}", NS.export_html(plain; inline_assets = false))
end

# `save_asset` generated blobs: stored on a cell output, then served live and inlined (standalone) or
# published as a page-local sibling — the write-side dual of `@asset`.
@testset "save_asset export + serving" begin
    # A cell output carrying one generated asset (as `_save_asset` would leave it).
    _asset_nb() = begin
        a = (; name = "airports.json", path = "data/airports-1d6b6d68.json",
               mime = "application/json", bytes = Vector{UInt8}(codeunits("{\"ATL\":[33.6,-84.4]}")))
        out = _RE.CellOutput("", _RE.MimeChunk[], Any[], Any[], _RE.BindSpec[], "", nothing, nothing, 1.0,
                             Any[], "", Any[], Any[], "", "", Any[], Any[a])
        rep = _RE.parse_report("#%% md id=t title\n# Asset\n\n#%% code id=c\nsave_asset(\"x\", d)\n")
        rep.cells[end].output = out
        NS.LiveNotebook("assetnb", "/tmp/anb.jl", rep, _RE.InProcessKernel(), 1, String[], String[],
            ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    end

    # Harvest at eval time: content-hashed page-local path, mime inference, dedup by content.
    task_local_storage(:slate_assets, Any[])
    ref = _RE._save_asset("airports.json", "{\"ATL\":[33.6,-84.4]}")
    _RE._save_asset("airports.json", "{\"ATL\":[33.6,-84.4]}")     # identical content → dedup
    _RE._save_asset("raw", UInt8[1, 2, 3]; mime = "application/octet-stream")
    aref = _RE._save_asset("Ur", Float32[1 2 3; 4 5 6])           # numeric matrix → packed binary
    dref = _RE._save_asset("cfg", Dict("a" => 1, "b" => [1, 2]))  # Dict → JSON (server-encoded)
    nref = _RE._save_asset("nt", (msg = "hi", n = 42))            # NamedTuple → JSON
    harvested = _RE._harvest_assets(task_local_storage(:slate_assets))
    delete!(task_local_storage(), :slate_assets)
    @test "$(ref)" == "data/airports-1d6b6d68.json"               # AssetRef interpolates to its path
    @test ref.mime == "application/json"
    @test length(harvested) == 5                                  # dup collapsed (6 saved → 5)
    @test any(a -> endswith(a.path, ".bin"), harvested)           # raw bytes → .bin
    # Numeric array: packed as column-major f32 with shape metadata on the ref + record.
    @test aref.dtype == "f32" && aref.shape == [2, 3] && aref.nbytes == 24 && endswith(aref.path, ".f32.bin")
    arec = only(a for a in harvested if a.path == aref.path)
    @test NS._asset_bytes(arec) == reinterpret(UInt8, Float32[1, 4, 2, 5, 3, 6])   # col-major flatten
    @test NS._asset_meta(arec)["dtype"] == "f32" && NS._asset_meta(arec)["shape"] == [2, 3]
    # Dict / NamedTuple → JSON bytes (encoded server-side).
    @test dref.mime == "application/json"
    drec = only(a for a in harvested if a.path == dref.path)
    @test occursin("\"a\":1", String(NS._asset_bytes(drec)))
    nrec = only(a for a in harvested if a.path == nref.path)
    @test occursin("\"msg\":\"hi\"", String(NS._asset_bytes(nrec)))
    # A returned AssetRef renders a summary (path + array shape + load hint).
    @test occursin("f32", sprint(show, MIME("text/plain"), aref)) && occursin("2×3", sprint(show, MIME("text/plain"), aref))

    nb = _asset_nb()
    @test length(NS._page_save_assets(nb)) == 1

    # Live serving spec: bytes go to the blob store, exposed as {path, url, mime}.
    spec = NS._asset_specs(nb.report.cells[end], "assetnb")
    @test length(spec) == 1
    @test spec[1]["path"] == "data/airports-1d6b6d68.json"
    @test spec[1]["mime"] == "application/json"
    @test occursin(r"^/api/assetnb/blob/", spec[1]["url"])

    # Standalone: the `Slate.asset` shim + the bytes inlined (base64 `data`), keyed by the path.
    std = NS.export_html(_asset_nb(); inline_assets = true)
    @test occursin("Slate.asset=function", std)
    @test occursin("\"data\":\"", std) && occursin("data/airports-1d6b6d68.json", std)

    # Published: the registry points at the page-local sibling (`url`), no inlined bytes; the file lands.
    pub = NS.export_html(_asset_nb(); inline_assets = false)
    @test occursin("\"url\":\"data/airports-1d6b6d68.json\"", pub) && !occursin("\"data\":\"", pub)
    dir = mktempdir()
    try
        @test NS._write_page_assets!(dir, _asset_nb()) == 1
        f = joinpath(dir, "data", "airports-1d6b6d68.json")
        @test isfile(f) && String(read(f)) == "{\"ATL\":[33.6,-84.4]}"
    finally
        rm(dir; recursive = true, force = true)
    end
end
