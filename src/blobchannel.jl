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
#   'H' <hex,hex,…>                  → reply: comma-joined hashes the server DOESN'T have (dedup).
#   'P' <64-hex><u8 last><chunk…>    → reply "ok"/"done"/"err:…" — single-frame put; chunks stream
#                                      into a tmp, sha256-verified on the last, atomic-renamed into
#                                      the CAS: a corrupt/truncated transfer never lands.
#   'p' <64-hex><u8 last> ‖ <chunk>  → same put, TWO frames: 66-byte header + a raw payload frame
#                                      (the sender may zero-copy it over an mmap).
#   'G' <64-hex>:<offset>:<len>      → PULL one chunk (the reverse direction). TWO reply frames:
#                                      "ok <total>" (or "err: …" alone) + the payload, sent
#                                      zero-copy over an mmap of the blob. RANGE-ADDRESSED — the
#                                      primitive a lazy/partial fetch would build on.
#   'M' <fullkey>\n<toml…>           → reply "ok" — manifest written; senders order it LAST so a
#                                      manifest can never reference blobs that aren't there yet.

import Mmap

# Bytes per REQ/REP round-trip on the blob channel. Bigger amortizes RTT (fat links); smaller
# bounds per-chunk exposure (thin links). `KAIMONSLATE_BLOB_CHUNK_MB` env → default 8 MiB, min 64 KB.
# (The hub has its own tunable `ReportEngine._blob_chunk`; this is the worker/standalone default.)
_default_blob_chunk() = max(65_536, round(Int, 2^20 *
    something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_CHUNK_MB", "")), 8.0)))

_is_zmq_timeout(Z, e) = (T = try; Z.TimeoutError; catch; nothing; end; T !== nothing && e isa T)

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
                      running::Ref{Bool} = Ref(true), on_ready = nothing)
    sock = ctx === nothing ? Z.Socket(Z.REP) : Z.Socket(ctx, Z.REP)
    configure! === nothing || configure!(sock)     # CURVE/ZAP applied by the caller BEFORE bind
    Z.bind(sock, "tcp://$host:$port")
    sock.rcvtimeo = 500                             # wake periodically to re-check `running`
    on_ready === nothing || on_ready()
    open_tmps = Dict{String,Tuple{IOStream,String}}()   # hash → (io, tmppath)
    # One put chunk (either framing): append to the blob's tmp; on the last chunk verify the sha
    # and atomically land it in the CAS.
    put_chunk! = function (h::String, last::Bool, writechunk!)
        io, tmp = get!(open_tmps, h) do
            bdir = joinpath(root, "blobs"); mkpath(bdir)
            t = tempname(bdir)
            (open(t, "w"), t)
        end
        writechunk!(io)
        last || return "ok"
        close(io); delete!(open_tmps, h)
        got = bytes2hex(open(MemoStore.SHA.sha256, tmp))
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
                elseif cmd == 'H'
                    hs = split(String(copy(data))[2:end], ","; keepempty = false)
                    join([h for h in hs if !MemoStore.has_blob(root, String(h))], ",")
                elseif cmd == 'p'
                    h = String(copy(data[2:65])); last = data[66] == 0x01
                    payload = length(frames) >= 2 ? frames[2] : Z.Message()
                    put_chunk!(h, last, io -> GC.@preserve payload begin
                        unsafe_write(io, pointer(payload), length(payload))
                    end)
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
                            mm = Mmap.mmap(p, Vector{UInt8}, sz) # Message(origin=mm,…) keeps it alive till sent
                            ("ok $sz", Z.Message(mm, pointer(mm) + off, n))
                        end
                    end
                elseif cmd == 'P'
                    d = copy(data)
                    h = String(d[2:65]); last = d[66] == 0x01
                    put_chunk!(h, last, io -> write(io, @view d[67:end]))
                elseif cmd == 'M'
                    s = String(copy(data))[2:end]
                    nl = findfirst('\n', s)
                    key = s[1:nl-1]
                    p = MemoStore.manifest_path(root, key)
                    mkpath(dirname(p))
                    tmp = p * ".tmp"; write(tmp, s[nl+1:end]); mv(tmp, p; force = true)
                    "ok"
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
                         timeout_ms::Integer = 20_000, on_progress = nothing)
    dest = MemoStore.blob_path(root, hash)
    isfile(dest) && return 0                              # dedup: already here — nothing moved
    sock = Z.Socket(Z.REQ)
    try
        sock.rcvtimeo = timeout_ms; sock.sndtimeo = timeout_ms
        configure! === nothing || configure!(sock)       # CURVE client applied BEFORE connect
        Z.connect(sock, "tcp://$ip:$port")
        mkpath(dirname(dest))
        tmp = tempname(dirname(dest))
        total = -1; off = 0
        open(tmp, "w") do io
            while total < 0 || off < total
                Z.send(sock, "G$(hash):$(off):$(chunk)")
                frames = Z.recv_multipart(sock)
                meta = String(copy(frames[1]))
                startswith(meta, "err") && error("pull $hash: $meta")
                total = parse(Int, split(meta)[2])
                total == 0 && break
                payload = frames[2]
                GC.@preserve payload unsafe_write(io, pointer(payload), length(payload))
                off += length(payload)
                on_progress === nothing || on_progress(off, total)
                length(payload) == 0 && off < total && error("pull $hash: empty chunk at $off/$total")
            end
        end
        got = bytes2hex(open(MemoStore.SHA.sha256, tmp))
        got == String(hash) || (rm(tmp; force = true); error("pull $hash: hash mismatch (got $got)"))
        mv(tmp, dest; force = true)
        return total < 0 ? 0 : total
    finally
        try; Z.close(sock); catch; end
    end
end
