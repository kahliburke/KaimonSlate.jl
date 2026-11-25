# Rebuilding a notebook's fork from its project (src/server.jl `_rebuild_notebook_env!`): a rebuild that
# fails puts the fork back as it was and says why on the notebook; one that succeeds clears that.
# The Pkg cases run real Pkg in a subprocess, as the hub does.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

const CAIRO = "13f3f980-e62b-5c42-98c6-ff1f3baf88f0"

function project_dir(body::AbstractString)
    d = mktempdir()
    write(joinpath(d, "Project.toml"), body)
    return d
end

function fork_with(files::Pair...)
    env = mktempdir()
    for (f, s) in files
        write(joinpath(env, f), s)
    end
    return env
end

fork_files(env) = Dict(f => read(joinpath(env, f), String)
                       for f in ("Project.toml", "Manifest.toml") if isfile(joinpath(env, f)))

@testset "a fork rebuild that is refused keeps the fork and names the project's file" begin
    # A [compat] entry whose [deps] line was removed by hand: Pkg rejects the project, and its error
    # named the fork's copy of the file.
    parent = project_dir("[deps]\nStatistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n[compat]\nGLMakie = \"0.13\"\n")
    env = fork_with("Project.toml" => "[deps]\nMine = \"33333333-3333-3333-3333-333333333333\"\n",
                    "Manifest.toml" => "# the fork's own\n")
    before = fork_files(env)
    said = String[]
    ok = NS._rebuild_notebook_env!(env, parent; online = l -> push!(said, l))
    problem = RE.env_problem(env)
    @test !ok
    @test fork_files(env) == before
    @test occursin("not updated from its project", problem) && occursin(joinpath(parent, "Project.toml"), problem)
    @test any(occursin("Compat `GLMakie`", l) for l in said)
end

@testset "a fork rebuild that fails in Pkg puts the fork back" begin
    # Seeding succeeds (no registry knows the UUID, so there is nothing to compare it with); the
    # resolve then fails on the unregistered package.
    parent = project_dir("[deps]\nNoSuchPkg = \"44444444-4444-4444-4444-444444444444\"\n")
    env = fork_with("Project.toml" => "[deps]\n", "Manifest.toml" => "# the fork's own\n")
    before = fork_files(env)
    ok = NS._rebuild_notebook_env!(env, parent)
    @test !ok
    @test fork_files(env) == before
    @test occursin("NoSuchPkg", RE.env_problem(env))
    @test RE.env_stale(env, parent)   # not stamped, so the next open tries again
end

@testset "a fork of a project with no package resolves, and drops what the project no longer lists" begin
    # The copied manifest holds an entry no project line reaches, named for one package with another's
    # UUID: what an edit of the project leaves behind. Adding the package that UUID belongs to is
    # refused while it is there.
    parent = project_dir("[deps]\nStatistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n")
    write(joinpath(parent, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"

        [[deps.GLMakie]]
        uuid = "$CAIRO"
        version = "0.15.17"
        """)
    env = fork_with("Project.toml" => "[deps]\n")
    RE.set_env_problem!(env; failure = "an earlier failure")
    delta = [Dict{String,Any}("name" => "GLMakie", "version" => "0.15.17", "uuid" => CAIRO)]
    ok = NS._rebuild_notebook_env!(env, parent; delta)
    man = read(joinpath(env, "Manifest.toml"), String)
    @test ok
    @test !occursin(CAIRO, man)
    @test occursin("SlateExtensionsBase", man)          # the seed's own addition is resolved in
    @test !RE.env_stale(env, parent)
    # The footer record that pairs GLMakie with CairoMakie's UUID was not added, and the notebook says so.
    @test RE.env_problem(env) == "Slate.env packages not added: GLMakie = $CAIRO (CairoMakie's UUID)"
    @test NS._rebuild_notebook_env!(env, parent)
    @test RE.env_problem(env) == ""
end

@testset "the env notice ends with what it describes" begin
    env = mktempdir()
    RE.set_env_problem!(env; failure = "not updated from its project: x", left_out = ["Slate.env packages not added: y"])
    @test RE.env_problem(env) == "Slate.env packages not added: y\nnot updated from its project: x"
    # A package operation rewrites the footer from the env: the left-out records are gone from it.
    @test RE.clear_env_problem!(env, :left_out)
    @test RE.env_problem(env) == "not updated from its project: x"
    @test !RE.clear_env_problem!(env, :left_out)
    @test RE.clear_env_problem!(env, :failure)
    @test RE.env_problem(env) == ""

    # A project edited so the fork can't follow it, then put back: the fork is current again with no
    # rebuild, and the failure is over.
    parent = project_dir("[deps]\nStatistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n")
    fork = fork_with("Project.toml" => "[deps]\n")
    RE.stamp_env!(fork, parent)
    good = read(joinpath(parent, "Project.toml"), String)
    write(joinpath(parent, "Project.toml"), good * "[compat]\nGLMakie = \"0.13\"\n")
    # A failed rebuild reports nothing new, so no region worker's copy of the fork is sent again.
    @test !NS._refresh_fork_env!(fork, parent, Dict{String,Any}[])
    @test occursin("not updated from its project", RE.env_problem(fork))
    write(joinpath(parent, "Project.toml"), good)
    @test !NS._refresh_fork_env!(fork, parent, Dict{String,Any}[])
    @test RE.env_problem(fork) == ""
end

@testset "the error a Pkg subprocess ended with" begin
    lines = ["Resolving package versions...",
             "ERROR: `Foo` is a direct dependency, but does not appear in the manifest.",
             "Run `Pkg.resolve()`.",
             "Stacktrace:",
             " [1] pkgerror(msg::String)"]
    @test RE.pkg_error(lines) == "`Foo` is a direct dependency, but does not appear in the manifest. Run `Pkg.resolve()`."
    @test RE.pkg_error(["just a line"]) == "just a line"
    @test RE.pkg_error(String[]) == "the build failed"
end

@testset "a sweep's task environment builds from a project with no package" begin
    # The seed lists SlateExtensionsBase, which the project's manifest does not have; with no package
    # to develop, the build resolves it in.
    parent = project_dir("[deps]\nStatistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n")
    env = RE.Sweep.task_env!(mktempdir(), parent, :parent)
    @test occursin("SlateExtensionsBase", read(joinpath(env, "Manifest.toml"), String))

    # A project that can't be built says why.
    bad = project_dir("[deps]\nNoSuchPkg = \"44444444-4444-4444-4444-444444444444\"\n")
    e = try; RE.Sweep.task_env!(mktempdir(), bad, :parent); ""; catch err; sprint(showerror, err); end
    @test contains(e, "could not prepare the task environment")
    @test contains(e, "NoSuchPkg")
end

# A worker whose environment can't be read answers with no packages and an error. Read as "this notebook
# has no packages of its own", that emptied the footer at the next package operation.
struct _UnreadableEnv <: RE.Kernel end
RE.env_info(::_UnreadableEnv, ::RE.Report) =
    (notebook = (path = "", name = "", deps = Dict{String,Any}[]), parent = nothing,
     error = "expected package `SlateExtensionsBase` to exist in the manifest")

@testset "an environment that can't be read leaves the footer alone" begin
    dir = mktempdir()
    path = joinpath(dir, "nb.jl")
    src = "#%% code id=a\nx = 1\n"
    write(path, src)
    report = RE.parse_report(src)
    footer = [Dict{String,Any}("name" => "Compat", "version" => "4.18.1", "uuid" => "34da2185-b29b-5c13-b0c7-acf172513d20")]
    report.meta["env"] = footer
    nb = NS.LiveNotebook("unreadable", path, report, _UnreadableEnv(), 1, String[], String[], ReentrantLock(),
                         Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())
    @test !NS._notebook_adds(nb).ok
    NS._refresh_env_meta!(nb)
    @test nb.report.meta["env"] == footer
end
