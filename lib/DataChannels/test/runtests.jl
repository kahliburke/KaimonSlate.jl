using DataChannels
using DataChannels: REGISTRY, REGISTRY_LOCK, DROPPED
using SHA
using Test

const TIMEOUT = 20.0

@info "threads" default = Threads.nthreads(:default) interactive = Threads.nthreads(:interactive)

"""Run `f` in a task; fail the test instead of hanging if it takes longer than `secs`."""
function within(f, secs = TIMEOUT)
    t = Threads.@spawn f()
    timedwait(() -> istaskdone(t), secs) === :ok || error("timed out after $(secs)s")
    fetch(t)
end

"""Forward `from`'s descriptions and candidates to `to` until `from` closes."""
function forward(from::PeerConnection, to::PeerConnection)
    Threads.@spawn for s in signals(from)
        isopen(to) || break
        try
            s isa Description ? set_remote_description!(to, s) : add_remote_candidate!(to, s)
        catch err
            isopen(to) && rethrow()
        end
    end
end

"""Two connected peers and an open channel between them, `a` the offerer."""
function connected_pair(label = "test"; kwargs...)
    a = PeerConnection(ice_servers = String[])
    b = PeerConnection(ice_servers = String[])
    forward(a, b)
    forward(b, a)
    dc = create_data_channel(a, label; kwargs...)
    rdc = within(() -> accept(b))
    @test within(() -> wait_open(dc))
    @test within(() -> wait_open(rdc))
    a, b, dc, rdc
end

registry_size() = @lock REGISTRY_LOCK length(REGISTRY)

"""Run `f` with libdatachannel's logging off, for errors the test provokes on purpose."""
function quietly(f)
    DataChannels.set_log_level(:none)
    try
        f()
    finally
        DataChannels.set_log_level(:warning)
    end
end

@testset "DataChannels" begin
    @testset "connect, messages both ways" begin
        a, b, dc, rdc = connected_pair("chat"; protocol = "chat-v1")
        @test wait_state(a, :connected; timeout = TIMEOUT) === :connected
        @test wait_state(b, :connected; timeout = TIMEOUT) === :connected
        @test label(rdc) == "chat"
        @test protocol(rdc) == "chat-v1"
        @test stream_id(dc) == stream_id(rdc)

        send(dc, "hello")
        @test within(() -> take!(rdc)) == "hello"
        send(rdc, "héllo back ✓")
        @test within(() -> take!(dc)) == "héllo back ✓"

        bytes = rand(UInt8, 1000)
        send(dc, bytes)
        got = within(() -> take!(rdc))
        @test got isa Vector{UInt8} && got == bytes
        send(rdc, view(bytes, 11:20))
        @test within(() -> take!(dc)) == bytes[11:20]
        send(dc, UInt8[])
        @test within(() -> take!(rdc)) == UInt8[]
        send(dc, "")
        @test within(() -> take!(rdc)) == ""
        @test_throws ArgumentError send(dc, "nul\0inside")

        mms = max_message_size(dc)
        @info "max message size" bytes = mms
        @test mms >= 64 * 1024
        quietly(() -> @test_throws RTCError send(dc, zeros(UInt8, mms + 1)))

        pair = selected_candidate_pair(a)
        @test pair isa CandidatePair
        @info "selected candidate pair" local_candidate = pair.local_candidate remote_candidate = pair.remote_candidate local_address(a) remote_address(a)
        @test candidate_type(pair.local_candidate) === :host
        @test candidate_type(pair.remote_candidate) === :host
        @test gathering_state(a) === :complete
        @test local_description(a).type == "offer"
        @test local_description(b).type == "answer"

        # Closing one end closes the other, and ends iteration there.
        close(dc)
        @test !isopen(dc)
        @test within(() -> collect(rdc)) == []
        @test !isopen(rdc)
        @test_throws InvalidStateException send(dc, "late")
        close(a)
        close(b)
        @test state(a) === :closed
        @test_throws InvalidStateException create_data_channel(a, "x")
    end

    @testset "unordered, unreliable and negotiated channels" begin
        a, b, dc, rdc = connected_pair("lossy"; ordered = false, reliable = false, max_retransmits = 0)
        send(dc, "datagram")
        @test within(() -> take!(rdc)) == "datagram"
        # A negotiated channel is not announced; both sides create it with the same stream id.
        na = create_data_channel(a, "pre"; negotiated = true, stream = 42)
        nb = create_data_channel(b, "pre"; negotiated = true, stream = 42)
        @test within(() -> wait_open(na)) && within(() -> wait_open(nb))
        send(nb, "negotiated")
        @test within(() -> take!(na)) == "negotiated"
        @test stream_id(na) == 42
        close(a)
        close(b)
    end

    @testset "bulk transfer with backpressure" begin
        a, b, dc, rdc = connected_pair("bulk")
        chunk = 64 * 1024
        total = 100 * 1024 * 1024
        data = rand(UInt8, total)
        expected = sha256(data)
        peak = Threads.Atomic{Int}(0)

        receiver = Threads.@spawn begin
            ctx = SHA2_256_CTX()
            n = 0
            while n < total
                m = take!(rdc)::Vector{UInt8}
                SHA.update!(ctx, m)
                n += length(m)
            end
            n, SHA.digest!(ctx)
        end
        t0 = time()
        within(120) do
            for i in 1:chunk:total
                wait_writable(dc)
                send(dc, view(data, i:min(i + chunk - 1, total)))
                Threads.atomic_max!(peak, buffered_amount(dc))
            end
        end
        n, digest = within(() -> fetch(receiver), 120)
        secs = time() - t0
        @test n == total
        @test digest == expected
        @test peak[] <= dc.high_water + chunk
        @info "bulk transfer" MB = total / 2^20 seconds = round(secs; digits = 2) MB_per_s = round(total / 2^20 / secs; digits = 1) peak_buffered = peak[]
        close(a)
        close(b)
    end

    @testset "closing with traffic in flight" begin
        a, b, dc, rdc = connected_pair("flood")
        sender = Threads.@spawn try
            while true
                wait_writable(dc)
                send(dc, rand(UInt8, 16 * 1024))
            end
        catch err
            err
        end
        within(() -> for _ in 1:50; take!(rdc); end)
        quietly() do
            close(b)                   # remote end goes away mid-stream
            @test within(() -> fetch(sender)) isa Exception
            @test wait_state(a, :closed; timeout = TIMEOUT) === :closed
        end
        @test !isopen(a)               # closed by the remote end
        @test !isopen(dc) && !isopen(rdc)
        @test collect(signals(a)) isa Vector
    end

    @testset "open and close repeatedly" begin
        before = registry_size()
        rss0 = Sys.maxrss()
        for i in 1:20
            a, b, dc, rdc = connected_pair("cycle$i")
            send(dc, "ping $i")
            @test within(() -> take!(rdc)) == "ping $i"
            send(rdc, "pong $i")
            @test within(() -> take!(dc)) == "pong $i"
            isodd(i) ? (close(a); close(b)) : (close(b); close(a))
        end
        @test registry_size() == before
        @info "20 open/close cycles" maxrss_growth_MB = round((Sys.maxrss() - rss0) / 2^20; digits = 1)
    end

    @test registry_size() == 0
    @test DROPPED[] == 0

    @testset "shutdown and reinitialize" begin
        DataChannels.shutdown()
        a, b, dc, rdc = connected_pair("again")
        send(dc, "after shutdown")
        @test within(() -> take!(rdc)) == "after shutdown"
        close(a)
        close(b)
    end
end
