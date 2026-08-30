# Datasets — results stored ADDRESSABLY rather than whole, so a notebook can slice terabyte-scale
# output without moving it. What these check is the property the whole design rests on: a slice
# costs the bytes it names and nothing more, and the index that decides which bytes those are is
# small, exact, and computable without touching the data.

using ReTest
using KaimonSlate
# Loaded so the TABLE path is genuinely exercised: the codecs soft-detect Arrow, so without it here
# every table assertion below would quietly take the "no addressable form" branch and pass vacuously.
using Arrow, DataFrames
const RE = KaimonSlate.ReportEngine
const ST = RE.SlateTask
const MS = RE.MemoStore

@testset "dataset" begin

    @testset "an array is addressable with no index beyond its dims" begin
        # The strongest case: the `raw` layout is a fixed header plus elements in memory order, so
        # ANY sub-range is arithmetic. No chunking, no packages, no scan to find a row.
        mktempdir() do root
            v = collect(reshape(Float32(1):Float32(6000), 100, 60))
            idx, n = ST.write_dataset!(root, v)
            @test idx["kind"] == "array"
            @test idx["dims"] == [100, 60] && idx["eltype"] == "Float32"
            @test idx["rows"] == 6000 && idx["elsize"] == 4
            @test n == 64 + 6000 * 4                      # header + elements, nothing else

            # The index alone answers "where are elements 501:600?" — no I/O.
            blob, off, nb, cnt = ST.array_range(idx, 501:600)
            @test off == 64 + 500 * 4 && nb == 400 && cnt == 100
            @test blob == idx["blob"]

            # …and reading that range gives exactly those elements.
            @test ST.dataset_elements(root, idx, 501:600) == v[501:600]
            @test ST.dataset_elements(root, idx, 1:1) == [v[1]]
            @test ST.dataset_elements(root, idx, 6000:6000) == [v[6000]]
            @test_throws Exception ST.array_range(idx, 5999:6001)   # past the end is a bounds error
        end
    end

    @testset "a table chunks, and a row range touches only its chunks" begin
        # Chunking is what keeps the index small AND the reads narrow: a row range resolves to the
        # few chunks covering it, so a slice near the end of a huge dataset does not read the start.
        mktempdir() do root
            n = 1000
            tbl = (; i = collect(1:n), x = float.(1:n) ./ 10)
            # A tiny chunk target so the test exercises MANY chunks rather than one.
            idx, _ = ST.write_dataset!(root, tbl; chunk_bytes = 16 * 100)   # ~100 rows/chunk
            @test idx["kind"] == "table"
            @test idx["rows"] == n
            @test idx["columns"] == ["i", "x"]
            @test length(idx["chunks"]) > 1                     # actually chunked
            # A unit UNDER the byte target still splits, because one chunk can never be pruned:
            # every predicate would have to read all of it and so would every row range.
            small, _ = ST.write_dataset!(root, tbl)              # default 64 MB target ≫ this table
            @test length(small["chunks"]) >= ST.DATASET_MIN_CHUNKS
            @test sum(c -> Int(c["rows"]), idx["chunks"]) == n  # …and the rows all land

            # A mid-dataset range resolves to a SUBSET of chunks, not all of them.
            sel = ST.table_chunks(idx, 450:470)
            @test !isempty(sel) && length(sel) < length(idx["chunks"])
            @test sum(hi - lo + 1 for (_, _, lo, hi) in sel) == 21

            # …and the rows that come back are the ones asked for.
            r = ST.dataset_rows(root, idx, 450:470)
            @test r.i == collect(450:470)
            @test r.x ≈ float.(450:470) ./ 10

            # Column projection: ask for one column, get one column.
            r2 = ST.dataset_rows(root, idx, 1:5; select = (:x,))
            @test keys(r2) == (:x,) && r2.x ≈ float.(1:5) ./ 10
            @test_throws Exception ST.dataset_rows(root, idx, 1:5; select = (:nope,))

            # Boundary rows, where an off-by-one in the chunk walk would show.
            @test ST.dataset_rows(root, idx, 1:1).i == [1]
            @test ST.dataset_rows(root, idx, n:n).i == [n]
            @test ST.dataset_rows(root, idx, 1:n).i == collect(1:n)

            # A DataFrame is the same dataset — the author's choice of container is not a format.
            idx2, _ = ST.write_dataset!(root, DataFrame(tbl); chunk_bytes = 16 * 100)
            @test idx2["columns"] == idx["columns"] && idx2["rows"] == n
            @test ST.dataset_rows(root, idx2, 450:470).i == collect(450:470)
        end
    end

    @testset "per-chunk ranges let a predicate skip chunks unread" begin
        # The point of the statistic: a `where` on a sorted-ish column reads a handful of chunks
        # instead of all of them. A chunk with no statistic is never skipped — an absent bound is
        # not evidence of absence.
        mktempdir() do root
            n = 1000
            idx, _ = ST.write_dataset!(root, (; i = collect(1:n)); chunk_bytes = 8 * 100)
            nchunks = length(idx["chunks"])
            @test nchunks > 4
            keep = ST.prune_chunks(idx, "i", 500, 520)
            @test !isempty(keep) && length(keep) < nchunks
            # Every kept chunk really can contain a match, and none that can was dropped.
            @test all(p -> Float64(idx["chunks"][p]["stats"]["i"]["min"]) <= 520 &&
                           Float64(idx["chunks"][p]["stats"]["i"]["max"]) >= 500, keep)
            @test length(ST.prune_chunks(idx, "i", 1, n)) == nchunks     # everything overlaps
            @test isempty(ST.prune_chunks(idx, "i", n + 1, n + 100))     # nothing does
            @test length(ST.prune_chunks(idx, "absent", 1, 2)) == nchunks  # unknown ⇒ keep all
        end
    end

    @testset "column shapes the author might naturally return" begin
        # The author picks none of this: whatever the body returns decides the layout. These are the
        # three column-shaped things a sweep body actually produces.
        @test ST.dataset_kind(rand(Float64, 10)) === :array
        @test ST.dataset_kind((; a = [1, 2], b = [3.0, 4.0])) === :table
        @test ST.dataset_kind(DataFrame(; a = [1, 2])) === :table
        @test ST.dataset_kind(42) === nothing                    # a scalar has nothing to address
        @test ST.dataset_kind("text") === nothing
        @test ST.dataset_kind(Any[1, "a"]) === nothing           # not isbits ⇒ stored whole
        cols = ST._ds_columns((; a = [1, 2], b = [3.0, 4.0]))
        @test cols !== nothing && cols[1] == ["a", "b"]
        cols2 = ST._ds_columns([(; a = 1, b = 2.0), (; a = 3, b = 4.0)])
        @test cols2 !== nothing && cols2[1] == ["a", "b"] && cols2[2][1] == [1, 3]
        @test ST._ds_columns((; a = [1, 2], b = [3.0])) === nothing   # ragged is not a table
        @test ST._ds_columns((; a = 1)) === nothing                    # scalars are not columns
    end

    @testset "the notebook sees one dataset across every unit" begin
        # What the author actually touches. The units are separate jobs writing separate files; the
        # notebook asks one object for its schema and its rows and never learns that.
        mktempdir() do root
            t = RE.Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                     payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = RE.Sweep.@sweep(RE.Sweep.paramgrid(part = 1:4), t; submit = false, lazy = true) do p
                n = 250
                (; part = fill(p.part, n), i = collect(1:n), x = float.(1:n) .* p.part)
            end
            for c in RE.BatchSweep.sweep_chunks(root, r.run); ST.run_chunk(root, c); end
            RE.Sweep.refresh!(r)
            ds = r.dataset

            # Describing it reads no data — schema and totals come from the indices.
            @test ds.kind === :table
            @test RE.Sweep.nparts(ds) == 4
            @test length(ds) == 1000                       # 4 units × 250 rows, one row space
            @test ds.columns == ["part", "i", "x"]
            @test occursin("1000 rows", sprint(show, MIME"text/plain"(), ds))

            # A slice spanning a UNIT BOUNDARY: rows 249..252 straddle parts 1 and 2.
            s = ds[249:252]
            @test s.part == [1, 1, 2, 2]
            @test s.i == [249, 250, 1, 2]
            @test ds[1:1].i == [1] && ds[1000:1000].part == [4]
            @test ds[1:1000].i == repeat(collect(1:250), 4)

            # Column projection, and the single-column shorthand.
            @test keys(ds[1:3, (:i,)]) == (:i,)
            @test ds[1:3, :i] == [1, 2, 3]

            # Out of range is a bounds error, not a silent clamp.
            @test_throws Exception ds[0:3]
            @test_throws Exception ds[999:1001]

            # scan: `between` is pushed down to the chunk statistics, `where` filters what survives.
            # …and the cost of that predicate is answerable BEFORE paying it, off the same index.
            cheap = RE.Sweep.query_cost(ds; between = (:i, 10, 20))
            all_of = RE.Sweep.query_cost(ds)
            @test cheap.chunks < all_of.chunks && cheap.bytes < all_of.bytes
            @test all_of.percent ≈ 100.0 && all_of.chunks == all_of.of_chunks
            @test 0 < cheap.percent < 100

            got = RE.Sweep.scan(ds; select = (:i, :x), between = (:i, 10, 20), limit = 1000)
            @test all(10 .<= got.i .<= 20)
            @test length(got.i) == 4 * 11                  # every unit contributes i ∈ 10:20
            few = RE.Sweep.scan(ds; between = (:i, 10, 20), limit = 5)
            @test length(few.i) == 5                       # …and `limit` really stops early
            odd = RE.Sweep.scan(ds; where = row -> isodd(row.i), select = (:i,), limit = 7)
            @test all(isodd, odd.i) && length(odd.i) == 7
        end
    end

    @testset "no call can quietly ask for everything" begin
        # The point of the whole design: a slice is a look at the data, and there is no ergonomic
        # way to spell "all of it" that a terabyte would answer.
        mktempdir() do root
            t = RE.Sweep.LocalTarget(; root, project = tempdir(), chunk = 4,
                                     payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = RE.Sweep.@sweep(RE.Sweep.paramgrid(part = 1:2), t; submit = false, lazy = true) do p
                (; i = collect(1:10))
            end
            for c in RE.BatchSweep.sweep_chunks(root, r.run); ST.run_chunk(root, c); end
            ds = RE.Sweep.refresh!(r).dataset
            @test length(ds) == 20
            # The cap refuses at the CALL, before any bytes move, and says what to do instead.
            err = try; RE.Sweep.load(ds, 1:20; max_rows = 5); "" catch e; sprint(showerror, e); end
            @test occursin("slice cap", err)
            @test occursin("scan", err) && occursin("max_rows", err)
            # …and raising it deliberately is the escape hatch, with the number written down.
            @test length(RE.Sweep.load(ds, 1:20; max_rows = 100).i) == 20
            # Asking past the end is a bounds error rather than a cap message — the more specific
            # complaint wins, so "outside 1:20" is what you see.
            @test_throws Exception ds[1:21]
        end
    end

    @testset "a unit stored whole is reported, not silently dropped" begin
        # Flipping `data=` does not re-key: a value is the same either way, so finished work is
        # kept. Those units simply have no index — the dataset says how many rather than pretending
        # to be complete.
        mktempdir() do root
            t = RE.Sweep.LocalTarget(; root, project = tempdir(), chunk = 1,
                                     payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            body = "p -> (; i = collect(1:10))"
            grid = [(; part = 1), (; part = 2)]
            r = RE.Sweep.run_sweep(t, grid, body; lazy = false)
            for c in RE.BatchSweep.sweep_chunks(root, r.run); ST.run_chunk(root, c); end
            r2 = RE.Sweep.run_sweep(t, grid, body; lazy = true)
            @test r2.run == r.run                                  # same sweep, not a re-key
            ds = RE.Sweep.refresh!(r2).dataset
            @test RE.Sweep.nparts(ds) == 0 && ds.whole == 2
            @test occursin("stored whole", sprint(show, MIME"text/plain"(), ds))
        end
    end

    @testset "a store the hub cannot see is read by ranges" begin
        # Slate on a login node sees the store as a directory and a slice is an mmap. Slate on a
        # laptop sees a host name, and the SAME slice becomes a ranged read. What must hold is that
        # only the range crosses — not the file, and not the dataset.
        S = RE.Sweep
        cmd = S.range_command("/scratch/cas", "ab" * repeat("c", 62), 4096, 1024)
        @test occursin("/scratch/cas/blobs/sha256/ab/ab", cmd)
        @test occursin("skip=4096", cmd) && occursin("count=1024", cmd)
        @test occursin("skip_bytes,count_bytes", cmd)      # exact offset, sane block size
        @test occursin("tail -c +4097", cmd)               # …and a fallback where dd lacks the flags
        @test !occursin("bs=1 ", cmd)                      # never a byte-at-a-time copy

        # Everything sent to a host is a SCRIPT — ssh joins its arguments and hands the result to
        # the remote shell — so an untidy store root is several words, or a glob, unless quoted.
        @test occursin("'/scratch/cas/blobs", cmd)
        @test S.shq("/a b/c") == "'/a b/c'"
        @test S.shq("it's") == "'it'\\''s'"                # the standard escape, not a broken quote
        @test occursin("'/od d/blobs", S.range_command("/od d", "ab" * repeat("c", 62), 0, 8))

        # Which source a target implies. A SLURM target with no host runs its tools locally, so its
        # store is local too; with a host it is only reachable through it.
        mktempdir() do root
            t = S.LocalTarget(; root, project = tempdir(),
                              payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            @test S.source_of(t) isa S.LocalSource
            here = S.SlurmTarget(""; root, root_remote = "/scratch/cas", project = tempdir(),
                                 payload = "/scratch/src/slatetask.jl")
            @test S.source_of(here) isa S.LocalSource
            far = S.SlurmTarget("login1"; root = "/not/mounted/here",
                                root_remote = "/scratch/cas", project = tempdir(),
                                payload = "/scratch/src/slatetask.jl")
            @test S.source_of(far) isa S.SshSource
            @test S.source_of(far).root == "/scratch/cas"   # the path the HOST sees, not ours
        end

        # The fetch-and-cache path, driven end to end without a cluster: an empty host runs the
        # same command through `sh`, so this exercises the real byte plumbing.
        mktempdir() do root
            v = collect(Float32(1):Float32(4096))
            idx, _ = ST.write_dataset!(root, v)
            src = S.SshSource("", root)                     # "" ⇒ sh -c, i.e. this machine
            blob, off, nb, _ = ST.array_range(idx, 100:109)
            got = S.read_range(src, blob, off, nb)
            @test length(got) == nb
            @test collect(reinterpret(Float32, got)) == v[100:109]

            # …and a whole blob lands in the cache, once, under its own hash.
            withenv("XDG_CACHE_HOME" => joinpath(root, "cache")) do
                p1 = S.blob_file(src, blob, idx["bytes"])
                @test isfile(p1) && filesize(p1) == idx["bytes"]
                @test basename(p1) == blob                  # content-addressed ⇒ never stale
                t0 = time(); p2 = S.blob_file(src, blob, idx["bytes"]); el = time() - t0
                @test p2 == p1 && el < 0.5                  # second look is free
                @test isempty(filter(f -> occursin(".part.", f), readdir(dirname(p1))))
            end
        end

        # An ARTIFACT off a remote store reads the same way. It used to be looked up in the mirror,
        # where a file the cluster wrote has never existed — so `fetch` on any real remote sweep
        # failed with "it may live on the cluster only", which is where it did in fact live.
        mktempdir() do root
            payload = repeat("W", 4096)
            blob, nb = MS.put_blob(io -> write(io, payload), root)
            far = S.ArtifactRef(root, "weights.bin", blob, nb, S.SshSource("", root))
            withenv("XDG_CACHE_HOME" => joinpath(root, "cache")) do
                dest = joinpath(root, "pulled.bin")
                @test S.fetch(far, dest) == dest && read(dest, String) == payload
                @test S.bytes(far) == Vector{UInt8}(payload)
            end
            # …and the local case keeps reading the store directly, with no cache in the way.
            near = S.ArtifactRef(root, "weights.bin", blob, nb)
            @test near.src isa S.LocalSource
            @test S.bytes(near) == Vector{UInt8}(payload)
        end
    end

    @testset "the hub plans against a mirror it can see" begin
        # The deployment: notebook on a laptop, work on a cluster, no filesystem in common. The
        # planning code goes on reading a local path — the mirror — and one rsync keeps it true.
        S = RE.Sweep
        mktempdir() do dir
            far = joinpath(dir, "far"); mkpath(far)          # stands in for the cluster's scratch
            withenv("XDG_CACHE_HOME" => joinpath(dir, "cache")) do
                # An empty host means "this machine", so the whole path is exercisable without one.
                st = S.RemoteStore("", far)
                @test st.mirror != far                        # a shadow, not an alias
                @test all(isdir(joinpath(st.mirror, d)) for d in S.META_DIRS)

                # The connection is MULTIPLEXED: without this every manifest read and every slice
                # pays a fresh handshake, which is what makes a poll feel broken.
                o = S.ssh_opts("login1")
                @test "ControlMaster=auto" in o && any(startswith("ControlPath="), o)
                @test any(startswith("ControlPersist="), o)
                @test occursin("ControlMaster=auto", S.ssh_command("login1"))

                # `blobs` is deliberately not mirrored — pulling it would pull the results.
                @test !("blobs" in S.META_DIRS)
            end
        end

        # WHO WRITES a directory decides which way a deletion may travel, and getting it wrong is
        # silent. `jobs/` is the hub's: the submission index, the armed markers, the attempt counts.
        # Those counts are bumped DURING a reconcile — after that run's push — so a pull that
        # deleted would remove each one before it could ever reach the budget, and a sweep whose
        # units the scheduler kills would resubmit forever with nothing to show why. (This was the
        # live behaviour: `read_attempts` came back empty after every submit.)
        del(d, dir) = "--delete" in collect(S.sync_flags(d, dir))
        @test !del("jobs", :in)                     # hub state is never erased by a stale store copy
        @test del("jobs", :out)                     # …and disarming takes effect by deleting there
        @test del("manifests", :in) && del("status", :in)     # the store is authoritative for these
        @test !del("manifests", :out) && !del("status", :out) # …so a push must not race a finishing unit
        @test !del("blobs", :out)
        @test "--ignore-existing" in collect(S.sync_flags("blobs", :out))   # content-addressed
        @test_throws ErrorException S.sync_flags("jobs", :sideways)

        # A target with a host plans against the mirror, but its BLOBS stay on the far side, read by
        # range at the path the host uses.
        mktempdir() do root
            far = S.SlurmTarget("login1"; root, root_remote = "/scratch/cas",
                                project = tempdir(), payload = "/scratch/src/slatetask.jl")
            withenv("XDG_CACHE_HOME" => joinpath(root, "cache")) do
                @test S.plan_root(far) != "/scratch/cas"      # planning is local…
                @test S.plan_root(far) != root
                @test S.source_of(far).root == "/scratch/cas" # …reading is not
            end
            here = S.SlurmTarget(""; root, root_remote = root, project = tempdir(),
                                 payload = "x")
            @test S.plan_root(here) == root                   # no host ⇒ no mirror, no sync
            @test S.sync_in!(here) && S.sync_out!(here)
        end
    end

    @testset "a dataset outlives the scratch it was written to" begin
        # Cluster scratch is purged on a timer and is not backed up. The bytes are meant to die
        # there; the INDEX is kilobytes and must not, or a purge costs you the record of what you
        # had as well as the data.
        S = RE.Sweep
        mktempdir() do dir
            root = joinpath(dir, "store"); mkpath(root)
            withenv("XDG_DATA_HOME" => joinpath(dir, "data")) do
                t = S.LocalTarget(; root, project = tempdir(), chunk = 2,
                                  payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
                # `RE.Sweep.@sweep`, not `S.@sweep`: a macro is resolved when the expression is
                # lowered, so its module has to be a real path and not a local binding.
                r = RE.Sweep.@sweep(RE.Sweep.paramgrid(part = 1:2), t;
                                    submit = false, lazy = true) do p
                    collect(Float32(1):Float32(64))
                end
                for c in RE.BatchSweep.sweep_chunks(root, r.run); ST.run_chunk(root, c); end
                ds = S.refresh!(r).dataset
                @test S.nparts(ds) == 2 && !ds.purged

                # Building it remembered the index somewhere durable.
                keep = S.recall_index(r.run)
                @test keep !== nothing
                @test length(get(keep, "parts", [])) == 2

                # Now the store is purged — all of it, as a policy timer would take it.
                rm(root; recursive = true, force = true); mkpath(root)
                # Reopening the notebook re-runs the cell, which rewrites the descriptors; the
                # sweep is then simply un-run, and its results are the thing that cannot come back.
                r2 = RE.Sweep.@sweep(RE.Sweep.paramgrid(part = 1:2), t;
                                     submit = false, lazy = true) do p
                    collect(Float32(1):Float32(64))
                end
                @test r2.run == r.run && r2.done == 0
                gone = r2.dataset
                @test gone.purged
                @test S.nparts(gone) == 2                      # …but it still knows what it held
                @test length(gone) == 128
                out = sprint(show, MIME"text/plain"(), gone)
                @test occursin("purged", out) && occursin("re-run", lowercase(out))

                # Asking for a part is free — it is a handle, and the index is still here.
                @test gone[1] isa S.DatasetPart
                # READING one says what happened, rather than surfacing a SystemError on a path.
                err = try; gone[1][1:10]; "" catch e; sprint(showerror, e); end
                @test occursin("purged", err) && occursin("re-run", err)
            end
        end
    end

    @testset "a cluster reports what is going on with it" begin
        # A cluster is defined once and referenced from any number of cells, so "what is it doing"
        # is a question about the CLUSTER. Everything here is derived from the store and the
        # scheduler, so it reports what is true rather than what a cell last wrote down.
        mktempdir() do root
            RE.Sweep.reset_transfers!()
            spec = Dict("name" => "here", "kind" => "local", "root" => root,
                        "project" => tempdir(), "chunk" => "2",
                        "payload" => joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            clusters = Dict("here" => spec)

            # An empty store is a legitimate answer, not an error.
            s0 = RE.Sweep.cluster_status("here"; clusters)
            @test s0.name == "here" && s0.root == root
            @test isempty(s0.sweeps) && s0.store.bytes == 0
            @test occursin("no sweeps in this store yet", sprint(show, MIME"text/plain"(), s0))

            t = RE.Sweep.LocalTarget(; root, project = tempdir(), chunk = 2,
                                     payload = joinpath(@__DIR__, "..", "src", "slatetask.jl"))
            r = RE.Sweep.@sweep(RE.Sweep.paramgrid(part = 1:4), t; submit = false, lazy = true) do p
                (; i = collect(1:100), x = float.(1:100) .* p.part)
            end
            for c in RE.BatchSweep.sweep_chunks(root, r.run); ST.run_chunk(root, c); end
            RE.Sweep.refresh!(r)

            s = RE.Sweep.cluster_status("here"; clusters)
            @test length(s.sweeps) == 1
            row = s.sweeps[1]
            @test row.sweep == r.run && row.done == 4 && row.total == 4
            @test row.stored > 0                          # output IS sitting in the store…
            @test row.read == 0                           # …and none of it has been pulled
            @test s.store.bytes >= row.stored
            @test isempty(s.err)

            # Read a slice; the cluster's accounting moves, and only by what the slice cost.
            n = length(r.dataset[1:50, (:i,)].i)
            @test n == 50
            s2 = RE.Sweep.cluster_status("here"; clusters)
            @test s2.xfer.bytes > 0
            @test s2.xfer.bytes < row.stored               # a slice, not the dataset
            @test s2.sweeps[1].read == s2.xfer.bytes       # attributed to the sweep that served it
            # The same reads are grouped per sweep AND per store; the per-store view must not
            # report the bytes with a read count of zero.
            @test s2.xfer.reads > 0
            @test RE.Sweep.transfers().bytes == s2.xfer.bytes   # …and counted once, not twice

            # The store's size is measured where the DATA is. For a cluster that is not the mirror,
            # which holds the descriptors this hub pushed and none of the output — so measuring it
            # reported kilobytes directly above per-sweep rows totalling tens of megabytes, a panel
            # contradicting itself. An empty host runs the same command through `sh`.
            far = RE.Sweep.store_size(RE.Sweep.SshSource("", root))
            @test far.bytes >= row.stored && far.blobs > 0
            @test far.blobs == RE.Sweep.store_size(root).blobs
            @test RE.Sweep.store_size(RE.Sweep.SshSource("", joinpath(root, "nope"))).bytes == 0

            # The panel names the STORE and labels the mirror. Printing a local cache path against
            # a size measured on the cluster invited the wrong reading of both.
            far = RE.Sweep.ClusterStatus(
                "hpc", Dict("kind" => "slurm", "host" => "login1", "root_remote" => "/scratch/cas"),
                "/home/me/.cache/mirror", s.sweeps, s.live, s.store, s.xfer, "")
            txt = sprint(show, MIME"text/plain"(), far)
            @test occursin("store   login1:/scratch/cas", txt)
            @test occursin("mirror  /home/me/.cache/mirror", txt)
            # …and a local cluster has no mirror to distinguish, so it says nothing about one.
            @test !occursin("mirror", sprint(show, MIME"text/plain"(), s))

            # Blobs nothing references any more are the reclaimable half of a quota, so the gap
            # between what the sweeps claim and what the store weighs is named when it is real —
            # and not when dedup or block-rounding accounts for it.
            big = RE.Sweep.ClusterStatus("hpc", s.spec, root, s.sweeps, s.live,
                                         (; bytes = 10 * row.stored, blobs = 99), s.xfer, "")
            @test occursin("unreferenced", sprint(show, MIME"text/plain"(), big))
            tight = RE.Sweep.ClusterStatus("hpc", s.spec, root, s.sweeps, s.live,
                                           (; bytes = row.stored, blobs = 4), s.xfer, "")
            @test !occursin("unreferenced", sprint(show, MIME"text/plain"(), tight))

            # Naming a cluster the notebook does not define says which ones it does.
            e = try; RE.Sweep.cluster_status("nope"; clusters); "" catch x; sprint(showerror, x); end
            @test occursin("no cluster `nope`", e) && occursin("here", e)
        end
    end

    @testset "a lazy sweep stores an index, not a result blob" begin
        # End to end through the runner: the manifest carries the dataset index and NO binding, so
        # reading the manifest tells the notebook the shape without reading a byte of the data.
        mktempdir() do root
            key = "k1"
            ST.write_chunk!(root, "c1"; fn_src = "p -> collect(Float32(1):Float32(p.n))",
                            params = [(; n = 500)], keys = [key], lazy = true)
            ST.run_chunk(root, "c1")
            m = MS.read_manifest(root, key)
            @test String(get(m, "status", "")) == "ok"
            @test haskey(m, "dataset")
            @test isempty(get(m, "bindings", Any[]))     # nothing stored whole
            idx = m["dataset"]
            @test idx["kind"] == "array" && idx["rows"] == 500
            @test ST.dataset_elements(root, idx, 10:12) == Float32[10, 11, 12]

            # …and without the attribute the ordinary whole-value path is unchanged.
            ST.write_chunk!(root, "c2"; fn_src = "p -> collect(Float32(1):Float32(p.n))",
                            params = [(; n = 500)], keys = ["k2"])
            ST.run_chunk(root, "c2")
            m2 = MS.read_manifest(root, "k2")
            @test !haskey(m2, "dataset")
            @test length(get(m2, "bindings", Any[])) == 1
        end
    end
end
