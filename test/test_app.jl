# The `slate` Pkg app: first-run onboarding (consented extension registration), the
# consent flag round-trip, and entrypoint arg handling. The TUI loop itself is not
# driven here (interactive); its data path (_refresh!/_fetch_notebooks) is exercised
# via the model against no hub. Run:  julia --startup-file=no test/test_app.jl
using ReTest, JSON
using KaimonSlate

const KS = KaimonSlate

# Isolate BOTH config surfaces in a temp dir: Kaimon's registry (~/.config/kaimon via
# XDG_CONFIG_HOME) and Slate's own slate.json (SlateHome, same XDG root). KAIMONSLATE_HOME /
# KAIMONSLATE_CONFIG_HOME are cleared so XDG_CONFIG_HOME is what resolves.
_with_isolated_config(f) = mktempdir() do tmp
    withenv("XDG_CONFIG_HOME" => tmp, "KAIMONSLATE_HOME" => nothing,
            "KAIMONSLATE_CONFIG_HOME" => nothing) do
        f(tmp)
    end
end

_ext_entries(tmp) = begin
    file = joinpath(tmp, "kaimon", "extensions.json")
    isfile(file) ? get(JSON.parsefile(file), "extensions", Any[]) : Any[]
end

# Drive the onboarding prompt; returns (just_registered::Bool, printed_output::String).
_onboard(input::String) = begin
    out = IOBuffer()
    ret = KS._maybe_onboard!(input = IOBuffer(input), output = out)
    (ret, String(take!(out)))
end

@testset "slateapp onboarding" begin
    @testset "no Kaimon dir → silent no-op" begin
        _with_isolated_config() do tmp
            @test _onboard("y\n") == (false, "")
            @test isempty(_ext_entries(tmp))
            @test KS.ext_prompt_choice() == ""
        end
    end

    @testset "Yes → registers + persists consent + reports it" begin
        _with_isolated_config() do tmp
            mkpath(joinpath(tmp, "kaimon"))
            ret, out = _onboard("y\n")
            @test ret                                            # just registered → caller must say "restart Kaimon" + exit
            @test occursin("Register Slate", out)
            entries = _ext_entries(tmp)
            @test length(entries) == 1
            @test KS._is_slate_project(String(entries[1]["project_path"]))
            @test KS.ext_prompt_choice() == "yes"
            @test KS._slate_registered()
            # second run: already registered → silent, nothing written
            @test _onboard("y\n") == (false, "")
        end
    end

    @testset "empty answer defaults to Yes" begin
        _with_isolated_config() do tmp
            mkpath(joinpath(tmp, "kaimon"))
            ret, _ = _onboard("\n")
            @test ret
            @test length(_ext_entries(tmp)) == 1
            @test KS.ext_prompt_choice() == "yes"
        end
    end

    @testset "No → nothing persisted, asks again" begin
        _with_isolated_config() do tmp
            mkpath(joinpath(tmp, "kaimon"))
            ret, _ = _onboard("n\n")
            @test !ret
            @test isempty(_ext_entries(tmp))
            @test KS.ext_prompt_choice() == ""
            @test occursin("Register Slate", _onboard("n\n")[2])   # asked again
        end
    end

    @testset "Don't ask → dismissed persists, second run silent" begin
        _with_isolated_config() do tmp
            mkpath(joinpath(tmp, "kaimon"))
            ret, _ = _onboard("d\n")
            @test !ret
            @test isempty(_ext_entries(tmp))
            @test KS.ext_prompt_choice() == "dismissed"
            @test _onboard("y\n") == (false, "")                   # never asks again
        end
    end

    @testset "removed entry after prior Yes → prompted again, not auto-repaired" begin
        _with_isolated_config() do tmp
            mkpath(joinpath(tmp, "kaimon"))
            KS.set_ext_prompt_choice!("yes")                     # consented in the past…
            ret, out = _onboard("n\n")                           # …but the entry is gone now
            @test occursin("Register Slate", out)                # asked, nothing silent
            @test !ret
            @test isempty(_ext_entries(tmp))                     # "no" respected
            ret2, _ = _onboard("y\n")                            # opting back in works
            @test ret2
            @test length(_ext_entries(tmp)) == 1
        end
    end
end

@testset "slateapp startup mode" begin
    # hub answering always wins; a registered auto-start extension defers unless --own
    @test KS._startup_mode(true,  true,  false) == :viewer
    @test KS._startup_mode(true,  false, true)  == :viewer
    @test KS._startup_mode(false, true,  false) == :waiting
    @test KS._startup_mode(false, true,  true)  == :owner
    @test KS._startup_mode(false, false, false) == :owner
    @test KS._startup_mode(false, false, true)  == :owner

    _with_isolated_config() do tmp
        @test !KS._ext_autostarts()                              # nothing registered
        mkpath(joinpath(tmp, "kaimon"))
        KS.register_extension()
        @test KS._ext_autostarts()                               # default entry: enabled + auto_start
        # flip auto_start off → the extension won't come up on its own → owner path
        file = joinpath(tmp, "kaimon", "extensions.json")
        data = JSON.parsefile(file)
        data["extensions"][1]["auto_start"] = false
        write(file, JSON.json(data))
        @test !KS._ext_autostarts()
        data["extensions"][1]["auto_start"] = true
        data["extensions"][1]["enabled"] = false
        write(file, JSON.json(data))
        @test !KS._ext_autostarts()
    end
end

@testset "slateapp consent flag round-trip" begin
    _with_isolated_config() do _
        @test KS.ext_prompt_choice() == ""
        @test KS.set_ext_prompt_choice!("dismissed") == "dismissed"
        @test KS.ext_prompt_choice() == "dismissed"
        KS.set_ext_prompt_choice!("yes")
        @test KS.ext_prompt_choice() == "yes"
        # other slate.json keys survive the write
        cfg = KS._slate_config()
        @test get(cfg, "ext_prompt", "") == "yes"
    end
end

@testset "slateapp registered check" begin
    _with_isolated_config() do tmp
        @test !KS._slate_registered()                            # no kaimon dir
        kdir = joinpath(tmp, "kaimon"); mkpath(kdir)
        @test !KS._slate_registered()                            # no file
        write(joinpath(kdir, "extensions.json"),
              JSON.json(Dict("extensions" => [Dict("project_path" => "/nonexistent", "enabled" => true)])))
        @test !KS._slate_registered()                            # entry isn't a Slate checkout
        KS.register_extension()
        @test KS._slate_registered()
    end
end

@testset "slateapp entry args" begin
    @test KS._app_main(["-h"]) == 0
    @test KS._app_main(["--help"]) == 0
    @test KS._app_main(["--bogus"]) == 2
    @test KS._app_main(["a.jl", "b.jl"]) == 2
    @test KS._app_main(["--status"]) in (0, 1)   # env-dependent: 0 with a live hub, 1 without
    @test occursin("KAIMONSLATE_PORT", KS._APP_HELP)
    @test occursin("--status", KS._APP_HELP)
end

@testset "slateapp status model (no hub)" begin
    m = KS.SlateModel(:viewer)
    @test !KS.Tachikoma.should_quit(m)
    # viewer-mode restart is refused with a pointer to Kaimon
    @test occursin("Kaimon", KS._restart_hub!(m))
    # waiting mode: no hub to restart — points at [s]
    @test occursin("[s]", KS._restart_hub!(KS.SlateModel(:waiting)))
    # a queued file survives construction (opened on the waiting→viewer flip)
    @test KS.SlateModel(:waiting; pending = "nb.jl").pending == "nb.jl"
    # quit keys flip the flag
    KS.Tachikoma.update!(m, KS.Tachikoma.KeyEvent(:char, 'q'))
    @test KS.Tachikoma.should_quit(m)
end
