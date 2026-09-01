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
#
# `version` guards the LAYOUT above, not the contents of any field. Appending a row to `DTYPES`
# widens what `dtype` may hold but leaves every offset identical, so it does NOT bump the version:
# a decoder that knows only the older rows still parses the frame correctly and declines the one
# dtype it lacks (`wscall.js` drops the frame; `core.js` throws). Bumping instead would make those
# decoders reject every v2 frame — including the types they handle perfectly — to announce a change
# that cannot affect them. Reserve the bump for a change that moves or reinterprets bytes.

"""
    SlateBinary(data, meta = (;))

Mark a numeric `data` array for BINARY streaming through [`slate_emit`](@ref) — raw little-endian bytes on
the wire instead of Serialization+JSON, for high-rate frames. `meta` (a NamedTuple/Dict of small JSON-safe
values) rides alongside as a compact header; the browser handler receives `{…meta, d}` with `d` a typed
array. Element type must be one of `Float32`/`Float64`/`Int32`/`Int16`/`UInt8`.

A dense `Array` is held by REFERENCE, so the frame carries whatever it holds when it is ENCODED —
emit and move on, and reusing one buffer across frames costs nothing. Mutating the array between
construction and emit therefore changes what is sent; pass `snapshot = true` for a copy taken at
construction instead. Any other `AbstractArray` (a view, a range, an adjoint) is copied either way,
since its bytes aren't contiguous.

```julia
slate_emit("field", SlateBinary(frame; i = idx, t = time()))   # frame::Matrix{Float32}
```
"""
struct SlateBinary{T,N}
    data::Array{T,N}
    meta::Dict{String,Any}
    # Spelled out so Julia does NOT generate the default outer `SlateBinary(::Array, ::Dict)`. The
    # constructors below need that signature to carry `snapshot`, and redefining a generated method
    # is method overwriting, which a precompiled module rejects outright.
    SlateBinary{T,N}(data::Array{T,N}, meta::Dict{String,Any}) where {T,N} = new{T,N}(data, meta)
end
# Anything non-contiguous has to be gathered, so it copies regardless; `snapshot` is accepted and
# ignored there so callers need not know which kind of array they hold.
SlateBinary(data::AbstractArray, meta; snapshot::Bool = false) = SlateBinary(collect(data), _props_dict(meta))
SlateBinary(data::AbstractArray; snapshot::Bool = false, kw...) =
    SlateBinary(collect(data), Dict{String,Any}(String(k) => v for (k, v) in kw))
# A dense array is kept by REFERENCE — at this path's rates a per-frame copy of the payload is most
# of its cost, and a sender reusing one buffer would copy it again for nothing. `snapshot = true` is
# for a caller that HOLDS the value instead of emitting it straight away: a copy taken at
# construction, immune to whatever happens to the array afterwards.
SlateBinary(data::Array{T,N}, meta::Dict{String,Any}; snapshot::Bool = false) where {T,N} =
    SlateBinary{T,N}(snapshot ? copy(data) : data, meta)
SlateBinary(data::Array{T,N}, meta; snapshot::Bool = false) where {T,N} =
    SlateBinary(data, _props_dict(meta); snapshot)
SlateBinary(data::Array{T,N}; snapshot::Bool = false, kw...) where {T,N} =
    SlateBinary(data, Dict{String,Any}(String(k) => v for (k, v) in kw); snapshot)

# ── The dtype table ───────────────────────────────────────────────────────────────────────────
"""
    DTYPES

One row per element type Slate can put on a wire as raw bytes, and the only place the set is
written down. Everything else is derived from it: the streaming frame's numeric tag
(`_bin_dtype`), the asset manifest's string tag ([`dtype_tag`](@ref), which capture.jl's
`_asset_dtype` delegates to), and the browser's decoders ([`dtype_js`](@ref), injected as
`window.__SLATE_DTYPES` and read by core.js and wscall.js). Supporting another element type is a
row here and nothing else.

Each row is a `NamedTuple` of `(T, code, tag, js)`:

- `code` is a WIRE CONTRACT: it is the frame's dtype byte, so rows may be APPENDED but never
  reordered, renumbered or removed.
- `tag` is the asset manifest's spelling (it crosses as JSON, so it is a string rather than a byte).
- `js` names the TypedArray that reads the bytes back.
"""
const DTYPES = (
    (T = Float32, code = 0x00, tag = "f32", js = "Float32Array"),
    (T = Float64, code = 0x01, tag = "f64", js = "Float64Array"),
    (T = Int32,   code = 0x02, tag = "i32", js = "Int32Array"),
    (T = Int16,   code = 0x03, tag = "i16", js = "Int16Array"),
    (T = UInt8,   code = 0x04, tag = "u8",  js = "Uint8Array"),
    (T = Int8,    code = 0x05, tag = "i8",  js = "Int8Array"),
    (T = UInt16,  code = 0x06, tag = "u16", js = "Uint16Array"),
    (T = UInt32,  code = 0x07, tag = "u32", js = "Uint32Array"),
    # Julia's DEFAULT integer, so `rand(1:10, n, n)` lands here. `BigInt64Array` is the only
    # lossless landing spot — JS numbers carry 53 bits — at the cost of BigInt elements, which do
    # not mix with Number in arithmetic. Downcast (`Int32.(A)`, `Float64.(A)`) when the array is
    # headed for a plot; this row is for when the values matter more than the ergonomics.
    (T = Int64,   code = 0x08, tag = "i64", js = "BigInt64Array"),
    (T = UInt64,  code = 0x09, tag = "u64", js = "BigUint64Array"),
    # `Bool` is one byte per element in Julia, so a mask ships as bytes and reads back as 0/1.
    (T = Bool,    code = 0x0a, tag = "b8",  js = "Uint8Array"),
    (T = Float16, code = 0x0b, tag = "f16", js = "Float16Array"),
)

for row in DTYPES
    @eval _bin_dtype(::Type{$(row.T)}) = $(row.code)
    @eval dtype_tag(::Type{$(row.T)}) = $(row.tag)
end

_bin_dtype(::Type{T}) where {T} = throw(ArgumentError(
    "SlateBinary: unsupported element type $T (use $(join((string(r.T) for r in DTYPES), "/")))"))

"""
    dtype_tag(T) -> String | Nothing

The asset manifest's dtype spelling for element type `T` (`"f32"`, `"i32"`, …), or `nothing` when
`T` is not one Slate packs as raw bytes — the caller then falls back to JSON. Derived from
[`DTYPES`](@ref).
"""
dtype_tag(::Type) = nothing

"""
    dtype_js() -> String

The dtype table as a JavaScript snippet defining `window.__SLATE_DTYPES`:

- `byCode` — TypedArray constructors indexed by the binary frame's dtype byte (decoding a frame),
- `byTag` — the same, keyed by the asset manifest's string tag (decoding an asset),
- `codeByTag` — tag → dtype byte, for the browser's uplink encoder.

Served live at `/assets/js/dtypes.js` and inlined into static exports, so a browser cannot disagree
with Julia about what a dtype means.

Constructors are looked up by NAME at run time rather than referenced directly: a row whose
TypedArray the browser doesn't implement (`Float16Array` on an older engine) resolves to `null` and
that one dtype declines to decode, instead of a `ReferenceError` taking the whole table — and with
it every other dtype — down with it.
"""
dtype_js() = string(
    "window.__SLATE_DTYPES=(function(){",
    "var g=function(n){try{return globalThis[n]||null;}catch(e){return null;}};",
    "var rows=[", join(("[\"$(r.tag)\",\"$(r.js)\",$(Int(r.code))]" for r in DTYPES), ","), "];",
    "var byCode=[],byTag={},codeByTag={};",
    "rows.forEach(function(r){var C=g(r[1]);byCode[r[2]]=C;byTag[r[0]]=C;codeByTag[r[0]]=r[2];});",
    "return {byCode:byCode,byTag:byTag,codeByTag:codeByTag};})();")

"""
    encode_binary_frame(channel, x::SlateBinary) -> Vector{UInt8}

Serialize a [`SlateBinary`](@ref) into the self-describing binary streaming frame (see the layout above).
The channel + meta + dtype + shape are the header; the array's raw column-major bytes are the payload.
"""
function encode_binary_frame(channel::AbstractString, x::SlateBinary{T,N}) where {T,N}
    ch = codeunits(String(channel))
    mb = codeunits(sprint(_write_json, x.meta))
    # Sized exactly: unhinted, the buffer doubles its way to the payload and allocates a multiple of
    # the frame it produces — per frame, on the task that is streaming.
    n = 1 + 2 + length(ch) + 2 + length(mb) + 1 + 1 + 4N + sizeof(x.data)
    io = IOBuffer(; sizehint = n)
    write(io, 0x01)                                            # version
    write(io, UInt16(length(ch))); write(io, ch)
    write(io, UInt16(length(mb))); write(io, mb)
    write(io, _bin_dtype(T))
    write(io, UInt8(N)); for d in size(x.data); write(io, UInt32(d)); end
    write(io, reinterpret(UInt8, vec(x.data)))                # raw LE bytes, column-major
    return take!(io)
end
