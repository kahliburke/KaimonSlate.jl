# Unit tests for the "preparing environment" progress classifier (src/prepare.jl) — the shared brain
# that turns raw `Pkg.instantiate()`/`Pkg.precompile()` output into a structured status the notebook
# banner narrates (phase, precompile k/N, current package). Pure string logic, so it stands alone.
using ReTest

include(joinpath(@__DIR__, "..", "src", "prepare.jl"))

@testset "prepare" begin
    @testset "precompile stream → structured k/N + package" begin
        tr = PrepareTracker(0.0)   # fixed t0 → deterministic-ish (secs derived from wall clock, not asserted)
        # The real non-TTY format: a `Precompiling` header, then `<timing>  ✓ Name` per package, then a summary.
        feed = [
            "@@SLATE_PREP total=3",
            "Precompiling packages...",
            "     12.3 ms  ✓ ColorTypes",
            "  1234.5 ms  ✓ Colors",
            "            ✗ FixedPointNumbers",   # ✗ pads with spaces, not a timing token
            "  3 dependencies successfully precompiled in 8 seconds. 40 already precompiled.",
            "@@SLATE_PREP done",
        ]
        changed = [prepare_feed!(tr, l) for l in feed]
        @test all(changed)                       # every one of these lines advances the status
        @test tr.phase == "done"
        @test tr.total == 3 && tr.done == 3       # denominator from the control marker; 3 completions
        @test tr.pkg == "FixedPointNumbers"       # most-recent
        @test tr.recent == ["FixedPointNumbers", "Colors", "ColorTypes"]   # newest-first, capped
        @test tr.err                              # a ✗ marks the run errored
        @test occursin("successfully precompiled", tr.note)
    end

    @testset "resolve / install churn is context, not headline" begin
        tr = PrepareTracker(0.0)
        @test prepare_feed!(tr, "    Updating `~/Proj/Project.toml`")   # a phase transition
        @test tr.phase == "resolve"
        @test prepare_feed!(tr, "  [5ae59095] + Colors v0.13.1")       # the noisy resolver line…
        @test tr.phase == "install" && tr.installed == 1               # …counted, never surfaced raw
        @test prepare_feed!(tr, "  [3da002f7] + ColorTypes v0.12.1")
        @test tr.installed == 2
        # An Info/warn banner is pure noise → NOT a structured change (goes to the raw build log only).
        @test !prepare_feed!(tr, "┌ Info: something chatty")
        @test !prepare_feed!(tr, "")
    end

    @testset "overshoot clamps; empty env is inactive" begin
        tr = PrepareTracker(0.0)
        prepare_feed!(tr, "@@SLATE_PREP total=1")
        prepare_feed!(tr, "  10.0 ms  ✓ A")
        prepare_feed!(tr, "  10.0 ms  ✓ B")     # extensions can exceed the estimate
        @test tr.done == 2 && tr.total == 2      # total bumped up so k never exceeds n
        @test prepare_active(tr)
        @test !prepare_active(PrepareTracker(0.0))   # nothing seen yet → no banner
    end

    @testset "coarse stage headline rides above the precompile bar" begin
        tr = PrepareTracker(0.0)
        @test prepare_feed!(tr, "@@SLATE_PREP stage=Starting worker process on host")
        @test tr.stage == "Starting worker process on host"
        @test prepare_active(tr)                 # a stage alone (no precompile) still shows the banner
        @test prepare_feed!(tr, "@@SLATE_PREP total=2")   # env-build substage begins under the same headline
        @test prepare_feed!(tr, "  10.0 ms  ✓ Foo")
        @test tr.stage == "Starting worker process on host"   # stage persists while the precompile bar advances
        @test tr.phase == "precompile" && tr.done == 1
        @test occursin("\"stage\":\"Starting worker process on host\"", prepare_json(tr))
    end

    @testset "json is well-formed and escapes" begin
        tr = PrepareTracker(0.0)
        prepare_feed!(tr, "@@SLATE_PREP total=2")
        prepare_feed!(tr, raw"  10.0 ms  ✓ Weird\Name")   # backslash must be escaped in the JSON
        j = prepare_json(tr)
        @test occursin("\"phase\":\"precompile\"", j)
        @test occursin("\"k\":1", j) && occursin("\"n\":2", j)
        @test occursin("Weird\\\\Name", j)                # one JSON-escaped backslash
        @test !occursin('\n', j)                          # single-line (safe as an SSE frame)
    end

    @testset "error marker keeps the note after the space (regression)" begin
        # `@@SLATE_PREP error <msg>` → the note is the text AFTER the space, not a fixed offset that
        # dropped the first character (the old bug turned "the env failed" into "he env failed").
        tr = PrepareTracker(0.0)
        @test prepare_feed!(tr, "@@SLATE_PREP error the environment failed to build")
        @test tr.phase == "error" && tr.err
        @test tr.note == "the environment failed to build"
        # A bare "error" with no trailing message leaves the note untouched (the `m === nothing` branch).
        tr2 = PrepareTracker(0.0)
        @test prepare_feed!(tr2, "@@SLATE_PREP error")
        @test tr2.err && isempty(tr2.note)
    end
end
