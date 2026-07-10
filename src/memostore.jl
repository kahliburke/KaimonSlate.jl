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

const FMT = 3

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
        h = bytes2hex(open(SHA.sha256, tmp))
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
    tmp = tempname(mdir)
    try
        open(io -> TOML.print(io, d), tmp, "w")
        mv(tmp, manifest_path(root, key); force = true)
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
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
Best-effort throughout: a vanished file (another worker's gc) is skipped, never an error.
"""
function gc(root::AbstractString; cap::Integer, grace::Real = 900.0)
    isdir(root) || return nothing
    now = time()
    total = 0
    # Legacy fmt≤2 entries lived as flat files directly in `root` — no current code can read
    # them, so they're pure dead weight; sweep unconditionally.
    for f in readdir(root; join = true)
        isfile(f) && try; rm(f; force = true); catch; end
    end
    # Inventory. Blobs live at blobs/sha256/<p>/<hash>; anything under blobs/ whose basename
    # isn't a digest is temp litter from a crashed `put_blob` — deletable past the grace window.
    mdir = joinpath(root, "manifests"); bdir = joinpath(root, "blobs")
    manifests = Tuple{String,Float64,Int}[]           # (path, mtime, size)
    isdir(mdir) && for f in readdir(mdir; join = true)
        isfile(f) || continue
        st = try; (Float64(mtime(f)), Int(filesize(f))); catch; continue; end
        push!(manifests, (f, st[1], st[2])); total += st[2]
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
    # Refcount blobs from the surviving manifests (one parse pass, only on the over-cap path).
    refs = Dict{String,Int}()
    msets = Dict{String,Vector{String}}()             # manifest path → its blob hashes
    for (p, _, _) in manifests
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
