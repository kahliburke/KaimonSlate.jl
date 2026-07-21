# The extension SDK (lib/SlateExtensionsBase) versions INDEPENDENTLY of KaimonSlate — it's the
# stable contract external packages pin, so it moves only when the contract changes. This guard
# makes the independence safe: the SHIPPED pair can never be incompatible, because KaimonSlate's
# `[compat]` bound on SlateExtensionsBase must include the lib's current version (and it's sourced
# from the monorepo path, so engine + worker load the exact same code).
using ReTest
import TOML
import Pkg

@testset "SlateExtensionsBase compat guard" begin
    root = joinpath(@__DIR__, "..")
    seb = TOML.parsefile(joinpath(root, "lib", "SlateExtensionsBase", "Project.toml"))
    ks  = TOML.parsefile(joinpath(root, "Project.toml"))

    @test haskey(ks["deps"], "SlateExtensionsBase")                                  # declared as a dep
    @test ks["sources"]["SlateExtensionsBase"]["path"] == "lib/SlateExtensionsBase"  # sourced from the monorepo lib
    # The compat bound must cover the lib's current version.
    sebver = VersionNumber(seb["version"])
    spec = Pkg.Types.semver_spec(ks["compat"]["SlateExtensionsBase"])
    @test sebver in spec
end
