# Unit tests for the batch-fabric task runner (src/slatetask.jl) — the stateless CAS-in, CAS-out
# process a scheduler starts on a compute node. No scheduler is involved here: everything runs
# in-process against a fresh mktempdir, which is exactly the point of the runner being stateless.
using ReTest
import Serialization
include(joinpath(@__DIR__, "..", "src", "memostore.jl"))
include(joinpath(@__DIR__, "..", "src", "slatetask.jl"))

# A sweep of `n` shards over `fn_src`, keyed the way the hub will key them (any filename-safe
# string works here; the real key is a content digest).
function mkchunk(root, n; fn_src = "p -> p * 2", setup_src = "", captures = Dict{String,Any}(),
                 chunk = "chunk0", params = collect(1:n))
    keys = ["shard$(i)" for i in 1:length(params)]
    SlateTask.write_chunk!(root, chunk; fn_src, params, keys, setup_src, captures)
    return (chunk, keys)
end

blobcount(root) = sum(length(fs) for (_, _, fs) in walkdir(joinpath(root, "blobs")); init = 0)

@testset "a chunk where nothing worked exits nonzero" begin
    # Individual failures are a STORE fact — a sweep is expected to have some, and the manifests
    # carry them. A chunk where everything attempted failed is different: it is a failed chunk, and
    # an exit status is the only thing a scheduler can read. That is what lets the rest of a sweep
    # be queued behind the first chunk with `--dependency=afterok`, so nothing local is needed
    # between the waves.
    #
    # `ran` counts the units that SUCCEEDED and `failed` those that did not, so what was attempted
    # is their sum. A chunk that skipped its units attempted nothing and proves nothing either way.
    run1(root, chunk) = redirect_stderr(devnull) do; SlateTask.main([root, chunk]); end

    mktempdir() do root
        chunk, _ = mkchunk(root, 4)
        @test run1(root, chunk) == 0
        @test run1(root, chunk) == 0          # re-run: every unit skipped, nothing attempted
    end
    mktempdir() do root
        chunk, _ = mkchunk(root, 4; fn_src = "p -> error(\"always\")")
        @test run1(root, chunk) == 1
        r = SlateTask.run_chunk(root, chunk)
        @test r.ran == 0 && r.failed == 0     # …and a re-run attempts nothing: they are recorded
    end
    mktempdir() do root
        # Some failures are still a sweep that ran. Exiting nonzero here would stop the rest of a
        # grid over one bad parameter point, which is the opposite of what a sweep is for.
        chunk, _ = mkchunk(root, 4; fn_src = "p -> (p == 1 ? error(\"one\") : p * 2)")
        @test run1(root, chunk) == 0
    end
end

@testset "slatetask" begin
    @testset "round trip: a chunk runs and its shards read back" begin
        mktempdir() do root
            chunk, keys = mkchunk(root, 4)
            r = SlateTask.run_chunk(root, chunk)
            @test (r.total, r.ran, r.skipped, r.failed) == (4, 4, 0, 0)
            got = [SlateTask.result(root, k) for k in keys]
            @test all(x -> x[1] && x[2] == "ok", got)
            @test [x[3] for x in got] == [2, 4, 6, 8]
        end
    end

    @testset "idempotent: a second run skips everything, force re-runs" begin
        mktempdir() do root
            chunk, _ = mkchunk(root, 3)
            SlateTask.run_chunk(root, chunk)
            again = SlateTask.run_chunk(root, chunk)
            @test (again.ran, again.skipped, again.failed) == (0, 3, 0)
            forced = SlateTask.run_chunk(root, chunk; force = true)
            @test (forced.ran, forced.skipped) == (3, 0)
        end
    end

    @testset "partial completion resumes rather than repeats" begin
        # The preemption / walltime-kill case: some shards landed, the job died, it is requeued.
        mktempdir() do root
            chunk, keys = mkchunk(root, 5)
            @test !any(SlateTask.is_done(root, k) for k in keys)
            SlateTask.run_chunk(root, chunk)
            # Pretend these never finished. The log is immutable, so a unit is forgotten by saying
            # so in a later event rather than by deleting the one that recorded it.
            SlateTask.write_event!(root, chunk, Dict{String,Any}[]; dropped = keys[1:2])
            r = SlateTask.run_chunk(root, chunk)
            @test (r.ran, r.skipped) == (2, 3)
        end
    end

    @testset "a failing shard is recorded and the chunk continues" begin
        mktempdir() do root
            chunk, keys = mkchunk(root, 4; fn_src = "p -> p == 3 ? error(\"boom on 3\") : p * 10")
            r = SlateTask.run_chunk(root, chunk)
            @test (r.ran, r.failed) == (3, 1)
            found, st, val = SlateTask.result(root, keys[3])
            @test found && st == "error"
            @test occursin("boom on 3", String(val))
            # the shards after the failure still ran
            @test SlateTask.result(root, keys[4])[3] == 40
        end
    end

    @testset "captures and setup source" begin
        mktempdir() do root
            chunk, keys = mkchunk(root, 2;
                setup_src = "scale(x) = x * 100",
                fn_src = "p -> scale(p) + offset",
                captures = Dict{String,Any}("offset" => 7))
            SlateTask.run_chunk(root, chunk)
            @test [SlateTask.result(root, k)[3] for k in keys] == [107, 207]
        end
    end

    @testset "the event log tracks progress without a file per unit" begin
        mktempdir() do root
            chunk, _ = mkchunk(root, 6)
            SlateTask.run_chunk(root, chunk)
            evs = SlateTask.chunk_events(root, chunk)
            pr = SlateTask.chunk_progress(root, evs)
            @test (pr.total, pr.ran, pr.failed) == (6, 6, 0)
            @test pr.done == 6
            @test !isempty(pr.node)
            # Six units, a couple of events, and no manifest per unit. That ratio is the point.
            @test length(evs) < 6
            @test length(SlateTask.chunk_rows(root, chunk)) == 6
        end
    end

    @testset "compaction folds a chunk's log without changing what it says" begin
        # A store's log would otherwise grow for its whole life. Folding is optional: a store that
        # is never compacted is correct, only larger.
        mktempdir() do root
            chunk, keys = mkchunk(root, 4)
            SlateTask.run_chunk(root, chunk)
            SlateTask.write_event!(root, chunk, Dict{String,Any}[]; dropped = [keys[2]])
            before = SlateTask.chunk_rows(root, chunk)
            @test length(SlateTask.chunk_events(root, chunk)) > 1

            n = SlateTask.compact_events!(root; grace = -1.0)
            @test n > 0
            @test length(SlateTask.chunk_events(root, chunk)) == 1
            # Same answer, fewer files — including the removal, which must survive folding.
            @test sort(collect(keys2 for keys2 in Base.keys(SlateTask.chunk_rows(root, chunk)))) ==
                  sort(collect(Base.keys(before)))
            @test !haskey(SlateTask.chunk_rows(root, chunk), keys[2])
            # Counts come from the rows: the newest event folded was a tombstone carrying none, and
            # inheriting its header made a compacted chunk report nothing done.
            pr = SlateTask.chunk_progress(root, SlateTask.chunk_events(root, chunk))
            @test (pr.done, pr.failed, pr.total) == (3, 0, 4)
        end
    end

    @testset "artifacts: stored, listed, and priced into the entry" begin
        mktempdir() do root
            src = """
            p -> begin
                f = joinpath(tempdir(), "art\$(p).txt")
                write(f, "payload-\$(p)")
                SlateTask.artifact!(f; name = "out\$(p).txt")
                p
            end
            """
            chunk, keys = mkchunk(root, 2; fn_src = src)
            r = SlateTask.run_chunk(root, chunk)
            # Assert the shards actually succeeded first: an artifact assertion alone cannot tell
            # "no artifact was registered" from "the shard threw before registering one".
            @test (r.ran, r.failed) == (2, 0)
            @test SlateTask.result(root, keys[1])[2] == "ok"
            arts = SlateTask.artifacts(root, keys[1])
            @test length(arts) == 1 && arts[1]["name"] == "out1.txt"
            ok, payload = MemoStore.with_blob(io -> read(io, String), root, arts[1]["blob"])
            @test ok && payload == "payload-1"
            # entry_bytes walks the same edge set gc does, so an artifact that gc can see is also
            # an artifact the entry is charged for.
            row = SlateTask.chunk_rows(root, chunk)[keys[1]]
            @test SlateTask.row_bytes(root, row) > arts[1]["bytes"]
        end
    end

    @testset "a shard writes its own files through datadir()/@sfile" begin
        # The case this exists for: a unit that writes an HDF5 or NetCDF file itself rather than
        # returning a value. It needs a portable place to put it, and the notebook's `datadir()` is
        # a notebook-namespace name that a bare shard module does not have — so a body written
        # against it failed with UndefVarError on every unit.
        mktempdir() do root
            src = """
            p -> begin
                write(@sfile("cubes/cube_\$(p).bin"), "vol-\$(p)")
                (; dir = datadir(), path = @sfile("cubes/cube_\$(p).bin"))
            end
            """
            chunk, keys = mkchunk(root, 2; fn_src = src,
                                  setup_src = "const SETUP_DIR = datadir()")
            r = SlateTask.run_chunk(root, chunk)
            @test (r.ran, r.failed) == (2, 0)
            vals = [SlateTask.result(root, k)[3] for k in keys]
            @test all(v -> v.dir == joinpath(root, "data"), vals)
            # `@sfile` created the intermediate directory, so the write target was usable directly.
            @test [read(v.path, String) for v in vals] == ["vol-1", "vol-2"]
            # gc walks blobs and manifests only, so a data directory beside them survives it.
            MemoStore.gc(root; cap = 0)
            @test all(v -> isfile(v.path), vals)
        end
    end

    @testset "a region's pinned data root wins over the store's" begin
        mktempdir() do root
            mktempdir() do pinned
                withenv("KAIMONSLATE_DATADIR" => pinned) do
                    chunk, keys = mkchunk(root, 1; fn_src = "p -> datadir()")
                    SlateTask.run_chunk(root, chunk)
                    @test SlateTask.result(root, keys[1])[3] == pinned
                end
            end
        end
    end

    @testset "gc does not collect a live shard's artifact blob" begin
        # The bug this guards: artifacts are blobs referenced only from a batch-specific manifest
        # field, so unless _manifest_blobs knows about them they look orphaned and gc deletes the
        # user's output while keeping the manifest that claims to have it.
        mktempdir() do root
            # Unqualified `artifact!` here, qualified in the test above: both names are injected
            # into the shard module, and both spellings need to keep working.
            src = """
            p -> begin
                f = joinpath(tempdir(), "keep\$(p).bin")
                write(f, "important-\$(p)")
                artifact!(f)
                p
            end
            """
            chunk, keys = mkchunk(root, 1; fn_src = src)
            r = SlateTask.run_chunk(root, chunk)
            @test (r.ran, r.failed) == (1, 0)
            h = SlateTask.artifacts(root, keys[1])[1]["blob"]
            MemoStore.set_pin!(root, keys[1], true)      # keep the manifest through eviction
            MemoStore.gc(root; cap = 0, grace = 0.0)     # force a full sweep, no grace
            @test MemoStore.has_blob(root, h)
            @test SlateTask.artifacts(root, keys[1])[1]["blob"] == h
        end
    end

    @testset "gc does not collect a chunk descriptor's inputs" begin
        # Same hazard for the descriptor: its closure source, captures, and per-shard arguments are
        # what make a resubmission possible, so they must stay reachable from it.
        mktempdir() do root
            chunk, _ = mkchunk(root, 3; setup_src = "g(x) = x + 1",
                               captures = Dict{String,Any}("offset" => 5))
            d = MemoStore.read_manifest(root, chunk)
            hashes = vcat(String(d["fn"]), String(d["setup"]),
                          [String(c["blob"]) for c in d["captures"]],
                          [String(s["arg"]) for s in d["shards"]])
            MemoStore.set_pin!(root, chunk, true)
            MemoStore.gc(root; cap = 0, grace = 0.0)
            @test all(h -> MemoStore.has_blob(root, h), hashes)
        end
    end

    @testset "identical params across chunks dedup to one blob" begin
        mktempdir() do root
            mkchunk(root, 3; chunk = "a")
            before = blobcount(root)
            mkchunk(root, 3; chunk = "b")           # same fn source, same params
            # Only the second descriptor's manifest is new; every blob it points at already exists.
            @test blobcount(root) == before
        end
    end

    @testset "a chunk with no descriptor is an error, not a silent no-op" begin
        mktempdir() do root
            @test_throws ErrorException SlateTask.run_chunk(root, "nosuchchunk")
        end
    end
end
