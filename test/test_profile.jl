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

    @testset "the static check is the notebook's to opt into" begin
        r = RE.profile_prepare!(ProfNS; cell = "ps1", source = "y = work(n)\n", reads = ["work", "n"])
        st = r["static"]
        if Base.locate_package(RE._JET_ID) === nothing
            @test st["available"] === false && occursin("JET", st["why"]) && isempty(st["findings"])
        else
            @test st["available"] === true && st["error"] === nothing
        end
        # Findings read in the cell's terms: the module's name dropped, a capture on its assignment.
        fake = Dict{String,Any}("findings" => Any[Dict{String,Any}("kind" => "captured", "msg" => "captured variable `c` detected",
                    "sig" => "c = Core.Box()", "file" => "cell:ps1", "line" => 1),
                Dict{String,Any}("kind" => "dispatch", "msg" => "runtime dispatch detected",
                    "sig" => "(%1::Any $(ProfNS).:+ 1)::Any", "file" => "cell:ps1", "line" => 3)])
        RE._static_tidy!(fake["findings"], ProfNS, "cell:ps1", "a = 1\nc = 0\nf = () -> (c += 1)\n")
        # A capture reported on a function's first line moves to the assignment that follows it.
        @test RE._capture_line(["best = 0", "function f()", "  rng = 1", "  best = Inf", "end"], 3, ["best"]) == 4 &&
              RE._capture_line(["x = 1"], 1, ["nope"]) == 1 &&
              RE._capture_line(["f() = 0", "  a = 1", "  b = 2"], 1, ["b", "a"]) == 2
        # One finding per line, with what came from inside library calls counted there.
        lines = RE._static_lines(Any[
            Dict{String,Any}("kind" => "dispatch", "sig" => "a", "file" => "cell:x", "line" => 4, "func" => "f", "mine" => true, "call" => "f", "frames" => Any[]),
            Dict{String,Any}("kind" => "dispatch", "sig" => "b", "file" => "cell:x", "line" => 4, "func" => "f", "mine" => false, "call" => "sum", "frames" => Any[]),
            Dict{String,Any}("kind" => "captured", "sig" => "c", "file" => "cell:x", "line" => 2, "func" => "f", "mine" => true, "call" => "f", "frames" => Any[])])
        @test [(g["line"], g["kind"], g["own"], g["lib"]) for g in lines] == [(2, "captured", 1, 0), (4, "dispatch", 1, 1)] &&
              lines[2]["calls"] == ["sum"]
        @test fake["findings"][1]["line"] == 2 && fake["findings"][2]["sig"] == "(%1::Any :+ 1)::Any"
    end

    @testset "with JET, the static check finds dispatch and boxed captures on the cell's lines" begin
        # (`if`, not an early `return`: under Test.jl a `return` leaves the enclosing testset too.)
        if Base.locate_package(RE._JET_ID) !== nothing
            src = "t = unstable(xs0)\nc = 0\nbump = () -> (c += 1)\nbump()\nz = t + c\n"
            Core.eval(ProfNS, :(xs0 = Any[1, 2.5]))
            st = RE.profile_prepare!(ProfNS; cell = "pj", source = src, reads = ["unstable", "xs0"])["static"]
            kinds = Set((g["kind"], g["line"]) for g in st["findings"] if g["file"] == "cell:pj")
            @test ("captured", 2) in kinds && ("dispatch", 5) in kinds
        end
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
        if Threads.nthreads() > 1
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
        # The waiting is counted apart, and on the line that waited rather than as its own time.
        @test p["waiting"] > 0 && sum(p["lines"]["wait"]) > 0
    end

    @testset "waiting on the GPU is its own node, and library wrapper frames pass through" begin
        sf(f, file, l = 1) = Base.StackTraces.StackFrame(Symbol(f), Symbol(file), l, nothing, false, false, 0)
        cu(f, file, l = 1) = sf(f, "/d/packages/CUDACore/abc/lib/cudadrv/" * file, l)
        ff(f, l) = sf(f, "/d/packages/cuFFT/abc/src/libcufft.jl", l)
        t = RE._ProfTree(); a = RE._Acc(t, "cell:g")
        root = RE._node!(t, 0, "cell:g", 0, "cell g", "cell", RE._K_SYNTH)
        leaf = RE._add!(a, [sf("top", "cell:g", 3), cu("synchronize", "events.jl", 130),
                            cu("nonblocking_synchronize", "synchronization.jl"), sf("put!", "./channels.jl")], 1, root, 1)
        @test t.strings[t.func[leaf]] == "waiting on the GPU" && a.waiting == 1 && a.waiting_gpu == 1
        @test all(v -> v[2] == 0 && v[6] == 1, values(a.lines))
        leaf2 = RE._add!(a, [sf("top", "cell:g", 4), ff("cufftXtExec", 9), ff("check", 21),
                             cu("retry_reclaim", "memory.jl", 506), ff("#cufftXtExec##0", 9)], 1, root, 1)
        @test t.strings[t.func[t.parent[leaf2]]] == "cufftXtExec"
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

    @testset "arming clears the last result, and the sampler is set back afterwards" begin
        before = RE._profile_settings()
        _, p = profile_cell(ProfNS, "ps", "r = work(n ÷ 4)\n")
        @test p !== nothing && RE._profile_settings() == before
        RE.profile_arm!("ps", "cpu")
        @test RE.profile_result("ps") === nothing
        RE.profile_disarm!("ps")
    end

    @testset "a sample caught inside a BLAS kernel is named as BLAS" begin
        fr(f) = Base.StackTraces.StackFrame(Symbol(f), :x, 0, nothing, true, false, 0)
        @test RE._blas_name([fr("dgemv_64_"), fr(".Lgemv_n_kernel_F40")]) == "gemv"
        @test RE._blas_name([fr("dscal_k_NEOVERSEN1")]) == "scal"
        @test RE._blas_name([fr("jl_safepoint_trigger")]) === nothing && RE._blas_name([fr("memmove")]) === nothing
    end

    @testset "another cell's tasks are not this cell's" begin
        sf(file) = Base.StackTraces.StackFrame(:f, Symbol(file), 1)
        @test RE._other_cells([sf("task.jl"), sf("cell:b"), sf("cell:a")], "cell:a")
        @test !RE._other_cells([sf("task.jl"), sf("cell:a"), sf("cell:b")], "cell:a")   # a helper from cell b
        @test !RE._other_cells([sf("task.jl"), sf("array.jl")], "cell:a")
    end

    @testset "the worker's own code is never the user's package" begin
        @test RE._user_pkg("MyModel", "/home/u/dev/MyModel/src/MyModel.jl")
        @test !RE._user_pkg("SlateWorker", "/home/u/.cache/kaimonslate/worker/profile.jl")
        @test !RE._user_pkg("CUDA", "/home/u/.julia/packages/CUDA/abc/src/array.jl")
    end

    @testset "a thinned timeline keeps every thread" begin
        n = 2RE._TL_MAX + 2
        th = UInt[isodd(i) ? 1 : 2 for i in 1:n]
        tl = RE._timeline(th, UInt.(1:n), fill(1, n), [1], 100.0, 1.0)
        @test sort(unique(tl["thread"])) == [1, 2] && length(tl["t"]) <= RE._TL_MAX + 2
    end

    @testset "samples are placed on the run's own clock" begin
        # The clock read here is the one the profiler stamps samples with, so a sample maps to ms from
        # the run's start.
        RE.Profile.clear(); RE.Profile.init(n = 10^5, delay = 0.001)
        c0 = RE._cycles(); t0 = time_ns()
        RE.Profile.@profile (local s = 0.0; for i in 1:20_000_000; s += sin(i); end; s)
        r = (c0, Int64(t0), RE._cycles(), Int64(time_ns()))
        data = RE.Profile.fetch(include_meta = true, limitwarn = false)
        clocks = [data[i - RE.Profile.META_OFFSET_CPUCYCLECLOCK] for i in eachindex(data) if RE.Profile.is_block_end(data, i)]
        RE.Profile.clear()
        toms = RE._clock_ms(r); run_ms = (r[4] - r[2]) / 1e6
        @test !isempty(clocks) && all(c -> 0 <= toms(c) <= run_ms, clocks)
        @test RE._clock_ms((UInt64(5), 0, UInt64(5), 10)) === nothing
    end

    @testset "pauses with no sample from any thread are reported" begin
        smp(c) = RE._Sample(1:0, UInt(1), UInt(1), UInt(c), true)
        # One clock unit per ms: steady 1 ms ticks with two one-second gaps.
        clocks = [0:99; 1100:1199; 2200:2299]
        @test RE._stalls(smp.(clocks), (UInt(0), UInt(2299)), 2299.0) == (2, 2002.0)
        @test RE._stalls(smp.(0:999), (UInt(0), UInt(999)), 999.0) == (0, 0.0)
    end

    @testset "GPU mode keeps the cell's own error and runs the cell if the profiler cannot" begin
        # Without CUPTI bindings the cell still runs, and the profile says why.
        out = Dict{String,Any}()
        @test RE._with_cupti(() -> 42, out, RE._cupti_prepare(Module(:NoCUPTI)), () -> Int64(time_ns())) == 42 && occursin("CUPTI", out["error"])
        # A stand-in CUDA whose CUPTI records nothing: the run goes through, and the cell's error is its own.
        fake = Module(:FakeCUDA)
        Core.eval(fake, :(synchronize() = nothing))
        Core.eval(fake, :(module CUPTI
                const CUPTI_CB_DOMAIN_DRIVER_API = 1; const CUPTI_API_ENTER = 0; const SUCCESS = 0; const CUPTI_API_EXIT = 1
                const CUPTI_ACTIVITY_KIND_DRIVER = 1; const CUPTI_ACTIVITY_KIND_CONCURRENT_KERNEL = 2
                const CUPTI_ACTIVITY_KIND_KERNEL = 3; const CUPTI_ACTIVITY_KIND_MEMCPY = 4; const CUPTI_ACTIVITY_KIND_MEMSET = 5
                unchecked_cuptiGetCallbackName(d, id, ref) = 1
                const CUpti_SubscriberHandle = Ptr{Cvoid}
                struct CUpti_CallbackData; callbackSite::UInt32; correlationId::UInt32; end
                cuptiSubscribe(r, cb, ud) = (r[] = C_NULL; nothing)
                cuptiEnableCallback(on, sub, domain, id) = nothing
                cuptiUnsubscribe(sub) = nothing
                ActivityConfig(kinds) = kinds
                cuptiGetTimestamp(r) = (r[] = 0; nothing)
                enable!(f, cfg) = f()
                process(f, cfg) = nothing
            end))
        g = Dict{String,Any}()
        RE._CUPTI_NAMES[] = nothing
        @test RE._with_cupti(() -> 42, g, RE._cupti_prepare(fake), () -> Int64(time_ns())) == 42 && !haskey(g, "source")
        @test RE._cupti_finish!(g)["source"] == "cupti" && isempty(g["kernels"]) && !haskey(g, "__finish")
        # A cell that throws keeps its own error, and what it did on the GPU is still summarised.
        gt = Dict{String,Any}()
        @test_throws ErrorException("boom") RE._with_cupti(() -> error("boom"), gt, RE._cupti_prepare(fake), () -> Int64(time_ns()))
        @test RE._cupti_finish!(gt)["source"] == "cupti"
        RE._CUPTI_NAMES[] = nothing
    end

    @testset "a CUDA call lands on the notebook line whose stack made it" begin
        # A real stack: a function defined as cell `k1` would define it, called from here.
        m = Module(:CuptiStack)
        Core.eval(m, Meta.parseall("f() = backtrace()\n"; filename = "cell:k1"))
        bt = Base.invokelatest(m.f)
        @test RE._notebook_frame(bt)[1:2] == ("cell:k1", 1)
        @test RE._notebook_frame(backtrace()) == ("", 0, "")
        # The frame-pointer chain finds the same line, from the same place, and what the line called.
        Core.eval(m, Meta.parseall("g(h) = h()\n"; filename = "cell:k2"))
        chain = UInt64[]
        h = Base.invokelatest(m.g, () -> RE._fp_walk(chain))
        nf = RE._notebook_frame(chain)
        @test h != 0 && nf[1:2] == ("cell:k2", 1) && !isempty(nf[3])
        # Recording the same call site twice keeps one stack.
        calls0 = RE._CuptiCalls()
        site() = RE._record_stack!(calls0)
        ids = Int32[]
        for _ in 1:3; push!(ids, Base.invokelatest(m.g, site)); end
        @test allequal(ids) && length(calls0.stacks) == 1
        # Stacks stand in as symbols. A wait starts with queries on the waiting line's stack; the
        # blocking call on CUDA.jl's own thread (no notebook frame) is part of it. A wait with no
        # launch after it drains the cell's work. The profiler's own call after `stop` is left out.
        ms = 1_000_000
        calls = RE._CuptiCalls()
        stacks = Dict(:launch => ("cell:draft", 3, "launch"), :query => ("cell:draft", 15, "synchronize events.jl:130"),
                      :worker => ("", 0, ""), :copy => ("cell:draft", 15, "Array"), :launch20 => ("cell:draft", 20, "k2"),
                      :query22 => ("cell:draft", 22, "synchronize"), :sync22 => ("cell:draft", 22, "synchronize"))
        seq = [(10, 10, 11, :launch), (13, 60, 61, :query), (11, 61.5, 100, :worker), (12, 100.5, 103, :copy),
               (10, 104, 105, :launch20), (13, 106, 107, :query22), (11, 107.5, 140, :sync22), (11, 150, 151, :worker)]
        for (k, (cb, a, b, st)) in enumerate(seq)
            push!(calls.corr, UInt32(k)); push!(calls.cbid, UInt32(cb)); push!(calls.t, round(Int64, a * ms))
            push!(calls.stacks, st); push!(calls.sid, Int32(k)); calls.ends[UInt32(k)] = round(Int64, b * ms)
        end
        frame(bt, _) = stacks[bt]
        names = Dict(UInt32(10) => "cuLaunchKernel", UInt32(11) => "cuStreamSynchronize",
                     UInt32(12) => "cuMemcpyDtoHAsync_v2", UInt32(13) => "cuStreamQuery")
        recs = [(:kernel, "stencil", 12ms, 62ms, UInt32(1), 14, 0), (:copy, "[CUDA memcpy DtoH]", 100ms, 102ms, UInt32(4), 14, 4096),
                (:kernel, "k2", 105ms, 147ms, UInt32(5), 14, 0)]
        g = RE._cupti_summary!(Dict{String,Any}(), calls, names, recs, Int64(0), Int64(10ms); stop = Int64(145ms), frame = frame)
        L = Dict((d["file"], d["line"]) => d for d in g["lines"])
        @test L[("cell:draft", 3)]["launches"] == 1 && L[("cell:draft", 3)]["kernel_ms"] == 50.0 &&
              L[("cell:draft", 15)]["sync"] == [1, 40.0] && L[("cell:draft", 15)]["via"] == "synchronize events.jl:130" &&
              L[("cell:draft", 15)]["copy_bytes"] == 4096 &&
              L[("cell:draft", 22)]["drain"] == [1, 34.0] && L[("cell:draft", 22)]["sync"] == [0, 0.0] &&
              g["kernels"][1] == ["stencil", 1, 50.0] && g["device_ms"] == 94.0
        @test g["wait"]["n"] == 1 && g["wait"]["ms"] == 40.0 && g["wait"]["drain_n"] == 1 && g["wait"]["tail_ms"] == 2.0
        tl = g["timeline"]
        @test length(tl["calls"]) == 7 && tl["gpu"][1][1:3] == [2.0, 52.0, 14] &&
              tl["lines"][tl["gpu"][1][5]] == ["cell:draft", 3]
        # The device was busy 94 of the 135 ms from its first work to its last, with two gaps.
        u = g["util"]
        @test u["span_ms"] == 135.0 && u["busy_ms"] == 94.0 && u["idle_ms"] == 41.0 && u["ngaps"] == 2 &&
              u["gaps"][end][2] == 2 && u["longest"][1][2] == 38.0 && u["longest"][1][3:4] == ["stencil", "[CUDA memcpy DtoH]"]
        @test RE._kernel_name("_Z19gpu_getindex_kernel16CompilerMetadataI11DynamicSize") == "gpu_getindex_kernel" &&
              RE._kernel_name("my_kernel") == "my_kernel"
    end

    @testset "source for a frame is read on the kernel's machine" begin
        s = RE.profile_source("./array.jl")
        @test s["error"] === nothing && occursin("function", s["text"]) && isfile(s["path"])
        @test RE.profile_source("/no/such/file.jl")["error"] !== nothing
        # A stdlib frame names the file where Julia was built; it is read from this Julia's copy.
        built = "/builder/julia-ci/usr/share/julia/stdlib/v$(VERSION.major).$(VERSION.minor)/LinearAlgebra/src/matmul.jl"
        @test RE.profile_source(built)["error"] === nothing && startswith(RE.profile_source(built)["path"], Sys.STDLIB)
    end
end
