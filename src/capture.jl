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

import REPL       # for `REPL.softscope` — REPL-style cell eval (stdlib; always available)
import Logging    # to capture a cell's `@warn`/`@info` onto the redirected stderr (stdlib)

const _RICH_MIMES = ("image/svg+xml", "image/png", "text/html", "text/latex")

# ── Output size caps ─────────────────────────────────────────────────────────
# A cell that accidentally produces a giant result (a printed 10⁷-element loop, the text repr of a
# huge array, a multi-MB HTML dump) otherwise ships megabytes back over the gate and renders them
# into the page — bloating /state and freezing the tab. We cap each text stream at the worker, before
# any of it travels, with a clear truncation notice. The full value still lives in the namespace.
const _MAX_OUT_CHARS = 100_000      # per text stream: stdout, stderr, value repr
const _MAX_HTML_BYTES = 400_000     # per text/html | text/latex output chunk

function _cap_text(s::AbstractString, limit::Int = _MAX_OUT_CHARS)
    str = String(s)
    n = length(str)
    n <= limit && return str
    return string(first(str, limit), "\n\n… ⚠ truncated — ", n - limit,
                  " more characters. (Assign the result to a variable, or use `first(x, n)`, to inspect it.)")
end

# Evaluate a cell's `source` the way the REPL does, NOT like a file `include_string`:
# `REPL.softscope` rewrites top-level soft-scope assignments so a `for`/`while` can update an
# existing global without `local`/`global` (matching the REPL / IJulia / Pluto — the behaviour
# users expect from a notebook). `parseall` → a `:toplevel` block, so each statement runs in its
# own world (a `using`/`struct`/macro def is visible to later statements in the same cell), and
# `Core.eval` returns the last statement's value. `softscope` descends through the `@trace`
# wrapper too, so a traced loop works without `local` exactly like an untraced one. Parse errors
# surface as a catchable `ParseError`. `filename` becomes the backtrace location: the engine passes
# `"cell:<id>"` so a frame reads `cell:<id>:N` (→ cross-cell error jump); defaults to `"string"`.
_eval_cell_source(mod::Module, source::AbstractString, filename::AbstractString = "string") =
    Core.eval(mod, REPL.softscope(Meta.parseall(String(source); filename = String(filename))))

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

# ── Progress protocol bridge ─────────────────────────────────────────────────
# Julia's de-facto progress standard (ProgressLogging.jl, consumed by Pluto / VS Code /
# Juno / TerminalLoggers) is a LOG RECORD carrying a `progress` value (a Float 0..1,
# `nothing`, or "done") at `LogLevel(-1)`, identified by its log `id`. We wrap the cell's
# eval logger to intercept those records and funnel them into the SAME sink as a manual
# `slate_progress(frac; msg)` call — so a plain `@progress for …` loop, or any library that
# speaks the protocol, drives the cell meter with ZERO extra work. Everything else passes
# through to the parent (console) logger untouched. No dep on ProgressLogging: we match the
# `:progress` kwarg, which IS the wire protocol.
struct _ProgressLogger <: Logging.AbstractLogger
    parent::Logging.AbstractLogger
    sink                       # (id, frac::Float64, msg::String, done::Bool) -> Any  (cell progress channel)
end
Logging.shouldlog(::_ProgressLogger, _...) = true                          # filter in handle_message
Logging.min_enabled_level(l::_ProgressLogger) = min(Logging.LogLevel(-1), Logging.min_enabled_level(l.parent))
Logging.catch_exceptions(l::_ProgressLogger) = Logging.catch_exceptions(l.parent)

_progress_frac(p) = p === nothing                  ? 0.0 :
                    p isa AbstractString           ? (p == "done" ? 1.0 : 0.0) :
                    p isa Real                     ? (isnan(p) ? 0.0 : clamp(Float64(p), 0.0, 1.0)) : 0.0

function Logging.handle_message(l::_ProgressLogger, level, message, _module, group, id, file, line; kwargs...)
    if haskey(kwargs, :progress)                                            # a progress record → cell meter
        p = kwargs[:progress]
        # The log `id` keys the bar — each `@withprogress` scope (nested loops, parallel tasks) has
        # its own, so they render as separate bars. `progress="done"` ends a scope → remove its bar
        # (else each new nested scope's fresh id would pile up).
        bid = id === nothing ? "" : string(id)
        try; l.sink(bid, _progress_frac(p), message === nothing ? "" : string(message), p === "done"); catch; end
        return nothing                                                      # consume (don't echo to stderr)
    end
    Logging.shouldlog(l.parent, level, _module, group, id) &&
        Logging.handle_message(l.parent, level, message, _module, group, id, file, line; kwargs...)
    return nothing
end

# The progress sink for `mod`: the namespace's injected `slate_progress` (in-process → live cell
# update; worker → PUB on the gate stream), or a no-op on a bare module (tests).
function _progress_sink(mod::Module)
    isdefined(mod, :slate_progress) || return (_i, _f, _m, _d) -> nothing
    sp = getfield(mod, :slate_progress)
    return (i, f, m, d) -> (try; Base.invokelatest(sp, f; msg = m, id = i, done = d); catch; end)
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
function run_capture(mod::Module, source::AbstractString, filename::AbstractString = "string")
    chunks = Tuple{String,Vector{UInt8}}[]
    capture = _CaptureDisplay(chunks)
    pushdisplay(capture)
    original = stdout
    (rd, wr) = redirect_stdout()
    reader = @async read(rd, String)
    # Also capture stderr — `@warn`/`@info`/`@error` and any `print(stderr,…)` (deprecation and
    # soft-scope notices, user warnings). redirect_stderr catches direct writes; a `ConsoleLogger`
    # on that redirected stream (installed for the eval task below) catches the logging macros,
    # whose default logger would otherwise hold the original stderr.
    origerr = stderr
    (rde, wre) = redirect_stderr()
    ereader = @async read(rde, String)

    # Collect `@bind` controls declared during this eval — the namespace's injected
    # `__slate_bind` pushes to this sink. Absent on bare modules (e.g. tests) → no-op.
    sinkref = isdefined(mod, :__slate_bind_sink) ? getfield(mod, :__slate_bind_sink) : nothing
    sinkref === nothing || (sinkref[] = NamedTuple[])

    # `@trace` publishes its row buffer here (one per traced cell). Reset before eval; read after.
    tracesink = isdefined(mod, :__slate_trace_sink) ? getfield(mod, :__slate_trace_sink) : nothing
    tracesink === nothing || (tracesink[] = nothing)

    value = nothing
    err = nothing
    btrace = nothing
    t0 = time_ns()
    try
        # `ConsoleLogger(stderr)` — `stderr` is the redirected pipe now, so the macros land in
        # `ereader`. Non-colored (a pipe isn't a color tty), so no ANSI escapes reach the browser.
        # Console logger for @warn/@info/@error (→ ereader), wrapped so ProgressLogging
        # `@progress`/`progress=…` records drive the cell meter instead of printing.
        _logger = _ProgressLogger(Logging.ConsoleLogger(stderr), _progress_sink(mod))
        Logging.with_logger(_logger) do
            value = _eval_cell_source(mod, source, filename)
        end
    catch e
        err = e
        btrace = catch_backtrace()
    finally
        redirect_stdout(original)
        redirect_stderr(origerr)
        close(wr)
        close(wre)
        popdisplay(capture)
    end
    # Guard `sinkref[] === nothing` too (a cold-worker race can leave the bind sink uninitialised),
    # else `copy(nothing)` throws and the whole eval errors. Mirrors the trace-sink guard below.
    binds = (sinkref === nothing || sinkref[] === nothing) ? NamedTuple[] : copy(sinkref[])
    sinkref === nothing || (sinkref[] = nothing)
    # Trace rows the cell recorded (empty unless it was `@trace`-wrapped). JSON-safe Dicts, like `tables`.
    trace = (tracesink === nothing || tracesink[] === nothing) ? Any[] : _trace_wire(tracesink[])
    tracesink === nothing || (tracesink[] = nothing)
    stdout_str = _cap_text(fetch(reader))
    stderr_str = _cap_text(fetch(ereader))
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
            # `:displaysize` bounds how much `show` even generates for big containers (≈40 rows),
            # then `_cap_text` is the hard ceiling for anything still huge (e.g. a giant String value).
            value_repr = Base.invokelatest(sprint, show, MIME("text/plain"), value;
                                           context = (:limit => true, :displaysize => (40, 160)))
            value_repr = _cap_text(value_repr)
        catch
        end
    end
    # A cell's runtime error may still arrive wrapped in a LoadError (defensive — unwrap to the
    # REAL error: UndefVarError, DomainError, …). Parse errors arrive as `ParseError` directly.
    realerr = err isa LoadError ? err.error : err
    exc = realerr === nothing ? nothing : sprint(showerror, realerr)
    # Trim our eval machinery (the `Core.eval`/`_eval_cell_source` + capture/gate frames below it)
    # from the backtrace — user/package frames sit above it — so the trace shows where the error
    # actually is. `Core.eval` appears as `:eval` in boot.jl.
    bt = nothing
    if btrace !== nothing
        k = findfirst(ip -> any(f -> f.func === :_eval_cell_source ||
                                     (f.func === :eval && occursin("boot.jl", string(f.file))),
                                Base.StackTraces.lookup(ip)), btrace)
        tb = k === nothing ? btrace : btrace[1:max(1, k - 1)]
        bt = sprint((io, t) -> Base.show_backtrace(io, t), tb)
    end

    # Cap oversized text/html | text/latex chunks: truncating mid-markup would break the DOM, so an
    # over-limit chunk is replaced by a notice (the page can't render multi-MB HTML usefully anyway).
    for i in eachindex(chunks)
        (m, data) = chunks[i]
        if (m == "text/html" || m == "text/latex") && length(data) > _MAX_HTML_BYTES
            kb = round(Int, length(data) / 1024)
            chunks[i] = ("text/html",
                Vector{UInt8}("<div class=\"disp html\"><em>⚠ output too large to display ($(kb) KB) — truncated. Assign it to a variable to inspect.</em></div>"))
        end
    end

    return (stdout = stdout_str, mime = chunks, echarts = echarts, tables = tables,
            binds = binds, value_repr = value_repr, exception = exc, backtrace = bt,
            duration_ms = dur_ms, trace = trace, stderr = stderr_str)
end
