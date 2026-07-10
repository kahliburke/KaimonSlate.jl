# Memo codecs — how a binding VALUE becomes blob BYTES (and back). The manifest's per-name
# `codec` field names one of these; "jls" (Serialization) is the universal fallback. The fast
# codecs exist for the multi-GB case, where JLS's object-graph walk (~87MB/s measured) turns
# "instant reopen" into minutes:
#   raw    isbits Arrays — 64-byte self-describing header + the raw bytes. When the graph
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

const _RAW_MAGIC = UInt32(0x534c5257)   # "SLRW"
_rawable(v) = v isa Array && isbitstype(eltype(v)) && !isempty(v)

"The manifest codec for `v` (restore-mode `zc` never affects the pick, only the decode)."
function _codec_pick(v)
    _rawable(v) && return "raw"
    D = _codec_loaded("DataFrames")
    D !== nothing && v isa D.DataFrame && _codec_loaded("Arrow") !== nothing && return "arrow"
    return "jls"
end

function _codec_encode(io::IO, codec::String, v)
    if codec == "raw"
        hdr = IOBuffer()
        write(hdr, _RAW_MAGIC); write(hdr, UInt8(ndims(v)))
        for d in size(v); write(hdr, Int64(d)); end
        et = string(eltype(v))
        write(hdr, UInt16(ncodeunits(et))); write(hdr, et)
        pad = take!(hdr)
        length(pad) > 64 && error("raw codec: header too large for eltype $(et)")
        write(io, pad); write(io, zeros(UInt8, 64 - length(pad)))
        write(io, v)
    elseif codec == "arrow"
        _codec_loaded("Arrow").write(io, v)          # pure IPC bytes — see header comment
    else
        Serialization.serialize(io, v)
    end
    return nothing
end

"Decode blob at `path`. `zc=true` ⇒ the graph proved no downstream mutation → mmap zero-copy."
function _codec_decode(codec::String, path::String, zc::Bool)
    if codec == "raw"
        io = open(path, "r")
        try
            read(io, UInt32) == _RAW_MAGIC || error("raw codec: bad magic")
            nd = Int(read(io, UInt8))
            dims = Int[read(io, Int64) for _ in 1:nd]
            T = Core.eval(Main, Meta.parse(String(read(io, read(io, UInt16)))))
            if zc
                flat = Mmap.mmap(io, Vector{T}, prod(dims), 64)   # read-only stream ⇒ read-only pages
                return nd == 1 ? flat : reshape(flat, Tuple(dims))
            end
            seek(io, 64)
            a = Array{T}(undef, dims...)
            read!(io, a)
            return a
        finally
            close(io)   # an established mmap outlives the stream
        end
    elseif codec == "arrow"
        A = _codec_loaded("Arrow"); D = _codec_loaded("DataFrames")
        (A === nothing || D === nothing) && error("arrow codec: Arrow/DataFrames not loaded yet")
        return D.DataFrame(A.Table(path); copycols = !zc)   # zc ⇒ arrow-backed (immutable) columns
    else
        return open(Serialization.deserialize, path, "r")
    end
end
