# The durable memo STORE — a content-addressed blob layer + per-entry manifests. Pure: no
# namespace, no gate, no KaimonSlate deps (stdlib SHA/TOML only), so it's unit-tested directly
# (test/test_memostore.jl) and shared by the worker's memoization (worker.jl `_memo_store` /
# `_memo_restore`), which owns codecs (Serialization) and namespace assignment on top of it.
#
# Layout under one root (the worker's `_memo_dir()`):
#   blobs/sha256/<h[1:2]>/<h>   immutable content-addressed blobs (tmp + atomic rename; a
#                               re-put of existing content is a no-op ⇒ dedup across entries,
#                               cells, and notebooks for free)
#   manifests/<key>.toml        one entry per memo key: per-NAME blob refs {name, codec, blob,
#                               bytes} + the wire blob — small, human-readable, `ls`-able
#
# Why split identity (manifest) from content (blob): a key change with unchanged values (e.g. a
# src/ edit re-keys every entry) re-stores only ~1 KB manifests — every byte of data dedups; one
# undecodable value can be diagnosed BY NAME; a future consumer can fetch a single binding without
# the rest (region transfer); and immutable blobs make concurrent workers, rsync/NFS sharing, and
# post-transfer verification safe by construction. fmt 3 supersedes the fmt-2 monolithic
# `serialize((fmt, bindings, wire))` flat files — those are unreadable now and swept by `gc`.

module MemoStore

import SHA
import TOML
import Libdl

const FMT = 3

# ── Accelerated content hashing (SHA-NI via OpenSSL libcrypto; stdlib SHA.jl fallback) ────────────
# The CAS hashes every blob on write and re-verifies it on receive. Stdlib SHA.jl is pure-Julia
# (~120 MB/s) — the measured throughput wall for peer transfer. libcrypto's sha256 uses SHA-NI
# (~1.4 GB/s) and ships on essentially every host: we dlopen it once, self-test that its digest
# matches SHA.jl, and fall back to SHA.jl if it's absent or mismatched. The output is byte-identical
# either way, so content addresses NEVER change (no cache invalidation). Streamed over the file, so
# a multi-GB blob never spikes RSS. Kept dependency-pure (Libdl + a runtime dlopen, no new package).
struct _Evp
    md::Ptr{Cvoid}; ctxnew::Ptr{Cvoid}; init::Ptr{Cvoid}; update::Ptr{Cvoid}; final::Ptr{Cvoid}; free::Ptr{Cvoid}
end
function _evp_digest(ev::_Evp, p::Ptr{UInt8}, n::Integer)   # one-shot, for the self-test
    h = ccall(ev.ctxnew, Ptr{Cvoid}, ())
    ccall(ev.init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), h, ev.md, C_NULL)
    ccall(ev.update, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, p, n)
    out = Vector{UInt8}(undef, 32); nout = Ref{Cuint}(0)
    ccall(ev.final, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cuint}), h, out, nout)
    ccall(ev.free, Cvoid, (Ptr{Cvoid},), h)
    return out
end
const _LIBCRYPTO = Ref{String}("")   # explicit path (e.g. OpenSSL_jll.libcrypto) — tried FIRST

"""
    set_libcrypto!(path)

Register an explicit libcrypto path — tried before the system names so a vendored, version-pinned
lib (OpenSSL_jll) wins over whatever the host happens to ship. The worker calls this at startup;
clears the cached backend so the next hash re-probes.
"""
set_libcrypto!(path::AbstractString) = (_LIBCRYPTO[] = String(path); _EVP[] = missing; nothing)

function _load_evp()
    names = String[]
    isempty(_LIBCRYPTO[]) || push!(names, _LIBCRYPTO[])
    append!(names, ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so",
                    "libcrypto.3.dylib", "libcrypto.1.1.dylib", "libcrypto.dylib", "libcrypto"])
    for name in names
        try
            lib = Libdl.dlopen(name; throw_error = false); lib === nothing && continue
            s(nm) = Libdl.dlsym(lib, nm; throw_error = false)
            shafn, cn, ini, upd, fin, fr = s(:EVP_sha256), s(:EVP_MD_CTX_new), s(:EVP_DigestInit_ex),
                                           s(:EVP_DigestUpdate), s(:EVP_DigestFinal_ex), s(:EVP_MD_CTX_free)
            any(==(C_NULL), (shafn, cn, ini, upd, fin, fr)) && continue
            md = ccall(shafn, Ptr{Cvoid}, ()); md == C_NULL && continue
            ev = _Evp(md, cn, ini, upd, fin, fr)
            probe = codeunits("abc")
            ok = GC.@preserve probe (_evp_digest(ev, pointer(probe), length(probe)) == SHA.sha256(b"abc"))
            ok && return ev
        catch
        end
    end
    return nothing
end
const _EVP = Ref{Any}(missing)                     # missing = not yet probed; nothing = unavailable
_evp() = (b = _EVP[]; b === missing ? (_EVP[] = _load_evp()) : b)

"""
    sha_file_hex(path) -> hex::String

sha256 of a file's bytes, hex. SHA-NI-accelerated (OpenSSL libcrypto) when available, else stdlib
SHA.jl; identical output either way. Streamed in 1 MiB chunks — flat RSS on a multi-GB blob.
"""
function sha_file_hex(path::AbstractString)
    ev = _evp()
    open(path, "r") do io
        ev === nothing && return bytes2hex(SHA.sha256(io))
        buf = Vector{UInt8}(undef, 1 << 20)
        h = ccall(ev.ctxnew, Ptr{Cvoid}, ())
        ccall(ev.init, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), h, ev.md, C_NULL)
        while !eof(io)
            n = readbytes!(io, buf)
            GC.@preserve buf ccall(ev.update, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), h, pointer(buf), n)
        end
        out = Vector{UInt8}(undef, 32); nout = Ref{Cuint}(0)
        ccall(ev.final, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Cuint}), h, out, nout)
        ccall(ev.free, Cvoid, (Ptr{Cvoid},), h)
        bytes2hex(out)
    end
end

# Manifest keys become filenames — constrain to filename-safe (worker passes hex hashes).
const _VALID_KEY = r"^[A-Za-z0-9_-]{1,200}$"
_checkkey(key::AbstractString) =
    occursin(_VALID_KEY, key) || throw(ArgumentError("invalid memo key: $(repr(key))"))

# A blob NAME is a sha256 hex digest; anything else in a (corrupt) manifest must not join paths.
_validhash(h::AbstractString) = occursin(r"^[0-9a-f]{64}$", h)

blob_path(root::AbstractString, h::AbstractString) =
    joinpath(root, "blobs", "sha256", h[1:2], h)
manifest_path(root::AbstractString, key::AbstractString) =
    joinpath(root, "manifests", key * ".toml")

has_blob(root::AbstractString, h::AbstractString) = _validhash(h) && isfile(blob_path(root, h))

# Atomically write to `dest`: `f(io)` streams into a temp file in `dir`, which is then renamed over
# `dest` (rename is atomic on the same filesystem). On any failure the temp file is cleaned up and the
# error rethrown. (`put_blob` open-codes its own variant — its destination is content-derived and it
# dedups an already-present blob, so it can't name `dest` up front.)
function _atomic_write(f, dir::AbstractString, dest::AbstractString)
    tmp = tempname(dir)
    try
        open(f, tmp, "w")
        mv(tmp, dest; force = true)
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
    return nothing
end

"""
    put_blob(f, root) -> (sha256_hex, bytes)

Store the bytes `f(io)` writes, content-addressed. Streams through a temp file (no in-memory
buffer — a multi-GB binding must not spike RSS), hashes it, then atomically renames into place.
Content already present ⇒ the write is discarded (dedup) and the existing blob's mtime is
refreshed (it was just re-referenced — resets the `gc` grace clock). Rethrows whatever `f`
throws (e.g. an unserializable value), cleaning up the temp file.
"""
function put_blob(f, root::AbstractString)
    broot = joinpath(root, "blobs")
    mkpath(broot)
    tmp = tempname(broot)
    try
        open(f, tmp, "w")
        h = sha_file_hex(tmp)
        n = Int(filesize(tmp))
        dest = blob_path(root, h)
        if isfile(dest)
            try; touch(dest); catch; end
            rm(tmp; force = true)
        else
            mkpath(dirname(dest))
            mv(tmp, dest; force = true)
        end
        return (h, n)
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
end

"""
    with_blob(f, root, h) -> (found::Bool, value)

Open blob `h` and return `(true, f(io))`, or `(false, nothing)` when absent/invalid. The
explicit flag (not a `nothing` sentinel) because a legitimately stored value can BE `nothing`
(`x = nothing` is a cacheable binding).
"""
function with_blob(f, root::AbstractString, h::AbstractString)
    _validhash(h) || return (false, nothing)
    p = blob_path(root, h)
    isfile(p) || return (false, nothing)
    return (true, open(f, p, "r"))
end

"""
    write_manifest(root, key, manifest) -> nothing

Persist `manifest` (a TOML-representable Dict — the worker builds {bindings, wire, created,
julia, …}) atomically under `key`. `fmt` is stamped here; callers never version themselves.
"""
function write_manifest(root::AbstractString, key::AbstractString, manifest::AbstractDict)
    _checkkey(key)
    mdir = joinpath(root, "manifests")
    mkpath(mdir)
    d = Dict{String,Any}(String(k) => v for (k, v) in manifest)
    d["fmt"] = FMT
    _atomic_write(io -> TOML.print(io, d), mdir, manifest_path(root, key))
    return nothing
end

"Read + fmt-gate the manifest for `key`: a Dict, or `nothing` (absent, unparseable, or wrong fmt)."
function read_manifest(root::AbstractString, key::AbstractString)
    _checkkey(key)
    p = manifest_path(root, key)
    isfile(p) || return nothing
    d = try; TOML.parsefile(p); catch; return nothing; end
    get(d, "fmt", 0) == FMT || return nothing
    return d
end

"Mark `key` recently used (manifests are the LRU roots `gc` evicts oldest-first)."
touch_manifest(root::AbstractString, key::AbstractString) =
    (p = manifest_path(root, key); isfile(p) && try; touch(p); catch; end; nothing)

# Every blob hash a manifest references (bindings + wire) — the gc refcount edge set.
function _manifest_blobs(d::AbstractDict)
    hs = String[]
    for b in get(d, "bindings", Any[])
        b isa AbstractDict && push!(hs, String(get(b, "blob", "")))
    end
    w = get(d, "wire", nothing)
    w isa AbstractDict && push!(hs, String(get(w, "blob", "")))
    return filter(_validhash, hs)
end

# ── Scoped export: a SUBSET of the store, for embedding in a standalone `.jl` ─────────────────
# A self-contained notebook can carry the precomputed results for ITS OWN cells so they restore
# instantly on import — never the whole (potentially multi-GB) shared store. `pack` gathers the
# manifests for `keys` (fullkeys) plus every blob they reference (deduped) into one flat container
# — [pathlen:u32][relpath][len:u64][bytes], network byte order, the SAME wire as the bundle tree
# so it's dependency-free; the caller's footer layer gzips it. `unpack` merges it back into a
# store: content-addressed, so an already-present blob is skipped, and (since the archive rides an
# untrusted shared file) only the two known subtrees are written, no path escape. Missing entries
# or blobs are silently skipped — a since-gc'd value simply recomputes on the other side.
function pack(root::AbstractString, keys)
    io = IOBuffer(); seen = Set{String}()
    emit(rel, data) = (rb = Vector{UInt8}(rel);
                       write(io, hton(UInt32(length(rb))), rb, hton(UInt64(length(data))), data))
    for key in keys
        occursin(_VALID_KEY, key) || continue
        mp = manifest_path(root, key); isfile(mp) || continue
        emit("manifests/$key.toml", read(mp))
        d = read_manifest(root, key); d === nothing && continue
        for h in _manifest_blobs(d)
            (h in seen) && continue; push!(seen, h)
            bp = blob_path(root, h); isfile(bp) && emit("blobs/sha256/$(h[1:2])/$h", read(bp))
        end
    end
    return take!(io)
end

function unpack(root::AbstractString, data::AbstractVector{UInt8})
    io = IOBuffer(data)
    base = normpath(root); sep = Base.Filesystem.path_separator
    endswith(base, sep) || (base *= sep)
    n = 0
    while !eof(io)
        rel = String(read(io, ntoh(read(io, UInt32))))
        bytes = read(io, ntoh(read(io, UInt64)))
        (startswith(rel, "manifests/") || startswith(rel, "blobs/sha256/")) || continue   # known subtrees only
        out = normpath(joinpath(root, rel))
        startswith(out, base) || continue                                                 # no path escape
        (startswith(rel, "blobs/") && isfile(out)) && continue                            # content-addressed dedup
        mkpath(dirname(out)); try; write(out, bytes); n += 1; catch; end
    end
    return n
end

# One entry's on-disk footprint (its manifest + the blobs IT references — NOT deduped against
# other keys; the export UI's density ranking wants each entry's own cost). `key => bytes`.
function entry_bytes(root::AbstractString, key::AbstractString)
    occursin(_VALID_KEY, key) || return 0
    mp = manifest_path(root, key); isfile(mp) || return 0
    b = Int(filesize(mp))
    d = read_manifest(root, key); d === nothing && return b
    for h in _manifest_blobs(d)
        bp = blob_path(root, h); isfile(bp) && (b += Int(filesize(bp)))
    end
    return b
end

# ── Pins (the `locked` cell tag's durability guarantee) ────────────────────────────────────────
# A pinned key is exempt from `gc` regardless of age/cap — a small `pins.toml` set at the store
# root (NOT per-manifest, so pinning never touches/rewrites the manifest file itself). The set is
# tiny (one entry per locked cell across every notebook sharing this store) so a full read+rewrite
# on every pin/unpin is cheap and keeps the file atomic + trivially inspectable.
const _PINS_FILE = "pins.toml"
_pins_path(root::AbstractString) = joinpath(root, _PINS_FILE)
function _read_pins(root::AbstractString)::Set{String}
    p = _pins_path(root)
    isfile(p) || return Set{String}()
    d = try; TOML.parsefile(p); catch; return Set{String}(); end
    ks = get(d, "keys", nothing)
    return ks isa AbstractVector ? Set{String}(String(k) for k in ks) : Set{String}()
end

"""
    set_pin!(root, key, pin::Bool) -> nothing

Pin (`pin=true`) or release (`pin=false`) `key` against `gc` eviction. Idempotent.
"""
function set_pin!(root::AbstractString, key::AbstractString, pin::Bool)
    _checkkey(key)
    isdir(root) || mkpath(root)
    pins = _read_pins(root)
    pin ? push!(pins, key) : delete!(pins, key)
    _atomic_write(io -> TOML.print(io, Dict("keys" => sort!(collect(pins)))), root, _pins_path(root))
    return nothing
end

"Is `key` currently pinned?"
is_pinned(root::AbstractString, key::AbstractString) = key in _read_pins(root)

"Store shape/size: `(manifests, blobs, bytes)` — cheap enough for telemetry."
function stats(root::AbstractString)
    nm = 0; nb = 0; bytes = 0
    mdir = joinpath(root, "manifests"); bdir = joinpath(root, "blobs")
    isdir(mdir) && for f in readdir(mdir; join = true)
        isfile(f) && (nm += 1; bytes += filesize(f))
    end
    isdir(bdir) && for (r, _, fs) in walkdir(bdir), f in fs
        nb += 1; bytes += filesize(joinpath(r, f))
    end
    return (manifests = nm, blobs = nb, bytes = Int(bytes))
end

"""
    gc(root; cap, grace = 900.0) -> nothing

Bound the store to `cap` bytes. Manifests are the roots, evicted oldest-mtime-first (restore
touches its manifest, so mtime IS recency); a blob is deleted only once no surviving manifest
references it — a shared blob outlives any one entry's eviction. `grace` (seconds) protects
just-written blobs whose manifest hasn't landed yet: an unreferenced blob younger than it is
never deleted, so a concurrent worker mid-`put_blob`→`write_manifest` can't be raced. Legacy
fmt≤2 flat files at the root level (unreadable now) and stale temp litter are always swept.
A `set_pin!`ned key is NEVER evicted, regardless of age or cap (the `locked` cell tag's
durability guarantee) — pins can keep the store over `cap` indefinitely; that's the deliberate
trade (no silent cap violates the guarantee worse than an oversized store does). Best-effort
throughout: a vanished file (another worker's gc) is skipped, never an error.
"""
function gc(root::AbstractString; cap::Integer, grace::Real = 900.0)
    isdir(root) || return nothing
    now = time()
    total = 0
    pins = _read_pins(root)
    # Legacy fmt≤2 entries lived as flat files directly in `root` — no current code can read
    # them, so they're pure dead weight; sweep unconditionally.
    for f in readdir(root; join = true)
        isfile(f) && f != _pins_path(root) && try; rm(f; force = true); catch; end
    end
    # Inventory. Blobs live at blobs/sha256/<p>/<hash>; anything under blobs/ whose basename
    # isn't a digest is temp litter from a crashed `put_blob` — deletable past the grace window.
    mdir = joinpath(root, "manifests"); bdir = joinpath(root, "blobs")
    manifests = Tuple{String,Float64,Int}[]           # (path, mtime, size) — EVICTABLE (unpinned) only
    pinned_paths = String[]                            # pinned manifests: refcounted, never evicted
    isdir(mdir) && for f in readdir(mdir; join = true)
        isfile(f) || continue
        st = try; (Float64(mtime(f)), Int(filesize(f))); catch; continue; end
        total += st[2]
        if splitext(basename(f))[1] in pins
            push!(pinned_paths, f)
        else
            push!(manifests, (f, st[1], st[2]))
        end
    end
    blobinfo = Dict{String,Tuple{String,Float64,Int}}()   # hash → (path, mtime, size)
    isdir(bdir) && for (r, _, fs) in walkdir(bdir), name in fs
        p = joinpath(r, name)
        st = try; (Float64(mtime(p)), Int(filesize(p))); catch; continue; end
        if _validhash(name)
            blobinfo[name] = (p, st[1], st[2]); total += st[2]
        elseif now - st[1] > grace                    # crashed put_blob temp file
            try; rm(p; force = true); catch; end
        end
    end
    total <= cap && return nothing
    # Refcount blobs from EVERY surviving manifest, pinned or not (one parse pass, only on the
    # over-cap path) — a pinned entry's blobs must never look orphaned just because the manifest
    # itself is excluded from the eviction list below.
    refs = Dict{String,Int}()
    msets = Dict{String,Vector{String}}()             # manifest path → its blob hashes
    for p in Iterators.flatten((first.(manifests), pinned_paths))
        hs = (d = try; TOML.parsefile(p); catch; nothing; end) === nothing ? String[] : _manifest_blobs(d)
        msets[p] = hs
        for h in hs; refs[h] = get(refs, h, 0) + 1; end
    end
    droppable(h) = (get(refs, h, 0) <= 0 && haskey(blobinfo, h) && now - blobinfo[h][2] > grace)
    dropblob!(h) = (try; rm(blobinfo[h][1]; force = true); catch; end; total -= blobinfo[h][3];
                    delete!(blobinfo, h))
    # Orphans first (no manifest at all — crashed stores, prior partial gc), then LRU eviction.
    for h in collect(keys(blobinfo))
        droppable(h) && dropblob!(h)
    end
    sort!(manifests; by = m -> m[2])
    for (p, _, sz) in manifests
        total <= cap && break
        try; rm(p; force = true); catch; end
        total -= sz
        for h in msets[p]
            refs[h] = get(refs, h, 0) - 1
            droppable(h) && dropblob!(h)
        end
    end
    return nothing
end

end # module MemoStore
