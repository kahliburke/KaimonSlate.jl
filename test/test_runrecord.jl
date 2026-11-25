# A cell's run in flight is a `Run` record beside its state, and every outcome reaches the cell through
# `_settle!`. These pin the rules that record exists for: an input that changes mid-run reruns the cell,
# a result for a namespace that has gone is dropped, Stop halts the drain and holds the stopped cell's
# readers, and nothing but a run moves a cell's state.
using ReTest
include(joinpath(@__DIR__, "freeport.jl"))
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

mknb(id, src) = NS.LiveNotebook(id, joinpath(mktempdir(), "$id.jl"), RE.parse_report(src; title = id),
    RE.InProcessKernel(), 1, String[], String[], ReentrantLock(), Channel{String}[],
    ReentrantLock(), "", false, Dict{String,String}())
cellof(nb, id) = nb.report.cells[findfirst(c -> c.id == id, nb.report.cells)]

@testset "run record" begin
    @testset "one run per cell, and RUNNING is derived from it" begin
        c = RE.Cell("c", RE.CODE, "1")
        @test RE.shown_state(c) == RE.STALE
        run = RE.begin_run!(c)
        @test RE.is_running(c) && RE.shown_state(c) == RE.RUNNING && c.state == RE.STALE
        @test_throws Exception RE.begin_run!(c)
        # Ending someone else's run does nothing.
        @test !RE.end_run!(c, RE.Run(RE._new_run_id(), c.src_hash, "", :preparing, false, 0.0, time(), 0.0, nothing, 0, 0))
        @test RE.end_run!(c, run) && !RE.is_running(c)
        @test RE._new_run_id() != RE._new_run_id()
    end

    @testset "an edit while a run is out reruns the cell whatever the run ends in" begin
        nb = mknb("edited", "#%% code id=a\nx = 1\n")
        run = RE.begin_run!(cellof(nb, "a"))
        RE.update_source!(nb.report, "#%% code id=a\nx = 2\n")
        @test cellof(nb, "a").run === run && run.rerun
        # A failure for the old source (a region that could not come up) must not leave the edit ERRORED.
        NS._settle!(c -> RE.mark_errored!(c, "no node"), nb, "a", run)
        a = cellof(nb, "a")
        @test a.run === nothing && a.state == RE.STALE
    end

    @testset "a result for a namespace that is gone is dropped" begin
        nb = mknb("dropped", "#%% code id=a\nx = 1\n")
        run = RE.begin_run!(cellof(nb, "a"))
        e0 = nb.epoch
        lock(nb.lock) do; NS._drop_runs!(nb); end
        @test cellof(nb, "a").run === nothing && nb.epoch == e0 + 1
        @test NS._settle!(c -> (RE.mark_result!(c, nothing); :applied), nb, "a", run) === nothing
        @test cellof(nb, "a").state == RE.STALE && cellof(nb, "a").output === nothing
    end

    @testset "a stopped cell holds its readers until it runs again" begin
        nb = mknb("held", "#%% code id=a\nx = 1\n#%% code id=b\ny = x + 1\n")
        RE.build_dependencies!(nb.report)
        a, b = cellof(nb, "a"), cellof(nb, "b")
        run = RE.begin_run!(a)
        NS._settle!(c -> RE.mark_stopped!(c, nothing), nb, "a", run)
        RE.mark_blocked!(b, NS.WAIT_UPSTREAM_STOPPED, "a")
        @test a.state == RE.STOPPED
        # An input change, a reset or a worker restart leaves a stop in place; a run asked for ends it.
        @test !RE.restale!(a) && a.state == RE.STOPPED
        RE.reset_all!(nb.report)
        @test a.state == RE.STOPPED
        RE.mark_blocked!(b, NS.WAIT_UPSTREAM_STOPPED, "a")
        RE.request_run!(a)
        @test a.state == RE.STALE
        run2 = RE.begin_run!(a)
        NS._settle!(c -> RE.mark_result!(c, nothing), nb, "a", run2)
        @test a.state == RE.FRESH && b.state == RE.STALE && b.blocked == ""
    end

    @testset "a live re-render replaces the view and nothing else" begin
        nb = mknb("rerender", "#%% code id=a\nx = 1\n")
        a = cellof(nb, "a")
        RE.mark_result!(a, RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], "1", nothing, nothing, 0.0))
        wire = nothing
        rev = a.rev
        NS.apply_live_rerender!(nb, "a", wire)
        @test a.state == RE.FRESH && a.rev > rev
        # Not while a run is out: that run produces the view.
        run = RE.begin_run!(a); rev = a.rev
        NS.apply_live_rerender!(nb, "a", wire)
        @test a.rev == rev && a.run === run
    end

    @testset "a side's results belong to the worker they were computed in" begin
        nb = mknb("sides", "#%% code id=a\nx = 1\n#%% code id=g region=gpu\ny = 2\n" *
                           "#%% code id=h region=gpu\nz = y + 1\n#%% md id=m\nprose\n")
        RE.build_dependencies!(nb.report)
        for c in nb.report.cells; RE.mark_fresh!(c); end
        RE.mark_stopped!(cellof(nb, "h"), nothing)
        @test NS._note_side_worker!(nb, "gpu", UInt(1)) === :first
        @test NS._note_side_worker!(nb, "gpu", UInt(1)) === :same
        @test NS._note_side_worker!(nb, "gpu", UInt(2)) === :changed
        @test NS._note_side_worker!(nb, "", UInt(2)) === :first           # each side has its own
        # A new worker on the region: its cells run again; the notebook's own, and prose, keep theirs.
        NS._invalidate_side!(nb, "gpu", RE.InProcessKernel())
        @test [c.state for c in nb.report.cells] == [RE.FRESH, RE.STALE, RE.STOPPED, RE.FRESH]
        # Only a connected gate worker is compared: a key read before it connects is not final.
        @test !NS._check_side!(nb, "gpu", RE.InProcessKernel())
        @test !NS._check_side!(nb, "gpu", RE.GateKernel(mktempdir()))
        @test NS._kernel_gen(RE.GateKernel(mktempdir())) == -1
    end

    @testset "Stop halts the drain, and only a run asked for resumes it" begin
        hub = NS.start_hub(; port = freeport())
        try
            nbp = tempname() * ".jl"
            write(nbp, "#%% code id=a\nn = 0\nfor i in 1:3000\n    @info \"step\" i\n    sleep(0.01)\n    global n = i\nend\nn\n" *
                       "#%% code id=b\nm = n + 1\n" *
                       "#%% code id=c\nk = 3\n")
            nb = hub.notebooks[NS.open_notebook!(hub, nbp; autorun = false)]
            t = Threads.@spawn NS._eval!(nb; wait_all = true)
            started = timedwait(10.0; pollint = 0.02) do
                r = cellof(nb, "a").run
                r !== nothing && r.phase === :dispatched
            end
            sleep(0.3)
            NS.cancel_run!(nb)
            ended = timedwait(() -> istaskdone(t), 20.0; pollint = 0.05)
            @test (started, ended) == (:ok, :ok)
            @test nb.halted && cellof(nb, "a").state == RE.STOPPED
            @test cellof(nb, "a").output.exception == "Stopped"
            # Nothing started after the stop.
            @test cellof(nb, "b").state == RE.STALE && cellof(nb, "c").state == RE.STALE

            # A run of a reader waits on the stopped cell instead of computing from what it left behind.
            NS.edit_cell!(nb, "b", "m = n + 2"; force = true)
            NS._eval!(nb; wait_for = "b")
            b = cellof(nb, "b")
            @test (b.state, b.blocked, b.blocked_host) == (RE.BLOCKED, NS.WAIT_UPSTREAM_STOPPED, "a")
            @test !nb.halted && cellof(nb, "a").state == RE.STOPPED

            # Running the stopped cell again lets its reader go.
            NS.edit_cell!(nb, "a", "n = 5"; force = true)
            NS._eval!(nb; wait_all = true)
            @test cellof(nb, "a").state == RE.FRESH
            @test (cellof(nb, "b").state, cellof(nb, "b").output.value_repr) == (RE.FRESH, "7")
            @test cellof(nb, "c").state == RE.FRESH
        finally
            NS.stop_hub(hub)
        end
    end
end

# Between a worker connecting and its first cell, the hub loads the notebook's packages there and reads
# their exports. Each step is published with the worker, so the page can say what the notebook waits on.
@testset "the setup a worker does before the first cell is published" begin
    @test NS._cell_packages("using CairoMakie, Dates\nusing DataFrames: DataFrame\nimport A.B as C\nusing .Local\nx = 1") ==
          ["CairoMakie", "Dates", "DataFrames", "A.B"]
    @test NS._cell_packages("this does not parse (") == String[]
    @test NS._names_phrase(["A"]) == "A"
    @test NS._names_phrase(["A", "B"]) == "A and B"
    @test NS._names_phrase(["A", "B", "C", "D"]) == "A, B and 2 more"

    nb = mknb("setup", "#%% code id=a\nusing Statistics\n")
    @test NS._setup(nb, "") === nothing
    seen = NS._with_setup(nb, "", "loading"; pkgs = ["Statistics"], cell = "a") do
        outer = NS._setup(nb, "")
        inner = NS._with_setup(() -> NS._setup(nb, ""), nb, "", "reading"; pkgs = ["Statistics", "Dates", "Random"])
        (outer, inner, NS._setup(nb, ""))
    end
    outer, inner, after_inner = seen
    @test (outer.stage, outer.what, outer.cell) == ("loading", "Statistics", "a")
    # A nested stage keeps the clock of the setup it is part of, and hands the outer one back.
    @test inner.stage == "reading" && inner.since == outer.since
    @test after_inner == outer
    @test NS._setup(nb, "") === nothing
    @test NS._setup_face(outer) == "loading Statistics"
    # The pill has room for one name; more than one is counted, and the note names them.
    @test NS._setup_face(inner) == "reading 3 packages" && inner.what == "Statistics, Dates and 1 more"
    # A failure inside a stage still ends it.
    @test_throws ErrorException NS._with_setup(() -> error("boom"), nb, "", "loading")
    @test NS._setup(nb, "") === nothing
end
