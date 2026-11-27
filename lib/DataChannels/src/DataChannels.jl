"""
    DataChannels

WebRTC peer connections and data channels, wrapping libdatachannel's C API.
"""
module DataChannels

using libdatachannel_jll: libdatachannel
import Sockets
using Sockets: send, accept

export PeerConnection, DataChannel, Description, Candidate, CandidatePair, RTCError
export signals, accept, state, gathering_state, wait_state, wait_gathering
export set_local_description!, set_remote_description!, add_remote_candidate!, local_description
export create_data_channel, send, wait_open, wait_writable, buffered_amount, set_watermarks!
export label, protocol, stream_id, max_message_size
export selected_candidate_pair, candidate_type, local_address, remote_address, set_log_level

include("capi.jl")
include("dispatch.jl")
include("peerconnection.jl")
include("datachannel.jl")

const LOG_LEVELS = Dict(:none => RTC_LOG_NONE, :fatal => RTC_LOG_FATAL, :error => RTC_LOG_ERROR,
                        :warning => RTC_LOG_WARNING, :info => RTC_LOG_INFO, :debug => RTC_LOG_DEBUG,
                        :verbose => RTC_LOG_VERBOSE)

const INIT_LOCK = ReentrantLock()
const INITIALIZED = Ref(false)
const DISPATCHER = Ref{Union{Nothing,Task}}(nothing)

"""
    set_log_level(level::Symbol)

libdatachannel's log level: `:none`, `:fatal`, `:error`, `:warning` (default), `:info`, `:debug`
or `:verbose`. Its messages go to Julia's logger.
"""
function set_log_level(level::Symbol)
    ensure_initialized()
    lvl = get(() -> throw(ArgumentError("unknown log level :$level")), LOG_LEVELS, level)
    @rtc rtcInitLogger(lvl::Cint, CB[].log::Ptr{Cvoid})::Cvoid
    nothing
end

function ensure_initialized()
    INITIALIZED[] && return
    @lock INIT_LOCK begin
        INITIALIZED[] && return
        CB[] = make_callbacks()
        wake = Base.AsyncCondition()
        WAKE[] = wake
        DISPATCHER[] = if Threads.nthreads(:interactive) > 0
            Threads.@spawn :interactive dispatch_loop(wake)
        else
            Threads.@spawn dispatch_loop(wake)
        end
        errormonitor(DISPATCHER[])
        @rtc rtcInitLogger(RTC_LOG_WARNING::Cint, CB[].log::Ptr{Cvoid})::Cvoid
        @rtc rtcPreload()::Cvoid
        INITIALIZED[] = true
    end
end

"""
    shutdown()

Close every peer connection and channel and release libdatachannel's threads. Runs at exit;
calling it earlier is allowed, and the package initializes itself again on next use.
"""
function shutdown()
    @lock INIT_LOCK begin
        INITIALIZED[] || return
        objs = @lock REGISTRY_LOCK collect(values(REGISTRY))
        for obj in objs
            obj isa PeerConnection && close(obj)
        end
        @rtc rtcCleanup()::Cvoid
        # libdatachannel's threads have been joined; nothing calls back into Julia from here on.
        @rtc rtcInitLogger(RTC_LOG_NONE::Cint, C_NULL::Ptr{Cvoid})::Cvoid
        wake = WAKE[]
        WAKE[] = nothing
        wake === nothing || close(wake)
        INITIALIZED[] = false
    end
end

function __init__()
    atexit(shutdown)
end

end
