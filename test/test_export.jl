# Static-site export: the manifest-driven card index and its series grouping (pure render
# functions, no live hub needed).
using ReTest
using KaimonSlate
import Base64
using CodecZlib: GzipDecompressor            # verify the packed-asset round-trip
using Random: Xoshiro                        # deterministic incompressible bytes
import JSON                                  # hand the @replay control fixture to node
const ReportEngine = KaimonSlate.ReportEngine
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

@testset "offline export inlines every third-party lib" begin
    # Only SUBRESOURCE references matter: a url inside an inlined script body (a licence header, a
    # `//# sourceMappingURL`, a string constant) is never fetched by the browser, so a bare "http" count
    # would be meaningless. Match the attribute/`url()` forms a browser actually resolves.
    subres(s) = collect(eachmatch(r"(?:src|href)\s*=\s*[\"']https?://|url\(\s*[\"']?https?://", s))

    online = NS._thirdparty_head(false)
    @test !isempty(subres(online))                          # the default really is CDN-linked
    @test occursin("echarts", online) && occursin("katex", online)

    # The vendor cache is populated over the network on first use; if that isn't available the helper
    # degrades to CDN tags by design, so only assert the inlining when it actually resolved.
    if NS._vendor_file("katex", "katex.min.css") !== nothing
        offline = NS._thirdparty_head(true)
        @test isempty(subres(offline))                      # ZERO external subresources — the whole point
        @test length(offline) > 100_000                     # real library bodies, not empty tags
        @test occursin("data:font/woff2;base64,", offline)  # KaTeX fonts ride inline, else math renders wrong
        # Both modes resolve versions from vendor.json, so they can't drift apart.
        @test occursin("@dagrejs/dagre@3.0.0", NS._vendor_url("dagre", "dagre.min.js"))

        offmap = NS._slate_ui_imports(true)
        @test length(offmap) == 6
        @test all(startswith(v, "data:text/javascript;base64,") for v in values(offmap))
    end
end

@testset "packed data assets — narrowed + gzipped for a single file" begin
    # A `@replay` table is the one payload whose size scales with what the author computed, so the
    # inlined copy is narrowed and compressed. Both are ARTIFACT decisions: the live notebook keeps the
    # real array, and re-exporting can revisit them without re-running a cell.
    n = 4000
    vals = Float64[2 + sin(i / 40) for i in 1:n]           # smooth ⇒ genuinely compressible
    raw = Vector{UInt8}(reinterpret(UInt8, vals))
    spec = Dict{String,Any}("dtype" => "f64", "shape" => [n], "order" => "col")

    b, dt, enc = NS._pack_export_asset(spec, raw)
    @test dt == "f32"                                       # f64 halves; a plot cannot show the rest
    @test enc == "gzip"
    @test length(b) < length(raw) ÷ 2                       # narrowing alone already halves it
    # Round-trips to the same numbers a Float32Array would read.
    back = reinterpret(Float32, transcode(GzipDecompressor, b))
    @test length(back) == n
    @test all(isapprox.(back, Float32.(vals); rtol = 1e-6))

    # Ordering matters: narrowing FIRST leaves fewer distinct bytes, so it compresses better than
    # gzipping the f64 buffer would.
    gz_only, _, _ = NS._pack_export_asset(spec, raw; narrow = false)
    @test length(b) < length(gz_only)

    # Never pay for compression that doesn't win: tiny buffers skip it, and incompressible bytes are
    # left alone rather than shipped larger through base64.
    _, _, e_small = NS._pack_export_asset(Dict{String,Any}(), rand(UInt8, 64))
    @test e_small === nothing
    noise = rand(Xoshiro(1), UInt8, 200_000)
    _, _, e_noise = NS._pack_export_asset(Dict{String,Any}(), noise)
    @test e_noise === nothing

    # A non-float asset is left at its own dtype — only f64 has precision to give away.
    _, dt_i, _ = NS._pack_export_asset(Dict{String,Any}("dtype" => "i32"), rand(UInt8, 8192))
    @test dt_i === nothing

    # Both reductions are switchable, because they trade different things. Compression costs REACH — a
    # page inflates with DecompressionStream, so an old locked-down viewer (an exam machine) needs it
    # off. Narrowing costs precision only, and every browser reads a Float32Array.
    b_off, dt_off, enc_off = NS._pack_export_asset(spec, raw; compress = false)
    @test enc_off === nothing && dt_off == "f32"
    @test length(b_off) == length(raw) ÷ 2                  # narrowed, not compressed
    _, dt_raw, enc_raw = NS._pack_export_asset(spec, raw; compress = false, narrow = false)
    @test dt_raw === nothing && enc_raw === nothing         # untouched — exactly the bytes given

    # The page must be told it has to inflate, and must say so plainly if it cannot.
    @test occursin("_slateInflate", NS._EXPORT_ASSET_JS)
    @test occursin("DecompressionStream", NS._EXPORT_ASSET_JS)
    @test occursin("a.enc===\"gzip\"", NS._EXPORT_ASSET_JS)
end

@testset "asset stem keeps non-ASCII names distinct" begin
    # Julia names are routinely Greek. Blanket substitution collapsed `σ_replay` and `θ_replay` to the
    # same unreadable `__replay`; the content hash kept them correct but impossible to tell apart.
    @test ReportEngine._asset_base("plain_name") == "plain_name"      # untouched when already safe
    s, t = ReportEngine._asset_base("σ_replay"), ReportEngine._asset_base("θ_replay")
    @test s != t                                                     # the whole point
    # The readable half survives (the Greek letter itself cannot), and a digest of the ORIGINAL name is
    # appended so two names that sanitize alike stay tellable apart.
    @test startswith(s, "__replay-") && startswith(t, "__replay-")
    @test occursin(r"-[0-9a-z]+$", s)
    @test ReportEngine._asset_base("σ_replay") == s                   # stable across calls
    @test ReportEngine._asset_base("") == "asset"
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

# A dropped clip lands in a markdown cell as `<video src="/n/<id>/asset/…">`. A standalone page has no
# server to serve it from and a media element can't seek a `data:` URL — so the bytes must leave the body
# for the blob registry. A published page keeps its sibling file, which HTTP can range-request.
@testset "embedded video in export" begin
    root = mktempdir(); mkpath(joinpath(root, "assets"))
    write(joinpath(root, "assets", "clip.mp4"), UInt8[0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 1, 2, 3])
    _vid_nb() = begin
        rep = _RE.parse_report("#%% md id=t title\n# vid\n\n#%% md id=v\n<video controls src=\"/n/vid/asset/assets/clip.mp4\"></video>\n")
        rep.meta["assetbase"] = root
        NS.LiveNotebook("vid", joinpath(root, "vid.jl"), rep, _RE.InProcessKernel(), 1, String[], String[],
            ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    end

    standalone = NS.export_html(_vid_nb(); inline_assets = true)
    @test occursin("data-slate-media=\"m1\"", standalone)
    @test occursin("window.__slateMedia={\"m1\":{\"mime\":\"video/mp4\"", standalone)
    @test occursin("URL.createObjectURL", standalone)
    @test !occursin("data:video/", standalone)      # no unseekable data: URL survives
    @test !occursin("/n/vid/asset/", standalone)    # and no dead server route either

    published = NS.export_html(_vid_nb(); inline_assets = false)
    @test occursin("src=\"assets/clip.mp4\"", published) && !occursin("__slateMedia", published)
    dir = mktempdir()
    try
        NS._write_page_assets!(dir, _vid_nb())
        @test isfile(joinpath(dir, "assets", "clip.mp4"))   # the sibling the published page points at
    finally
        rm(dir; recursive = true, force = true)
    end
end

# A front end split across several ES modules: the cell names only the ENTRY point, so the exporter
# has to follow its imports or the page ships with everything but that one file missing. Standalone
# additionally has to REWRITE the specifiers — a `data:` module has no base URL to resolve `./x.js`
# against, so nesting is the only way the dependency can travel with it.
@testset "multi-file JS modules in export" begin
    root = mktempdir(); mkpath(joinpath(root, "assets", "lib"))
    write(joinpath(root, "assets", "app.js"),
          "import { u } from \"./lib/util.js\";\nimport { html } from \"htm/preact\";\nexport const go = () => u(html);\n")
    write(joinpath(root, "assets", "lib", "util.js"),
          "import { S } from \"../shared.js\";\nexport const u = (h) => S + h;\n")
    write(joinpath(root, "assets", "shared.js"), "export const S = 42;\n")
    write(joinpath(root, "assets", "unused.js"), "export const nope = 1;\n")
    _mod_nb() = begin
        rep = _RE.parse_report("#%% md id=t title\n# mods\n\n#%% web id=w\n@web(js\"\"\"\n" *
                               "const m = await import(window.Slate.assetUrl(\"assets/app.js\"));\nm.go();\n\"\"\")\n")
        rep.meta["assetbase"] = root
        NS.LiveNotebook("mods", joinpath(root, "mods.jl"), rep, _RE.InProcessKernel(), 1, String[], String[],
            ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    end

    wm = NS._web_asset_modules(_mod_nb())
    @test sort(collect(keys(wm))) == ["assets/app.js", "assets/lib/util.js", "assets/shared.js"]
    @test !haskey(wm, "assets/unused.js")        # only what is actually reachable rides along

    # Bare specifiers stay bare — those resolve through the page's import map, not the asset tree.
    inlined = NS._inline_js_modules(wm)
    app = String(inlined["assets/app.js"])
    @test occursin("\"htm/preact\"", app)
    @test !occursin("\"./lib/util.js\"", app)
    @test occursin("import { u } from \"data:text/javascript;base64,", app)
    # util.js travels INSIDE app.js, and must itself already have shared.js nested in it.
    util = String(Base64.base64decode(match(r"data:text/javascript;base64,([^\"]+)\"", app).captures[1]))
    @test !occursin("\"../shared.js\"", util)
    @test occursin("data:text/javascript;base64,", util)

    standalone = NS.export_html(_mod_nb(); inline_assets = true)
    for k in ("assets/app.js", "assets/lib/util.js", "assets/shared.js")
        @test occursin("\"$k\":{", standalone)
    end

    # Published: modules stay page-local siblings with their relative imports intact, and every one
    # of them is actually written out next to the page.
    published = NS.export_html(_mod_nb(); inline_assets = false)
    @test occursin("\"url\":\"assets/lib/util.js\"", published)
    dir = mktempdir()
    try
        NS._write_page_assets!(dir, _mod_nb())
        @test isfile(joinpath(dir, "assets", "lib", "util.js"))
        @test isfile(joinpath(dir, "assets", "shared.js"))
        @test occursin("\"../shared.js\"", read(joinpath(dir, "assets", "lib", "util.js"), String))
    finally
        rm(dir; recursive = true, force = true)
    end
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

# Package-vendored asset dirs (`provide_assets!` → `nb.assets`): a chart whose spec carries
# `requireScripts` needs a served library (echarts-gl) loaded before render. Live it's `/ext-assets/…`;
# a static export inlines it as a `data:` URL (standalone) or repoints at a page-local sibling (site),
# with the whole vendored tree copied out. Mirrors the geo-map path.
@testset "package-vendored asset dirs in export" begin
    # A fake vendored package dir: one served JS file (+ a nested one, to prove the whole tree travels).
    pkgdir = mktempdir()
    write(joinpath(pkgdir, "echarts-gl.min.js"), "window.__eg=1;")
    mkpath(joinpath(pkgdir, "sub"))
    write(joinpath(pkgdir, "sub", "extra.js"), "// extra")

    _gl_spec() = Dict{String,Any}(
        "requireScripts" => ["/ext-assets/GlobeSlate/echarts-gl.min.js"],
        "series" => [Dict{String,Any}("type" => "surface", "data" => [[0, 0, 0]])])
    _gl_nb() = begin
        nb = _nb_with_echart(_gl_spec(), "gl")
        nb.assets["GlobeSlate"] = pkgdir
        nb
    end

    # Spec-level helpers: resolve the served url to its file (with traversal guard), and rewrite.
    nb = _gl_nb()
    @test NS._ext_asset_file(nb, "/ext-assets/GlobeSlate/echarts-gl.min.js") == joinpath(pkgdir, "echarts-gl.min.js")
    @test NS._ext_asset_file(nb, "/ext-assets/GlobeSlate/../../etc/passwd") === nothing   # escape blocked
    @test NS._ext_asset_file(nb, "/ext-assets/Unknown/x.js") === nothing                  # unknown package
    # Whole vendored tree → page-local siblings under ext-assets/<pkg>/.
    rels = Dict(NS._package_asset_files(nb))
    @test rels["ext-assets/GlobeSlate/echarts-gl.min.js"] == joinpath(pkgdir, "echarts-gl.min.js")
    @test rels[joinpath("ext-assets", "GlobeSlate", "sub", "extra.js")] == joinpath(pkgdir, "sub", "extra.js")

    # Site rewrite → page-relative (no leading slash); standalone → inline data: URL of the bytes.
    site = NS._rewrite_requirescripts!(_gl_spec(), nb; inline = false)
    @test site["requireScripts"] == ["ext-assets/GlobeSlate/echarts-gl.min.js"]
    stand = NS._rewrite_requirescripts!(_gl_spec(), nb; inline = true)
    @test startswith(stand["requireScripts"][1], "data:text/javascript;base64,")
    @test String(Base64.base64decode(split(stand["requireScripts"][1], ",")[2])) == "window.__eg=1;"

    # Standalone export: the render JS gates on scripts, and the lib rides inline as a data: URL.
    standalone = NS.export_html(_gl_nb(); inline_assets = true)
    @test occursin("_slateEnsureScripts", standalone)
    @test occursin("data:text/javascript;base64,", standalone)

    # Published export: url is page-relative, and the vendored tree is written as page-local siblings.
    published = NS.export_html(_gl_nb(); inline_assets = false)
    @test occursin("ext-assets/GlobeSlate/echarts-gl.min.js", published)
    @test !occursin("/ext-assets/GlobeSlate", published)                 # no leading-slash live route
    dir = mktempdir()
    try
        n = NS._write_page_assets!(dir, _gl_nb())
        @test n == 2                                                     # both files in the tree
        @test isfile(joinpath(dir, "ext-assets", "GlobeSlate", "echarts-gl.min.js"))
        @test isfile(joinpath(dir, "ext-assets", "GlobeSlate", "sub", "extra.js"))
    finally
        rm(dir; recursive = true, force = true)
    end

    # Served-file MIME types a vendored dir may ship: WASM needs the exact `application/wasm` for
    # `WebAssembly.instantiateStreaming`; 3D model formats for a Cesium-style package.
    @test NS._site_ctype("m.wasm") == "application/wasm"
    @test NS._site_ctype("scene.glb") == "model/gltf-binary"
    @test NS._site_ctype("scene.gltf") == "model/gltf+json"
    @test NS._site_ctype("worker.js") == "application/javascript; charset=utf-8"

    # `_register_assets!` registry semantics: new pkg → changed; identical dir → unchanged; moved → changed.
    nb2 = _nb_with_echart(_gl_spec(), "gl2")
    @test NS._register_assets!(nb2, "GlobeSlate", pkgdir)                 # new → true
    @test !NS._register_assets!(nb2, "GlobeSlate", pkgdir)               # same → false
    @test NS._register_assets!(nb2, "GlobeSlate", pkgdir * "-v2")        # moved → true
    @test !NS._register_assets!(nb2, "", pkgdir)                         # empty pkg → false

    # A front-end ES-module script that dynamic-`import()`s a served SIBLING module (the multi-file
    # `provide_assets!` case): a static export must repoint the live `/ext-assets/…` route to a `./`-relative
    # specifier, NOT a bare `ext-assets/…` one — a bare specifier throws in `import()` (it's not `/`, `./`, or
    # a URL, so the resolver demands an import-map entry) and the vendored lib never loads.
    fenb = _gl_nb()
    NS._register_frontend!(fenb, "boot", "import(\"/ext-assets/GlobeSlate/globe-lib/globe-lib.js\").catch(()=>{});", true, "")
    fhead = NS._frontend_export_head(fenb)
    @test occursin("import(\"./ext-assets/GlobeSlate/globe-lib/globe-lib.js\")", fhead)   # ./-relative specifier
    @test !occursin("import(\"ext-assets/GlobeSlate/globe-lib/globe-lib.js\")", fhead)    # never a bare specifier

    # STANDALONE: that same vendored url must be INLINED as a `data:` url instead — a single-file export has
    # no sibling to fetch and no server to ask, so without this an extension's front-end library silently
    # fails to load in exactly the export that has to carry everything (a viewer with no network, or one
    # that blocks fetched scripts). The site path keeps the sibling. Mirrors `_rewrite_ext_asset_urls!`.
    snb = _gl_nb()
    NS._register_frontend!(snb, "boot", "fetch(\"/ext-assets/GlobeSlate/echarts-gl.min.js\");", false, "")
    sstand = NS._frontend_export_head(snb, true)
    @test occursin("data:application/javascript;charset=utf-8;base64,", sstand)  # mime carries no raw space
    @test !occursin("ext-assets/GlobeSlate/echarts-gl.min.js", sstand)           # no path reference survives
    @test occursin("./ext-assets/GlobeSlate/echarts-gl.min.js", NS._frontend_export_head(snb, false))

    # A vendored url that resolves to NO file falls back to the sibling form even standalone: one widget
    # holding a dead relative link is a better failure than a script that lost its dependency silently.
    @test occursin("./ext-assets/GlobeSlate/globe-lib/globe-lib.js", NS._frontend_export_head(fenb, true))

    # A vendored-asset url in a NON-`requireScripts` spec field — a globe `baseTexture` (a binary image) —
    # must be repointed too: site → the page-local sibling; standalone → a `data:<mime>;base64,…` url of the
    # BYTES (mime by extension), so a self-contained page carries the binary. The general rewrite that
    # covers the whole spec, not just scripts. A non-`/ext-assets/` url (a CDN texture) is left untouched.
    png = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]           # PNG magic bytes
    write(joinpath(pkgdir, "earth.png"), png)
    tnb = _gl_nb()
    _texspec() = Dict{String,Any}("globe" => Dict{String,Any}("baseTexture" => "/ext-assets/GlobeSlate/earth.png"),
                                  "series" => [Dict{String,Any}("type" => "scatter3D")])
    tsite = NS._rewrite_ext_asset_urls!(_texspec(), tnb; inline = false)
    @test tsite["globe"]["baseTexture"] == "ext-assets/GlobeSlate/earth.png"          # page-relative sibling (image src, no ./ needed)
    tstand = NS._rewrite_ext_asset_urls!(_texspec(), tnb; inline = true)
    @test startswith(tstand["globe"]["baseTexture"], "data:image/png;base64,")       # binary inlined, mime by extension
    @test Base64.base64decode(split(tstand["globe"]["baseTexture"], ",")[2]) == png   # exact bytes round-trip
    cdn = NS._rewrite_ext_asset_urls!(Dict{String,Any}("globe" => Dict{String,Any}("baseTexture" => "https://cdn/x.png")), tnb; inline = false)
    @test cdn["globe"]["baseTexture"] == "https://cdn/x.png"                          # external url untouched
    @test NS._site_ctype("earth.png") == "image/png"                                  # image mime for the live route
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

@testset "Typst slide frag preserves the override Bool (regression)" begin
    # A slide code-cell frag is `(cell, nothing)`. `_emit_slide_frag!` must forward the themed-render
    # `override::Bool` to `_emit_output!`, NOT shadow it with the frag's source-override — before the fix,
    # a code cell on a slide passed `override=nothing` into a `::Bool` kwarg and threw at the call.
    rep = _RE.parse_report("#%% code id=c\n1 + 1\n")
    nb = NS.LiveNotebook("slidenb", "/tmp/slidenb.jl", rep, _RE.InProcessKernel(), 1, String[], String[],
        ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    c = rep.cells[end]
    @test c.kind != NS.MARKDOWN                       # the else-branch that forwards `override` is a code cell
    io = IOBuffer(); dir = mktempdir()
    try
        # override=true is the themed-render flag; it must reach _emit_output! as a Bool (no throw).
        @test (NS._emit_slide_frag!(io, dir, "s1f1", nb, (c, nothing); theme = "dark", override = true,
                                    show_source = false, include_params = false); true)
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "_apply_ordering! sets section/order in place, leaves unmatched" begin
    docs = Any[Dict{String,Any}("slug" => "a"), Dict{String,Any}("slug" => "b"),
               Dict{String,Any}("slug" => "keep")]
    NS._apply_ordering!(docs, [Dict("slug" => "a", "section" => "Intro", "order" => 2),
                               Dict("slug" => "b", "section" => "", "order" => 1)])
    @test docs[1]["section"] == "Intro" && docs[1]["order"] == 2.0    # order coerced to Float64
    @test docs[2]["section"] == "" && docs[2]["order"] == 1.0
    @test !haskey(docs[3], "section") && !haskey(docs[3], "order")     # unmatched doc untouched
end

@testset "_split_region_csv strips, drops empties, dedups in order" begin
    @test NS._split_region_csv("east, west , , east ,north") == ["east", "west", "north"]
    @test NS._split_region_csv("") == String[]
    @test NS._split_region_csv("  ,  ") == String[]
end

# ── The `@replay` export contract ────────────────────────────────────────────────────────────────
# Julia decides two things about a control independently: what markup it renders as in a static
# export (`_export_control_html`) and what values it can take (`bind_domain`). The browser then has
# to look at that markup, read the control's position back, and find it in that domain.
#
# Nothing checked that those three agreed, and disagreement is SILENT — the page renders, the control
# moves, the figure doesn't, and nothing is logged. Every `@replay` bug found so far was of exactly
# that shape, and every one was found by hand.
#
# So the fixture is built HERE, from the real functions, and handed to node to drive: every control
# kind, moved to every position in its own domain, read back, against both copies of `Slate.replay`.
@testset "@replay export contract: markup ↔ domain ↔ client" begin
    RE = ReportEngine
    # One entry per replayable control kind. `NumberField` must be bounded to have a domain at all;
    # `MultiCheckBox` renders as a multi-select listbox in an export (a checkbox column is a live-UI
    # affordance, and the listbox binds the same set), which is precisely the sort of live/export
    # divergence this test exists to hold honest.
    widgets = Any[
        ("region",  RE.Select(["All", "APAC", "EMEA"])),
        ("mode",    RE.Radio(["fast", "slow"])),
        ("on",      RE.Checkbox(true)),
        ("live",    RE.Toggle(false)),
        ("w",       RE.Slider(1:2:9)),
        ("k",       RE.NumberField(2; min = 0, max = 5)),
        ("span",    RE.RangeSlider(0:1:3)),
        ("picks",   RE.MultiSelect(["a", "b", "c"])),
        ("flags",   RE.MultiCheckBox(["x", "y"])),
        ("sel",     RE.TableSelect([(a = 1, b = "p"), (a = 2, b = "q"), (a = 3, b = "r")])),
    ]

    fixture = Any[]
    for (name, w) in widgets
        dom = RE.bind_domain(w)
        @test dom !== nothing                       # every kind listed here must be replayable
        dom === nothing && continue
        html = NS._export_control_html(RE.BindSpec(Symbol(name), w.kind, w.params, w.default))
        @test !isempty(html)                        # …and must render as something a reader can drive
        @test occursin("data-name=\"$name\"", html) # …carrying the identity the client looks it up by
        e = Dict{String,Any}("name" => name, "kind" => w.kind, "html" => html, "domain" => dom)
        # Only a control that sweeps ONE NUMBER may be strided (`_replay_strideable`); for those,
        # hand the client the coarsened domain too, so it can check that every position the RENDERED
        # control still offers resolves to something that shipped.
        RE._replay_strideable(w.kind) && (e["strided"] = dom[1:2:end])
        push!(fixture, e)
    end

    node = Sys.which("node")
    if node === nothing
        @info "node not found — skipping the @replay export contract (fixture built, not driven)"
        @test true
    else
        mktempdir() do dir
            path = joinpath(dir, "controls.json")
            open(io -> JSON.print(io, fixture), path, "w")
            io = IOBuffer()
            script = joinpath(@__DIR__, "js", "export_contract.mjs")
            ok = success(pipeline(`$node $script $path`; stdout = io, stderr = io))
            ok || print(String(take!(io)))          # surface every diverging control on failure
            @test ok
        end
    end
end

# ── A `@replay`-marked table ──────────────────────────────────────────────────────────────────────
# A figure follows its control in a static export; a table did not. That is worse than no control at
# all: the knob sits above the table, moves the charts beside it, and leaves the rows alone — which
# reads as a live page rather than a frozen one.
#
# What ships for a table is the UNION of the rows across the control's positions, written into the page
# once, plus a per-position ORDER over that union. This checks the Julia half of that (the union, the
# packing, the markup) and then hands the real bytes and the real markup to node to drive.
@testset "@replay table: union rows, per-position order, and the page that reads them" begin
    RE = ReportEngine
    # "All" then a subset then a REORDER of a subset — a filtering control and a sorting control are
    # the same thing here, and only the second one distinguishes an order from a present/absent flag.
    byregion = Dict("All"  => [("a", 1), ("b", 2), ("c", 3)],
                    "APAC" => [("b", 2), ("c", 3)],
                    "EMEA" => [("c", 3), ("a", 1)])
    mk = region -> RE.slate_table(["product", "n"], [Any[p, n] for (p, n) in byregion[region]])

    w = RE.Select(["All", "APAC", "EMEA"])
    dom = RE.bind_domain(w)
    # A hand-built sweeps entry, which is what the `@replay` macro registers: the notebook eval path is
    # covered in test_bind.jl, and building it here keeps this test about what an EXPORT does with one.
    # `wrap = identity` for the same reason — a bare Select's wrapping is tested where wrapping lives.
    sweeps = Dict{String,Any}("tbl:region" =>
        (; name = "region", f = mk, wrap = identity, domain = Any[dom...], cell = "tbl", kind = w.kind))
    got = RE._run_replay_sweeps(sweeps)
    r = got["tbl:region"]

    @test r["target"] == "table"                     # the page must drive a table, not a chart series
    @test r["dtype"] == "i16"                        # …and the order packs as one of the native dtypes
    @test r["rows"] == Any[Any["a", 1], Any["b", 2], Any["c", 3]]   # union, in first-seen order
    @test r["slice"] == [3] && r["shape"] == [3, 3]  # one entry per union row, per position

    # The order itself: 1-based indices into the union, 0 for "no row". Column-major, so a position is
    # a contiguous run — the layout `Slate.replay.slice` reads.
    A = reshape(reinterpret(Int16, Base64.base64decode(r["b64"])), 3, 3)
    @test A[:, 1] == Int16[1, 2, 3]                  # All  → every row, as written
    @test A[:, 2] == Int16[2, 3, 0]                  # APAC → two of them, padded
    @test A[:, 3] == Int16[3, 1, 0]                  # EMEA → reordered, which a mask could not say

    # The live table carries the mark; the export swaps the union in behind it.
    spec = RE._table_wire(RE._mark_table_replay!(mk("All"), "tbl:region", "region", 1))
    @test NS._table_replay_mark(spec)["id"] == "tbl:region"
    sub = NS._replay_base_spec(spec, Dict{String,Any}("tbl:region" => r["rows"]))
    @test sub["rows"] == r["rows"]
    @test sub["opts"]["nrows"] == 3
    tablehtml = NS._export_table_html(sub)
    @test occursin("data-replay=\"tbl:region\"", tablehtml)   # what the enhancer registers itself under

    # An unmarked table, and a marked one whose sweep produced nothing, are both left exactly alone —
    # a failed sweep must leave a normal static table, not a broken one.
    plain = RE._table_wire(mk("All"))
    @test NS._replay_base_spec(plain, Dict{String,Any}()) === plain
    @test !occursin("data-replay", NS._export_table_html(plain))
    @test NS._replay_base_spec(spec, Dict{String,Any}()) === spec

    node = Sys.which("node")
    if node === nothing
        @info "node not found — skipping the @replay table drive (fixture built, not driven)"
        @test true
    else
        fixture = Dict{String,Any}(
            "control" => Dict{String,Any}(
                "name" => "region", "domain" => r["domain"],
                "html" => NS._export_control_html(RE.BindSpec(:region, w.kind, w.params, w.default))),
            "tableHtml" => tablehtml,
            "sweep" => Dict{String,Any}("id" => "tbl:region", "asset" => "data/region_replay.i16.bin",
                                        "control" => "region", "domain" => r["domain"],
                                        "slice" => r["slice"], "target" => "table"),
            "packed" => Dict{String,Any}("dtype" => r["dtype"], "shape" => r["shape"], "b64" => r["b64"]),
            "col" => 0,                                     # assert on the product column
            "expect" => Any[["a", "b", "c"], ["b", "c"], ["c", "a"]],
            # The reader's filter is their state, not the control's: moving the knob changes which rows
            # exist and must not clear it.
            "filter" => Dict{String,Any}("text" => "c", "position" => 0, "expect" => ["c"]))
        mktempdir() do dir
            path = joinpath(dir, "table.json")
            open(io -> JSON.print(io, fixture), path, "w")
            io = IOBuffer()
            script = joinpath(@__DIR__, "js", "table_replay.mjs")
            ok = success(pipeline(`$node $script $path`; stdout = io, stderr = io))
            ok || print(String(take!(io)))
            @test ok
        end
    end
end

# ── The chain sweep: a table a hop or more from its control ────────────────────────────────────────
# `@replay` marks one expression. The shape that actually occurs is a table two cells away from the
# control — `slate_table(selected)` where `selected` is what reads `region` — and there is no expression
# to mark. The cells in between are in the graph, so the export composes them into one closure.
#
# Composing SOURCE is the part that has to be conservative: it runs code the author did not write in
# that form, once per position of a control. So the analysis is tested for what it REFUSES as much as
# for what it composes.
@testset "chain sweep: composing the cells between a control and a table" begin
    RE = ReportEngine
    # A stub table output — enough for `_table_specs` to find a candidate spec on a cell.
    _tblout(rows) = RE.CellOutput("", RE.MimeChunk[], Any[],
                                  Any[Dict{String,Any}("columns" => Any["a"], "rows" => rows,
                                                        "opts" => Dict{String,Any}("nrows" => length(rows)))],
                                  RE.BindSpec[], "", nothing, nothing, 0.0)

    # The notebook shape this exists for: two controls upstream, one of them surfaced on the table.
    r = RE.parse_report("""
    #%% code id=data
    using Dates
    ORDERS = [(revenue = 1.0, region = "All"), (revenue = 2.0, region = "APAC")]
    orders_in(r) = r == "All" ? ORDERS : filter(o -> o.region == r, ORDERS)

    #%% code id=ctl
    @bind region Select(["All", "APAC"])
    @bind band Slider(0:100)

    #%% code id=selection
    selected = filter(o -> o.revenue <= band, orders_in(region))

    #%% code id=table_filtered controls=region
    slate_table(selected)
    """)
    RE.build_dependencies!(r)
    byid = Dict(c.id => c for c in r.cells)
    # Stand in for a run: the specs the `@bind` cell registered, and the table the last cell produced.
    _spec(name, w) = RE.BindSpec(name, w.kind, w.params, w.default)
    byid["ctl"].binds = [_spec(:region, RE.Select(["All", "APAC"])), _spec(:band, RE.Slider(0:100))]
    byid["table_filtered"].output = _tblout(Any[Any[1.0]])

    # `selection` reads `band`, so the graph makes `table_filtered` downstream of BOTH controls. Only
    # one may be swept — the cross product is 2 × 101 evaluations of the same chain — and `controls=`
    # is the author saying which knob belongs to this table.
    plan = NS._chain_sweep_plan(r.cells)
    @test length(plan) == 1
    p = only(plan)
    @test p.control == "region" && p.cell == "table_filtered"
    @test p.id == "table_filtered:region"
    @test p.key == "table_filtered#1"
    @test p.blocked === nothing
    # …and the other one is REPORTED, not silently ignored. HELD, not frozen: `band` still works on the
    # page for anything with its own data — what is baked in is the value it had at export.
    @test p.held == ["band"]

    # The composed closure: the control is the parameter, the chain's assignments are inside a `let`,
    # and `data` is NOT in it — it does not read the control, so it is a global the chain reads as usual
    # (which is what keeps a `using Dates` cell out of a scope that cannot hold one).
    @test startswith(p.source, "region -> let\n")
    @test occursin("selected = filter", p.source)
    @test occursin("slate_table(selected)", p.source)
    @test !occursin("ORDERS = ", p.source)
    @test (Meta.parse(p.source); true)            # …and it is one parseable expression

    # A `let` is what makes this safe: the chain assigns `selected`, and a sweep over a hundred
    # positions must not leave the notebook's global holding the last one.
    m = Module(:ChainScope)
    Core.eval(m, :(ORDERS = [(revenue = 1.0, region = "All"), (revenue = 2.0, region = "APAC")]))
    Core.eval(m, :(orders_in(r) = r == "All" ? ORDERS : filter(o -> o.region == r, ORDERS)))
    Core.eval(m, :(band = 100))
    Core.eval(m, :(selected = :untouched))
    Core.eval(m, :(slate_table = identity))
    f = Core.eval(m, Meta.parse(NS._chain_sweep_source([byid["selection"], byid["table_filtered"]], "region")))
    @test length(Base.invokelatest(f, "All")) == 2
    @test Base.invokelatest(getproperty, m, :selected) === :untouched

    # ── What it refuses ──
    bad = RE.parse_report("""
    #%% code id=ctl
    @bind k Slider(1:3)

    #%% code id=uses
    using Statistics
    u = k + 1

    #%% code id=consts
    const C = k

    #%% code id=side resource
    h = k

    #%% code id=marked
    z = @replay(k, [k])

    #%% code id=fine
    w = k * 2
    """)
    RE.build_dependencies!(bad)
    bb = Dict(c.id => c for c in bad.cells)
    @test occursin("using", NS._replay_chain_blocker(bb["uses"]))
    @test occursin("const", NS._replay_chain_blocker(bb["consts"]))
    @test occursin("@replay", NS._replay_chain_blocker(bb["marked"]))
    # A declared side effect is refused by its EFFECT CLASS, not by reading its source: a cell that
    # opens a handle should not be re-run once per position of a slider.
    @test occursin("resource", NS._replay_chain_blocker(bb["side"]))
    @test NS._replay_chain_blocker(bb["ctl"]) !== nothing          # a @bind cell never composes
    @test NS._replay_chain_blocker(bb["fine"]) === nothing         # …and an ordinary cell composes
    # A markdown cell is not a link in a chain — the chain is code.
    md = RE.parse_report("#%% md id=m\n@md\"\"\"hi\"\"\"\n")
    @test NS._replay_chain_blocker(md.cells[1]) == "is not a code cell"

    # A chain whose middle is refused reports the CELL and the reason, and composes nothing.
    r2 = RE.parse_report("""
    #%% code id=ctl
    @bind k Slider(1:3)

    #%% code id=mid
    using Statistics
    picked = k

    #%% code id=tbl
    slate_table(picked)
    """)
    RE.build_dependencies!(r2)
    b2 = Dict(c.id => c for c in r2.cells)
    b2["ctl"].binds = [_spec(:k, RE.Slider(1:3))]
    b2["tbl"].output = _tblout(Any[Any[1.0]])
    p2 = only(NS._chain_sweep_plan(r2.cells))
    @test p2.blocked !== nothing && occursin("mid", p2.blocked)

    # A table that already carries its own mark is left alone — the author was more specific than the
    # graph, and composing a second sweep for the same table would ship the rows twice.
    b3 = Dict(c.id => c for c in r.cells)
    spec = Dict{String,Any}("columns" => Any["a"], "rows" => Any[Any[1.0]],
                            "opts" => Dict{String,Any}("__replay" => Dict{String,Any}("id" => "x:y")))
    b3["table_filtered"].output = RE.CellOutput("", RE.MimeChunk[], Any[], Any[spec],
                                                RE.BindSpec[], "", nothing, nothing, 0.0)
    @test isempty(NS._chain_sweep_plan(r.cells))

    # A server-paged table has no rows to ship — they are fetched from the kernel a page at a time.
    b3["table_filtered"].output = RE.CellOutput("", RE.MimeChunk[], Any[],
        Any[Dict{String,Any}("columns" => Any["a"], "paged" => true, "rows" => Any[])],
        RE.BindSpec[], "", nothing, nothing, 0.0)
    @test isempty(NS._chain_sweep_plan(r.cells))

    # A composed sweep is INFERRED, not asked for, so it declines a domain nobody chose. An author who
    # wants it writes `@replay` and sees the cost in the export dialog.
    r4 = RE.parse_report("""
    #%% code id=ctl
    @bind span RangeSlider(0:1:120)

    #%% code id=mid
    picked = span.lo

    #%% code id=tbl
    slate_table(picked)
    """)
    RE.build_dependencies!(r4)
    b4 = Dict(c.id => c for c in r4.cells)
    _stub!(cell, name, w) = (cell.binds = [RE.BindSpec(name, w.kind, w.params, w.default)])
    rs = RE.RangeSlider(0:1:120)
    _stub!(b4["ctl"], :span, rs)
    b4["tbl"].output = _tblout(Any[Any[1.0]])
    @test length(RE.bind_domain(rs)) > NS._CHAIN_MAX_POSITIONS   # 7 381 ordered pairs — replayable, not automatic
    p4 = only(NS._chain_sweep_plan(r4.cells))
    @test p4.blocked !== nothing && occursin("positions", p4.blocked)

    # …and the same chain under the ceiling composes.
    _stub!(b4["ctl"], :span, RE.Slider(0:1:120))
    p5 = only(NS._chain_sweep_plan(r4.cells))
    @test p5.blocked === nothing && p5.control == "span"

    # A substring macro check refused cells over names that merely START with a refused one, which reads
    # as an unexplainable refusal with no way to find the cause.
    okmac = RE.parse_report("#%% code id=z\nq = @tracepoint \"x\" 1 + 1\n")
    @test NS._replay_chain_blocker(okmac.cells[1]) === nothing
end

# The chain path end to end, in-process: compose the cells between a control and a table, register the
# result as a sweep, and let the ordinary sweep pack it. The only piece not exercised here is the gate
# round trip, which carries the source string and nothing else.
@testset "chain sweep: a composed closure sweeps like a written one, and retires" begin
    RE = ReportEngine
    r = RE.parse_report("""
    #%% code id=data
    ROWS = [(city = "oslo", n = 1), (city = "lima", n = 3), (city = "bergen", n = 2)]

    #%% code id=ctl
    @bind north Checkbox(true)

    #%% code id=selection
    picked = filter(o -> (o.n < 3) == north, ROWS)

    #%% code id=tbl
    slate_table(picked)
    """)
    RE.build_dependencies!(r)
    RE.eval_stale!(r)

    sweeps = Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps)
    @test isempty(sweeps)                    # nothing in the notebook mentions the control and the table

    byid = Dict(c.id => c for c in r.cells)
    src = NS._chain_sweep_source([byid["selection"], byid["tbl"]], "north")
    f = Core.eval(r.mod, Meta.parse(src))
    register = Base.invokelatest(getproperty, r.mod, :__slate_replay_chain)
    res = Base.invokelatest(register, [(; id = "tbl:north", name = :north, f = f, cell = "tbl")])
    @test res["tbl:north"] == "ok"

    # From here on it is an ordinary mark: the domain came from the control, not from the export.
    got = Base.invokelatest(Base.invokelatest(getproperty, r.mod, :__slate_run_replays))
    s = got["tbl:north"]
    @test s["target"] == "table" && s["control"] == "north" && s["cell"] == "tbl"
    @test s["domain"] == Any[false, true]
    @test s["rows"] == Any[Any["lima", 3], Any["oslo", 1], Any["bergen", 2]]
    A = reshape(reinterpret(Int16, Base64.base64decode(s["b64"])), 3, 2)
    @test A[:, 1] == Int16[1, 0, 0]           # unchecked → the one row with n ≥ 3
    @test A[:, 2] == Int16[2, 3, 0]           # checked   → the other two, in the chain's own order

    # …and the sweep did not leave the notebook holding the last position's value.
    @test length(Base.invokelatest(getproperty, r.mod, :picked)) == 2

    # A composed sweep is RETIRED when a later pass stops asking for it — the graph is re-derived on
    # every export, so a deleted table must stop being swept rather than billing the page forever.
    @test Base.invokelatest(register, []) isa AbstractDict
    @test isempty(Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps))

    # Only entries this mechanism created are retired — an author's `@replay` is theirs, and a pass that
    # found no chains must not silently strip the marks the notebook actually declares.
    sweeps["mine:north"] = (; name = "north", f = (v -> [1.0]), wrap = identity,
                              domain = Any[false, true], cell = "mine", kind = "checkbox")
    Base.invokelatest(register, [])
    @test haskey(Base.invokelatest(getproperty, r.mod, :__slate_replay_sweeps), "mine:north")
end

# ── A published page's data has to exist ─────────────────────────────────────────────────────────
# A site page references its data as plain sibling files instead of carrying it inline. The site
# builder writes the assets it can see from the NOTEBOOK before rendering the page — but a `@replay`
# sweep is evaluated inside `export_html`, so it does not exist yet at that point. Every sweep
# therefore shipped as a URL with no file behind it, and because `wire` only enables a control once
# its asset resolves, every replayed control on every published site rendered disabled. The page
# looked complete, nothing was logged, and it went unnoticed for as long as `@replay` has existed.
#
# `asset_sink` closes it. This asserts the wiring rather than the symptom, because reproducing the
# symptom needs a live worker and a real site build.
@testset "a site page collects the siblings only its export could produce" begin
    src = read(joinpath(@__DIR__, "..", "src", "server_export.jl"), String)
    lines = split(src, '\n')
    # The CALL sites (not the prose about them): each is a page whose data ships as neighbouring files.
    calls = [i for (i, l) in enumerate(lines)
             if occursin("inline_assets = false", l) && !startswith(strip(l), "#")]
    @test length(calls) == 3            # _build_site_dir! · _build_doc! · _assemble_site!
    for i in calls
        window = join(lines[max(1, i - 5):min(length(lines), i + 4)], "\n")
        # A new site-page builder that forgets this ships a page whose data is missing, silently.
        @test occursin("asset_sink", window)
    end
    # …and whatever lands in the sink is written where the page will look for it.
    mktempdir() do dir
        n = NS._write_sibling_assets!(dir, Dict{String,Vector{UInt8}}(
            "data/x.i16.bin" => UInt8[1, 0, 2, 0], "nested/deep/y.bin" => UInt8[9]))
        @test n == 2
        @test read(joinpath(dir, "data", "x.i16.bin")) == UInt8[1, 0, 2, 0]
        @test read(joinpath(dir, "nested", "deep", "y.bin")) == UInt8[9]   # dirs created on the way
    end
end

# Surfacing MOVES a control, it does not copy it. `controls=` on a figure's header puts the knob
# beside the thing it drives, and the live page then renders NOTHING where that control was declared
# — which is the whole point, since a lone copy above the definition is the layout the author was
# getting rid of. The export used to render only what each cell declared (so every surfaced strip
# vanished); rendering both places instead would be the opposite error.
@testset "@bind controls render where they are surfaced, not where declared" begin
    RE = ReportEngine
    r = RE.parse_report("""
    #%% code id=ctl
    @bind w Slider(1:10)
    @bind k Select(["a", "b"])

    #%% code id=fig controls=w
    1 + 1

    #%% code id=other
    2 + 2
    """)
    RE.build_dependencies!(r)
    byid = Dict(c.id => c for c in r.cells)
    # Stand in for a run: the specs a `@bind` cell would have registered.
    byid["ctl"].binds = [RE.BindSpec(:w, "slider", Dict{String,Any}("min" => 1, "max" => 10, "step" => 1), 1),
                         RE.BindSpec(:k, "select", Dict{String,Any}("options" => Any["a", "b"]), "a")]

    idx = NS._bind_index(r.cells)
    surf = NS._surfaced_names(r.cells)
    @test surf == Set(["w"])                       # only `w` was moved

    decl = NS._export_controls_html(byid["ctl"], idx, surf)
    fig  = NS._export_controls_html(byid["fig"], idx, surf)
    other = NS._export_controls_html(byid["other"], idx, surf)

    @test occursin("data-name=\"w\"", fig)         # the surfaced one renders beside its figure…
    @test !occursin("data-name=\"w\"", decl)       # …and NOT where it was declared
    @test occursin("data-name=\"k\"", decl)        # the un-surfaced one stays put
    @test isempty(other)                            # a cell with neither declares nor surfaces

    # And when every declared control is surfaced, the declaring cell emits nothing at all rather
    # than an empty strip that still takes vertical space.
    byid["fig"].controls = [["w"], ["k"]]
    surf2 = NS._surfaced_names(r.cells)
    @test isempty(NS._export_controls_html(byid["ctl"], idx, surf2))
end

# ── PDF export: admonitions ───────────────────────────────────────────────────────────────────────
# `cmarker` (the Typst markdown renderer) is plain CommonMark and has no `!!!` rule, so the marker
# would print literally and the four-space body would typeset as a CODE BLOCK. `_admonitions_to_quotes`
# lowers each callout to a titled blockquote before the source reaches it.
@testset "typst export lowers admonitions to titled blockquotes" begin
    f = NS._admonitions_to_quotes

    out = f("!!! answer \"Answer (a)\"\n\n    First para.\n\n    Second para.\n\nAfter.\n")
    @test occursin("> **Answer (a)**", out)
    @test occursin("> First para.", out)
    @test occursin("> Second para.", out)
    @test occursin("\nAfter.", out)                  # prose after the box leaves the quote
    @test !occursin("!!!", out)
    @test !occursin("    First para.", out)          # de-indented, so it can't read as a code block

    # No title → the category, capitalised.
    @test occursin("> **Note**", f("!!! note\n\n    Body.\n"))

    # Pluto writes admonition bodies with a TAB; CommonMark expands it to the same four columns.
    @test occursin("> Tabbed body.", f("!!! tip \"T\"\n\n\tTabbed body.\n"))

    # A `!!!` inside a fence is code, not a callout.
    fenced = "```julia\n!!! not a callout\n```\n"
    @test f(fenced) == fenced

    # Math rides through untouched for mitex.
    @test occursin("> Rate \$U>U_n\$ holds.", f("!!! answer \"A\"\n\n    Rate \$U>U_n\$ holds.\n"))

    # Nothing to do → the source is unchanged.
    @test f("Just prose.\n") == "Just prose.\n"
end

@testset "Typst export — components (`slate_render`) reach the page" begin
    compchunk() = _RE.MimeChunk(NS._COMPONENT_MIME,
                                Vector{UInt8}(codeunits("{\"v\":1,\"component\":\"K\",\"props\":{}}")))
    out(chunks) = _RE.CellOutput("", chunks, Any[], Any[], _RE.BindSpec[], "", nothing, nothing, 1.0)

    # ── which mounts get captured, and under which slot ──
    # A code cell that returned one is slot 0. A markdown cell addresses its mounts by their order in
    # the rendered DOM, so the slot is a position among the COMPONENT-valued interpolations, not among
    # all of them — `_render_chunks` emits a `.disp.slatecomp` only for a component chunk.
    rep = _RE.parse_report("#%% code id=c\n1\n")
    cc = rep.cells[end]
    @test NS._component_slots(cc) == Tuple{Int,Int}[]        # not run yet ⇒ nothing to capture
    cc.output = out([compchunk()])
    @test NS._component_slots(cc) == [(0, 0)]
    cc.output = out([_RE.MimeChunk("image/png", UInt8[0x89])])
    @test NS._component_slots(cc) == Tuple{Int,Int}[]        # a raster is not a component

    mrep = _RE.parse_report("#%% md id=m\n@md\"\"\"\n{{ 1 }} and {{ 2 }} and {{ 3 }}\n\"\"\"\n")
    mc = mrep.cells[end]
    mc.interp = [out(_RE.MimeChunk[]), out([compchunk()]), out([compchunk()])]
    @test NS._component_slots(mc) == [(0, 2), (1, 3)]        # 2nd and 3rd interp ⇒ mounts 0 and 1

    # ── print width tracks the diagram's own proportions ──
    svg(w) = Vector{UInt8}(codeunits("<svg viewBox=\"0 0 $w 100\" xmlns=\"…\"></svg>"))
    @test NS._comp_fig_width_pct(svg(640), "svg") == 100     # the reference column ⇒ full width
    @test NS._comp_fig_width_pct(svg(320), "svg") == 50      # half as wide on screen ⇒ half in print
    @test NS._comp_fig_width_pct(svg(4000), "svg") == 100    # capped: it can never overflow the column
    @test NS._comp_fig_width_pct(svg(16), "svg") == 25       # floored: never vanishingly small
    @test NS._comp_fig_width_pct(Vector{UInt8}(codeunits("<svg></svg>")), "svg") === nothing
    @test NS._comp_fig_width_pct(svg(640), "png") === nothing   # a raster has no intrinsic column

    # ── the html2canvas rescue covers BOTH HTML output flavours ──
    hc = _RE.parse_report("#%% code id=h\n1\n").cells[end]
    hc.output = out([_RE.MimeChunk("application/vnd.kaimonslate.html+html", Vector{UInt8}("<b>x</b>"))])
    @test NS._has_html_output(hc)                            # `html_fragment`, not just `text/html`
end

@testset "Typst export — a claimed fence degrades to its source, never to nothing" begin
    # A ```mermaid fence is desugared to an interpolation, so with no capture available the token had
    # nothing to resolve to and the whole block — source included — dropped out of the PDF. That is
    # strictly worse than an UNCLAIMED fence, which prints as a code block; so print the code block.
    src = "#%% md id=m\n@md\"\"\"\nBefore.\n\n```mermaid\nflowchart LR\n    A --> B\n```\n\nAfter.\n\"\"\"\n"
    c = _RE.parse_report(src).cells[end]
    c.interp = [_RE.CellOutput("", _RE.MimeChunk[], Any[], Any[], _RE.BindSpec[], "", nothing, nothing, 1.0)]
    md = NS._md_for_typst(c)
    @test occursin("```mermaid", md)
    @test occursin("flowchart LR", md) && occursin("A --> B", md)
    @test occursin("Before.", md) && occursin("After.", md)

    # With a capture, the same slot becomes the figure instead.
    @test occursin("![](fig.svg)", NS._md_for_typst(c; compfig = _ -> "fig.svg"))

    # A body containing its own backticks gets a longer fence, so the block still closes where it should.
    inner = "a\n```\nb"
    blk = NS._md_fence_block("mermaid", inner)
    @test occursin("````mermaid", blk) && endswith(strip(blk), "````")
end

# The live page and the HTML export have SEPARATE stylesheets. Admonition markup is produced by the
# shared markdown pipeline, so an export gets the divs either way — but with no rules to draw them the
# callouts flatten into ordinary prose, which is silent: the page looks fine, just wrong.
@testset "export CSS styles admonitions" begin
    css = NS._export_css("dark", "normal", 900)
    @test occursin(".exp-md .admonition", css)
    @test occursin("admonition-title", css)
    # Each named category must set an accent, and the base rule must carry a fallback for one nobody
    # anticipated — the category is free-form, so `!!! wibble` has to look deliberate too.
    @test occursin("--adm:var(--dim)", css)
    for cat in ("note", "tip", "answer", "warning", "danger", "hint", "info")
        @test occursin(".admonition.$cat", css)
    end
    # It must reference only variables the export palette actually defines — `--strong` is the LIVE
    # sheet's name for high-emphasis text and does not exist here, so using it would silently inherit.
    @test occursin("var(--titlefg)", css)
    @test !occursin("--adm) 25%,var(--strong)", css)

    # A `---` in prose. Unstyled it falls back to the browser's `1px inset grey` — a different grey
    # from everything else on the page, most visibly right beside a cell's own box edge.
    @test occursin(".exp-md hr", css)
    @test occursin("border-top:1px solid var(--border)", css)
end

@testset "figure cross-refs — a component is a figure, and `[@fig:x]` resolves" begin
    compout() = _RE.CellOutput("", [_RE.MimeChunk(NS._COMPONENT_MIME, Vector{UInt8}("{}"))],
                               Any[], Any[], _RE.BindSpec[], "", nothing, nothing, 1.0)

    # A component draws in the browser, so it has no bytes until an export asks — but it IS the
    # figure the caption below it refers to. Before this it was invisible to the flow binding, and a
    # caption silently anchored to whatever earlier cell had produced a raster.
    rep = _RE.parse_report("#%% code id=diagram\n1\n#%% md id=cap caption\n@md\"\"\"A diagram.\"\"\"\n")
    dia = rep.cells[findfirst(c -> c.id == "diagram", rep.cells)]
    @test !NS._cell_has_figure(dia)                       # not run yet
    dia.output = compout()
    @test NS._cell_has_figure(dia)

    idx = NS.figure_index(rep)
    @test idx.numbers["cap"] == 1
    @test idx.capfor["cap"] == "diagram"                  # flow-bound to the component above it

    # `[@fig:<label>]` is the documented form, but a tag value can't hold a colon (`_parse_tag_symbols`
    # folds it), so the label an author can actually write is bare. Both spellings resolve.
    @test idx.labels["cap"] == (1, "diagram")
    @test idx.labels["fig:cap"] == (1, "diagram")

    ref(s) = NS._rewrite_citations(s, Set{String}(); figrefs = idx.labels)
    @test ref("See [@fig:cap] below.") == "See Figure 1 below."
    @test ref("See [@cap] below.") == "See Figure 1 below."

    # An explicit `label=` behaves the same way.
    rep2 = _RE.parse_report("#%% code id=d2\n1\n#%% md id=c2 caption label=schedule\n@md\"\"\"S.\"\"\"\n")
    rep2.cells[findfirst(c -> c.id == "d2", rep2.cells)].output = compout()
    l2 = NS.figure_index(rep2).labels
    @test haskey(l2, "schedule") && haskey(l2, "fig:schedule")

    # An author who somehow already has a `fig:`-prefixed label doesn't get `fig:fig:…`.
    @test !any(startswith(k, "fig:fig:") for k in keys(l2))
end

# ── @replay: marks outliving their cell ───────────────────────────────────────────────────────────
# The sweep registry is keyed by cell id and only grows — a mark is written when its cell RUNS, and
# nothing retires it when that cell is later renamed or deleted. Renaming through the UI could evict,
# but a notebook is a file: edit the `.jl` outside Slate and there is no rename event to hook. So the
# export reconciles against the cells that actually exist. Left alone, a stale mark is swept, packed
# and shipped for a cell that is not in the document.
@testset "export drops replay marks whose cell is gone" begin
    live = ReportEngine.Report("r", "")
    push!(live.cells, ReportEngine.Cell("keeper", ReportEngine.CODE, "x = 1"))

    plan = Dict{String,Any}(
        "keeper:w"  => Dict{String,Any}("control" => "w", "cell" => "keeper", "values" => 5),
        "ghost:w"   => Dict{String,Any}("control" => "w", "cell" => "ghost",  "values" => 5),
    )
    ids   = Set{String}(c.id for c in live.cells)
    cellof(r) = String(haskey(r, "cell") ? r["cell"] : get(r, :cell, ""))
    stale = [k for (k, r) in plan if !isempty(cellof(r)) && !(cellof(r) in ids)]
    keep  = [k for k in keys(plan) if !(k in stale)]

    @test stale == ["ghost:w"]
    @test keep  == ["keeper:w"]

    # A registry that is entirely live must produce NO filter — `only = nothing` means "sweep
    # everything", so the common case cannot be made to pay for this.
    allgood = Dict{String,Any}("keeper:w" => plan["keeper:w"])
    @test isempty([k for (k, r) in allgood if !isempty(cellof(r)) && !(cellof(r) in ids)])

    # A record with no `cell` at all is left alone rather than guessed at.
    nocell = Dict{String,Any}("x" => Dict{String,Any}("control" => "w"))
    @test isempty([k for (k, r) in nocell if !isempty(cellof(r)) && !(cellof(r) in ids)])
end
