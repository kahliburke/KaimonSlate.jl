# Reproducibility: the `.jl` env-delta footer (engine) and the self-contained bundle
# (export_bundle). Run:  julia --startup-file=no test/test_repro.jl
using ReTest, Base64, JSON, CodecZlib

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

# Per-notebook durable settings (Slate.config footer) — incl. the new `agentmodel` override that
# travels with the file. Typed round-trip through report.meta, idempotent serialize, no leakage.
@testset "per-notebook config footer (Slate.config)" begin
    src = "#%% code id=a\nx = 1\n\n" *
          "# ╔═╡ Slate.config · per-notebook settings (Settings panel)\n" *
          "#   agentmodel = opus\n#   parallel = false\n#   slidelevel = 3\n" *
          "#   publishrepo = kahli/site\n#   publishslug = my-doc\n# ╚═╡\n"
    r = parse_report(src)
    @test length(r.cells) == 1                       # config footer is not a cell
    @test r.meta["agentmodel"] == "opus"             # :string
    @test r.meta["parallel"] === false               # :bool coerced
    @test r.meta["slidelevel"] === 3                 # :int coerced
    @test r.meta["publishrepo"] == "kahli/site"      # remembered publish target
    @test r.meta["publishslug"] == "my-doc"

    s1 = serialize_report(r)
    @test occursin("agentmodel = opus", s1)
    @test occursin("publishrepo = kahli/site", s1)
    @test parse_report(s1).meta["agentmodel"] == "opus"      # idempotent
    @test parse_report(s1).meta["publishrepo"] == "kahli/site"

    r2 = parse_report("#%% code id=a\nx=1\n")         # no config → no footer, no keys
    @test !haskey(r2.meta, "agentmodel")
    @test !occursin("Slate.config", serialize_report(r2))
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

# Make `git` discoverable even under a minimal GUI-launched PATH (macOS apps often omit
# /opt/homebrew/bin, so a gate/test subprocess can miss git), so these tests actually run
# in the harness instead of silently skipping.
let g = Sys.which("git")
    if g === nothing
        for c in ("/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git")
            if isfile(c)
                ENV["PATH"] = dirname(c) * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")
                break
            end
        end
    end
end

# Git bundle + repo-rooted expand tests. A LOUD warning (never a silent skip) when git is absent.
if Sys.which("git") !== nothing
    # Repo-rooted stays robust when a path-dep is `dev`'d from OUTSIDE the repo: the repo is still
    # bundled as the root and the external dep is vendored into `local/` (Manifest rewritten) — an
    # external dev-dep no longer forces the flat layout. And the checkout is CLEAN: a real branch,
    # a working `git log` (full-history bundle, no broken shallow graft), no dangling `origin`, and
    # Slate's `.slatebundle.json` locally ignored — no legacy `repo/` subdir.
    @testset "repo-rooted: external dev-dep vendored + clean git checkout" begin
        repo = mktempdir()
        mkpath(joinpath(repo, "src")); mkpath(joinpath(repo, "notebooks"))
        write(joinpath(repo, "Project.toml"),
            "name=\"Demo\"\nuuid=\"00000000-0000-0000-0000-0000000000d0\"\nversion=\"0.1.0\"\n[deps]\nFoo=\"00000000-0000-0000-0000-0000000000f0\"\n")
        write(joinpath(repo, "src", "Demo.jl"), "module Demo\nend\n")
        foo = mktempdir(); mkpath(joinpath(foo, "src"))              # Foo lives OUTSIDE the repo
        write(joinpath(foo, "Project.toml"), "name=\"Foo\"\nuuid=\"00000000-0000-0000-0000-0000000000f0\"\nversion=\"0.1.0\"\n")
        write(joinpath(foo, "src", "Foo.jl"), "module Foo\nend\n")
        write(joinpath(repo, "Manifest.toml"),
            "manifest_format=\"2.0\"\n\n[[deps.Foo]]\npath = \"$(foo)\"\nuuid = \"00000000-0000-0000-0000-0000000000f0\"\nversion = \"0.1.0\"\n")
        write(joinpath(repo, "notebooks", "nb.jl"), "#%% code id=a\nx=1\n")
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))

        nbpath = joinpath(repo, "notebooks", "nb.jl")
        deps = [(name = "Foo", source = foo)]
        cells = "#%% code id=a\nx=2\n"
        sj = joinpath(mktempdir(), "nb.standalone.jl")
        write(sj, cells * "\n" * _bundle_footer(_make_bundle_b64(repo, deps, nbpath, cells)) * "\n")
        tdir = expand(sj)

        @test isdir(joinpath(tdir, ".git"))                                   # git checkout at the ROOT
        @test !ispath(joinpath(tdir, "repo"))                                 # no legacy repo/ hybrid
        @test isfile(joinpath(tdir, "local", "Foo", "src", "Foo.jl"))         # external dep vendored INTO the checkout
        man = read(joinpath(tdir, "Manifest.toml"), String)
        @test occursin("local/Foo", man) && !occursin(foo, man)              # rewritten, no abs-path leak
        @test strip(read(`git -C $tdir rev-parse --abbrev-ref HEAD`, String)) != "HEAD"   # on a real branch
        @test !isempty(strip(read(pipeline(`git -C $tdir log --oneline`; stderr = devnull), String)))   # log works
        @test isempty(strip(read(`git -C $tdir remote`, String)))            # no dangling origin (no remote)
        @test !occursin(".slatebundle.json", read(`git -C $tdir status --porcelain`, String))   # locally ignored
    end

    # When the repo HAS an origin remote, expand wires `origin` to it (matching SHAs → branch & PR).
    @testset "repo-rooted: origin wired to the real remote" begin
        repo = mktempdir()
        mkpath(joinpath(repo, "notebooks"))
        write(joinpath(repo, "Project.toml"), "name=\"Demo\"\nuuid=\"00000000-0000-0000-0000-0000000000d1\"\nversion=\"0.1.0\"\n[deps]\n")
        write(joinpath(repo, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        write(joinpath(repo, "notebooks", "nb.jl"), "#%% code id=a\nx=1\n")
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))
        run(pipeline(`git -C $repo remote add origin https://example.com/demo.git`; stderr = devnull))
        nbpath = joinpath(repo, "notebooks", "nb.jl")
        sj = joinpath(mktempdir(), "nb.standalone.jl")
        write(sj, "#%% code id=a\nx=1\n\n" * _bundle_footer(_make_bundle_b64(repo, NamedTuple[], nbpath, "#%% code id=a\nx=1\n")) * "\n")
        tdir = expand(sj)
        @test strip(read(`git -C $tdir remote get-url origin`, String)) == "https://example.com/demo.git"
        @test strip(read(`git -C $repo rev-parse HEAD`, String)) == strip(read(`git -C $tdir rev-parse HEAD`, String))
    end

    # Repo-rooted: the notebook + its env live INSIDE a git repo (the WindowPrimes.jl/notebooks case),
    # and the package it uses is that same repo. `expand` must reproduce the REAL project structure —
    # the repo at the root (its src/ + notebooks/), the notebook back in its subdir, the {path=".."}
    # source intact — NOT a wrapper with a vendored local/ package.
    @testset "repo-rooted: expand reproduces the project (package root + notebook subdir)" begin
        repo = mktempdir()
        mkpath(joinpath(repo, "src")); mkpath(joinpath(repo, "notebooks"))
        write(joinpath(repo, "Project.toml"), "name=\"WinP\"\nuuid=\"00000000-0000-0000-0000-0000000000a1\"\nversion=\"0.1.0\"\n[deps]\n")
        write(joinpath(repo, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        write(joinpath(repo, "src", "WinP.jl"), "module WinP\ngo() = 42\nend\n")
        # notebook env: its OWN Project (deps + a {path=\"..\"} source), Manifest, and the notebook.
        write(joinpath(repo, "notebooks", "Project.toml"),
            "[deps]\nWinP = \"00000000-0000-0000-0000-0000000000a1\"\n\n[sources]\nWinP = {path = \"..\"}\n")
        write(joinpath(repo, "notebooks", "Manifest.toml"),
            "manifest_format=\"2.0\"\n\n[[deps.WinP]]\npath = \"..\"\nuuid = \"00000000-0000-0000-0000-0000000000a1\"\nversion = \"0.1.0\"\n")
        write(joinpath(repo, "notebooks", "presentation.jl"), "#%% code id=a\nx=1\n")
        write(joinpath(repo, "notebooks", "references.bib"), "@book{k,title={T}}\n")
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))
        run(pipeline(`git -C $repo remote add origin https://example.com/winp.git`; stderr = devnull))

        envdir = joinpath(repo, "notebooks")
        nbpath = joinpath(envdir, "presentation.jl")
        deps = [(name = "WinP", source = repo)]                      # the package IS the repo root
        cells = "#%% code id=a\nx=2\n"                               # LIVE cells differ from the committed file
        b64 = _make_bundle_b64(envdir, deps, nbpath, cells)
        sj = joinpath(mktempdir(), "presentation.standalone.jl")
        write(sj, cells * "\n" * _bundle_footer(b64) * "\n")
        tdir = expand(sj)

        @test isdir(joinpath(tdir, ".git"))                          # a real git checkout at the ROOT
        @test isfile(joinpath(tdir, "src", "WinP.jl"))               # the package lives at the root
        @test isfile(joinpath(tdir, "notebooks", "presentation.jl")) # notebook back in its subdir
        @test isfile(joinpath(tdir, "notebooks", "references.bib"))  # committed sibling files survive the overlay
        @test !ispath(joinpath(tdir, "local"))                       # NO vendored local/ package
        @test !isfile(joinpath(tdir, "presentation.jl"))             # NOT flattened to the root
        # the {path=".."} source is untouched (resolves to the package at the repo root)
        @test occursin("path = \"..\"", read(joinpath(tdir, "notebooks", "Manifest.toml"), String))
        @test occursin("{path = \"..\"}", read(joinpath(tdir, "notebooks", "Project.toml"), String))
        # the overlay wins: the expanded notebook carries the LIVE cells, not the committed ones
        @test occursin("x=2", read(joinpath(tdir, "notebooks", "presentation.jl"), String))
        @test strip(read(`git -C $tdir remote get-url origin`, String)) == "https://example.com/winp.git"
        # matching SHAs — ready to branch & PR
        @test strip(read(`git -C $repo rev-parse HEAD`, String)) == strip(read(`git -C $tdir rev-parse HEAD`, String))
        @test !ispath(joinpath(tdir, "repo"))                        # no legacy repo/ hybrid
        @test strip(read(`git -C $tdir rev-parse --abbrev-ref HEAD`, String)) != "HEAD"   # a real branch, not detached
        @test !isempty(strip(read(pipeline(`git -C $tdir log --oneline`; stderr = devnull), String)))   # git log works

        # reconstruct coords point the kernel at the notebook env (nested), with the repo root as parent
        co = _read_coords(tdir)
        @test co.envdir == joinpath(tdir, "notebooks") && co.parent == tdir
        @test co.notebook == joinpath(tdir, "notebooks", "presentation.jl")
    end

    # Forked-env repo-rooted (the MicrocavitySeries.jl case): the notebook lives inside a git package
    # repo (`MyPkg/notebooks/nb.jl`) but its active env is a depot FORK *outside* the repo that `dev`s
    # the package (path-dep at the repo root) plus an EXTERNAL dep. The env's own git-toplevel is
    # `nothing`, so this used to fall to the flat layout (losing src/ and the git structure). Now expand
    # must clone the package as the ROOT (src/, notebooks/), stage the forked env under `_slate_env/`
    # with the parent `dev`'d at `..` and the external dep vendored to `local/`.
    @testset "repo-rooted: forked depot env dev'ing the parent package" begin
        repo = mktempdir()
        mkpath(joinpath(repo, "src")); mkpath(joinpath(repo, "notebooks"))
        write(joinpath(repo, "Project.toml"),
            "name=\"MyPkg\"\nuuid=\"00000000-0000-0000-0000-0000000000b1\"\nversion=\"0.1.0\"\n[deps]\n")
        write(joinpath(repo, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        write(joinpath(repo, "src", "MyPkg.jl"), "module MyPkg\ngo() = 7\nend\n")
        write(joinpath(repo, "notebooks", "nb.jl"), "#%% code id=a\nx=1\n")
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))

        ext = mktempdir(); mkpath(joinpath(ext, "src"))              # an EXTERNAL dep, outside the repo
        write(joinpath(ext, "Project.toml"), "name=\"Ext\"\nuuid=\"00000000-0000-0000-0000-0000000000e1\"\nversion=\"0.1.0\"\n")
        write(joinpath(ext, "src", "Ext.jl"), "module Ext\nend\n")
        write(joinpath(ext, "junk.dat"), "x"^2048)                   # data bloat: must NOT ride along

        env = mktempdir()                                            # the depot FORK — OUTSIDE the repo
        write(joinpath(env, "Project.toml"),
            "[deps]\nMyPkg = \"00000000-0000-0000-0000-0000000000b1\"\nExt = \"00000000-0000-0000-0000-0000000000e1\"\n")
        write(joinpath(env, "Manifest.toml"),
            "manifest_format=\"2.0\"\n\n[[deps.MyPkg]]\npath = \"$(repo)\"\nuuid = \"00000000-0000-0000-0000-0000000000b1\"\nversion = \"0.1.0\"\n" *
            "\n[[deps.Ext]]\npath = \"$(ext)\"\nuuid = \"00000000-0000-0000-0000-0000000000e1\"\nversion = \"0.1.0\"\n")

        nbpath = joinpath(repo, "notebooks", "nb.jl")
        deps = [(name = "MyPkg", source = repo), (name = "Ext", source = ext)]
        cells = "#%% code id=a\nx=2\n"                               # LIVE cells differ from committed
        b64 = _make_bundle_b64(env, deps, nbpath, cells)
        sj = joinpath(mktempdir(), "nb.standalone.jl")
        write(sj, cells * "\n" * _bundle_footer(b64) * "\n")
        tdir = expand(sj)

        @test isdir(joinpath(tdir, ".git"))                          # the package cloned as the ROOT
        @test isfile(joinpath(tdir, "src", "MyPkg.jl"))              # src/ travels (was lost in flat)
        @test isfile(joinpath(tdir, "notebooks", "nb.jl"))          # notebook back in its subdir
        @test !isfile(joinpath(tdir, "nb.jl"))                       # NOT flattened to the root
        @test isfile(joinpath(tdir, "_slate_env", "Manifest.toml"))  # forked env staged in its own dir
        @test occursin("x=2", read(joinpath(tdir, "notebooks", "nb.jl"), String))   # live cells win
        man = read(joinpath(tdir, "_slate_env", "Manifest.toml"), String)
        @test occursin("path = \"..\"", man)                         # parent dev'd at the repo root
        @test occursin("../local/Ext", man)                          # external dep, relative to the env dir
        @test !occursin(repo, man) && !occursin(ext, man)            # no author-absolute path leak
        @test isfile(joinpath(tdir, "local", "Ext", "src", "Ext.jl")) # external source vendored
        @test !isfile(joinpath(tdir, "local", "Ext", "junk.dat"))    # …source only, no data bloat
        # coords: kernel activates the forked env, parent is the repo root, notebook in its subdir
        co = _read_coords(tdir)
        @test co.envdir == joinpath(tdir, "_slate_env") && co.parent == tdir
        @test co.notebook == joinpath(tdir, "notebooks", "nb.jl")
        # the reconstruction scaffolding is locally ignored (the notebook itself legitimately shows
        # modified — it carries the LIVE cells — so `git status` is not empty, just free of our dirs)
        status = read(pipeline(`git -C $tdir status --porcelain`; stderr = devnull), String)
        @test !occursin("_slate_env", status) && !occursin("local/", status) && !occursin(".slatebundle", status)
        @test occursin("notebooks/nb.jl", status)                    # the live-cell edit is the only change
    end

    # Source-rooted (history=false): the SAME reconstructed structure as repo-rooted, but the repo's
    # tracked SOURCE is staged directly (no `.git`, no commit history published) — the safe default for
    # a PUBLIC web export. Still fully runnable (env + vendored deps + live cells in place).
    @testset "source-rooted: history=false ships source, not the git history" begin
        repo = mktempdir()
        mkpath(joinpath(repo, "src")); mkpath(joinpath(repo, "notebooks"))
        write(joinpath(repo, "Project.toml"),
            "name=\"MyPkg\"\nuuid=\"00000000-0000-0000-0000-0000000000c1\"\nversion=\"0.1.0\"\n[deps]\n")
        write(joinpath(repo, "Manifest.toml"), "manifest_format=\"2.0\"\n")
        write(joinpath(repo, "src", "MyPkg.jl"), "module MyPkg\nend\n")
        write(joinpath(repo, "notebooks", "nb.jl"), "#%% code id=a\nx=1\n")
        write(joinpath(repo, "secret.env"), "TOKEN=hunter2\n")        # committed then DELETED: must not resurface
        run(pipeline(`git -C $repo init -q`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t add -A`; stderr = devnull))
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t commit -q -m init`; stderr = devnull))
        rm(joinpath(repo, "secret.env"))                             # no longer tracked in the working tree
        run(pipeline(`git -C $repo -c user.email=t@t -c user.name=t rm -q --cached secret.env`; stderr = devnull))

        ext = mktempdir(); mkpath(joinpath(ext, "src"))
        write(joinpath(ext, "Project.toml"), "name=\"Ext\"\nuuid=\"00000000-0000-0000-0000-0000000000e2\"\nversion=\"0.1.0\"\n")
        write(joinpath(ext, "src", "Ext.jl"), "module Ext\nend\n")
        env = mktempdir()
        write(joinpath(env, "Project.toml"),
            "[deps]\nMyPkg = \"00000000-0000-0000-0000-0000000000c1\"\nExt = \"00000000-0000-0000-0000-0000000000e2\"\n")
        write(joinpath(env, "Manifest.toml"),
            "manifest_format=\"2.0\"\n\n[[deps.MyPkg]]\npath = \"$(repo)\"\nuuid = \"00000000-0000-0000-0000-0000000000c1\"\nversion = \"0.1.0\"\n" *
            "\n[[deps.Ext]]\npath = \"$(ext)\"\nuuid = \"00000000-0000-0000-0000-0000000000e2\"\nversion = \"0.1.0\"\n")

        nbpath = joinpath(repo, "notebooks", "nb.jl")
        deps = [(name = "MyPkg", source = repo), (name = "Ext", source = ext)]
        cells = "#%% code id=a\nx=2\n"
        b64 = _make_bundle_b64(env, deps, nbpath, cells; history = false)
        sj = joinpath(mktempdir(), "nb.standalone.jl")
        write(sj, cells * "\n" * _bundle_footer(b64) * "\n")
        tdir = expand(sj)

        @test !ispath(joinpath(tdir, ".git"))                        # NO git → no commit history published
        @test !isfile(joinpath(tdir, "repo.gitbundle"))              # no git bundle scaffolding
        @test isfile(joinpath(tdir, "src", "MyPkg.jl"))              # source travels (runnable structure)
        @test isfile(joinpath(tdir, "notebooks", "nb.jl"))          # notebook in its subdir
        @test occursin("x=2", read(joinpath(tdir, "notebooks", "nb.jl"), String))   # live cells
        @test !isfile(joinpath(tdir, "secret.env"))                  # a since-deleted committed file stays gone
        @test isfile(joinpath(tdir, "_slate_env", "Manifest.toml"))
        man = read(joinpath(tdir, "_slate_env", "Manifest.toml"), String)
        @test occursin("path = \"..\"", man) && occursin("../local/Ext", man)
        @test !occursin(repo, man) && !occursin(ext, man)            # no author-absolute path leak
        @test isfile(joinpath(tdir, "local", "Ext", "src", "Ext.jl"))
        co = _read_coords(tdir)
        @test co.envdir == joinpath(tdir, "_slate_env") && co.parent == tdir
        @test co.notebook == joinpath(tdir, "notebooks", "nb.jl")
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

    # Package-as-project via the FLAT layout (the notebook here is a bare filename, not inside the
    # repo, so it doesn't qualify for repo-rooted): the package's src/ must still travel to the
    # expanded project root so `using <Pkg>` resolves there. FLAT is git-free (no repo.gitbundle).
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
        @test !isfile(joinpath(tdir, "repo.gitbundle"))                      # FLAT is git-free
        @test !ispath(joinpath(tdir, "repo"))                                # no repo/ subdir
    end
else
    @warn "test_repro: `git` not found on PATH — SKIPPING the git bundle + repo-rooted expand \
           tests. They are NOT being covered; install git or fix PATH to run them."
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

    # The cache is content-addressed and persists in the depot — clear this bundle's dir so `fresh`
    # is deterministic regardless of a prior run (or a prior errored run that skipped the cleanup).
    rm(_bundle_cache_dir(_read_bundle_b64(read(sj, String))); recursive = true, force = true)
    r1 = _reconstruct_bundle!(sj)
    @test r1.fresh                                       # first time: extracted
    @test occursin("kaimonslate-bundles", r1.root)       # depot cache, not a sibling dir
    @test r1.envdir == r1.root && r1.parent == ""        # flat bundle → env is the root, no parent
    @test isfile(joinpath(r1.root, "Project.toml"))
    @test isfile(joinpath(r1.root, "demo.jl"))

    r2 = _reconstruct_bundle!(sj)
    @test !r2.fresh && r2.root == r1.root                # same content → cache hit, reused

    sj2 = joinpath(mktempdir(), "other.standalone.jl")
    write(sj2, cells * "y=2\n\n" * _bundle_footer(_make_bundle_b64(proj, NamedTuple[], "other.jl", cells * "y=2\n")) * "\n")
    r3 = _reconstruct_bundle!(sj2)
    @test r3.root != r1.root                             # different content → different dir

    rm(r1.root; recursive = true, force = true)          # don't litter the depot
    rm(r3.root; recursive = true, force = true)
end

# A truncated / incompatible bundle (e.g. an OLD-format standalone) must fail with an actionable
# message, not a raw `EOFError: read end of file` in the hydrate banner.
@testset "corrupt/incompatible bundle → actionable error, not EOFError" begin
    cells = "#%% code id=a\nusing Foo\n"
    proj = mktempdir()
    write(joinpath(proj, "Project.toml"), "name=\"Demo\"\n[deps]\n")
    write(joinpath(proj, "Manifest.toml"), "manifest_format=\"2.0\"\n")
    b64 = _make_bundle_b64(proj, NamedTuple[], "demo.jl", cells)
    half = length(b64) ÷ 2
    truncated = b64[1:(half - half % 4)]                 # chop the payload (stay base64-length-valid)
    sj = joinpath(mktempdir(), "corrupt.standalone.jl")
    write(sj, cells * "\n" * _bundle_footer(truncated) * "\n")
    rm(_bundle_cache_dir(_read_bundle_b64(read(sj, String))); recursive = true, force = true)
    e = try; _reconstruct_bundle!(sj); nothing; catch err; err; end
    @test e !== nothing
    msg = sprint(showerror, e)
    @test occursin("incompatible Slate version", msg)    # actionable
    @test !startswith(msg, "EOFError")                   # NOT the cryptic raw error
end

# A path-dep's data/computed files (a `bowtie_search/`, a gitignored `output/`, a stray 60 MB
# `test.out`) must NOT ride into the bundle — that ballooned a real notebook's standalone to 100 MB+.
@testset "path-dep vendoring ships source, drops data bloat" begin
    # non-git dep → ships *.toml + src/, drops a data dir + stray top-level file
    d = mktempdir()
    write(joinpath(d, "Project.toml"), "name=\"D2\"\n")
    mkpath(joinpath(d, "src")); write(joinpath(d, "src", "D2.jl"), "module D2 end")
    mkpath(joinpath(d, "data")); write(joinpath(d, "data", "big.bin"), zeros(UInt8, 2_000_000))
    write(joinpath(d, "stray.out"), zeros(UInt8, 2_000_000))
    dest = mktempdir(); _copy_dep_source!(dest, d)
    @test isfile(joinpath(dest, "Project.toml")) && isfile(joinpath(dest, "src", "D2.jl"))
    @test !ispath(joinpath(dest, "data")) && !isfile(joinpath(dest, "stray.out"))

    if Sys.which("git") !== nothing
        # git dep → tracked source shipped (incl. tracked non-src like README); untracked + ignored dropped
        g = mktempdir()
        write(joinpath(g, "Project.toml"), "name=\"G\"\n"); write(joinpath(g, "README.md"), "hi")
        mkpath(joinpath(g, "src")); write(joinpath(g, "src", "G.jl"), "module G end")
        write(joinpath(g, ".gitignore"), "output/\n")
        mkpath(joinpath(g, "output")); write(joinpath(g, "output", "o.dat"), zeros(UInt8, 2_000_000))
        write(joinpath(g, "test.out"), zeros(UInt8, 2_000_000))     # untracked, not ignored
        run(pipeline(`git -C $g init -q`; stderr = devnull))
        run(pipeline(`git -C $g add Project.toml README.md src .gitignore`; stderr = devnull))
        dest2 = mktempdir(); _copy_dep_source!(dest2, g)
        @test isfile(joinpath(dest2, "src", "G.jl")) && isfile(joinpath(dest2, "README.md"))  # tracked kept
        @test !isfile(joinpath(dest2, "test.out")) && !ispath(joinpath(dest2, "output"))      # untracked/ignored dropped
    end
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
