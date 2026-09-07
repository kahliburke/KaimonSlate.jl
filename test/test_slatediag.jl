# SlateDiag: the switchable instrumentation (src/slatediag.jl). Pure and local — no hub, no server.
# What is worth pinning down here is the part that is silently wrong rather than loudly broken:
# a route key that fails to collapse its variables gives a million one-call buckets, and a frame
# filter that fails to skip Julia's own trees attributes every sample to `readline`. Both look like
# working instrumentation while telling you nothing.
using ReTest
using KaimonSlate

const SD = KaimonSlate.SlateDiag

@testset "slatediag" begin

    @testset "route keys collapse the variable parts" begin
        # Same route, different ids/names → ONE bucket. This is the whole point of a key.
        @test SD.diag_key("GET", "/api/abcd1234-ef/state") == SD.diag_key("GET", "/api/99887766-aa/state")
        @test SD.diag_key("GET", "/n/notebook-one") == SD.diag_key("GET", "/n/notebook-two")
        @test SD.diag_key("GET", "/blob/aaa") == SD.diag_key("GET", "/blob/bbb")
        # ...and the collapse must not go so far that distinct routes merge.
        @test allunique((SD.diag_key("GET", "/api/x/state"), SD.diag_key("POST", "/api/x/state"),
                         SD.diag_key("GET", "/api/regions"), SD.diag_key("GET", "/n/x")))
        # A query string is not part of the route.
        @test SD.diag_key("GET", "/api/regions?warm=1") == SD.diag_key("GET", "/api/regions")
    end

    @testset "recording: totals, worst case, errors" begin
        SD.reset!()
        SD.diag_record!("GET /t", 1_000_000, 100, true)
        SD.diag_record!("GET /t", 9_000_000, 100, false)
        r = only(filter(x -> x["route"] == "GET /t", SD.diag_snapshot()["routes"]))
        @test (r["calls"], r["errors"]) == (2, 1)
        @test r["mean_ms"] ≈ 5.0                      # (1 + 9) / 2
        @test r["max_ms"] ≈ 9.0                       # the worst call, not the last
        @test r["last_ms"] ≈ 9.0
        SD.reset!()
        @test isempty(SD.diag_snapshot()["routes"])
    end

    @testset "gauges are callbacks, and a throwing one cannot break a snapshot" begin
        SD.diag_gauge!("t_count", () -> 7)
        SD.diag_gauge!("t_broken", () -> error("registry is gone"))
        g = SD.diag_snapshot()["gauges"]
        @test g["t_count"] == 7
        @test g["t_broken"] == -1                     # reported as unreadable, not propagated
    end

    @testset "frame attribution skips Julia's own trees" begin
        # Base reports bare relative filenames; stdlib reports absolute paths under its own root.
        # Neither is ours, and a substring test for "Base" catches neither.
        @test !SD._is_own_file("io.jl")
        @test !SD._is_own_file("./iostream.jl")
        @test !SD._is_own_file(joinpath(Sys.STDLIB, "REPL", "src", "docview.jl"))
        @test SD._is_own_file(abspath(joinpath(@__DIR__, "..", "src", "slatediag.jl")))
        @test !SD._is_own_file(abspath(joinpath(@__DIR__, "notes.md")))   # not Julia source

        # The behaviour that matters: allocation happening inside Base is charged to the nearest
        # frame of ours, not to the Base function that physically allocated.
        fr(file, line, func) = Base.StackTraces.StackFrame(Symbol(func), Symbol(file), line)
        ours = abspath(joinpath(@__DIR__, "..", "src", "remote.jl"))
        st = [fr("iostream.jl", 43, "readline"), fr("io.jl", 1244, "iterate"), fr(ours, 99, "_pump!")]
        @test SD._first_own_frame(st) == "remote.jl:99 _pump!"
        # An all-Julia stack is still reported rather than dropped, marked so it is not read as ours.
        @test startswith(SD._first_own_frame(st[1:2]), "[julia] ")
    end

    @testset "enable/disable" begin
        was = SD.diag_enabled()
        @test SD.diag_enable!(true) && SD.diag_enabled()
        SD.diag_record!("GET /x", 1000, 0, true)
        @test !SD.diag_enable!(false)
        @test isempty(SD.diag_snapshot()["routes"])   # disabling clears, so nothing reads as current
        SD.diag_enable!(was)
    end

    @testset "the periodic line is rate limited and shows deltas" begin
        n = Ref(3)
        SD._LAST_AT[] = 0.0; empty!(SD._LAST)
        SD.diag_gauge!("t_growing", () -> n[])
        first_line = SD.diag_log_line(every = 0.0)
        @test occursin("t_growing=3", first_line)
        @test !occursin("t_growing=3(", first_line)   # nothing to compare against on the first line
        @test SD.diag_log_line(every = 3600.0) === nothing        # not due yet
        n[] = 5
        @test occursin("t_growing=5(+2)", SD.diag_log_line(every = 0.0))
        n[] = 0
        @test !occursin("t_growing", SD.diag_log_line(every = 0.0))   # zero gauges stay off the line
        # ...but a gauge that empties is still BASELINED at zero, so refilling reports the rise from
        # zero rather than from whatever it held before it emptied.
        n[] = 2
        @test occursin("t_growing=2(+2)", SD.diag_log_line(every = 0.0))
        # A gauge whose registry was renamed out from under it must say so rather than vanish, which
        # would read as a quiet registry instead of a broken callback.
        SD.diag_gauge!("t_gone", () -> error("renamed"))
        @test occursin("t_gone=err", SD.diag_log_line(every = 0.0))
    end
end
