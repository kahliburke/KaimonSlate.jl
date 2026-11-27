"""
    Description(type, sdp)

A session description: `type` is `"offer"`, `"answer"`, `"pranswer"` or `"rollback"`.
"""
struct Description
    type::String
    sdp::String
end

"""
    Candidate(candidate, mid)

An ICE candidate line (`"a=candidate:..."` or `"candidate:..."`) and the media id it belongs to.
"""
struct Candidate
    candidate::String
    mid::String
end

const PEER_STATES = (:new, :connecting, :connected, :disconnected, :failed, :closed)
const GATHERING_STATES = (:new, :in_progress, :complete)

"""
    PeerConnection(; ice_servers = ["stun:stun.cloudflare.com:3478"], kwargs...)

A WebRTC peer connection. Signaling is up to the caller: forward every `Description` and
`Candidate` taken from `signals(pc)` to the remote peer, and feed theirs to
[`set_remote_description!`](@ref) and [`add_remote_candidate!`](@ref).

ICE server URLs follow libdatachannel: `"stun:host:port"`, `"turn:user:password@host:port"`.

Keywords:
- `bind_address`: local address to bind ICE sockets to (default any).
- `port_range`: `(first, last)` UDP port range for ICE, `(0, 0)` for automatic.
- `ice_udp_mux`: multiplex all ICE traffic over one UDP port.
- `relay_only`: only use TURN relay candidates.
- `mtu`: path MTU in bytes (`0` for libdatachannel's default, 1280).
- `max_message_size`: largest message this side accepts (`0` for the default, 256 KiB).
- `auto_negotiation`: create the offer automatically when the first channel is added.
"""
mutable struct PeerConnection
    const id::Cint
    const signals::Channel{Union{Description,Candidate}}
    const incoming::Channel{Any}
    const cond::Threads.Condition
    const channels::Set{Any}
    @atomic state::Symbol
    @atomic gathering::Symbol
    @atomic closed::Bool
end

function PeerConnection(;
    ice_servers::AbstractVector{<:AbstractString} = ["stun:stun.cloudflare.com:3478"],
    bind_address::Union{Nothing,AbstractString} = nothing,
    port_range::Tuple{Integer,Integer} = (0, 0),
    ice_udp_mux::Bool = false,
    relay_only::Bool = false,
    mtu::Integer = 0,
    max_message_size::Integer = 0,
    auto_negotiation::Bool = true,
)
    ensure_initialized()
    servers = String.(ice_servers)
    bind = bind_address === nothing ? nothing : String(bind_address)
    ptrs = Ptr{UInt8}[pointer(s) for s in servers]
    id = GC.@preserve servers bind ptrs begin
        config = RtcConfiguration(
            isempty(ptrs) ? C_NULL : pointer(ptrs), length(ptrs),
            C_NULL, bind === nothing ? C_NULL : pointer(bind),
            0, relay_only ? 1 : 0,
            false, ice_udp_mux, !auto_negotiation, false,
            port_range[1], port_range[2], mtu, max_message_size,
        )
        ref = Ref(config)
        check(:rtcCreatePeerConnection, @rtc rtcCreatePeerConnection(ref::Ptr{RtcConfiguration})::Cint)
    end
    pc = PeerConnection(Cint(id), Channel{Union{Description,Candidate}}(Inf), Channel{Any}(Inf),
                        Threads.Condition(), Set{Any}(), :new, :new, false)
    register!(pc.id, pc)
    try
        set_peer_callbacks(pc.id)
    catch
        close(pc)
        rethrow()
    end
    pc
end

Base.show(io::IO, pc::PeerConnection) = print(io, "PeerConnection(", pc.id, ", :", pc.state, ")")

"""
    signals(pc) -> Channel{Union{Description,Candidate}}

The local description and candidates to send to the remote peer, in the order libdatachannel
produced them. Closed when `pc` is closed.
"""
signals(pc::PeerConnection) = pc.signals

"""
    accept(pc) -> DataChannel

Wait for the next data channel the remote peer opens. Throws `InvalidStateException` once `pc` is
closed.
"""
Sockets.accept(pc::PeerConnection) = take!(pc.incoming)::DataChannel

"""
    state(pc) -> Symbol

One of `:new`, `:connecting`, `:connected`, `:disconnected`, `:failed`, `:closed`.
"""
state(pc::PeerConnection) = pc.state

"""
    gathering_state(pc) -> Symbol

One of `:new`, `:in_progress`, `:complete`.
"""
gathering_state(pc::PeerConnection) = pc.gathering

function wait_until(pred, cond::Threads.Condition, timeout::Real)
    lock(cond) do
        pred() && return true
        timer = isfinite(timeout) ? Timer(_ -> @lock(cond, notify(cond)), timeout) : nothing
        try
            while !pred()
                timer === nothing || isopen(timer) || return false
                wait(cond)
            end
            true
        finally
            timer === nothing || close(timer)
        end
    end
end

"""
    wait_state(pc, states...; timeout = Inf) -> Symbol

Wait until `state(pc)` is one of `states` (or `:failed`/`:closed`) and return it. Returns the
current state if the timeout passes first.
"""
function wait_state(pc::PeerConnection, states::Symbol...; timeout::Real = Inf)
    wait_until(() -> pc.state in states || pc.state in (:failed, :closed), pc.cond, timeout)
    pc.state
end

"""
    wait_gathering(pc; timeout = Inf) -> Bool

Wait until ICE candidate gathering is complete, for signaling that sends one description with all
candidates instead of trickling them.
"""
wait_gathering(pc::PeerConnection; timeout::Real = Inf) =
    wait_until(() -> pc.gathering === :complete || pc.closed, pc.cond, timeout) && !pc.closed

"""
    set_local_description!(pc, type = "")

Create an offer or answer explicitly. Only needed with `auto_negotiation = false`; otherwise
libdatachannel does it when the first channel is created or a remote offer arrives.
"""
function set_local_description!(pc::PeerConnection, type::AbstractString = "")
    t = isempty(type) ? nothing : String(type)
    GC.@preserve t begin
        p = t === nothing ? Ptr{UInt8}(C_NULL) : pointer(t)
        check(:rtcSetLocalDescription, @rtc rtcSetLocalDescription(pc.id::Cint, p::Ptr{UInt8})::Cint)
    end
    pc
end

"""
    set_remote_description!(pc, d::Description)
    set_remote_description!(pc, sdp, type)
"""
set_remote_description!(pc::PeerConnection, d::Description) = set_remote_description!(pc, d.sdp, d.type)

function set_remote_description!(pc::PeerConnection, sdp::AbstractString, type::AbstractString)
    check(:rtcSetRemoteDescription,
          @rtc rtcSetRemoteDescription(pc.id::Cint, String(sdp)::Cstring, String(type)::Cstring)::Cint)
    pc
end

"""
    add_remote_candidate!(pc, c::Candidate)
    add_remote_candidate!(pc, candidate, mid = "")
"""
add_remote_candidate!(pc::PeerConnection, c::Candidate) = add_remote_candidate!(pc, c.candidate, c.mid)

function add_remote_candidate!(pc::PeerConnection, candidate::AbstractString, mid::AbstractString = "")
    m = isempty(mid) ? nothing : String(mid)
    c = String(candidate)
    GC.@preserve m begin
        p = m === nothing ? Ptr{UInt8}(C_NULL) : pointer(m)
        check(:rtcAddRemoteCandidate, @rtc rtcAddRemoteCandidate(pc.id::Cint, c::Cstring, p::Ptr{UInt8})::Cint)
    end
    pc
end

"""
    local_description(pc) -> Union{Description,Nothing}

The current local description, including every candidate gathered so far.
"""
function local_description(pc::PeerConnection)
    sdp = rtc_string(:rtcGetLocalDescription, pc.id; size = 4096) do id, buf, n
        @rtc rtcGetLocalDescription(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
    end
    type = rtc_string(:rtcGetLocalDescriptionType, pc.id; size = 32) do id, buf, n
        @rtc rtcGetLocalDescriptionType(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
    end
    sdp === nothing || type === nothing ? nothing : Description(type, sdp)
end

"""
    CandidatePair

The ICE candidates the connection uses, as candidate lines. [`candidate_type`](@ref) tells host,
server-reflexive and relayed candidates apart.
"""
struct CandidatePair
    local_candidate::String
    remote_candidate::String
end

"""
    selected_candidate_pair(pc) -> Union{CandidatePair,Nothing}

`nothing` until ICE has selected a pair.
"""
function selected_candidate_pair(pc::PeerConnection)
    n = 1024
    loc = Vector{UInt8}(undef, n)
    rem = Vector{UInt8}(undef, n)
    r = @rtc rtcGetSelectedCandidatePair(pc.id::Cint, loc::Ptr{UInt8}, n::Cint, rem::Ptr{UInt8}, n::Cint)::Cint
    r < 0 && return nothing
    GC.@preserve loc rem CandidatePair(unsafe_string(pointer(loc)), unsafe_string(pointer(rem)))
end

"""
    candidate_type(candidate) -> Symbol

`:host`, `:srflx`, `:prflx`, `:relay`, or `:unknown`, read from the candidate's `typ` field.
"""
function candidate_type(candidate::AbstractString)
    m = match(r"\btyp\s+(\w+)", candidate)
    m === nothing ? :unknown : Symbol(m.captures[1])
end

"""
    local_address(pc), remote_address(pc) -> Union{String,Nothing}

The addresses of the selected candidate pair, as `"ip:port"`.
"""
local_address(pc::PeerConnection) = rtc_string(:rtcGetLocalAddress, pc.id; size = 64) do id, buf, n
    @rtc rtcGetLocalAddress(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
end

remote_address(pc::PeerConnection) = rtc_string(:rtcGetRemoteAddress, pc.id; size = 64) do id, buf, n
    @rtc rtcGetRemoteAddress(id::Cint, buf::Ptr{UInt8}, n::Cint)::Cint
end

"""
    close(pc)

Close every channel of `pc` and the connection itself. No callbacks for them run after this
returns. Idempotent; also done automatically when the connection reaches `:closed` (the remote
peer closed it).
"""
function Base.close(pc::PeerConnection)
    chans = @lock pc.cond begin
        (@atomicswap pc.closed = true) && return nothing
        collect(pc.channels)
    end
    foreach(close, chans)
    unregister!(pc.id)
    @rtc rtcDeletePeerConnection(pc.id::Cint)::Cint
    close(pc.signals)
    close(pc.incoming)
    @lock pc.cond begin
        @atomic pc.state = :closed
        notify(pc.cond)
    end
    nothing
end

Base.isopen(pc::PeerConnection) = !pc.closed

function handle(pc::PeerConnection, ev::EvDescription)
    offer!(pc.signals, Description(ev.type, ev.sdp))
end

function handle(pc::PeerConnection, ev::EvCandidate)
    offer!(pc.signals, Candidate(ev.candidate, ev.mid))
end

function handle(pc::PeerConnection, ev::EvState)
    s = get(PEER_STATES, ev.state + 1, :unknown)
    # :closed is terminal; release the connection so `signals` and `accept` loops end.
    s === :closed && return close(pc)
    @lock pc.cond begin
        pc.closed || @atomic pc.state = s
        notify(pc.cond)
    end
end

function handle(pc::PeerConnection, ev::EvGathering)
    s = get(GATHERING_STATES, ev.state + 1, :unknown)
    @lock pc.cond begin
        @atomic pc.gathering = s
        notify(pc.cond)
    end
end

function handle(ev::EvDataChannel)
    pc = lookup(ev.id)
    if pc isa PeerConnection
        @lock pc.cond begin
            if !pc.closed
                dc = DataChannel(pc, ev.dc)
                register!(dc.id, dc)
                push!(pc.channels, dc)
                put!(pc.incoming, dc)
                return
            end
        end
    end
    @rtc rtcDeleteDataChannel(ev.dc::Cint)::Cint
    nothing
end
