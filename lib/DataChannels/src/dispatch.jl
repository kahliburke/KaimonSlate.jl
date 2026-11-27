# Callbacks from libdatachannel's threads, and the task that hands their events to Julia objects.
#
# libdatachannel calls back on its own threads (Julia adopts them on first entry). A callback here
# only copies its arguments into an event, appends it to `QUEUE` under a spin lock, and wakes the
# dispatcher with `uv_async_send`, which is safe from any thread and never blocks. It never takes a
# task-level lock, never waits, never runs user code and never throws. The dispatcher task drains
# the queue in order and routes each event, by the libdatachannel id it carries, to the
# PeerConnection or DataChannel registered under that id.

abstract type Event end

struct EvDescription <: Event
    id::Cint
    sdp::String
    type::String
end
struct EvCandidate <: Event
    id::Cint
    candidate::String
    mid::String
end
struct EvState <: Event
    id::Cint
    state::Cint
end
struct EvGathering <: Event
    id::Cint
    state::Cint
end
struct EvDataChannel <: Event
    id::Cint     # peer connection
    dc::Cint
end
struct EvOpen <: Event
    id::Cint
end
struct EvClosed <: Event
    id::Cint
end
struct EvError <: Event
    id::Cint
    message::String
end
struct EvMessage <: Event
    id::Cint
    data::Union{String,Vector{UInt8}}
end
struct EvBufferedLow <: Event
    id::Cint
end
struct EvLog <: Event
    level::Cint
    message::String
end

const QUEUE_LOCK = Threads.SpinLock()
const QUEUE = Event[]
const WAKE = Ref{Union{Nothing,Base.AsyncCondition}}(nothing)
const DROPPED = Threads.Atomic{Int}(0)   # events lost to an exception inside a callback

function enqueue(ev::Event)
    lock(QUEUE_LOCK)
    try
        push!(QUEUE, ev)
    finally
        unlock(QUEUE_LOCK)
    end
    wake = WAKE[]
    wake === nothing || ccall(:uv_async_send, Cint, (Ptr{Cvoid},), wake.handle)
    nothing
end

cstr(p::Cstring) = p == C_NULL ? "" : unsafe_string(p)

macro callback(body)
    quote
        try
            $(esc(body))
        catch
            Threads.atomic_add!(DROPPED, 1)
        end
        nothing
    end
end

cb_description(pc::Cint, sdp::Cstring, type::Cstring, ::Ptr{Cvoid}) =
    @callback enqueue(EvDescription(pc, cstr(sdp), cstr(type)))
cb_candidate(pc::Cint, cand::Cstring, mid::Cstring, ::Ptr{Cvoid}) =
    @callback enqueue(EvCandidate(pc, cstr(cand), cstr(mid)))
cb_state(pc::Cint, state::Cint, ::Ptr{Cvoid}) = @callback enqueue(EvState(pc, state))
cb_gathering(pc::Cint, state::Cint, ::Ptr{Cvoid}) = @callback enqueue(EvGathering(pc, state))
cb_open(id::Cint, ::Ptr{Cvoid}) = @callback enqueue(EvOpen(id))
cb_closed(id::Cint, ::Ptr{Cvoid}) = @callback enqueue(EvClosed(id))
cb_error(id::Cint, msg::Cstring, ::Ptr{Cvoid}) = @callback enqueue(EvError(id, cstr(msg)))
cb_buffered_low(id::Cint, ::Ptr{Cvoid}) = @callback enqueue(EvBufferedLow(id))
cb_log(level::Cint, msg::Cstring) = @callback enqueue(EvLog(level, cstr(msg)))

function cb_message(id::Cint, msg::Ptr{UInt8}, size::Cint, ::Ptr{Cvoid})
    @callback begin
        data = if size < 0
            unsafe_string(msg)
        else
            v = Vector{UInt8}(undef, size)
            size > 0 && unsafe_copyto!(pointer(v), msg, size)
            v
        end
        enqueue(EvMessage(id, data))
    end
end

function cb_datachannel(pc::Cint, dc::Cint, ::Ptr{Cvoid})
    # Queue the channel before its own callbacks are set, so the dispatcher registers it before
    # any of its events arrive.
    @callback begin
        enqueue(EvDataChannel(pc, dc))
        set_channel_callbacks(dc)
    end
end

struct Callbacks
    description::Ptr{Cvoid}
    candidate::Ptr{Cvoid}
    state::Ptr{Cvoid}
    gathering::Ptr{Cvoid}
    datachannel::Ptr{Cvoid}
    open::Ptr{Cvoid}
    closed::Ptr{Cvoid}
    error::Ptr{Cvoid}
    message::Ptr{Cvoid}
    buffered_low::Ptr{Cvoid}
    log::Ptr{Cvoid}
end

# Filled in by __init__; @cfunction pointers do not survive precompilation.
const CB = Ref{Callbacks}()

function make_callbacks()
    Callbacks(
        @cfunction(cb_description, Cvoid, (Cint, Cstring, Cstring, Ptr{Cvoid})),
        @cfunction(cb_candidate, Cvoid, (Cint, Cstring, Cstring, Ptr{Cvoid})),
        @cfunction(cb_state, Cvoid, (Cint, Cint, Ptr{Cvoid})),
        @cfunction(cb_gathering, Cvoid, (Cint, Cint, Ptr{Cvoid})),
        @cfunction(cb_datachannel, Cvoid, (Cint, Cint, Ptr{Cvoid})),
        @cfunction(cb_open, Cvoid, (Cint, Ptr{Cvoid})),
        @cfunction(cb_closed, Cvoid, (Cint, Ptr{Cvoid})),
        @cfunction(cb_error, Cvoid, (Cint, Cstring, Ptr{Cvoid})),
        @cfunction(cb_message, Cvoid, (Cint, Ptr{UInt8}, Cint, Ptr{Cvoid})),
        @cfunction(cb_buffered_low, Cvoid, (Cint, Ptr{Cvoid})),
        @cfunction(cb_log, Cvoid, (Cint, Cstring)),
    )
end

function set_peer_callbacks(pc::Cint)
    cb = CB[]
    check(:rtcSetLocalDescriptionCallback, @rtc rtcSetLocalDescriptionCallback(pc::Cint, cb.description::Ptr{Cvoid})::Cint)
    check(:rtcSetLocalCandidateCallback, @rtc rtcSetLocalCandidateCallback(pc::Cint, cb.candidate::Ptr{Cvoid})::Cint)
    check(:rtcSetStateChangeCallback, @rtc rtcSetStateChangeCallback(pc::Cint, cb.state::Ptr{Cvoid})::Cint)
    check(:rtcSetGatheringStateChangeCallback, @rtc rtcSetGatheringStateChangeCallback(pc::Cint, cb.gathering::Ptr{Cvoid})::Cint)
    check(:rtcSetDataChannelCallback, @rtc rtcSetDataChannelCallback(pc::Cint, cb.datachannel::Ptr{Cvoid})::Cint)
    nothing
end

# Called from cb_datachannel on a libdatachannel thread as well, so it must not throw.
function set_channel_callbacks(dc::Cint)
    cb = CB[]
    r = 0
    r |= @rtc rtcSetOpenCallback(dc::Cint, cb.open::Ptr{Cvoid})::Cint
    r |= @rtc rtcSetClosedCallback(dc::Cint, cb.closed::Ptr{Cvoid})::Cint
    r |= @rtc rtcSetErrorCallback(dc::Cint, cb.error::Ptr{Cvoid})::Cint
    r |= @rtc rtcSetMessageCallback(dc::Cint, cb.message::Ptr{Cvoid})::Cint
    r |= @rtc rtcSetBufferedAmountLowCallback(dc::Cint, cb.buffered_low::Ptr{Cvoid})::Cint
    r
end

# id => PeerConnection or DataChannel. Only Julia tasks touch it, never the callbacks.
const REGISTRY_LOCK = ReentrantLock()
const REGISTRY = Dict{Cint,Any}()

register!(id::Cint, obj) = @lock REGISTRY_LOCK (REGISTRY[id] = obj)
unregister!(id::Cint) = @lock REGISTRY_LOCK (delete!(REGISTRY, id); nothing)
lookup(id::Cint) = @lock REGISTRY_LOCK get(REGISTRY, id, nothing)

function drain!(buf::Vector{Event})
    lock(QUEUE_LOCK)
    try
        append!(buf, QUEUE)
        empty!(QUEUE)
    finally
        unlock(QUEUE_LOCK)
    end
    buf
end

function dispatch_loop(wake::Base.AsyncCondition)
    buf = Event[]
    while true
        for ev in drain!(buf)
            try
                handle(ev)
            catch err
                @error "DataChannels: failed to handle event" event = typeof(ev) exception = (err, catch_backtrace())
            end
        end
        isempty(buf) || (empty!(buf); continue)
        isopen(wake) || break
        try
            wait(wake)
        catch err
            err isa EOFError && break
            rethrow()
        end
    end
end

function handle(ev::EvLog)
    msg = ev.message
    if ev.level <= RTC_LOG_ERROR
        @error "libdatachannel: $msg"
    elseif ev.level == RTC_LOG_WARNING
        @warn "libdatachannel: $msg"
    elseif ev.level == RTC_LOG_INFO
        @info "libdatachannel: $msg"
    else
        @debug "libdatachannel: $msg"
    end
end

# put! into an unbounded Channel that a user task may close at any moment.
function offer!(ch::Channel, x)
    try
        put!(ch, x)
    catch err
        err isa InvalidStateException || rethrow()
    end
    nothing
end

handle(ev::Event) = (obj = lookup(ev.id); obj === nothing || handle(obj, ev))
