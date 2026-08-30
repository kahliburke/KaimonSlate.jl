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
