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

    # ── PUT side: what happens when a transfer dies mid-blob and the sender tries again ──────────
    # The wire carries (hash, flags, payload) and nothing else, so a receiver cannot tell a
    # CONTINUATION from a RESTART on its own. The 0x02 first-chunk flag is what tells it.
    _req(port) = (s = ZMQ.Socket(ZMQ.REQ); s.rcvtimeo = 5000; s.linger = 0;
                  ZMQ.connect(s, "tcp://127.0.0.1:$port"); s)
    _ask(s, frame) = (ZMQ.send(s, frame); String(copy(ZMQ.recv(s))))
    _put(s, h, flags, chunk) =
        _ask(s, vcat(UInt8['P'], Vector{UInt8}(codeunits(h)), UInt8[flags], chunk))
    _thirds(d) = (n = length(d) ÷ 3; (d[1:n], d[n+1:2n], d[2n+1:end]))

    @testset "a restarted put discards the abandoned partial" begin
        mktempdir() do a
            mktempdir() do b
                data = rand(UInt8, 90_000)
                h, _ = MemoStore.put_blob(io -> write(io, data), a)
                port, stop = serve(b)
                s = _req(port)
                try
                    @test occursin("restart", _ask(s, UInt8['C']))   # capability is advertised
                    c1, c2, c3 = _thirds(data)
                    @test _put(s, h, 0x02, c1) == "ok"               # attempt one, then it dies
                    @test _put(s, h, 0x02, c1) == "ok"               # attempt two starts over
                    @test _put(s, h, 0x00, c2) == "ok"
                    @test _put(s, h, 0x01, c3) == "done"
                    @test MemoStore.has_blob(b, h)
                    _, back = MemoStore.with_blob(io -> read(io), b, h)
                    @test back == data                               # not the abandoned bytes + these
                finally
                    ZMQ.close(s); stop()
                end
            end
        end
    end

    @testset "without the flag, a retry appends to the wreckage and never verifies" begin
        # This is the behaviour the flag exists to prevent, and it is also what an OLD sender still
        # gets — hence the capability probe rather than a silent change of meaning for 0x00.
        mktempdir() do a
            mktempdir() do b
                data = rand(UInt8, 90_000)
                h, _ = MemoStore.put_blob(io -> write(io, data), a)
                port, stop = serve(b)
                s = _req(port)
                try
                    c1, c2, c3 = _thirds(data)
                    @test _put(s, h, 0x00, c1) == "ok"
                    @test _put(s, h, 0x00, c1) == "ok"               # restart, unmarked → appended
                    @test _put(s, h, 0x00, c2) == "ok"
                    @test startswith(_put(s, h, 0x01, c3), "err")     # sha over c1+c1+c2+c3
                    @test !MemoStore.has_blob(b, h)                   # and nothing corrupt landed
                    # The failed attempt drops its tmp, so a clean retry now succeeds.
                    @test _put(s, h, 0x00, c1) == "ok"
                    @test _put(s, h, 0x00, c2) == "ok"
                    @test _put(s, h, 0x01, c3) == "done"
                    @test MemoStore.has_blob(b, h)
                finally
                    ZMQ.close(s); stop()
                end
            end
        end
    end

    @testset "a put of a blob already in the CAS costs nothing" begin
        mktempdir() do b
            data = rand(UInt8, 40_000)
            h, _ = MemoStore.put_blob(io -> write(io, data), b)       # already present
            port, stop = serve(b)
            s = _req(port)
            try
                @test _put(s, h, 0x03, UInt8[]) == "done"             # answered without a tmp
                _, back = MemoStore.with_blob(io -> read(io), b, h)
                @test back == data                                    # untouched by the empty put
            finally
                ZMQ.close(s); stop()
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
