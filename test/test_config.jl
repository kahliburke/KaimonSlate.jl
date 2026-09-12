# Hub-port configuration: the boot-time precedence (env > persisted config > default) and the
# durable `set_configured_port!`/`configured_port` round-trip. The config home is redirected to a
# tempdir (SlateHome re-reads ENV per call) so the real `slate.json` is never touched.
using ReTest
using KaimonSlate
import JSON   # the embedded-Kaimon config is written as JSON and read back below
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

    # The keyboard shortcuts live in their OWN file beside slate.json, so a rebind (frequent, written
    # on every change) can never race a port or worker-threads write and clobber it. What Julia
    # validates is the SHAPE only: which chords are legal, which command ids exist and which chords the
    # browser refuses are all front-end knowledge (test/js/keymap_resolve.mjs), and a second opinion
    # here would be one more thing to keep in step.
    @testset "keymap config" begin
        NS = KaimonSlate.NotebookServer
        old = get(ENV, "KAIMONSLATE_CONFIG_HOME", nothing)
        ENV["KAIMONSLATE_CONFIG_HOME"] = mktempdir()
        try
            # No file yet: the default keymap, not an error and not an empty dict.
            fresh = NS.keymap_config()
            @test fresh["preset"] == "slate"
            @test isempty(fresh["bindings"])

            stored = NS.keymap_config!(Dict("preset" => "vscode",
                                            "bindings" => Dict("cell.run" => ["Mod-Enter"],
                                                               "nb.runStale" => String[])))
            @test stored["preset"] == "vscode"
            @test stored["bindings"]["cell.run"] == ["Mod-Enter"]
            # `[]` is MEANINGFUL — "deliberately unbound", as distinct from an absent key, which means
            # "inherit the preset". Dropping empties would make an unbind impossible to express.
            @test haskey(stored["bindings"], "nb.runStale")
            @test isempty(stored["bindings"]["nb.runStale"])
            @test NS.keymap_config() == stored              # survives the round trip through disk

            # A save REPLACES rather than merges: the body is the user's whole keymap, and merging
            # would make a removed binding unremovable.
            @test isempty(NS.keymap_config!(Dict("preset" => "slate", "bindings" => Dict()))["bindings"])

            # Garbage is coerced, one entry at a time, rather than rejected wholesale — a hand-edited
            # file is the normal way this gets malformed, and losing one mistyped line beats losing
            # the other fifty bindings.
            junk = NS.keymap_config!(Dict("preset" => 42,
                                          "bindings" => Dict("ok" => ["Mod-k"],
                                                             "notalist" => "Mod-j",
                                                             "hasjunk" => ["Mod-m", 7, ""])))
            @test junk["preset"] == "slate"
            @test junk["bindings"]["ok"] == ["Mod-k"]
            @test !haskey(junk["bindings"], "notalist")
            @test junk["bindings"]["hasjunk"] == ["Mod-m"]
            @test NS.keymap_config!("not even a dict")["preset"] == "slate"

            # An unreadable file must not take the notebook down with it — the page opens on the
            # defaults, which is a far better failure than refusing to load.
            write(NS._keymap_path(), "{ this is not json")
            @test NS.keymap_config()["preset"] == "slate"

            # Bounded, so a runaway or hostile PUT cannot fill the config directory.
            big = NS.keymap_config!(Dict("bindings" => Dict("many" => fill("Mod-k", 40),
                                                            "long" => [repeat("x", 500)])))
            @test length(big["bindings"]["many"]) <= NS._KEYMAP_MAX_CHORDS
            @test isempty(big["bindings"]["long"])
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

# `slate --ai` runs a headless Kaimon isolated under Slate's cache. The isolation rests on a
# precedence detail that is easy to get wrong: Kaimon has no KAIMON_HOME and resolves purely from
# XDG, while the Slate extension it SPAWNS inherits those same vars — so both halves have to be set,
# or the embedded Slate silently gets a fresh config and an empty notebook list.
@testset "embedded Kaimon is isolated without displacing Slate" begin
    root = mktempdir()
    withenv("KAIMONSLATE_KAIMON_HOME" => root) do
        @test KaimonSlate._embedded_root() == root
        @test KaimonSlate._embedded_config_home() == joinpath(root, "config")

        vars = Dict(KaimonSlate._embedded_env_vars(2828))
        @testset "Kaimon is pointed into the private location" begin
            @test vars["XDG_CONFIG_HOME"] == joinpath(root, "config")
            # The cache home is asserted by PROPERTY, not by path: the gate puts a unix socket under
            # it, and that path has a hard length limit (a struct field, so overflow is an error and
            # not a truncation). When the tidy location is too deep — which a mktempdir root under
            # /var/folders already is — a short private directory is used instead. The requirement
            # is that a socket fits, which is what actually broke: the extension bound its hub, then
            # died creating the socket, and crash-looped.
            cache = vars["XDG_CACHE_HOME"]
            sock = joinpath(cache, "kaimon", "sock", "0f9ced16-c229-1f86-df1b-cfc60879d5f4-stream.sock")
            @test length(sock) < (Sys.islinux() ? 108 : 104)
            @test cache == joinpath(root, "cache") || startswith(cache, "/tmp/ks-ai-")
        end
        @testset "Slate is pinned back to the user's real homes" begin
            # These must NOT follow XDG into the private dir — that is the whole trap.
            @test vars["KAIMONSLATE_CONFIG_HOME"] == KaimonSlate.SlateHome.config_home()
            @test vars["KAIMONSLATE_DATA_HOME"] == KaimonSlate.SlateHome.data_home()
        end
        @testset "and the two resolve apart under that environment" begin
            withenv(KaimonSlate._embedded_env_vars(2828)...) do
                @test startswith(KaimonSlate._kaimon_dir(), root)          # Kaimon: private
                @test !startswith(KaimonSlate.SlateHome.config_home(), root)   # Slate: not
            end
        end
        @testset "Julia's own resolution is ours, not the launcher's" begin
            # The `slate` app shim exports JULIA_LOAD_PATH=<the KaimonSlate checkout>, which REPLACES
            # the whole load path — no `@`. Inheriting that makes `--project=<embedded env>` name an
            # environment Julia then never searches, and the host dies with "Package Kaimon not found
            # in current path". Verified as the cause: the same spawn differs only by this variable.
            @test vars["JULIA_LOAD_PATH"] == join(("@", "@v#.#", "@stdlib"), Sys.iswindows() ? ';' : ':')
            @test haskey(vars, "JULIA_PROJECT") && vars["JULIA_PROJECT"] === nothing
        end

        @testset "no index sync — Ollama may not be running" begin
            @test vars["KAIMON_HEADLESS_SYNC_INTERVAL"] == "0"
        end

        @testset "the config is lax, loopback, and key-free" begin
            # Kaimon's own first-run path writes :strict with a generated API key, which would put a
            # token between the host, the extension it spawns, and any CLI agent attaching.
            f = KaimonSlate._write_kaimon_config!(2828)
            cfg = JSON.parsefile(f)
            @test cfg["mode"] == "lax"
            @test isempty(cfg["api_keys"])
            @test cfg["allowed_ips"] == ["127.0.0.1", "::1"]
            @test cfg["port"] == 2828
            @test cfg["created_at"] isa Integer      # Int64 field; a float is the hand-written-config trap
        end
    end
end

# `--ai`'s value is OPTIONAL while a notebook path is also positional, so the token after it has to
# be inspected rather than consumed. Both flags take both spellings; there is no per-flag convention
# to remember. `_parse_app_args` is the REAL parser `_app_main` uses — exercised directly rather than
# mirrored here, so the grammar cannot drift away from its tests.
@testset "slate --ai argument forms" begin
    P = KS._parse_app_args

    @testset "both spellings agree" begin
        @test P(["--ai", "2828"]).ai_port == 2828
        @test P(["--ai=2828"]).ai_port == 2828
        @test P(["--port", "9000"]).port == 9000
        @test P(["--port=9000"]).port == 9000
    end

    @testset "a bare --ai keeps the default and consumes nothing" begin
        r = P(["--ai"])
        @test r.ai && r.ai_port === nothing
        # The token after --ai is only its value when it looks like one.
        @test P(["--ai", "nb.jl"]).file == "nb.jl"
        @test P(["--ai", "nb.jl"]).ai_port === nothing
        @test P(["--ai", "--own"]).own == true      # a flag is never eaten as a port
    end

    @testset "port and file together" begin
        r = P(["--ai", "2828", "nb.jl"])
        @test r.ai_port == 2828 && r.file == "nb.jl"
        r2 = P(["--port", "9000", "--ai", "2828", "nb.jl"])
        @test r2.port == 9000 && r2.ai_port == 2828 && r2.file == "nb.jl"
    end

    @testset "malformed lines are refused, not guessed at" begin
        @test occursin("invalid --ai port", P(["--ai=99999"]).err)
        @test occursin("invalid --ai port", P(["--ai=abc"]).err)
        @test occursin("invalid --port", P(["--port", "abc"]).err)
        @test occursin("--port needs a value", P(["--port"]).err)
        @test occursin("unknown option", P(["--bogus"]).err)
        @test occursin("too many arguments", P(["a.jl", "b.jl"]).err)
        # An out-of-range value AFTER a bare `--ai` is not its port, so it stays a positional and
        # is caught as a file rather than silently starting a host on a nonsense port.
        @test P(["--ai", "99999"]).ai_port === nothing && P(["--ai", "99999"]).file == "99999"
    end

    @testset "actions are decided, not performed" begin
        @test P(["--help"]).action == :help
        @test P(["--status"]).action == :status
        @test P(["nb.jl"]).action == :run
    end
end

# `pgrep -f "SlateWorker.start"` matches every Slate worker on the machine, and the kills run as the
# user — so reaping every match takes down the workers of any OTHER live hub the same person owns
# (a second checkout, a worktree, `slate --ai` beside the hub under their Kaimon). Those are running
# notebooks, not leftovers. Only a worker whose parent is actually gone may be reaped.
@testset "orphan reaping spares live hubs' workers" begin
    @testset "a process with a live parent is never an orphan" begin
        @test KS._is_orphan_worker(getpid()) == false      # we have a live parent
        c = run(`sleep 30`; wait = false)
        try
            sleep(0.5)
            @test KS._ppid(getpid(c)) == getpid()          # our child, parent alive
            @test KS._is_orphan_worker(getpid(c)) == false # THE case that was being killed
        finally
            try; kill(c); catch; end
        end
    end

    @testset "unknown parentage fails safe" begin
        # Lingering is untidy; killing a worker out from under a running notebook destroys work.
        @test KS._is_orphan_worker(999_999) == false
        @test KS._ppid(999_999) == 0
        @test KS._pid_alive(999_999) == false
    end

    @testset "the orphan decision, over its whole truth table" begin
        # Split from the PID lookup so this is deterministic: a shell's backgrounded child does not
        # reliably outlive the shell, so manufacturing a real orphan in a test is flaky.
        @test KS._orphaned_by(1) == true         # reparented to init ⇒ its hub is gone ⇒ reap
        @test KS._orphaned_by(0) == false        # unknown parentage ⇒ fail safe
        @test KS._orphaned_by(getpid()) == false # parent alive ⇒ belongs to a running hub
        @test KS._orphaned_by(999_999) == true   # parent gone (the Windows dangling-PID case)
    end
end
