# Unit tests for the blob DATA CHANNEL transport (src/blobchannel.jl) — the REP server and the
# direct-pull REQ client that move content-addressed blobs between processes. Drives REAL ZMQ
# sockets over loopback against fresh mktempdirs. Covers the transport: ranged multi-chunk pull,
# dedup, content/sha verification, and the error paths. (The CURVE allow-list GATE that guards a
# real cross-worker pull is exercised end-to-end by KaimonGate's own test_curve.jl and verified live
# against these functions; it needs KaimonGate, deliberately kept out of Slate's test deps.)
using ReTest
import ZMQ
using Sockets
include(joinpath(@__DIR__, "..", "src", "memostore.jl"))
include(joinpath(@__DIR__, "..", "src", "blobchannel.jl"))

freeport() = (s = Sockets.listen(Sockets.IPv4(0), 0); p = Int(Sockets.getsockname(s)[2]); close(s); p)

# Stand up a plaintext blob server over `root` on a loopback port; returns (port, stop). Waits for the
# bind (via on_ready) so a pull can't race it.
function serve(root)
    port = freeport(); ready = Ref(false); running = Ref(true)
    Threads.@spawn blob_server!(ZMQ, "127.0.0.1", port, root; running = running,
                                on_ready = () -> (ready[] = true))
    t0 = time(); while !ready[] && time() - t0 < 5; sleep(0.01); end
    sleep(0.05)
    return port, () -> (running[] = false)
end

@testset "blobchannel" begin

    @testset "ranged multi-chunk pull round-trips + content-verifies" begin
        mktempdir() do a
            mktempdir() do b
                data = rand(UInt8, 300_000)
                h, n = MemoStore.put_blob(io -> write(io, data), a)
                port, stop = serve(a)
                try
                    moved = pull_blob_into!(ZMQ, "127.0.0.1", port, b, h; chunk = 65_536)   # ~5 chunks
                    @test moved == n == 300_000
                    @test MemoStore.has_blob(b, h)
                    _, back = MemoStore.with_blob(io -> read(io), b, h)
                    @test back == data                                                      # sha-addressed, exact
                finally
                    stop()
                end
            end
        end
    end

    @testset "single-request (whole blob) pull also verifies" begin
        mktempdir() do a
            mktempdir() do b
                data = rand(UInt8, 4_000)
                h, _ = MemoStore.put_blob(io -> write(io, data), a)
                port, stop = serve(a)
                try
                    @test pull_blob_into!(ZMQ, "127.0.0.1", port, b, h) == 4_000            # default 8 MiB chunk
                    _, back = MemoStore.with_blob(io -> read(io), b, h)
                    @test back == data
                finally
                    stop()
                end
            end
        end
    end

    @testset "dedup: a blob already in the destination moves nothing" begin
        mktempdir() do a
            mktempdir() do b
                h, _ = MemoStore.put_blob(io -> write(io, rand(UInt8, 10_000)), a)
                port, stop = serve(a)
                try
                    @test pull_blob_into!(ZMQ, "127.0.0.1", port, b, h) > 0
                    @test pull_blob_into!(ZMQ, "127.0.0.1", port, b, h) == 0                # already present
                finally
                    stop()
                end
            end
        end
    end

    @testset "a missing blob errors and never lands a partial" begin
        mktempdir() do a
            mktempdir() do b
                port, stop = serve(a)
                try
                    @test_throws Exception pull_blob_into!(ZMQ, "127.0.0.1", port, b, "ff"^32; timeout_ms = 2000)
                    @test !MemoStore.has_blob(b, "ff"^32)
                finally
                    stop()
                end
            end
        end
    end
end
