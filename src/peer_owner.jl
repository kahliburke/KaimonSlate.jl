# Which local account opened a loopback TCP connection.
#
# Loopback is no access boundary on a shared host: every account on a login node can connect to its
# 127.0.0.1. The kernel records who owns each end of a connection, and Linux reports it two ways:
#
#   • `sock_diag`: one netlink request names a TCP socket by its exact address pair and the reply
#     carries the uid that created it. Microseconds. It needs the `tcp_diag` kernel module, which is
#     not loaded on every machine, and hardened hosts disable loading it on demand.
#   • `/proc/net/tcp` and `tcp6`: always there, but the kernel formats every socket on the machine
#     for each read, which costs tens of milliseconds on a busy node.
#
# `owner_uid` uses `sock_diag` while it works and `/proc` otherwise. Callers should cache the answer
# per connection; the owner of a connection cannot change.
#
# A connection that arrives through an SSH forward (`ssh -L`, VS Code's port forwarding) is opened by
# the forwarding process, which runs as the account that logged in, so it reads as that user. Under
# WSL a Windows browser's connection reads as root or as no one; `accepts` lets those through there.
#
# Pure and dependency-free, so its test can include it on its own (test/test_peer_owner.jl).

module PeerOwner

const AF_INET = 2
const AF_INET6 = 10
const AF_NETLINK = 16
const SOCK_DGRAM = 2
const SOCK_CLOEXEC = 0o2000000
const NETLINK_SOCK_DIAG = 4
const SOCK_DIAG_BY_FAMILY = 20
const NLMSG_ERROR = 2
const NLM_F_REQUEST = 1
const IPPROTO_TCP = 6
const SOL_SOCKET = 1
const SO_RCVTIMEO = 20

const NLMSG_HDRLEN = 16
const DIAG_REQ_LEN = NLMSG_HDRLEN + 56     # nlmsghdr + inet_diag_req_v2
const DIAG_MSG_LEN = 72                    # inet_diag_msg
const UID_OFFSET = 64                      # of `idiag_uid` within inet_diag_msg

"Is `ip` (4 or 16 bytes, network order) a loopback address — 127/8, `::1`, or `::ffff:127.x.y.z`?"
function is_loopback(ip)::Bool
    b = collect(UInt8, ip)
    length(b) == 4 && return b[1] == 0x7f
    length(b) == 16 || return false
    all(iszero, b[1:15]) && b[16] == 0x01 && return true
    return all(iszero, b[1:10]) && b[11] == 0xff && b[12] == 0xff && b[13] == 0x7f
end

"The IPv4-mapped IPv6 form of a 4-byte address."
v4mapped(ip) = UInt8[zeros(UInt8, 10); 0xff; 0xff; collect(UInt8, ip)]

_pad16(ip) = (b = collect(UInt8, ip); UInt8[b; zeros(UInt8, 16 - length(b))])

"""
    diag_request(family, src, sport, dst, dport) -> Vector{UInt8}

A `SOCK_DIAG_BY_FAMILY` request for the one TCP socket whose local end is `src:sport` and remote end
`dst:dport`. Addresses are network-order bytes; netlink's own header fields are host order.
"""
function diag_request(family::Integer, src, sport::Integer, dst, dport::Integer; seq::Integer = 1)
    io = IOBuffer()
    # nlmsghdr
    write(io, UInt32(DIAG_REQ_LEN), UInt16(SOCK_DIAG_BY_FAMILY), UInt16(NLM_F_REQUEST),
          UInt32(seq), UInt32(0))
    # inet_diag_req_v2: family, protocol, extensions, pad, states (all)
    write(io, UInt8(family), UInt8(IPPROTO_TCP), UInt8(0), UInt8(0), typemax(UInt32))
    # inet_diag_sockid: ports in network order, then source and destination, any interface, and
    # INET_DIAG_NOCOOKIE so the kernel matches on the addresses alone
    write(io, hton(UInt16(sport)), hton(UInt16(dport)), _pad16(src), _pad16(dst),
          UInt32(0), typemax(UInt32), typemax(UInt32))
    return take!(io)
end

"The uid in a `sock_diag` reply, or `nothing` when the kernel found no such socket (or answered oddly)."
function reply_uid(resp::AbstractVector{UInt8})::Union{UInt32,Nothing}
    length(resp) >= NLMSG_HDRLEN || return nothing
    typ = reinterpret(UInt16, resp[5:6])[1]
    typ == SOCK_DIAG_BY_FAMILY || return nothing          # NLMSG_ERROR: ENOENT for an unknown socket
    length(resp) >= NLMSG_HDRLEN + DIAG_MSG_LEN || return nothing
    o = NLMSG_HDRLEN + UID_OFFSET
    return reinterpret(UInt32, resp[o+1:o+4])[1]
end

# One request/reply over a fresh netlink socket. A socket per lookup keeps this free of shared state
# across threads, and costs microseconds. The receive timeout bounds a kernel that never answers.
function _query(req::Vector{UInt8})::Vector{UInt8}
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_SOCK_DIAG)
    fd < 0 && error("sock_diag: socket() failed: $(Libc.strerror(Libc.errno()))")
    try
        tv = Int64[1, 0]                                   # struct timeval: 1 s
        ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Int64}, Cuint), fd, SOL_SOCKET, SO_RCVTIMEO, tv, 16)
        kernel = UInt8[reinterpret(UInt8, [UInt16(AF_NETLINK)]); zeros(UInt8, 10)]   # sockaddr_nl, pid 0
        n = ccall(:sendto, Cssize_t, (Cint, Ptr{UInt8}, Csize_t, Cint, Ptr{UInt8}, Cuint),
                  fd, req, length(req), 0, kernel, length(kernel))
        n < 0 && error("sock_diag: sendto() failed: $(Libc.strerror(Libc.errno()))")
        buf = Vector{UInt8}(undef, 8192)
        n = ccall(:recv, Cssize_t, (Cint, Ptr{UInt8}, Csize_t, Cint), fd, buf, length(buf), 0)
        n < 0 && error("sock_diag: recv() failed: $(Libc.strerror(Libc.errno()))")
        return resize!(buf, n)
    finally
        ccall(:close, Cint, (Cint,), fd)
    end
end

# An IPv4 peer is looked up twice when needed: a dual-stack client socket connecting to an IPv4
# address is an AF_INET6 socket holding the IPv4-mapped form.
function _diag_owner(p::Vector{UInt8}, pport::Integer, l::Vector{UInt8}, lport::Integer)
    if length(p) == 4 && length(l) == 4
        uid = reply_uid(_query(diag_request(AF_INET, p, pport, l, lport)))
        uid === nothing || return uid
        return reply_uid(_query(diag_request(AF_INET6, v4mapped(p), pport, v4mapped(l), lport)))
    end
    length(p) == 4 && (p = v4mapped(p))
    length(l) == 4 && (l = v4mapped(l))
    return reply_uid(_query(diag_request(AF_INET6, p, pport, l, lport)))
end

"""
    proc_addr(field) -> (bytes, port)

An address as `/proc/net/tcp{,6}` prints it: each 32-bit word of the address in the kernel's own
byte order, as 8 hex digits, then `:` and the port in hex. Read on the same machine, so reinterpreting
each word natively recovers network-order bytes.
"""
function proc_addr(s::AbstractString)
    a, p = split(s, ':')
    bytes = UInt8[]
    for i in 1:8:length(a)
        append!(bytes, reinterpret(UInt8, [parse(UInt32, a[i:i+7]; base = 16)]))
    end
    return bytes, parse(Int, p; base = 16)
end

"""
    proc_owner(lines, peer, peer_port, here, here_port) -> Union{UInt32,Nothing}

The uid on the `/proc/net/tcp{,6}` line whose local end is `peer:peer_port` and remote end
`here:here_port`.
"""
function proc_owner(lines, p::Vector{UInt8}, pport::Integer, l::Vector{UInt8}, lport::Integer)
    tag = ":" * uppercase(string(pport; base = 16, pad = 4)) * " "   # cheap filter before parsing
    for line in lines
        occursin(tag, line) || continue
        f = split(line)
        length(f) >= 8 || continue
        (proc_addr(f[2]) == (p, pport) && proc_addr(f[3]) == (l, lport)) || continue
        return parse(UInt32, f[8])
    end
    return nothing
end

function _proc_lookup(p::Vector{UInt8}, pport::Integer, l::Vector{UInt8}, lport::Integer)
    if length(p) == 4 && length(l) == 4
        uid = open(io -> proc_owner(eachline(io), p, pport, l, lport), "/proc/net/tcp")
        uid === nothing || return uid
        p, l = v4mapped(p), v4mapped(l)
    end
    length(p) == 4 && (p = v4mapped(p))
    length(l) == 4 && (l = v4mapped(l))
    return open(io -> proc_owner(eachline(io), p, pport, l, lport), "/proc/net/tcp6")
end

# Whether sock_diag answers on this machine: unknown until it either finds a socket or misses one
# that /proc shows. A miss means the module is absent, and every later request would only repeat it.
const _DIAG_WORKS = Ref{Union{Nothing,Bool}}(nothing)

"""
    owner_uid(peer_ip, peer_port, local_ip, local_port) -> Union{UInt32,Nothing}

The uid that owns the far end of a loopback TCP connection this process accepted: the socket whose
local end is `peer_ip:peer_port` and whose remote end is `local_ip:local_port`. `nothing` when the
kernel has no such socket. Linux only.
"""
function owner_uid(peer_ip, peer_port::Integer, local_ip, local_port::Integer)
    p = collect(UInt8, peer_ip); l = collect(UInt8, local_ip)
    if _DIAG_WORKS[] !== false
        uid = try; _diag_owner(p, peer_port, l, local_port); catch; nothing; end
        uid === nothing || (_DIAG_WORKS[] = true; return uid)
    end
    uid = _proc_lookup(p, peer_port, l, local_port)
    uid === nothing || _DIAG_WORKS[] === true || (_DIAG_WORKS[] = false)
    return uid
end

"This process's real uid."
my_uid() = ccall(:getuid, Cuint, ())

"Whether this Linux runs under WSL, going by the kernel release Microsoft's kernels carry."
is_wsl(release::AbstractString) = occursin(r"microsoft|wsl"i, release)
is_wsl() = is_wsl(try; read("/proc/sys/kernel/osrelease", String); catch; ""; end)

"""
    accepts(uid, me; wsl = false) -> Bool

Whether a loopback connection whose far end `uid` owns (`nothing` when no local socket holds it) may
use the hub account `me` runs. Under WSL a Windows program's connection arrives through a relay that
runs as root (NAT networking), or from the Windows side with no Linux socket behind it (mirrored
networking), so both pass there. Another ordinary account is refused everywhere.
"""
accepts(uid, me; wsl::Bool = false) = uid == me || (wsl && (uid === nothing || uid == 0))

end # module PeerOwner
