# Bindings to libdatachannel's C API (rtc/rtc.h, v0.20).
#
# Every call is `gc_safe`: libdatachannel holds internal mutexes while it runs our callbacks, and a
# callback that allocates may need a garbage collection. A Julia thread blocked on one of those
# mutexes inside a non-gc-safe ccall would keep the collection from starting, and the callback
# thread would wait for it forever.

const RTC_ERR_SUCCESS = 0
const RTC_ERR_INVALID = -1
const RTC_ERR_FAILURE = -2
const RTC_ERR_NOT_AVAIL = -3
const RTC_ERR_TOO_SMALL = -4

const RTC_LOG_NONE = Cint(0)
const RTC_LOG_FATAL = Cint(1)
const RTC_LOG_ERROR = Cint(2)
const RTC_LOG_WARNING = Cint(3)
const RTC_LOG_INFO = Cint(4)
const RTC_LOG_DEBUG = Cint(5)
const RTC_LOG_VERBOSE = Cint(6)

struct RtcConfiguration
    iceServers::Ptr{Ptr{UInt8}}
    iceServersCount::Cint
    proxyServer::Ptr{UInt8}      # libnice only
    bindAddress::Ptr{UInt8}      # libjuice only, NULL means any
    certificateType::Cint        # rtcCertificateType
    iceTransportPolicy::Cint     # rtcTransportPolicy
    enableIceTcp::Bool           # libnice only
    enableIceUdpMux::Bool        # libjuice only
    disableAutoNegotiation::Bool
    forceMediaTransport::Bool
    portRangeBegin::UInt16
    portRangeEnd::UInt16
    mtu::Cint
    maxMessageSize::Cint
end

struct RtcReliability
    unordered::Bool
    unreliable::Bool
    maxPacketLifeTime::Cuint
    maxRetransmits::Cuint
end

struct RtcDataChannelInit
    reliability::RtcReliability
    protocol::Ptr{UInt8}
    negotiated::Bool
    manualStream::Bool
    stream::UInt16
end

"""
    RTCError(fn, code)

A libdatachannel call `fn` returned the error `code` (`RTC_ERR_*`).
"""
struct RTCError <: Exception
    fn::Symbol
    code::Int
end

function Base.showerror(io::IO, e::RTCError)
    what = e.code == RTC_ERR_INVALID ? "invalid argument" :
           e.code == RTC_ERR_FAILURE ? "runtime error" :
           e.code == RTC_ERR_NOT_AVAIL ? "not available" :
           e.code == RTC_ERR_TOO_SMALL ? "buffer too small" : "error"
    print(io, "RTCError: ", e.fn, " failed: ", what, " (", e.code, ")")
end

check(fn::Symbol, r::Integer) = r < 0 ? throw(RTCError(fn, r)) : Int(r)

macro rtc(call)
    # `@rtc rtcFoo(a::T, ...)::R` → gc-safe ccall into libdatachannel.
    call.head === :(::) || error("@rtc needs a return type")
    fcall, rt = call.args
    fname = fcall.args[1]
    target = Expr(:., :libdatachannel, QuoteNode(fname))
    lowered = Expr(:(::), Expr(:call, target, fcall.args[2:end]...), rt)
    esc(:(@ccall gc_safe = true $lowered))
end

# String getters share one shape: (id, buffer, size) -> length including NUL, or an error.
function rtc_string(f::Function, fn::Symbol, id::Integer; size::Integer = 1024)
    buf = Vector{UInt8}(undef, size)
    while true
        r = f(Cint(id), buf, Cint(length(buf)))
        if r == RTC_ERR_TOO_SMALL
            resize!(buf, 2 * length(buf))
            continue
        end
        r < 0 && return nothing
        return GC.@preserve buf unsafe_string(pointer(buf))
    end
end
