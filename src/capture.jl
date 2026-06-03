# Cell evaluation + rich-output capture (§7). Dependency-light (Base only) and
# self-contained so the *same* implementation runs both in-process (the default
# kernel) and inside a per-notebook gate worker — no duplicate capture code.
#
# `run_capture` returns a **wire-form** NamedTuple of primitives (String, byte
# vectors, Dicts). That matters for the gate worker: a NamedTuple of primitives
# serializes across the gate and reconstructs on the server without the two
# processes needing to share `MimeChunk`/`CellOutput` struct identity. The server
# wraps the wire form into `CellOutput` (see `_eval_capture` in eval.jl).
#
# The mechanism is Base-only: a display pushed onto the stack records the richest
# MIME of anything `display()`'d during a cell, and the return value is captured
# the same way. What a captured object can `show` as (e.g. a CairoMakie figure →
# image/png) is orthogonal — that lives in the worker's own project env.

const _RICH_MIMES = ("image/svg+xml", "image/png", "text/html")

struct _CaptureDisplay <: AbstractDisplay
    chunks::Vector{Tuple{String,Vector{UInt8}}}
end

function _mime_bytes(m::MIME, x)
    io = IOBuffer()
    show(io, m, x)
    return take!(io)
end

# Capture the richest available representation of `x`; true if anything captured.
function _capture_rich!(chunks::Vector{Tuple{String,Vector{UInt8}}}, x)
    for m in _RICH_MIMES
        if showable(m, x)
            push!(chunks, (m, _mime_bytes(MIME(m), x)))
            return true
        end
    end
    return false
end

function Base.display(d::_CaptureDisplay, x)
    _capture_rich!(d.chunks, x) && return nothing
    throw(MethodError(display, (d, x)))   # let the stack fall through to text
end

"""
    run_capture(mod, source) -> NamedTuple

Evaluate `source` in module `mod`, capturing stdout (async-read to avoid
deadlock), rich display output + the returned value's MIME (or an ECharts spec),
a text/plain repr fallback, eval duration, and any thrown error + backtrace.

Returns the wire form:
`(stdout::String, mime::Vector{Tuple{String,Vector{UInt8}}}, echarts::Vector{Any},
  value_repr::String, exception::Union{String,Nothing},
  backtrace::Union{String,Nothing}, duration_ms::Float64)`.
"""
function run_capture(mod::Module, source::AbstractString)
    chunks = Tuple{String,Vector{UInt8}}[]
    capture = _CaptureDisplay(chunks)
    pushdisplay(capture)
    original = stdout
    (rd, wr) = redirect_stdout()
    reader = @async read(rd, String)

    value = nothing
    err = nothing
    btrace = nothing
    t0 = time_ns()
    try
        value = include_string(mod, source)
    catch e
        err = e
        btrace = catch_backtrace()
    finally
        redirect_stdout(original)
        close(wr)
        popdisplay(capture)
    end
    stdout_str = fetch(reader)
    dur_ms = (time_ns() - t0) / 1e6

    # Capture the return value: an ECharts spec is kept raw (encoded server-side
    # to dodge JSON world-age in the eval frame); otherwise the richest MIME.
    echarts = Any[]
    if err === nothing && value !== nothing
        if value isa EChart
            push!(echarts, value.option)
        else
            try
                Base.invokelatest(_capture_rich!, chunks, value)
            catch
            end
        end
    end

    # text/plain repr — skipped when richer output exists (the renderer suppresses
    # it anyway), and `invokelatest`-guarded for the world-age reason.
    value_repr = ""
    if err === nothing && value !== nothing && isempty(chunks) && isempty(echarts)
        try
            value_repr = Base.invokelatest(sprint, show, MIME("text/plain"), value;
                                           context = :limit => true)
        catch
        end
    end
    exc = err === nothing ? nothing : sprint(showerror, err)
    bt = btrace === nothing ? nothing :
        sprint((io, t) -> Base.show_backtrace(io, t), btrace)

    return (stdout = stdout_str, mime = chunks, echarts = echarts,
            value_repr = value_repr, exception = exc, backtrace = bt, duration_ms = dur_ms)
end
