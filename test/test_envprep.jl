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

    @testset "a named parent is reported, and the fork is not itself a package" begin
        r = seed_from("")
        @test r.pname == "Parent"
        # The fork inherits sections, never the parent's identity: carrying name/uuid would
        # make the scratch env claim to BE the parent.
        @test !haskey(r.seeded, "name")
        @test !haskey(r.seeded, "uuid")
    end

end
