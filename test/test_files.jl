# Files tab helpers (src/server_complete.jl): file-kind classification, project-path confinement,
# and the project tree (all files shown, tagged by kind). Pure filesystem logic — a temp dir stands
# in for a notebook's project root; no live hub needed.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer

@testset "files-tab" begin
    @testset "_file_kind classification" begin
        @test NS._file_kind("worker.jl")      == "text"
        @test NS._file_kind("style.css")      == "text"
        @test NS._file_kind("synth.js")       == "text"
        @test NS._file_kind("page.html")      == "text"
        @test NS._file_kind("data.json")      == "text"
        @test NS._file_kind("README.md")      == "text"
        @test NS._file_kind("plot.PNG")       == "image"     # case-insensitive
        @test NS._file_kind("photo.jpeg")     == "image"
        @test NS._file_kind("icon.svg")       == "image"     # svg previews as image (still text-editable via ?as=text)
        @test NS._file_kind("clip.mp3")       == "audio"
        @test NS._file_kind("intro.mp4")      == "video"
        @test NS._file_kind("blob.bin")       == "binary"
        @test NS._file_kind("archive.zip")    == "binary"
        @test NS._file_kind("noext")          == "binary"
    end

    @testset "_safe_proj_path confinement" begin
        root = mktempdir()
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "src", "a.jl"), "x")
        @test NS._safe_proj_path(root, "src/a.jl") == normpath(joinpath(root, "src", "a.jl"))
        @test NS._safe_proj_path(root, "src/../src/a.jl") == normpath(joinpath(root, "src", "a.jl"))
        # escapes and absolute paths are rejected (empty string)
        @test NS._safe_proj_path(root, "../secret") == ""
        @test NS._safe_proj_path(root, "../../etc/passwd") == ""
        @test NS._safe_proj_path(root, "/etc/passwd") == ""
        @test NS._safe_proj_path(root, "") == ""
        @test NS._safe_proj_path("", "src/a.jl") == ""       # no root ⇒ detached
    end

    @testset "_proj_tree shows all files with kinds, prunes noise" begin
        root = mktempdir()
        mkpath(joinpath(root, "src"))
        mkpath(joinpath(root, "assets"))
        mkpath(joinpath(root, "node_modules", "pkg"))        # skip-dir: must not appear
        mkpath(joinpath(root, "empty"))                      # no visible content: pruned
        write(joinpath(root, "Project.toml"), "name=\"X\"")
        write(joinpath(root, "src", "main.jl"), "1")
        write(joinpath(root, "assets", "logo.png"), "PNG")
        write(joinpath(root, "assets", "app.js"), "//")
        write(joinpath(root, ".hidden"), "nope")             # dotfile: skipped
        write(joinpath(root, "node_modules", "pkg", "index.js"), "//")

        tree = NS._proj_tree(root, root)
        names = Set(n["name"] for n in tree)
        @test "Project.toml" in names
        @test "src" in names
        @test "assets" in names
        @test !("node_modules" in names)                     # skip-dir pruned
        @test !("empty" in names)                            # empty dir pruned
        @test !(".hidden" in names)                          # dotfile skipped

        # dirs before files; each file carries a kind + bytes
        assets = only(n for n in tree if n["name"] == "assets")
        @test assets["dir"] === true
        kinds = Dict(n["name"] => n["kind"] for n in assets["children"] if get(n, "dir", false) === false)
        @test kinds["logo.png"] == "image"
        @test kinds["app.js"]   == "text"
        for n in assets["children"]
            get(n, "dir", false) === false && (@test haskey(n, "bytes"))
        end

        proj = only(n for n in tree if n["name"] == "Project.toml")
        @test proj["kind"] == "text"
        @test proj["path"] == "Project.toml"
    end

    # ── Embedded-media export helpers (make drag/drop assets survive HTML/PDF/publish exports) ────────
    @testset "_embedded_media decode" begin
        # a 1×1 red PNG
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        got = NS._embedded_media("", "data:image/png;base64," * png_b64)
        @test got !== nothing
        bytes, mime, ext = got
        @test mime == "image/png" && ext == ".png"
        @test bytes[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]        # PNG magic

        # plain (non-base64) data URL is URL-decoded
        g2 = NS._embedded_media("", "data:text/plain,Hello%20World")
        @test g2 !== nothing && String(g2[1]) == "Hello World"

        # asset-route URL resolves against the asset base, with the traversal guard
        root = mktempdir(); mkpath(joinpath(root, "assets"))
        write(joinpath(root, "assets", "logo.png"), UInt8[1, 2, 3])
        ga = NS._embedded_media(root, "/n/abc123/asset/assets/logo.png")
        @test ga !== nothing && ga[1] == UInt8[1, 2, 3] && ga[2] == "image/png"
        @test NS._embedded_media(root, "/n/abc/asset/../secret") === nothing   # escape rejected
        @test NS._embedded_media(root, "/n/abc/asset/nope.png") === nothing    # missing file
        @test NS._embedded_media("", "/n/abc/asset/assets/logo.png") === nothing  # no base
        @test NS._embedded_media(root, "https://example.com/x.png") === nothing  # not an embeddable ref
    end

    @testset "_export_embed_html rewrite (inline vs published)" begin
        root = mktempdir(); mkpath(joinpath(root, "assets"))
        write(joinpath(root, "assets", "pic.png"), UInt8[0x89, 0x50, 0x4e, 0x47, 9, 9])
        html = "<p><img src=\"/n/xyz/asset/assets/pic.png\" alt=\"p\"></p>"

        inlined = NS._export_embed_html(html, root; inline = true)      # standalone → data: URI
        @test occursin("src=\"data:image/png;base64,", inlined)
        @test !occursin("/asset/", inlined)

        published = NS._export_embed_html(html, root; inline = false)   # site → page-relative
        @test occursin("src=\"assets/pic.png\"", published)
        @test !occursin("/n/xyz/asset/", published)

        # an already-inline data: src is left untouched in both modes
        d = "<img src=\"data:image/gif;base64,AAAA\">"
        @test NS._export_embed_html(d, root; inline = true) == d
        @test NS._export_embed_html(d, root; inline = false) == d
        # an unreadable asset ref is left as-is rather than corrupting the doc
        miss = "<img src=\"/n/x/asset/assets/gone.png\">"
        @test NS._export_embed_html(miss, root; inline = true) == miss
    end

    @testset "_stage_typst_md_media stages images, drops non-images" begin
        root = mktempdir(); mkpath(joinpath(root, "assets"))
        write(joinpath(root, "assets", "fig.png"), UInt8[0x89, 0x50, 0x4e, 0x47])
        dir = mktempdir()

        md = "See ![a fig](/n/n1/asset/assets/fig.png) here."
        out = NS._stage_typst_md_media(md, dir, "c1", root)
        @test occursin("![a fig](c1_media1.png)", out)                 # rewritten to a local filename
        @test isfile(joinpath(dir, "c1_media1.png"))                   # bytes staged into the project dir
        @test !occursin("/asset/", out)

        # a data: image is decoded + staged too
        md2 = "![x](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==)"
        out2 = NS._stage_typst_md_media(md2, dir, "c2", root)
        @test occursin("![x](c2_media1.png)", out2)
        @test isfile(joinpath(dir, "c2_media1.png"))

        # a non-image (would abort the PDF) collapses to its (escaped) alt text — never a broken image()
        md3 = "![clip](/n/n1/asset/assets/song.mp3)"
        write(joinpath(root, "assets", "song.mp3"), UInt8[1, 2, 3])
        out3 = NS._stage_typst_md_media(md3, dir, "c3", root)
        @test out3 == "clip" && !occursin("song.mp3", out3)

        # alt text with markdown/math-active chars is escaped so it can't abort the cmarker/Typst compile
        md4 = "![price \$5 to \$9](/n/n1/asset/assets/gone.png)"    # unresolved → escaped alt
        out4 = NS._stage_typst_md_media(md4, dir, "c4", root)
        @test occursin(raw"\$", out4) && !occursin("](", out4)

        # a titled image `![a](url "cap")` still matches and stages (regex allows the optional title)
        md5 = "![a fig](/n/n1/asset/assets/fig.png \"a caption\")"
        out5 = NS._stage_typst_md_media(md5, dir, "c5", root)
        @test occursin("![a fig](c5_media1.png)", out5)
    end

    @testset "_embedded_asset_files scans sources + output, honours any subdir" begin
        RE = KaimonSlate.ReportEngine
        root = mktempdir()
        for d in ("assets", "media", joinpath("images", "sub"))
            mkpath(joinpath(root, d))
        end
        write(joinpath(root, "assets", "a.png"), UInt8[1])
        write(joinpath(root, "media", "b.png"), UInt8[2])         # non-default subdir (the attach route allows it)
        write(joinpath(root, "images", "sub", "c.png"), UInt8[3]) # nested subdir

        cells = [
            RE.Cell("m1", RE.MARKDOWN, "text ![a](/n/x/asset/assets/a.png) more"),
            RE.Cell("m2", RE.MARKDOWN, "raw <img src=\"/n/x/asset/media/b.png\"> and nested ![c](/n/x/asset/images/sub/c.png)"),
            RE.Cell("m3", RE.MARKDOWN, "data ![d](data:image/png;base64,AAAA) — no file"),
        ]
        files = NS._embedded_asset_files(cells, root)
        @test Set(keys(files)) == Set(["assets/a.png", "media/b.png", "images/sub/c.png"])   # any subdir, no data:
        @test files["media/b.png"] == joinpath(root, "media", "b.png")
    end

    # The drag/drop snippet map ((file kind, editor syntax) → inserted reference) lives in files.js;
    # assert it from JS so the client stays honest. Skips cleanly when node isn't installed.
    @testset "embed snippet map: JS _embedSnippet (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping JS _embedSnippet assertion"
            @test true
        else
            io = IOBuffer()
            ok = success(pipeline(`$node $(joinpath(@__DIR__, "js", "embed_snippet.mjs"))`; stdout = io, stderr = io))
            ok || print(String(take!(io)))
            @test ok
        end
    end
end
