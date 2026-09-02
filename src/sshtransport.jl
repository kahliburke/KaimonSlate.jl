# ── SSH as a library, not a subprocess ───────────────────────────────────────────────────────
#
# One authenticated session per host, held in this process, with a channel per command. SSH
# multiplexes channels natively, which is what `ControlMaster` was approximating — and it needs no
# Unix domain socket, so it works the same on every platform.
#
# NON-BLOCKING throughout. libssh2's blocking mode parks an OS thread inside `_libssh2_wait_socket`
# for every network wait — a handshake, a read, an auth — and a hub with a handful of threads runs
# out of them and stops answering. In non-blocking mode a call answers `EAGAIN` and `_ready` waits
# on the socket through Julia's event loop, which parks the TASK and hands the thread back.
#
# Authentication is the one thing that cannot work that way: libssh2 calls our prompt callback from
# inside a C stack frame and needs a return value, and Julia cannot park a task with C frames on its
# stack. So answers are collected BEFORE the call (see `_try_kbdint`) and the callback finds them
# already queued.
#
# WINDOWS: only `_tcp_connect` is platform-bound. Winsock wants `WSAStartup` and a `SOCKET` handle
# instead of an fd; that is the piece to add.
module SshTransport

import LibSSH2_jll
import FileWatching
import Sockets
using Sockets: getaddrinfo, IPv4

const LIB = LibSSH2_jll.libssh2

const EAGAIN = Cint(-37)          # LIBSSH2_ERROR_EAGAIN
const DIR_INBOUND = Cint(1)       # LIBSSH2_SESSION_BLOCK_INBOUND
const DIR_OUTBOUND = Cint(2)

# ── resolved connection settings ─────────────────────────────────────────────────────────────
# `ssh -G` prints a host's effective config with Match/Include/wildcards already applied. Running
# it is one local process and no network; reimplementing it is a standing source of bugs.
struct Endpoint
    alias::String
    hostname::String
    port::Int
    user::String
    identities::Vector{String}
    proxyjump::String
end

function resolve(alias::AbstractString)
    g = try; read(pipeline(`ssh -G $alias`; stderr = devnull), String); catch; ""; end
    get1(k, d) = (m = match(Regex("^$k\\s+(.+)\$", "m"), g); m === nothing ? d : String(strip(m.captures[1])))
    ids = String[String(strip(m.captures[1])) for m in eachmatch(r"^identityfile\s+(.+)$"m, g)]
    return Endpoint(String(alias), get1("hostname", String(alias)),
                    something(tryparse(Int, get1("port", "22")), 22),
                    get1("user", get(ENV, "USER", "")),
                    [replace(i, r"^~" => homedir()) for i in ids],
                    get1("proxyjump", ""))
end

# ── socket ───────────────────────────────────────────────────────────────────────────────────
const AF_INET = Cint(2)
const SOCK_STREAM = Cint(1)
const F_SETFL = Cint(4)
const O_NONBLOCK = Cint(4)

function _tcp_connect(hostname::AbstractString, port::Integer)
    Sys.iswindows() && error("SshTransport: Windows needs a Winsock socket here (WSAStartup + SOCKET)")
    ip = getaddrinfo(String(hostname))
    ip isa IPv4 || error("only IPv4 so far; $hostname resolved to $ip")
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), AF_INET, SOCK_STREAM, 0)
    fd < 0 && error("socket() failed")
    sa = zeros(UInt8, 16)
    if Sys.isbsd(); sa[1] = 0x10; sa[2] = UInt8(AF_INET); else; sa[1] = UInt8(AF_INET); end
    p = UInt16(port); sa[3] = UInt8(p >> 8); sa[4] = UInt8(p & 0xff)
    v = UInt32(ip.host)
    sa[5] = UInt8((v >> 24) & 0xff); sa[6] = UInt8((v >> 16) & 0xff)
    sa[7] = UInt8((v >> 8) & 0xff);  sa[8] = UInt8(v & 0xff)
    if ccall(:connect, Cint, (Cint, Ptr{UInt8}, Cuint), fd, sa, 16) != 0
        ccall(:close, Cint, (Cint,), fd)
        error("connect to $hostname:$port refused")
    end
    ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_SETFL, O_NONBLOCK)
    return fd
end

# ── keyboard-interactive ─────────────────────────────────────────────────────────────────────
struct KbdPrompt;   text::Ptr{UInt8}; length::Cuint; echo::Cuchar; end
struct KbdResponse; text::Ptr{UInt8}; length::Cuint; end

# Reached through libssh2's per-session `abstract` pointer, so two hosts can authenticate at once
# with no lock between them.
mutable struct Prompter
    host::String
    answers::Vector{String}
    seen::Vector{Tuple{String,Bool}}
    idx::Int              # prompts the callback has consumed
    want::Int             # index it is waiting on (0 = idle)
    text::String
    echo::Bool            # false ⇒ a secret; the dialog masks it
    cancelled::Bool
end
Prompter(host) = Prompter(String(host), String[], Tuple{String,Bool}[], 0, 0, "", false, false)

# Matches SshAuth.TIMEOUT; the callback cannot see that module, so the two are stated together here.
const PROMPT_TIMEOUT = 120.0

function _kbd_callback(_n::Ptr{UInt8}, _nl::Cint, _i::Ptr{UInt8}, _il::Cint,
                       n::Cint, prompts::Ptr{KbdPrompt},
                       responses::Ptr{KbdResponse}, abstract::Ptr{Ptr{Cvoid}})::Cvoid
    abstract == C_NULL && return nothing
    handle = unsafe_load(abstract)
    handle == C_NULL && return nothing
    pr = unsafe_pointer_to_objref(handle)::Prompter
    for k in 1:n
        p = unsafe_load(prompts, k)
        pr.idx += 1
        pr.text = p.length > 0 ? unsafe_string(p.text, p.length) : ""
        pr.echo = p.echo != 0
        push!(pr.seen, (pr.text, pr.echo))
        pr.want = pr.idx
        ans = ""
        # Normally already queued (see `_try_kbdint`), so this does not loop at all. It can only
        # wait on first contact with a host whose prompts are not yet known.
        deadline = time() + PROMPT_TIMEOUT
        while time() < deadline
            if pr.idx <= length(pr.answers); ans = pr.answers[pr.idx]; break; end
            pr.cancelled && break
            Base.Libc.systemsleep(0.05)
        end
        pr.want = 0
        buf = ccall(:malloc, Ptr{UInt8}, (Csize_t,), max(sizeof(ans), 1))
        sizeof(ans) > 0 && GC.@preserve ans unsafe_copyto!(buf, pointer(ans), sizeof(ans))
        unsafe_store!(responses, KbdResponse(buf, Cuint(sizeof(ans))), k)
    end
    return nothing
end

# ── session ──────────────────────────────────────────────────────────────────────────────────
# One accepted local connection, carried to the far side by a direct-tcpip channel. The local
# socket is ordinary Julia I/O read by its own task; only the channel touches libssh2, and only from
# the session's owner.
mutable struct Conn
    sock::Any
    ch::Ptr{Cvoid}
    inbox::Channel{Vector{UInt8}}
    closed::Bool
end

# A local port carried to `host:port` as seen from the far side. `host` is resolved THERE, which is
# what lets a login node reach a compute node with no second authentication.
mutable struct Fwd
    localport::Int
    host::String
    port::Int
    listener::Any
    conns::Vector{Conn}
end

mutable struct Session
    ep::Endpoint
    fd::Cint
    ptr::Ptr{Cvoid}
    req::Channel{Any}
    owner::Union{Task,Nothing}
    prompter::Prompter
    alive::Bool
    err::String
    fwds::Vector{Fwd}
end

const _SESSIONS = Dict{String,Session}()
const _REG_LOCK = ReentrantLock()

function _lasterr(s::Session)
    msg = Ref{Ptr{UInt8}}(C_NULL); len = Ref{Cint}(0)
    rc = ccall((:libssh2_session_last_error, LIB), Cint,
               (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Cint}, Cint), s.ptr, msg, len, 0)
    msg[] == C_NULL ? "libssh2 error $rc" : unsafe_string(msg[], len[])
end
_errno(s::Session) = ccall((:libssh2_session_last_errno, LIB), Cint, (Ptr{Cvoid},), s.ptr)

# Wait for the socket in the direction libssh2 says it needs, yielding the task. This is the whole
# point of non-blocking mode: the thread goes back to the pool while we wait.
function _ready(s::Session, timeout::Real)
    _pump_forwards!(s)      # every wait is a chance to move tunnel bytes; nothing else gets a turn
    dir = ccall((:libssh2_session_block_directions, LIB), Cint, (Ptr{Cvoid},), s.ptr)
    r = (dir & DIR_INBOUND) != 0
    w = (dir & DIR_OUTBOUND) != 0
    (r || w) || (r = true)                 # nothing stated: wait for something to read
    try
        FileWatching.poll_fd(RawFD(s.fd), timeout; readable = r, writable = w)
    catch
    end
    return nothing
end

"Run a libssh2 call that may answer EAGAIN, waiting on the socket between attempts."
function _again(s::Session, f; timeout::Real = 60.0)
    deadline = time() + timeout
    while true
        rc = f()
        rc != EAGAIN && return rc
        time() > deadline && return rc
        _ready(s, 5.0)
    end
end

"The pointer form: NULL with EAGAIN means try again, anything else is final."
function _again_ptr(s::Session, f; timeout::Real = 60.0)
    deadline = time() + timeout
    while true
        p = f()
        p == C_NULL || return p
        _errno(s) != EAGAIN && return C_NULL
        time() > deadline && return C_NULL
        _ready(s, 5.0)
    end
end

"Authentication methods the server offers, as it names them."
function auth_methods(s::Session)
    p = Ptr{UInt8}(C_NULL)
    _again(s, () -> begin
        p = ccall((:libssh2_userauth_list, LIB), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Cuint),
                  s.ptr, s.ep.user, length(s.ep.user))
        p == C_NULL ? _errno(s) : Cint(0)
    end)
    p == C_NULL ? String[] : String.(split(unsafe_string(p), ','))
end

_authed(s::Session) = ccall((:libssh2_userauth_authenticated, LIB), Cint, (Ptr{Cvoid},), s.ptr) == 1

function _try_pubkey(s::Session)
    for priv in s.ep.identities
        isfile(priv) || continue
        pub = priv * ".pub"
        rc = _again(s, () -> ccall((:libssh2_userauth_publickey_fromfile_ex, LIB), Cint,
                                   (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cstring, Cstring),
                                   s.ptr, s.ep.user, length(s.ep.user),
                                   isfile(pub) ? pub : C_NULL, priv, ""))
        rc == 0 && return true
    end
    return false
end

# What a host asked last time, so the next connection can collect the answers BEFORE calling
# libssh2. Servers do not change their prompts between logins, and this is not secret.
const _PROMPTS = Dict{String,Vector{Tuple{String,Bool}}}()
const _PROMPTS_LOCK = ReentrantLock()

remembered_prompts(host) = lock(_PROMPTS_LOCK) do; get(_PROMPTS, String(host), Tuple{String,Bool}[]); end

# Learn what a host asks WITHOUT answering: run keyboard-interactive with the callback pre-cancelled
# so it returns empty immediately. Authentication fails by design — no secret is sent and no
# one-time code is spent — and `pr.seen` now holds the prompts, with the server's own echo flags.
function _discover_prompts!(s::Session)
    cb = @cfunction(_kbd_callback, Cvoid,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{KbdPrompt}, Ptr{KbdResponse}, Ptr{Ptr{Cvoid}}))
    pr = s.prompter
    empty!(pr.answers); empty!(pr.seen); pr.idx = 0; pr.want = 0
    pr.cancelled = true                       # every prompt answered instantly, with nothing
    _again(s, () -> ccall((:libssh2_userauth_keyboard_interactive_ex, LIB), Cint,
                          (Ptr{Cvoid}, Cstring, Cuint, Ptr{Cvoid}),
                          s.ptr, s.ep.user, length(s.ep.user), cb); timeout = 30.0)
    isempty(pr.seen) && return false
    lock(_PROMPTS_LOCK) do; _PROMPTS[s.ep.alias] = copy(pr.seen); end
    return true
end

# Authenticate with every answer already in hand. The callback runs inside a C stack frame, and a
# task cannot be parked with C frames on its stack — so anything it has to wait for pins a thread.
# It waits for nothing: the answers are queued before the call.
function _try_kbdint(s::Session, ask)
    isempty(remembered_prompts(s.ep.alias)) && return false      # caller discovers first
    cb = @cfunction(_kbd_callback, Cvoid,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{KbdPrompt}, Ptr{KbdResponse}, Ptr{Ptr{Cvoid}}))
    pr = s.prompter
    empty!(pr.answers); empty!(pr.seen); pr.idx = 0; pr.want = 0; pr.cancelled = false
    for (text, echo) in remembered_prompts(s.ep.alias)
        a = try; ask(s.ep.alias, text, echo); catch; nothing; end
        a === nothing && return false
        push!(pr.answers, String(a))
    end
    pr.cancelled = true                       # anything unexpected returns empty rather than waiting
    rc = _again(s, () -> ccall((:libssh2_userauth_keyboard_interactive_ex, LIB), Cint,
                               (Ptr{Cvoid}, Cstring, Cuint, Ptr{Cvoid}),
                               s.ptr, s.ep.user, length(s.ep.user), cb); timeout = 60.0)
    rc == 0 && !isempty(pr.seen) &&
        lock(_PROMPTS_LOCK) do; _PROMPTS[s.ep.alias] = copy(pr.seen); end
    return rc == 0
end

# ── running things ───────────────────────────────────────────────────────────────────────────
_open_channel(s::Session) =
    _again_ptr(s, () -> ccall((:libssh2_channel_open_ex, LIB), Ptr{Cvoid},
                              (Ptr{Cvoid}, Cstring, Cuint, Cuint, Cuint, Cstring, Cuint),
                              s.ptr, "session", 7, 2 * 1024 * 1024, 32768, C_NULL, 0))

function _drain(s::Session, ch, stream::Cint, sink::IO, deadline::Float64)
    buf = Vector{UInt8}(undef, 65536)
    while true
        n = ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                  (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), ch, stream, buf, length(buf))
        if n == Cssize_t(EAGAIN)
            time() > deadline && return false
            _ready(s, 5.0); continue
        end
        n <= 0 && return true                  # 0 = EOF, negative = a real error
        write(sink, view(buf, 1:Int(n)))
    end
end

function _finish(s::Session, ch, out::IO, err::IO, timeout::Real)
    deadline = time() + timeout
    _drain(s, ch, Cint(0), out, deadline)
    _drain(s, ch, Cint(1), err, deadline)
    _again(s, () -> ccall((:libssh2_channel_close, LIB), Cint, (Ptr{Cvoid},), ch); timeout = 10.0)
    status = ccall((:libssh2_channel_get_exit_status, LIB), Cint, (Ptr{Cvoid},), ch)
    ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
    return status
end

function _start(s::Session, ch, cmd::AbstractString)
    _again(s, () -> ccall((:libssh2_channel_process_startup, LIB), Cint,
                          (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cuint),
                          ch, "exec", 4, cmd, length(cmd)))
end

"Run `cmd` on the session's host. `(ok, output)` with stdout and stderr interleaved."
function _exec(s::Session, cmd::AbstractString; timeout::Real = 120.0)
    ch = _open_channel(s)
    ch == C_NULL && return (false, "channel_open: " * _lasterr(s))
    if _start(s, ch, cmd) != 0
        ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
        return (false, "exec: " * _lasterr(s))
    end
    out = IOBuffer()
    status = _finish(s, ch, out, out, timeout)
    return (status == 0, String(take!(out)))
end

# Run `cmd`, streaming `input` to its stdin and collecting stdout. This is what replaces rsync: the
# metadata directories are small text files, so `tar` over the channel moves them in one round trip.
function _exec_io(s::Session, cmd::AbstractString, input::Union{Vector{UInt8},Nothing};
                  timeout::Real = 300.0)
    ch = _open_channel(s)
    ch == C_NULL && return (false, UInt8[], "channel_open: " * _lasterr(s))
    if _start(s, ch, cmd) != 0
        ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
        return (false, UInt8[], "exec: " * _lasterr(s))
    end
    if input !== nothing
        off = 0
        deadline = time() + timeout
        while off < length(input)
            n = ccall((:libssh2_channel_write_ex, LIB), Cssize_t,
                      (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                      ch, 0, pointer(input, off + 1), length(input) - off)
            if n == Cssize_t(EAGAIN)
                time() > deadline && break
                _ready(s, 5.0); continue
            end
            n < 0 && break
            off += Int(n)
        end
        _again(s, () -> ccall((:libssh2_channel_send_eof, LIB), Cint, (Ptr{Cvoid},), ch); timeout = 10.0)
    end
    out = IOBuffer(); err = IOBuffer()
    status = _finish(s, ch, out, err, timeout)
    return (status == 0, take!(out), String(take!(err)))
end

# ── port forwarding ──────────────────────────────────────────────────────────────────────────
# `direct_tcpip` replaces `ssh -N -L`. The forward rides the session that is already authenticated,
# so it costs no second prompt — and because the far side resolves the target host, a login node
# can carry a connection to a compute node without one either.

_open_tcpip(s::Session, host::AbstractString, port::Integer) =
    _again_ptr(s, () -> ccall((:libssh2_channel_direct_tcpip_ex, LIB), Ptr{Cvoid},
                              (Ptr{Cvoid}, Cstring, Cint, Cstring, Cint),
                              s.ptr, host, Cint(port), "127.0.0.1", Cint(22)); timeout = 15.0)

function _close_conn!(c::Conn)
    c.closed = true
    try; close(c.sock); catch; end
    c.ch == C_NULL || ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), c.ch)
    c.ch = C_NULL
    return nothing
end

# Move whatever is ready, in both directions, without blocking on either. Called from every point
# where the session would otherwise sit waiting, so tunnel traffic keeps flowing during a command.
function _pump_forwards!(s::Session)
    isempty(s.fwds) && return nothing
    buf = Vector{UInt8}(undef, 32768)
    for f in s.fwds, c in f.conns
        c.closed && continue
        # local → remote
        while isready(c.inbox)
            data = take!(c.inbox)
            if isempty(data); _close_conn!(c); break; end
            off = 0
            while off < length(data)
                n = ccall((:libssh2_channel_write_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                          c.ch, 0, pointer(data, off + 1), length(data) - off)
                n == Cssize_t(EAGAIN) && (sleep(0.001); continue)
                n < 0 && (_close_conn!(c); break)
                off += Int(n)
            end
        end
        c.closed && continue
        # remote → local
        while true
            n = ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                      (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), c.ch, 0, buf, length(buf))
            n == Cssize_t(EAGAIN) && break
            if n <= 0; _close_conn!(c); break; end
            try; write(c.sock, view(buf, 1:Int(n))); catch; _close_conn!(c); break; end
        end
    end
    for f in s.fwds
        filter!(c -> !c.closed, f.conns)
    end
    return nothing
end

# Accept on the local port. The channel is opened by the OWNER (libssh2 is not thread-safe), so the
# listener only hands over the socket.
function _add_forward!(s::Session, localport::Integer, host::AbstractString, port::Integer, pending)
    l = try
        Sockets.listen(Sockets.localhost, Int(localport))
    catch e
        return (false, "cannot listen on $localport: $(sprint(showerror, e))")
    end
    f = Fwd(Int(localport), String(host), Int(port), l, Conn[])
    push!(s.fwds, f)
    Threads.@spawn begin
        while isopen(l)
            sock = try; Sockets.accept(l); catch; break; end
            put!(pending, (f, sock))
        end
    end
    return (true, "")
end

# Give an accepted socket its channel and its reader task.
function _attach_conn!(s::Session, f::Fwd, sock)
    ch = _open_tcpip(s, f.host, f.port)
    if ch == C_NULL
        try; close(sock); catch; end
        return nothing
    end
    c = Conn(sock, ch, Channel{Vector{UInt8}}(64), false)
    push!(f.conns, c)
    Threads.@spawn begin
        try
            while !eof(sock) && !c.closed
                put!(c.inbox, readavailable(sock))
            end
        catch
        end
        try; put!(c.inbox, UInt8[]); catch; end     # empty frame = the local side hung up
    end
    return nothing
end

function _drop_forward!(s::Session, localport::Integer)
    for f in s.fwds
        f.localport == Int(localport) || continue
        try; close(f.listener); catch; end
        for c in f.conns; _close_conn!(c); end
    end
    filter!(f -> f.localport != Int(localport), s.fwds)
    return nothing
end

function _close_forwards!(s::Session)
    for f in s.fwds
        try; close(f.listener); catch; end
        for c in f.conns; _close_conn!(c); end
    end
    empty!(s.fwds)
    return nothing
end

function _open!(s::Session, ask)
    ccall((:libssh2_init, LIB), Cint, (Cint,), 0)
    s.fd = _tcp_connect(s.ep.hostname, s.ep.port)
    # The session's `abstract` is this session's Prompter; the keyboard-interactive callback reads
    # it back. Rooted by `Session.prompter`, so it outlives every call that can see it.
    s.ptr = ccall((:libssh2_session_init_ex, LIB), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  C_NULL, C_NULL, C_NULL, pointer_from_objref(s.prompter))
    s.ptr == C_NULL && error("libssh2 session_init failed")
    ccall((:libssh2_session_set_blocking, LIB), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 0)
    rc = _again(s, () -> ccall((:libssh2_session_handshake, LIB), Cint,
                               (Ptr{Cvoid}, Cint), s.ptr, s.fd); timeout = 30.0)
    rc != 0 && error("ssh handshake with $(s.ep.hostname) failed ($rc)")
    ms = auth_methods(s)
    if "publickey" in ms && _try_pubkey(s)
        # nothing more to do
    elseif "keyboard-interactive" in ms
        # A host we have not met yet: find out what it asks, then start again with the answers.
        # Discovery burns an authentication attempt and nothing else — it sends no secret.
        if isempty(remembered_prompts(s.ep.alias))
            _discover_prompts!(s) || error("$(s.ep.alias): the server asked nothing we could answer")
            _reconnect!(s)
        end
        _try_kbdint(s, ask) || error("$(s.ep.alias): authentication was declined or cancelled")
    else
        error(isempty(ms) ? "$(s.ep.alias): no authentication method succeeded" :
              "$(s.ep.alias): could not authenticate (server offers " * join(ms, ", ") * ")")
    end
    _authed(s) || error("$(s.ep.alias): authentication did not complete")
    s.alive = true
    return s
end

# Start the connection over: a failed authentication leaves the session unusable, and discovery
# fails on purpose.
function _reconnect!(s::Session)
    s.ptr == C_NULL || ccall((:libssh2_session_free, LIB), Cint, (Ptr{Cvoid},), s.ptr)
    s.fd >= 0 && ccall(:close, Cint, (Cint,), s.fd)
    s.fd = _tcp_connect(s.ep.hostname, s.ep.port)
    s.ptr = ccall((:libssh2_session_init_ex, LIB), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  C_NULL, C_NULL, C_NULL, pointer_from_objref(s.prompter))
    s.ptr == C_NULL && error("libssh2 session_init failed")
    ccall((:libssh2_session_set_blocking, LIB), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 0)
    rc = _again(s, () -> ccall((:libssh2_session_handshake, LIB), Cint,
                               (Ptr{Cvoid}, Cint), s.ptr, s.fd); timeout = 30.0)
    rc != 0 && error("ssh handshake with $(s.ep.hostname) failed ($rc)")
    return nothing
end

function _close!(s::Session)
    s.alive = false
    if s.ptr != C_NULL
        _again(s, () -> ccall((:libssh2_session_disconnect_ex, LIB), Cint,
                              (Ptr{Cvoid}, Cint, Cstring, Cstring), s.ptr, 11, "closing", "");
               timeout = 5.0)
        ccall((:libssh2_session_free, LIB), Cint, (Ptr{Cvoid},), s.ptr)
    end
    s.fd >= 0 && ccall(:close, Cint, (Cint,), s.fd)
    s.ptr = C_NULL; s.fd = Cint(-1)
    return nothing
end

# One owner task per session: libssh2 sessions are not thread-safe, so every call on a session is
# serialized here. It yields at each network wait, so it holds no thread while waiting.
function _serve(s::Session, ask)
    try
        _open!(s, ask)
    catch e
        s.err = sprint(showerror, e); s.alive = false
    end
    pending = Channel{Any}(32)          # sockets accepted by a listener, waiting for a channel
    while true
        # A forward is a live stream, so the loop cannot simply block on the next request. Take one
        # if there is one, otherwise move tunnel bytes and come back.
        item = nothing
        if isready(s.req) || isempty(s.fwds)
            item = try; take!(s.req); catch; break; end
        else
            while isready(pending)
                f, sock = take!(pending)
                s.alive ? _attach_conn!(s, f, sock) : (try; close(sock); catch; end)
            end
            _pump_forwards!(s)
            sleep(0.002)
            continue
        end
        while isready(pending)
            f, sock = take!(pending)
            s.alive ? _attach_conn!(s, f, sock) : (try; close(sock); catch; end)
        end
        kind, arg, reply = item
        result = try
            !s.alive ? (kind === :io ? (false, UInt8[], s.err) : (false, s.err)) :
            kind === :exec ? _exec(s, arg) :
            kind === :io ? _exec_io(s, arg[1], arg[2]) :
            kind === :forward ? _add_forward!(s, arg[1], arg[2], arg[3], pending) :
            kind === :unforward ? (_drop_forward!(s, arg); (true, "")) :
            kind === :close ? (_close_forwards!(s); _close!(s); (true, "")) :
            (false, "unknown request $kind")
        catch e
            kind === :io ? (false, UInt8[], sprint(showerror, e)) : (false, sprint(showerror, e))
        end
        put!(reply, result)
        kind === :close && break
    end
    _close_forwards!(s)
    s.alive && _close!(s)
    return nothing
end

"""
    session(host; ask) -> Session

The live session for `host`, opening one if needed. `ask(host, prompt, echo) -> String` supplies an
answer for each server prompt; returning `nothing` cancels.
"""
function session(host::AbstractString; ask)
    key = String(host)
    lock(_REG_LOCK) do
        s = get(_SESSIONS, key, nothing)
        s !== nothing && s.alive && return s
        s !== nothing && delete!(_SESSIONS, key)
        ep = resolve(key)
        s = Session(ep, Cint(-1), C_NULL, Channel{Any}(32), nothing, Prompter(key), false, "", Fwd[])
        s.owner = Threads.@spawn _serve(s, ask)
        _SESSIONS[key] = s
        return s
    end
end

function _request(host::AbstractString, kind::Symbol, arg, fail; ask)
    s = session(host; ask = ask)
    reply = Channel{Any}(1)
    try
        put!(s.req, (kind, arg, reply))
    catch
        return fail
    end
    return take!(reply)
end

"Run `cmd` on `host` over the shared session. `(ok, output)`."
exec(host::AbstractString, cmd::AbstractString; ask) =
    _request(String(host), :exec, String(cmd), (false, "session for $host is gone"); ask = ask)

"""
    exec_io(host, cmd, input) -> (ok, stdout::Vector{UInt8}, stderr::String)

Like `exec`, but streams `input` to the command's stdin and returns stdout as bytes. This is what
carries a tar archive in either direction without a second authenticated transport.
"""
exec_io(host::AbstractString, cmd::AbstractString, input::Union{Vector{UInt8},Nothing}; ask) =
    _request(String(host), :io, (String(cmd), input),
             (false, UInt8[], "session for $host is gone"); ask = ask)

"""
    forward!(host, localport, target, targetport; ask) -> (ok, message)

Carry `localport` on this machine to `target:targetport` as the far side sees it, over the session
that is already authenticated. `target` is resolved THERE, so a login node can reach a compute node
without a second connection to authenticate.
"""
forward!(host::AbstractString, localport::Integer, target::AbstractString, targetport::Integer; ask) =
    _request(String(host), :forward, (Int(localport), String(target), Int(targetport)),
             (false, "session for $host is gone"); ask = ask)

"Stop carrying `localport`; its live connections are closed."
unforward!(host::AbstractString, localport::Integer) =
    connected(host) ? first(_request(String(host), :unforward, Int(localport), (false, "no session");
                                     ask = (_...) -> nothing)) : false

"Drop the session for `host` — the next call authenticates again."
function disconnect!(host::AbstractString)
    s = lock(_REG_LOCK) do; pop!(_SESSIONS, String(host), nothing); end
    s === nothing && return false
    s.prompter.cancelled = true
    reply = Channel{Any}(1)
    try; put!(s.req, (:close, "", reply)); take!(reply); catch; end
    close(s.req)
    return true
end

"Is there an authenticated session for `host` right now?"
connected(host::AbstractString) =
    lock(_REG_LOCK) do; (s = get(_SESSIONS, String(host), nothing)) !== nothing && s.alive; end

"Every host with a live session."
hosts() = lock(_REG_LOCK) do; String[k for (k, s) in _SESSIONS if s.alive]; end

end # module SshTransport
