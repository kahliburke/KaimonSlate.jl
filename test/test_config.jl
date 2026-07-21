# Hub-port configuration: the boot-time precedence (env > persisted config > default) and the
# durable `set_configured_port!`/`configured_port` round-trip. The config home is redirected to a
# tempdir (SlateHome re-reads ENV per call) so the real `slate.json` is never touched.
using ReTest
using KaimonSlate
const KS = KaimonSlate

@testset "port-config" begin
    @testset "_resolve_boot_port precedence" begin
        @test KS._resolve_boot_port("", 0) == 8765            # nothing set → default
        @test KS._resolve_boot_port("", 9000) == 9000         # persisted config applies
        @test KS._resolve_boot_port("7000", 9000) == 7000     # env var overrides config
        @test KS._resolve_boot_port("nope", 9000) == 9000     # invalid env → fall back to config
        @test KS._resolve_boot_port("nope", 0) == 8765        # invalid env, no config → default
    end

    @testset "persist + clear (isolated config home)" begin
        old = get(ENV, "KAIMONSLATE_CONFIG_HOME", nothing)
        ENV["KAIMONSLATE_CONFIG_HOME"] = mktempdir()
        try
            @test KS.configured_port() == 0                   # fresh config: unset
            @test KS.set_configured_port!(8080) == 8080
            @test KS.configured_port() == 8080
            @test isfile(KS._slate_config_path())             # written to disk
            @test occursin("8080", read(KS._slate_config_path(), String))

            # a co-existing setting is preserved across a port write
            KS.set_worker_threads!("4,1"; respawn = false)
            @test KS.set_configured_port!(9001) == 9001
            @test KS.worker_threads() == "4,1"
            @test KS.configured_port() == 9001

            @test KS.set_configured_port!(0) == 0             # clear reverts to unset
            @test KS.configured_port() == 0
            @test KS.worker_threads() == "4,1"                # clearing port leaves other keys intact
        finally
            old === nothing ? delete!(ENV, "KAIMONSLATE_CONFIG_HOME") : (ENV["KAIMONSLATE_CONFIG_HOME"] = old)
        end
    end

    # `--port` arg validation — only the early-return paths (help + bad input); a valid port would
    # fall through to the interactive TUI, which needs a real terminal.
    @testset "--port arg validation" begin
        redirect_stdout(devnull) do
            @test KS._app_main(["--help"]) == 0
        end
        redirect_stderr(devnull) do
            @test KS._app_main(["--port", "abc"]) == 2        # non-numeric
            @test KS._app_main(["--port", "99999"]) == 2      # out of 1–65535 range
            @test KS._app_main(["--port"]) == 2               # missing value
            @test KS._app_main(["--bogus"]) == 2              # unknown option still rejected
        end
    end
end
