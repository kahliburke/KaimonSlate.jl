# A worker under a host's confinement policy (Kaimon's `confine`, Landlock) is started through the
# launcher, writing only its own folders and without the host's credentials. Only Linux confines.
using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

@testset "confined workers" begin
    @test RE._credential_var("CLAUDE_CODE_OAUTH_TOKEN") && RE._credential_var("ANTHROPIC_API_KEY")
    @test RE._credential_var("AWS_SECRET_ACCESS_KEY") && RE._credential_var("SSH_AUTH_SOCK")
    @test !RE._credential_var("KAIMON_GATE_TOKEN") && !RE._credential_var("PATH") && !RE._credential_var("JULIA_DEPOT_PATH")

    k = RE.GateKernel(mktempdir())
    cmd = addenv(`julia -e 1`, "CLAUDE_CODE_OAUTH_TOKEN" => "t", "KAIMON_SESSION_LABEL" => "nb.jl")
    withenv("KAIMON_CONFINE" => nothing, "KAIMON_CONFINE_POLICY" => nothing) do
        @test RE._confined_worker(cmd, k) === cmd                     # no policy: as it is
    end
    withenv("KAIMON_CONFINE" => "/opt/kaimon-confine", "KAIMON_CONFINE_POLICY" => "/etc/policy",
            "XDG_CACHE_HOME" => mktempdir()) do
        c = RE._confined_worker(cmd, k)
        if Sys.islinux()
            @test c.exec[1:3] == ["/opt/kaimon-confine", "--policy", "/etc/policy"]
            @test c.exec[end-2:end] == ["julia", "-e", "1"]
            @test k.project in c.exec                                 # its project is written to
            env = Dict(split(kv, '='; limit = 2) for kv in c.env)
            @test !haskey(env, "CLAUDE_CODE_OAUTH_TOKEN") && env["KAIMON_SESSION_LABEL"] == "nb.jl"
            depots = split(env["JULIA_DEPOT_PATH"], ':')
            @test isdir(depots[1]) && depots[1] in c.exec             # a depot of its own, first
            @test all(in(depots), DEPOT_PATH)                         # then the host's, where its packages are
        else
            @test c === cmd
        end
    end
end
