# Reproducibility: the `.jl` env-delta footer (engine) and the self-contained bundle
# (export_bundle). Run:  julia --startup-file=no test/test_repro.jl
using Test, Base64, JSON, CodecZlib

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

# The `collapsed` header token (cell folded in the UI) round-trips through the .jl via the
# cell's `flags`, and composes with `controls=`.
@testset "collapsed header token round-trips" begin
    r = parse_report("#%% code id=a collapsed\nx = 1\n\n#%% code id=b\ny = 2\n")
    @test :collapsed in first(c for c in r.cells if c.id == "a").flags
    @test !(:collapsed in first(c for c in r.cells if c.id == "b").flags)

    s = serialize_cells(r)
    @test occursin("#%% code id=a collapsed", s)
    @test occursin(r"#%% code id=b\b(?! collapsed)", s)            # b carries no token
    @test :collapsed in first(c for c in parse_report(s).cells if c.id == "a").flags   # idempotent

    r3 = parse_report("#%% code id=c controls=n collapsed\nz = n\n")   # composes with controls=
    @test r3.cells[1].controls == [["n"]] && :collapsed in r3.cells[1].flags
    @test occursin("controls=n collapsed", serialize_cells(r3))
end

# The `hidecode` header token (editor hidden, output shown — clean plots) round-trips via
# `flags`, independent of and composing with `collapsed`.
@testset "hidecode header token round-trips" begin
    r = parse_report("#%% code id=a hidecode\nplot(x)\n\n#%% code id=b\ny = 2\n")
    @test :hidecode in first(c for c in r.cells if c.id == "a").flags
    @test !(:hidecode in first(c for c in r.cells if c.id == "b").flags)

    s = serialize_cells(r)
    @test occursin("#%% code id=a hidecode", s)
    @test occursin(r"#%% code id=b\b(?! hidecode)", s)
    @test :hidecode in first(c for c in parse_report(s).cells if c.id == "a").flags   # idempotent

    r2 = parse_report("#%% code id=c collapsed hidecode\nplot(x)\n")    # composes with collapsed
    @test :collapsed in r2.cells[1].flags && :hidecode in r2.cells[1].flags
    s2 = serialize_cells(r2)
    @test occursin("collapsed", s2) && occursin("hidecode", s2)
end

# ── Notebook-environment model helpers (gate_kernel.jl, loaded via engine.jl) ─
@testset "notebook env model" begin
    @testset "env dir keying" begin
        d1 = ReportEngine.notebook_env_dir("/tmp/a/para.jl")
        d2 = ReportEngine.notebook_env_dir("/tmp/b/para.jl")   # same basename, different path
        @test d1 != d2                                          # keyed by full path, not name
        @test ReportEngine.notebook_env_dir("/tmp/a/para.jl") == d1   # stable
        @test occursin("kaimonslate", d1)
    end

    @testset "ensure_notebook_env! materialises a Project.toml" begin
        d = mktempdir()
        env = joinpath(d, "nbenv")
        ReportEngine.ensure_notebook_env!(env)
        @test isfile(joinpath(env, "Project.toml"))
    end

    @testset "base/forked/detached mode detection" begin
        base   = ReportEngine.GateKernel("/repo"; parent = "/repo", envdir = "/depot/env")
        forked = ReportEngine.GateKernel("/depot/env"; parent = "/repo", envdir = "/depot/env")
        detach = ReportEngine.GateKernel("/depot/env"; parent = "", envdir = "/depot/env")
        @test ReportEngine._base_mode(base)
        @test !ReportEngine._base_mode(forked)
        @test !ReportEngine._base_mode(detach)
    end

    @testset "parent manifest hash" begin
        d = mktempdir()
        @test ReportEngine._parent_manifest_hash("") == ""
        @test ReportEngine._parent_manifest_hash(d) == ""        # no Manifest yet
        write(joinpath(d, "Manifest.toml"), "julia_version=\"1.12.0\"\n")
        h1 = ReportEngine._parent_manifest_hash(d)
        @test !isempty(h1)
        write(joinpath(d, "Manifest.toml"), "julia_version=\"1.12.0\"\n[[deps.X]]\n")
        @test ReportEngine._parent_manifest_hash(d) != h1        # changes with content
    end
end

# Live help lookup (docs palette ?Module drill-down + cross-reference links).
@testset "module_help" begin
    mh = ReportEngine.module_help
    m = mh(@__MODULE__, "Base")                 # a module → exports list
    @test m["kind"] == "module"
    @test !isempty(m["exports"])
    @test all(haskey(e, "name") && haskey(e, "kind") for e in m["exports"])
    @test any(e["name"] == "sum" for e in m["exports"])           # Base exports sum
    @test any(e["kind"] == "function" for e in m["exports"])

    f = mh(@__MODULE__, "sum")                  # a function → doc, no exports
    @test f["kind"] == "function"
    @test isempty(f["exports"])
    @test occursin("sum", lowercase(f["doc"]))

    bad = mh(@__MODULE__, "no_such_binding_xyz")
    @test bad["kind"] == "unknown" && isempty(bad["exports"]) && bad["doc"] == ""
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
    # Manifest carries Foo as a path-dep at the author's ABSOLUTE path — the bundle must
    # rewrite this to `local/Foo` or an expanded copy fails to instantiate elsewhere.
    write(joinpath(proj, "Manifest.toml"),
        "julia_version=\"1.12.0\"\nmanifest_format=\"2.0\"\n\n[[deps.Foo]]\npath = \"/authors/abs/path/Foo\"\nuuid = \"00000000-0000-0000-0000-000000000001\"\nversion = \"0.1.0\"\n")
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

        # The path-dep entry must now point at the bundled source (relative), not the
        # author's absolute path — otherwise instantiate fails with "Missing source file".
        man = read(joinpath(tdir, "Manifest.toml"), String)
        @test occursin("path = \"local/Foo\"", man)
        @test !occursin("/authors/abs/path/Foo", man)
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

    # A path-dep whose committed-clean source already lives inside the bundled repo is reused
    # straight from the cloned repo/ (Manifest → repo/<rel>), with no redundant local/ copy.
    # A dirty/uncommitted subtree stays conservative and ships its own local/ copy.
    @testset "git-tracked path-dep dedups against repo/" begin
        root = mktempdir()
        mkpath(joinpath(root, "Foo", "src"))
        write(joinpath(root, "Foo", "Project.toml"), "name=\"Foo\"\nuuid=\"00000000-0000-0000-0000-0000000000f0\"\nversion=\"0.1.0\"\n")
        write(joinpath(root, "Foo", "src", "Foo.jl"), "module Foo\nend\n")
        write(joinpath(root, "Project.toml"), "name=\"Demo\"\n[deps]\nFoo=\"00000000-0000-0000-0000-0000000000f0\"\n")
        write(joinpath(root, "Manifest.toml"),
            "manifest_format=\"2.0\"\n\n[[deps.Foo]]\npath = \"$(joinpath(root, "Foo"))\"\nuuid = \"00000000-0000-0000-0000-0000000000f0\"\nversion = \"0.1.0\"\n")
        run(pipeline(`git -C $root init -q`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))
        deps = [(name = "Foo", source = joinpath(root, "Foo"))]

        @testset "clean subtree → reuse repo/, no local copy" begin
            sj = joinpath(mktempdir(), "c.standalone.jl")
            write(sj, "#%% code id=a\nx=1\n\n" * _bundle_footer(_make_bundle_b64(root, deps, "nb.jl", "#%% code id=a\nx=1\n")) * "\n")
            tdir = expand(sj)
            man = read(joinpath(tdir, "Manifest.toml"), String)
            @test occursin("path = \"repo/Foo\"", man)                    # points into the cloned repo
            @test !ispath(joinpath(tdir, "local"))                        # no redundant copy
            @test isfile(joinpath(tdir, "repo", "Foo", "src", "Foo.jl"))  # source rides the git bundle
        end

        @testset "dirty subtree → conservative local copy" begin
            write(joinpath(root, "Foo", "src", "Foo.jl"), "module Foo\n# uncommitted\nend\n")
            sj = joinpath(mktempdir(), "d.standalone.jl")
            write(sj, "#%% code id=a\nx=1\n\n" * _bundle_footer(_make_bundle_b64(root, deps, "nb.jl", "#%% code id=a\nx=1\n")) * "\n")
            tdir = expand(sj)
            man = read(joinpath(tdir, "Manifest.toml"), String)
            @test occursin("path = \"local/Foo\"", man)                   # falls back to a copy
            src = read(joinpath(tdir, "local", "Foo", "src", "Foo.jl"), String)
            @test occursin("uncommitted", src)                           # working-tree bytes, not HEAD
        end
    end

    # The git bundle is gated to project-IS-repo-root: a project merely NESTED inside a larger
    # repo must not drag that whole repo into the bundle (only the project itself travels).
    @testset "nested project does not bundle the enclosing repo" begin
        root = mktempdir()
        sub = joinpath(root, "proj"); mkpath(sub)
        write(joinpath(sub, "Project.toml"), "name=\"Nested\"\n[deps]\n")
        write(joinpath(sub, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        run(pipeline(`git -C $root init -q`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))

        sj = joinpath(mktempdir(), "n.standalone.jl")
        write(sj, "#%% code id=a\nx=1\n\n" * _bundle_footer(_make_bundle_b64(sub, NamedTuple[], "nb.jl", "#%% code id=a\nx=1\n")) * "\n")
        tdir = expand(sj)
        @test !isfile(joinpath(tdir, "repo.gitbundle"))   # enclosing repo NOT captured
        @test !ispath(joinpath(tdir, "repo"))
        @test isfile(joinpath(tdir, "Project.toml"))      # the project itself still travels
    end

    # Package-as-project: the notebook runs in its OWN package's project (project root == repo
    # root). The package's src/ must travel to the expanded project root so `using <Pkg>` resolves
    # there, while repo/ still carries history for collaboration.
    @testset "package-as-project carries its own src to the root" begin
        root = mktempdir()
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Project.toml"), "name=\"Demo\"\nuuid=\"00000000-0000-0000-0000-0000000000d0\"\nversion=\"0.1.0\"\n[deps]\n")
        write(joinpath(root, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        write(joinpath(root, "src", "Demo.jl"), "module Demo\ngreet() = \"hi from Demo\"\nend\n")
        run(pipeline(`git -C $root init -q`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $root -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))

        sj = joinpath(mktempdir(), "p.standalone.jl")
        write(sj, "#%% code id=a\nx=1\n\n" * _bundle_footer(_make_bundle_b64(root, NamedTuple[], "nb.jl", "#%% code id=a\nx=1\n")) * "\n")
        tdir = expand(sj)
        @test isfile(joinpath(tdir, "src", "Demo.jl"))                       # source at the project root
        @test occursin("module Demo", read(joinpath(tdir, "src", "Demo.jl"), String))
        @test isfile(joinpath(tdir, "repo.gitbundle"))                       # repo still bundled too
    end
end

# Content-addressed reconstruction into the depot cache (the "Run (temporary)" engine): same
# bundle ⇒ same dir reused instantly; different bundle ⇒ fresh dir. No git needed.
@testset "bundle reconstruction into the depot cache" begin
    cells = "#%% code id=a\nusing Foo\n"
    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "name=\"Demo\"\n[deps]\n")
    write(joinpath(proj, "Manifest.toml"), "manifest_format=\"2.0\"\n")
    sj = joinpath(mktempdir(), "demo.standalone.jl")
    write(sj, cells * "\n" * _bundle_footer(_make_bundle_b64(proj, NamedTuple[], "demo.jl", cells)) * "\n")

    @test _has_bundle(read(sj, String))
    @test !_has_bundle("#%% code id=a\nx=1\n")

    r1 = _reconstruct_bundle!(sj)
    @test r1.fresh                                       # first time: extracted
    @test occursin("kaimonslate-bundles", r1.dir)        # depot cache, not a sibling dir
    @test isfile(joinpath(r1.dir, "Project.toml"))
    @test isfile(joinpath(r1.dir, "demo.jl"))

    r2 = _reconstruct_bundle!(sj)
    @test !r2.fresh && r2.dir == r1.dir                  # same content → cache hit, reused

    sj2 = joinpath(mktempdir(), "other.standalone.jl")
    write(sj2, cells * "y=2\n\n" * _bundle_footer(_make_bundle_b64(proj, NamedTuple[], "other.jl", cells * "y=2\n")) * "\n")
    r3 = _reconstruct_bundle!(sj2)
    @test r3.dir != r1.dir                               # different content → different dir

    rm(r1.dir; recursive = true, force = true)           # don't litter the depot
    rm(r3.dir; recursive = true, force = true)
end

# Frozen-render preview: the rendered-cells payload round-trips (gzip+base64) and the footer
# block is ignored by parse_report (it's terminal, after the cells / bundle).
@testset "frozen-render preview round-trips" begin
    cells = [Dict("id" => "a", "kind" => "code", "output" => "<pre>42</pre>", "echarts" => [], "tables" => []),
             Dict("id" => "b", "kind" => "md", "output" => "<h1>Title</h1>")]
    sj = "#%% code id=a\nx=1\n\n" * _bundle_footer("AAAA") * "\n" * _preview_footer(cells) * "\n"

    @test [c.id for c in parse_report(sj).cells] == ["a"]     # footer region ignored as cells
    got = _read_preview(sj)
    @test got !== nothing && length(got) == 2
    @test got[1]["id"] == "a" && got[1]["output"] == "<pre>42</pre>"
    @test got[2]["kind"] == "md"
    @test _read_preview("#%% code id=a\nx=1\n") === nothing   # absent → nothing
end
