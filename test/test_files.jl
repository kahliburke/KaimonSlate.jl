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

    @testset "_export_embed_html routes video/audio onto the blob registry" begin
        root = mktempdir(); mkpath(joinpath(root, "assets"))
        write(joinpath(root, "assets", "clip.mp4"), UInt8[0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70])
        vid = "<p><video controls src=\"/n/xyz/asset/assets/clip.mp4\"></video></p>"

        # standalone: the bytes leave the body, the element keeps only its registry key
        reg = Tuple{String,String,String}[]
        out = NS._export_embed_html(vid, root; inline = true, media = reg)
        @test occursin("data-slate-media=\"m1\"", out)
        @test !occursin("src=", out) && !occursin("data:", out)
        @test length(reg) == 1 && reg[1][1] == "m1" && reg[1][2] == "video/mp4"
        @test NS.Base64.base64decode(reg[1][3]) == read(joinpath(root, "assets", "clip.mp4"))

        # a drop-time-inlined data: clip is re-homed too — `data:` media is what fails on file://
        reg2 = Tuple{String,String,String}[]
        dvid = "<video controls src=\"data:video/webm;base64,AAAA\"></video>"
        out2 = NS._export_embed_html(dvid, root; inline = true, media = reg2)
        @test occursin("data-slate-media=\"m1\"", out2) && !occursin("data:", out2)
        @test length(reg2) == 1 && reg2[1][2] == "video/webm"

        # ...but a data: IMAGE still passes straight through, registry or not
        img = "<img src=\"data:image/gif;base64,AAAA\">"
        @test NS._export_embed_html(img, root; inline = true, media = reg2) == img
        @test length(reg2) == 1

        # published: media stays a page-relative sibling file (seekable over HTTP), registry untouched
        reg3 = Tuple{String,String,String}[]
        pub = NS._export_embed_html(vid, root; inline = false, media = reg3)
        @test occursin("src=\"assets/clip.mp4\"", pub) && isempty(reg3)
        # ...and with no registry at all (PDF/legacy callers) inlining still yields a typed data: URI
        @test occursin("src=\"data:video/mp4;base64,", NS._export_embed_html(vid, root; inline = true))
    end

    @testset "_site_ctype types media by extension" begin
        # `application/octet-stream` here makes a clip unplayable wherever the bytes aren't sniffed
        @test NS._site_ctype("a/clip.mp4") == "video/mp4"
        @test NS._site_ctype("clip.webm") == "video/webm"
        @test NS._site_ctype("clip.MOV") == "video/quicktime"
        @test NS._site_ctype("track.mp3") == "audio/mpeg"
        @test NS._site_ctype("track.flac") == "audio/flac"
        @test NS._site_ctype("pic.webp") == "image/webp"
        @test NS._site_ctype("doc.pdf") == "application/pdf"
        @test NS._site_ctype("blob.xyz") == "application/octet-stream"   # still the fallback
    end

    @testset "_stage_typst_md_media carries {width=…} to the document" begin
        root = mktempdir(); mkpath(joinpath(root, "assets"))
        write(joinpath(root, "assets", "fig.png"), UInt8[0x89, 0x50, 0x4e, 0x47])
        dir = mktempdir()

        # Markdown has nowhere to hang a size, so it rides in the sizes table keyed by the staged name.
        sizes = Dict{String,Any}()
        out = NS._stage_typst_md_media("![a](/n/n1/asset/assets/fig.png){width=300}", dir, "c1", root; sizes = sizes)
        @test out == "![a](c1_media1.png)"                          # block consumed, never printed
        @test sizes["c1_media1.png"]["width"] == Any[225.0, "pt"]    # 300 CSS px at 96dpi

        # A block on an image we don't stage is still dropped rather than printed as prose.
        @test NS._stage_typst_md_media("![b](local.png){width=50%}", dir, "c2", root) == "![b](local.png)"

        # Alone on its line ⇒ a centred figure; inside a run of prose ⇒ left inline.
        s2 = Dict{String,Any}()
        NS._stage_typst_md_media("![a](/n/n1/asset/assets/fig.png)", dir, "c3", root; sizes = s2)
        @test s2["c3_media1.png"]["block"] == true
        s3 = Dict{String,Any}()
        NS._stage_typst_md_media("see ![a](/n/n1/asset/assets/fig.png) there", dir, "c4", root; sizes = s3)
        @test isempty(s3)
        # `{align=…}` overrides where a figure sits
        s4 = Dict{String,Any}()
        NS._stage_typst_md_media("![a](/n/n1/asset/assets/fig.png){align=right}", dir, "c5", root; sizes = s4)
        @test s4["c5_media1.png"]["align"] == "right" && s4["c5_media1.png"]["block"] == true

        @test NS._typst_len("50%") == (50.0, "%")       # relative units stay relative
        @test NS._typst_len("2em") == (2.0, "em")
        @test NS._typst_len("1in") == (72.0, "pt")
        @test NS._typst_len("banana") === nothing       # unparseable ⇒ no size, not a broken document
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
