# Animation — a precomputed frame stack + a client-side player. See ANIMATION_PIPELINE_DESIGN.md.
#
# `animate(frames; …)` (called from a cell, so it runs in the worker / notebook project) quantizes
# the stack to a compact byte buffer + a 256-entry colormap LUT and wraps them with a small JSON
# manifest. capture.jl pulls the payload across the wire (like an EChart option); the server
# registers the frame buffer in the durable blob store and the browser plays it back on a WebGL2
# canvas — nothing touches Julia during playback.
#
# Dependency-free on purpose: this executes in the worker's environment (the user's project), which
# is NOT guaranteed to have KaimonSlate's deps. So no gzip here (the server compresses at the blob
# boundary) and no Colors.jl (colors are read by duck-typing `.r/.g/.b`, so `colormap = cgrad(:magma)`
# from the user's own Makie/Colors works without us importing anything).

"A precomputed animation: a quantized frame stack + colormap LUT + a small display manifest."
struct Animation
    manifest::Dict{String,Any}   # kind, shape, bits, fps, times, clim, diverging, dither, axes, controls
    frames::Vector{UInt8}        # quantized stack, frame-major then row-major (see _quantize!)
    lut::Vector{UInt8}           # 256 × RGBA
end

# ── Built-in colormaps (anchor RGB 0–255, linearly interpolated to 256) ───────────────────────────
# Accurate enough to read correctly; pass `colormap = cgrad(:magma)` for an exact Makie match.
const _CMAP_ANCHORS = Dict{Symbol,Vector{NTuple{3,Int}}}(
    :viridis => [(68,1,84),(72,40,120),(62,74,137),(49,104,142),(38,130,142),
                 (31,158,137),(53,183,121),(110,206,88),(181,222,43),(253,231,37)],
    :magma   => [(0,0,4),(28,16,68),(79,18,123),(129,37,129),(181,54,122),
                 (229,80,100),(251,135,97),(254,194,135),(252,253,191)],
    :inferno => [(0,0,4),(31,12,72),(85,15,109),(136,34,106),(186,54,85),
                 (227,89,51),(249,140,10),(249,201,50),(252,255,164)],
    :plasma  => [(13,8,135),(84,2,163),(139,10,165),(185,50,137),(219,92,104),
                 (244,136,73),(254,188,43),(240,249,33)],
    :gray    => [(0,0,0),(255,255,255)],
    :grays   => [(0,0,0),(255,255,255)],
    # Diverging (blue → white → red) for signed fields; default when clim = :symmetric.
    :coolwarm => [(59,76,192),(122,150,235),(192,212,245),(241,241,241),
                  (245,200,170),(222,120,98),(180,4,38)],
    :balance  => [(59,76,192),(122,150,235),(192,212,245),(241,241,241),
                  (245,200,170),(222,120,98),(180,4,38)],
    :rdbu     => [(178,24,43),(214,96,77),(244,165,130),(247,247,247),
                  (146,197,222),(67,147,195),(33,102,172)],
)

const _DIVERGING_CMAPS = Set([:coolwarm, :balance, :rdbu])

# Interpolate `anchors` (RGB 0–255) into a 256 × RGBA `UInt8` LUT (opaque).
function _lut_from_anchors(anchors::AbstractVector{<:NTuple{3,<:Real}})
    n = length(anchors)
    lut = Vector{UInt8}(undef, 256 * 4)
    @inbounds for i in 0:255
        t = n == 1 ? 0.0 : (i / 255) * (n - 1)
        lo = clamp(floor(Int, t), 0, n - 1); hi = min(lo + 1, n - 1); f = t - lo
        a = anchors[lo + 1]; b = anchors[hi + 1]
        lut[4i + 1] = round(UInt8, clamp(a[1] + (b[1] - a[1]) * f, 0, 255))
        lut[4i + 2] = round(UInt8, clamp(a[2] + (b[2] - a[2]) * f, 0, 255))
        lut[4i + 3] = round(UInt8, clamp(a[3] + (b[3] - a[3]) * f, 0, 255))
        lut[4i + 4] = 0xff
    end
    return lut
end

# One RGB triple (0–255 Int) from an arbitrary color value, by duck-typing — handles Colors.jl
# colorants (`.r/.g/.b` in 0–1), RGB/RGBA tuples, and `(r,g,b)` in either 0–1 or 0–255.
function _rgb_of(c)
    if hasproperty(c, :r) && hasproperty(c, :g) && hasproperty(c, :b)
        return (round(Int, clamp(float(c.r), 0, 1) * 255),
                round(Int, clamp(float(c.g), 0, 1) * 255),
                round(Int, clamp(float(c.b), 0, 1) * 255))
    elseif c isa Union{Tuple,AbstractVector} && length(c) >= 3
        v = float.(collect(c)[1:3])
        scale = maximum(v) <= 1.0 ? 255 : 1
        return (round(Int, clamp(v[1] * scale, 0, 255)),
                round(Int, clamp(v[2] * scale, 0, 255)),
                round(Int, clamp(v[3] * scale, 0, 255)))
    end
    throw(ArgumentError("animate: don't know how to read a color from $(typeof(c))"))
end

# Resolve `colormap` → a 256 × RGBA LUT. Symbol → built-in; otherwise an iterable of colors
# (sampled to 256), e.g. `cgrad(:magma)` from the user's Makie environment.
function _resolve_lut(colormap, signed::Bool)
    if colormap isa Symbol
        # :auto → a diverging map for signed data, a sequential one otherwise.
        colormap === :auto && (colormap = signed ? :coolwarm : :viridis)
        key = lowercase(string(colormap))
        sym = Symbol(key)
        anchors = get(_CMAP_ANCHORS, sym, nothing)
        anchors === nothing && (anchors = signed ? _CMAP_ANCHORS[:coolwarm] : _CMAP_ANCHORS[:viridis])
        return _lut_from_anchors(anchors), sym in _DIVERGING_CMAPS
    end
    cols = collect(colormap)
    isempty(cols) && return _lut_from_anchors(_CMAP_ANCHORS[:viridis]), false
    return _lut_from_anchors([_rgb_of(c) for c in cols]), signed
end

# ── Quantization ──────────────────────────────────────────────────────────────────────────────
_apply(::Nothing, v) = v
_apply(f, v) = f(v)

# Resolve the colour limits. Returns (mode::String, lo, hi, ranges) where `ranges` is per-frame for
# :perframe (else empty). `transform` is applied to the data BEFORE limits are taken (and is skipped
# upstream for signed/:symmetric data — sqrt of a negative is a NaN trap).
function _resolve_clim(frames, clim, transform)
    if clim isa Tuple || clim isa AbstractVector && length(clim) == 2 && eltype(clim) <: Real
        return ("explicit", float(clim[1]), float(clim[2]), Tuple{Float64,Float64}[])
    end
    sym = clim === :symmetric
    if clim === :perframe
        ranges = Tuple{Float64,Float64}[]
        for fr in frames
            lo, hi = _extrema_valid(fr, transform)
            lo == hi && (hi = lo + 1.0)         # flat frame → avoid a zero-width range
            push!(ranges, (lo, hi))
        end
        return ("perframe", 0.0, 1.0, ranges)
    end
    # :global (default) or :symmetric → one range over the whole stack
    glo, ghi = Inf, -Inf
    for fr in frames
        lo, hi = _extrema_valid(fr, transform)
        glo = min(glo, lo); ghi = max(ghi, hi)
    end
    isfinite(glo) || (glo = 0.0); isfinite(ghi) || (ghi = 1.0)
    if sym
        m = max(abs(glo), abs(ghi)); m = m == 0 ? 1.0 : m
        return ("symmetric", -m, m, Tuple{Float64,Float64}[])
    end
    glo == ghi && (ghi = glo + 1.0)            # flat field → avoid a zero-width range
    return ("global", glo, ghi, Tuple{Float64,Float64}[])
end

# (min,max) over the finite, transformed values of one frame.
function _extrema_valid(fr, transform)
    lo, hi = Inf, -Inf
    @inbounds for v in fr
        x = _apply(transform, float(v))
        isfinite(x) || continue
        x < lo && (lo = x); x > hi && (hi = x)
    end
    (isfinite(lo) && isfinite(hi)) ? (lo, hi) : (0.0, 1.0)
end

# Quantize one frame's value to a UInt8 (0–255). NaN/Inf → 0.
@inline function _q8(v, lo, hi, transform)
    x = _apply(transform, float(v))
    isfinite(x) || return 0x00
    hi == lo && return 0x00
    return round(UInt8, clamp((x - lo) / (hi - lo) * 255, 0, 255))
end

# Quantize the whole stack into a frame-major, row-major (top row first) UInt8 buffer.
# Julia matrices are column-major H×W (M[row,col]); we emit row-by-row so the player can upload it
# straight into a WebGL texture array of width=W, height=H, depth=nframes.
function _quantize8(frames, mode, lo, hi, ranges, transform)
    nf = length(frames)
    H, W = size(first(frames))
    buf = Vector{UInt8}(undef, nf * H * W)
    k = 1
    @inbounds for (fi, fr) in enumerate(frames)
        flo, fhi = mode == "perframe" ? ranges[fi] : (lo, hi)
        for r in 1:H, c in 1:W
            buf[k] = _q8(fr[r, c], flo, fhi, transform); k += 1
        end
    end
    return buf, H, W, nf
end

# ── RGBA image frames (kind=:image) ───────────────────────────────────────────────────────────
# A frame is either an H×W matrix of colors (duck-typed via `_rgb_of`, e.g. `Matrix{RGB{N0f8}}`
# as returned by VideoIO.jl/Images.jl) or a raw H×W×3 array. No quantization needed — packed
# straight to RGBA8 (opaque) so the player can upload it into an RGBA texture array.
_image_hw(f) = ndims(f) == 3 ? (size(f, 1), size(f, 2)) : size(f)
_image_px(f, r, c) = ndims(f) == 3 ? _rgb_of(view(f, r, c, :)) : _rgb_of(f[r, c])

function _quantize_rgba(frames)
    nf = length(frames)
    H, W = _image_hw(first(frames))
    buf = Vector{UInt8}(undef, nf * H * W * 4)
    k = 1
    @inbounds for fr in frames
        for r in 1:H, c in 1:W
            rr, gg, bb = _image_px(fr, r, c)
            buf[k] = UInt8(rr); buf[k+1] = UInt8(gg); buf[k+2] = UInt8(bb); buf[k+3] = 0xff
            k += 4
        end
    end
    return buf, H, W, nf
end

# ── Overlay (frame-synced markers, e.g. tracked object positions) ────────────────────────────────
# One entry per frame, each a list of points `(x, y[, id])` in the SAME index space as the frame
# data (x ∈ [1,W], y ∈ [1,H], row 1 = top). `id` (default 0) gives a point a stable color/trail
# across frames — e.g. a track identity. Rendered client-side, independent of the frame texture.
function _overlay_json(overlay, nf)
    overlay === nothing && return nothing
    length(overlay) == nf ||
        throw(ArgumentError("animate: `overlay` must have one entry per frame ($(length(overlay)) given, $nf frames)"))
    return [[_overlay_point(p) for p in pts] for pts in overlay]
end
_overlay_point(p) = length(p) >= 3 ? [Float64(p[1]), Float64(p[2]), Int(p[3])] : [Float64(p[1]), Float64(p[2]), 0]

# ── Public API ──────────────────────────────────────────────────────────────────────────────────
"""
    animate(frames; kind=:heatmap, fps=30, colormap=:viridis, clim=:global, transform=nothing,
            dither=true, bits=8, x=nothing, y=nothing, title="", colorbar=true,
            loop=true, autoplay=false, overlay=nothing, maxbytes=128_000_000) -> Animation

Build a client-side-playable animation from an already-computed stack of frames. The heavy compute
is yours and runs once; `animate` only quantizes + packages. Playback happens entirely in the
browser. See ANIMATION_PIPELINE_DESIGN.md.

`kind=:heatmap` (default) takes a vector of 2-D scalar matrices, colormapped via `colormap`/`clim`.
`kind=:image` takes a vector of H×W color matrices (e.g. `Matrix{RGB}` from VideoIO.jl/Images.jl)
or H×W×3 arrays — real video/image frames, played back as true color (no colormap).

`overlay` (either kind) draws frame-synced markers on top — a vector with one entry per frame, each
a list of `(x, y[, id])` points in frame pixel space; `id` keeps a point's color/trail stable across
frames, e.g. a tracked object's identity.
"""
function animate(frames::AbstractVector;
                 kind::Symbol = :heatmap, fps::Real = 30, times = nothing,
                 colormap = :auto, clim = :global, transform = nothing,
                 dither::Bool = true, bits::Integer = 8,
                 x = nothing, y = nothing, title::AbstractString = "",
                 colorbar::Bool = true, loop::Bool = true, autoplay::Bool = false,
                 overlay = nothing, maxbytes::Integer = 128_000_000)
    kind === :heatmap || kind === :image ||
        throw(ArgumentError("animate: kind must be :heatmap or :image (got $kind)"))
    isempty(frames) && throw(ArgumentError("animate: `frames` is empty"))
    bits == 8 || throw(ArgumentError("animate: only bits=8 is supported (bits=16 is schema-reserved)"))

    if kind === :image
        all(f -> f isa AbstractMatrix || (f isa AbstractArray && ndims(f) == 3), frames) ||
            throw(ArgumentError("animate(kind=:image) needs a vector of H×W color matrices or H×W×3 arrays"))
        sz = _image_hw(first(frames))
        all(f -> _image_hw(f) == sz, frames) || throw(ArgumentError("animate: all frames must share the same size"))
        nbytes = length(frames) * sz[1] * sz[2] * 4
        nbytes > maxbytes && throw(ArgumentError(
            "animate: stack is $(round(nbytes/1e6; digits=1)) MB raw (> maxbytes $(round(maxbytes/1e6; digits=1)) MB). " *
            "Use fewer frames, a smaller frame, or raise maxbytes="))
        buf, H, W, nf = _quantize_rgba(frames)
        # A LUT isn't used in image mode, but the blob-store contract (server_history.jl) requires a
        # non-empty one alongside the frame stack, so ship a trivial one.
        lut = _lut_from_anchors(_CMAP_ANCHORS[:gray])
        manifest = Dict{String,Any}(
            "kind"   => "image",
            "animId" => string(hash(buf); base = 16),
            "shape"  => [nf, H, W],
            "channels" => 4,
            "bits"   => 8,
            "fps"    => Float64(fps),
            "times"  => times === nothing ? nothing : Float64.(collect(times)),
            "axes"   => Dict("x" => x === nothing ? nothing : Float64.(collect(x)),
                             "y" => y === nothing ? nothing : Float64.(collect(y)),
                             "title" => String(title), "colorbar" => false),
            "controls" => Dict("loop" => loop, "autoplay" => autoplay),
            "overlay" => _overlay_json(overlay, nf),
        )
        return Animation(manifest, buf, lut)
    end

    all(f -> f isa AbstractMatrix, frames) ||
        throw(ArgumentError("animate(kind=:heatmap) needs a vector of matrices"))
    sz = size(first(frames))
    all(f -> size(f) == sz, frames) || throw(ArgumentError("animate: all frames must share the same size"))

    signed = clim === :symmetric
    xform  = signed ? nothing : transform          # never sqrt() signed data
    mode, lo, hi, ranges = _resolve_clim(frames, clim, xform)
    signed |= (mode == "symmetric")

    nbytes = length(frames) * prod(sz)
    nbytes > maxbytes && throw(ArgumentError(
        "animate: stack is $(round(nbytes/1e6; digits=1)) MB raw (> maxbytes $(round(maxbytes/1e6; digits=1)) MB). " *
        "Use fewer frames, a smaller field, or raise maxbytes="))

    buf, H, W, nf = _quantize8(frames, mode, lo, hi, ranges, xform)
    lut, diverging = _resolve_lut(colormap, signed)

    clim_json = mode == "perframe" ?
        Dict("mode" => "perframe", "ranges" => [[r[1], r[2]] for r in ranges]) :
        Dict("mode" => mode, "range" => [lo, hi])

    manifest = Dict{String,Any}(
        "kind"   => "heatmap",
        # Stable per-content id linking this animation to a `playhead(anim)` bind in another cell.
        "animId" => string(hash(buf); base = 16),
        "shape"  => [nf, H, W],
        "bits"   => 8,
        "fps"    => Float64(fps),
        "times"  => times === nothing ? nothing : Float64.(collect(times)),
        "clim"   => clim_json,
        "diverging" => diverging,
        "dither" => dither,
        "axes"   => Dict("x" => x === nothing ? nothing : Float64.(collect(x)),
                         "y" => y === nothing ? nothing : Float64.(collect(y)),
                         "title" => String(title), "colorbar" => colorbar),
        "controls" => Dict("loop" => loop, "autoplay" => autoplay),
        "overlay" => _overlay_json(overlay, nf),
    )
    return Animation(manifest, buf, lut)
end

"`animate(f, nframes; …)` — generate frame `i` with `f(i)` (sugar for `animate([f(i) for i in 1:n])`)."
animate(f, nframes::Integer; kw...) = animate([f(i) for i in 1:nframes]; kw...)

Base.showable(::MIME"application/x-slate-animation", ::Animation) = true
# The frame buffer is binary and goes to the blob store, so `show` emits only the manifest (the
# capture hook in capture.jl carries the bytes across the wire separately).
Base.show(io::IO, ::MIME"application/x-slate-animation", a::Animation) = print(io, "[animation]")
