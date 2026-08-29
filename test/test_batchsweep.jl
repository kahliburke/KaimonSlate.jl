# Unit tests for the batch reconciler (src/batchsweep.jl) and the launcher interface
# (src/batchlauncher.jl). Most of this runs against a scripted fake launcher, because the point of
# the reconciler is that it derives everything from the store and needs no scheduler to be correct.
# One test at the end does drive real subprocesses through ExecLauncher end to end.
using ReTest
import Serialization
include(joinpath(@__DIR__, "..", "src", "batchsweep.jl"))

const BL = BatchLauncher
const BS = BatchSweep

# A launcher that reports whatever the test tells it to, and records what was submitted.
mutable struct FakeLauncher <: BL.Launcher
    live::Dict{String,Symbol}          # name => :pending | :running
    submitted::Vector{BL.JobSpec}
    fail::Bool
end
FakeLauncher(; live = Dict{String,Symbol}(), fail = false) =
    FakeLauncher(live, BL.JobSpec[], fail)

function BL.submit!(l::FakeLauncher, spec::BL.JobSpec)
    l.fail && error("submit refused")
    push!(l.submitted, spec)
    l.live[spec.name] = :pending
    return "fake-$(spec.name)"
end
BL.poll(l::FakeLauncher, root::AbstractString, names) =
    Dict{String,Symbol}(String(n) => get(l.live, String(n), :unknown) for n in names)
BL.cancel!(l::FakeLauncher, root::AbstractString, names) =
    (n = 0; for x in names; haskey(l.live, String(x)) && (delete!(l.live, String(x)); n += 1); end; n)

specfn(root, project = tempdir()) =
    (name, chunks) -> BL.JobSpec(name, chunks; root,
                                 project, payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))

# For tests about submission bookkeeping rather than about probing: release everything at once so
# the assertion under test is not entangled with the probe wave.
const NOPROBE = BS.FailurePolicy(; probe_chunks = 0)

# A sweep of `nchunk` chunks of `per` shards each, over `fn_src`.
# Chunk and shard keys are namespaced by sweep: two sweeps in one store would otherwise share keys
# and each would see the other's results as its own.
function mksweep(root; nchunk = 2, per = 3, fn_src = "p -> p * 2", sweep = "sweep0")
    chunks = String[]
    n = 0
    for c in 1:nchunk
        chunk = "$(sweep)_c$(c)"
        params = collect((n + 1):(n + per)); n += per
        SlateTask.write_chunk!(root, chunk; fn_src, params,
                               keys = ["$(sweep)_s$(p)" for p in params])
        push!(chunks, chunk)
    end
    BS.write_sweep!(root, sweep, chunks)
    return (sweep, chunks)
end

@testset "batchsweep" begin
    @testset "submission names are content-derived and order-independent" begin
        @test BS.submission_name(["a", "b"]) == BS.submission_name(["b", "a"])
        @test BS.submission_name(["a", "b"]) != BS.submission_name(["a", "c"])
        @test startswith(BS.submission_name(["a"]), "slate-")
    end

    @testset "a fresh sweep is entirely missing" begin
        mktempdir() do root
            sweep, chunks = mksweep(root)
            p = BS.plan(root, sweep)
            @test (p.shards_total, p.shards_done) == (6, 0)
            @test sort(p.to_submit) == sort(chunks)
            @test all(==(:missing), values(p.chunk_state))
            @test !BS.is_complete(p)
            @test BS.fraction(p) == 0.0
        end
    end

    @testset "reconcile submits exactly the missing chunks, once" begin
        mktempdir() do root
            sweep, chunks = mksweep(root)
            l = FakeLauncher()
            p = BS.reconcile!(root, sweep, l, specfn(root); failure_policy = NOPROBE)
            @test length(l.submitted) == 1
            @test sort(l.submitted[1].chunks) == sort(chunks)
            @test all(s -> s in (:pending, :running), values(p.chunk_state))
            @test isempty(p.to_submit)
            # Second pass: the work is live, so nothing new goes out.
            BS.reconcile!(root, sweep, l, specfn(root); failure_policy = NOPROBE)
            @test length(l.submitted) == 1
        end
    end

    @testset "a live submission survives a hub restart" begin
        # The durability property: nothing is carried in memory between these two reconciles, and
        # the second one still knows the work is in flight.
        mktempdir() do root
            sweep, _ = mksweep(root)
            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root); failure_policy = NOPROBE)
            l2 = FakeLauncher(; live = copy(l.live))       # a brand new hub, same cluster
            p = BS.plan(root, sweep; launcher = l2)
            @test isempty(p.to_submit)
            @test all(s -> s === :pending, values(p.chunk_state))
        end
    end

    @testset "without a launcher every unfinished chunk reads as missing" begin
        mktempdir() do root
            sweep, chunks = mksweep(root)
            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root))
            @test sort(BS.plan(root, sweep).to_submit) == sort(chunks)
        end
    end

    @testset "finished shards drop out of the plan" begin
        mktempdir() do root
            sweep, chunks = mksweep(root)
            SlateTask.run_chunk(root, chunks[1])            # run one chunk in-process
            p = BS.plan(root, sweep)
            @test p.shards_done == 3 && p.shards_ok == 3
            @test p.chunk_state[chunks[1]] === :done
            @test p.to_submit == [chunks[2]]
            @test BS.fraction(p) == 0.5
        end
    end

    @testset "a partially finished chunk is resubmitted and resumes" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 1, per = 4)
            SlateTask.run_chunk(root, chunks[1])
            MemoStore.drop_manifest(root, "$(sweep)_s2")             # pretend one shard never landed
            p = BS.plan(root, sweep)
            @test p.chunk_state[chunks[1]] === :missing     # partial counts as missing
            @test p.shards_done == 3
            r = SlateTask.run_chunk(root, chunks[1])        # what the resubmitted job would do
            @test (r.ran, r.skipped) == (1, 3)              # resumes, does not repeat
            @test BS.is_complete(BS.plan(root, sweep))
        end
    end

    @testset "everything done means nothing to submit" begin
        mktempdir() do root
            sweep, chunks = mksweep(root)
            for c in chunks; SlateTask.run_chunk(root, c); end
            l = FakeLauncher()
            p = BS.reconcile!(root, sweep, l, specfn(root))
            @test isempty(l.submitted)
            @test BS.is_complete(p) && BS.fraction(p) == 1.0
        end
    end

    @testset "failures are reported per shard, not as a dead sweep" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 1, per = 4,
                                    fn_src = "p -> p == 2 ? error(\"bad param\") : p")
            SlateTask.run_chunk(root, chunks[1])
            p = BS.plan(root, sweep)
            @test (p.shards_done, p.shards_ok, p.shards_failed) == (4, 3, 1)
            # Finished with failures is its own outcome: settled, but not clean.
            @test p.state === :partial
            @test BS.is_settled(p)
            @test !BS.is_complete(p)
            @test !BS.is_stuck(p)
            fs = BS.failures(root, sweep)
            @test length(fs) == 1 && occursin("bad param", String(fs[1].error))
        end
    end

    @testset "results carry provenance and tolerate unfinished shards" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 2)
            SlateTask.run_chunk(root, chunks[1])
            rs = BS.results(root, sweep)
            @test length(rs) == 4
            @test [r.status for r in rs] == ["ok", "ok", "", ""]
            @test [r.value for r in rs[1:2]] == [2, 4]
            @test all(r -> !isempty(r.ran_on), rs[1:2])
            @test all(r -> r.value === nothing, rs[3:4])
        end
    end

    @testset "progress aggregates one status file per chunk" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 3)
            for c in chunks; SlateTask.run_chunk(root, c); end
            pr = BS.progress(root, sweep)
            @test (pr.total, pr.done, pr.ran, pr.failed) == (6, 6, 6, 0)
            @test pr.chunks == 2
            @test length(readdir(SlateTask.status_dir(root))) == 2
        end
    end

    @testset "sweep state distinguishes the four not-running outcomes" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 2)
            @test BS.plan(root, sweep).state === :pending    # work to do, nothing submitted yet

            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root))
            @test BS.plan(root, sweep; launcher = l).state === :running

            for c in chunks; SlateTask.run_chunk(root, c); end
            p = BS.plan(root, sweep; launcher = l)
            @test p.state === :succeeded && BS.is_complete(p)
        end
    end

    @testset "a chunk that never lands stalls instead of resubmitting forever" begin
        # The walltime-kill / OOM case: the job dies without writing a manifest, so the shard looks
        # exactly like one that was never attempted. Only the attempt budget tells them apart.
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 1, per = 2)
            l = FakeLauncher()
            for _ in 1:BS.MAX_ATTEMPTS
                BS.reconcile!(root, sweep, l, specfn(root))
                empty!(l.live)                      # the job vanished, producing nothing
            end
            p = BS.plan(root, sweep; launcher = l)
            @test p.chunk_attempts[chunks[1]] == BS.MAX_ATTEMPTS
            @test p.chunk_state[chunks[1]] === :exhausted
            @test p.state === :exhausted
            @test BS.is_stuck(p) && !BS.is_settled(p)
            @test isempty(p.to_submit)              # stops on its own
            n = length(l.submitted)
            BS.reconcile!(root, sweep, l, specfn(root))
            @test length(l.submitted) == n          # and stays stopped

            # After raising the walltime, clearing the history lets it go again.
            @test BS.clear_attempts!(root, sweep) >= 1
            p2 = BS.plan(root, sweep; launcher = l)
            @test p2.state === :pending && p2.to_submit == [chunks[1]]
        end
    end

    @testset "retry_failed! clears only the errors" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 1, per = 4,
                                    fn_src = "p -> p == 2 ? error(\"nope\") : p * 3")
            SlateTask.run_chunk(root, chunks[1])
            @test BS.plan(root, sweep).state === :partial
            @test BS.retry_failed!(root, sweep) == 1
            p = BS.plan(root, sweep)
            @test (p.shards_done, p.shards_ok, p.shards_failed) == (3, 3, 0)
            @test p.shards_missing == 1
            @test p.state === :pending                # there is work to submit again
            # The successful shards were not disturbed, so a rerun only redoes the failure. It
            # throws again (the parameter is genuinely bad), which is why errors are not retried
            # automatically.
            r = SlateTask.run_chunk(root, chunks[1]; force = false)
            @test (r.ran, r.skipped, r.failed) == (0, 3, 1)
        end
    end

    @testset "ExecLauncher never exceeds its process limit" begin
        # Each task process is a whole Julia loading a project, so an unbounded process-per-chunk
        # launch is measured in gigabytes. Locally there is no scheduler to enforce this.
        @test length(BL._deal(["c$i" for i in 1:20], 4)) == 4
        @test length(BL._deal(["c$i" for i in 1:20], 1)) == 1
        @test length(BL._deal(["c1", "c2"], 8)) == 2          # never more slices than chunks
        @test sort(vcat(BL._deal(["c$i" for i in 1:7], 3)...)) == sort(["c$i" for i in 1:7])
        @test BL.ExecLauncher().maxproc <= 4
        # Every chunk lands in exactly one slice, so nothing is dropped or run twice.
        sl = BL._deal(["c$i" for i in 1:9], 4)
        @test sum(length, sl) == 9 && length(unique(vcat(sl...))) == 9
    end

    @testset "one process runs several chunks in sequence" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 6, per = 2)
            spec = BL.JobSpec("t", chunks; root, project = tempdir(),
                              payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            cmd = BL.task_command(spec, chunks)
            for c in chunks
                @test occursin(c, cmd)                        # all six on one command line
            end
        end
    end

    @testset "a fresh sweep releases only a probe wave" begin
        # Without this the breaker is decorative: submitting every chunk at once means nothing has
        # finished when the failure rate is judged, and by the time it can be judged the whole
        # sweep has already run.
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 6, per = 2)
            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root))
            @test length(l.submitted) == 1
            @test length(l.submitted[1].chunks) == 1          # one chunk, not six
            @test l.submitted[1].chunks[1] == chunks[1]

            # Once the probe reports, the rest is released.
            empty!(l.live)
            SlateTask.run_chunk(root, chunks[1])
            BS.reconcile!(root, sweep, l, specfn(root))
            @test length(l.submitted) == 2
            @test sort(l.submitted[2].chunks) == sort(chunks[2:end])
        end
    end

    @testset "a broken body is caught by the probe, not after the whole sweep" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 10, per = 4, fn_src = "p -> error(\"broken\")")
            l = FakeLauncher()
            pol = BS.FailurePolicy(; min_sample = 4, max_fraction = 0.5, probe_chunks = 1)
            BS.reconcile!(root, sweep, l, specfn(root); failure_policy = pol)
            @test length(l.submitted[1].chunks) == 1
            empty!(l.live)
            SlateTask.run_chunk(root, chunks[1])              # the probe: 4 units, all fail
            p = BS.reconcile!(root, sweep, l, specfn(root); failure_policy = pol)
            @test p.state === :blocked
            @test length(l.submitted) == 1                    # the other 36 units never went out
        end
    end

    @testset "the breaker stops a sweep that is failing early" begin
        # The failure this prevents: submit thousands of units, wait a day, find the body was
        # broken all along.
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 4, per = 3, fn_src = "p -> error(\"always\")")
            SlateTask.run_chunk(root, chunks[1])          # a pilot chunk: 3 of 3 fail
            pol = BS.FailurePolicy(; min_sample = 3, max_fraction = 0.5)
            p = BS.plan(root, sweep; failure_policy = pol)
            @test p.state === :blocked
            @test BS.is_stuck(p)
            @test occursin("3 of the first 3", p.blocked)
            @test isempty(p.to_submit)                    # the other 9 units are not queued

            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root); failure_policy = pol)
            @test isempty(l.submitted)                    # and nothing goes out
        end
    end

    @testset "the breaker tolerates a few bad parameters in a large sweep" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 10,
                                    fn_src = "p -> p == 3 ? error(\"one bad\") : p")
            SlateTask.run_chunk(root, chunks[1])          # 10 units, 1 failure
            p = BS.plan(root, sweep; failure_policy = BS.FailurePolicy(; min_sample = 5))
            @test p.blocked == ""
            @test p.state === :pending
            @test p.to_submit == [chunks[2]]
        end
    end

    @testset "telemetry gives a rate, an ETA, and an idle age" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 4)
            SlateTask.run_chunk(root, chunks[1])          # half the sweep
            t = BS.telemetry(root, sweep)
            @test t.total == 8 && t.done == 4 && t.ok == 4
            @test BS.fraction(t) == 0.5
            @test t.idle_s >= 0                            # something has completed
            @test t.mean_unit_s >= 0
            @test !isempty(t.hosts)
            # Nothing has finished in a fresh sweep, so an ETA is honestly unknown rather than 0.
            sweep2, _ = mksweep(root; nchunk = 1, per = 2, sweep = "empty0")
            t2 = BS.telemetry(root, sweep2)
            @test t2.done == 0 && t2.eta_s == -1.0 && t2.idle_s == -1.0
        end
    end

    @testset "stalled_for stays quiet on a healthy, unstarted, or deliberately stopped run" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 1, per = 3)
            @test BS.stalled_for(BS.telemetry(root, sweep)) == 0.0   # nothing started yet
            SlateTask.run_chunk(root, chunks[1])
            @test BS.stalled_for(BS.telemetry(root, sweep)) == 0.0   # complete, so not stalled
        end
        mktempdir() do root
            # A blocked sweep is not stuck: it stopped on purpose, and saying "it may be stuck"
            # would send someone looking for a scheduler problem that does not exist.
            sweep, chunks = mksweep(root; nchunk = 4, per = 3, fn_src = "p -> error(\"always\")")
            SlateTask.run_chunk(root, chunks[1])
            pol = BS.FailurePolicy(; min_sample = 3, max_fraction = 0.5)
            t = BS.telemetry(root, sweep; plan = BS.plan(root, sweep; failure_policy = pol))
            @test t.state === :blocked
            @test BS.stalled_for(t) == 0.0
        end
    end

    @testset "the three ways of stopping short are distinguishable" begin
        # Same outward symptom (nothing is progressing), three different causes, three different
        # things to do about it.
        mktempdir() do root
            # 1. The work is failing.
            s1, c1 = mksweep(root; nchunk = 4, per = 3, sweep = "sw_err",
                             fn_src = "p -> error(\"always\")")
            SlateTask.run_chunk(root, c1[1])
            p1 = BS.plan(root, s1; failure_policy = BS.FailurePolicy(; min_sample = 3))
            @test p1.state === :blocked

            # 2. Someone stopped it.
            s2, _ = mksweep(root; nchunk = 3, per = 2, sweep = "sw_cancel")
            l = FakeLauncher()
            BS.reconcile!(root, s2, l, specfn(root); failure_policy = NOPROBE)
            @test BS.plan(root, s2; launcher = l).state === :running
            BS.cancel!(root, s2, l)
            @test BS.plan(root, s2; launcher = l).state === :cancelled

            # 3. It outran its resources: attempted the full budget, never landed.
            s3, c3 = mksweep(root; nchunk = 1, per = 2, sweep = "sw_gone")
            l3 = FakeLauncher()
            for _ in 1:BS.MAX_ATTEMPTS
                BS.reconcile!(root, s3, l3, specfn(root))
                empty!(l3.live)                      # the job vanished, producing nothing
            end
            @test BS.plan(root, s3; launcher = l3).state === :exhausted

            # All three are "stuck", none of them is merely idle.
            for p in (p1, BS.plan(root, s2; launcher = l), BS.plan(root, s3; launcher = l3))
                @test BS.is_stuck(p)
                @test BS.stalled_for(BS.telemetry(root, p.sweep; plan = p)) == 0.0
            end
        end
    end

    @testset "a cancelled sweep is not resurrected by the next reconcile" begin
        # The marker is on disk, not in the hub, so closing the notebook cannot silently un-cancel.
        mktempdir() do root
            sweep, _ = mksweep(root; nchunk = 3, per = 2)
            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root); failure_policy = NOPROBE)
            n = length(l.submitted)
            BS.cancel!(root, sweep, l)

            BS.reconcile!(root, sweep, l, specfn(root))          # same hub
            @test length(l.submitted) == n
            l2 = FakeLauncher()                                  # a brand new hub
            BS.reconcile!(root, sweep, l2, specfn(root))
            @test isempty(l2.submitted)
            @test BS.plan(root, sweep; launcher = l2).state === :cancelled

            # Resuming picks up only what is left.
            @test BS.resume!(root, sweep)
            p = BS.reconcile!(root, sweep, l2, specfn(root))
            @test !isempty(l2.submitted)
            @test p.state !== :cancelled
        end
    end

    @testset "cancelling keeps what already finished" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 3, per = 2)
            SlateTask.run_chunk(root, chunks[1])
            l = FakeLauncher()
            BS.cancel!(root, sweep, l)
            p = BS.plan(root, sweep; launcher = l)
            @test p.state === :cancelled
            @test p.shards_done == 2 && p.shards_missing == 4
            BS.resume!(root, sweep)
            # Only the unfinished chunks are queued again.
            @test sort(BS.plan(root, sweep).to_submit) == sort(chunks[2:end])
        end
    end

    @testset "cap refuses an oversized submission" begin
        mktempdir() do root
            sweep, _ = mksweep(root; nchunk = 4, per = 1)
            l = FakeLauncher()
            @test_throws ErrorException BS.reconcile!(root, sweep, l, specfn(root); cap = 2)
            @test isempty(l.submitted)
        end
    end

    @testset "a refused submit leaves nothing looking live" begin
        # If the index file survived a failed sbatch, the next reconcile would believe the work was
        # in flight and never resubmit it.
        mktempdir() do root
            sweep, chunks = mksweep(root)
            l = FakeLauncher(; fail = true)
            @test_throws ErrorException BS.reconcile!(root, sweep, l, specfn(root))
            @test isempty(BS.known_submissions(root))
            @test sort(BS.plan(root, sweep).to_submit) == sort(chunks)
        end
    end

    @testset "end to end through ExecLauncher subprocesses" begin
        mktempdir() do root
            sweep, chunks = mksweep(root; nchunk = 2, per = 2)
            l = BL.ExecLauncher()
            # Reconcile on a loop, which is what a monitor does: the first pass releases only the
            # probe wave, and later passes send the rest once it has reported.
            done = false
            for _ in 1:120
                BS.reconcile!(root, sweep, l, specfn(root))
                BS.is_complete(BS.plan(root, sweep; launcher = l)) && (done = true; break)
                sleep(1)
            end
            p = BS.plan(root, sweep)
            @test done
            @test (p.shards_total, p.shards_ok, p.shards_failed) == (4, 4, 0)
            @test [r.value for r in BS.results(root, sweep)] == [2, 4, 6, 8]
        end
    end
end
