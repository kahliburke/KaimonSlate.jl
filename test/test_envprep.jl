# Forked-notebook-env seeding policy (src/envprep.jl): which Project.toml sections a fork
# inherits from its parent.
using ReTest
import Pkg   # Pkg.TOML only, as envprep.jl itself does

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine

"Write a parent project with `body` appended after its [deps], and seed a fork from it."
function seed_from(body::AbstractString)
    parent = mktempdir()
    write(joinpath(parent, "Project.toml"), """
    name = "Parent"
    uuid = "11111111-1111-1111-1111-111111111111"

    [deps]
    Statistics = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"

    $body
    """)
    envdir = mktempdir()
    pname = ReportEngine.seed_env_project!(envdir, parent)
    return (; pname, seeded = Pkg.TOML.parsefile(joinpath(envdir, "Project.toml")))
end

@testset "seed_env_project!" begin

    @testset "carries the sections [compat] is allowed to name" begin
        # Pkg REJECTS a compat entry naming nothing the project declares. Seeding compat
        # while dropping weakdeps/extras made every parent with a weakdep unforkable, and
        # the error named the fork rather than the parent it came from.
        r = seed_from("""
        [weakdeps]
        Widget = "22222222-2222-2222-2222-222222222222"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [compat]
        Statistics = "1"
        Widget = "0.1.9"
        Test = "1"
        """)
        @test haskey(r.seeded, "weakdeps")
        @test haskey(r.seeded, "extras")
        @test r.seeded["weakdeps"]["Widget"] == "22222222-2222-2222-2222-222222222222"
        @test r.seeded["extras"]["Test"] == "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        # Every compat name resolves to something the fork declares, which is the property
        # Pkg actually checks.
        declared = union(keys(get(r.seeded, "deps", Dict())),
                         keys(get(r.seeded, "weakdeps", Dict())),
                         keys(get(r.seeded, "extras", Dict())))
        @test all(n -> n in declared, keys(r.seeded["compat"]))
    end

    @testset "absent sections stay absent" begin
        r = seed_from("""
        [compat]
        Statistics = "1"
        """)
        @test !haskey(r.seeded, "weakdeps")
        @test !haskey(r.seeded, "extras")
        @test r.seeded["deps"]["Statistics"] == "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
    end

    @testset "a rebuild puts the notebook's own packages back" begin
        # Seeding rebuilds the fork from the PARENT, which knows nothing about what the notebook
        # added — so a parent Project.toml edit stales the fork, the rebuild re-seeds, and every
        # package the notebook installed disappears. The failure lands at the notebook's first
        # `using`, far from the upstream edit that caused it.
        delta = [Dict{String,Any}("name" => "FFTW", "version" => "1.10.0",
                                  "uuid" => "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"),
                 Dict{String,Any}("name" => "NNlib", "version" => "0.9.43",
                                  "uuid" => "872c559c-99b0-510c-b3b7-b6c96a88d5cd")]
        code = ReportEngine.env_add_code(delta)
        @test occursin("Pkg.add(", code)
        @test occursin("name=raw\"FFTW\"", code)
        @test occursin("uuid=raw\"7a1cc6ca-52ef-59f5-83cd-3a7055c09341\"", code)
        @test occursin("name=raw\"NNlib\"", code)
        # The recorded VERSION is deliberately not pinned — it would fight the parent's fresh resolve.
        @test !occursin("1.10.0", code)
        # A notebook that added nothing rebuilds exactly as before.
        @test ReportEngine.env_add_code(Dict{String,Any}[]) == ""
        @test ReportEngine.env_add_code(nothing) == ""
    end

    @testset "a named parent is reported, and the fork is not itself a package" begin
        r = seed_from("")
        @test r.pname == "Parent"
        # The fork inherits sections, never the parent's identity: carrying name/uuid would
        # make the scratch env claim to BE the parent.
        @test !haskey(r.seeded, "name")
        @test !haskey(r.seeded, "uuid")
    end

end

# ── workspaces ────────────────────────────────────────────────────────────────
# A notebook in a workspace member (`[workspace] projects = ["papers"]` in an ancestor) has no
# manifest beside its Project.toml — the workspace shares ONE at the root, under a possibly
# versioned name — and inherits the root's `[sources]`. Seeding a fork from the member's own
# Project.toml alone produced an env that could not resolve an unregistered dep the member could:
# "expected package `X` to be registered".

const WIDGET_UUID = "11111111-2222-3333-4444-555555555555"
_manifest_vname() = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"

"A workspace: root (deps/sources/compat for an unregistered `Widget`) + a `papers` member."
function workspace_fixture(; manifest_name = _manifest_vname(), member_extra = "")
    root = mktempdir()
    mkpath(joinpath(root, "papers"))
    mkpath(joinpath(root, "lib", "Widget"))
    write(joinpath(root, "Project.toml"), """
    [workspace]
    projects = ["papers"]

    [deps]
    Widget = "$WIDGET_UUID"

    [sources]
    Widget = {path = "lib/Widget"}

    [compat]
    Widget = "0.1"
    julia = "1.10"
    """)
    write(joinpath(root, "papers", "Project.toml"), """
    [deps]
    Widget = "$WIDGET_UUID"

    $member_extra
    """)
    # Path deps in a shared manifest are relative to the MANIFEST's dir (the workspace root).
    write(joinpath(root, manifest_name), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"
    project_hash = "deadbeef"

    [[deps.Widget]]
    path = "lib/Widget"
    uuid = "$WIDGET_UUID"
    version = "0.1.0"
    """)
    return root
end

@testset "workspace members" begin

    @testset "the resolving manifest is the workspace root's, under any name" begin
        root = workspace_fixture()
        member = joinpath(root, "papers")
        # The member has no manifest of its own; looking beside its Project.toml finds nothing.
        @test !isfile(joinpath(member, "Manifest.toml"))
        @test ReportEngine.parent_manifest(member) == joinpath(root, _manifest_vname())
        @test ReportEngine.workspace_chain(joinpath(member, "Project.toml")) ==
              [joinpath(root, "Project.toml")]
        # Plain `Manifest.toml` at the root is found too.
        root2 = workspace_fixture(manifest_name = "Manifest.toml")
        @test ReportEngine.parent_manifest(joinpath(root2, "papers")) ==
              joinpath(root2, "Manifest.toml")
        # A project that is NOT a member keeps the sibling-manifest behaviour.
        plain = mktempdir()
        write(joinpath(plain, "Project.toml"), "[deps]\n")
        write(joinpath(plain, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        @test ReportEngine.parent_manifest(plain) == joinpath(plain, "Manifest.toml")
        @test isempty(ReportEngine.workspace_chain(joinpath(plain, "Project.toml")))
    end

    @testset "a fork inherits the workspace root's sources and compat" begin
        root = workspace_fixture()
        envdir = mktempdir()
        ReportEngine.seed_env_project!(envdir, joinpath(root, "papers"))
        seeded = Pkg.TOML.parsefile(joinpath(envdir, "Project.toml"))
        # Without this the fork declares an unregistered UUID with no source and cannot resolve it.
        @test haskey(seeded, "sources") && haskey(seeded["sources"], "Widget")
        # Root `[sources]` paths are relative to the ROOT, not the member.
        @test seeded["sources"]["Widget"]["path"] == abspath(joinpath(root, "lib", "Widget"))
        @test seeded["compat"]["Widget"] == "0.1"
        @test seeded["compat"]["julia"] == "1.10"
    end

    @testset "the member's own entries win over the root's" begin
        root = workspace_fixture(member_extra = """
        [sources]
        Widget = {path = "../vendored/Widget"}

        [compat]
        Widget = "0.2"
        """)
        envdir = mktempdir()
        ReportEngine.seed_env_project!(envdir, joinpath(root, "papers"))
        seeded = Pkg.TOML.parsefile(joinpath(envdir, "Project.toml"))
        @test seeded["sources"]["Widget"]["path"] == abspath(joinpath(root, "vendored", "Widget"))
        @test seeded["compat"]["Widget"] == "0.2"
    end

    @testset "inherited entries naming an undeclared package are dropped" begin
        # Pkg REJECTS a sources/compat entry naming nothing the project declares, and the error
        # names the fork rather than the workspace it came from. The root legitimately carries
        # entries for its OTHER members, so this filter is what keeps the fork loadable.
        root = mktempdir()
        mkpath(joinpath(root, "papers"))
        write(joinpath(root, "Project.toml"), """
        [workspace]
        projects = ["papers"]

        [deps]
        Elsewhere = "99999999-9999-9999-9999-999999999999"

        [sources]
        Elsewhere = {path = "lib/Elsewhere"}

        [compat]
        Elsewhere = "1"
        """)
        write(joinpath(root, "papers", "Project.toml"), "[deps]\nWidget = \"$WIDGET_UUID\"\n")
        envdir = mktempdir()
        ReportEngine.seed_env_project!(envdir, joinpath(root, "papers"))
        seeded = Pkg.TOML.parsefile(joinpath(envdir, "Project.toml"))
        declared = keys(get(seeded, "deps", Dict()))
        @test !("Elsewhere" in declared)
        @test all(n -> n in declared, keys(get(seeded, "sources", Dict())))
        @test all(n -> n == "julia" || n in declared, keys(get(seeded, "compat", Dict())))
    end

    @testset "the copied manifest is adapted to the fork" begin
        root = workspace_fixture()
        envdir = mktempdir()
        ReportEngine.seed_env_project!(envdir, joinpath(root, "papers"))
        man = joinpath(envdir, "Manifest.toml")
        @test isfile(man)
        m = Pkg.TOML.parsefile(man)
        # Anchored on the MANIFEST's dir (the workspace root) — anchoring on the member would
        # point at papers/lib/Widget, which does not exist.
        @test m["deps"]["Widget"][1]["path"] == abspath(joinpath(root, "lib", "Widget"))
        # A workspace `project_hash` covers the whole workspace and never matches a single-project
        # fork; left in, Pkg calls the fork unresolved forever and re-resolves on every later add.
        @test !haskey(m, "project_hash")
    end

    @testset "the fingerprint covers the workspace, and is unchanged for a plain project" begin
        root = workspace_fixture()
        member = joinpath(root, "papers")
        f0 = ReportEngine.env_parent_fingerprint(member)
        # An edit to the workspace ROOT changes what the fork was seeded from, so it must stale it.
        write(joinpath(root, "Project.toml"),
              read(joinpath(root, "Project.toml"), String) * "\n[extras]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n")
        @test ReportEngine.env_parent_fingerprint(member) != f0
        # …as does a re-resolve of the shared manifest.
        f1 = ReportEngine.env_parent_fingerprint(member)
        write(joinpath(root, _manifest_vname()),
              read(joinpath(root, _manifest_vname()), String) * "\n[[deps.Other]]\n")
        @test ReportEngine.env_parent_fingerprint(member) != f1
        # For an ordinary project the hash is over the same bytes in the same order as before the
        # workspace support, so upgrading doesn't stale every existing fork.
        plain = mktempdir()
        write(joinpath(plain, "Project.toml"), "[deps]\nStatistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n")
        write(joinpath(plain, "Manifest.toml"), "manifest_format = \"2.0\"\n")
        io = IOBuffer()
        for f in ("Project.toml", "Manifest.toml"); write(io, read(joinpath(plain, f))); end
        @test ReportEngine.env_parent_fingerprint(plain) == string(hash(take!(io)); base = 16)
    end

end
