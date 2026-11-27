"""
    DataChannel

A WebRTC data channel. Messages arrive as `String` (text) or `Vector{UInt8}` (binary); take them
with `take!(dc)` or iterate `dc`. Iteration ends when the channel closes.

Sending does not block: libdatachannel buffers what the transport cannot take yet. A bulk sender
calls [`wait_writable`](@ref) before each `send` to bound that buffer.
"""
mutable struct DataChannel
    const id::Cint
    const pc::PeerConnection
    const label::String
    const messages::Channel{Union{String,Vector{UInt8}}}
    const cond::Threads.Condition
    @atomic open::Bool
    @atomic closed::Bool
    @atomic error::Union{Nothing,String}
    low_water::Int
    high_water::Int
end

const DEFAULT_LOW_WATER = 1 << 20
const DEFAULT_HIGH_WATER = 4 << 20

function DataChannel(pc::PeerConnection, id::Cint)
    label = something(rtc_string(:rtcGetDataChannelLabel, id; size = 256) do id, buf, n
        @rtc rtcGetDataChannelLabel(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
    end, "")
    dc = DataChannel(id, pc, label, Channel{Union{String,Vector{UInt8}}}(Inf), Threads.Condition(),
                     false, false, nothing, DEFAULT_LOW_WATER, DEFAULT_HIGH_WATER)
    @rtc rtcSetBufferedAmountLowThreshold(id::Cint, DEFAULT_LOW_WATER::Cint)::Cint
    # An incoming channel may already be open; its open callback was set before we got here and
    # its event is queued behind this one, but report the state right away.
    @rtc(rtcIsOpen(id::Cint)::Bool) && @atomic dc.open = true
    dc
end

Base.show(io::IO, dc::DataChannel) =
    print(io, "DataChannel(", repr(dc.label), ", ", dc.closed ? "closed" : dc.open ? "open" : "connecting", ")")

"""
    create_data_channel(pc, label; ordered = true, reliable = true, max_retransmits = 0,
                        max_packet_lifetime = 0, protocol = "", negotiated = false,
                        stream = nothing) -> DataChannel

Open a data channel to the remote peer, which receives it through `accept`. With
`reliable = false`, a message is retransmitted at most `max_retransmits` times, or for
`max_packet_lifetime` milliseconds if that is set. A `negotiated` channel is not announced: both
sides create it with the same `stream` id.
"""
function create_data_channel(pc::PeerConnection, label::AbstractString;
                             ordered::Bool = true, reliable::Bool = true,
                             max_retransmits::Integer = 0, max_packet_lifetime::Integer = 0,
                             protocol::AbstractString = "", negotiated::Bool = false,
                             stream::Union{Nothing,Integer} = nothing)
    pc.closed && throw(InvalidStateException("peer connection is closed", :closed))
    negotiated && stream === nothing && throw(ArgumentError("a negotiated channel needs a stream id"))
    proto = String(protocol)
    lbl = String(label)
    id = GC.@preserve proto begin
        init = Ref(RtcDataChannelInit(
            RtcReliability(!ordered, !reliable, max_packet_lifetime, max_retransmits),
            pointer(proto), negotiated, stream !== nothing, something(stream, 0),
        ))
        check(:rtcCreateDataChannelEx,
              @rtc rtcCreateDataChannelEx(pc.id::Cint, lbl::Cstring, init::Ptr{RtcDataChannelInit})::Cint)
    end
    dc = DataChannel(pc, Cint(id))
    register!(dc.id, dc)
    @lock pc.cond push!(pc.channels, dc)
    r = set_channel_callbacks(dc.id)
    if r < 0
        close(dc)
        throw(RTCError(:rtcSetCallback, r))
    end
    dc
end

label(dc::DataChannel) = dc.label

protocol(dc::DataChannel) = something(rtc_string(:rtcGetDataChannelProtocol, dc.id; size = 256) do id, buf, n
    @rtc rtcGetDataChannelProtocol(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
end, "")

"""
    stream_id(dc) -> Int

The SCTP stream id of the channel.
"""
stream_id(dc::DataChannel) = check(:rtcGetDataChannelStream, @rtc rtcGetDataChannelStream(dc.id::Cint)::Cint)

"""
    max_message_size(dc) -> Int

The largest message `send` accepts: the smaller of the local limit and the one the remote peer
advertised.
"""
max_message_size(dc::DataChannel) = check(:rtcMaxMessageSize, @rtc rtcMaxMessageSize(dc.id::Cint)::Cint)

Base.isopen(dc::DataChannel) = dc.open && !dc.closed

"""
    wait_open(dc; timeout = Inf) -> Bool

Wait until `dc` is open. `false` if it closed or the timeout passed first.
"""
wait_open(dc::DataChannel; timeout::Real = Inf) =
    wait_until(() -> dc.open || dc.closed, dc.cond, timeout) && isopen(dc)

function check_open(dc::DataChannel)
    dc.closed && throw(InvalidStateException("data channel is closed", :closed))
    nothing
end

"""
    send(dc, data::AbstractVector{UInt8})
    send(dc, text::AbstractString)

Send one binary or text message. Throws `RTCError` if the channel is not open or the message is
larger than [`max_message_size`](@ref).
"""
function Sockets.send(dc::DataChannel, data::Union{DenseVector{UInt8},Base.FastContiguousSubArray{UInt8,1,<:DenseVector{UInt8}}})
    check_open(dc)
    n = length(data)
    GC.@preserve data begin
        p = n == 0 ? Ptr{UInt8}(C_NULL) : pointer(data)
        check(:rtcSendMessage, @rtc rtcSendMessage(dc.id::Cint, p::Ptr{UInt8}, n::Cint)::Cint)
    end
    nothing
end

Sockets.send(dc::DataChannel, data::AbstractVector{UInt8}) = send(dc, collect(data))

function Sockets.send(dc::DataChannel, text::AbstractString)
    check_open(dc)
    check(:rtcSendMessage, @rtc rtcSendMessage(dc.id::Cint, String(text)::Cstring, (-1)::Cint)::Cint)
    nothing
end

"""
    buffered_amount(dc) -> Int

Bytes passed to `send` that the transport has not taken yet.
"""
function buffered_amount(dc::DataChannel)
    dc.closed && return 0
    max(0, @rtc rtcGetBufferedAmount(dc.id::Cint)::Cint)
end

"""
    set_watermarks!(dc; low, high)

[`wait_writable`](@ref) blocks once more than `high` bytes are buffered, until at most `low`
remain. Defaults are 1 MiB and 4 MiB.
"""
function set_watermarks!(dc::DataChannel; low::Integer = dc.low_water, high::Integer = dc.high_water)
    0 <= low <= high || throw(ArgumentError("need 0 <= low <= high"))
    @lock dc.cond begin
        dc.low_water = low
        dc.high_water = high
    end
    check(:rtcSetBufferedAmountLowThreshold, @rtc rtcSetBufferedAmountLowThreshold(dc.id::Cint, low::Cint)::Cint)
    dc
end

"""
    wait_writable(dc)

Return once `dc` can take more data: right away while at most the high watermark is buffered,
otherwise when the buffer has drained to the low watermark. Throws `InvalidStateException` if the
channel closes.
"""
function wait_writable(dc::DataChannel)
    check_open(dc)
    buffered_amount(dc) <= dc.high_water && return nothing
    # The buffered-amount-low event is queued after libdatachannel updates the amount, and is
    # notified under `dc.cond`, so testing the amount under the lock cannot miss it.
    wait_until(() -> dc.closed || buffered_amount(dc) <= dc.low_water, dc.cond, Inf)
    check_open(dc)
end

Base.take!(dc::DataChannel) = take!(dc.messages)
Base.isready(dc::DataChannel) = isready(dc.messages)
Base.iterate(dc::DataChannel, state = nothing) = iterate(dc.messages, state)
Base.IteratorSize(::Type{DataChannel}) = Base.SizeUnknown()
Base.eltype(::Type{DataChannel}) = Union{String,Vector{UInt8}}

"""
    close(dc)

Close the channel and release it. Messages already received can still be taken. No callbacks for
it run after this returns. Idempotent.
"""
function Base.close(dc::DataChannel)
    (@atomicswap dc.closed = true) && return nothing
    unregister!(dc.id)
    @rtc rtcDeleteDataChannel(dc.id::Cint)::Cint
    @lock dc.pc.cond delete!(dc.pc.channels, dc)
    finish!(dc)
end

function finish!(dc::DataChannel)
    err = dc.error
    err === nothing ? close(dc.messages) : close(dc.messages, ErrorException("data channel error: $err"))
    @lock dc.cond notify(dc.cond)
    nothing
end

handle(dc::DataChannel, ev::EvMessage) = offer!(dc.messages, ev.data)

function handle(dc::DataChannel, ev::EvOpen)
    @lock dc.cond begin
        @atomic dc.open = true
        notify(dc.cond)
    end
end

handle(dc::DataChannel, ::EvBufferedLow) = @lock dc.cond notify(dc.cond)

handle(dc::DataChannel, ev::EvError) = @atomic dc.error = ev.message

handle(dc::DataChannel, ::EvClosed) = close(dc)
