# Unit tests for the pure content-addressed memo store (src/memostore.jl) — blobs, manifests,
# dedup, fmt gating, and gc (refcounted blobs, LRU manifest roots, grace window, legacy sweep).
# Everything runs against a fresh mktempdir; grace/cap are injected, so no mtime manipulation.
using ReTest
import Serialization
include(joinpath(@__DIR__, "..", "src", "memostore.jl"))
include(joinpath(@__DIR__, "..", "src", "memocodecs.jl"))

# A manifest shaped the way the worker writes it (bindings + wire referencing stored blobs).
mkmanifest(binds::Vector{<:Pair}, wire_h::String) = Dict{String,Any}(
    "created" => 0, "julia" => string(VERSION),
    "bindings" => [Dict{String,Any}("name" => n, "codec" => "jls", "blob" => h, "bytes" => 1)
                   for (n, h) in binds],
    "wire" => Dict{String,Any}("codec" => "jls", "blob" => wire_h, "bytes" => 1))

blobcount(root) = sum(length(fs) for (_, _, fs) in walkdir(joinpath(root, "blobs")); init = 0)

@testset "memostore" begin
    @testset "blobs: content addressing, dedup, round-trip" begin
        mktempdir() do root
            h, n = MemoStore.put_blob(io -> write(io, "hello"), root)
            @test h == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            @test n == 5
            @test MemoStore.has_blob(root, h)
            ok, s = MemoStore.with_blob(io -> read(io, String), root, h)
            @test ok && s == "hello"
            h2, _ = MemoStore.put_blob(io -> write(io, "hello"), root)   # same content
            @test h2 == h
            @test blobcount(root) == 1                                   # dedup'd + no tmp litter
            ok2, v2 = MemoStore.with_blob(io -> read(io, String), root, "ff"^32)
            @test !ok2 && v2 === nothing
            @test !MemoStore.has_blob(root, "not-a-hash")                # rejected, not an error
        end
    end

    @testset "blobs: writer failure cleans up, store untouched" begin
        mktempdir() do root
            @test_throws ErrorException MemoStore.put_blob(io -> error("unserializable"), root)
            @test blobcount(root) == 0
        end
    end

    @testset "blobs: a stored `nothing` is distinguishable from a miss" begin
        mktempdir() do root
            h, _ = MemoStore.put_blob(io -> Serialization.serialize(io, nothing), root)
            ok, v = MemoStore.with_blob(io -> Serialization.deserialize(io), root, h)
            @test ok && v === nothing
        end
    end

    @testset "manifests: round-trip, fmt gate, key hygiene" begin
        mktempdir() do root
            hA, _ = MemoStore.put_blob(io -> Serialization.serialize(io, [1, 2, 3]), root)
            MemoStore.write_manifest(root, "abc123", mkmanifest(["x" => hA], hA))
            d = MemoStore.read_manifest(root, "abc123")
            @test d !== nothing && d["fmt"] == MemoStore.FMT
            @test d["bindings"][1]["name"] == "x" && d["bindings"][1]["blob"] == hA
            @test d["wire"]["blob"] == hA
            @test MemoStore.read_manifest(root, "missing0") === nothing
            # wrong fmt (an old/foreign manifest) reads as a miss, not an error
            write(MemoStore.manifest_path(root, "oldfmt00"), "fmt = 2\n")
            @test MemoStore.read_manifest(root, "oldfmt00") === nothing
            @test_throws ArgumentError MemoStore.write_manifest(root, "../evil", mkmanifest(Pair{String,String}[], hA))
            @test_throws ArgumentError MemoStore.read_manifest(root, "a/b")
            MemoStore.touch_manifest(root, "abc123")                     # no-throw; still readable
            @test MemoStore.read_manifest(root, "abc123") !== nothing
        end
    end

    @testset "worker-shaped round-trip through Serialization" begin
        mktempdir() do root
            val = Dict("df" => rand(10), "n" => 42)
            h, _ = MemoStore.put_blob(io -> Serialization.serialize(io, val), root)
            ok, back = MemoStore.with_blob(io -> Serialization.deserialize(io), root, h)
            @test ok && back == val
        end
    end

    @testset "gc: legacy flat files swept even under cap" begin
        mktempdir() do root
            write(joinpath(root, "deadbeef01"), "fmt2 relic")
            hA, _ = MemoStore.put_blob(io -> write(io, "keep"), root)
            MemoStore.write_manifest(root, "live0001", mkmanifest(["x" => hA], hA))
            MemoStore.gc(root; cap = typemax(Int))
            @test !isfile(joinpath(root, "deadbeef01"))
            @test MemoStore.read_manifest(root, "live0001") !== nothing && MemoStore.has_blob(root, hA)
        end
    end

    @testset "gc: LRU eviction, shared blobs survive, exclusive blobs go" begin
        mktempdir() do root
            hA, _ = MemoStore.put_blob(io -> write(io, "A"^64), root)    # shared m1+m2
            hB, _ = MemoStore.put_blob(io -> write(io, "B"^64), root)    # exclusive to m1
            hC, _ = MemoStore.put_blob(io -> write(io, "C"^64), root)    # exclusive to m2
            MemoStore.write_manifest(root, "m1", mkmanifest(["a" => hA, "b" => hB], hA))
            sleep(0.05)                                                  # m2 strictly newer (LRU order)
            MemoStore.write_manifest(root, "m2", mkmanifest(["a" => hA, "c" => hC], hA))
            st = MemoStore.stats(root)
            MemoStore.gc(root; cap = st.bytes - 1, grace = -1.0)         # force ≥1 eviction; grace off
            @test MemoStore.read_manifest(root, "m1") === nothing        # oldest root evicted
            @test MemoStore.read_manifest(root, "m2") !== nothing
            @test !MemoStore.has_blob(root, hB)                          # only m1 referenced it
            @test MemoStore.has_blob(root, hA) && MemoStore.has_blob(root, hC)   # still referenced
        end
    end

    @testset "gc: grace window protects fresh unreferenced blobs" begin
        mktempdir() do root
            hO, _ = MemoStore.put_blob(io -> write(io, "orphan"), root)  # no manifest yet (mid-store)
            MemoStore.gc(root; cap = 0, grace = 1e6)                     # young → survives
            @test MemoStore.has_blob(root, hO)
            MemoStore.gc(root; cap = 0, grace = -1.0)                    # grace off → swept
            @test !MemoStore.has_blob(root, hO)
        end
    end

    @testset "stats counts both layers" begin
        mktempdir() do root
            @test MemoStore.stats(root) == (manifests = 0, blobs = 0, bytes = 0)
            hA, _ = MemoStore.put_blob(io -> write(io, "12345678"), root)
            MemoStore.write_manifest(root, "s1", mkmanifest(["x" => hA], hA))
            st = MemoStore.stats(root)
            @test st.manifests == 1 && st.blobs == 1 && st.bytes > 8
        end
    end

    @testset "pack / unpack: a scoped subset round-trips, dedups, resists escape" begin
        mktempdir() do src
            hs, _ = MemoStore.put_blob(io -> write(io, "shared-blob"), src)   # referenced by BOTH entries
            hA, _ = MemoStore.put_blob(io -> write(io, "AAAA"), src)
            hB, _ = MemoStore.put_blob(io -> write(io, "BBBBBBBB"), src)
            wh, _ = MemoStore.put_blob(io -> write(io, "wire"), src)
            MemoStore.write_manifest(src, "keyA", mkmanifest(["a" => hA, "s" => hs], wh))
            MemoStore.write_manifest(src, "keyB", mkmanifest(["b" => hB, "s" => hs], wh))
            @test MemoStore.entry_bytes(src, "keyA") > 0
            @test MemoStore.entry_bytes(src, "nope") == 0

            # Pack ONLY keyA → its manifest + hA + hs + wire; keyB and hB excluded (scoping).
            packed = MemoStore.pack(src, ["keyA"])
            @test !isempty(packed)
            mktempdir() do dst
                @test MemoStore.unpack(dst, packed) >= 3
                @test MemoStore.read_manifest(dst, "keyA") !== nothing
                @test MemoStore.read_manifest(dst, "keyB") === nothing          # not selected → absent
                @test MemoStore.has_blob(dst, hA) && MemoStore.has_blob(dst, hs) && MemoStore.has_blob(dst, wh)
                @test !MemoStore.has_blob(dst, hB)
                blobs_before = blobcount(dst)
                MemoStore.unpack(dst, packed)                                    # idempotent: blobs already present
                @test blobcount(dst) == blobs_before
            end

            # Pack BOTH → the shared blob travels once (dedup), both entries restore.
            packed2 = MemoStore.pack(src, ["keyA", "keyB"])
            mktempdir() do dst2
                MemoStore.unpack(dst2, packed2)
                @test MemoStore.has_blob(dst2, hA) && MemoStore.has_blob(dst2, hB) && MemoStore.has_blob(dst2, hs)
            end

            # A hand-forged entry escaping the store (path traversal / unknown subtree) is ignored.
            io = IOBuffer()
            for rel in ("../escape.txt", "secrets/x")
                rb = Vector{UInt8}(rel); db = Vector{UInt8}("x")
                write(io, hton(UInt32(length(rb))), rb, hton(UInt64(length(db))), db)
            end
            mktempdir() do dst3
                MemoStore.unpack(dst3, take!(io))
                @test !ispath(joinpath(dirname(dst3), "escape.txt"))
                @test !ispath(joinpath(dst3, "secrets"))
            end
        end
    end

    @testset "codecs: pick, raw round-trip, zero-copy mmap enforces immutability" begin
        mktempdir() do root
            @test _codec_pick([1.0, 2.0]) == "raw"
            @test _codec_pick(Dict("a" => 1)) == "jls"        # not an isbits Array → fallback
            @test _codec_pick(String[]) == "jls"              # empty / non-isbits stay jls
            a = reshape(collect(1.0:24.0), 2, 3, 4)
            h, n = MemoStore.put_blob(io -> _codec_encode(io, "raw", a), root)
            @test n == 64 + sizeof(a)                         # padded header + pure bytes
            p = MemoStore.blob_path(root, h)
            @test _codec_decode("raw", p, false) == a          # materialized copy
            z = _codec_decode("raw", p, true)                  # zero-copy mmap
            @test z == a && size(z) == size(a)
            @test_throws ReadOnlyMemoryError (z[1] = 99.0)     # the safety property itself
            # jls path through the same dispatch
            hj, _ = MemoStore.put_blob(io -> _codec_encode(io, "jls", Dict("k" => [1, 2])), root)
            @test _codec_decode("jls", MemoStore.blob_path(root, hj), false) == Dict("k" => [1, 2])
        end
    end
end
