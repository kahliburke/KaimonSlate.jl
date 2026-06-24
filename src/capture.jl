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

const _RICH_MIMES = ("image/svg+xml", "image/png", "text/html", "text/latex")

# Vector format captured *in addition* to a raster figure, for publication PDF export
# (fonts embedded, scales crisply). The browser ignores this chunk; only the Typst
# exporter consumes it (preferring it over the raster). See `_capture_export_vector!`.
const _EXPORT_VEC_MIME = "application/pdf"

struct _CaptureDisplay <: AbstractDisplay
    chunks::Vector{Tuple{String,Vector{UInt8}}}
end

function _mime_bytes(m::MIME, x)
    io = IOBuffer()
    show(io, m, x)
    return take!(io)
end

# Capture the richest available representation of `x`; true if anything captured.
#
# `showable`/`show` go through `invokelatest`: a cell can `using SomePkg` (or define
# a method) and then return a value rendered by a method that package just added —
# all in one eval. Those methods land in a world newer than this frame, so a direct
# `showable`/`show` would miss them and yield an empty chunk (notably on a cell's
# first run). `invokelatest` pins the dispatch to the latest world.
function _capture_rich!(chunks::Vector{Tuple{String,Vector{UInt8}}}, x)
    for m in _RICH_MIMES
        if Base.invokelatest(showable, m, x)
            push!(chunks, (m, Base.invokelatest(_mime_bytes, MIME(m), x)))
            startswith(m, "image/") && _capture_export_vector!(chunks, x)
            return true
        end
    end
    return false
end

# When we just captured a raster figure (image/*), also try to render it to PDF — a
# vector form for publication export. We attempt `show(io, MIME"application/pdf", x)`
# *directly* (not gated on `showable`): CairoMakie gates `showable` on its active output
# `type` (png by default → `showable` is false for pdf) but its `show` method still
# renders a PDF. Anything without a PDF method just throws and is skipped. The chunk is
# export-only — `_render_chunks` (browser) handles image/*, html, latex and ignores it.
function _capture_export_vector!(chunks::Vector{Tuple{String,Vector{UInt8}}}, x)
    any(c -> c[1] == _EXPORT_VEC_MIME, chunks) && return
    try
        bytes = Base.invokelatest(_mime_bytes, MIME(_EXPORT_VEC_MIME), x)
        isempty(bytes) || push!(chunks, (_EXPORT_VEC_MIME, bytes))
    catch
    end
    return
end

function Base.display(d::_CaptureDisplay, x)
    _capture_rich!(d.chunks, x) && return nothing
    throw(MethodError(display, (d, x)))   # let the stack fall through to text
end

# Drop a trailing `# …` line comment, ignoring `#` inside a "…" string (so
# `foo("#");` keeps its `;`). Only `"` strings are tracked — `'` is left alone to
# avoid confusing adjoint (`a'`) with a char literal.
function _strip_trailing_comment(line::AbstractString)
    instr = false; i = firstindex(line)
    while i <= lastindex(line)
        c = line[i]
        if instr
            c == '"' && (instr = false)
            c == '\\' && i < lastindex(line) && (i = nextind(line, i))
        elseif c == '"'
            instr = true
        elseif c == '#'
            return rstrip(line[1:prevind(line, i)])
        end
        i = nextind(line, i)
    end
    return rstrip(line)
end

# True if a cell is "quiet" — its last non-blank, non-comment line ends in `;`
# (like the REPL / Jupyter, where a trailing `;` suppresses the value's display).
function _is_quiet_cell(source::AbstractString)
    for raw in Iterators.reverse(split(String(source), '\n'))
        code = _strip_trailing_comment(raw)
        isempty(code) && continue                    # blank/comment-only → look further up
        return endswith(code, ';')
    end
    return false
end

"""
    run_capture(mod, source) -> NamedTuple

Evaluate `source` in module `mod`, capturing stdout (async-read to avoid
deadlock), rich display output + the returned value's MIME (or an ECharts spec),
a text/plain repr fallback, eval duration, and any thrown error + backtrace.

Returns the wire form:
`(stdout::String, mime::Vector{Tuple{String,Vector{UInt8}}}, echarts::Vector{Any},
  tables::Vector{Any}, binds::Vector{NamedTuple}, value_repr::String,
  exception::Union{String,Nothing}, backtrace::Union{String,Nothing},
  duration_ms::Float64)`. `binds` are the `@bind` controls declared this eval
(`(name, kind, params, value)` each), for the host to render.
"""
function run_capture(mod::Module, source::AbstractString)
    chunks = Tuple{String,Vector{UInt8}}[]
    capture = _CaptureDisplay(chunks)
    pushdisplay(capture)
    original = stdout
    (rd, wr) = redirect_stdout()
    reader = @async read(rd, String)

    # Collect `@bind` controls declared during this eval — the namespace's injected
    # `__slate_bind` pushes to this sink. Absent on bare modules (e.g. tests) → no-op.
    # `__slate_bind_sink` is defined via `Core.eval` (a newer world age) than this caller, so the
    # access goes through `invokelatest` — otherwise Julia 1.12 warns (and a future Julia errors)
    # on reading a binding from a world prior to its definition (seen on the in-process kernel).
    sinkref = isdefined(mod, :__slate_bind_sink) ?
              Base.invokelatest(getfield, mod, :__slate_bind_sink) : nothing
    sinkref === nothing || (sinkref[] = NamedTuple[])

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
    binds = sinkref === nothing ? NamedTuple[] : copy(sinkref[])
    sinkref === nothing || (sinkref[] = nothing)
    stdout_str = fetch(reader)
    dur_ms = (time_ns() - t0) / 1e6

    # Capture the return value: an ECharts spec / a table are kept raw (reduced to
    # JSON-safe primitives here but JSON-*encoded* server-side, dodging JSON
    # world-age in the eval frame); otherwise the richest MIME. The table check
    # precedes rich MIME so a DataFrame renders as our interactive table rather
    # than its own `text/html` show method.
    # A cell whose last code line ends in `;` is "quiet" — suppress the RETURN
    # value's display (like the REPL / Jupyter). stdout and explicit `display(…)`
    # calls (already in `chunks`) still show.
    quiet = _is_quiet_cell(source)
    echarts = Any[]
    tables = Any[]
    if err === nothing && value !== nothing && !quiet
        if value isa EChart
            push!(echarts, value.option)
        elseif (st = (try Base.invokelatest(_as_slate_table, value) catch; nothing end)) !== nothing
            push!(tables, _table_wire(st))
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
    if err === nothing && value !== nothing && !quiet && isempty(chunks) && isempty(echarts) && isempty(tables)
        try
            value_repr = Base.invokelatest(sprint, show, MIME("text/plain"), value;
                                           context = :limit => true)
        catch
        end
    end
    # `include_string` wraps a cell's runtime error in a LoadError ("… in expression starting at
    # string:N"). Unwrap it so the cell shows the REAL error (UndefVarError, DomainError, …).
    realerr = err isa LoadError ? err.error : err
    exc = realerr === nothing ? nothing : sprint(showerror, realerr)
    # Trim our eval machinery (include_string + capture/gate frames below it) from the backtrace —
    # user/package frames sit above it — so the trace shows where the error actually is.
    bt = nothing
    if btrace !== nothing
        k = findfirst(ip -> any(f -> f.func === :include_string ||
                                     (f.func === :eval && occursin("boot.jl", string(f.file))),
                                Base.StackTraces.lookup(ip)), btrace)
        tb = k === nothing ? btrace : btrace[1:max(1, k - 1)]
        bt = sprint((io, t) -> Base.show_backtrace(io, t), tb)
    end

    return (stdout = stdout_str, mime = chunks, echarts = echarts, tables = tables,
            binds = binds, value_repr = value_repr, exception = exc, backtrace = bt,
            duration_ms = dur_ms)
end
