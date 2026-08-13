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
