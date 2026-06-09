# Reproducibility: the `.jl` env-delta footer (engine) and the self-contained bundle
# (export_bundle). Run:  julia --startup-file=no test/test_repro.jl
using Test, Base64

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine

@testset "reproducibility footer" begin
    src = """
    #%% code id=a
    using Plots
    x = 1

    #%% md id=b
    # Title

    # ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
    #   CSV 0.10.14 336ed68f-0bac-5ca0-87d4-7b16caf5d00b
    #   Plots 1.40.5 91a5bcdd-7333-5406-abb4-e4a6da0a7c5c
    # ╚═╡
    """

    @testset "parse: footer → meta, not a cell" begin
        r = parse_report(src)
        @test length(r.cells) == 2                       # footer is not a cell
        @test [c.id for c in r.cells] == ["a", "b"]
        env = r.meta["env"]
        @test length(env) == 2
        @test env[1]["name"] == "CSV"                    # sorted by name
        @test env[2]["name"] == "Plots"
        @test env[2]["version"] == "1.40.5"
        @test env[2]["uuid"] == "91a5bcdd-7333-5406-abb4-e4a6da0a7c5c"
    end

    @testset "round-trip is stable" begin
        r = parse_report(src)
        s1 = serialize_report(r)
        r2 = parse_report(s1)
        @test serialize_report(r2) == s1                 # idempotent
        @test occursin("Slate.env", s1)
        @test r2.meta["env"] == r.meta["env"]
    end

    @testset "no footer when no delta" begin
        r = parse_report("#%% code id=a\nx = 1\n")
        @test !haskey(r.meta, "env")
        @test !occursin("Slate.env", serialize_report(r))
    end

    @testset "serialize_cells omits the footer" begin
        r = parse_report(src)
        @test !occursin("Slate.env", serialize_cells(r))
        @test occursin("using Plots", serialize_cells(r))
    end

    @testset "tolerant of missing version/uuid" begin
        r = parse_report("#%% code id=a\nx=1\n\n# ╔═╡ Slate.env\n#   Foo\n# ╚═╡\n")
        @test r.meta["env"][1]["name"] == "Foo"
        @test r.meta["env"][1]["version"] == ""
    end
end

# ── Self-contained bundle (export_bundle.jl) ─────────────────────────────────
# export_bundle.jl is a flat file meant for `module NotebookServer`; its only module
# coupling is `LiveNotebook` (a signature annotation) and qualified `ReportEngine.*` calls.
# A stub `LiveNotebook` lets it load here so the kernel-independent helpers are testable.
struct LiveNotebook end
include(joinpath(@__DIR__, "..", "src", "export_bundle.jl"))

@testset "self-contained bundle round-trip" begin
    cells = "#%% code id=a\nusing Foo\nFoo.greet()\n"

    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "name=\"Demo\"\n[deps]\nFoo = \"00000000-0000-0000-0000-000000000001\"\n")
    write(joinpath(proj, "Manifest.toml"), "julia_version=\"1.12.0\"\n")
    localpkg = mktempdir()
    mkpath(joinpath(localpkg, "src"))
    write(joinpath(localpkg, "Project.toml"), "name=\"Foo\"\n")
    write(joinpath(localpkg, "src", "Foo.jl"), "module Foo\ngreet()=\"hi\"\nend\n")

    b64 = _make_bundle_b64(proj, [(name = "Foo", source = localpkg)], "demo.jl", cells)
    standalone = cells * "\n" * _bundle_footer(b64) * "\n"

    @testset "footer payload extraction" begin
        @test occursin(_BUNDLE_OPEN, standalone)
        @test _read_bundle_b64(standalone) == b64
    end

    @testset "a standalone .jl still parses as a notebook" begin
        r = parse_report(standalone)
        @test length(r.cells) == 1                        # bundle footer stripped
        @test r.cells[1].id == "a"
    end

    @testset "expand reinflates the project tree" begin
        sj = joinpath(mktempdir(), "demo.standalone.jl")
        write(sj, standalone)
        tdir = expand(sj)
        @test isfile(joinpath(tdir, "Project.toml"))
        @test isfile(joinpath(tdir, "Manifest.toml"))
        @test isfile(joinpath(tdir, "demo.jl"))
        @test isfile(joinpath(tdir, "local", "Foo", "src", "Foo.jl"))
        @test occursin("module Foo", read(joinpath(tdir, "local", "Foo", "src", "Foo.jl"), String))
    end
end

# Git bundle + auto-attach (only when git is available).
if Sys.which("git") !== nothing
    @testset "git bundle: matching SHAs + auto-attach origin" begin
        cells = "#%% code id=a\nx=1\n"
        repo = mktempdir()
        write(joinpath(repo, "Project.toml"), "name=\"Demo\"\n[deps]\n")
        write(joinpath(repo, "Manifest.toml"), "julia_version=\"1.12.0\"\n")
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))
        run(pipeline(`git -C $repo remote add origin https://example.com/demo.git`; stderr = devnull))

        b64 = _make_bundle_b64(repo, NamedTuple[], "demo.jl", cells)
        sj = joinpath(mktempdir(), "demo.standalone.jl")
        write(sj, cells * "\n" * _bundle_footer(b64) * "\n")
        tdir = expand(sj)

        @test isfile(joinpath(tdir, "repo.gitbundle"))
        cloned = joinpath(tdir, "repo")
        @test isdir(cloned)
        orig_sha = strip(read(`git -C $repo rev-parse HEAD`, String))
        clone_sha = strip(read(`git -C $cloned rev-parse HEAD`, String))
        @test orig_sha == clone_sha                       # matching SHAs
        @test strip(read(`git -C $cloned remote get-url origin`, String)) == "https://example.com/demo.git"
    end
end
