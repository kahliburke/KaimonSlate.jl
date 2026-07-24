# Binary transport for `slateCall` / `slate_emit`: the browser↔hub binary buffer path that lets an
# extension move raw bytes both ways without base64. Covers the three seams the feature added:
#   1. the uplink frame round-trip — `encode_binary_frame` (browser encodes the same layout in JS) ↔ the
#      hub's `_decode_uplink_frame`;
#   2. `_slate_args` passing a raw `Vector{UInt8}` through WHOLE (not exploding it into a boxed Vector{Any});
#   3. the in-process kernel's `slate_emit` routing a `SlateBinary` onto the binary frame path (the twin of
#      the worker's behaviour), while any other value still takes the JSON emit path.
using ReTest
using KaimonSlate
import SlateExtensionsBase as SEB

const RE = KaimonSlate.ReportEngine
const NS = KaimonSlate.NotebookServer

@testset "slateCall / slate_emit binary transport" begin

    @testset "uplink frame round-trips encode_binary_frame ↔ _decode_uplink_frame" begin
        # A browser→server buffer frame reuses `encode_binary_frame`'s layout: channel = correlating call
        # id, meta = {i,n} index/count, payload = raw UInt8 bytes. The hub decodes it back to those parts.
        bytes = UInt8[10, 20, 30, 40]
        frame = SEB.encode_binary_frame("c7", SEB.SlateBinary(bytes; i = 0, n = 2))
        ch, i, n, payload = NS._decode_uplink_frame(frame)
        @test ch == "c7"
        @test i == 0
        @test n == 2
        @test payload == bytes
        @test payload isa Vector{UInt8}          # raw bytes, not exploded

        # A different index/count + a longer payload survives intact.
        big = rand(UInt8, 1024)
        ch2, i2, n2, p2 = NS._decode_uplink_frame(SEB.encode_binary_frame("c42", SEB.SlateBinary(big; i = 3, n = 4)))
        @test (ch2, i2, n2) == ("c42", 3, 4)
        @test p2 == big

        # A non-frame (wrong version byte) is rejected, not misread.
        @test NS._decode_uplink_frame(UInt8[0x00, 0x01, 0x02]) === nothing
    end

    @testset "_slate_args passes a raw byte buffer through whole" begin
        # Without the Vector{UInt8} method a byte vector hits the generic AbstractVector clause and explodes
        # into Vector{Any} — the exact inefficiency the binary transport exists to avoid.
        b = UInt8[1, 2, 3, 4, 5]
        out = RE._slate_args(b)
        @test out === b
        @test out isa Vector{UInt8}

        # Delivered as the reserved `__slate_buffers` arg (a Vector of byte vectors), each buffer stays a
        # compact Vector{UInt8}; only the small outer container is generic.
        args = RE._slate_args(Dict("ch" => "x", "__slate_buffers" => Vector{UInt8}[UInt8[9, 8, 7], UInt8[1]]))
        @test args.ch == "x"
        @test length(args.__slate_buffers) == 2
        @test all(x -> x isa Vector{UInt8}, args.__slate_buffers)
        @test args.__slate_buffers[1] == UInt8[9, 8, 7]
    end

    @testset "in-process slate_emit routes SlateBinary to the binary frame path" begin
        r = RE.parse_report("#%% code id=a\n1 + 1\n")
        m = RE.report_module(r)
        emit = getglobal(m, :slate_emit)

        binframes = Vector{UInt8}[]
        plainpushes = Tuple{String,Any}[]
        RE.register_bin_emit!(r.id, frame -> push!(binframes, frame))
        RE.register_emit!(r.id, (ch, v) -> push!(plainpushes, (String(ch), v)))
        try
            emit("buf", SEB.SlateBinary(UInt8[1, 2, 3]; k = 1))   # → binary frame path
            emit("txt", Dict("hello" => "world"))                  # → JSON emit path
        finally
            RE.unregister_bin_emit!(r.id)
            RE.unregister_emit!(r.id)
        end

        # The SlateBinary produced ONE binary frame (and no JSON emit); it decodes back to its bytes.
        @test length(binframes) == 1
        @test isempty(filter(p -> p[1] == "buf", plainpushes))
        _, _, _, bytes = NS._decode_uplink_frame(binframes[1])
        @test bytes == UInt8[1, 2, 3]

        # The plain value took the JSON emit path (and produced no binary frame).
        @test length(plainpushes) == 1
        @test plainpushes[1][1] == "txt"
    end

end

@testset "@onclick/@onchange handlers can stream" begin
    # `__on_fire!` must re-establish the notebook's Slate execution context inside the handler's async task,
    # so a handler that calls `slate_emit`/`afm_emit` actually pushes. The fire path runs on a server task
    # with no context and `@async` doesn't inherit task-locals, so without this the stream is a silent no-op.
    import SlateExtensionsBase as SEB2
    got = Ref{Any}(nothing)
    ctx = (; region = nothing, notebook = "", side = "", emit = (ch, v) -> (got[] = (String(ch), v)),
             regions = Symbol[], effect = (k; kw...) -> nothing, on = (c, f) -> nothing)
    tokens = Dict{Symbol,Base.RefValue{Bool}}()
    handler = _ -> SEB2.slate_emit("chan", 42)

    RE.__on_fire!(tokens, :btn, handler, nothing, ctx)                 # WITH ctx → the emit lands
    for _ in 1:200; got[] === nothing || break; sleep(0.01); end
    @test got[] == ("chan", 42)

    got[] = nothing                                                    # WITHOUT ctx → silent no-op (the old bug)
    RE.__on_fire!(tokens, :btn2, handler, nothing)
    sleep(0.3)
    @test got[] === nothing
end
