# Memo codecs — how a binding VALUE becomes blob BYTES (and back). The manifest's per-name
# `codec` field names one of these; "jls" (Serialization) is the universal fallback. The fast
# codecs exist for the multi-GB case, where JLS's slow object-graph walk turns
# "instant reopen" into minutes:
#   raw    isbits Arrays — a self-describing header + the raw bytes. When the graph
#          proves the binding is never mutated downstream (`zc`), restore MMAPs the immutable
#          CAS blob read-only: zero-copy, ~ms, no RSS. Else it materializes a copy (bulk
#          read, GB/s — still ≫ JLS).
#   arrow  DataFrame — PURE Arrow IPC file bytes, deliberately NO envelope: the blob mmaps
#          straight off disk (`Arrow.Table(path)`), zero-copy-sends over ZMQ
#          (zmq_msg_init_data wraps the mapped pages), and stays readable by duckdb/pyarrow.
#          Soft-detected (Arrow + DataFrames loaded in this process — the tables.jl
#          precedent); absent packages simply mean "jls" at store time and a clean miss →
#          recompute at restore time.
# Zero-copy safety: a read-only mmap makes a later mutation THROW (ReadOnlyMemoryError)
# rather than corrupt the CAS — the safe failure mode when the graph gained a mutating cell
# AFTER the entry was stored (the safe-set is store-time knowledge). One re-run of the
# producer re-stores the entry in copy mode.

import Mmap

# A loaded package by name, or nothing — soft detection, never a dependency.
function _codec_loaded(name::String)
    for (k, m) in Base.loaded_modules
        k.name == name && return m
    end
    return nothing
end

const _RAW_MAGIC = UInt32(0x534c5257)   # "SLRW" — v1, a fixed 64-byte header
const _RAW_MAGIC2 = UInt32(0x534c5232)  # "SLR2" — v2, the payload offset is written in the header
_rawable(v) = v isa Array && isbitstype(eltype(v)) && !isempty(v)

# The header is as long as it needs to be, padded to a multiple of this. v1 fixed it at 64 bytes,
# which meant an eltype whose printed name did not fit in what was left could not be written AT ALL
# — a `Vector` of six-field NamedTuples names itself in over a hundred characters and hit the wall.
# Padding to 64 keeps the payload aligned for any isbits element, which is what the zero-copy mmap
# restore needs.
const _RAW_ALIGN = 64
_raw_offset(v) = _RAW_ALIGN *
    cld(13 + 8 * ndims(v) + ncodeunits(string(eltype(v))), _RAW_ALIGN)

# `(dims, eltype-name, payload offset)`, reading either version. v1 blobs are still read: the CAS
# holds entries written before this, and a stored value that throws on restore is worse than one
# that is merely slow to produce.
function _raw_header(io::IO)
    magic = read(io, UInt32)
    if magic == _RAW_MAGIC2
        nd = Int(read(io, UInt8))
        tlen = Int(read(io, UInt32))
        off = Int(read(io, UInt32))
        dims = Int[read(io, Int64) for _ in 1:nd]
        return (dims, String(read(io, tlen)), off)
    elseif magic == _RAW_MAGIC
        nd = Int(read(io, UInt8))
        dims = Int[read(io, Int64) for _ in 1:nd]
        return (dims, String(read(io, read(io, UInt16))), 64)
    end
    error("raw codec: bad magic")
end

# Serialization that carries a notebook's closures with their code. Julia's serializer does that only
# for anonymous functions in `Main`, and writes any other by its generated name, which exists only in
# the process that made it. A notebook's namespace is a module under `Main`, so a value holding a
# closure made there (an option `rows -> …`, a field a macro filled) could be decoded nowhere else.
# The standard deserializer reads both forms.
mutable struct _SlateSerializer{I<:IO} <: Serialization.AbstractSerializer
    io::I
    counter::Int
    table::IdDict{Any,Any}
    pending_refs::Vector{Int}
    known_object_data::Dict{UInt64,Any}
    version::Int
    _SlateSerializer(io::I) where {I<:IO} =
        new{I}(io, 0, IdDict(), Int[], Dict{UInt64,Any}(), Serialization.ser_version)
end

function Serialization.should_send_whole_type(s::_SlateSerializer, t::DataType)
    invoke(Serialization.should_send_whole_type, Tuple{Any,DataType}, s, t) && return true
    tn = t.name
    mod = tn.module
    (mod !== Main && Base.moduleroot(mod) === Main) || return false
    (t.super === Function && startswith(String(tn.name), "#")) || return false
    # A named function's type is hidden too, but it is reached by its name.
    name = tn.singletonname
    return !isdefined(mod, name) || t != typeof(getglobal(mod, name))
end

function _serialize(io::IO, v)
    s = _SlateSerializer(io)
    Serialization.writeheader(s)
    Serialization.serialize(s, v)
    return nothing
end

"The manifest codec for `v` (restore-mode `zc` never affects the pick, only the decode)."
function _codec_pick(v)
    _rawable(v) && return "raw"
    D = _codec_loaded("DataFrames")
    # `invokelatest` for the same reason as `_ds_columns`: the package was loaded after this was
    # compiled, so even the type binding is not visible from here.
    D !== nothing && v isa Base.invokelatest(getglobal, D, :DataFrame) &&
        _codec_loaded("Arrow") !== nothing && return "arrow"
    return "jls"
end

function _codec_encode(io::IO, codec::String, v)
    if codec == "raw"
        et = string(eltype(v))
        off = _raw_offset(v)
        hdr = IOBuffer()
        write(hdr, _RAW_MAGIC2)
        write(hdr, UInt8(ndims(v)))
        write(hdr, UInt32(ncodeunits(et)))
        write(hdr, UInt32(off))
        for d in size(v); write(hdr, Int64(d)); end
        write(hdr, et)
        pad = take!(hdr)
        write(io, pad); write(io, zeros(UInt8, off - length(pad)))
        write(io, v)
    elseif codec == "arrow"
        _codec_loaded("Arrow").write(io, v)          # pure IPC bytes — see header comment
    else
        _serialize(io, v)
    end
    return nothing
end

"Decode blob at `path`. `zc=true` ⇒ the graph proved no downstream mutation → mmap zero-copy."
function _codec_decode(codec::String, path::String, zc::Bool)
    if codec == "raw"
        io = open(path, "r")
        try
            dims, et, off = _raw_header(io)
            T = Core.eval(Main, Meta.parse(et))
            if zc
                flat = Mmap.mmap(io, Vector{T}, prod(dims), off)  # read-only stream ⇒ read-only pages
                return length(dims) == 1 ? flat : reshape(flat, Tuple(dims))
            end
            seek(io, off)
            a = Array{T}(undef, dims...)
            read!(io, a)
            return a
        finally
            close(io)   # an established mmap outlives the stream
        end
    elseif codec == "arrow"
        A = _codec_loaded("Arrow"); D = _codec_loaded("DataFrames")
        (A === nothing || D === nothing) && error("arrow codec: Arrow/DataFrames not loaded yet")
        # Both packages were loaded at RUNTIME, so neither call is visible from this world age.
        tbl = Base.invokelatest(Base.invokelatest(getglobal, A, :Table), path)
        return Base.invokelatest(Base.invokelatest(getglobal, D, :DataFrame), tbl; copycols = !zc)
    else
        return open(Serialization.deserialize, path, "r")
    end
end
