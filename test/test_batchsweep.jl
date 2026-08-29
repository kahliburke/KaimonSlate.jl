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

# A sweep of `nchunk` chunks of `per` shards each, over `fn_src`.
function mksweep(root; nchunk = 2, per = 3, fn_src = "p -> p * 2", sweep = "sweep0")
    chunks = String[]
    n = 0
    for c in 1:nchunk
        chunk = "chunk$(c)"
        params = collect((n + 1):(n + per)); n += per
        SlateTask.write_chunk!(root, chunk; fn_src, params,
                               keys = ["s$(p)" for p in params])
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
            p = BS.reconcile!(root, sweep, l, specfn(root))
            @test length(l.submitted) == 1
            @test sort(l.submitted[1].chunks) == sort(chunks)
            @test all(s -> s in (:pending, :running), values(p.chunk_state))
            @test isempty(p.to_submit)
            # Second pass: the work is live, so nothing new goes out.
            BS.reconcile!(root, sweep, l, specfn(root))
            @test length(l.submitted) == 1
        end
    end

    @testset "a live submission survives a hub restart" begin
        # The durability property: nothing is carried in memory between these two reconciles, and
        # the second one still knows the work is in flight.
        mktempdir() do root
            sweep, _ = mksweep(root)
            l = FakeLauncher()
            BS.reconcile!(root, sweep, l, specfn(root))
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
            MemoStore.drop_manifest(root, "s2")             # pretend one shard never landed
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
            @test BS.is_complete(p)                          # done is done, failures included
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
            BS.reconcile!(root, sweep, l, specfn(root))
            # Wait for the subprocesses; they are plain julia starts, so give them room.
            done = false
            for _ in 1:120
                BS.is_complete(BS.plan(root, sweep)) && (done = true; break)
                sleep(1)
            end
            p = BS.plan(root, sweep)
            @test done
            @test (p.shards_total, p.shards_ok, p.shards_failed) == (4, 4, 0)
            @test [r.value for r in BS.results(root, sweep)] == [2, 4, 6, 8]
        end
    end
end
