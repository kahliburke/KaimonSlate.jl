# ── SSH as a library, not a subprocess ───────────────────────────────────────────────────────
#
# One authenticated session per host, held in this process, with a channel per command. SSH
# multiplexes channels natively, which is what `ControlMaster` was approximating — and it needs no
# Unix domain socket, so it works the same on every platform.
#
# It also puts authentication in the hub. A cluster wanting a password and a one-time code offers
# `keyboard-interactive`; libssh2 hands us the server's own prompts and takes our answers back, so
# nothing scripts a prompt or guesses how many there will be. Answers come from `ask`, which the
# caller wires to the browser dialog.
#
# WINDOWS: only `_tcp_connect` is platform-bound. Winsock wants `WSAStartup` and a `SOCKET` handle
# instead of an fd; that is the piece to add.
module SshTransport

import LibSSH2_jll
using Sockets: getaddrinfo, IPv4

const LIB = LibSSH2_jll.libssh2

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
    return fd
end

# ── keyboard-interactive ─────────────────────────────────────────────────────────────────────
struct KbdPrompt;   text::Ptr{UInt8}; length::Cuint; echo::Cuchar; end
struct KbdResponse; text::Ptr{UInt8}; length::Cuint; end

# The callback runs inside a libssh2 C call, so it must not touch Julia's scheduler: it publishes
# the prompt in plain fields and spins on a raw sleep. A normal task does the browser round-trip
# and drops the answer in. That split is the whole trick.
mutable struct Prompter
    host::String
    answers::Vector{String}
    seen::Vector{String}
    idx::Int              # prompts the callback has consumed
    want::Int             # index it is waiting on (0 = idle)
    text::String          # the prompt it is waiting on
    echo::Bool            # false ⇒ a secret; the dialog masks it
    cancelled::Bool
end
Prompter(host) = Prompter(String(host), String[], String[], 0, 0, "", false, false)

# Matches SshAuth.TIMEOUT; the callback cannot see that module, so the two are stated together here.
const PROMPT_TIMEOUT = 120.0

const _ACTIVE = Ref{Union{Prompter,Nothing}}(nothing)   # libssh2 gives the callback no user pointer we own
const _AUTH_LOCK = ReentrantLock()                      # …so one keyboard-interactive at a time

function _kbd_callback(_n::Ptr{UInt8}, _nl::Cint, _i::Ptr{UInt8}, _il::Cint,
                       n::Cint, prompts::Ptr{KbdPrompt},
                       responses::Ptr{KbdResponse}, _a::Ptr{Ptr{Cvoid}})::Cvoid
    pr = _ACTIVE[]
    pr === nothing && return nothing
    for k in 1:n
        p = unsafe_load(prompts, k)
        pr.idx += 1
        pr.text = p.length > 0 ? unsafe_string(p.text, p.length) : ""
        pr.echo = p.echo != 0
        push!(pr.seen, pr.text)
        pr.want = pr.idx
        ans = ""
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
mutable struct Session
    ep::Endpoint
    fd::Cint
    ptr::Ptr{Cvoid}
    req::Channel{Any}
    owner::Union{Task,Nothing}
    prompter::Prompter
    alive::Bool
    err::String
end

const _SESSIONS = Dict{String,Session}()
const _REG_LOCK = ReentrantLock()

_rc(s::Session) = ccall((:libssh2_session_last_errno, LIB), Cint, (Ptr{Cvoid},), s.ptr)
function _lasterr(s::Session)
    msg = Ref{Ptr{UInt8}}(C_NULL); len = Ref{Cint}(0)
    rc = ccall((:libssh2_session_last_error, LIB), Cint,
               (Ptr{Cvoid}, Ptr{Ptr{UInt8}}, Ptr{Cint}, Cint), s.ptr, msg, len, 0)
    msg[] == C_NULL ? "libssh2 error $rc" : unsafe_string(msg[], len[])
end

"Authentication methods the server offers, as it names them."
function auth_methods(s::Session)
    p = ccall((:libssh2_userauth_list, LIB), Cstring, (Ptr{Cvoid}, Cstring, Cuint),
              s.ptr, s.ep.user, length(s.ep.user))
    p == C_NULL ? String[] : String.(split(unsafe_string(p), ','))
end

_authed(s::Session) = ccall((:libssh2_userauth_authenticated, LIB), Cint, (Ptr{Cvoid},), s.ptr) == 1

function _try_pubkey(s::Session)
    for priv in s.ep.identities
        isfile(priv) || continue
        pub = priv * ".pub"
        rc = ccall((:libssh2_userauth_publickey_fromfile_ex, LIB), Cint,
                   (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cstring, Cstring),
                   s.ptr, s.ep.user, length(s.ep.user), isfile(pub) ? pub : C_NULL, priv, "")
        rc == 0 && return true
    end
    return false
end

function _try_kbdint(s::Session, ask)
    cb = @cfunction(_kbd_callback, Cvoid,
        (Ptr{UInt8}, Cint, Ptr{UInt8}, Cint, Cint, Ptr{KbdPrompt}, Ptr{KbdResponse}, Ptr{Ptr{Cvoid}}))
    return lock(_AUTH_LOCK) do
        pr = s.prompter
        _ACTIVE[] = pr
        # Feed the callback while it runs: it publishes a prompt, this answers it.
        pump = Threads.@spawn begin
            served = 0
            while served < 64 && !pr.cancelled
                if pr.want > served
                    a = try; ask(pr.host, pr.text, pr.echo); catch; nothing; end
                    a === nothing && (pr.cancelled = true; break)
                    push!(pr.answers, String(a)); served += 1
                else
                    sleep(0.05)
                end
            end
        end
        rc = ccall((:libssh2_userauth_keyboard_interactive_ex, LIB), Cint,
                   (Ptr{Cvoid}, Cstring, Cuint, Ptr{Cvoid}), s.ptr, s.ep.user, length(s.ep.user), cb)
        pr.cancelled = true          # release the pump whatever happened
        _ACTIVE[] = nothing
        rc == 0
    end
end

"Run `cmd` on the session's host. Returns `(ok, output)` with stdout and stderr interleaved."
function _exec(s::Session, cmd::AbstractString)
    ch = ccall((:libssh2_channel_open_ex, LIB), Ptr{Cvoid},
               (Ptr{Cvoid}, Cstring, Cuint, Cuint, Cuint, Cstring, Cuint),
               s.ptr, "session", 7, 2 * 1024 * 1024, 32768, C_NULL, 0)
    ch == C_NULL && return (false, "channel_open: " * _lasterr(s))
    try
        rc = ccall((:libssh2_channel_process_startup, LIB), Cint,
                   (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cuint), ch, "exec", 4, cmd, length(cmd))
        rc != 0 && return (false, "exec: " * _lasterr(s))
        out = IOBuffer(); buf = Vector{UInt8}(undef, 32768)
        for stream in (0, 1)                    # 0 = stdout, 1 = stderr
            while true
                n = ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), ch, stream, buf, length(buf))
                n <= 0 && break
                write(out, view(buf, 1:Int(n)))
            end
        end
        ccall((:libssh2_channel_close, LIB), Cint, (Ptr{Cvoid},), ch)
        status = ccall((:libssh2_channel_get_exit_status, LIB), Cint, (Ptr{Cvoid},), ch)
        return (status == 0, String(take!(out)))
    finally
        ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
    end
end

# Run `cmd`, streaming `input` to its stdin, and collect stdout. This is what replaces rsync: the
# metadata directories are small text files, so `tar` over the channel moves them in one round trip
# without needing a second authenticated transport.
function _exec_io(s::Session, cmd::AbstractString, input::Union{Vector{UInt8},Nothing})
    ch = ccall((:libssh2_channel_open_ex, LIB), Ptr{Cvoid},
               (Ptr{Cvoid}, Cstring, Cuint, Cuint, Cuint, Cstring, Cuint),
               s.ptr, "session", 7, 2 * 1024 * 1024, 32768, C_NULL, 0)
    ch == C_NULL && return (false, UInt8[], "channel_open: " * _lasterr(s))
    try
        rc = ccall((:libssh2_channel_process_startup, LIB), Cint,
                   (Ptr{Cvoid}, Cstring, Cuint, Cstring, Cuint), ch, "exec", 4, cmd, length(cmd))
        rc != 0 && return (false, UInt8[], "exec: " * _lasterr(s))
        if input !== nothing
            off = 0
            while off < length(input)
                n = ccall((:libssh2_channel_write_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                          ch, 0, pointer(input, off + 1), length(input) - off)
                n < 0 && return (false, UInt8[], "write: " * _lasterr(s))
                off += Int(n)
            end
            ccall((:libssh2_channel_send_eof, LIB), Cint, (Ptr{Cvoid},), ch)
        end
        out = IOBuffer(); err = IOBuffer(); buf = Vector{UInt8}(undef, 65536)
        for (stream, sink) in ((0, out), (1, err))
            while true
                n = ccall((:libssh2_channel_read_ex, LIB), Cssize_t,
                          (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t), ch, stream, buf, length(buf))
                n <= 0 && break
                write(sink, view(buf, 1:Int(n)))
            end
        end
        ccall((:libssh2_channel_close, LIB), Cint, (Ptr{Cvoid},), ch)
        status = ccall((:libssh2_channel_get_exit_status, LIB), Cint, (Ptr{Cvoid},), ch)
        return (status == 0, take!(out), String(take!(err)))
    finally
        ccall((:libssh2_channel_free, LIB), Cint, (Ptr{Cvoid},), ch)
    end
end

function _open!(s::Session, ask)
    ccall((:libssh2_init, LIB), Cint, (Cint,), 0)
    s.fd = _tcp_connect(s.ep.hostname, s.ep.port)
    s.ptr = ccall((:libssh2_session_init_ex, LIB), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), C_NULL, C_NULL, C_NULL, C_NULL)
    s.ptr == C_NULL && error("libssh2 session_init failed")
    ccall((:libssh2_session_set_blocking, LIB), Cvoid, (Ptr{Cvoid}, Cint), s.ptr, 1)
    rc = ccall((:libssh2_session_handshake, LIB), Cint, (Ptr{Cvoid}, Cint), s.ptr, s.fd)
    rc != 0 && error("ssh handshake with $(s.ep.hostname) failed ($rc)")
    ms = auth_methods(s)
    if "publickey" in ms && _try_pubkey(s)
        # nothing more to do
    elseif "keyboard-interactive" in ms && _try_kbdint(s, ask)
        # answered in the browser
    else
        error(isempty(ms) ? "$(s.ep.alias): no authentication method succeeded" :
              "$(s.ep.alias): could not authenticate (server offers " * join(ms, ", ") * ")")
    end
    _authed(s) || error("$(s.ep.alias): authentication did not complete")
    s.alive = true
    return s
end

function _close!(s::Session)
    s.alive = false
    s.ptr == C_NULL || ccall((:libssh2_session_disconnect_ex, LIB), Cint,
                             (Ptr{Cvoid}, Cint, Cstring, Cstring), s.ptr, 11, "closing", "")
    s.ptr == C_NULL || ccall((:libssh2_session_free, LIB), Cint, (Ptr{Cvoid},), s.ptr)
    s.fd >= 0 && ccall(:close, Cint, (Cint,), s.fd)
    s.ptr = C_NULL; s.fd = Cint(-1)
    return nothing
end

# One owner task per session: libssh2 sessions are not thread-safe, and the blocking API parks a
# thread. Callers post a request and wait for the reply, so nothing else in the hub is held up.
function _serve(s::Session, ask)
    try
        _open!(s, ask)
    catch e
        s.err = sprint(showerror, e); s.alive = false
    end
    for (kind, arg, reply) in s.req
        result = try
            !s.alive ? (false, s.err) :
            kind === :exec ? _exec(s, arg) :
            kind === :io ? _exec_io(s, arg[1], arg[2]) :
            kind === :close ? (_close!(s); (true, "")) :
            (false, "unknown request $kind")
        catch e
            (false, sprint(showerror, e))
        end
        put!(reply, result)
        kind === :close && break
    end
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
        s = Session(ep, Cint(-1), C_NULL, Channel{Any}(32), nothing, Prompter(key), false, "")
        s.owner = Threads.@spawn _serve(s, ask)
        _SESSIONS[key] = s
        return s
    end
end

"Run `cmd` on `host` over the shared session. `(ok, output)`."
function exec(host::AbstractString, cmd::AbstractString; ask)
    s = session(host; ask = ask)
    reply = Channel{Any}(1)
    try
        put!(s.req, (:exec, String(cmd), reply))
    catch
        return (false, "session for $host is gone")
    end
    return take!(reply)
end

"""
    exec_io(host, cmd, input) -> (ok, stdout::Vector{UInt8}, stderr::String)

Like `exec`, but streams `input` to the command's stdin and returns stdout as bytes. This is what
carries a tar archive in either direction without a second authenticated transport.
"""
function exec_io(host::AbstractString, cmd::AbstractString, input::Union{Vector{UInt8},Nothing}; ask)
    s = session(host; ask = ask)
    reply = Channel{Any}(1)
    try
        put!(s.req, (:io, (String(cmd), input), reply))
    catch
        return (false, UInt8[], "session for $host is gone")
    end
    return take!(reply)
end

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
