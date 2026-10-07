# Cell profiler, the kernel side (profile.jl): prepare compiles a cell without running it, and an
# armed cell's next ordinary run (`run_capture`) is sampled into a tree keyed by source line. The
# gate path is the same functions behind `__slate_profile_*`, so this is where the semantics live.
using ReTest
using KaimonSlate
const RE = KaimonSlate.ReportEngine

# A namespace standing in for a notebook's, with a function defined in "another cell".
module ProfNS
    function work(n)
        s = 0.0
        for i in 1:n
            s += sin(i) * cos(i)
        end
        return s
    end
    unstable(xs) = (s = 0.0; for x in xs; s += x; end; s)
    n = 20_000_000
end

str(p, i) = p["strings"][i]
nodes(p) = p["nodes"]

function profile_cell(mod, cid, src)
    RE.profile_arm!(cid, "cpu")
    w = RE.run_capture(mod, src, "cell:" * cid)
    return w, RE.profile_result(cid)
end

@testset "cell profiler" begin
    @testset "prepare compiles the cell without running it" begin
        src = "f2(x) = x + 1\ny = work(n)\nz = y + f2(1)\n"
        r = RE.profile_prepare!(ProfNS; cell = "pp", source = src, reads = ["work", "n"])
        @test r["ok"] === true && r["error"] === nothing
        @test r["skipped"] == [1]                    # the definition stays out of the wrapper
        @test sort(r["args"]) == ["n", "work"]
        @test !isdefined(ProfNS, :y)                 # nothing ran
        @test isdefined(ProfNS, :__slate_prof_pp)
        bad = RE.profile_prepare!(ProfNS; cell = "pb", source = "y = (", reads = String[])
        @test bad["ok"] === false && occursin("parse", bad["error"])
    end

    @testset "an armed run is sampled, rooted at the cell's lines" begin
        src = "a = 1\nr = work(n)\nb = 2\n"
        w, p = profile_cell(ProfNS, "pc", src)
        @test w.exception === nothing && Base.invokelatest(getfield, ProfNS, :r) isa Float64   # the run is the real one
        @test p !== nothing && p["cell"] == "pc" && p["samples"] > 20
        nd = nodes(p)
        @test nd["parent"][1] == 0 && str(p, nd["func"][1]) == "cell pc"
        # The cell's line 2 is under the root and holds nearly all the time, with `work`'s loop below it.
        kids = [i for i in eachindex(nd["parent"]) if nd["parent"][i] == 1]
        l2 = only(i for i in kids if str(p, nd["file"][i]) == "cell:pc" && nd["line"][i] == 2)
        @test nd["total"][l2] >= 0.8 * p["samples"]
        below = [i for i in eachindex(nd["parent"]) if nd["parent"][i] == l2]
        @test any(i -> str(p, nd["func"][i]) == "work", below)
        # The line table covers the cell and the function it called.
        ln = p["lines"]
        rows = [(str(p, ln["file"][i]), ln["line"][i], ln["incl"][i]) for i in eachindex(ln["file"])]
        @test any(r -> r[1] == "cell:pc" && r[2] == 2 && r[3] >= 0.8 * p["samples"], rows)
        @test any(r -> endswith(r[1], "test_profile.jl") && r[3] > 0, rows)
        @test p["duration_ms"] > 0 && p["error"] === nothing
        # Unarmed, a run leaves the last profile as it was.
        RE.run_capture(ProfNS, src, "cell:pc")
        @test RE.profile_result("pc")["at"] == p["at"]
    end

    @testset "a cell that throws is still profiled" begin
        w, p = profile_cell(ProfNS, "pe", "work(n)\nerror(\"boom\")\n")
        @test w.exception !== nothing
        @test p !== nothing && occursin("boom", p["error"]) && p["samples"] > 0
    end

    @testset "runtime dispatch is marked on the line under it" begin
        src = "xs = Any[isodd(i) ? i : Float64(i) for i in 1:3_000_000]\nt = unstable(xs)\n"
        _, p = profile_cell(ProfNS, "pd", src)
        nd = nodes(p)
        @test sum(nd["dispatch"]) > 0
    end

    @testset "work handed to other threads hangs under the line that handed it out" begin
        Threads.nthreads() > 1 || return
        # The threaded function is defined by another cell, as in a notebook.
        RE.run_capture(ProfNS, "function spread(m)\n    acc = zeros(Threads.nthreads())\n    Threads.@threads for k in 1:4Threads.nthreads()\n        acc[Threads.threadid()] += work(m)\n    end\n    sum(acc)\nend\n", "cell:defs")
        _, p = profile_cell(ProfNS, "pt", "a = 1\ns = spread(n ÷ 8)\n")
        @test p["threads"] >= 2
        nd = nodes(p)
        @test !any(i -> str(p, nd["func"][i]) == "other threads", eachindex(nd["func"]))
        l2 = only(i for i in eachindex(nd["parent"]) if nd["parent"][i] == 1 && nd["line"][i] == 2)
        @test nd["total"][l2] >= 0.8 * p["samples"]
        # `work` is reached from the threads' tasks, beneath the cell's line, through `spread`.
        under(i, a) = (while i > 0; i == a && return true; i = nd["parent"][i]; end; false)
        w = [i for i in eachindex(nd["func"]) if str(p, nd["func"][i]) == "work" && under(i, l2)]
        @test sum(nd["total"][w]) >= 0.5 * p["samples"]
        @test p["dropped"]["other cells"] == 0
    end

    @testset "allocations are profiled by bytes, with what was allocated" begin
        RE.profile_arm!("pa", "alloc"; alloc_rate = 0.5)
        RE.run_capture(ProfNS, "a = Any[i for i in 1:50_000]\nb = sum(length(collect(1:k % 50)) for k in 1:20_000)\n", "cell:pa")
        p = RE.profile_result("pa")
        @test p["unit"] == "bytes" && p["samples"] > 0 && !isempty(p["types"])
        nd = nodes(p)
        l1 = [i for i in eachindex(nd["parent"]) if nd["parent"][i] == 1 && nd["line"][i] == 1]
        @test !isempty(l1) && sum(nd["total"][l1]) > 0
    end

    @testset "what compiled during the run, and what dispatched at runtime" begin
        RE.profile_arm!("pc2", "cpu")
        RE.run_capture(ProfNS, "fresh_f(x) = x + 1\nv = Any[1, 2.5, 0x3]\nt = sum(fresh_f, v)\n", "cell:pc2")
        p = RE.profile_result("pc2")
        @test p["compiled_n"] >= 1 && any(c -> occursin("fresh_f", c[1]), p["compiled"])
        @test p["dispatched_n"] >= 1
        # Again: the runtime keeps the stream it first traced to, so a second run must still capture.
        RE.profile_arm!("pc3", "cpu")
        RE.run_capture(ProfNS, "fresh_g(x) = x * 2\nw = Any[1, 2.5]\nu = sum(fresh_g, w)\n", "cell:pc3")
        @test any(c -> occursin("fresh_g", c[1]), RE.profile_result("pc3")["compiled"])
    end

    @testset "wall time samples a waiting task" begin
        RE.profile_arm!("pw", "wall"; delay_ms = 0.2)
        RE.run_capture(ProfNS, "sleep(0.3)\n", "cell:pw")
        p = RE.profile_result("pw")
        nd = nodes(p)
        @test p["mode"] == "wall" && any(i -> nd["parent"][i] == 1 && nd["line"][i] == 1, eachindex(nd["parent"]))
    end

    @testset "a profile exports to speedscope and pprof" begin
        NS = KaimonSlate.NotebookServer
        _, p = profile_cell(ProfNS, "px", "a = 1\nr = work(n)\n")
        ss = NS.profile_speedscope(p, "cell pc")
        prof = only(ss["profiles"])
        @test prof["type"] == "sampled" && length(prof["samples"]) == length(prof["weights"]) > 0
        @test sum(prof["weights"]) ≈ p["samples"] * p["delay_ms"]
        @test all(s -> all(i -> 0 <= i < length(ss["shared"]["frames"]), s), prof["samples"])
        b = NS.profile_pprof(p)
        @test length(b) > 100 && b[1] == 0x0a          # field 1 (sample_type), length-delimited
    end

    @testset "source for a frame is read on the kernel's machine" begin
        s = RE.profile_source("./array.jl")
        @test s["error"] === nothing && occursin("function", s["text"]) && isfile(s["path"])
        @test RE.profile_source("/no/such/file.jl")["error"] !== nothing
    end
end
