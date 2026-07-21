# ── Binary numeric frame (high-throughput streaming) ──────────────────────────
# `slate_emit` normally Serialization+base64+JSON-encodes a value (three passes) — fine for small payloads,
# a bottleneck for high-rate numeric arrays. Wrap an array in `SlateBinary` and it rides a COMPACT,
# self-describing binary frame instead: the worker builds this frame ONCE and hands it to the gate's raw
# binary publish (a by-reference multipart hop — no Serialization, no base64), the hub forwards the raw
# bytes as a binary WebSocket frame, and the browser reads a TypedArray directly — no JSON, no
# `JSON.parse`. Only the small `meta` stays JSON.
#
# Frame layout (all integers little-endian — every target platform is LE):
#   [u8 version=1]
#   [u16 channelLen][channelLen bytes: UTF-8 channel]
#   [u16 metaLen][metaLen bytes: UTF-8 JSON metadata]
#   [u8 dtype][u8 rank][rank × u32 dims]      # dtype per `_bin_dtype`; dims column-major (Julia order)
#   [raw element bytes]

"""
    SlateBinary(data, meta = (;))

Mark a numeric `data` array for BINARY streaming through [`slate_emit`](@ref) — raw little-endian bytes on
the wire instead of Serialization+JSON, for high-rate frames. `meta` (a NamedTuple/Dict of small JSON-safe
values) rides alongside as a compact header; the browser handler receives `{…meta, d}` with `d` a typed
array. Element type must be one of `Float32`/`Float64`/`Int32`/`Int16`/`UInt8`.

```julia
slate_emit("field", SlateBinary(frame; i = idx, t = time()))   # frame::Matrix{Float32}
```
"""
struct SlateBinary{T,N}
    data::Array{T,N}
    meta::Dict{String,Any}
end
SlateBinary(data::AbstractArray, meta) = SlateBinary(collect(data), _props_dict(meta))
SlateBinary(data::AbstractArray; kw...) = SlateBinary(collect(data), Dict{String,Any}(String(k) => v for (k, v) in kw))

# dtype tags — keep in sync with `_asset_dtype` (capture.jl) and core.js `_SLATE_TYPED`.
_bin_dtype(::Type{Float32}) = 0x00
_bin_dtype(::Type{Float64}) = 0x01
_bin_dtype(::Type{Int32})   = 0x02
_bin_dtype(::Type{Int16})   = 0x03
_bin_dtype(::Type{UInt8})   = 0x04
_bin_dtype(::Type{T}) where {T} =
    throw(ArgumentError("SlateBinary: unsupported element type $T (use Float32/Float64/Int32/Int16/UInt8)"))

"""
    encode_binary_frame(channel, x::SlateBinary) -> Vector{UInt8}

Serialize a [`SlateBinary`](@ref) into the self-describing binary streaming frame (see the layout above).
The channel + meta + dtype + shape are the header; the array's raw column-major bytes are the payload.
"""
function encode_binary_frame(channel::AbstractString, x::SlateBinary{T,N}) where {T,N}
    io = IOBuffer()
    write(io, 0x01)                                            # version
    ch = codeunits(String(channel)); write(io, UInt16(length(ch))); write(io, ch)
    mb = codeunits(sprint(_write_json, x.meta)); write(io, UInt16(length(mb))); write(io, mb)
    write(io, _bin_dtype(T))
    write(io, UInt8(N)); for d in size(x.data); write(io, UInt32(d)); end
    write(io, reinterpret(UInt8, vec(x.data)))                # raw LE bytes, column-major
    return take!(io)
end
