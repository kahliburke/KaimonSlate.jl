# Notebook-facing value fingerprinting + memo-store introspection (engine + worker; included by
# widgets.jl so both namespaces inject the same helpers — see `_populate_notebook_ns!`).
#
# `slate_fingerprint` answers "is this the same VALUE?" across runs, sessions, and worker
# restarts — the question every cache-fidelity check, reproducibility assertion, and
# did-my-refactor-change-the-result cell wants. `hash(...)` can't serve it: Dict iteration order,
# session salts, and Julia-version drift all leak in. This is a canonical SHA-256 with `isequal`
# semantics: order-independent for Dicts/Sets, NaN ≡ NaN (bit-normalized), missing/nothing
# distinct, numeric widening so Int32(3) ≡ Int64(3).
#
# `slate_memo_stats` / `slate_memo_entries` expose the durable memo store (MemoStore CAS +
# manifests) READ-ONLY from notebook code — what's cached, under which names, how many bytes,
# how much dedup. Resolved dynamically through `Main.SlateWorker` at CALL time, so this file
# stays kernel-agnostic: in-process kernels (no durable store) return empties.

import SHA
import Serialization as _FPSerialization

const _FP_CANON_NAN = reinterpret(UInt64, NaN)   # one bit pattern for every NaN payload

_fp_bytes!(ctx, v::UInt8) = SHA.update!(ctx, UInt8[v])
_fp_bytes!(ctx, bs::AbstractVector{UInt8}) = SHA.update!(ctx, bs)
_fp_u64!(ctx, x::UInt64) = SHA.update!(ctx, reinterpret(UInt8, UInt64[x]))

# ── Array elements ───────────────────────────────────────────────────────────────
# An array is fingerprinted one element at a time, which for a numeric array costs a dynamic dispatch
# and a 9-byte write (a tag plus the value widened to UInt64) per element — around a second and a
# gigabyte of garbage for an 8 MB vector. That is paid by every memo check on a large array, not only
# by `save_asset`. For the element types whose encoding is fixed and known, the same bytes are written
# in chunks instead. The BYTES are identical, so fingerprints do not change and no memo is invalidated.
#
# Only the types that provably take one branch below qualify. `UInt64`/`Int128` are excluded because a
# value above `typemax(Int64)` falls through to the structured fallback, and `Bool` because it has its
# own tag. An abstract `eltype` (a `Vector{Any}` of numbers) takes the element loop, as it must.
const _FP_FAST_INT = Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32}
const _FP_FAST_FLOAT = Union{Float16,Float32,Float64}
const _FP_CHUNK = 8192                     # elements per flush → a 72 kB scratch buffer

# `_fp_u64!` writes the machine's native byte order, and this path exists to be indistinguishable from
# it — so it is taken only where "native" is the little-endian layout written below.
const _FP_FAST_ENDIAN = Base.ENDIAN_BOM == 0x04030201

@inline function _fp_put_u64!(buf::Vector{UInt8}, i::Int, u::UInt64)
    @inbounds for k in 0:7
        buf[i + k] = UInt8((u >> (8 * k)) & 0xff)
    end
end

function _fp_chunked!(ctx, x::AbstractArray, tag::UInt8, code::F) where {F}
    buf = Vector{UInt8}(undef, 9 * _FP_CHUNK)
    i, n = 1, 0
    for v in x
        @inbounds buf[i] = tag
        _fp_put_u64!(buf, i + 1, code(v))
        i += 9; n += 1
        if n == _FP_CHUNK
            _fp_bytes!(ctx, buf)
            i, n = 1, 0
        end
    end
    n == 0 || _fp_bytes!(ctx, buf[1:(9 * n)])
    return nothing
end

function _fp_elements!(ctx, x::AbstractArray)
    T = eltype(x)
    if _FP_FAST_ENDIAN && T <: _FP_FAST_INT
        _fp_chunked!(ctx, x, 0x04, v -> reinterpret(UInt64, Int64(v)))
    elseif _FP_FAST_ENDIAN && T <: _FP_FAST_FLOAT
        _fp_chunked!(ctx, x, 0x05, v -> isnan(v) ? _FP_CANON_NAN : reinterpret(UInt64, Float64(v)))
    else
        for v in x; _fp!(ctx, v); end
    end
    return nothing
end

function _fp!(ctx, x)
    if x === nothing
        _fp_bytes!(ctx, 0x00)
    elseif x === missing
        _fp_bytes!(ctx, 0x01)
    elseif x isa Bool
        _fp_bytes!(ctx, 0x02); _fp_bytes!(ctx, UInt8(x))
    elseif x isa BigInt
        _fp_bytes!(ctx, 0x03); _fp_bytes!(ctx, codeunits(string(x)))
    elseif x isa Integer && typemin(Int64) <= x <= typemax(Int64)
        _fp_bytes!(ctx, 0x04); _fp_u64!(ctx, reinterpret(UInt64, Int64(x)))   # widen: Int32(3) ≡ 3
    elseif x isa AbstractFloat
        b = reinterpret(UInt64, Float64(x))
        _fp_bytes!(ctx, 0x05); _fp_u64!(ctx, isnan(x) ? _FP_CANON_NAN : b)    # NaN ≡ NaN; -0.0 ≢ 0.0
    elseif x isa AbstractString
        _fp_bytes!(ctx, 0x06); _fp_u64!(ctx, UInt64(ncodeunits(x))); _fp_bytes!(ctx, codeunits(String(x)))
    elseif x isa Symbol
        _fp_bytes!(ctx, 0x07); _fp_bytes!(ctx, codeunits(String(x)))
    elseif x isa Char
        _fp_bytes!(ctx, 0x08); _fp_u64!(ctx, UInt64(codepoint(x)))
    elseif x isa Tuple
        _fp_bytes!(ctx, 0x09); _fp_u64!(ctx, UInt64(length(x)))
        for v in x; _fp!(ctx, v); end
    elseif x isa NamedTuple
        _fp_bytes!(ctx, 0x0a)
        for (k, v) in pairs(x); _fp!(ctx, k); _fp!(ctx, v); end
    elseif x isa Pair
        _fp_bytes!(ctx, 0x0b); _fp!(ctx, x.first); _fp!(ctx, x.second)
    elseif x isa AbstractDict
        _fp_bytes!(ctx, 0x0c); _fp_u64!(ctx, UInt64(length(x)))
        subs = sort!([_fp_digest((k, v)) for (k, v) in pairs(x)])   # order-independent
        for s in subs; _fp_bytes!(ctx, s); end
    elseif x isa AbstractSet
        _fp_bytes!(ctx, 0x0d); _fp_u64!(ctx, UInt64(length(x)))
        subs = sort!([_fp_digest(v) for v in x])
        for s in subs; _fp_bytes!(ctx, s); end
    elseif x isa AbstractArray
        _fp_bytes!(ctx, 0x0e); _fp_u64!(ctx, UInt64(ndims(x)))
        for d in size(x); _fp_u64!(ctx, UInt64(d)); end
        _fp_elements!(ctx, x)
    else
        # Structured fallback (DataFrames, Dates, user structs): canonical serialization bytes —
        # the SAME identity the memo store's content-addressed blobs use. Deterministic for data;
        # a value that won't serialize falls back to its repr.
        _fp_bytes!(ctx, 0x0f)
        bs = try
            io = IOBuffer(); _FPSerialization.serialize(io, x); take!(io)
        catch
            Vector{UInt8}(codeunits(repr(x)))
        end
        _fp_u64!(ctx, UInt64(length(bs))); _fp_bytes!(ctx, bs)
    end
    return nothing
end

function _fp_digest(x)::Vector{UInt8}
    ctx = SHA.SHA2_256_CTX()
    _fp!(ctx, x)
    return SHA.digest!(ctx)
end

"""
    slate_fingerprint(xs...) -> String

A canonical, session-stable content hash (SHA-256 hex) of the given value(s) — `isequal`-style
semantics: Dicts/Sets are order-independent, `NaN ≡ NaN`, integer widths widen, `missing` and
`nothing` are distinct. The robust way to assert a restored/recomputed/transferred value is REALLY
the same — unlike `hash`, which leaks Dict order and session state.
`slate_fingerprint(df, params)` in a cell gives one comparable line across runs, sessions, and
worker restarts.
"""
slate_fingerprint(xs...) = bytes2hex(_fp_digest(length(xs) == 1 ? xs[1] : xs))

# ── Durable memo-store introspection (read-only) ─────────────────────────────
_memostore_ctx() =
    (isdefined(Main, :SlateWorker) && isdefined(Main.SlateWorker, :MemoStore) &&
     Main.SlateWorker._MEMO_OK) ? (Main.SlateWorker.MemoStore, Main.SlateWorker._memo_dir()) : nothing

"""
    slate_memo_stats() -> (; manifests, blobs, bytes, root)

Shape of the durable memo store backing this notebook's `cache` tags: entry count, unique
content blobs (identical values dedup to one), total on-disk bytes, and the store root.
In-process kernels have no durable store — all zeros.
"""
function slate_memo_stats()
    ctx = _memostore_ctx()
    ctx === nothing && return (manifests = 0, blobs = 0, bytes = 0, root = "")
    MS, root = ctx
    s = MS.stats(root)
    return (manifests = s.manifests, blobs = s.blobs, bytes = s.bytes, root = root)
end

"""
    slate_memo_entries(; name = "") -> Vector{NamedTuple}

The durable memo store's entries, newest first — one row per cached cell result:
`(; key, names, bytes, blobs, created)` where `names` are the globals the entry restores and
`blobs` their content hashes (shared hash across rows = deduped storage). `name = "x"` filters
to entries carrying a binding named `x`. Return it from a cell (or wrap in `slate_table`) to
see exactly what a cold open will restore.
"""
function slate_memo_entries(; name::AbstractString = "")
    ctx = _memostore_ctx()
    ctx === nothing && return NamedTuple[]
    MS, root = ctx
    mdir = joinpath(root, "manifests")
    isdir(mdir) || return NamedTuple[]
    out = NamedTuple[]
    for f in sort!(filter(isfile, readdir(mdir; join = true)); by = mtime, rev = true)
        d = try; MS.TOML.parsefile(f); catch; continue; end
        get(d, "fmt", 0) == MS.FMT || continue
        binds = [b for b in get(d, "bindings", Any[]) if b isa AbstractDict]
        nms = String[String(get(b, "name", "")) for b in binds]
        isempty(name) || String(name) in nms || continue
        bytes = sum(Int(get(b, "bytes", 0)) for b in binds; init = 0)
        w = get(d, "wire", nothing)
        w isa AbstractDict && (bytes += Int(get(w, "bytes", 0)))
        elided = join((String(get(e, "name", "")) for e in get(d, "elided", Any[]) if e isa AbstractDict), ", ")
        push!(out, (key = replace(basename(f), r"\.toml$" => ""),
                    names = join(nms, ", "),
                    bytes = bytes,
                    blobs = join((first(String(get(b, "blob", "")), 8) for b in binds), ", "),
                    elided = elided,   # display objects stored as wire image only (see _memo_store)
                    created = Int(get(d, "created", 0))))
    end
    return out
end
