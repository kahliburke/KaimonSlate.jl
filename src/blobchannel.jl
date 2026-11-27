# ── The blob data channel (the "third socket" — a worker's gate port + 2) ────────────────────
#
# Bulk content-addressed blobs move HERE so they can never head-of-line-block the control gate
# (a multi-GB Arrow shipment must not queue ahead of a cell result). This file is the transport
# in isolation — dependency-light (ZMQ + MemoStore + Mmap; all CURVE/ZAP config is INJECTED by the
# caller via `configure!` callbacks), so it is unit-tested directly over loopback exactly like
# `memostore.jl` (see test/test_blobchannel.jl). It shares the SAME wire protocol on both ends,
# kept in lockstep here.
#
# Two roles:
#   • `blob_server!`     — a `ZMQ.REP` server bound at `(host, port)` serving/receiving blobs from
#     its CAS `root`. PASSIVE: it only answers, never dials. Every worker runs one
#     (worker.jl `_blob_server!` is a thin wrapper that injects the gate's CURVE identity).
#   • `pull_blob_into!`  — a `ZMQ.REQ` client that pulls ONE content-addressed blob (ranged `G`
#     chunks) from a peer's blob server INTO a CAS `root`, sha-verified + atomically landed. This
#     is the direct worker→worker data leg (worker.jl `__slate_pull_blob`); the hub's own
#     `pull_blob!`/`push_blob!` (remote.jl) speak the identical protocol against the hub's CAS.
#
# Protocol v2: strict REQ/REP alternation (backpressure for free); commands are self-framed:
#   'V'                              → reply "2" — protocol version probe. A v1 server answers
#                                      "err: unknown cmd", telling a hub to stay on 'P' single-frame
#                                      puts (a multipart 'p' would EFSM-wedge it).
#   'C'                              → reply: comma-joined capability tokens this server understands.
#                                      New abilities are announced HERE rather than by bumping 'V',
#                                      whose reply senders compare for equality with "2" — a bump
#                                      would silently drop every existing sender to the v1 copy path.
#                                      An older server answers "err: unknown cmd", which reads as
#                                      "no capabilities" without a special case.
#   'H' <hex,hex,…>                  → reply: comma-joined hashes the server DOESN'T have (dedup).
#   'P' <64-hex><u8 flags><chunk…>   → reply "ok"/"done"/"err:…" — single-frame put; chunks stream
#                                      into a tmp, sha256-verified on the last, atomic-renamed into
#                                      the CAS: a corrupt/truncated transfer never lands.
#   'p' <64-hex><u8 flags> ‖ <chunk> → same put, TWO frames: 66-byte header + a raw payload frame
#                                      (the sender copies it straight from an mmap).
#
# Put flags (the byte after the hash) are a BITFIELD: 0x01 = last chunk, 0x02 = first chunk
# ("restart" capability). Older code wrote 0x00/0x01 and tested the byte with `== 0x01`, so the low
# bit keeps its old meaning and an old sender is read correctly. 0x02 exists because the wire
# otherwise gives a receiver no way to tell a CONTINUATION from a RESTART: a transfer that died
# mid-blob leaves a partial tmp, and the retry used to append to it and then fail sha verification
# for that hash forever. A sender only sets it after seeing "restart" in the 'C' reply, so a new
# sender never hands an old server a flag byte it would misread as "not last".
#   'G' <64-hex>:<offset>:<len>      → PULL one chunk (the reverse direction). TWO reply frames:
#                                      "ok <total>" (or "err: …" alone) + the payload, copied
#                                      from an mmap of the blob. RANGE-ADDRESSED — the
#                                      primitive a lazy/partial fetch would build on.
#   'M' <fullkey>\n<toml…>           → reply "ok" — manifest written; senders order it LAST so a
#                                      manifest can never reference blobs that aren't there yet.

import Mmap

# Bytes per REQ/REP round-trip on the blob channel. Bigger amortizes RTT (fat links); smaller
# bounds per-chunk exposure (thin links). `KAIMONSLATE_BLOB_CHUNK_MB` env → default 8 MiB, min 64 KB.
# (The hub has its own tunable `ReportEngine._blob_chunk`; this is the worker/standalone default.)
_default_blob_chunk() = max(65_536, round(Int, 2^20 *
    something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_CHUNK_MB", "")), 8.0)))

# A payload frame in a buffer libzmq owns. Never use the zero-copy `Message(origin, ptr, n)`:
# libzmq frees it by calling a Julia @cfunction on its own I/O thread, Julia adopts that thread,
# and it blocks every signal. From then on each profiler tick that reaches it waits out a
# one-second timeout, so a profile of the process collects almost nothing.
function _zmq_copy_message(Z, src::Ptr{UInt8}, n::Integer)
    m = Z.Message(n)
    GC.@preserve m unsafe_copyto!(pointer(m), src, n)
    m
end

_is_zmq_timeout(Z, e) =(T = try; Z.TimeoutError; catch; nothing; end; T !== nothing && e isa T)

# ── Who may connect: a ZAP handler (RFC 27) over the channel's own context ───────────────────────
const ZAP_ENDPOINT = "inproc://zeromq.zap.01"
const _ZMQ_ZAP_DOMAIN = 55
# A draft option in libzmq 4.3, present in ZeroMQ_jll's build: a handshake no ZAP handler answers is
# refused. Without it libzmq admits the client, so a handler that died would leave a channel encrypted
# but open to any key.
const _ZMQ_ZAP_ENFORCE_DOMAIN = 93

function _zsetopt(Z, sock, opt::Integer, v::Integer)
    rc = Z.lib.zmq_setsockopt(sock, Cint(opt), Ref{Cint}(v), sizeof(Cint))
    rc == 0 || error("zmq_setsockopt($opt) failed: errno $(Libc.errno())")
end
function _zsetopt(Z, sock, opt::Integer, s::AbstractString)
    bytes = codeunits(String(s))
    rc = GC.@preserve bytes Z.lib.zmq_setsockopt(sock, Cint(opt), pointer(bytes), length(bytes))
    rc == 0 || error("zmq_setsockopt($opt) failed: errno $(Libc.errno())")
end

"""
    blob_zap_domain!(Z, sock, domain)

Put CURVE server socket `sock` under the ZAP handler of its context, for `domain`, enforced: a
handshake the handler does not answer, or answers with anything but 200, is refused. Call before
`bind`, with [`blob_zap!`](@ref) bound on the same context.
"""
function blob_zap_domain!(Z, sock, domain::AbstractString)
    _zsetopt(Z, sock, _ZMQ_ZAP_DOMAIN, domain)
    _zsetopt(Z, sock, _ZMQ_ZAP_ENFORCE_DOMAIN, 1)
    return sock
end

"""
    blob_zap!(Z, ctx, allowed; running = Ref(true)) -> Task

Answer the CURVE handshakes on context `ctx`'s sockets: `allowed(key)` decides, `key` the client's
raw 32-byte long-term public key. Binds the context's ZAP endpoint at once (before the server socket
binds) and serves until `running[]` goes false or the context closes.
"""
function blob_zap!(Z, ctx, allowed; running::Ref{Bool} = Ref(true))
    zap = Z.Socket(ctx, Z.REP)
    Z.bind(zap, ZAP_ENDPOINT)
    zap.rcvtimeo = 250; zap.linger = 0
    return Threads.@spawn begin
        try
            while running[]
                frames = try
                    Z.recv_multipart(zap, Vector{UInt8})
                catch e
                    _is_zmq_timeout(Z, e) && continue
                    isopen(zap) || break            # the context closed under it
                    continue
                end
                try
                    # ZAP 1.0 CURVE request: [version, request_id, domain, address, identity,
                    # mechanism, credentials(= the client's 32-byte public key)].
                    ok = length(frames) >= 7 && length(frames[7]) == 32 && allowed(frames[7]) === true
                    Z.send_multipart(zap, Any["1.0", frames[2], ok ? "200" : "400", ok ? "OK" : "denied", "", ""])
                catch e
                    @debug "blob ZAP handler error" exception = e
                end
            end
        finally
            try; close(zap); catch; end
        end
    end
end

"""
    blob_server!(Z, host, port, root; ctx=nothing, configure!=nothing,
                 running=Ref(true), on_ready=nothing)

Bind a blob-channel `ZMQ.REP` server at `tcp://host:port` serving the CAS at `root` and service
requests until `running[]` goes false. `configure!(sock)` (optional) is applied BEFORE `bind` — the
caller uses it to make the socket a CURVE server + set the ZAP domain (so a shared ZAP handler's
allow-list gates who may connect); omit it for a plaintext channel. `on_ready()` fires once the
socket is bound (a test can then connect without racing the bind). `Z` is the ZMQ module.
"""
function blob_server!(Z, host::AbstractString, port::Integer, root::AbstractString;
                      ctx = nothing, configure! = nothing,
                      running::Ref{Bool} = Ref(true), on_ready = nothing, control_handler = nothing)
    sock = ctx === nothing ? Z.Socket(Z.REP) : Z.Socket(ctx, Z.REP)
    configure! === nothing || configure!(sock)     # CURVE/ZAP applied by the caller BEFORE bind
    Z.bind(sock, "tcp://$host:$port")
    sock.rcvtimeo = 500                             # wake periodically to re-check `running`
    sock.linger = 0                                 # release the bound port IMMEDIATELY on close — no lingering
                                                    # socket, so a fast worker respawn onto the SAME data_port
                                                    # doesn't hit "Address already in use" (the collision the
                                                    # blob-bind retry in worker.jl backstops; this removes its cause)
    on_ready === nothing || on_ready()
    open_tmps = Dict{String,Tuple{IOStream,String}}()   # hash → (io, tmppath)
    # One put chunk (either framing): append to the blob's tmp; on the last chunk verify the sha
    # and atomically land it in the CAS.
    put_chunk! = function (h::String, last::Bool, writechunk!; first::Bool = false)
        # Content-addressed: a blob already in the CAS is BY DEFINITION the bytes being offered, so a
        # re-push (a sender that retried after the land, or two senders racing the same content) is
        # answered without opening a tmp. Without this the second sender appends to a fresh tmp,
        # re-lands identical bytes, and pays the whole transfer to do it.
        MemoStore.has_blob(root, h) && return last ? "done" : "ok"
        # A first chunk means the sender is starting this blob over, so whatever is half-written under
        # this hash is from an abandoned attempt. Drop it: appending to it is what made a retried
        # transfer fail sha verification every time from then on.
        if first
            prev = pop!(open_tmps, h, nothing)
            if prev !== nothing
                try; close(prev[1]); catch; end
                try; rm(prev[2]; force = true); catch; end
            end
        end
        io, tmp = get!(open_tmps, h) do
            bdir = joinpath(root, "blobs"); mkpath(bdir)
            t = tempname(bdir)
            (open(t, "w"), t)
        end
        writechunk!(io)
        last || return "ok"
        close(io); delete!(open_tmps, h)
        got = MemoStore.sha_file_hex(tmp)
        # A mismatch means the accumulated bytes are not `h` — most often a sender that restarted a
        # blob mid-flight, whose second attempt appended to this partial. Drop it so the NEXT attempt
        # starts from an empty tmp instead of failing forever on the same wreckage.
        got == h || (rm(tmp; force = true); return "err: hash mismatch (got $got)")
        dest = MemoStore.blob_path(root, h)
        mkpath(dirname(dest)); mv(tmp, dest; force = true)
        return "done"
    end
    try
        while running[]
            frames = try
                Z.recv_multipart(sock)             # Message frames — payload never copied here
            catch e
                _is_zmq_timeout(Z, e) && continue  # re-check `running`
                running[] || break
                continue
            end
            reply = try
                data = frames[1]
                cmd = Char(data[1])
                if cmd == 'V'
                    "2"
                elseif cmd == 'C'
                    "restart"          # understands the 0x02 first-chunk put flag
                elseif cmd == 'H'
                    hs = split(String(copy(data))[2:end], ","; keepempty = false)
                    join([h for h in hs if !MemoStore.has_blob(root, String(h))], ",")
                elseif cmd == 'p'
                    h = String(copy(data[2:65])); fl = data[66]
                    payload = length(frames) >= 2 ? frames[2] : Z.Message()
                    put_chunk!(h, (fl & 0x01) != 0x00, io -> GC.@preserve payload begin
                        unsafe_write(io, pointer(payload), length(payload))
                    end; first = (fl & 0x02) != 0x00)
                elseif cmd == 'G'
                    parts = split(String(copy(data))[2:end], ':')
                    h = String(parts[1])
                    off = length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
                    len = length(parts) >= 3 ? something(tryparse(Int, parts[3]), 0) : 0
                    p = MemoStore.blob_path(root, h)
                    if !isfile(p)
                        "err: no blob $h"
                    else
                        sz = filesize(p)
                        n = clamp(len <= 0 ? sz - off : min(len, sz - off), 0, sz - off)
                        if n <= 0 || sz == 0
                            ("ok $sz", Z.Message())              # empty tail (or zero-size blob)
                        else
                            mm = Mmap.mmap(p, Vector{UInt8}, sz)
                            ("ok $sz", GC.@preserve mm _zmq_copy_message(Z, pointer(mm) + off, n))
                        end
                    end
                elseif cmd == 'P'
                    d = copy(data)
                    h = String(d[2:65]); fl = d[66]
                    put_chunk!(h, (fl & 0x01) != 0x00, io -> write(io, @view d[67:end]);
                               first = (fl & 0x02) != 0x00)
                elseif cmd == 'M'
                    s = String(copy(data))[2:end]
                    nl = findfirst('\n', s)
                    key = s[1:nl-1]
                    p = MemoStore.manifest_path(root, key)
                    mkpath(dirname(p))
                    tmp = p * ".tmp"; write(tmp, s[nl+1:end]); mv(tmp, p; force = true)
                    "ok"
                elseif control_handler !== nothing
                    # Non-data verbs (transfer-control plane, e.g. X/S) → the injected handler, which must
                    # answer FAST (enqueue/lookup only — the actual transfer runs on a separate task) so the
                    # serve loop keeps servicing peers. Keeps this transport dep-light; logic lives upstream.
                    control_handler(cmd, copy(data))
                else
                    "err: unknown cmd"
                end
            catch e
                "err: " * first(split(sprint(showerror, e), '\n'))
            end
            # REP must always answer or the channel wedges. A Tuple reply = multipart ('G').
            try
                if reply isa Tuple
                    Z.send(sock, reply[1]; more = true)
                    Z.send(sock, reply[2])
                else
                    Z.send(sock, reply)
                end
            catch
            end
        end
    finally
        # A sender that vanished mid-blob leaves its tmp open. Nothing will ever finish it, so releasing
        # the handle and the partial file here is the difference between a bounded server and one that
        # accumulates open descriptors and half-blobs for as long as it runs.
        for (_, (io, tmp)) in open_tmps
            try; close(io); catch; end
            try; rm(tmp; force = true); catch; end
        end
        empty!(open_tmps)
        try; close(sock); catch; end
    end
    return nothing
end

"""
    pull_blob_into!(Z, ip, port, root, hash; configure!=nothing,
                    chunk=_default_blob_chunk(), timeout_ms=20_000, on_progress=nothing) -> Int

PULL the content-addressed blob `hash` from a peer's blob server at `tcp://ip:port` INTO the CAS at
`root`, over the ranged `G` protocol. `configure!(sock)` (optional) makes the REQ socket a CURVE
client pinned to the server's key BEFORE `connect` (omit for plaintext). Streams into a tmp,
sha-verifies against the address, atomic-renames — a truncated/corrupt transfer never lands. Dedup:
an already-present blob returns 0 without touching the network. Returns bytes moved over the wire.
"""
function pull_blob_into!(Z, ip::AbstractString, port::Integer, root::AbstractString, hash::AbstractString;
                         configure! = nothing, chunk::Integer = _default_blob_chunk(),
                         timeout_ms::Integer = 20_000, on_progress = nothing, stall_ms::Integer = 0)
    dest = MemoStore.blob_path(root, hash)
    isfile(dest) && return 0                              # dedup: already here — nothing moved
    # Stall detection (opt-in, stall_ms>0): a recv that times out with NO progress for `stall_ms` FAILS
    # FAST — a wedged link (e.g. an ssh forward stuck on a since-changed permitopen grant) otherwise burns
    # the whole `timeout_ms` before erroring. A timeout while bytes are still flowing instead RESETS the
    # REQ socket (a REQ can't re-send after a missed reply) and re-requests from `off` — the ranged `G`
    # protocol is stateless, so the resume is exact, and a transient hiccup on a slow link recovers rather
    # than aborting. stall_ms<=0 preserves the old single-budget behaviour (each recv waits `timeout_ms`).
    recvto = stall_ms > 0 ? min(Int(timeout_ms), Int(stall_ms)) : Int(timeout_ms)
    newsock = function ()
        s = Z.Socket(Z.REQ)
        s.rcvtimeo = recvto; s.sndtimeo = recvto
        configure! === nothing || configure!(s)          # CURVE client applied BEFORE connect
        Z.connect(s, "tcp://$ip:$port")
        s
    end
    sock = newsock()
    try
        mkpath(dirname(dest))
        tmp = tempname(dirname(dest))
        total = -1; off = 0
        open(tmp, "w") do io
            last_progress = time()
            while total < 0 || off < total
                Z.send(sock, "G$(hash):$(off):$(chunk)")
                frames = try
                    Z.recv_multipart(sock)
                catch e
                    (_is_zmq_timeout(Z, e) && stall_ms > 0) || rethrow()
                    (time() - last_progress) * 1000 >= stall_ms &&
                        error("pull $hash: no progress for $(round(Int, stall_ms / 1000))s at $off/$total (link stalled)")
                    try; Z.close(sock); catch; end        # transient timeout, progress was recent → reset + resume from off
                    sock = newsock()
                    continue
                end
                meta = String(copy(frames[1]))
                startswith(meta, "err") && error("pull $hash: $meta")
                total = parse(Int, split(meta)[2])
                total == 0 && break
                payload = frames[2]
                GC.@preserve payload unsafe_write(io, pointer(payload), length(payload))
                off += length(payload)
                last_progress = time()
                on_progress === nothing || on_progress(off, total)
                length(payload) == 0 && off < total && error("pull $hash: empty chunk at $off/$total")
            end
        end
        got = MemoStore.sha_file_hex(tmp)
        got == String(hash) || (rm(tmp; force = true); error("pull $hash: hash mismatch (got $got)"))
        mv(tmp, dest; force = true)
        return total < 0 ? 0 : total
    finally
        try; Z.close(sock); catch; end
    end
end
