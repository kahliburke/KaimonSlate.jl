# The `#%% sweep` cell kind: parse/serialize round-trip and the kind predicates that decide how the
# engine treats it. The lifecycle and the renderer are separate; this is the plumbing that has to be
# right before either can be built, because it is what every notebook file on disk depends on.
using ReTest
import KaimonSlate
const RE = KaimonSlate.ReportEngine

findcell(r, id) = r.cells[findfirst(c -> c.id == id, r.cells)]

@testset "sweep cell kind" begin
    @testset "parses from the header token" begin
        r = RE.parse_report("""
        #%% sweep id=scan
        @sweep(grid, target) do p
            work(p)
        end
        """)
        c = findcell(r, "scan")
        @test c.kind === RE.SWEEP
        @test occursin("@sweep", c.source)
    end

    @testset "round-trips through serialization" begin
        src = """
        #%% md id=intro
        # A sweep

        #%% sweep id=scan
        @sweep(grid, target) do p
            work(p)
        end

        #%% code id=after
        summary = length(scan)
        """
        r = RE.parse_report(src)
        out = RE.serialize_report(r)
        @test occursin("#%% sweep id=scan", out)
        r2 = RE.parse_report(out)
        @test [c.kind for c in r2.cells] == [c.kind for c in r.cells]
        @test findcell(r2, "scan").kind === RE.SWEEP
        @test findcell(r2, "after").kind === RE.CODE
    end

    @testset "header tags survive alongside the kind" begin
        # Target and resources ride in the header so the tag editor can drive them without the
        # author editing Julia.
        r = RE.parse_report("""
        #%% sweep id=scan collapsed
        @sweep(grid, target) do p; work(p); end
        """)
        c = findcell(r, "scan")
        @test c.kind === RE.SWEEP
        @test :collapsed in c.flags
        @test occursin("#%% sweep id=scan", RE.serialize_report(r))
        @test occursin("collapsed", RE.serialize_report(r))
    end

    @testset "is evaluated, and participates in the graph, exactly like code" begin
        # This is what buys full DAG integration for free: deps, capture, staleness, memoization.
        @test RE.is_code_kind(RE.SWEEP)
        @test RE.is_code_kind(RE.CODE)
        @test !RE.is_code_kind(RE.MARKDOWN)
    end

    @testset "runs automatically, unlike a tool call" begin
        # Evaluating a sweep cell RECONCILES (reads the store and the scheduler); it does not submit.
        # That is what makes reopening a notebook safe, so unlike TOOL it is not excluded from
        # automatic runs — otherwise a reopened notebook could never show progress on its own.
        @test RE.runs_automatically(RE.SWEEP)
        @test !RE.runs_automatically(RE.TOOL)
    end

    @testset "dependencies are inferred from the body" begin
        # A plain call, not the `@sweep` macro: expanding an unknown macro needs a kernel
        # (`resolve_macros!`), which is an orthogonal mechanism Slate already has. What is being
        # checked here is that the KIND participates in the graph at all.
        r = RE.parse_report("""
        #%% code id=g
        grid = [1, 2, 3]

        #%% sweep id=scan
        results = run_sweep(grid, tgt)

        #%% code id=plot
        total = sum(results)
        """)
        RE.build_dependencies!(r)
        @test :grid in findcell(r, "scan").reads
        @test :results in findcell(r, "plot").reads
        @test "scan" in findcell(r, "plot").deps
    end

    # The scheduler options the cell editor suggests. A CATALOGUE, not a permitted set: the editor
    # warns outside it and forwards the name anyway, because a scheduler has far more options than
    # are worth naming and a site can add its own. What must not happen is the previous failure —
    # a name Slate accepts, parses, and then never emits.
    @testset "the option catalogue cannot drift from what Slate emits" begin
        S = RE.Sweep
        opts = S.sched_options()
        @test length(opts) == length(S._ATTR_RESOURCES)
        # Every catalogued option carries a hint; the editor shows it, so a missing one is a blank
        # row in the UI rather than a test failure nobody sees.
        @test all(o -> !isempty(o.hint), opts)
        # …and the header spelling maps to sbatch's, `_` → `-`.
        by = Dict(o.key => o for o in opts)
        @test by["mem_per_cpu"].flag == "mem-per-cpu"
        @test by["ntasks_per_node"].flag == "ntasks-per-node"
        @test by["cpus"].flag == "cpus-per-task"     # the three whose names predate the rest
        @test by["walltime"].flag == "time"
        @test by["constraint"].flag == "constraint"
        @test by["cpus"].count && by["gpus"].count && !by["mem"].count

        # BOTH spellings ride in one list: the editor is opened before it knows which cluster the
        # cell names, and typing either spelling has to land on the same stored key.
        @test by["cpus"].pbs == "select=…:ncpus" && by["partition"].pbs == "-q"
        @test by["walltime"].pbs == "-l walltime" && by["account"].pbs == "-A"
        # An empty spelling means that scheduler cannot say it at all, which the editor SHOWS. The
        # alternative — offering a setting whose only effect is a rejected job — is the failure this
        # catalogue exists to prevent, in the other direction.
        @test by["constraint"].pbs == "" && by["gres"].pbs == "" && by["reservation"].pbs == ""
        # …but only where translation would be a guess. Anything mechanical is spelled, not refused.
        @test by["mem_per_cpu"].pbs != "" && by["nodelist"].pbs == "select=…:host"
        @test by["select"].pbs == "-l select"

        # The split the editor makes must be the split Julia makes, or a Slate setting is forwarded
        # to sbatch as a job option (or a scheduler option is silently treated as one of ours).
        @test !S.is_sched_attr("cluster") && !S.is_sched_attr("chunk") && !S.is_sched_attr("region")
        @test S.is_sched_attr("licenses") && S.is_sched_attr("walltime")
        # An option nobody has catalogued still becomes a real flag.
        @test S.BatchLauncher.sbatch_flag(:switches) == "switches"
        @test S.BatchLauncher.sbatch_flag(:mem_bind) == "mem-bind"
    end

    # A scheduler option that a cell HEADER cannot carry — an `=` or a space in the value — is why
    # these live in the footer instead. The whole point is that a notebook can say everything a
    # hand-written batch script said, so the round trip has to survive the characters that forced
    # the move in the first place.
    @testset "per-cell scheduler options round-trip through the footer" begin
        src = """
        #%% sweep id=scan cluster=hpc
        @sweep(grid) do p
            p.x
        end
        """
        r = RE.parse_report(src)
        r.meta["sweepopts"] = Dict("scan" => Dict(
            "licenses"   => "ansys@srv:2",        # `@` and `:`
            "constraint" => "(avx512|avx2)&!gpu", # parentheses, pipe, ampersand, bang
            "comment"    => "run for the paper",  # spaces
            "walltime"   => "04:00:00"))
        out = RE.serialize_report(r)
        @test occursin("# ╔═╡ Slate.sweep", out)
        back = RE.parse_report(out)
        @test back.meta["sweepopts"]["scan"] == r.meta["sweepopts"]["scan"]
        # …and the cells are untouched by a footer that now sits below them.
        @test [c.id for c in back.cells] == [c.id for c in r.cells]
        @test findcell(back, "scan").kind === RE.SWEEP

        # Stable across a re-serialise, or every save churns the file.
        @test RE.serialize_report(back) == out

        # Nothing to say ⇒ no block at all, rather than an empty one accreting in every notebook.
        r2 = RE.parse_report(src)
        @test !occursin("Slate.sweep", RE.serialize_report(r2))
        r2.meta["sweepopts"] = Dict("scan" => Dict{String,String}())
        @test !occursin("Slate.sweep", RE.serialize_report(r2))

        # JSON escapes, so even a newline survives — the format's problem, not ours. This is the
        # whole reason for moving off header tags, so it is worth asserting rather than assuming.
        r3 = RE.parse_report(src)
        r3.meta["sweepopts"] = Dict("scan" => Dict("script" => "one\ntwo", "ok" => "1"))
        b3 = RE.parse_report(RE.serialize_report(r3))
        @test b3.meta["sweepopts"]["scan"]["script"] == "one\ntwo"
        # …and the block stays ONE line per cell: the newline is escaped, not emitted, so it cannot
        # split the record across lines and orphan the rest of the footer.
        blk = split(RE.serialize_report(r3), "Slate.sweep")[2]
        @test count(l -> startswith(l, "#   {"), split(blk, '\n')) == 1
        # …and a hand-edited line that is not valid JSON is skipped, not thrown: a malformed option
        # must never stop a notebook opening.
        broken = replace(RE.serialize_report(r3), "{\"cell\"" => "{oops\"cell\"")
        @test (RE.parse_report(broken); true)

        # The footer coexists with the config footer — both are parsed from the first Slate mark and
        # each stops at its own close, so neither eats the other.
        r4 = RE.parse_report(src)
        r4.meta["threads"] = "4"
        r4.meta["sweepopts"] = Dict("scan" => Dict("licenses" => "x@y"))
        b4 = RE.parse_report(RE.serialize_report(r4))
        @test b4.meta["threads"] == "4"
        @test b4.meta["sweepopts"]["scan"]["licenses"] == "x@y"
    end

    # `script = "model.jl"` — the definitions the body calls, kept in a file rather than pasted into
    # the cell. It must ride `setup_src`, because that is simultaneously what SHIPS to the compute
    # node and what is DIGESTED into the sweep key. A bare `include` would do neither: the file
    # would be absent on the far side, and editing it would not invalidate anything, so the sweep
    # would serve results computed from a version of the code that no longer exists.
    @testset "a sweep's script file ships and is keyed" begin
        S = RE.Sweep
        mktempdir() do dir
            f = joinpath(dir, "model.jl")
            write(f, "step(x) = 2x\n")
            # A stand-in for the notebook namespace: `_script_src` only needs the file resolver that
            # `@asset` uses, which is what makes the path resolve the same way on a remote worker.
            mod = Module(:FakeNb)
            Core.eval(mod, :(__slate_readfile(p; bytes = false) = read(joinpath($dir, p), String)))
            @test S._script_src(mod, "model.jl") == "step(x) = 2x\n"
            @test S._script_src(mod, "") == ""                  # no script named ⇒ nothing added

            # The key MOVES when the script does — that is the property a bare `include` cannot have.
            k1 = S.sweep_key("p -> step(p.x)", S._script_src(mod, "model.jl"), Dict())
            write(f, "step(x) = 3x\n")
            k2 = S.sweep_key("p -> step(p.x)", S._script_src(mod, "model.jl"), Dict())
            @test k1 != k2
            # …and does not move when nothing changed, or a resumed sweep would discard its results.
            @test k2 == S.sweep_key("p -> step(p.x)", S._script_src(mod, "model.jl"), Dict())

            # A missing file says so, naming how the path is resolved — the commonest mistake here
            # is a path relative to the wrong thing.
            @test_throws ErrorException S._script_src(mod, "absent.jl")
            # …and a namespace with no resolver points at the option that does work there.
            @test_throws ErrorException S._script_src(Module(:Bare), "model.jl")
        end
    end
end
