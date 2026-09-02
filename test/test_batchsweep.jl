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

        # PBS is detectable and configurable but cannot be allocated on by this build. Saying so is
        # the point: issuing SLURM commands to a scheduler that has never heard of them would fail
        # further from the cause, and silently running on the login node would be worse than either.
        @test_throws ErrorException Sweep._unsupported_scheduler(:pbs)
        @test occursin("SLURM only", try; Sweep._unsupported_scheduler(:pbs); catch e; e.msg; end)
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
            @test !haskey(Sweep.status_payload(t, r.run, r.params, r.keys; advance = false), "chart")
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
            @test !haskey(s, "charterr")

            # A plot that throws says so on the card. A blank chart during a long run reads as a
            # stalled sweep, which is the one thing this whole design is trying to rule out.
            bad = Sweep.status_payload(t, r.run, r.params, r.keys;
                                       plot = _ -> error("no method matching frobnicate"),
                                       advance = false)
            @test !haskey(bad, "chart")
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
            @test occursin("no compute target named `hcp`", sprint(showerror, e))
            @test occursin("box, hpc", sprint(showerror, e))
            e2 = try; Sweep.resolve_target(nothing, Dict{String,String}(), defs); catch x; x; end
            @test occursin("box, hpc", sprint(showerror, e2))          # names the choices, not the syntax
            e3 = try; Sweep.resolve_target(nothing, Dict{String,String}(), Dict()); catch x; x; end
            @test occursin("Compute targets", sprint(showerror, e3))     # nothing defined ⇒ say where to

            # An unsupported scheduler is an error naming what this build does support, not a
            # silent fall-through to SLURM.
            e4 = try
                Sweep.cluster_args(Dict("name" => "k", "kind" => "pbs", "root" => root))
            catch x; x; end
            @test occursin("kind `pbs`", sprint(showerror, e4))
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
