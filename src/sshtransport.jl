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
using Sockets: getaddrinfo, getalladdrinfo, IPAddr, IPv4, IPv6

const LIB = LibSSH2_jll.libssh2

const EAGAIN = Cint(-37)          # LIBSSH2_ERROR_EAGAIN
const DIR_INBOUND = Cint(1)       # LIBSSH2_SESSION_BLOCK_INBOUND
const DIR_OUTBOUND = Cint(2)
const EXTENDED_DATA_MERGE = Cint(2)  # LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE (0 normal, 1 ignore, 2 merge)

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
    identities_only::Bool
    agent::String            # the ssh-agent socket; empty for none
end

"""
The agent socket for an `IdentityAgent` setting as `ssh -G` prints it: unset or `SSH_AUTH_SOCK` means
the environment's, `none` means no agent, `\$VAR` names another variable, anything else is a path.
"""
function _agent_socket(setting::AbstractString)
    v = String(setting)
    (isempty(v) || v == "SSH_AUTH_SOCK") && return get(ENV, "SSH_AUTH_SOCK", "")
    v == "none" && return ""
    startswith(v, '$') && return get(ENV, v[2:end], "")
    return replace(v, r"^~" => homedir())
end

function resolve(alias::AbstractString)
    g = try; read(pipeline(`ssh -G $alias`; stderr = devnull), String); catch; ""; end
    get1(k, d) = (m = match(Regex("^$k\\s+(.+)\$", "m"), g); m === nothing ? d : String(strip(m.captures[1])))
    ids = String[String(strip(m.captures[1])) for m in eachmatch(r"^identityfile\s+(.+)$"m, g)]
    return Endpoint(String(alias), get1("hostname", String(alias)),
                    something(tryparse(Int, get1("port", "22")), 22),
                    get1("user", get(ENV, "USER", "")),
                    [replace(i, r"^~" => homedir()) for i in ids],
                    get1("proxyjump", ""),
                    lowercase(get1("identitiesonly", "no")) == "yes",
                    _agent_socket(get1("identityagent", "")))
end

# ── socket ───────────────────────────────────────────────────────────────────────────────────
const AF_INET = Cint(2)
const SOCK_STREAM = Cint(1)
const F_SETFL = Cint(4)
const O_NONBLOCK = Cint(Sys.isbsd() ? 0x0004 : 0o4000)

const AF_INET6 = Cint(Sys.isbsd() ? 30 : 10)

# The `sockaddr` for `ip:port`, in this system's layout: BSD puts a length byte before a one-byte
# family, Linux has a two-byte family.
function _sockaddr(ip::IPAddr, port::Integer)
    v6 = ip isa IPv6
    sa = zeros(UInt8, v6 ? 28 : 16)
    fam = v6 ? AF_INET6 : AF_INET
    if Sys.isbsd(); sa[1] = UInt8(length(sa)); sa[2] = UInt8(fam); else; sa[1] = UInt8(fam); end
    p = UInt16(port); sa[3] = UInt8(p >> 8); sa[4] = UInt8(p & 0xff)
    if v6
        h = UInt128(ip.host)                     # address at offset 8, after the flow label
        for k in 0:15; sa[9+k] = UInt8((h >> (8 * (15 - k))) & 0xff); end
    else
        v = UInt32(ip.host)
        for k in 0:3; sa[5+k] = UInt8((v >> (8 * (3 - k))) & 0xff); end
    end
    return fam, sa
end

# How long one address may take to accept a connection before the next is tried. An address family
# the network does not route (IPv6 on many networks) otherwise holds a connect for the system's TCP
# timeout, over a minute.
const CONNECT_TIMEOUT_S = 4.0
const SOL_SOCKET = Cint(Sys.isbsd() ? 0xffff : 1)
const SO_ERROR = Cint(Sys.isbsd() ? 0x1007 : 4)
const EINPROGRESS = Cint(Sys.isbsd() ? 36 : 115)

const F_GETFL = Cint(3)

# Put a socket in non-blocking mode, keeping its other flags, and confirm it took. `fcntl` is variadic,
# and on arm64 macOS a variadic argument is passed on the stack, so the call must say so (`Cint...`)
# or the flag never arrives. Every libssh2 call on the session relies on this: a blocking socket holds
# the session lock inside `recv`.
function _set_nonblocking(fd::Cint)
    fl = ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_GETFL, Cint(0))
    fl < 0 && return false
    ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_SETFL, fl | O_NONBLOCK) < 0 && return false
    return (ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_GETFL, Cint(0)) & O_NONBLOCK) != 0
end

# The address family that last connected to each host, tried first next time, so a network without a
# route for the other family costs its timeout once rather than on every connection.
const _GOOD_FAMILY = Dict{String,Bool}()        # host => connected over IPv6
const _GOOD_FAMILY_LOCK = ReentrantLock()

# Connect to the first of the host's addresses that answers, IPv6 and IPv4 alike: a network that
# offers IPv6 may have no usable IPv4 route, or the reverse. Non-blocking, so a wait yields the task
# rather than holding a thread.
function _tcp_connect(hostname::AbstractString, port::Integer)
    Sys.iswindows() && error("SshTransport: Windows needs a Winsock socket here (WSAStartup + SOCKET)")
    host = String(hostname)
    ips = getalladdrinfo(host)
    isempty(ips) && error("$hostname did not resolve")
    good = lock(() -> get(_GOOD_FAMILY, host, nothing), _GOOD_FAMILY_LOCK)
    good === nothing || (ips = sort(ips; by = ip -> (ip isa IPv6) != good))      # stable: last good family first
    tried = String[]
    for ip in ips
        fam, sa = _sockaddr(ip, port)
        fd = ccall(:socket, Cint, (Cint, Cint, Cint), fam, SOCK_STREAM, 0)
        fd < 0 && (push!(tried, "$ip: socket() failed"); continue)
        _set_nonblocking(fd) || (push!(tried, "$ip: could not make the socket non-blocking");
                                 ccall(:close, Cint, (Cint,), fd); continue)
        rc = ccall(:connect, Cint, (Cint, Ptr{UInt8}, Cuint), fd, sa, length(sa))
        err = rc == 0 ? Cint(0) : Libc.errno()
        if err == EINPROGRESS
            # A refused connect can make the wait itself fail (libuv reports the socket's error as a
            # bad descriptor), so the socket's own error is read whenever the wait did not time out.
            ev = try
                FileWatching.poll_fd(RawFD(fd), CONNECT_TIMEOUT_S; writable = true)
            catch
                nothing
            end
            if ev !== nothing && ev.timedout
                err = Cint(-1)                          # no answer within the timeout
            else
                v = Ref{Cint}(0); l = Ref{Cuint}(4)
                rcg = ccall(:getsockopt, Cint, (Cint, Cint, Cint, Ptr{Cint}, Ptr{Cuint}), fd, SOL_SOCKET, SO_ERROR, v, l)
                err = rcg != 0 ? Libc.errno() : v[]
                (err == 0 && ev === nothing) && (err = Cint(-2))   # neither failed nor connected: give up on it
            end
        end
        if err == 0
            lock(() -> (_GOOD_FAMILY[host] = ip isa IPv6), _GOOD_FAMILY_LOCK)
            return fd
        end
        push!(tried, err == -1 ? "$ip: no answer in $(CONNECT_TIMEOUT_S)s" :
                     err == -2 ? "$ip: the wait for the connection failed" : "$ip: errno $err")
        ccall(:close, Cint, (Cint,), fd)
    end
    error("could not connect to $hostname:$port (" * join(tried, "; ") * ")")
end

# ── keyboard-interactive ─────────────────────────────────────────────────────────────────────
struct KbdPrompt;   text::Ptr{UInt8}; length::Csize_t; echo::Cuchar; end   # libssh2 1.11: size_t length
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
    outbox::Vector{UInt8}   # read from the local socket, not yet accepted by the far side
    stalled::Float64        # when the far side stopped accepting bytes; 0 while it keeps up
    tosock::Channel{Vector{UInt8}}   # from the far side, for this connection's writer task
    queued::Threads.Atomic{Int}      # bytes in `tosock` not yet written to the local socket
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
    # libssh2 is not thread-safe, so every call on the session holds `lk`, and only for that call:
    # a command waiting for output holds nothing, so commands run side by side and one that never
    # ends delays only its caller.
    lk::ReentrantLock
    # libssh2 keeps a half-opened channel's state on the SESSION, so one channel open is in flight at
    # a time: `openlk` is held across an open's whole retry loop, and `openerr` is why the last failed.
    openlk::ReentrantLock
    openerr::Cint
    openmsg::String
    # A server allows a few session channels per connection (OpenSSH's MaxSessions, 10 by default) and
    # refuses the rest, so commands past this many wait for one to finish. Forwards are not counted.
    slots::Base.Semaphore
    busy::Threads.Atomic{Int}       # commands running now
    pending::Channel{Any}           # sockets accepted by a forward's listener, waiting for a channel
    # The pump waits on `kick` rather than sleeping: the socket turning readable (`_watch_socket`), a
    # local connection's bytes, an accepted socket, or another channel's read (which can leave tunnel
    # bytes buffered inside libssh2) set it. `pumped` is set after each pass.
    kick::Base.Event
    pumped::Base.Event
    # How many forwards are open: `fwds` changes only under `lk`, and this is what other tasks read.
    ntun::Threads.Atomic{Int}
    # The task polling the socket for the pump. The socket is closed only after it has stopped, so it
    # can never poll a descriptor number the system has handed to something else.
    watcher::Union{Task,Nothing}
    # A connection of its own for one bulk transfer (`_with_bulk`): signed in by key only, never with
    # prompts, and not announced or registered as the host's session.
    bulk::Bool
    # Channels being closed: in non-blocking mode `libssh2_channel_free` on a channel the far side has
    # not closed yet answers EAGAIN and frees nothing, so the channel waits here and the pump frees it
    # once the close has gone through (`_free_channel!`). Under `lk`.
    dying::Vector{Ptr{Cvoid}}
    # The server runs a command in the account's login shell. Commands here are written for bash, so
    # when that shell is another one (zsh, whose unmatched glob is an error) and bash is installed,
    # each command is handed to bash. Set once signed in (`_note_login_shell!`).
    in_bash::Bool
end
Session(ep, fd, ptr, req, owner, prompter, alive, err, fwds; bulk::Bool = false) =
    Session(ep, fd, ptr, req, owner, prompter, alive, err, fwds, ReentrantLock(), ReentrantLock(), Cint(0), "",
            Base.Semaphore(_max_channels()), Threads.Atomic{Int}(0), Channel{Any}(32),
            Base.Event(true), Base.Event(true), Threads.Atomic{Int}(0), nothing, bulk, Ptr{Cvoid}[], false)

# `cmd` as the server should be sent it: as it is under a bash login shell, else as bash's argument.
_as_sent(s::Session, cmd::AbstractString) =
    s.in_bash ? "exec bash -c '" * replace(cmd, "'" => "'\\''") * "'" : String(cmd)

# Ask the login shell what it is. The probe parses in sh, bash and zsh alike; a shell it fails in is
# left to run commands itself. The last line is read, since a login file may print before it.
function _note_login_shell!(s::Session)
    s.in_bash = false
    ok, out, _ = _exec(s, "printf '%s|' \"\${BASH_VERSION:-}\"; command -v bash"; timeout = 15.0)
    ok || return nothing
    lines = split(strip(out), '\n')
    isempty(lines) && return nothing
    parts = split(last(lines), '|'; limit = 2)
    length(parts) == 2 || return nothing
    ver, path = parts
    s.in_bash = isempty(ver) && !isempty(strip(path))
    s.in_bash && !s.bulk && @info "ssh: $(s.ep.alias) login shell is not bash; commands run in $(strip(path))"
    return nothing
end

# Free a channel now, or once its close has gone through. Under `s.lk`.
function _free_channel!(s::Session, ch::Ptr{Cvoid})
    ch == C_NULL && return nothing
    rc = ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
    rc == EAGAIN ? push!(s.dying, ch) : _note_freed!(ch)
    return nothing
end

# Free the channels whose close has gone through since. Under `s.lk`; called on each pump pass.
_reap_dying!(s::Session) =
    isempty(s.dying) || filter!(s.dying) do ch
        freed = ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch) != EAGAIN
        freed && _note_freed!(ch)
        !freed
    end

# The command channels open now, each with the session it belongs to, its command and its start: the account given when
# a server refuses another channel. A channel stays here until it is freed, which for a command whose far end has not
# finished is not yet; a session's channels are freed with it, so its entries go when it does (`_forget_session_cmds!`).
const _OPEN_CMDS = Dict{Ptr{Cvoid},Tuple{Session,String,Float64}}()
const _OPEN_CMDS_LOCK = ReentrantLock()
const _REFUSAL_REPORTED = Dict{String,Float64}()
_note_open!(s::Session, ch, cmd) = lock(_OPEN_CMDS_LOCK) do
    _OPEN_CMDS[ch] = (s, first(String(cmd), 120), time())
    delete!(_IDLE_REFUSAL_SINCE, s)
    nothing
end
_note_freed!(ch) = lock(() -> (delete!(_OPEN_CMDS, ch); nothing), _OPEN_CMDS_LOCK)

# `s`'s command channels, oldest first, as (start, command).
_session_cmds(s::Session) =
    sort!([(t, cmd) for (o, cmd, t) in values(_OPEN_CMDS) if o === s]; by = first)   # under `_OPEN_CMDS_LOCK`

# Called as libssh2 frees the session, which frees its channels with it.
_forget_session_cmds!(s::Session) = lock(_OPEN_CMDS_LOCK) do
    filter!(kv -> last(kv)[1] !== s, _OPEN_CMDS)
    delete!(_IDLE_REFUSAL_SINCE, s)
    nothing
end

# A server that refuses every channel while this session holds none of its command channels and is closing none is
# counting sessions this side has already let go. The connection then refuses every command from that point on, while
# the forwards riding it keep working, since a forward is not a session. Seen for `IDLE_REFUSAL_S` with no channel
# opening in between, the session is ended as a lost connection is: the next command connects afresh, and the forwards
# are made again over the new connection. Each connection is counted on its own, so only this session's channels
# count. When the first such refusal was seen, per session; under `_OPEN_CMDS_LOCK`.
const _IDLE_REFUSAL_SINCE = IdDict{Session,Float64}()
const IDLE_REFUSAL_S = 60.0

function _refused_with_none_open!(s::Session, why::AbstractString)
    s.bulk && return false
    closing = lock(() -> length(s.dying), s.lk)
    stale = lock(_OPEN_CMDS_LOCK) do
        if closing > 0 || any(v -> v[1] === s, values(_OPEN_CMDS))
            delete!(_IDLE_REFUSAL_SINCE, s)
            return false
        end
        since = get!(_IDLE_REFUSAL_SINCE, s, time())
        time() - since < IDLE_REFUSAL_S && return false
        delete!(_IDLE_REFUSAL_SINCE, s)
        true
    end
    stale && _channel_dead!(s, "$(s.ep.alias) refuses every channel though none of this session's are open ($why)")
    return stale
end

# What the session holds when the server refuses a channel, at most once a minute per host
function _report_refusal(s::Session, why::AbstractString)
    host = s.ep.alias
    now = time()
    lock(_OPEN_CMDS_LOCK) do
        now - get(_REFUSAL_REPORTED, host, 0.0) < 60 && return nothing
        _REFUSAL_REPORTED[host] = now
        mine = _session_cmds(s)
        @warn "ssh: $host refused a channel" why commands_running = s.busy[] forwards = s.ntun[] closing = length(s.dying) open_commands = length(mine) oldest = [string(round(Int, now - t), "s  ", cmd) for (t, cmd) in mine[1:min(end, 12)]]
    end
    nothing
end

# libssh2's global setup, which must not run twice at once. Once per process.
const _LIBSSH2_INIT_LOCK = ReentrantLock()
const _LIBSSH2_INITED = Ref(false)
_libssh2_init!() = lock(_LIBSSH2_INIT_LOCK) do
    _LIBSSH2_INITED[] || (ccall((:libssh2_init, LIB), Cint, (Cint,), 0); _LIBSSH2_INITED[] = true)
    nothing
end

# Wake the session's pump: something it may have to move has arrived.
_kick!(s::Session) = (notify(s.kick); nothing)

# Wait for `ev`, or `timeout` seconds at most.
function _wait_event(ev::Base.Event, timeout::Real)
    t = Timer(_ -> notify(ev), timeout)
    try
        wait(ev)
    finally
        close(t)
    end
    return nothing
end

# Read when a session opens, not when this file is compiled into an image.
_max_channels() = something(tryparse(Int, get(ENV, "KAIMONSLATE_SSH_MAX_CHANNELS", "")), 8)

const _SESSIONS = Dict{String,Session}()
const _REG_LOCK = ReentrantLock()

function _lasterr(s::Session)
    lock(s.lk) do
    msg = Ref{Ptr{UInt8}}(C_NULL); len = Ref{Cint}(0)
    rc = ccall((:libssh2_session_last_error, LIB), Cint,
               (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Cint}, Cint), s.ptr, msg, len, 0)
    msg[] == C_NULL ? "libssh2 error $rc" : unsafe_string(msg[], len[])
    end
end
_errno(s::Session) = ccall((:libssh2_session_last_errno, LIB), Cint, (Ptr{Cvoid},), s.ptr)

# Wait for the socket in the direction libssh2 says it needs, yielding the task. This is the whole
# point of non-blocking mode: the thread goes back to the pool while we wait. Several commands wait
# on one socket, and a read for one channel can take in what another was waiting for, so no wait is
# longer than a moment: the call is simply tried again.
const _WAIT_S = 0.02
function _ready(s::Session, timeout::Real)
    dir = lock(() -> ccall((:libssh2_session_block_directions, LIB), Cint, (Ptr{Cvoid},), s.ptr), s.lk)
    r = (dir & DIR_INBOUND) != 0
    w = (dir & DIR_OUTBOUND) != 0
    (r || w) || (r = true)                 # nothing stated: wait for something to read
    # A bulk session's reader waits in the kernel: it wakes as the bytes arrive, where a wait through
    # the event loop wakes only when that loop next runs, which in a busy process is late enough to
    # leave the connection idle. GC-safe, so a thread waiting here never holds up a collection.
    (s.bulk && BULK_KERNEL_POLL[]) && (_kernel_poll(s.fd, r, w, round(Cint, 1000 * min(timeout, _WAIT_S))); return nothing)
    try
        FileWatching.poll_fd(RawFD(s.fd), min(timeout, _WAIT_S); readable = r, writable = w)
    catch
        sleep(0.002)
    end
    return nothing
end

# poll(2) on one descriptor for at most `ms` milliseconds. `struct pollfd` is the same on BSD and
# Linux; `nfds_t` is unsigned int on BSD and unsigned long on Linux.
struct _PollFd
    fd::Cint
    events::Cshort
    revents::Cshort
end
const POLLIN = 0x0001
const POLLOUT = 0x0004
const BULK_KERNEL_POLL = Ref(true)     # bulk sessions wait in poll(2) rather than the event loop
function _kernel_poll(fd::Cint, readable::Bool, writable::Bool, ms::Cint)
    pfd = Ref(_PollFd(fd, Cshort((readable ? POLLIN : 0) | (writable ? POLLOUT : 0)), Cshort(0)))
    return Sys.isbsd() ? @ccall(gc_safe = true, poll(pfd::Ptr{_PollFd}, 1::Cuint, ms::Cint)::Cint) :
                         @ccall(gc_safe = true, poll(pfd::Ptr{_PollFd}, 1::Culong, ms::Cint)::Cint)
end

"Run a libssh2 call that may answer EAGAIN, waiting on the socket between attempts."
function _again(s::Session, f; timeout::Real = 60.0)
    deadline = time() + timeout
    while true
        rc = lock(f, s.lk)
        rc != EAGAIN && return rc
        time() > deadline && return rc
        _ready(s, 5.0)
    end
end

"The pointer form: NULL with EAGAIN means try again, anything else is final."
function _again_ptr(s::Session, f; timeout::Real = 60.0)
    deadline = time() + timeout
    while true
        p, e, m = lock(s.lk) do
            p = f()
            p != C_NULL ? (p, Cint(0), "") : (e = _errno(s); (p, e, e == EAGAIN ? "" : _lasterr(s)))
        end
        p == C_NULL || return p
        s.openerr = e; isempty(m) || (s.openmsg = m)
        e != EAGAIN && return C_NULL
        time() > deadline && return C_NULL
        _ready(s, 5.0)
    end
end

"Authentication methods the server offers, as it names them."
function auth_methods(s::Session)
    p = Ptr{UInt8}(C_NULL)
    _again(s, () -> begin
        p = ccall((:libssh2_userauth_list, LIB), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Cuint),
                  s.ptr, s.ep.user, sizeof(s.ep.user))
        p == C_NULL ? _errno(s) : Cint(0)
    end)
    p == C_NULL ? String[] : String.(split(unsafe_string(p), ','))
end

_authed(s::Session) = ccall((:libssh2_userauth_authenticated, LIB), Cint, (Ptr{Cvoid},), s.ptr) == 1

"""
The public halves to offer with the private key `priv`, in order: its certificate `<priv>-cert.pub`
(OpenSSH's naming, which short-lived keys from a site's certificate authority follow), then
`<priv>.pub`. `nothing` lets libssh2 derive the public key from `priv`.
"""
function _pubkey_candidates(priv::AbstractString)
    pubs = Union{String,Nothing}[p for p in (priv * "-cert.pub", priv * ".pub") if isfile(p)]
    return isempty(pubs) ? Union{String,Nothing}[nothing] : pubs
end

# ── ssh-agent ────────────────────────────────────────────────────────────────────────────────
# `struct libssh2_agent_publickey`
struct _AgentKey
    magic::Cuint
    node::Ptr{Cvoid}
    blob::Ptr{UInt8}
    blob_len::Csize_t
    comment::Ptr{UInt8}
end

const _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function _b64decode(s::AbstractString)
    out = UInt8[]; acc = UInt32(0); bits = 0
    for c in s
        c == '=' && break
        v = findfirst(==(c), _B64)
        v === nothing && continue
        acc = (acc << 6) | UInt32(v - 1); bits += 6
        bits >= 8 && (bits -= 8; push!(out, UInt8((acc >> bits) & 0xff)))
    end
    return out
end

"The key blobs in `priv`'s public key and certificate files, where they exist."
function _pub_blobs(priv::AbstractString)
    out = Vector{UInt8}[]
    for f in (priv * ".pub", priv * "-cert.pub")
        isfile(f) || continue
        fs = split(strip(readline(f)))
        length(fs) >= 2 && push!(out, _b64decode(fs[2]))
    end
    return out
end

"The key type a blob names, such as `ssh-ed25519` or `ssh-rsa-cert-v01@openssh.com`."
function _blob_type(blob::AbstractVector{UInt8})
    length(blob) < 4 && return ""
    n = (Int(blob[1]) << 24) | (Int(blob[2]) << 16) | (Int(blob[3]) << 8) | Int(blob[4])
    return length(blob) < 4 + n ? "" : String(blob[5:4+n])
end

# The length-prefixed fields of a key or certificate blob.
function _blob_fields(blob::AbstractVector{UInt8})
    out = Vector{UInt8}[]; i = 1
    while i + 3 <= length(blob)
        n = (Int(blob[i]) << 24) | (Int(blob[i+1]) << 16) | (Int(blob[i+2]) << 8) | Int(blob[i+3])
        i + 3 + n > length(blob) && break
        push!(out, blob[i:i+3+n]); i += 4 + n
    end
    return out
end

const _CERT_SUFFIX = "-cert-v01@openssh.com"
# How many fields hold the public key, for each key type a certificate can carry.
const _KEY_FIELDS = Dict("ssh-rsa" => 2, "ssh-dss" => 4, "ssh-ed25519" => 1, "ssh-ed448" => 1)
_key_fields(t) = startswith(t, "ecdsa-sha2-") || startswith(t, "sk-ecdsa-sha2-") ? 2 + startswith(t, "sk-") :
                 startswith(t, "sk-ssh-ed25519") ? 2 : get(_KEY_FIELDS, t, 0)

"""
The plain public key a certificate certifies, as a key blob: its type without the certificate
suffix, then the key fields that follow the certificate's nonce. `nothing` for anything else.
"""
function _certified_key(blob::AbstractVector{UInt8})
    t = _blob_type(blob)
    endswith(t, _CERT_SUFFIX) || return nothing
    base = t[1:end-length(_CERT_SUFFIX)]
    n = _key_fields(base)
    fs = _blob_fields(blob)
    (n == 0 || length(fs) < 2 + n) && return nothing
    name = Vector{UInt8}(base)
    len = UInt8[(length(name) >> s) & 0xff for s in (24, 16, 8, 0)]
    return vcat(len, name, fs[3:2+n]...)
end

"""
The agent's keys to offer, as indices into `blobs`. Each certificate comes first, followed by the
plain key it certifies, then every other key: a host that issues certificates often accepts nothing
else, and each refusal counts against its limit on attempts. With `IdentitiesOnly`, only keys whose
public key or certificate sits beside one of the host's identity files, as OpenSSH does.
"""
function _agent_order(blobs::Vector{Vector{UInt8}}, identities, identities_only::Bool)
    allowed = identities_only ? Set(b for priv in identities for b in _pub_blobs(priv)) : nothing
    ok(i) = allowed === nothing || blobs[i] in allowed
    order = Int[]
    for i in eachindex(blobs)
        k = _certified_key(blobs[i])
        k === nothing && continue
        ok(i) && push!(order, i)
        j = findfirst(==(k), blobs)
        j === nothing || j in order || !ok(j) || push!(order, j)
    end
    append!(order, (i for i in eachindex(blobs) if ok(i) && !(i in order)))
    return order
end

function _try_agent(s::Session)
    sock = s.ep.agent
    (isempty(sock) || !ispath(sock)) && return false
    a = ccall((:libssh2_agent_init, LIB), Ptr{Cvoid}, (Ptr{Cvoid},), s.ptr)
    a == C_NULL && return false
    try
        ccall((:libssh2_agent_set_identity_path, LIB), Cvoid, (Ptr{Cvoid}, Cstring), a, sock)
        ccall((:libssh2_agent_connect, LIB), Cint, (Ptr{Cvoid},), a) == 0 || return false
        ccall((:libssh2_agent_list_identities, LIB), Cint, (Ptr{Cvoid},), a) == 0 || return false
        keys = Ptr{_AgentKey}[]
        prev = Ptr{_AgentKey}(C_NULL)
        while true
            store = Ref{Ptr{_AgentKey}}(C_NULL)
            ccall((:libssh2_agent_get_identity, LIB), Cint,
                  (Ptr{Cvoid}, Ref{Ptr{_AgentKey}}, Ptr{_AgentKey}), a, store, prev) == 0 || break
            prev = store[]
            push!(keys, prev)
        end
        blobs = [(k = unsafe_load(p); copy(unsafe_wrap(Array, k.blob, k.blob_len))) for p in keys]
        for i in _agent_order(blobs, s.ep.identities, s.ep.identities_only)
            rc = _again(s, () -> ccall((:libssh2_agent_userauth, LIB), Cint,
                                       (Ptr{Cvoid}, Cstring, Ptr{_AgentKey}), a, s.ep.user, keys[i]))
            rc == 0 && return true
        end
        return false
    finally
        ccall((:libssh2_agent_disconnect, LIB), Cint, (Ptr{Cvoid},), a)
        ccall((:libssh2_agent_free, LIB), Cvoid, (Ptr{Cvoid},), a)
    end
end

function _try_pubkey(s::Session)
    for priv in s.ep.identities
        isfile(priv) || continue
        for pub in _pubkey_candidates(priv)
            rc = _again(s, () -> ccall((:libssh2_userauth_publickey_fromfile_ex, LIB), Cint,
                                       (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cstring, Cstring),
                                       s.ptr, s.ep.user, sizeof(s.ep.user),
                                       something(pub, C_NULL), priv, ""))
            rc == 0 && return true
        end
    end
    return false
end

# What a host asked last time, so the next connection can collect the answers BEFORE calling
# libssh2. Servers do not change their prompts between logins, and this is not secret.
const _PROMPTS = Dict{String,Vector{Tuple{String,Bool}}}()
const _PROMPTS_LOCK = ReentrantLock()

remembered_prompts(host) = lock(_PROMPTS_LOCK) do; get(_PROMPTS, String(host), Tuple{String,Bool}[]); end

# Drop what a host asked, for a login the server has just refused: the shape it was refused with is
# the one thing known to be wrong, so the next attempt rediscovers rather than replaying it. Goes
# through the same store as every other change, so a hub keeping them sees the removal too.
function _forget_prompts!(host)
    had = lock(_PROMPTS_LOCK) do
        pop!(_PROMPTS, String(host), nothing) !== nothing
    end
    had && _save_prompts()
    return nothing
end

# Learning what a host asks costs a deliberately-failed login (`_discover_prompts!`). Where a cluster
# issues its second factor with the prompt rather than on the answer, that failed login spends one of
# the user's codes and the real login spends another. Keeping what was learned across restarts is
# what makes that a one-off per host instead of a toll on every hub start.
#
# Safe to keep across restarts only because `_try_kbdint` rewrites the entry from what the server
# actually asked on every attempt, pass or fail: a login that changes shape corrects the store the
# next time it is used rather than wedging against it.
#
# WHERE they are kept is the caller's business, not this module's. Every file here also ships to a
# cluster as part of the worker payload and is loaded there against whatever environment the remote
# has, so this module imports nothing beyond libssh2 and the Base networking it needs. Choosing a
# directory and a file format would mean a serialization dependency, and a worker that cannot load
# it loses the whole batch fabric.
const _PROMPT_SAVE = Ref{Any}(nothing)

# A pair is whatever the caller's store round-trips to: a `Tuple` straight back from `save`, a
# two-element array once it has been through a file. Both, or the two calls do not compose.
function _parse_prompts(rows)
    rows isa AbstractVector || return nothing
    out = Tuple{String,Bool}[]
    for r in rows
        (r isa Union{AbstractVector,Tuple} && length(r) == 2 &&
         r[1] isa AbstractString && r[2] isa Bool) || return nothing
        push!(out, (String(r[1]), r[2]))
    end
    return isempty(out) ? nothing : out
end

"""
    set_prompt_store!(save)

Call `save(prompts)` whenever what a host asks changes, so the shapes outlive the process. `prompts`
maps a host to its `(text, echo)` list. Unset, which is the default, they last only as long as this
process does.
"""
set_prompt_store!(save) = (_PROMPT_SAVE[] = save; nothing)

"""
    adopt_prompts!(entries)

Seed from what a previous run kept. Anything this process has already learned wins, having come from
a live conversation with the server, and an entry that is not a list of `(text, echo)` pairs is
dropped rather than trusted.
"""
function adopt_prompts!(entries)
    entries isa AbstractDict || return nothing
    lock(_PROMPTS_LOCK) do
        for (host, rows) in entries
            haskey(_PROMPTS, String(host)) && continue
            got = _parse_prompts(rows)
            got === nothing || (_PROMPTS[String(host)] = got)
        end
    end
    return nothing
end

# Record what `host` asked. No-op when it has not changed, so an ordinary login does not rewrite the
# store; the snapshot is taken under the lock and handed over outside it, since keeping it is IO.
function _remember_prompts!(host::AbstractString, seen::Vector{Tuple{String,Bool}})
    isempty(seen) && return nothing
    changed = lock(_PROMPTS_LOCK) do
        get(_PROMPTS, String(host), nothing) == seen && return false
        _PROMPTS[String(host)] = copy(seen)
        return true
    end
    changed && _save_prompts()
    return nothing
end

# Hand the current shapes to whatever the caller keeps them in. Snapshot under the lock and save
# outside it, since keeping them is IO. A store that cannot be written costs a discovery round on
# the next start, never a login.
function _save_prompts()
    save = _PROMPT_SAVE[]
    save === nothing && return nothing
    snap = lock(_PROMPTS_LOCK) do; Dict(h => copy(v) for (h, v) in _PROMPTS); end
    try; save(snap); catch; end
    return nothing
end

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
                          s.ptr, s.ep.user, sizeof(s.ep.user), cb); timeout = 30.0)
    isempty(pr.seen) && return false
    _remember_prompts!(s.ep.alias, pr.seen)
    return true
end

# Authenticate with every answer already in hand. The callback runs inside a C stack frame, and a
# task cannot be parked with C frames on its stack — so anything it has to wait for pins a thread.
# It waits for nothing: the answers are queued before the call.
# Returns `:ok` on success, `:dismissed` if the person cancelled the dialog (answered nothing), or
# `:rejected` if answers were sent and the server refused them. The caller uses that distinction to
# tell a real rejection - worth forgetting stale remembered prompts over - from a dismissal, which
# must leave the prompts alone.
function _try_kbdint(s::Session, ask)::Symbol
    isempty(remembered_prompts(s.ep.alias)) && return :rejected      # caller discovers first
    cb = @cfunction(_kbd_callback, Cvoid,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{KbdPrompt}, Ptr{KbdResponse}, Ptr{Ptr{Cvoid}}))
    pr = s.prompter
    empty!(pr.answers); empty!(pr.seen); pr.idx = 0; pr.want = 0; pr.cancelled = false
    for (text, echo) in remembered_prompts(s.ep.alias)
        # `nothing` is a real answer: the person dismissed the dialog. An asker that THROWS is a
        # fault in the path that shows it, so it is raised — a fault reported as a dismissal names
        # the failure as the user's and says nothing about the code that broke.
        a = try
            ask(s.ep.alias, text, echo)
        catch e
            error("$(s.ep.alias): could not ask for \"$(strip(text))\" — " *
                  first(sprint(showerror, e), 200))
        end
        a === nothing && return :dismissed
        push!(pr.answers, String(a))
    end
    pr.cancelled = true                       # anything unexpected returns empty rather than waiting
    rc = _again(s, () -> ccall((:libssh2_userauth_keyboard_interactive_ex, LIB), Cint,
                               (Ptr{Cvoid}, Cstring, Cuint, Ptr{Cvoid}),
                               s.ptr, s.ep.user, sizeof(s.ep.user), cb); timeout = 60.0)
    # `pr.seen` is what the server asked THIS time, recorded by the callback whether or not the
    # answers were accepted. A mistyped password leaves it matching what was remembered; a login
    # that has since gained or lost a factor leaves it different. Keeping it either way is what
    # stops a changed login wedging the host: the remembered list is never allowed to outlive the
    # conversation it came from, so the next attempt asks for what the server now wants.
    _remember_prompts!(s.ep.alias, pr.seen)
    return rc == 0 ? :ok : :rejected
end

# ── running things ───────────────────────────────────────────────────────────────────────────
# How much one read asks for, which is also what paces a transfer: libssh2 tops a channel's receive
# window up only when a read's buffer is larger than what is left, and only by that buffer
# (`libssh2_channel_read_ex`), so the far side can have about one buffer in flight per round trip. A
# small buffer caps a long link at a few MB/s. The window is grown this way, inside libssh2's own read,
# rather than adjusted separately: an adjustment that cannot be sent at once has to be finished by the
# same call before anything else is sent on the session, and the read does exactly that.
const READ_BYTES = 4 * 1024 * 1024          # a command's output
const PUMP_READ_BYTES = 1024 * 1024         # a tunnel's, per connection per pass

# A channel, or NULL with why: `(ch, err, msg)`, all read under the open lock.
_open_channel(s::Session) = lock(s.openlk) do
    ch = _again_ptr(s, () -> ccall((:libssh2_channel_open_ex, LIB), Ptr{Cvoid},
                                   (Ptr{Cvoid}, Cstring, Cuint, Cuint, Cuint, Cstring, Cuint),
                                   s.ptr, "session", 7, 2 * 1024 * 1024, 32768, C_NULL, 0))
    ch == C_NULL ? (ch, s.openerr, "channel_open: " * (s.openerr == EAGAIN ? "no answer from the server" : s.openmsg)) :
                   (ch, Cint(0), "")
end

# libssh2 errors that mean the connection itself is gone: a socket that failed or closed, or a server
# that stopped answering (still EAGAIN at the open's deadline). A refused channel is not one of them:
# that fails the command and leaves the session, and every tunnel on it, as it is. Nor is -1: libssh2
# returns it while waiting for a reply that has not arrived yet, which happens when another channel's
# read took the socket's data first.
const _TRANSPORT_ERRS = (Cint(-7), Cint(-13), Cint(-30), Cint(-43), EAGAIN)

"""
    stop_requested(sink) -> Bool

Whether whoever reads a command's output has stopped wanting it. A sink that can be stopped (a
transfer a cell abandoned) defines a method; the command's channel is then closed, which ends the
command on the far side.
"""
stop_requested(::IO) = false

# Reads one stream to its end: `:eof`, `:timeout` (past the deadline, or the session is closing),
# `:lost` (a read failed, so what arrived is not all the command wrote) or `:stopped` (the sink's
# reader stopped wanting it).
function _drain(s::Session, ch, stream::Cint, sink::IO, deadline::Float64)
    buf = Vector{UInt8}(undef, stream == 0 ? READ_BYTES : 65536)   # stderr carries messages, not data
    while true
        stop_requested(sink) && return :stopped
        n = lock(() -> ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                             (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), ch, stream, buf, length(buf)), s.lk)
        # -1 is libssh2 still waiting on data another channel's read took off the socket: not yet, the
        # same as at a channel open.
        if n == Cssize_t(EAGAIN) || n == Cssize_t(-1)
            (time() > deadline || !s.alive) && return :timeout
            _ready(s, 5.0); continue
        end
        n == 0 && return :eof
        if n < 0
            Cint(n) in _TRANSPORT_ERRS && _channel_dead!(s, "read: " * lock(() -> _lasterr(s), s.lk))
            return :lost
        end
        # This read took what was on the socket, tunnel bytes included, into libssh2: the pump has to
        # look, since the socket will not tell it.
        s.ntun[] > 0 && _kick!(s)
        write(sink, view(buf, 1:Int(n)))
    end
end

# The command's exit status, or one of these when it has none. Both are failures even though the
# channel then closes cleanly: libssh2 reports 0 for a command whose exit it never saw. A command that
# ran past its deadline, or whose output was cut off, may still be running there.
const TIMED_OUT = Cint(-1)
const LOST = Cint(-2)

function _finish(s::Session, ch, out::IO, err::IO, timeout::Real)
    deadline = time() + timeout
    a = _drain(s, ch, Cint(0), out, deadline)
    # Stderr only after a whole stdout: a stopped reader closes the channel at once, since draining
    # stderr would wait for the command to end.
    b = a === :eof ? _drain(s, ch, Cint(1), err, deadline) : a
    _again(s, () -> ccall((:libssh2_channel_close, LIB), Cint, (Ptr{Cvoid},), ch); timeout = 10.0)
    status = lock(s.lk) do
        st = ccall((:libssh2_channel_get_exit_status, LIB), Cint, (Ptr{Cvoid},), ch)
        _free_channel!(s, ch)
        st
    end
    (a === :lost || b === :lost) && return LOST
    return (a === :eof && b === :eof) ? status : TIMED_OUT
end

# A sink that hands each complete line to `f` as it arrives and keeps everything, so a long command
# can be followed while it runs and still returns its whole output. `f` runs on the session's owner
# task, between reads, so it must be quick; a throw from it is dropped rather than ending the read.
# A carriage return ends a line too: progress output rewrites one line with `\r`.
mutable struct LineTap <: IO
    buf::IOBuffer
    partial::Vector{UInt8}
    f::Any
end
LineTap(f) = LineTap(IOBuffer(), UInt8[], f)

function _tap_line!(t::LineTap)
    isempty(t.partial) && return nothing
    line = String(copy(t.partial)); empty!(t.partial)
    try; t.f(line); catch; end
    return nothing
end

function Base.unsafe_write(t::LineTap, p::Ptr{UInt8}, n::UInt)
    unsafe_write(t.buf, p, n)
    for i in 1:n
        b = unsafe_load(p, i)
        (b == UInt8('\n') || b == UInt8('\r')) ? _tap_line!(t) : push!(t.partial, b)
    end
    return n
end
Base.write(t::LineTap, b::UInt8) = (unsafe_write(t, Ref(b), UInt(1)); 1)
Base.take!(t::LineTap) = (_tap_line!(t); take!(t.buf))

# Start `cmd` on `ch`: `(rc, why)`, with why read under the lock, beside the call that failed.
function _start(s::Session, ch, cmd::AbstractString; timeout::Real = 60.0)
    deadline = time() + timeout
    while true
        rc, why = lock(s.lk) do
            rc = ccall((:libssh2_channel_process_startup, LIB), Cint,
                       (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cuint), ch, "exec", 4, cmd, sizeof(cmd))      # byte lengths, not characters
            (rc, (rc < 0 && rc != EAGAIN) ? _lasterr(s) : "")
        end
        rc != EAGAIN && return (rc, why)
        time() > deadline && return (rc, "no answer from the server")
        _ready(s, 5.0)
    end
end

# A channel with `cmd` started on it: `(ch, "")`, or `(C_NULL, why)`. A server at its limit of open
# sessions can refuse a channel or the command for a moment while others close, and libssh2 gives up
# on a reply that has not arrived yet (-1) when other channels are reading, so those are tried again
# on a fresh channel; a dead transport ends the session.
const _CHANNEL_REFUSED = (Cint(-1), Cint(-21), Cint(-22))   # not yet, LIBSSH2_ERROR_CHANNEL_FAILURE, _REQUEST_DENIED
function _open_started(s::Session, cmd::AbstractString; merge::Bool)
    why = ""
    for attempt in 1:3
        ch, err, why = _open_channel(s)
        if ch == C_NULL
            err in _TRANSPORT_ERRS && (_channel_dead!(s, why); return (C_NULL, why))
            attempt < 3 && (sleep(0.3 * attempt); continue)
            _report_refusal(s, why)
            _refused_with_none_open!(s, why)
            return (C_NULL, why)
        end
        # stderr arrives on the same stream as stdout, in the order it was written. Read separately,
        # it waits until stdout ends, which holds back a command's progress (Pkg reports on stderr).
        merge && _again(s, () -> ccall((:libssh2_channel_handle_extended_data2, LIB), Cint, (Ptr{Cvoid}, Cint),
                                       ch, EXTENDED_DATA_MERGE))
        rc, m = _start(s, ch, _as_sent(s, cmd))
        rc == 0 && (_note_open!(s, ch, cmd); return (ch, ""))
        lock(() -> _free_channel!(s, ch), s.lk)
        why = "exec: " * m * " (libssh2 $rc)"
        (attempt < 3 && rc in _CHANNEL_REFUSED) || return (C_NULL, why)
        sleep(0.3 * attempt)
    end
    return (C_NULL, why)
end

# A session that cannot open a CHANNEL is finished, whatever its `alive` flag still says. The
# transport can die quietly — the far end reboots, a NAT drops the flow, an idle timeout fires — and
# nothing tells us: the flag stays true, `connected` keeps reporting a healthy session, and every
# call after that fails identically at channel open. Recording it here is what lets the next
# `connect!` build a new one instead of handing back the corpse, which is otherwise only cleared by
# someone signing in by hand.
function _channel_dead!(s::Session, why::AbstractString)
    s.alive = false
    s.err = String(why)
    # Clearing the flag is not enough on its own: `session` reuses an entry whose OWNER task is
    # still running, which it is here — the task is serving a transport that no longer carries
    # anything. Drop the entry so the next caller builds a new one, exactly as `disconnect!` would.
    key = s.ep.alias
    dropped = lock(_REG_LOCK) do
        get(_SESSIONS, key, nothing) === s ? (delete!(_SESSIONS, key); true) : false
    end
    # Off this task: `_channel_dead!` runs ON the session's owner, and the drop listener reaches
    # back into the transport to discard what was riding the session. Announcing inline would have
    # the owner waiting on work only the owner can do.
    dropped && @async _announce_drop(key, true)
    return nothing
end

"""
Run `cmd` on the session's host: `(ok, output, how)`, with stdout and stderr interleaved; `online` gets
each line as it arrives. `how` says what became of the command: `:ok`, `:failed` (it exited non-zero),
`:not_started` (no channel, or the server refused the command, so it never ran and is safe to send
again), `:timed_out` or `:lost` (it started and its end was not seen, so it may still be running).
"""
function _exec(s::Session, cmd::AbstractString; timeout::Real = 120.0, online = nothing)
    ch, why = _open_started(s, cmd; merge = true)
    ch == C_NULL && return (false, why, :not_started)
    out = online === nothing ? IOBuffer() : LineTap(online)
    status = _finish(s, ch, out, out, timeout)
    text = String(take!(out))
    status == TIMED_OUT &&
        return (false, text * "\n[no end within $(round(Int, timeout))s; the command may still be running there]", :timed_out)
    status == LOST &&
        return (false, text * "\n[the connection failed before the command ended; it may still be running there]", :lost)
    return (status == 0, text, status == 0 ? :ok : :failed)
end

# Run `cmd`, streaming `input` to its stdin and collecting stdout. This is what replaces rsync: the
# metadata directories are small text files, so `tar` over the channel moves them in one round trip.
function _exec_io(s::Session, cmd::AbstractString, input::Union{Vector{UInt8},IO,Nothing};
                  timeout::Real = 300.0, sink::Union{IO,Nothing} = nothing)
    ch, why = _open_started(s, cmd; merge = false)
    ch == C_NULL && return (false, UInt8[], why)
    if input !== nothing
        # An `IO` is read a chunk at a time, so what is SENT never has to fit in memory. A project
        # directory is tarred to a temp file and handed over as a stream: the archive is already as
        # large as the tree, and holding a second copy of it as a byte vector is what turned a big
        # project into an out-of-memory failure rather than a slow transfer.
        deadline = time() + timeout
        buf = input isa IO ? Vector{UInt8}(undef, 256 * 1024) : input
        while true
            n = if input isa IO
                eof(input) ? 0 : readbytes!(input, buf)
            else
                length(buf)                       # a plain vector is one pass
            end
            n == 0 && break
            off = 0
            while off < n
                w = lock(() -> ccall((:libssh2_channel_write_ex, LIB), Cssize_t,
                                     (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                                     ch, 0, pointer(buf, off + 1), n - off), s.lk)
                if w == Cssize_t(EAGAIN)
                    (time() > deadline || !s.alive) && @goto sent
                    _ready(s, 5.0); continue
                end
                w < 0 && @goto sent
                off += Int(w)
            end
            input isa IO || break                 # the vector case wrote it all
        end
        @label sent
        _again(s, () -> ccall((:libssh2_channel_send_eof, LIB), Cint, (Ptr{Cvoid},), ch); timeout = 10.0)
    end
    # With a `sink`, stdout goes there as it arrives (a file, for bulk data) and none of it is kept.
    out = sink === nothing ? IOBuffer() : sink; err = IOBuffer()
    status = _finish(s, ch, out, err, timeout)
    why = String(take!(err))
    status == TIMED_OUT && (why *= "\n[no end within $(round(Int, timeout))s, or its reader stopped]")
    status == LOST && (why *= "\n[the connection failed before the command ended]")
    return (status == 0, sink === nothing ? take!(out) : UInt8[], why)
end

# ── port forwarding ──────────────────────────────────────────────────────────────────────────
# `direct_tcpip` replaces `ssh -N -L`. The forward rides the session that is already authenticated,
# so it costs no second prompt — and because the far side resolves the target host, a login node
# can carry a connection to a compute node without one either.

_open_tcpip(s::Session, host::AbstractString, port::Integer) = lock(s.openlk) do
    _again_ptr(s, () -> ccall((:libssh2_channel_direct_tcpip_ex, LIB), Ptr{Cvoid},
                              (Ptr{Cvoid}, Cstring, Cint, Cstring, Cint),
                              s.ptr, host, Cint(port), "127.0.0.1", Cint(22)); timeout = 15.0)
end

# Whether the far side accepts a connection to `host:port` now: a channel opened and closed at once.
# A port nobody listens on fails the open straight away, so this answers in one round trip and tells
# a booting worker from a ready one, which the local end of a forward cannot (it always accepts).
# Under `openlk` like every other open: libssh2 keeps a half-opened channel on the session, and this
# runs on a task of its own beside the commands, so a probe of a port nobody listens on interleaved
# with a command's open hands that command the probe's "connect failed", and can leave the session's
# open state stuck so that it refuses every command after.
function _reach(s::Session, host::AbstractString, port::Integer)
    ch, why = lock(s.openlk) do
        c = _again_ptr(s, () -> ccall((:libssh2_channel_direct_tcpip_ex, LIB), Ptr{Cvoid},
                                      (Ptr{Cvoid}, Cstring, Cint, Cstring, Cint),
                                      s.ptr, host, Cint(port), "127.0.0.1", Cint(22)); timeout = 5.0)
        (c, c == C_NULL ? s.openmsg : "")
    end
    ch == C_NULL && return (false, why)
    _again(s, () -> ccall((:libssh2_channel_close, LIB), Cint, (Ptr{Cvoid},), ch); timeout = 5.0)
    lock(() -> _free_channel!(s, ch), s.lk)
    return (true, "")
end

function _close_conn!(s::Session, c::Conn)
    c.closed = true
    try; close(c.tosock); catch; end
    try; close(c.sock); catch; end
    _free_channel!(s, c.ch)          # under s.lk, as every caller holds it
    c.ch = C_NULL
    return nothing
end

# How long a forwarded connection may fail to accept a single byte before it counts as dead. A
# compute node reclaimed at its walltime leaves a tunnel whose far end no longer exists and whose
# window never reopens; without a bound the pump waits on it for as long as the hub runs.
const FWD_STALL_S = 20.0

# Bytes queued for a connection's local writer past which the pump stops reading its channel, so the
# far side waits rather than the queue growing. A connection whose queue still reaches four times this
# is dropped as dead (`_pump_forwards!`).
const _TOSOCK_HIGH = 16 * 1024 * 1024

# Move whatever is ready, in both directions. Runs on the session's pump task (`_pump_loop`), never
# under a command. libssh2 is called under the session lock; bytes for a local socket are written
# after it is released, so a local reader that falls behind slows only its own connection's turn.
# Returns whether anything moved.
function _pump_forwards!(s::Session, buf::Vector{UInt8} = Vector{UInt8}(undef, PUMP_READ_BYTES))
    deliver = Tuple{Conn,Vector{UInt8}}[]
    ended = Conn[]                  # the far side finished: write what it sent, then close
    moved = false
    lock(s.lk) do
        _reap_dying!(s)
        isempty(s.fwds) && return
        for f in s.fwds, c in f.conns
            (c.closed || c.ch == C_NULL) && continue
            # local → remote. Whatever the far side will not take now stays in `outbox` for the next
            # sweep, and a window shut for longer than `FWD_STALL_S` ends the connection.
            while !c.closed && (!isempty(c.outbox) || isready(c.inbox))
                if isempty(c.outbox)
                    data = take!(c.inbox)
                    if isempty(data); _close_conn!(s, c); break; end
                    append!(c.outbox, data)
                end
                n = ccall((:libssh2_channel_write_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                          c.ch, 0, pointer(c.outbox), length(c.outbox))
                n < 0 && n != Cssize_t(EAGAIN) && (_close_conn!(s, c); break)
                if n <= 0                                    # EAGAIN, or accepted nothing
                    c.stalled == 0.0 && (c.stalled = time())
                    time() - c.stalled > FWD_STALL_S && _close_conn!(s, c)
                    break
                end
                deleteat!(c.outbox, 1:Int(n)); c.stalled = 0.0; moved = true
            end
            c.closed && continue
            # remote → local, collected here and written below. A connection whose local reader has
            # fallen behind is not read: its bytes wait inside libssh2, its window is not topped up,
            # and the far side stops sending until the reader catches up.
            queued = c.queued[]
            while queued < _TOSOCK_HIGH
                n = ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), c.ch, 0, buf, length(buf))
                n == Cssize_t(EAGAIN) && break
                if n <= 0
                    # End of the far side's stream, however libssh2 reports it. What it sent before is
                    # still to be written, so the channel goes and the connection stays until its
                    # writer has written all of it. Any other failure ends the connection now.
                    if ccall((:libssh2_channel_eof, LIB), Cint, (Ptr{Cvoid},), c.ch) == 1
                        _free_channel!(s, c.ch)
                        c.ch = C_NULL
                        push!(ended, c); moved = true
                    elseif n < 0
                        _close_conn!(s, c)
                    end
                    break
                end
                push!(deliver, (c, buf[1:Int(n)])); moved = true
                queued += Int(n)
            end
        end
        for f in s.fwds
            filter!(c -> !c.closed, f.conns)
        end
    end
    for (c, bytes) in deliver
        c.closed && continue
        # Handed to the connection's writer: a local reader that falls behind holds up only its own
        # connection. One that stops altogether fills its queue, and the connection is closed.
        if c.queued[] < 4 * _TOSOCK_HIGH
            Threads.atomic_add!(c.queued, length(bytes))
            try; put!(c.tosock, bytes); catch; end      # closed meanwhile
        else
            lock(() -> _close_conn!(s, c), s.lk)
        end
    end
    # No more is coming: the writer writes what is queued, then closes the connection.
    for c in ended
        try; close(c.tosock); catch; end
    end
    return moved
end

# The session's pump: gives accepted sockets their channels and moves tunnel bytes, for as long as
# the session is open. It runs pass after pass while bytes move, then waits for something to happen
# (`kick`). The timeout is only a backstop: a timer cannot be the pace, because a short sleep lasts
# milliseconds and a tunnel's rate would be bounded by it.
function _pump_loop(s::Session)
    watcher = s.watcher = errormonitor(Threads.@spawn _watch_socket(s))
    buf = Vector{UInt8}(undef, PUMP_READ_BYTES)     # reused: each read is copied before delivery
    while s.ptr != C_NULL && s.alive
        moved = false
        try
            while isready(s.pending)
                f, sock = take!(s.pending)
                # Its own task: opening the channel can take up to its 15 s timeout when the target is
                # gone, and the pump keeps moving every other connection meanwhile.
                s.alive ? Threads.@spawn(_attach_conn!(s, f, sock)) : (try; close(sock); catch; end)
            end
            moved = _pump_forwards!(s, buf)
        catch
        end
        notify(s.pumped)
        if moved
            yield()
        else
            _wait_event(s.kick, s.ntun[] == 0 ? 1.0 : 0.05)
        end
    end
    notify(s.pumped)
    try; wait(watcher); catch; end
    return nothing
end

# Wake the pump when the session's socket has something for libssh2: bytes from the far side, or room
# to write again. Each wake waits for the pump's next pass, since the socket stays readable until
# libssh2 takes the bytes and polling it again before then would only spin.
function _watch_socket(s::Session)
    while s.alive
        # No tunnels: commands wait on the socket themselves (`_ready`), so there is nothing to do.
        s.ntun[] == 0 && (sleep(0.25); continue)
        fd, dir = lock(s.lk) do
            s.ptr == C_NULL ? (Cint(-1), Cint(0)) :
                (s.fd, ccall((:libssh2_session_block_directions, LIB), Cint, (Ptr{Cvoid},), s.ptr))
        end
        fd < 0 && break
        ev = try
            FileWatching.poll_fd(RawFD(fd), 0.25; readable = true, writable = (dir & DIR_OUTBOUND) != 0)
        catch
            sleep(0.05); continue
        end
        if (ev.readable || ev.writable) && s.alive
            _kick!(s)
            _wait_event(s.pumped, 0.05)
        end
    end
    return nothing
end

# Accept on the local port. The channel is opened by the pump (`_pump_loop`), so the listener only
# hands over the socket.
function _add_forward!(s::Session, localport::Integer, host::AbstractString, port::Integer)
    l = try
        Sockets.listen(Sockets.localhost, Int(localport))
    catch e
        return (false, "cannot listen on $localport: $(sprint(showerror, e))")
    end
    f = Fwd(Int(localport), String(host), Int(port), l, Conn[])
    lock(() -> (push!(s.fwds, f); s.ntun[] = length(s.fwds)), s.lk)
    Threads.@spawn begin
        while isopen(l)
            sock = try; Sockets.accept(l); catch; break; end
            put!(s.pending, (f, sock))
            _kick!(s)
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
    c = Conn(sock, ch, Channel{Vector{UInt8}}(64), false, UInt8[], 0.0, Channel{Vector{UInt8}}(Inf),
             Threads.Atomic{Int}(0))
    lock(() -> push!(f.conns, c), s.lk)
    _kick!(s)                                       # the far side may already have bytes for it
    Threads.@spawn begin
        # Until the queue is closed and empty: closed with bytes still in it when the far side has
        # finished, so all of them are written before the socket goes.
        for bytes in c.tosock
            c.closed && break
            try; write(c.sock, bytes); catch; break; end
            Threads.atomic_sub!(c.queued, length(bytes))
            _kick!(s)                               # room again: the pump may have held back
        end
        lock(() -> _close_conn!(s, c), s.lk)
    end
    Threads.@spawn begin
        try
            while !eof(sock) && !c.closed
                put!(c.inbox, readavailable(sock))
                _kick!(s)
            end
        catch
        end
        try; put!(c.inbox, UInt8[]); catch; end     # empty frame = the local side hung up
        _kick!(s)
    end
    return nothing
end

function _drop_forward!(s::Session, localport::Integer)
    lock(s.lk) do
    for f in s.fwds
        f.localport == Int(localport) || continue
        try; close(f.listener); catch; end
        for c in f.conns; _close_conn!(s, c); end
    end
    filter!(f -> f.localport != Int(localport), s.fwds)
    s.ntun[] = length(s.fwds)
    end
    return nothing
end

function _close_forwards!(s::Session)
    lock(s.lk) do
        for f in s.fwds
            try; close(f.listener); catch; end
            for c in f.conns; _close_conn!(s, c); end
        end
        empty!(s.fwds)
        s.ntun[] = 0
    end
    return nothing
end

# A handshake that dies before any prompt means the server hung up. The commonest reason is its own
# brute-force protection — OpenSSH refuses a source for a while after repeated failed logins
# (`PerSourcePenalties`) and drops new connections past `MaxStartups` — so say that: the bare
# libssh2 code reads as a network fault and sends you looking at the wrong layer.
function _handshake_msg(s::Session, rc)
    return "$(s.ep.alias): the server closed the connection during the ssh handshake (libssh2 $rc). " *
           "If earlier logins were refused, it may be blocking this machine for a few minutes — " *
           "wait, then try again."
end

function _open!(s::Session, ask)
    _libssh2_init!()
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
    rc != 0 && error(_handshake_msg(s, rc))
    ms = auth_methods(s)
    if "publickey" in ms && (_try_agent(s) || _try_pubkey(s))
        # nothing more to do
    elseif s.bulk
        # A bulk connection is only worth having when it costs nobody anything: no prompt, and no
        # attempt spent on a host that counts them. The transfer uses the host's session instead.
        error("$(s.ep.alias): a bulk connection signs in by key only")
    elseif "keyboard-interactive" in ms
        # Discover the host's prompts only when we do not already remember them - from this run, or a
        # persisted earlier one. Discovery burns an authentication attempt on its OWN connection (it
        # sends no secret), and that extra connection is what makes the first sign-in of a fresh
        # process fail on a second-factor host. Remembering the prompts lets the common case, a
        # restart against a known host, answer on ONE connection, so the first click succeeds.
        discovered = false
        if isempty(remembered_prompts(s.ep.alias))
            _discover_prompts!(s) || error("$(s.ep.alias): the server asked nothing we could answer")
            _reconnect!(s); discovered = true
        end
        was = remembered_prompts(s.ep.alias)
        st = _try_kbdint(s, ask)
        if st === :rejected && !discovered
            # We answered from REMEMBERED prompts and the server refused their shape: they may be
            # stale, the host's auth reconfigured since we learned them. A dismissal does not reach
            # here, so cancelling the dialog leaves the remembered prompts intact.
            #
            # `_try_kbdint` records what the server asked THIS time, pass or fail. So when the shape
            # has changed under us, the corrected one is already in hand and the retry uses it:
            # discovery is another connection, and on a second-factor host another connection is
            # another code sent to the person waiting. Only when the shape came back unchanged is
            # there something left to learn, and then the stale list is dropped and rediscovered so
            # it can never wedge sign-in.
            if remembered_prompts(s.ep.alias) != was
                _reconnect!(s)
            else
                _forget_prompts!(s.ep.alias)
                _reconnect!(s)
                _discover_prompts!(s) || error("$(s.ep.alias): the server asked nothing we could answer")
                _reconnect!(s)
            end
            st = _try_kbdint(s, ask)
        end
        st === :ok || error("$(s.ep.alias): authentication was declined or cancelled")
    else
        error(isempty(ms) ? "$(s.ep.alias): no authentication method succeeded" :
              "$(s.ep.alias): could not authenticate (server offers " * join(ms, ", ") * ")")
    end
    _authed(s) || error("$(s.ep.alias): authentication did not complete")
    s.alive = true
    Base.acquire(() -> _note_login_shell!(s), s.slots)
    s.bulk || errormonitor(Threads.@spawn _announce_connect(s.ep.alias))
    # Which login node the session landed on (an address can be shared by several) and the pid of its sshd there:
    # where to look for what the session holds when the server refuses it a channel
    s.bulk || errormonitor(Threads.@spawn begin
        ok, out, _ = Base.acquire(() -> _exec(s, "hostname; echo \$PPID"; timeout = 15.0), s.slots)
        ok && @info "ssh: $(s.ep.alias) session on $(join(split(strip(out)), ", sshd pid "))"
    end)
    # Keep the session warm. Between runs a region holds nothing but an idle control session, and an
    # idle session dies to the server's own timeout or a NAT dropping the flow - after which the only
    # way back is an interactive second factor. Configuring an interval here and sending on a timer
    # (see `_keepalive_sweep`) resets those timers with no user action. `want_reply=0`: the outbound
    # request alone counts as activity for the server's idle clock and the NAT, and an idle session's
    # owner never reads the socket - so asking for a reply would only buffer answers nobody drains. A
    # peer that has actually gone still surfaces, at the next channel open (`_channel_dead!`).
    ccall((:libssh2_keepalive_config, LIB), Cvoid, (Ptr{Cvoid}, Cint, Cuint), s.ptr, 0, _keepalive_s())
    return s
end

# Start the connection over: a failed authentication leaves the session unusable, and discovery
# fails on purpose.
function _reconnect!(s::Session)
    s.ptr == C_NULL || ccall((:libssh2_session_free, LIB), Cint, (Ptr{Cvoid},), s.ptr)
    _forget_session_cmds!(s)
    s.fd >= 0 && ccall(:close, Cint, (Cint,), s.fd)
    s.fd = _tcp_connect(s.ep.hostname, s.ep.port)
    s.ptr = ccall((:libssh2_session_init_ex, LIB), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  C_NULL, C_NULL, C_NULL, pointer_from_objref(s.prompter))
    s.ptr == C_NULL && error("libssh2 session_init failed")
    ccall((:libssh2_session_set_blocking, LIB), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 0)
    rc = _again(s, () -> ccall((:libssh2_session_handshake, LIB), Cint,
                               (Ptr{Cvoid}, Cint), s.ptr, s.fd); timeout = 30.0)
    rc != 0 && error(_handshake_msg(s, rc))
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
    empty!(s.dying)                 # freed with the session
    _forget_session_cmds!(s)
    s.fd >= 0 && ccall(:close, Cint, (Cint,), s.fd)
    s.ptr = C_NULL; s.fd = Cint(-1)
    return nothing
end

# One owner task per session. It opens the session, starts its pump, and takes the requests in turn:
# a forward, an unforward or a keepalive it answers itself, a command it hands to a task of its own.
# libssh2 is not thread-safe, so every call on the session holds `s.lk`, for that call only.
function _serve(s::Session, ask)
    try
        _open!(s, ask)
    catch e
        s.err = sprint(showerror, e); s.alive = false
        # Hand the socket back. A connection left open is one the server holds until its login
        # grace expires, and a handful of those reaches MaxStartups — past which it drops new
        # connections before they can ask for a password at all.
        try; _close!(s); catch; end
    end
    pump = s.alive ? errormonitor(Threads.@spawn _pump_loop(s)) : nothing
    while true
        item = try; take!(s.req); catch; break; end
        kind, arg, reply = item
        # A keepalive is fire-and-forget: no reply is expected, and a failed send is not fatal (the
        # next sweep tries again, and a truly dead peer surfaces at the next channel open).
        if kind === :keepalive
            s.alive && (try; _keepalive_send(s); catch; end)
            continue
        end
        if !s.alive
            put!(reply, kind === :io ? (false, UInt8[], s.err) : (false, s.err))
            kind === :close && break
            continue
        end
        if kind === :exec || kind === :io || kind === :reach
            # Each command on a task of its own: it holds the session only for each libssh2 call, so a
            # command that runs long, or never ends, keeps the others waiting only for a free slot.
            Threads.atomic_add!(s.busy, 1)
            Threads.@spawn try
                put!(reply, try
                    Base.acquire(s.slots) do
                        kind === :io ? _exec_io(s, arg[1], arg[2]; timeout = arg[4], sink = arg[3]) :
                        kind === :reach ? _reach(s, arg[1], arg[2]) :
                        arg isa AbstractString ? _exec(s, arg) : _exec(s, arg.cmd; timeout = arg.timeout, online = arg.online)
                    end
                catch e
                    kind === :io ? (false, UInt8[], sprint(showerror, e)) :
                    kind === :exec ? (false, sprint(showerror, e), :lost) : (false, sprint(showerror, e))
                end)
            finally
                Threads.atomic_sub!(s.busy, 1)
            end
            continue
        end
        result = try
            kind === :forward ? _add_forward!(s, arg[1], arg[2], arg[3]) :
            kind === :unforward ? (_drop_forward!(s, arg); (true, "")) :
            kind === :close ? (_close_session!(s); (true, "")) :
            kind === :ready ? (true, "") :
            (false, "unknown request $kind")
        catch e
            (false, sprint(showerror, e))
        end
        put!(reply, result)
        kind === :close && break
    end
    # Whatever is still queued is answered, so no caller waits on a session that has gone; a request
    # sent after this fails at once (`_request` catches the closed queue).
    try; close(s.req); catch; end
    for (kind, _, reply) in s.req
        reply === nothing && continue
        try; put!(reply, kind === :io ? (false, UInt8[], "the session closed") : (false, "the session closed")); catch; end
    end
    _close_session!(s)
    pump === nothing || (try; wait(pump); catch; end)
    return nothing
end

# Close the session once the commands still running have finished or reached their own deadlines.
# Unconditional on the way out: a session that never came up still holds a socket.
function _close_session!(s::Session)
    s.alive = false                 # running commands stop at their next wait
    t0 = time()
    while s.busy[] > 0 && time() - t0 < 15.0
        sleep(0.05)
    end
    _close_forwards!(s)
    # The pump and its socket watcher see `alive` at their next turn; wake them, and let the watcher
    # stop before the socket is closed (its poll ends within a quarter second).
    notify(s.kick); notify(s.pumped)
    w = s.watcher
    w === nothing || timedwait(() -> istaskdone(w), 2.0)
    lock(() -> _close!(s), s.lk)
    return nothing
end

# ── Keepalive ────────────────────────────────────────────────────────────────────────────────────
# Seconds between keepalives. Chosen well under the idle timeouts that bite in practice - a login
# node's `ClientAliveInterval`, and the ~1-5 minute idle drop of a home or campus NAT - so a quiet
# session is refreshed several times before either could fire. Overridable for a host that wants it
# tighter or looser.
_keepalive_s() = Cuint(something(tryparse(Int, get(ENV, "KAIMONSLATE_SSH_KEEPALIVE_S", "")), 30))

# Send a keepalive if one is due (libssh2 tracks the interval set by `keepalive_config`). Non-blocking:
# an EAGAIN or any other return is left for the next sweep rather than waited on, so this never parks
# the owner task. Runs ONLY on the session's owner - the caller guarantees that.
function _keepalive_send(s::Session)
    secs = Ref{Cint}(0)
    lock(() -> ccall((:libssh2_keepalive_send, LIB), Cint, (Ptr{Cvoid}, Ptr{Cint}), s.ptr, secs), s.lk)
    return nothing
end

# One sweep for every session: enqueue a keepalive onto each live owner so the send runs where every
# other call on that session runs. Fire-and-forget with no reply channel; a session whose request
# queue is backed up is skipped rather than waited on, so a wedged owner cannot stall the sweep or
# the others. Started once, lazily, when the first session opens.
const _KEEPALIVE_STARTED = Ref(false)
function _keepalive_sweep()
    gap = max(3, Int(_keepalive_s()) ÷ 3)     # ping often enough that each session is refreshed on time
    while true
        try
            sleep(gap)
            snapshot = lock(_REG_LOCK) do; collect(values(_SESSIONS)); end
            for s in snapshot
                (s.alive && s.owner !== nothing && !istaskdone(s.owner)) || continue
                # A real request already queued resets the timers just as well, and a backed-up queue
                # means the owner is busy - either way, do not pile another item on.
                (isready(s.req) || Base.n_avail(s.req) >= 4) && continue
                try; put!(s.req, (:keepalive, nothing, nothing)); catch; end
            end
        catch
            # A sweep must outlive any single error - a transiently bad session must not end keepalives
            # for every other one.
        end
    end
end
_ensure_keepalive_sweep() = lock(_REG_LOCK) do
    _KEEPALIVE_STARTED[] && return
    _KEEPALIVE_STARTED[] = true
    errormonitor(Threads.@spawn _keepalive_sweep())
    return
end

"""
    session(host; ask) -> Session

The live session for `host`, opening one if needed. `ask(host, prompt, echo) -> String` supplies an
answer for each server prompt; returning `nothing` cancels.
"""
function session(host::AbstractString; ask)
    _ensure_keepalive_sweep()      # idempotent; the sweep exists for the life of the process once any session has
    key = String(host)
    replaced = Ref(false)
    dead = Ref{Union{Session,Nothing}}(nothing)
    s = lock(_REG_LOCK) do
        s = get(_SESSIONS, key, nothing)
        # Alive, or still opening. `alive` is only set once authentication has finished, and on a
        # host that asks for a second factor that takes as long as a person takes to answer — so a
        # request arriving in that window must QUEUE on the session being opened, not start a second
        # one. Replacing it orphans a login the far side has already accepted, and asks the person
        # to answer a fresh set of prompts for a connection they just made.
        #
        # `isempty(s.err)` is what actually means "still opening": `_serve` catches a failed `_open!`
        # and then runs forever answering requests with that cached error, so its owner task is NEVER
        # `istaskdone`. Without this check every later call, non-interactive ones included, would
        # replay the first failure verbatim instead of trying again, with no way back short of an
        # interactive sign-in (which is the only caller that currently clears a session).
        if s !== nothing
            (s.alive || (isempty(s.err) && s.owner !== nothing && !istaskdone(s.owner))) && return s
            delete!(_SESSIONS, key); replaced[] = true
            s.owner !== nothing && !istaskdone(s.owner) && (dead[] = s)   # still looping on its own error - tell it to stop
        end
        ep = resolve(key)
        s = Session(ep, Cint(-1), C_NULL, Channel{Any}(32), nothing, Prompter(key), false, "", Fwd[])
        s.owner = Threads.@spawn _serve(s, ask)
        _SESSIONS[key] = s
        return s
    end
    # Outside the lock, same as `disconnect!`: a session left here would otherwise idle forever,
    # since only a `:close` request ever ends `_serve`'s loop. Fire-and-forget — the replacement
    # session above is already live, so nothing needs to wait on this one's own shutdown.
    if (o = dead[]) !== nothing
        o.prompter.cancelled = true
        try; put!(o.req, (:close, "", Channel{Any}(1))); catch; end
        try; close(o.req); catch; end
    end
    # On a task of its own: the listener takes the hub's locks, and a caller may hold one of them.
    replaced[] && errormonitor(Threads.@spawn _announce_drop(key, true))
    return s
end

function _request(host::AbstractString, kind::Symbol, arg, fail; ask)
    return _request_on(session(host; ask = ask), kind, arg, fail)
end

function _request_on(s::Session, kind::Symbol, arg, fail)
    reply = Channel{Any}(1)
    try
        put!(s.req, (kind, arg, reply))
    catch
        return fail
    end
    return take!(reply)
end

# ── Bulk transfers on connections of their own ──────────────────────────────────────────────
# The host's session is one TCP connection kept for hours, and TCP carries a connection's history:
# after a burst of loss the sender keeps its window small, and after each idle pause it starts again
# from that small window rather than growing quickly to the path's capacity, so bulk reads on an old
# session can run at a fraction of what a new connection on the same path gets. A large transfer
# therefore gets a connection of its own, opened for it and closed after it: a TCP handshake and a
# key sign-in, about a second. Hosts that need a prompt to sign in keep using the session.

"""
    _with_bulk(f, host) -> f(s) or `nothing`

Open a session to `host` for one transfer, signed in by key without prompting, and run `f(s)` on it;
closed when `f` returns. `nothing` when the host cannot be signed in to that way.
"""
function _with_bulk(f, host::AbstractString)
    ep = resolve(String(host))
    s = Session(ep, Cint(-1), C_NULL, Channel{Any}(32), nothing, Prompter(String(host)), false, "", Fwd[];
                bulk = true)
    s.owner = Threads.@spawn _serve(s, (_...) -> nothing)
    try
        # Answered once the sign-in has finished, either way.
        _request_on(s, :ready, nothing, (false, "the bulk session closed"))
        s.alive || return nothing
        return f(s)
    finally
        try; put!(s.req, (:close, "", Channel{Any}(1))); catch; end
    end
end

"""
    exec(host, cmd; ask, timeout = 120, online = nothing) -> (ok, output, how)

Run `cmd` on `host` over the shared session. A command still producing output at `timeout` seconds is
a failure. `online(line)` is called with each line as it arrives, on the session's task: keep it quick.
`how` is what became of the command (`_exec`): only a `:not_started` one is safe to send again.
"""
exec(host::AbstractString, cmd::AbstractString; ask, timeout::Real = 120.0, online = nothing) =
    _request(String(host), :exec,
             (timeout == 120.0 && online === nothing) ? String(cmd) :
                 (; cmd = String(cmd), timeout = Float64(timeout), online = online),
             (false, "session for $host is gone", :not_started); ask = ask)

"""
    exec_io(host, cmd, input; sink = nothing, timeout = 300, bulk = false) -> (ok, stdout::Vector{UInt8}, stderr::String)

Like `exec`, but streams `input` to the command's stdin and returns stdout as bytes. This is what
carries a tar archive in either direction without a second authenticated transport. With `sink`,
stdout is written there as it arrives and the returned bytes are empty: how bulk data reaches a file
without being held in memory. `bulk = true` runs it on a connection of its own (`_with_bulk`).
"""
function exec_io(host::AbstractString, cmd::AbstractString, input::Union{Vector{UInt8},IO,Nothing}; ask,
                 sink::Union{IO,Nothing} = nothing, timeout::Real = 300.0, bulk::Bool = false)
    arg = (String(cmd), input, sink, Float64(timeout))
    fail = (false, UInt8[], "session for $host is gone")
    if bulk
        # On a connection of its own (`_with_bulk`); the host's session only when none can be opened,
        # so a transfer that started there is never repeated here.
        r = _with_bulk(s -> _request_on(s, :io, arg, fail), host)
        r === nothing || return r
    end
    return _request(String(host), :io, arg, fail; ask = ask)
end

"""
    forward!(host, localport, target, targetport; ask) -> (ok, message)

Carry `localport` on this machine to `target:targetport` as the far side sees it, over the session
that is already authenticated. `target` is resolved THERE, so a login node can reach a compute node
without a second connection to authenticate.
"""
forward!(host::AbstractString, localport::Integer, target::AbstractString, targetport::Integer; ask) =
    _request(String(host), :forward, (Int(localport), String(target), Int(targetport)),
             (false, "session for $host is gone"); ask = ask)

"""
    reachable(host, target, port; ask) -> (ok, message)

Whether `target:port`, as `host` sees it, accepts a connection now: one channel opened and closed on
the session, with no command run.
"""
reachable(host::AbstractString, target::AbstractString, port::Integer; ask) =
    _request(String(host), :reach, (String(target), Int(port)),
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
    # Returns once the session's tasks have finished: a caller that exits next must not leave them
    # running into the process's teardown. Each wait is bounded, the announcement's included: it runs
    # on a task of its own because the listener takes the hub's locks, as in `session`.
    s.owner === nothing || timedwait(() -> istaskdone(s.owner), 10.0)
    t = errormonitor(Threads.@spawn _announce_drop(String(host)))
    timedwait(() -> istaskdone(t), 10.0)
    return true
end

# ── Announcing that a session went away ──────────────────────────────────────────────────────
# Every forward dies with the session that carried it, and what USES those forwards lives a layer up
# (the data channel caches a local port per worker). Nothing up there can DETECT this: a dead forward
# is indistinguishable from a healthy one until something sits on it for a full receive timeout and
# then reports a transfer failure that is really "the session was replaced". So the drop is told,
# not discovered — and it happens on the ordinary path, since signing in interactively clears a
# half-open session first.
const _ON_DROP = Ref{Any}(nothing)

"""
    on_drop!(f)

Call `f(host, died)` whenever a session for `host` is dropped or replaced, so callers can discard what
rode it. `died` is true when the transport failed under it, false when it was closed on purpose (a
sign-out, or an interactive sign-in clearing the old session first).
"""
on_drop!(f) = (_ON_DROP[] = f; nothing)

function _announce_drop(host::AbstractString, died::Bool = false)
    f = _ON_DROP[]
    f === nothing && return nothing
    try; f(String(host), died); catch; end     # a listener's failure must never break disconnecting
    return nothing
end

# Told whenever a session for a host is signed in, by whatever signed it in: a person at the padlock,
# a key sign-in in the background, or a command that reconnected on its own. What shows a host's
# sign-in state updates from it instead of waiting for something else to.
const _ON_CONNECT = Ref{Any}(nothing)

"Call `f(host)` whenever a session for `host` has signed in."
on_connect!(f) = (_ON_CONNECT[] = f; nothing)

function _announce_connect(host::AbstractString)
    f = _ON_CONNECT[]
    f === nothing && return nothing
    try; f(String(host)); catch; end
    return nothing
end

"Is there an authenticated session for `host` right now?"
connected(host::AbstractString) =
    lock(_REG_LOCK) do; (s = get(_SESSIONS, String(host), nothing)) !== nothing && s.alive; end

"""
    probe(host) -> (; reachable, methods, error)

What `host` will ask for, WITHOUT authenticating. The server names its methods right after the
handshake (`libssh2_userauth_list`), so this is the honest way to tell a host that lets you in on a
key from one that is going to want a password and a second factor — and it costs no authentication
attempt, which matters on a server that penalises failures.

Runs on its own throwaway session so it cannot disturb one that is open.
"""
function probe(host::AbstractString)
    key = String(host)
    connected(key) && return (; reachable = true, methods = ["already-authenticated"], error = "")
    ep = try; resolve(key); catch e; return (; reachable = false, methods = String[],
                                                error = first(sprint(showerror, e), 200)); end
    s = Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, Prompter(key), false, "", Fwd[])
    try
        _libssh2_init!()
        s.fd = _tcp_connect(ep.hostname, ep.port)
        s.ptr = ccall((:libssh2_session_init_ex, LIB), Ptr{Cvoid},
                      (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                      C_NULL, C_NULL, C_NULL, pointer_from_objref(s.prompter))
        s.ptr == C_NULL && error("libssh2 session_init failed")
        ccall((:libssh2_session_set_blocking, LIB), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 0)
        rc = _again(s, () -> ccall((:libssh2_session_handshake, LIB), Cint,
                                   (Ptr{Cvoid}, Cint), s.ptr, s.fd); timeout = 15.0)
        rc != 0 && error(_handshake_msg(s, rc))
        return (; reachable = true, methods = auth_methods(s), error = "")
    catch e
        return (; reachable = false, methods = String[], error = first(sprint(showerror, e), 200))
    finally
        try; _close!(s); catch; end
    end
end

"""
Is a login to `host` in flight — waiting on a handshake, or on someone answering a prompt? A login
that failed is not: its owner task goes on answering requests with the cached error (see `session`).
"""
opening(host::AbstractString) = lock(_REG_LOCK) do
    s = get(_SESSIONS, String(host), nothing)
    s !== nothing && !s.alive && isempty(s.err) && s.owner !== nothing && !istaskdone(s.owner)
end

"Every host with a live session."
hosts() = lock(_REG_LOCK) do; String[k for (k, s) in _SESSIONS if s.alive]; end

end # module SshTransport
