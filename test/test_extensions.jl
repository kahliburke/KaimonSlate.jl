# The extension SDK (lib/SlateExtensionsBase) versions INDEPENDENTLY of KaimonSlate — it's the
# stable contract external packages pin, so it moves only when the contract changes. This guard
# makes the independence safe: the SHIPPED pair can never be incompatible, because KaimonSlate's
# `[compat]` bound on SlateExtensionsBase must include the lib's current version.
#
# SEB resolves from a registry rather than a `[sources]` path, so `pkg> app add` can install it
# (Pkg.Apps cannot resolve a sources entry). CI develops lib/ explicitly so the suite still tests
# this checkout's SDK.
using ReTest
using TOML: TOML
using Pkg: Pkg

@testset "SlateExtensionsBase compat guard" begin
    root = joinpath(@__DIR__, "..")
    seb = TOML.parsefile(joinpath(root, "lib", "SlateExtensionsBase", "Project.toml"))
    ks = TOML.parsefile(joinpath(root, "Project.toml"))

    @test haskey(ks["deps"], "SlateExtensionsBase")   # declared as a dep
    # The compat bound must cover the lib's current version.
    sebver = VersionNumber(seb["version"])
    spec = Pkg.Types.semver_spec(ks["compat"]["SlateExtensionsBase"])
    @test sebver in spec
end
