# Unit tests for the batch reconciler (src/batchsweep.jl) and the launcher interface
# (src/batchlauncher.jl). Most of this runs against a scripted fake launcher, because the point of
# the reconciler is that it derives everything from the store and needs no scheduler to be correct.
# One test at the end does drive real subprocesses through ExecLauncher end to end.
using ReTest
import Serialization
# sweep.jl pulls in batchsweep.jl (and slatetask/memostore/batchlauncher) behind its own guards.
# It has to be included at file top level: a macro used in a testset is resolved when the testset is
# parsed, which is before anything inside it has run.
include(joinpath(@__DIR__, "..", "src", "sweep.jl"))

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

    @testset "card actions do what their labels say" begin
        # These are the destructive controls, so each one's blast radius is pinned. In particular
        # cancel must KEEP finished units (resuming should cost only what is left) while reset
        # throws them away — the difference between the two is the whole reason both exist.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            g = Sweep.paramgrid(x = 1:4)
            r = Sweep.@sweep(g, t; submit = false) do p
                p.x == 2 ? error("bad") : p.x
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).plan.shards_failed == 1

            # retry clears only the failure
            s = Sweep.handle_action(t, r.run, r.params, r.keys, "retry")
            @test s["failed"] == 0 && s["ok"] == 3 && s["missing"] == 1

            # cancel stops it and is durable, but keeps what finished
            s = Sweep.handle_action(t, r.run, r.params, r.keys, "cancel")
            @test s["state"] == "cancelled" && s["ok"] == 3
            @test BS.is_cancelled(root, r.run)

            # resume lifts the stop without touching results
            s = Sweep.handle_action(t, r.run, r.params, r.keys, "resume")
            @test s["state"] != "cancelled" && s["ok"] == 3
            @test !BS.is_cancelled(root, r.key)

            # reset throws the results away
            s = Sweep.handle_action(t, r.run, r.params, r.keys, "reset")
            @test s["done"] == 0 && s["ok"] == 0

            @test_throws ErrorException Sweep.handle_action(t, r.run, r.params, r.keys, "nonsense")
        end
    end

    @testset "the settle report brings the result level with the card" begin
        # A sweep finishes long after the cell that started it returned, and that cell must NOT be
        # re-run (it would resubmit) — so the result object keeps the plan it was built with. The
        # card polls the store and knew better: it read "finished, with failures" beside an
        # `r.settled` of false, and every counter was stale with it.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 2 ? error("bad") : p.x
            end
            # Built before anything ran, so the snapshot says nothing has landed.
            @test !r.settled && r.done == 0

            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            # The store has moved on; the object has not, and nothing about reading it says so.
            @test !r.settled && r.done == 0

            # What the card reports when it sees the sweep stop. `landed` is the hook `run_sweep`
            # wires to the live result; supplied here by hand since no notebook registered one.
            s = Sweep.handle_action(t, r.run, r.params, r.keys, "settled";
                                    landed = () -> Sweep.refresh!(r))
            @test s["settled"] && s["done"] == 4               # the card's view
            @test r.settled && r.done == 4                     # …and now the object's too
            @test r.failed == 1 && r.ok == 3
            # Settled means every unit reached a terminal state; the failure does not unsettle it.
            @test r.state === :partial
        end

        # …and the same thing through the wiring a notebook actually gets, since the hook above was
        # handed in by the test. `run_sweep` registers the action channel BEFORE the result exists,
        # so it fills a Ref afterwards; a Ref left empty would make all of this a no-op in the one
        # place it matters.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            chans = Dict{String,Any}()
            r2 = Sweep.run_sweep(t, [(; x = 1), (; x = 2)], "p -> p.x";
                                 register = (ch, f) -> (chans[String(ch)] = f))
            @test !r2.settled && r2.done == 0
            for c in BS.sweep_chunks(root, r2.run); SlateTask.run_chunk(root, c); end
            @test !r2.settled                                   # still the snapshot

            act = chans[Sweep.action_channel(r2.run)]
            s = act(Dict(:action => "settled"))
            @test s["settled"] && s["done"] == 2
            @test r2.settled && r2.done == 2 && r2.ok == 2      # the Ref was filled and fired
        end
    end

    @testset "a host says whether it fronts a scheduler" begin
        # What kind of host this is decides what a region on it MEANS, and so which questions its
        # configuration should ask. A plain machine: ssh in and run. A scheduler's front door: ask
        # for an allocation, and the node you get is an output, not a setting — so it needs a
        # walltime, a partition, CPUs, maybe GPUs, and none of that belongs on a workstation.
        SD = Sweep.SchedulerDetect
        canned(out) = _ -> (true, out)

        h = SD.detect(canned("""
            KIND slurm
            VERSION slurm slurm-wlm 24.11.5
            PART slurm compute|(null)|infinite|up
            PART slurm gpu|gpu:a100:4|3-00:00:00|up
            PART slurm broken|(null)|1:00|down
            """))
        @test SD.is_cluster(h) && SD.suggested(h) === :slurm
        s = SD.scheduler(h, :slurm)
        @test s.version == "slurm-wlm 24.11.5"
        @test [p.name for p in s.partitions] == ["compute", "gpu", "broken"]
        @test [p.name for p in SD.gpu_partitions(s)] == ["gpu"]     # only where GPUs exist
        @test s.partitions[1].gpus == ""                            # "(null)" is not a GPU spec
        @test s.partitions[2].maxtime == "3-00:00:00"               # the ceiling a walltime must fit
        @test !s.partitions[3].up
        @test occursin("with GPUs", sprint(show, s))

        # BOTH can be present — a site mid-migration, or PBS compatibility wrappers on a SLURM
        # cluster, where finding `qsub` says nothing about what runs the jobs. Detection reports
        # what it found and suggests the first; it does not choose.
        b = SD.detect(canned("""
            KIND slurm
            VERSION slurm slurm-wlm 24.11.5
            PART slurm compute|(null)|infinite|up
            KIND pbs
            VERSION pbs pbs_version = 2022.1
            PART pbs main|gpu:4|24:00:00|up
            """))
        @test SD.kinds(b) == [:slurm, :pbs]
        @test SD.suggested(b) === :slurm                            # a default…
        @test SD.resolve(b, :pbs) === :pbs                          # …that config can override
        @test SD.resolve(b, :auto) === :slurm
        @test SD.resolve(b, :none) === :none                        # or decline a scheduler entirely
        @test SD.has_gpu(only(SD.scheduler(b, :pbs).partitions))
        @test SD.scheduler(b, :none) === nothing
        @test occursin("slurm + pbs", sprint(show, b))

        # An explicit choice is honoured even where detection found nothing: the tools may sit
        # behind a `module load`, and refusing to configure what the user knows is there is worse.
        none = SD.detect(canned(""))
        @test !SD.is_cluster(none) && SD.resolve(none, :auto) === :none
        @test SD.resolve(none, :slurm) === :slurm
        # Unreachable is not a cluster either — and must not throw.
        @test !SD.is_cluster(SD.detect(_ -> (false, "")))
        @test !SD.is_cluster(SD.detect(_ -> error("host is down")))
        @test occursin("ordinary machine", sprint(show, none))
    end

    @testset "a queued cell can say what the cluster is busy with" begin
        # Detection reports what a host OFFERS and never changes; this reports what is FREE, which
        # is the only thing that explains a wait. "Queued" alone does not distinguish thirty
        # seconds from tomorrow.
        SD = Sweep.SchedulerDetect
        canned(out) = _ -> (true, out)

        # SLURM: `%C` is allocated/idle/other/total CPUS, `%A` allocated/idle NODES.
        s = SD.load(canned("""
            LOAD slurm compute|12/20/0/32|4|1/3
            LOAD slurm gpu|8/0/0/8|1|1/0
            PEND slurm 7
            DOWN slurm 2
            ETA slurm 2026-09-05T14:20:00
            """), :slurm)
        @test [q.name for q in s] == ["compute", "gpu"]
        @test (s[1].cpus_free, s[1].cpus_total) == (20, 32)
        @test (s[1].nodes_free, s[1].nodes_total) == (3, 4)
        @test s[2].cpus_free == 0                      # full, and that is the answer to "why wait"
        # Scheduler-wide facts describe the scheduler, not a queue, so every row carries them.
        @test all(q -> q.queued == 7 && q.down == 2, s)
        @test all(q -> q.eta == "2026-09-05T14:20:00", s)
        @test occursin("20/32 cpus free", sprint(show, s[1]))
        @test occursin("7 queued", sprint(show, s[1]))
        @test occursin("2 down", sprint(show, s[1]))

        # An estimate the scheduler declines to make is not an estimate. SLURM says N/A when backfill
        # has nothing; reporting that verbatim would put "starts ~N/A" in front of someone waiting.
        @test only(SD.load(canned("LOADPBS 0|2|0|8\nETA pbs N/A"), :pbs)).eta == ""

        # The job name reaches the script — that is what makes the ETA OURS rather than the queue's —
        # and nothing but job-name characters survives the trip.
        seen = Ref("")
        SD.load(s -> (seen[] = s; (true, "")), :pbs; job = "slate-r1; rm -rf /")
        # The name reaches the script stripped to job-name characters, so the injected command never
        # arrives as one. (The script has semicolons of its own — what matters is that none of THESE
        # survived: no separator, no argument, no path.)
        @test occursin("slate-r1rm-rf", seen[])
        @test !occursin("; rm", seen[]) && !occursin("rm -rf", seen[]) && !occursin("-rf /", seen[])

        # PBS counts nodes once — it has no per-queue view of free CPUs — so the same figures are
        # reported against each queue asked about. Verified against a live cluster: two 4-cpu nodes
        # idle reads as 8/8.
        p = SD.load(canned("LOADPBS 2|2|8|8\nPEND pbs 0\nDOWN pbs 0\n"), :pbs, ["workq", "gpuq"])
        @test [q.name for q in p] == ["workq", "gpuq"]
        @test all(q -> (q.cpus_free, q.cpus_total, q.nodes_free) == (8, 8, 2), p)
        @test !occursin("queued", sprint(show, p[1]))  # a queue of nothing is not news

        # Named queues are optional; without them PBS still has one honest thing to say.
        @test only(SD.load(canned("LOADPBS 1|2|4|8"), :pbs)).name == "(cluster)"

        # A wait with no explanation beats an invented one: an unreachable or silent host says
        # nothing rather than reporting a cluster that is empty.
        @test isempty(SD.load(_ -> (false, ""), :slurm))
        @test isempty(SD.load(_ -> error("host is down"), :pbs, ["workq"]))
        @test isempty(SD.load(canned("LOAD slurm mangled|not/a/count"), :slurm))
    end

    @testset "waiting on a queue backs off instead of hammering the login node" begin
        # Every poll is a command on a shared login node. A queue wait is minutes to hours, so a
        # fixed 2s interval spends thousands of them to learn nothing — the cadence sites complain
        # about. The common case is still a cluster with room, which answers in seconds, so the
        # first stretch stays fast and only a genuinely long wait backs off.
        SW = Sweep
        @test SW._poll_gap(0) == SW._POLL_BACKOFF.first          # a free cluster is not made to wait
        @test SW._poll_gap(SW._POLL_BACKOFF.fast_for) == SW._POLL_BACKOFF.first
        @test SW._poll_gap(60) > SW._POLL_BACKOFF.first          # …a slow one stops being asked so often
        @test SW._poll_gap(3600) == SW._POLL_BACKOFF.ceiling     # and settles, rather than growing forever
        @test issorted([SW._poll_gap(t) for t in 0:5:600])       # monotone — never speeds back up

        # The budget: an hour of waiting costs a bounded number of commands, and the first minute
        # still costs few enough that nobody notices.
        polls(total) = (t = 0.0; n = 0; while t < total; t += SW._poll_gap(t); n += 1; end; n)
        @test polls(60) <= 25
        @test polls(3600) <= 300                                 # vs 1800 at a flat 2s

        # The clock is per ALLOCATION, not per attempt: `allocation_node!` returns after `wait_s`
        # and is called again, and a backoff restarting each time would never reach the ceiling.
        k = (:pbs, "h", "slate-x")
        try
            t1 = SW._waiting_since(k)
            @test SW._waiting_since(k) == t1                      # a later attempt inherits it
            SW._waited_enough!(k)
            @test SW._waiting_since(k) >= t1                      # …until it stops pending
        finally
            SW._waited_enough!(k)
        end
    end

    @testset "an allocation names the node the scheduler picked" begin
        # An interactive session needs a compute node, and which node is an OUTPUT of the
        # allocation — not something a config file can hold. The scheduler answers with a
        # compressed node list, so reading the first host out of one is the step between "the
        # queue granted it" and "ssh there". Pure, hence testable with no cluster.
        @test Sweep.first_node("c1") == "c1"                    # a bare name
        @test Sweep.first_node("c[1-4]") == "c1"                # a range
        @test Sweep.first_node("n[03,07]") == "n03"             # a list — zero padding preserved
        @test Sweep.first_node("gpu[10-12,20]") == "gpu10"      # both, together
        @test Sweep.first_node("c[2]") == "c2"                  # a range of one
        @test Sweep.first_node("c1,c2") == "c1"                 # an uncompressed list
        @test Sweep.first_node("  c5  ") == "c5"                # scheduler output is padded
        @test Sweep.first_node("") == ""                        # nothing allocated yet

        # An allocation that does not exist is a state, not an error: the caller decides whether to
        # ask for one, and `alive` is the single question everything else turns on.
        none = Sweep.Allocation("nm", "", :none, "", "")
        @test !Sweep.alive(none)
        @test !Sweep.alive(Sweep.Allocation("nm", "7", :pending, "", ""))    # queued, no node yet
        @test !Sweep.alive(Sweep.Allocation("nm", "7", :running, "", ""))    # running but nameless
        @test Sweep.alive(Sweep.Allocation("nm", "7", :running, "c1", "1:00"))
        @test occursin("none", sprint(show, none))
        @test occursin("on c1", sprint(show, Sweep.Allocation("nm", "7", :running, "c1", "1:00")))

        # "the scheduler holds nothing" and "nobody answered" are DIFFERENT, and were the same state
        # once: a cluster that was switched off reported as a queue that was merely busy, so the
        # message sent you reading squeue documentation about what was really an ssh failure. Both
        # are settled — there is nothing to wait for — but only one of them is about the queue.
        un = Sweep.Allocation("nm", "", :unreachable, "", "")
        @test !Sweep.alive(un)
        @test Sweep.settled(un) && Sweep.settled(none)
        @test !Sweep.settled(Sweep.Allocation("nm", "7", :pending, "", ""))
        @test !Sweep.settled(Sweep.Allocation("nm", "7", :running, "c1", "1:00"))
        @test occursin("unreachable", sprint(show, un))

        # Asking for a node must not WAIT for one. `salloc` does not return until the scheduler
        # grants the allocation, and asking is one command on the shared login session, so on a busy
        # queue it owns that session for the whole wait and every other command to the host queues
        # behind it. Both schedulers submit a job that sleeps and let the poll loop find the grant.
        slurm_ask = Sweep._slurm_request_script("hold"; walltime = "00:30:00", partition = "gpu",
                                                cpus = 2, mem = "512M", gpus = "1", account = "",
                                                extra = "")
        @test !occursin("salloc", slurm_ask)
        @test startswith(slurm_ask, "sbatch ")
        @test occursin("sleep 2147483647", slurm_ask)
        # Values are shell-quoted, so a walltime or a partition with anything awkward in it survives.
        for want in ["-J 'hold'", "-t '00:30:00'", "-n 2", "-p 'gpu'", "--mem '512M'", "--gpus '1'"]
            @test occursin(want, slurm_ask)
        end
        # An account nobody named must not reach the scheduler as an empty flag.
        @test !occursin("-A", slurm_ask)

        # PBS names the node a job landed on with a cpu on each host rather than a compressed list,
        # which is a different syntax and not a variant of SLURM's.
        @test Sweep.pbs_first_node("c1/0*4") == "c1"            # one node, four cpus
        @test Sweep.pbs_first_node("c1/0+c2/0") == "c1"         # two nodes
        @test Sweep.pbs_first_node("c1/0*4+c2/0*4") == "c1"
        @test Sweep.pbs_first_node("  c5/2  ") == "c5"
        @test Sweep.pbs_first_node("") == ""                    # queued, no node yet

        # A scheduler that is neither still fails loudly rather than being sent one of their
        # command sets: issuing `squeue` to something that has never heard of it fails further from
        # the cause, and silently running on the login node would be worse than either.
        @test_throws ErrorException Sweep._unsupported_scheduler(:k8s)
        @test occursin("SLURM and PBS",
                       try; Sweep._unsupported_scheduler(:k8s); catch e; e.msg; end)
    end

    @testset "what is LEFT of an allocation" begin
        # SLURM reports it (`squeue %L`); PBS does not, so it is the walltime asked for minus the
        # walltime used — and both sides of that subtraction are scheduler times.
        s = Sweep.sched_seconds
        @test s("01:00:00") == 3600 && s("00:02:30") == 150
        @test s("2-00:00:00") == 172800                         # SLURM's days form
        @test s("10:00") == 600 && s("45") == 2700              # MM:SS, and a bare MM
        @test s("UNLIMITED") == Inf && s("") == 3600            # unknown reads as an hour
        @test Sweep.hms(3600) == "01:00:00" && Sweep.hms(90) == "00:01:30"
        @test Sweep.hms(0) == "00:00:00" && Sweep.hms(Inf) == ""
        @test Sweep._pbs_timeleft("01:00:00", "00:15:00") == "00:45:00"
        @test Sweep._pbs_timeleft("01:00:00", "") == "01:00:00" # granted, nothing used yet
        @test Sweep._pbs_timeleft("00:10:00", "00:20:00") == "00:00:00"   # never negative
        @test Sweep._pbs_timeleft("", "") == ""                 # the job did not say
    end

    @testset "a sweep has an identity for what has landed" begin
        # The handle everything downstream needs. A sweep's value is not a function of its source,
        # so a reader's memo key has nothing to move with as units arrive — and keyed off source
        # alone it restored analysis computed while the sweep was still empty. This is what the
        # cell declares instead, so the key tracks the results rather than the code.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 4 && error("nope")
                p.x
            end
            # Computed off the rows the caller already holds — never a second pass over the store.
            # A sweep of a few thousand units is a few thousand manifests, and re-reading them here
            # would double what running the cell costs.
            dig() = (Sweep.refresh!(r); Sweep.landed_digest(r))
            empty = dig()
            @test !isempty(empty)
            @test dig() == empty                             # stable while nothing changes

            chunks = BS.sweep_chunks(root, r.run)
            SlateTask.run_chunk(root, first(chunks))
            half = dig()
            @test half != empty                              # units landing moves it
            for c in chunks; SlateTask.run_chunk(root, c); end
            full = dig()
            @test full != half && full != empty
            @test r.failed == 1

            # Losing a result moves it again, with no count consulted — which is what lets a retry
            # that replaces one value with another at the same tally re-key its readers.
            ok = [k for k in r.keys if (mm = MemoStore.read_manifest(root, k);
                                        mm !== nothing && String(get(mm, "status", "")) == "ok")]
            MemoStore.drop_manifest(root, first(ok))
            @test dig() != full
        end
    end

    @testset "the callable controls do what the card's buttons do" begin
        # `reset!`, `retry_failed!`, `cancel!` and `resume!` are documented on the result, so a
        # script reaches for them instead of the card. They had drifted: the card dropped a result
        # from the STORE while these dropped it only from the hub's copy, which on a cluster means
        # the next sync brings it straight back. Same route now, so they cannot disagree again.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 3 && error("nope")
                p.x
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).failed == 1 && r.ok == 3

            @test Sweep.retry_failed!(r) == 1               # only the failure is cleared…
            @test Sweep.refresh!(r).failed == 0 && r.ok == 3 && r.pending == 1

            Sweep.cancel!(r)
            @test BS.is_cancelled(root, r.run) && r.ok == 3   # …and finished units survive a stop
            Sweep.resume!(r)
            @test !BS.is_cancelled(root, r.run)

            @test Sweep.reset!(r) == 3                      # every remaining result goes
            @test Sweep.refresh!(r).done == 0 && r.state === :ready
        end
    end

    @testset "the status payload is JSON-shaped and covers every unit" begin
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:5), t; submit = false) do p; p.x; end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            s = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            @test length(s["tiles"]) == 5           # one tile per unit at this size
            @test s["done"] == 5 && s["settled"] === true
            @test s["label"] isa String && startswith(s["color"], "#")
        end
    end

    @testset "the rendered grid and the live payload bin identically" begin
        # The browser patches tiles BY INDEX, so a renderer and a payload that binned differently
        # would repaint the wrong cells — and only on large sweeps, which are the ones anyone
        # actually watches.
        for n in (1, 7, 600, 601, 4000, 100_000)
            spans = Sweep._tile_spans(n)
            @test length(spans) <= Sweep._TILE_BUDGET
            @test first(spans)[1] == 1 && last(spans)[2] == n     # every unit is covered
            @test all(i -> spans[i][2] + 1 == spans[i + 1][1], 1:length(spans) - 1)  # no gaps
        end
        @test isempty(Sweep._tile_spans(0))

        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 500,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2000), t; submit = false) do p; p.x; end
            html = sprint(show, MIME"text/html"(), r)
            rendered = length(collect(eachmatch(r"<div title=\"units ", html)))
            payload = length(Sweep.status_payload(t, r.run, r.params, r.keys;
                                                  advance = false)["tiles"])
            @test rendered == payload
            @test payload <= Sweep._TILE_BUDGET      # flat cost regardless of sweep size
        end
    end

    @testset "@sweep accepts options after a comma or a semicolon" begin
        # `;` puts the options in a `:parameters` expression that Julia places FIRST among the
        # macro's arguments, so a parser that assumes positional order sees the target where the
        # grid should be. Both spellings are idiomatic and both have to work.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            g = Sweep.paramgrid(x = 1:2)
            a = Sweep.@sweep(g, t, setup = "", submit = false) do p; p.x; end
            b = Sweep.@sweep(g, t; setup = "", submit = false) do p; p.x; end
            @test a.key == b.key                     # same body and options, so the same sweep
            @test length(a) == 2
            @test_throws LoadError @eval Sweep.@sweep(g, t; nosuchoption = 1) do p; p.x; end
        end
    end

    @testset "a sweep's key does not depend on where its body sits in the file" begin
        # `string(expr)` carries LineNumberNodes, so without stripping them a cell that merely moved
        # down the notebook would re-key and orphan every result it already had.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            g = Sweep.paramgrid(x = 1:2)
            first_key = Sweep.@sweep(g, t; submit = false) do p; p.x * 3; end.key
            # The identical body, several lines later.
            second_key = Sweep.@sweep(g, t; submit = false) do p; p.x * 3; end.key
            @test first_key == second_key
            # A body that genuinely differs must still key differently.
            other = Sweep.@sweep(g, t; submit = false) do p; p.x * 4; end
            @test other.key != first_key
        end
    end

    @testset "only genuinely free names are captured" begin
        # Captures enter the sweep key, so a name the body BINDS must never be mistaken for one it
        # reads. A symbol scrape counted comprehension and loop variables as free: a body written
        # over `x` then captured whatever the notebook happened to keep under that name, and an
        # unrelated cell assigning to `x` re-keyed the sweep and orphaned every finished unit.
        # Call heads (`*`, `:`, `println`) come back as free names and are dropped downstream by
        # `_collect_captures`, which never ships a function. Filter them here for the same reason:
        # what is under test is which DATA names travel.
        cn(src) = Set(n for n in Sweep._capture_names(Meta.parse(src), :p)
                      if !(isdefined(Base, n) && getfield(Base, n) isa Function))
        @test cn("[x^2 for x in 1:n]") == Set([:n])                    # generator variable
        @test cn("[x * y for x in a, y in b]") == Set([:a, :b])        # multi-dimensional
        @test cn("[x for x in a if x > lo]") == Set([:a, :lo])         # …with a filter
        @test cn("begin\n  s = 0\n  for i in 1:m; s += i * w; end\n  s\nend") == Set([:m, :w])
        @test cn("let q = seed; q * 2; end") == Set([:seed])           # let binding
        @test cn("begin\n  f(z) = z + off\n  f(p.x)\nend") == Set([:off])   # inner def: name + args
        @test cn("map(v -> v * scale, xs)") == Set([:xs, :scale])      # lambda parameter
        @test cn("sum(rand(rng, k) for _ in 1:reps)") == Set([:rng, :k, :reps])
        @test cn("range(-1, 1; length = npts)") == Set([:npts])        # `length` is a keyword NAME
        @test cn("begin\n  acc = base\n  acc += 1\n  acc\nend") == Set([:base])
        @test cn("(rows[i] = v; rows)") == Set([:rows, :i, :v])        # assigning THROUGH a variable
        @test cn("p.field") == Set{Symbol}()                            # field names are not reads

        # …and the effect on the key: an unrelated global sharing a comprehension variable's name
        # must not move it.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            g = Sweep.paramgrid(i = 1:2)
            k1 = Sweep.@sweep(g, t; submit = false) do p; sum(x^2 for x in 1:p.i); end.key
            x = "an unrelated cell now defines x"      # ← what used to re-key the sweep
            k2 = Sweep.@sweep(g, t; submit = false) do p; sum(x^2 for x in 1:p.i); end.key
            @test k1 == k2
            @test x isa String                          # (keep the binding live, not optimised away)
        end
    end

    @testset "a pilot and the full sweep share results but not a schedule" begin
        # The pattern the fabric exists to encourage: run four points, look at them, then run four
        # thousand with the same body and pay only for the difference. That makes the two cells the
        # same SWEEP with different grids — so the results are shared, and everything that describes
        # "these units" (chunks, plan, card, cancellation) must NOT be.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            pilot = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p; p.x * 7; end
            full  = Sweep.@sweep(Sweep.paramgrid(x = 1:6), t; submit = false) do p; p.x * 7; end

            @test pilot.key == full.key                    # one sweep: results are reusable
            @test pilot.run != full.run                    # two requests: schedules are separate
            @test pilot.keys == full.keys[1:2]             # and the shared units are the same units

            # Chunk descriptors must not collide. Before the run key they did, and whichever cell
            # ran last silently redefined the other's work.
            pc, fc = BS.sweep_chunks(root, pilot.run), BS.sweep_chunks(root, full.run)
            @test isempty(intersect(pc, fc))
            @test pilot.total == 2 && full.total == 6      # each card counts its OWN units

            # Running the pilot advances the full sweep by exactly the shared units, without the
            # full sweep having been submitted at all.
            for c in pc; SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(pilot).done == 2
            @test Sweep.refresh!(full).done == 2
            @test full.pending == 4

            # The two cards address different channels, so neither renders the other's progress.
            @test Sweep.status_channel(pilot.run) != Sweep.status_channel(full.run)
        end
    end

    @testset "the result answers questions as properties" begin
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 3 && error("rigged")
                p.x * 10
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)

            @test r.state === :partial
            @test (r.total, r.done, r.ok, r.failed, r.pending) == (4, 4, 3, 1, 0)
            @test r.fraction == 1.0 && r.percent == 100.0 && r.settled
            # `summaries` come from the manifests, so this costs the same at four units and four
            # million. A unit returning a number summarises to itself by default.
            @test r.summaries == [10, 20, 40]
            @test length(r.results) == 3 && length(r.errors) == 1
            @test only(r.errors).params.x == 3
            @test r.blocked == "" && r.stalled_for == 0.0
            # A typo must name itself rather than returning `nothing` from a silent `getfield`.
            @test_throws ArgumentError r.finishd
            # Nothing that LOOKS cheap reads a blob: a row's `value` is a handle, and asking for the
            # data is a separate, explicit act.
            @test all(row -> row.value isa Sweep.ShardRef, r.results)
            @test r.results[1].value[] == 10                 # one unit, deliberately
            @test Sweep.load(r) == [10, 20, 40]              # all of them, deliberately
            @test Sweep.load(r; limit = 2) == [10, 20]
            @test r.bytes > 0
            # …and the bulk path refuses rather than quietly pulling more than it should.
            e = try; Sweep.load(r; max_bytes = 1); catch x; x; end
            @test occursin("over the", sprint(showerror, e))
            @test occursin("r.summaries", sprint(showerror, e))
            @test :results in propertynames(r) && :plan in propertynames(r)
        end
    end

    @testset "editing the science package re-keys the sweep" begin
        # A task process is fresh and has no Revise, so an edit to the package a body CALLS changes
        # what every unit computes while leaving the body text identical. Reusing the old results
        # would silently mix two versions of the code — the one thing content addressing exists to
        # prevent — and it fails loudly only when a function is newly added.
        mktempdir() do root
            mkpath(joinpath(root, "pkg", "src"))
            pkg = joinpath(root, "pkg")
            write(joinpath(pkg, "Project.toml"), "name = \"P\"\nuuid = \"00000000-0000-0000-0000-000000000001\"\n")
            write(joinpath(pkg, "src", "P.jl"), "module P\nf() = 1\nend\n")
            fp1 = Sweep.env_source_fingerprint(pkg)

            # Project/Manifest are untouched, so the OLD fingerprint cannot see this.
            @test Sweep.env_parent_fingerprint(pkg) ==
                  (write(joinpath(pkg, "src", "P.jl"), "module P\nf() = 2\nend\n");
                   Sweep.env_parent_fingerprint(pkg))
            fp2 = Sweep.env_source_fingerprint(pkg)
            @test fp1 != fp2                       # …but the source-inclusive one does

            # A new file counts, and so does a rename — the path goes into the digest, not just the
            # bytes, so moving code between files is a change.
            write(joinpath(pkg, "src", "extra.jl"), "g() = 3\n")
            @test Sweep.env_source_fingerprint(pkg) != fp2

            # And the sweep key moves with the environment, because the provisioner names the env
            # directory after that fingerprint.
            t1 = Sweep.LocalTarget(; root, project = joinpath(root, "taskenv", "aaaa"), payload = "p", chunk = 2)
            t2 = Sweep.LocalTarget(; root, project = joinpath(root, "taskenv", "bbbb"), payload = "p", chunk = 2)
            @test Sweep.env_key(t1) == "aaaa" && Sweep.env_key(t2) == "bbbb"
            @test Sweep.sweep_key("body", "", Dict(), Sweep.env_key(t1)) !=
                  Sweep.sweep_key("body", "", Dict(), Sweep.env_key(t2))
            # Same env ⇒ same sweep, so a pilot and the full run still share results.
            @test Sweep.sweep_key("body", "", Dict(), "aaaa") ==
                  Sweep.sweep_key("body", "", Dict(), "aaaa")
        end
    end

    @testset "a sweep submits nothing until it is asked to" begin
        # Authoring a sweep means running its cell over and over. None of those may spend an
        # allocation — the cell reads the store and reports the plan, and the work starts when
        # someone presses Submit.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t) do p; p.x; end   # no `submit =`
            @test !r.armed && r.state === :ready && r.done == 0
            @test isempty(BS.known_submissions(root))

            # Re-running the cell is still free.
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t) do p; p.x; end
            @test isempty(BS.known_submissions(root))
            # …and so is the card's poll, which reconciles but may not submit.
            s = Sweep.status_payload(t, r.run, r.params, r.keys)
            @test s["state"] == "ready" && isempty(BS.known_submissions(root))
            @test first(s["actions"][1]) == "submit"
            @test occursin("Submit 4 units", last(s["actions"][1]))

            # Submitting is the explicit act, and it sticks.
            Sweep.handle_action(t, r.run, r.params, r.keys, "submit")
            @test BS.is_armed(root, r.run)
            @test Sweep.refresh!(r).state !== :ready

            # Reset clears the results AND the arming: ready again, not running again.
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.handle_action(t, r.run, r.params, r.keys, "reset")
            @test !BS.is_armed(root, r.run)
            @test Sweep.refresh!(r).state === :ready && r.done == 0
        end
    end

    @testset "the card's controls track the sweep's state" begin
        # The controls used to be rendered once by the cell and never updated, so cancelling a
        # running sweep left a button still reading "Cancel" beside a card reading "stopped at your
        # request" — indistinguishable from a cancel that did nothing.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 2 && error("boom")
                p.x
            end
            acts(p) = first.(Sweep.action_list(p))
            l = BL.ExecLauncher()
            plan() = BS.plan(root, r.run; launcher = l)

            # Nothing submitted yet: pending, so it can be cancelled.
            @test "cancel" in acts(plan())

            # Cancelled while in flight ⇒ offer Resume, and NOT Cancel again. This is the transition
            # the card has to follow: without it the button still reads "Cancel" beside a card that
            # says "stopped at your request".
            BS.cancel!(root, r.run, l)
            @test acts(plan()) == ["resume", "reset"]
            s = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            @test first(s["actions"][1]) == "resume"   # the poll carries it, so the row can rebuild
            BS.resume!(root, r.run)
            @test "cancel" in acts(plan())

            # Finished with a failure: retry + reset, and no cancel — there is nothing left to stop.
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            p = plan()
            @test acts(p) == ["retry", "reset"]
            @test occursin("Retry 1 failed", last(Sweep.action_list(p)[1]))
            # Cancelling something already finished changes nothing — it is not "stopped", it is done.
            BS.cancel!(root, r.run, l)
            @test acts(plan()) == ["retry", "reset"]
        end
    end

    @testset "a sweep that fails while watched grows its own explanation" begin
        # The card is rendered ONCE, when the cell runs — before anything has failed. Both the
        # failure list and the why-it-stopped panel used to exist only in that static render, so a
        # sweep that broke while you watched it showed a red label and nothing to expand; you had to
        # re-run the cell by hand to see which units died. Both now ride the poll.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x == 2 && error("boom at $(p.x)")
                p.x
            end
            # Nothing has run: no explanation to give and nothing to expand.
            s0 = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            @test get(s0, "why", "") == ""
            @test get(s0, "fails", "") == ""

            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            s1 = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            # The poll now carries the list the reader needs, with the failing PARAMS leading —
            # "which corner of the grid breaks" is the question, not "how".
            @test occursin("1 failed unit", s1["fails"])
            @test occursin("boom at 2", s1["fails"])
            @test occursin("<details", s1["fails"])
            @test occursin("x = 2", s1["fails"])
            # A partial finish is not a stopped sweep, so there is still nothing to explain.
            @test get(s1, "why", "") == ""
        end
    end

    @testset "reset is available at any time, including part-way through" begin
        # The case reset exists for is a long run that is half done and going wrong. Offering it only
        # once a sweep had settled meant waiting out the very thing you wanted to stop.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:6), t; submit = false) do p
                p.x
            end
            l = BL.ExecLauncher()
            acts() = first.(Sweep.action_list(BS.plan(root, r.run; launcher = l),
                                              BS.is_armed(root, r.run)))

            # Nothing asked for and nothing done: reset would be a no-op, so it is not offered.
            @test acts() == ["submit"]

            # Armed, and part-way: one chunk landed, the rest outstanding.
            Sweep.handle_action(t, r.run, r.params, r.keys, "submit")
            SlateTask.run_chunk(root, first(BS.sweep_chunks(root, r.run)))
            @test Sweep.refresh!(r).done == 2 && !r.settled
            @test "reset" in acts()

            # …and it really does clear, mid-flight, back to ready rather than stopped.
            Sweep.handle_action(t, r.run, r.params, r.keys, "reset")
            @test Sweep.refresh!(r).done == 0
            @test r.state === :ready && !BS.is_armed(root, r.run)
            @test !BS.is_cancelled(root, r.run)     # cleared, not stopped — submitting works again
            @test acts() == ["submit"]

            # A reset sweep submits and completes normally: nothing about the clear is sticky.
            Sweep.handle_action(t, r.run, r.params, r.keys, "submit")
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).state === :succeeded && r.summaries == collect(1:6)
        end
    end

    @testset "`using` is written in the body and lifted out" begin
        # Where you would expect to write it. It is legal to WRITE inside a closure — the parser
        # accepts it — but not to run, and a module wants loading once per chunk rather than once
        # per unit, so the macro moves it into the setup.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                using Statistics
                mean([p.x, p.x])
            end
            ch = MemoStore.read_manifest(root, first(BS.sweep_chunks(root, r.run)))
            setup = SlateTask._get_txt(root, String(ch["setup"]))
            fn = SlateTask._get_txt(root, String(ch["fn"]))
            @test occursin("using Statistics", setup)
            @test !occursin("using", fn)          # …and gone from the body it was written in
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).summaries == [1.0, 2.0]   # it actually loaded on the shard

            # An import moves the sweep's identity, like any other change to what a unit runs.
            r2 = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                mean([p.x, p.x])
            end
            @test r2.key != r.key
        end
    end

    @testset "a macro call in the body keeps its arguments" begin
        # The body is normalised by stripping LineNumberNodes before it is stringified. A
        # `:macrocall`'s second argument is POSITIONAL, though, so dropping the line node there
        # shifts the real arguments left: `@sfile "x.h5"` deparsed to a bare `@sfile`, and the unit
        # ran a macro with no arguments. Every sweep body that calls any macro was affected.
        ex = Meta.parse("""@sfile("cube_\$(p.t).h5")""")
        @test string(Sweep._strip_lines(ex)) == "@sfile \"cube_\$(p.t).h5\""
        nested = Meta.parse("f(@view(x[1:2]), @sprintf(\"%d\", n))")
        @test occursin("@view", string(Sweep._strip_lines(nested)))
        @test occursin("x[1:2]", string(Sweep._strip_lines(nested)))
        @test occursin("\"%d\"", string(Sweep._strip_lines(nested)))
        # …and the normalisation still does its job: line position is not part of the text.
        @test Sweep._strip_lines(Meta.parse("\n\n@sfile(\"a\")")) ==
              Sweep._strip_lines(Meta.parse("@sfile(\"a\")"))

        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            # End to end with the shard's own `@sfile`, which is where this surfaced.
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false, summary = v -> v) do p
                write(@sfile("out_$(p.x).txt"), string(p.x))
                basename(@sfile("out_$(p.x).txt"))
            end
            ch = MemoStore.read_manifest(root, first(BS.sweep_chunks(root, r.run)))
            fn = SlateTask._get_txt(root, String(ch["fn"]))
            @test occursin("@sfile", fn) && occursin("out_", fn)   # the call AND its argument
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).summaries == ["out_1.txt", "out_2.txt"]
            @test read(joinpath(root, "data", "out_2.txt"), String) == "2"
        end
    end

    # A stand-in for a notebook namespace: cells evaluated under `cell:<id>` filenames, with each
    # cell's top-level statements recorded the way `_eval_cell_source` records them. That pair is
    # all `_helper_defs` needs — a method knows which cell defined it, and this knows what that
    # cell said.
    function _fake_notebook(target, cells)
        m = Module(:NBHelpers)
        Core.eval(m, :(const __slate_cell_stmts = Dict{String,Vector{String}}()))
        Core.eval(m, :(const Sweep = $Sweep))
        Core.eval(m, :(const T = $target))
        for (file, src) in cells
            ast = Meta.parseall(src; filename = file)
            Core.eval(m, :(__slate_cell_stmts[$file] = $(Sweep.stmt_texts(src, ast))))
            Core.eval(m, ast)
        end
        return m
    end

    _chunk_setup(root, r) = SlateTask._get_txt(root, String(
        MemoStore.read_manifest(root, first(BS.sweep_chunks(root, r.run)))["setup"]))

    @testset "a helper the notebook defined travels with the sweep" begin
        # A function value cannot be revived on a compute node, so a body calling a notebook helper
        # used to fail there with UndefVarError unless the author restated it in `setup =`. The
        # defining cell is found instead, and its text travels.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            m = _fake_notebook(t, ["cell:h1" => "stress(x) = x * 3\nscale = 7",
                                   "cell:h2" => "shifted(x) = stress(x) + scale"])
            r = Core.eval(m, quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    shifted(p.x)
                end
            end)
            setup = _chunk_setup(root, r)
            # Transitive: the body calls `shifted`, which calls `stress`. Both travel.
            @test occursin("shifted(x) = ", setup) && occursin("stress(x) = ", setup)
            # `scale` is DATA the helper reads, so it travels as a capture, not as source.
            @test !occursin("scale = 7", setup)
            ch = MemoStore.read_manifest(root, first(BS.sweep_chunks(root, r.run)))
            @test "scale" in [String(c["name"]) for c in ch["captures"]]

            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).summaries == [10, 13]      # it genuinely ran on the shard
        end
    end

    @testset "a helper's cell brings its imports" begin
        # A helper is not self-contained without them, and the author wrote them next to it. Without
        # this, "define a helper in a cell" only works for helpers that need no package — the unit
        # gets past the helper's own name and dies on the first thing the helper calls.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            m = _fake_notebook(t, ["cell:h1" => "using Statistics\nspread(v) = mean(v) + 0",
                                   "cell:h2" => "using Dates\nunrelated() = 1"])
            r = Core.eval(m, quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    spread([p.x, p.x * 3])
                end
            end)
            setup = _chunk_setup(root, r)
            @test occursin("using Statistics", setup)
            # …only from the cells actually drawn from.
            @test !occursin("using Dates", setup)
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).failed == 0
            @test Sweep.refresh!(r).summaries == [2.0, 4.0]
        end
    end

    @testset "a helper is shipped as written, not as a deparse" begin
        # `string(expr)` does not round-trip. A comprehension with a filter over several iterators
        # comes back as `$(Expr(:filter, …))`, which no parser will take — so a real helper (a
        # docstring'd, keyword-argument function with such a comprehension in it) failed to re-parse,
        # was silently skipped, and the unit died with UndefVarError naming it.
        src = """
        \"\"\"Docstring, which wraps the definition in a macrocall.\"\"\"
        function ring(a; lo, hi)
            c = 3
            [a[i, j] for i in axes(a, 1), j in axes(a, 2) if lo < abs(i - c) < hi]
        end
        """
        texts = Sweep.stmt_texts(src, Meta.parseall(src; filename = "cell:h1"))
        @test length(texts) == 1
        @test occursin("\"\"\"Docstring", texts[1])           # the docstring came along
        @test Sweep._def_name(Meta.parse(texts[1])) == "ring"  # …and it re-parses to the right name
        @test !occursin("Expr(:filter", texts[1])

        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            m = _fake_notebook(t, ["cell:h1" => src])
            r = Core.eval(m, quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    length(ring(reshape(1:36, 6, 6); lo = 0, hi = p.x + 1))
                end
            end)
            @test occursin("function ring", _chunk_setup(root, r))
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            # It genuinely ran on the shard — a skipped helper would be an UndefVarError here.
            @test Sweep.refresh!(r).failed == 0
            @test Sweep.refresh!(r).summaries == [12, 24]
        end
    end

    @testset "a trailing comment on a helper's cell does not re-key" begin
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            call = quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    stress(p.x)
                end
            end
            a = Core.eval(_fake_notebook(t, ["cell:h1" => "stress(x) = x * 3\n"]), call)
            b = Core.eval(_fake_notebook(t, ["cell:h1" => "stress(x) = x * 3\n\n# a note\n"]), call)
            @test a.key == b.key
        end
    end

    @testset "editing a helper re-keys the sweep" begin
        # The property that makes this safe rather than a footgun. The helper is part of what
        # computed the results, so it is part of their identity: change it and the old results are
        # a different sweep's, not this one's.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            call = quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    stress(p.x)
                end
            end
            r1 = Core.eval(_fake_notebook(t, ["cell:h1" => "stress(x) = x * 3"]), call)
            r2 = Core.eval(_fake_notebook(t, ["cell:h1" => "stress(x) = x * 4"]), call)
            @test r1.key != r2.key
            # …and an unrelated edit to the SAME cell does not, so a comment does not orphan a run.
            r3 = Core.eval(_fake_notebook(t, ["cell:h1" => "unused = 1\nstress(x) = x * 3"]), call)
            @test r3.key == r1.key
        end
    end

    @testset "only what the notebook defined is shipped" begin
        # A package function is already installed where the unit runs; restating it would be noise
        # at best and a stale copy at worst. Only a definition with a notebook CELL behind it moves.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            m = _fake_notebook(t, ["cell:h1" => "double(x) = x * 2"])
            r = Core.eval(m, quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    sum([double(p.x), abs(-1)])
                end
            end)
            setup = _chunk_setup(root, r)
            @test occursin("double(x) = ", setup)
            @test !occursin("sum", setup) && !occursin("abs", setup)
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).summaries == [3, 5]
        end
    end

    @testset "a notebook struct and macro travel too" begin
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            m = _fake_notebook(t, ["cell:h1" => "struct Knob; n::Int; end",
                                   "cell:h2" => "macro twice(e); esc(:(2 * \$e)); end"])
            r = Core.eval(m, quote
                Sweep.@sweep(Sweep.paramgrid(x = 1:2), T; submit = false, summary = v -> v) do p
                    @twice(Knob(p.x).n)
                end
            end)
            setup = _chunk_setup(root, r)
            @test occursin("struct Knob", setup) && occursin("macro twice", setup)
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r).summaries == [2, 4]
        end
    end

    @testset "one view over everything a sweep produced" begin
        # The SAME call answers a sweep whose units returned one row each and one whose units
        # returned thousands, with the parameters attached either way. Whether a unit's rows were
        # chunked into the store or carried inline in its manifest is storage, and a reader never
        # has to pick an accessor by it.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))

            one = Sweep.@sweep(Sweep.paramgrid(a = 1:2, b = [10, 20]), t; submit = false) do p
                (; snr = float(p.a * p.b), sep = p.a)
            end
            # Before anything lands the ROWS are already the whole grid. The value columns are not
            # there yet and cannot be: nothing has said what they are called.
            d0 = one.dataset
            @test length(d0) == 4 && isempty(d0.columns) && d0.pnames == [:a, :b]
            g0 = d0[1:4]
            @test keys(g0) == (:a, :b)
            @test g0.a == [1, 2, 1, 2] && g0.b == [10, 10, 20, 20]
            @test all(isempty, d0[1:4, (:status,)].status)   # nothing ran, so nothing has a status

            # One unit landing names the columns; the rest are holes, not absences.
            SlateTask.run_chunk(root, first(BS.sweep_chunks(root, one.run)))
            d1 = Sweep.refresh!(one).dataset
            @test Symbol.(d1.columns) == [:snr, :sep]
            g1 = d1[1:4]
            @test keys(g1) == (:a, :b, :snr, :sep)
            @test g1.snr[1:2] == [10.0, 20.0] && all(ismissing, g1.snr[3:4])
            @test g1.a == [1, 2, 1, 2]                       # the grid never changed shape
            # A hole survives both predicates rather than throwing on one: comparing against
            # `missing` is not a match, and a `where` that comes back `missing` is not a pass.
            @test Sweep.scan(d1; between = (:snr, 0.0, 100.0)).snr == [10.0, 20.0]
            @test Sweep.scan(d1; where = row -> row.snr > 5).snr == [10.0, 20.0]

            for c in BS.sweep_chunks(root, one.run); SlateTask.run_chunk(root, c); end
            g = Sweep.refresh!(one).dataset[1:4]
            @test g.snr == [10.0, 20.0, 20.0, 40.0] && g.sep == [1, 2, 1, 2]
            @test eltype(g.snr) == Float64      # narrowed, so a plot or a `sum` over it behaves

            # The facts are off the default projection — on a unit with many rows they repeat
            # identically down the whole block — and come back when named.
            @test !(:status in keys(g))
            gf = one.dataset[1:4, (:snr, :status, :ms)]
            @test keys(gf) == (:snr, :status, :ms) && all(==("ok"), gf.status)
            @test all(x -> x isa Sweep.Dates.DateTime, one.dataset[1:4, (:at,)].at)
            # In the READER's clock, matching every other time a sweep prints. A raw UTC conversion
            # put two views hours apart while naming one event.
            @test abs((one.dataset[1:1, (:at,)].at[1] - Sweep.Dates.now()).value) < 60_000
            @test_throws ErrorException one.dataset[1:4, (:nope,)]

            # MANY rows per unit, stored INLINE — small enough to ride the manifest, and still three
            # rows each. Shape is not storage, and reading one as the other gave a unit's whole
            # output a single row holding vectors.
            inl = Sweep.@sweep(Sweep.paramgrid(g = 1:2), t; submit = false) do p
                (; i = collect(1:3), v = float.(1:3) .* p.g)
            end
            for c in BS.sweep_chunks(root, inl.run); SlateTask.run_chunk(root, c); end
            di = Sweep.refresh!(inl).dataset
            @test length(di) == 6
            gi = di[1:6]
            @test gi.i == [1, 2, 3, 1, 2, 3]
            @test gi.g == [1, 1, 1, 2, 2, 2]
            @test gi.v == [1.0, 2.0, 3.0, 2.0, 4.0, 6.0]
            # `scan` walks the ROW SPACE, not the chunk list, so inline rows are not invisible to it.
            s = Sweep.scan(di; where = r -> r.v > 2.0)
            @test s.v == [3.0, 4.0, 6.0] && s.g == [1, 2, 2]

            # MANY rows per unit, stored as CHUNKS. Same call, same columns beside the same
            # parameters — the backend is the one thing the reader never has to know.
            many = Sweep.@sweep(Sweep.paramgrid(g = 1:3), t; submit = false, lazy = true) do p
                n = 5
                (; i = collect(1:n), v = float.(1:n) .* p.g)
            end
            for c in BS.sweep_chunks(root, many.run); SlateTask.run_chunk(root, c); end
            dm = Sweep.refresh!(many).dataset
            @test length(dm) == 15                           # 3 units × 5 rows, one row space
            gm = dm[1:15]
            @test keys(gm) == (:g, :i, :v)
            @test gm.g == [1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3]
            @test gm.v[6:10] == [2.0, 4.0, 6.0, 8.0, 10.0]   # unit g=2's own rows
            @test all(p -> p.backend === :indexed, dm.parts)
            @test all(p -> p.backend === :inline, di.parts)

            # The parameter column reads like any vector but is stored ONCE PER UNIT, not per row.
            # Materialising it would keep one copy per output row, so a few hundred units returning
            # thousands each would hold millions of copies of a number with a few hundred values.
            @test gm.g isa Sweep.BlockColumn
            @test length(gm.g) == 15 && length(gm.g.values) == 3
            @test collect(gm.g) == [1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3]
            @test gm.g[1] == 1 && gm.g[6] == 2 && gm.g[15] == 3
            @test_throws BoundsError gm.g[16]
            @test sum(gm.g) == 30                     # behaves as a vector for ordinary work

            # A unit that returned a bare number has no field name, so its column is `result`.
            r2 = Sweep.@sweep(Sweep.paramgrid(x = 1:3), t; submit = false) do p; p.x * 5; end
            for c in BS.sweep_chunks(root, r2.run); SlateTask.run_chunk(root, c); end
            @test Sweep.refresh!(r2).dataset[1:3].result == [5, 10, 15]

            # A returned field colliding with a parameter keeps BOTH rather than overwriting.
            r3 = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p; (; x = p.x * 100); end
            for c in BS.sweep_chunks(root, r3.run); SlateTask.run_chunk(root, c); end
            g3 = Sweep.refresh!(r3).dataset[1:2]
            @test g3.x == [1, 2] && g3.x_result == [100, 200]

            # A value with no addressable form and too large to record inline is a HOLE: the grid
            # keeps its shape, and fetching that unit stays deliberate.
            r4 = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                collect(1:500) .* p.x
            end
            for c in BS.sweep_chunks(root, r4.run); SlateTask.run_chunk(root, c); end
            d4 = Sweep.refresh!(r4).dataset
            @test isempty(d4.columns) && d4.whole == 2
            @test all(p -> p.backend === :none, d4.parts)
            g4 = d4[1:2, (:x, :status)]
            @test g4.x == [1, 2] && all(==("ok"), g4.status)
            @test r4.results[1].value[] == collect(1:500)     # fetching it stays deliberate
        end
    end

    @testset "a sweep can be asked what its jobs printed" begin
        # The failures that cost the most time leave NO manifest — an OOM kill, a walltime cut, a
        # prologue that failed — so `r.errors` is empty and the only account of what happened is the
        # scheduler's job output. Every launcher could already tail it; nothing connected it to a
        # sweep, so the one question a stuck run raises had no answer.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p
                p.x
            end
            @test Sweep.logs(r) == ""                  # nothing submitted, nothing to say
            mkpath(joinpath(root, "logs"))
            mkpath(BS.jobs_dir(root))
            chunks = BS.sweep_chunks(root, r.run)
            name = BS.submission_name(chunks)
            write(BS.index_path(root, name), join(chunks, "\n") * "\n")
            write(joinpath(root, "logs", "$(name).1.log"), "slurmstepd: Exceeded job memory limit\n")

            @test Sweep.run_jobs(r) == [name]
            out = Sweep.logs(r)
            @test occursin("Exceeded job memory limit", out)
            @test occursin(name, out)                  # headed, so several jobs stay tellable apart
            @test occursin("Exceeded", Sweep.logs(r; job = name))
            # A job that is not this sweep's is not reported as if it were.
            write(BS.index_path(root, "slate-elsewhere"), "some-other-chunk\n")
            write(joinpath(root, "logs", "slate-elsewhere.1.log"), "unrelated\n")
            @test !occursin("unrelated", Sweep.logs(r))

            # The card asks the same question through its own channel — and only when asked. A poll
            # must never carry it: for a cluster this is a round trip to the login node, so a card
            # left open on a finished sweep would tail files over ssh for the rest of the session.
            poll = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            @test !haskey(poll, "logs")
            @test "logs" in [a[1] for a in poll["actions"]]
            got = Sweep.handle_action(t, r.run, r.params, r.keys, "logs")
            @test occursin("Exceeded job memory limit", got["logs"])
            # …and it is a question, not a mutation: nothing about the sweep moved.
            @test got["done"] == poll["done"] && got["state"] == poll["state"]
        end
    end

    @testset "job output is a list of files, newest first" begin
        # One `tail` across every element of every job could not be sorted, opened selectively, or
        # bounded — so the file that explained a failure sat somewhere in the middle of a dump that
        # grew with the sweep.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p; p.x; end
            mkpath(joinpath(root, "logs")); mkpath(BS.jobs_dir(root))
            chunks = BS.sweep_chunks(root, r.run)
            name = BS.submission_name(chunks)
            write(BS.index_path(root, name), join(chunks, "\n") * "\n")
            old = joinpath(root, "logs", "$(name).1.log")
            new = joinpath(root, "logs", "$(name).2.log")
            write(old, "starting\nall fine\n")
            write(new, "starting\nERROR: LoadError: no method matching\n")
            touch(old); sleep(1.1); touch(new)          # distinct mtimes to sort on

            fs = Sweep.log_files(t, r.run)
            @test length(fs) == 2
            @test fs[1].path == new                      # newest first
            @test fs[1].bytes > 0 && fs[1].modified > 0
            @test Sweep.log_tail(t, r.run, new; lines = 10) ==
                  "starting\nERROR: LoadError: no method matching\n"

            # A path this sweep did not report is refused, not quoted and hoped for: it would reach
            # a shell on a login node.
            e = try; Sweep.log_tail(t, r.run, "/etc/passwd"); "" catch x; sprint(showerror, x); end
            @test occursin("no such log", e)
            e2 = try; Sweep.log_tail(t, r.run, "$(new); rm -rf /"); "" catch x; sprint(showerror, x); end
            @test occursin("no such log", e2)

            # The card opens the newest file on the first press, which is where a dead job explains
            # itself, and marks the severity so it is findable without reading every line.
            got = Sweep.handle_action(t, r.run, r.params, r.keys, "logs")
            @test occursin(basename(new), got["logs"])
            @test occursin(basename(old), got["logs"])    # …and lists the others to pick from
            @test occursin("no method matching", got["logs"])
            @test occursin("--red", got["logs"])          # the ERROR line is coloured
            @test occursin("Refresh", got["logs"])
            @test !occursin("all fine", got["logs"])      # the unopened file is not dragged along

            # Naming one opens that one instead.
            pick = Sweep.handle_action(t, r.run, r.params, r.keys, "logs"; arg = old)
            @test occursin("all fine", pick["logs"])
        end
    end

    @testset "a healthy log does not read as a failing one" begin
        # The runner's own success line is "N ran, 0 skipped, 0 failed of N". Matching the bare word
        # `failed` painted the most common line in a healthy log the colour of the thing you are
        # hunting for, which is worse than not colouring at all.
        @test Sweep._log_severity("chunk sw1_c1: 4 ran, 0 skipped, 0 failed of 4") === :plain
        @test Sweep._log_severity("0 errors") === :plain
        @test Sweep._log_severity("Cancelled by user request") === :plain
        # A real one still lands.
        @test Sweep._log_severity("chunk sw1_c1: 1 ran, 0 skipped, 3 failed of 4") === :bad
        @test Sweep._log_severity("ERROR: LoadError: UndefVarError: `trial` not defined") === :bad
        @test Sweep._log_severity("slurmstepd: error: Exceeded job memory limit") === :bad
        @test Sweep._log_severity("srun: Job step aborted") === :bad
        @test Sweep._log_severity("Warning: assignment to `x` in soft scope") === :warn
        @test Sweep._log_severity("Precompiling MyPkg") === :plain
    end

    @testset "asking for a chart does not narrow what was recorded" begin
        # `summary` and the unit's own return value answered the same manifest field, so
        # `summary = v -> v.snr` on a unit returning `(; snr, sep_px)` dropped `sep_px` out of every
        # cheap view of the run: adding a chart hint cost a column, which is not a trade anyone
        # makes on purpose. They are separate questions and now separate fields.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false,
                             summary = v -> v.snr) do p
                (; snr = float(p.x), sep_px = 10 * p.x)
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            # The chart gets the derived figure…
            @test r.summaries == [1.0, 2.0]
            # …and the record still holds everything the unit returned.
            recs = [row.record for row in r.results]
            @test [x.snr for x in recs] == [1.0, 2.0]
            @test [x.sep_px for x in recs] == [10, 20]

            # With no `summary =`, the record IS the chart series — a sweep returning a couple of
            # numbers needs no wiring at all.
            r2 = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                (; snr = float(p.x), sep_px = 10 * p.x)
            end
            for c in BS.sweep_chunks(root, r2.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r2)
            @test [x.snr for x in r2.summaries] == [1.0, 2.0]
            @test [x.sep_px for x in r2.records] == [10, 20]
        end
    end

    @testset "three channels: facts, data, artifacts" begin
        # The shape a real run has. A unit that trains something reports FACTS worth watching, may
        # produce no returnable value at all, and leaves its heavy output where it ran. None of the
        # three is required, and only the one you ask for costs anything.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(lr = [0.1, 0.01, 0.001]), t;
                             submit = false, summary = v -> v.report) do p
                w = tempname(); write(w, repeat("W", 4096))     # stands in for model weights
                artifact!(w; name = "weights.bin")
                (; report = (; loss = p.lr * 10, steps = 100, converged = p.lr < 0.05),
                   data = nothing)
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            @test r.state === :succeeded && r.done == 3

            # FACTS — grouped, and read back the way they were written.
            s = r.summaries
            @test all(x -> x isa NamedTuple, s)
            @test [x.loss for x in s] ≈ [1.0, 0.1, 0.01]
            @test s[1].steps == 100 && s[3].converged === true

            # ARTIFACTS — named handles, sizes known, bytes still in the store.
            a = only(r.results[1].artifacts)
            @test a isa Sweep.ArtifactRef && a.name == "weights.bin" && a.bytes == 4096
            @test occursin("weights.bin", sprint(show, a))
            dest = joinpath(root, "pulled.bin")
            @test Sweep.fetch(a, dest) == dest && filesize(dest) == 4096   # deliberately, one file
            @test length(Sweep.bytes(a)) == 4096

            # A grouped summary auto-plots only when ONE field is numeric; `loss` and `steps` both
            # are, so it declines rather than choosing for the author.
            # …and it says so with a null rather than an absent key, so the card can tell "no
            # chart" from "no news" and clear one it had already drawn.
            @test Sweep.status_payload(t, r.run, r.params, r.keys;
                                       advance = false)["chart"] === nothing
        end
    end

    @testset "running the cell never submits" begin
        # It read the ARMED marker to decide, so a cell run resubmitted a sweep somebody had armed
        # at some point. A worker restart re-runs every cell, so reopening a notebook could start
        # hundreds of units nobody had asked for again — and locally there is no scheduler between
        # that and the machine.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            body = "p -> p.x"
            r = Sweep.run_sweep(t, Sweep.paramgrid(x = 1:4), body)
            @test isempty(BS.known_submissions(root))          # nothing submitted, as before

            # ARM it, as the card's Submit does, then run the cell again.
            BS.arm!(root, r.run)
            before = length(BS.known_submissions(root))
            Sweep.run_sweep(t, Sweep.paramgrid(x = 1:4), body)
            @test length(BS.known_submissions(root)) == before  # …and it still submitted nothing

            # The card's poll is what advances an armed sweep — that is where watching belongs.
            Sweep.status_payload(t, r.run, r.params, r.keys; advance = true)
            @test length(BS.known_submissions(root)) > before

            # An explicit `submit = true` — a standalone script, with no card to ask from — still works.
            r2 = Sweep.run_sweep(t, Sweep.paramgrid(y = 1:2), "p -> p.y"; submit = true)
            @test BS.is_armed(root, r2.run)
            @test any(cs -> any(in(Set(BS.sweep_chunks(root, r2.run))), cs),
                      values(BS.known_submissions(root)))
        end
    end

    @testset "at most one unarmed run per cell" begin
        # A run is keyed by body + setup + captures + grid, so every edit mints a new one and the
        # old — which nobody ever asked to run — is left behind holding a blob per parameter point.
        # An afternoon of adjusting a constant filled the store with descriptors for work that was
        # never requested, and there was no way to get rid of them.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            # A DIFFERENT BODY each time, not a different grid. Shard keys come from the sweep key
            # (body + setup + captures), so widening a grid inherits the results the narrower one
            # already computed — those units are landed, and the rule correctly keeps such a run.
            # Isolating the rule means each run having nothing to inherit.
            mk(i) = task_local_storage(:slate_cell, "sweepcell") do
                Sweep.run_sweep(t, Sweep.paramgrid(x = 1:4), "p -> p.x * $i"; cell = "sweepcell")
            end
            a = mk(1)
            @test BS.sweep_cell(root, a.run) == "sweepcell"
            # Found through the cell's own index, not by parsing every manifest in a store that
            # holds one per unit — this runs on every execution of a sweep cell.
            @test BS.cell_runs(root, "sweepcell") == [a.run]
            b = mk(2)                                  # an edited body ⇒ a different run
            @test b.run != a.run
            # …and the one nobody armed is gone rather than left behind.
            @test MemoStore.read_manifest(root, a.run) === nothing
            @test MemoStore.read_manifest(root, b.run) !== nothing

            # An ARMED run survives: it may have work queued even with nothing landed.
            BS.arm!(root, b.run)
            c = mk(3)
            @test MemoStore.read_manifest(root, b.run) !== nothing
            @test MemoStore.read_manifest(root, c.run) !== nothing

            # So does anything that RAN, including a run whose units all failed.
            for ch in BS.sweep_chunks(root, c.run); SlateTask.run_chunk(root, ch); end
            d = mk(4)
            @test MemoStore.read_manifest(root, c.run) !== nothing

            # Another CELL's unarmed runs are never touched.
            other = task_local_storage(:slate_cell, "othercell") do
                Sweep.run_sweep(t, Sweep.paramgrid(x = 1:3), "p -> p.x"; cell = "othercell")
            end
            mk(5)
            @test MemoStore.read_manifest(root, other.run) !== nothing
            @test MemoStore.read_manifest(root, d.run) === nothing

            # Releasing by hand is the same primitive, and refuses a run that may have work out.
            @test Sweep.forget_run!(t, other.run) > 0
            @test MemoStore.read_manifest(root, other.run) === nothing
            e = try; Sweep.forget_run!(t, b.run); "" catch x; sprint(showerror, x); end
            @test occursin("armed", e) && occursin("cancel", e)
        end
    end

    @testset "the card renders for every state a sweep can be in" begin
        # A throwing `text/html` method does not surface as an error: the notebook falls back to
        # the next MIME it can render, so the card silently becomes text and the exception is never
        # seen. Nothing here rendered the card, so a constructor change that broke it got through.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            card(x) = sprint((io, v) -> show(io, MIME"text/html"(), v), x)
            # Nothing submitted, part landed, all landed, and one that failed.
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p; (; y = p.x); end
            @test occursin("data-sweep", card(r))
            SlateTask.run_chunk(root, first(BS.sweep_chunks(root, r.run)))
            @test occursin("data-sweep", card(Sweep.refresh!(r)))
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            @test occursin("data-sweep", card(Sweep.refresh!(r)))

            bad = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                error("boom")
            end
            for c in BS.sweep_chunks(root, bad.run); SlateTask.run_chunk(root, c); end
            @test occursin("data-sweep", card(Sweep.refresh!(bad)))
            # The dataset renders too — it is built during the card's own render.
            @test !isempty(sprint((io, v) -> show(io, MIME"text/plain"(), v), r.dataset))
        end

        # …and when the dataset cannot be assembled at all. Building it is the one part of a card
        # that reaches outside the sweep, so whatever goes wrong out there must cost the data line
        # and nothing else. Without the guard the card degrades to plain text with no error
        # anywhere, which reads as "the card is broken" and points at nothing.
        #
        # The failure is injected by handing it an unusable shard key, since the store itself is
        # careful: a missing root yields no manifests and a corrupt one parses to `nothing`, so
        # neither throws. It stands in for the unforeseen, which is the category that matters here —
        # a purged scratch, a dropped mount, a process holding a stale version of a type.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p; (; y = p.x); end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            @test_throws ArgumentError MemoStore.read_manifest(root, "../not a key")  # the injection
            stranded = Sweep.ShardedResult(getfield(r, :key), getfield(r, :run), t,
                                           getfield(r, :params), ["../not a key", "../nor this"],
                                           getfield(r, :plan), getfield(r, :rows),
                                           getfield(r, :telemetry), getfield(r, :plot))
            @test_throws Exception stranded.dataset      # the dataset really is unreachable
            html = sprint((io, v) -> show(io, MIME"text/html"(), v), stranded)
            @test occursin("data-sweep", html)           # …and the card is still a card
            @test occursin("2 / 2", html)                # still reporting what it does know
            @test occursin("<div data-sw='data'></div>", html)   # only the data line went quiet
            @test !isempty(String(Sweep.text(stranded)))
        end
    end

    @testset "printing a sweep does not print the grid" begin
        # `@show r` / `println(r)` go through the 2-arg `show`, and with no method for it Julia
        # dumps every field — one of which is every ROW. On a real sweep that is the whole grid,
        # parameters and handles and all, because someone wanted one line.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 8,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:8), t; submit = false) do p; p.x; end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            s = sprint(show, r)
            @test length(split(s, '\n')) == 1                # one line, whatever the sweep holds
            @test occursin("8/8", s) && occursin("succeeded", s)
            # …and what it holds and where it ran, both already in the struct, so no extra reads.
            @test occursin("on local", s) && occursin("B", s)
            @test !occursin("ShardRef", s) && !occursin("params", s)
            @test length(s) < 100
            # The multi-line form is still the multi-line form.
            @test occursin("\n", sprint((io, x) -> show(io, MIME"text/plain"(), x), r))
        end
    end

    @testset "a unit's fields keep the order it returned them in" begin
        # The record rides a manifest as TOML, and a Dict has no order — so `(; snr, sep_px)` read
        # back as `(sep_px, snr)` and a results table's columns moved between reads.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:2), t; submit = false) do p
                (; zulu = p.x, alpha = p.x * 2, mike = p.x * 3)
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            @test keys(r.records[1]) == (:zulu, :alpha, :mike)      # not alphabetical — as written
            @test keys(r.dataset[1:2]) == (:x, :zulu, :alpha, :mike)
            # WHEN each unit ran, not only how long it took — a manifest records it and nothing
            # surfaced it, so "is this yesterday's result?" had no answer short of the store.
            @test all(x -> x isa Sweep.Dates.DateTime, r.dataset[1:2, (:at,)].at)
            @test occursin(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", String(Sweep.text(r)))
            @test occursin("ago", String(Sweep.text(r)))
        end
    end

    @testset "the sweep in words, not markup" begin
        # A sweep cell renders as an HTML card and the richer MIME always wins in a notebook, so the
        # text/plain form existed and had no way to reach the screen. One renderer, two surfaces.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:3), t; submit = false) do p
                (; sq = p.x^2)
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            Sweep.refresh!(r)
            rep = Sweep.text(r)
            txt = String(rep)
            @test occursin("succeeded", txt)
            @test occursin("3/3", txt)
            # …and it carries the results, which is the part the card had and this did not.
            @test occursin("sq", txt) && occursin(r"\bx\b", txt)
            @test occursin("9", txt)
            # Exactly what `show` produces, so there is no second version of the truth.
            @test txt == sprint((io, x) -> show(io, MIME"text/plain"(), x), r)
            @test !occursin("<div", txt)
            # It PRINTS as the report rather than as a quoted string: a String returned to a cell
            # renders as its repr, which is the whole report on one line with escaped newlines.
            @test sprint((io, x) -> show(io, MIME"text/plain"(), x), rep) == txt
            @test sprint(print, rep) == txt
            @test !occursin("\\n", sprint(show, rep))
        end
    end

    @testset "a reset takes the chart away with the results" begin
        # The payload could only ADD a chart: with nothing landed the option is `nothing` and the
        # key was omitted, so the browser's `if (s.chart)` never fired and the card went on showing
        # a chart of results that had just been thrown away.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false) do p; p.x * 2; end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            s1 = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            @test s1["chart"] !== nothing

            Sweep.handle_action(t, r.run, r.params, r.keys, "reset")
            s2 = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)
            # PRESENT and null — the difference between "no chart" and "no news", which is what the
            # card needs to tell them apart.
            @test haskey(s2, "chart") && s2["chart"] === nothing
            @test s2["fails"] == ""
            # `plot = false` says the same thing, rather than omitting the key.
            s3 = Sweep.status_payload(t, r.run, r.params, r.keys; plot = false, advance = false)
            @test haskey(s3, "chart") && s3["chart"] === nothing
        end
    end

    @testset "the chart you get without asking covers a grid, not just a line" begin
        # A `paramgrid` is a product of axes, so TWO varying axes is the most common shape a sweep
        # can have — and the default used to decline there, on the reasoning that a line would
        # project one away. True of a line; the ambiguity was which CHART, not which axis.
        mktempdir() do root
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 9,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = Sweep.@sweep(Sweep.paramgrid(a = 1:3, b = [10, 20, 30]), t; submit = false) do p
                p.a * p.b
            end
            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            opt = Sweep.status_payload(t, r.run, r.params, r.keys; advance = false)["chart"]
            @test opt["series"][1]["type"] == "heatmap"
            # Category axes over the sorted distinct values, so a log-spaced axis stays evenly
            # spaced instead of crowding into one corner.
            @test opt["xAxis"]["data"] == [1, 2, 3] && opt["xAxis"]["type"] == "category"
            @test opt["yAxis"]["data"] == [10, 20, 30] && opt["yAxis"]["name"] == "b"
            @test opt["visualMap"]["min"] == 10 && opt["visualMap"]["max"] == 90
            @test length(opt["series"][1]["data"]) == 9
            # `[xIndex, yIndex, value]` — the corners of the grid, both ends.
            @test [2, 2, 90] in opt["series"][1]["data"]         # a=3, b=30
            @test [0, 0, 10] in opt["series"][1]["data"]         # a=1, b=10

            # One axis is still a line.
            r1 = Sweep.@sweep(Sweep.paramgrid(a = 1:3), t; submit = false) do p; p.a * 2; end
            for c in BS.sweep_chunks(root, r1.run); SlateTask.run_chunk(root, c); end
            o1 = Sweep.status_payload(t, r1.run, r1.params, r1.keys; advance = false)["chart"]
            @test o1["series"][1]["type"] == "line"

            # THREE varying axes still declines, and that one is real: collapsing an axis means
            # choosing a reduction, which is the author's claim to make.
            r3 = Sweep.@sweep(Sweep.paramgrid(a = 1:2, b = 1:2, c = 1:2), t; submit = false) do p
                p.a + p.b + p.c
            end
            for c in BS.sweep_chunks(root, r3.run); SlateTask.run_chunk(root, c); end
            @test Sweep.status_payload(t, r3.run, r3.params, r3.keys;
                                       advance = false)["chart"] === nothing
        end
    end

    @testset "a sweep's plot rides the status poll" begin
        mktempdir() do root
            # TWO chunks, so there is a genuine half-landed state to assert on — the whole point of
            # handing the plot every unit is what it draws while some of them are still missing.
            t = Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            # The plot is handed EVERY unit in grid order, landed or not — without the holes it
            # cannot draw them, and a line through only the landed points invents shape across a
            # gap and then rewrites itself when the missing chunk arrives.
            # A plot works from SUMMARIES, never values — so it cannot pull result data on a poll
            # however large the units are.
            plot = rows -> Dict("series" => [Dict("data" =>
                [row.status == "ok" ? row.summary : nothing for row in rows])])
            r = Sweep.@sweep(Sweep.paramgrid(x = 1:4), t; submit = false, plot = plot) do p; p.x; end

            # Before anything runs: four units, all holes, so the axis is already the full grid.
            s0 = Sweep.status_payload(t, r.run, r.params, r.keys; plot, advance = false)
            @test s0["chart"]["series"][1]["data"] == [nothing, nothing, nothing, nothing]

            # Land only the FIRST chunk: the hole is where it actually is, not closed over.
            SlateTask.run_chunk(root, first(BS.sweep_chunks(root, r.run)))
            s1 = Sweep.status_payload(t, r.run, r.params, r.keys; plot, advance = false)
            @test s1["chart"]["series"][1]["data"] == [1, 2, nothing, nothing]

            for c in BS.sweep_chunks(root, r.run); SlateTask.run_chunk(root, c); end
            s = Sweep.status_payload(t, r.run, r.params, r.keys; plot, advance = false)
            @test s["chart"]["series"][1]["data"] == [1, 2, 3, 4]
            @test s["charterr"] == ""

            # A plot that throws says so on the card. A blank chart during a long run reads as a
            # stalled sweep, which is the one thing this whole design is trying to rule out.
            bad = Sweep.status_payload(t, r.run, r.params, r.keys;
                                       plot = _ -> error("no method matching frobnicate"),
                                       advance = false)
            @test bad["chart"] === nothing
            @test occursin("frobnicate", bad["charterr"])

            # Wrong return type is a mistake worth naming, not a silent no-chart.
            wrong = Sweep.status_payload(t, r.run, r.params, r.keys;
                                         plot = _ -> 42, advance = false)
            @test occursin("must return", wrong["charterr"])

            # The card carries the option inline too, so it draws before the first round trip.
            html = sprint(show, MIME"text/html"(), Sweep.refresh!(r))
            @test occursin("data-sw='chart'", html)
            @test occursin("\"data\":[1,2,3,4]", html)
        end
    end

    @testset "a cell's header configures the sweep without touching its code" begin
        # Walltime, partition and memory are what you change while a job is queued or after one was
        # killed. On the cell header they are editable from the UI; in a Julia keyword argument they
        # would mean editing source to adjust a number that is not part of the computation.
        mktempdir() do root
            t = Sweep.SlurmTarget("login";
                                  root, root_remote = "/scratch", project = tempdir(),
                                  payload = "/scratch/slatetask.jl", chunk = 4,
                                  resources = (; cpus = 1, mem = "1G", walltime = "00:10:00",
                                                 partition = "short"))
            attrs = Dict("walltime" => "04:00:00", "partition" => "gpu", "cpus" => "8",
                         "chunk" => "25", "cluster" => "ignored-here")
            res = Sweep.attr_resources(attrs)
            @test res.walltime == "04:00:00" && res.partition == "gpu" && res.cpus == 8
            @test !haskey(res, :mem)                    # unset stays inherited from the target
            @test Sweep.attr_chunk(attrs) == 25

            t2 = Sweep.with_chunk(Sweep.with_resources(t, res), Sweep.attr_chunk(attrs))
            @test t2.resources.walltime == "04:00:00" && t2.resources.partition == "gpu"
            @test t2.resources.mem == "1G"              # merged, not replaced
            @test t2.chunk == 25
            @test t2.root == t.root && t2.payload == t.payload

            @test Sweep.attr_resources(Dict{String,String}()) === nothing
            @test Sweep.attr_chunk(Dict{String,String}()) === nothing
            # A count that is not a number must say so rather than silently asking for zero CPUs.
            @test_throws ErrorException Sweep.attr_resources(Dict("cpus" => "lots"))
            @test_throws ErrorException Sweep.attr_chunk(Dict("chunk" => "0"))
            # Slate's OWN cell settings are never forwarded to the scheduler as job options.
            slate_only = Dict("cluster" => "hpc", "data" => "lazy", "chunk" => "4",
                              "region" => "gpu", "needs" => "prep")
            @test Sweep.attr_resources(slate_only) === nothing
            # …and anything else is a scheduler option, whether or not Slate has heard of it. A
            # fixed list is a losing game: sbatch has ~40 options and sites add their own.
            @test Sweep.attr_resources(Dict("licenses" => "ansys@srv")).licenses == "ansys@srv"
        end
    end

    # The script is the whole product of every setting above, and nothing asserted its CONTENT — so
    # `gpus=` and `nodes=` were accepted on a header, parsed into the spec, and then never emitted.
    # A cell asking for a GPU ran without one and returned plausible numbers from the wrong hardware.
    @testset "every setting reaches the batch script" begin
        l = BL.SlurmLauncher("login"; account = "site-acct", qos = "site-qos")
        spec(res; directives = "") =
            BL.JobSpec("sw1", ["c1", "c2"]; root = "/scratch/cas", project = "/proj",
                       payload = "/proj/slatetask.jl", resources = res, directives = directives)
        script(res; kw...) = BL._sbatch_script(l, spec(res; kw...), "/scratch/cas/jobs/sw1.index")

        s = script((; cpus = 8, mem = "16G", walltime = "04:00:00", partition = "gpu",
                      gpus = 2, nodes = 1, ntasks = 4, ntasks_per_node = 2, mem_per_cpu = "2G",
                      constraint = "avx512", reservation = "maint", gres = "gpu:v100:2",
                      nodelist = "c[1-4]", exclude = "c7", tmp = "100G"))
        for want in ["--cpus-per-task=8", "--mem=16G", "--time=04:00:00", "--partition=gpu",
                     "--gpus=2", "--nodes=1", "--ntasks=4", "--ntasks-per-node=2",
                     "--mem-per-cpu=2G", "--constraint=avx512", "--reservation=maint",
                     "--gres=gpu:v100:2", "--nodelist=c[1-4]", "--exclude=c7", "--tmp=100G"]
            @test occursin("#SBATCH " * want * "\n", s)
        end
        # `_` → `-`, so an option Slate has never heard of works the day the site invents it.
        @test occursin("#SBATCH --switches=1@00:30:00\n",
                       script((; switches = "1@00:30:00")))
        # Absent means ABSENT: emitting `--nodes=1` for a cell that asked for nothing would
        # override the partition's own configuration with a guess.
        bare = script((; cpus = 2))
        @test !occursin("--nodes", bare) && !occursin("--gpus", bare) && !occursin("--constraint", bare)
        # Cores, memory and time are always stated — a job at the mercy of a site's defaults is the
        # one whose walltime kills it.
        @test occursin("--cpus-per-task=2", bare) && occursin("--mem=1G", bare) &&
              occursin("--time=00:30:00", bare)

        # Account and QoS come from the SITE unless the cell overrides them (two allocations, one
        # sweep billed to each).
        @test occursin("--account=site-acct", bare) && occursin("--qos=site-qos", bare)
        mine = script((; account = "my-grant"))
        @test occursin("--account=my-grant", mine) && !occursin("--account=site-acct", mine)

        # `--exclusive` is the one flag whose value is optional.
        @test occursin("#SBATCH --exclusive\n", script((; exclusive = "yes")))
        @test occursin("#SBATCH --exclusive=user\n", script((; exclusive = "user")))
        @test !occursin("--exclusive", script((; exclusive = "no")))

        # Three options have a Slate name that differs from sbatch's, so the same setting is
        # reachable two ways (`cpus` / `cpus_per_task`). A spec holding both — an older notebook, a
        # hand-edited footer, the editor before it resolved aliases — must emit ONE flag, with the
        # explicit spelling winning. Two `--cpus-per-task` lines is something sbatch tolerates and a
        # reader does not.
        dup = script((; cpus = 1, cpus_per_task = 4))
        @test count(l -> occursin("--cpus-per-task=", l), split(dup, "\n")) == 1
        @test occursin("#SBATCH --cpus-per-task=4\n", dup)
        @test BL.sbatch_flag(:cpus) == BL.sbatch_flag(:cpus_per_task)   # …the alias this guards

        # Two identical sweeps must produce identical scripts, or the content-derived job name
        # stops matching what was submitted.
        r = (; cpus = 4, gpus = 1, partition = "gpu", constraint = "avx2")
        @test script(r) == script(r)
    end

    @testset "free-form directives are emitted verbatim, and last" begin
        # The escape hatch for a flag whose value a cell header cannot carry (`=` in the value is
        # folded by the tag sanitiser) and for site options there is no point naming.
        @test BL.directive_lines("--licenses=ansys@srv\n\n  --switches=1  \n# a comment\n") ==
              ["#SBATCH --licenses=ansys@srv", "#SBATCH --switches=1"]
        # Written either way, because both are what is in front of you in a working batch script.
        @test BL.directive_lines("#SBATCH --exclusive") == ["#SBATCH --exclusive"]
        @test BL.directive_lines("") == [] && BL.directive_lines("\n \n") == []
        # A shell line here would be silently ignored rather than run, so it is an error instead.
        @test_throws ErrorException BL.directive_lines("module load julia")

        l = BL.SlurmLauncher("login")
        s = BL._sbatch_script(l, BL.JobSpec("sw1", ["c1"]; root = "/r", project = "/p",
                                            payload = "/p/t.jl", resources = (; partition = "short"),
                                            directives = "--partition=bigmem"),
                              "/r/jobs/sw1.index")
        # sbatch takes the LAST occurrence, so a directive must come after the named settings for
        # the override to mean anything.
        @test findlast("--partition=bigmem", s)[1] > findlast("--partition=short", s)[1]
        @test findlast("--partition=bigmem", s)[1] < findfirst("set -euo pipefail", s)[1]

        # Either prefix is accepted on INPUT, so moving a definition between a SLURM cluster and a
        # PBS one does not mean re-typing the block — only the emitted prefix changes.
        @test BL.directive_lines("#PBS -l scratch_local=10gb"; prefix = "#PBS") ==
              ["#PBS -l scratch_local=10gb"]
        @test BL.directive_lines("-A other"; prefix = "#PBS") == ["#PBS -A other"]
    end

    # PBS is not SLURM with different flag names. Per-node resources live INSIDE a chunk statement,
    # there is no `--dependency=singleton`, and several settings cannot be said at all — each of
    # which is a decision the emitter has to make rather than a translation it can perform.
    @testset "a PBS job asks in PBS's own shape" begin
        l = BL.PbsLauncher("login"; account = "site-acct")
        spec(res; chunks = ["c1", "c2"], directives = "") =
            BL.JobSpec("sw1", chunks; root = "/scratch/cas", project = "/proj",
                       payload = "/proj/slatetask.jl", resources = res, directives = directives)
        script(res; kw...) = BL._pbs_script(l, spec(res; kw...), "/scratch/cas/jobs/sw1.index")

        # Sizes: SLURM writes `16G`, and PBS does not accept it. A size already in PBS's form, or in
        # a site syntax this does not recognise, is passed through rather than corrected.
        @test BL.pbs_size("16G") == "16gb" && BL.pbs_size("512M") == "512mb"
        @test BL.pbs_size("16gb") == "16gb" && BL.pbs_size("2TB") == "2tb"
        @test BL.pbs_size("1024") == "1024b"          # a bare number is bytes in PBS too
        @test BL.pbs_size("16gw") == "16gw"           # words, which PBS has and SLURM does not

        # Per-node resources go in the chunk; how many nodes is the chunk COUNT.
        @test BL.pbs_select((; cpus = 8, mem = "16G")) == "1:ncpus=8:mem=16gb"
        # Cores and memory lead; the rest follow in a fixed order, because two identical sweeps must
        # produce identical scripts or the content-derived job name stops matching what was sent.
        @test BL.pbs_select((; nodes = 2, cpus = 4, gpus = 1, ntasks_per_node = 2)) ==
              "2:ncpus=4:mem=1gb:ngpus=1:mpiprocs=2"
        # A cell that says nothing still states cores and memory — a job at the mercy of a site's
        # defaults is the one whose limits kill it.
        @test BL.pbs_select(NamedTuple()) == "1:ncpus=1:mem=1gb"
        # …but an interactive ALLOCATION asks only for what was named, exactly as `salloc` does.
        @test BL.pbs_select((; cpus = 4); defaults = false) == "1:ncpus=4"
        @test BL.pbs_select(NamedTuple(); defaults = false) == "1"
        # `select=` written out wins outright: one escape hatch answers every site chunk resource
        # Slate has no name for, which is what the unmappable settings below point at.
        @test BL.pbs_select((; cpus = 8, select = "3:ncpus=2:scratch_local=10gb")) ==
              "3:ncpus=2:scratch_local=10gb"

        s = script((; cpus = 8, mem = "16G", walltime = "04:00:00", partition = "gpu",
                      gpus = 2, nodes = 1, ntasks_per_node = 2, exclusive = "yes"))
        for want in ["#PBS -N sw1", "#PBS -j oe", "#PBS -J 1-2",
                     "#PBS -l select=1:ncpus=8:mem=16gb:ngpus=2:mpiprocs=2",
                     "#PBS -l walltime=04:00:00", "#PBS -q gpu", "#PBS -A site-acct",
                     "#PBS -l place=excl"]
            @test occursin(want * "\n", s)
        end
        # `-o` must name the FILE. Given a directory PBS names the output after the JOB ID, which is
        # the one thing the fabric deliberately never keeps — so `logs`, which is asked for a NAME,
        # found nothing at all. `^array_index^` is how an element gets its own file.
        @test occursin("#PBS -o /scratch/cas/logs/sw1.^array_index^.out\n", s)
        @test occursin("PBS_ARRAY_INDEX", s) && !occursin("SLURM", s)
        @test occursin("#PBS -l place=exclhost\n", script((; exclusive = "exclhost")))
        @test !occursin("place=", script((; exclusive = "no")))

        # A one-element array is not an array — PBS rejects the degenerate range — so the index is
        # read with a default and the same script serves both cases.
        one = script((; cpus = 1); chunks = ["c1"])
        @test !occursin("-J ", one) && occursin("\${PBS_ARRAY_INDEX:-1}", one)
        # …and its log is named as though it were element 1, so one glob finds either.
        @test occursin("#PBS -o /scratch/cas/logs/sw1.1.out\n", one)

        # Anything Slate has not named becomes a job-wide resource, written AS TYPED: PBS resource
        # names carry underscores, so sbatch's `_` → `-` would be wrong here.
        @test occursin("#PBS -l min_walltime=00:10:00\n", script((; min_walltime = "00:10:00")))

        # Two identical sweeps must produce identical scripts, or the content-derived job name stops
        # matching what was submitted.
        r = (; cpus = 4, gpus = 1, partition = "gpu", qos = "high", scratch_local = "10gb")
        @test script(r) == script(r)

        # Directives last, so they win — and they are `#PBS` here without the author re-typing them.
        d = script((; partition = "short"); directives = "-q bigmem")
        @test findlast("#PBS -q bigmem", d)[1] > findlast("#PBS -q short", d)[1]
        @test findlast("#PBS -q bigmem", d)[1] < findfirst("set -euo pipefail", d)[1]

        # Anything MECHANICAL is translated rather than refused, so a cell states what the work
        # needs once and each scheduler is asked in its own words. PBS has no per-CPU memory, but a
        # chunk holds exactly `ncpus` cpus, so the multiplication is arithmetic and not a guess.
        @test occursin("#PBS -l select=1:ncpus=4:mem=8gb\n", script((; cpus = 4, mem_per_cpu = "2G")))
        @test occursin("#PBS -l select=3:ncpus=2:mem=1024mb\n",
                       script((; nodes = 3, cpus = 2, mem_per_cpu = "512M")))
        @test !occursin("mem_per_cpu", script((; cpus = 4, mem_per_cpu = "2G")))
        # A `nodelist` naming ONE node is where a PBS chunk goes; several would need a chunk each.
        # `vnode`, NOT `host`: the two differ unless a cluster names its vnodes after its machines,
        # and `vnode` is the name `pbsnodes`/`exec_host` use — so it is the one the user has, and the
        # one `find_allocation` reports back. `host=` matches nothing and the job queues forever.
        @test occursin("#PBS -l select=1:ncpus=1:mem=1gb:vnode=c1\n", script((; nodelist = "c1")))
        for bad in ((; cpus = 4, mem = "8G", mem_per_cpu = "2G"),   # ambiguous, SLURM refuses too
                    (; nodelist = "c1,c2"))
            @test_throws ErrorException script(bad)
        end

        # A setting whose usual SLURM meaning has no PBS form is FORWARDED, with a warning — not
        # refused. PBS lets a site define arbitrary resources, so a name that means one thing on
        # SLURM may be a real resource here, and blocking it because SLURM uses the word would
        # refuse work that would have run. A site without it gets `Unknown resource` from `qsub`,
        # which is the loud rejection the pass-through rule asks for.
        hinted = [(:constraint, "avx512"), (:gres, "gpu:v100:2"), (:exclude, "c7"),
                  (:reservation, "maint"), (:ntasks, 4)]
        @test isempty([k for (k, v) in hinted
                       if !occursin("#PBS -l $(k)=$(v)\n", script(NamedTuple{(k,)}((v,))))])
        # …and symmetrically, `select=` reaches sbatch, which rejects it.
        @test occursin("#SBATCH --select=1:ncpus=2\n",
                       BL._sbatch_script(BL.SlurmLauncher("login"),
                                         BL.JobSpec("sw1", ["c1"]; root = "/r", project = "/p",
                                                    payload = "/p/t.jl",
                                                    resources = (; select = "1:ncpus=2")),
                                         "/r/jobs/sw1.index"))
        # The advice lives in the catalogue instead, where the editor shows it before submit.
        @test BL.pbs_flag(:constraint) == "" && occursin("select=", BL._PBS_HINT[:constraint])
        @test BL.pbs_flag(:cpus) == "select=…:ncpus" && BL.pbs_flag(:walltime) == "-l walltime"
    end

    # The half of a launcher a unit test can actually reach: `qstat -f` has no output format of its
    # own, so what Slate knows about a job comes out of an awk script — and an awk script that is
    # never run is a guess. `PbsLauncher("")` runs its commands through a local shell, so a fake
    # scheduler on PATH exercises the parsing for real.
    @testset "PBS state comes out of qstat -f" begin
        mktempdir() do bin
            state = joinpath(bin, "queue")
            write(state, """
                Job Id: 12.pbsserver
                    Job_Name = sw1_c1
                    Job_Owner = slate@login
                    job_state = R
                    queue = compute
                    Resource_List.select = 1:ncpus=1:mem=1gb
                    Resource_List.walltime = 00:30:00
                    resources_used.walltime = 00:00:07
                    exec_host = c1/0*2

                Job Id: 13.pbsserver
                    Job_Name = sw1_c2
                    job_state = Q
                    queue = compute
                    Resource_List.walltime = 00:30:00

                Job Id: 14.pbsserver
                    Job_Name = slate-gpu
                    job_state = R
                    queue = gpu
                    Resource_List.walltime = 02:00:00
                    resources_used.walltime = 00:20:00
                    exec_host = c2/0*4+c1/0

                Job Id: 15.pbsserver
                    Job_Name = sw1_c9
                    job_state = F
                    queue = compute
                """)
            # The fakes reproduce two behaviours that a permissive stand-in would hide, and both are
            # things the real scheduler does: `qstat` takes ids rather than a user, and `-u`
            # SILENTLY OVERRIDES `-f` — printing the short table, which has no Job_Name column at
            # all. Asking `qstat -f -u $USER` therefore parses as "no jobs anywhere", which reads as
            # a sweep that never started. Verified against OpenPBS 23.06.
            for (nm, body) in (
                "qstat"   => """
                    full=0; byuser=0; ids=""
                    for a in "\$@"; do
                      case "\$a" in
                        -f) full=1 ;;
                        -u) byuser=1 ;;
                        -*) ;;
                        *)  ids="\$ids \$a" ;;
                      esac
                    done
                    if [ "\$byuser" = 1 ]; then
                      echo "Job ID  Username Queue    Jobname   SessID NDS TSK Memory Time S Time"
                      exit 0
                    fi
                    [ "\$full" = 1 ] || exit 0
                    awk -v want="\$ids" '
                      BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1 }
                      /^Job Id:/ { id = substr(\$0, 9); sub(/[ \\t\\r]+\$/, "", id)
                                   p = (want == "" || (id in keep)) }
                      p { print }' "$(state)"
                    exit 0""",
                # `qselect -N <name>`: the ids of the jobs under that name, which is the step `qdel`
                # needs and SLURM's `scancel --name` does not. With no `-N`, every id. LIVE jobs
                # only, which is what makes it usable as the "was there anything to cancel" answer.
                "qselect" => """
                    n=""
                    while [ \$# -gt 0 ]; do
                      [ "\$1" = "-N" ] && { shift; n="\$1"; }
                      shift
                    done
                    awk -v want="\$n" '
                      function out() {
                        if (id != "" && (want == "" || n == want) && s != "F" && s != "X") print id
                        id = ""; n = ""; s = ""
                      }
                      /^Job Id:/      { out(); id = substr(\$0, 9); sub(/[ \\t\\r]+\$/, "", id) }
                      /Job_Name = /   { n = \$3 }
                      /job_state = /  { s = \$3 }
                      END             { out() }' "$(state)"
                    exit 0""",
                "qdel"    => ": > \"$(state)\"\nexit 0")
                p = joinpath(bin, nm)
                write(p, "#!/bin/sh\n" * body * "\n")
                chmod(p, 0o755)
            end
            withenv("PATH" => bin * ":" * ENV["PATH"]) do
                l = BL.PbsLauncher()          # no host: the client tools are on THIS machine
                st = BL.poll(l, "/scratch/cas", ["sw1_c1", "sw1_c2", "sw1_c9", "sw1_nope"])
                @test st["sw1_c1"] === :running
                @test st["sw1_c2"] === :pending
                # `F` is a job the scheduler no longer holds. Deliberately NOT "finished": only the
                # store can say that, because a job can die without producing anything.
                @test st["sw1_c9"] === :unknown
                @test st["sw1_nope"] === :unknown          # never submitted, or long gone
                @test BL.poll(l, "/scratch/cas", String[]) == Dict{String,Symbol}()

                # An allocation is found by NAME through the same output, and what is LEFT of it is
                # the walltime asked for minus the walltime used — PBS reports no `%L`.
                a = Sweep.find_allocation(:pbs, "", "slate-gpu")
                @test Sweep.alive(a) && a.id == "14.pbsserver" && a.node == "c2"
                @test a.timeleft == "01:40:00"
                @test Sweep.find_allocation(:pbs, "", "sw1_c2").state === :pending
                @test Sweep.find_allocation(:pbs, "", "sw1_c9").state === :none
                @test Sweep.find_allocation(:pbs, "", "nothing-here").state === :none

                # Cancelling resolves names to ids first, and counts what actually LEFT the queue
                # rather than trusting an exit status.
                @test BL.cancel!(l, "/scratch/cas", ["sw1_c1", "sw1_c9"]) == 1
                @test BL.cancel!(l, "/scratch/cas", ["sw1_c1"]) == 0     # nothing live left to stop
            end
        end
    end

    @testset "a sweep cell resolves its cluster by name" begin
        # Clusters are defined ONCE for the notebook and referenced by name, so several cells share
        # one definition and moving the work is a single edit.
        mktempdir() do root
            defs = Dict("hpc" => Dict("kind" => "slurm", "host" => "login", "root" => root,
                                      "root_remote" => "/scratch/cas", "project" => tempdir(),
                                      "payload" => "/scratch/slatetask.jl",
                                      "partition" => "compute", "walltime" => "02:00:00",
                                      "cpus" => "2", "mem" => "8G", "chunk" => "16"),
                        "box" => Dict("kind" => "local", "root" => root, "project" => tempdir()))

            # What the SLURM definition MEANS, checked without building it: constructing a target
            # provisions an environment over ssh, and validating a definition must not need the
            # cluster to be reachable.
            a = Sweep.cluster_args(merge(Dict("name" => "hpc"), defs["hpc"]))
            @test a.kind == "slurm" && a.host == "login"
            @test a.root_remote == "/scratch/cas" && a.chunk == 16
            @test a.resources.partition == "compute" && a.resources.cpus == 2
            @test a.resources.mem == "8G" && a.resources.walltime == "02:00:00"
            # `root_remote` defaults to `root`: a cluster sharing one filesystem needs to say it once.
            @test Sweep.cluster_args(Dict("name" => "s", "root" => root, "payload" => "p")).root_remote == root

            @test Sweep.resolve_target(nothing, Dict("cluster" => "box"), defs) isa Sweep.LocalTarget

            # A target written in the cell wins over the header — the explicit one is the cell's own.
            explicit = Sweep.LocalTarget(; root, project = tempdir(), payload = "x", chunk = 2)
            @test Sweep.resolve_target(explicit, Dict("cluster" => "hpc"), defs) === explicit

            # The failure modes name what IS defined: the usual cause is a typo or a rename.
            # A definition missing what the backend needs must say which field, not fail later at
            # submission time with a scheduler error.
            # The task runner is Slate's own code and is SHIPPED during provisioning, so a
            # definition naming no `payload` is complete rather than broken.
            @test Sweep.cluster_args(Dict("name" => "s", "root" => root)).payload == ""
            # A cluster reached over ssh has one store and it is the CLUSTER's — saying only where
            # it is on this machine says nothing about where the jobs will look.
            e1 = try
                Sweep.cluster_args(Dict("name" => "s", "host" => "login1", "root" => root))
                nothing
            catch x; x; end
            @test occursin("no `root_remote`", sprint(showerror, e1))
            @test occursin("scratch", sprint(showerror, e1))     # …and says where to put it
            # …while a LOCAL one needs a path here, since that is the only side there is.
            e2 = try; Sweep.cluster_args(Dict("name" => "s")); catch x; x; end
            @test occursin("no `root`", sprint(showerror, e2))
            # A host plus a cluster-side store is enough on its own.
            a = Sweep.cluster_args(Dict("name" => "s", "host" => "login1",
                                        "root_remote" => "/scratch/slate"))
            @test a.root_remote == "/scratch/slate" && a.payload == ""

            # A typo is the usual cause, so the error names what this machine DOES have. It points at
            # the UI rather than at header syntax: the cluster is picked from the cell's ⚙, and
            # telling someone to type `#%% sweep cluster=…` describes a path nobody takes.
            e = try; Sweep.resolve_target(nothing, Dict("cluster" => "hcp"), defs); catch x; x; end
            @test occursin("no cluster named `hcp`", sprint(showerror, e))
            @test occursin("box, hpc", sprint(showerror, e))
            e2 = try; Sweep.resolve_target(nothing, Dict{String,String}(), defs); catch x; x; end
            @test occursin("box, hpc", sprint(showerror, e2))          # names the choices, not the syntax
            e3 = try; Sweep.resolve_target(nothing, Dict{String,String}(), Dict()); catch x; x; end
            @test occursin("Remotes → Clusters", sprint(showerror, e3))  # nothing defined ⇒ say where to

            # An unsupported scheduler is an error naming what this build does support, not a
            # silent fall-through to SLURM.
            e4 = try
                Sweep.cluster_args(Dict("name" => "k", "kind" => "k8s", "root" => root))
            catch x; x; end
            @test occursin("kind `k8s`", sprint(showerror, e4))

            # A PBS cluster is the same definition with one word changed. Which scheduler is a
            # property of the cluster, so nothing in the cell moves and only the launcher differs.
            pbs = Sweep.cluster(Dict("name" => "hpc2", "kind" => "pbs", "host" => "login",
                                     "root_remote" => "/scratch/cas", "project" => tempdir(),
                                     "partition" => "compute", "walltime" => "02:00:00"))
            @test pbs isa Sweep.ClusterTarget && pbs.kind === :pbs
            @test Sweep.launcher_for(pbs) isa Sweep.BatchLauncher.PbsLauncher
            @test Sweep.launcher_for(Sweep.SlurmTarget("login"; root_remote = "/s")) isa
                  Sweep.BatchLauncher.SlurmLauncher
            @test Sweep.PbsTarget("login"; root_remote = "/s").kind === :pbs
            @test occursin("pbs", Sweep._target_line(Sweep.PbsTarget(; root = root)))
        end
    end

    @testset "the option JSON writer covers what an ECharts option contains" begin
        @test Sweep._json(Dict("a" => 1, "b" => "x")) in
              ("{\"a\":1,\"b\":\"x\"}", "{\"b\":\"x\",\"a\":1}")
        # `Any[…]`, not `[…]`: an untyped array literal promotes, so `[1, true]` would arrive here
        # already converted to floats and the test would be checking Julia's parser, not the writer.
        @test Sweep._json(Any[1, 2.5, true, nothing]) == "[1,2.5,true,null]"
        @test Sweep._json(Dict("k" => (1, 2))) == "{\"k\":[1,2]}"
        @test Sweep._json(:sym) == "\"sym\""
        # NaN/Inf are not JSON; emitting them raw makes the whole card fail to parse.
        @test Sweep._json([NaN, Inf]) == "[null,null]"
        # A string that closes the script tag would end the card early.
        @test !occursin("</script>", Sweep._json("</script><b>"))
        @test Sweep._json("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\""
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
