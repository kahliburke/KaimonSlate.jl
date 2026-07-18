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
const _MAX_OUT_CHARS = 100_000      # per text stream: stdout, stderr, value repr (RENDERED to page)
const _MAX_HTML_BYTES = 4_000_000   # per text/html | text/latex output chunk (RENDERED to page) —
                                    # generous so rich HTML (dashboards, custom pages with inline images)
                                    # renders inline; modern browsers handle a few MB fine.
# Hard ceiling on the FULL result we keep on disk for "open the full output" (new tab / editor /
# download). Configurable from the UI (server pushes the user's setting into this Ref). Beyond it,
# even the saved file is clipped — guards against a pathological multi-GB repr eating the disk.
const _MAX_KEEP_BYTES = Ref(50_000_000)

_cap_text(s::AbstractString, limit::Int = _MAX_OUT_CHARS) =
    (str = String(s); length(str) <= limit ? str :
     string(first(str, limit), "\n\n… ⚠ truncated — ", length(str) - limit, " more characters."))

# Persist an oversized result so the UI can offer the full thing. Writes (up to _MAX_KEEP_BYTES) to a
# content-addressed temp file; returns (path, bytes_kept, clipped) or nothing on failure. Same dir on
# every machine since worker + server share the filesystem (the server serves/links the path).
# Under $HOME (not tempdir()): the gate worker is spawned with a controlled env and may resolve a
# DIFFERENT tempdir() than the server, which would then fail to find the file. $HOME is shared.
_overflow_dir() = (d = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "kaimonslate", "overflow"); mkpath(d); d)
function _write_overflow(content::AbstractString, ext::AbstractString)
    try
        data = codeunits(String(content))
        cap = _MAX_KEEP_BYTES[]
        clipped = length(data) > cap
        kept = clipped ? data[1:cap] : data
        path = joinpath(_overflow_dir(), string(string(hash(kept); base = 16), ".", ext))
        isfile(path) || write(path, kept)
        return (path, length(kept), clipped)
    catch
        return nothing
    end
end
# Cap a text stream for display AND record an overflow file (for full access) when it's over-limit.
function _cap_keep!(overflow::Vector, kind::AbstractString, full::AbstractString, ext::AbstractString = "txt")
    s = String(full)
    length(s) <= _MAX_OUT_CHARS && return s
    info = _write_overflow(s, ext)
    info === nothing || push!(overflow, (kind = kind, path = info[1], bytes = info[2], clipped = info[3]))
    return string(first(s, _MAX_OUT_CHARS), "\n\n… ⚠ truncated for display — full result available below.")
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
# Per-statement attribution for the cell-effects channel (see `_slate_effect`): set the task-local
# "which top-level statement is executing" so a `slate_effect(…)` call made from inside statement `i`
# (e.g. the `register_op!` a `@defop` expands to) is attributed to THAT statement — whose deparsed
# source becomes the replay unit in the durable effect store. A trivial inert call; never errors.
_slate_mark_stmt(i::Int) = (task_local_storage(:slate_stmt, i); nothing)

# Evaluate a cell's `source` the way the REPL does — ONE `Core.eval` of the parsed `:toplevel` block so
# world-advancement + softscope + last-value semantics are exactly today's — but with a `_slate_mark_stmt`
# marker spliced before each real top-level statement (original `LineNumberNode`s kept, so backtraces are
# unchanged; markers inherit the preceding line). The per-statement deparsed sources are stashed in
# `:slate_stmt_srcs` for the harvest to resolve each declared effect's statement index → its source text.
function _eval_cell_source(mod::Module, source::AbstractString, filename::AbstractString = "string")
    ast = Meta.parseall(String(source); filename = String(filename))
    (ast isa Expr && ast.head === :toplevel) ||
        return Core.eval(mod, REPL.softscope(ast))   # a single-expr / non-toplevel parse: no per-statement marking
    srcs = String[]
    marked = Any[]
    for a in ast.args
        if a isa LineNumberNode
            push!(marked, a)
        else
            push!(srcs, string(a))                                   # deparsed statement source (replay unit)
            push!(marked, Expr(:call, _slate_mark_stmt, length(srcs)))   # mark before running it
            push!(marked, a)
        end
    end
    task_local_storage(:slate_stmt_srcs, srcs)
    return Core.eval(mod, REPL.softscope(Expr(:toplevel, marked...)))
end

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
            bytes = Base.invokelatest(_mime_bytes, MIME(m), x)
            m == "text/html" && (bytes = _fix_at_refs(bytes))
            push!(chunks, (m, bytes))
            startswith(m, "image/") && _capture_export_vector!(chunks, x)
            return true
        end
    end
    return false
end

# Documenter `[foo](@ref)` cross-references render (via Markdown/CommonMark, e.g. a cell's `@doc name`
# output) as `<a href="@ref">…</a>`, whose relative href resolves to `/n/@ref` → 404. Rewrite each to an
# inert `<span class="docref" data-name="…">`: the LIVE notebook wires a click on it to open the docs
# dock for that symbol (see outputs.js), while a static EXPORT — no such handler, no `#nb` styling —
# degrades it to plain text. Either way, no broken link. Guarded on the literal `@ref`, so it's a no-op
# on any other HTML and only ever touches rendered docstrings.
const _ATREF_RE = r"<a href=\"@ref([^\"]*)\">(.*?)</a>"s
_attr_esc(s) = replace(String(s), '&' => "&amp;", '"' => "&quot;", '<' => "&lt;", '>' => "&gt;")
# Decode the HTML entities Markdown emits inside a symbol name (`assign&#33;` → `assign!`, `f&#40;x&#41;`
# → `f(x)`) so `data-name` is the real identifier `openDocsFor()` looks up, not its escaped form.
function _html_unescape(s::AbstractString)
    s = replace(s, r"&#(\d+);" => m -> string(Char(parse(Int, SubString(m, 3, lastindex(m) - 1)))))
    return replace(s, "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"")
end
function _atref_span(matched::AbstractString)
    m = match(_ATREF_RE, matched)
    tgt = strip(replace(String(m.captures[1]), "%20" => " "))          # explicit `@ref target`, if any
    inner = m.captures[2]                                              # the link's rendered content
    sym = isempty(tgt) ? strip(replace(inner, r"<[^>]*>" => "")) : tgt  # else the symbol it displays
    return string("<span class=\"docref\" data-name=\"", _attr_esc(_html_unescape(sym)), "\">", inner, "</span>")
end
function _fix_at_refs(bytes::Vector{UInt8})
    s = String(copy(bytes))
    occursin("\"@ref", s) || return bytes
    return Vector{UInt8}(replace(s, _ATREF_RE => _atref_span))
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

# A task-local capture display for the worker's PARALLEL evaluators. One instance is pushed onto the
# display stack ONCE (at worker start); each `display(x)` routes to the CURRENT task's chunk vector
# (set in task-local storage by DemuxCapture), so concurrent cells don't cross-capture. Non-cell tasks
# (no `:slate_chunks`) fall through to the rest of the stack.
struct _DemuxDisplay <: AbstractDisplay end
function Base.display(d::_DemuxDisplay, x)
    chunks = get(task_local_storage(), :slate_chunks, nothing)
    (chunks !== nothing && _capture_rich!(chunks, x)) && return nothing
    throw(MethodError(display, (d, x)))
end

# ── Output-capture strategy (pluggable) ─────────────────────────────────────────────────────────
# `run_capture` redirects a cell's stdout/stderr/display while it evals. That's PROCESS-GLOBAL, fine
# for the one-at-a-time in-process kernel — but the gate worker runs a POOL of cells at once, so it
# needs TASK-LOCAL capture instead. Both implement the same 3-step contract; run_capture is otherwise
# identical, so all the value/MIME/binds/trace/overflow logic is shared.
abstract type OutputCapture end

# Process-global redirect + pushdisplay — one cell at a time (in-process kernel, and the worker's
# serial lane). Exactly the original behaviour.
mutable struct RedirectCapture <: OutputCapture
    disp::Any; orig_out::Any; rd::Any; wr::Any; reader::Any; orig_err::Any; rde::Any; wre::Any; ereader::Any
    RedirectCapture() = new(ntuple(_ -> nothing, 9)...)
end
function _begin_capture!(c::RedirectCapture, chunks)
    c.disp = _CaptureDisplay(chunks); pushdisplay(c.disp)
    c.orig_out = stdout; (c.rd, c.wr) = redirect_stdout(); c.reader = @async read(c.rd, String)
    c.orig_err = stderr; (c.rde, c.wre) = redirect_stderr(); c.ereader = @async read(c.rde, String)
    return nothing
end
_logio(c::RedirectCapture) = stderr        # the (now redirected) stderr
function _finish_capture!(c::RedirectCapture)
    redirect_stdout(c.orig_out); redirect_stderr(c.orig_err)
    close(c.wr); close(c.wre)
    try; popdisplay(c.disp); catch; end
    return (fetch(c.reader), fetch(c.ereader))
end

# Task-local capture via the worker's installed DemuxIO + _DemuxDisplay (see demux.jl). Concurrency-
# safe: every key lives in THIS task's storage, so parallel evaluators never share a buffer. Requires
# the demux to be installed as Base.stdout/stderr and a `_DemuxDisplay` on the stack (worker start).
mutable struct DemuxCapture <: OutputCapture
    out::IOBuffer; err::IOBuffer
    DemuxCapture() = new(IOBuffer(), IOBuffer())
end
function _begin_capture!(c::DemuxCapture, chunks)
    tls = task_local_storage()
    tls[:slate_out] = c.out; tls[:slate_err] = c.err; tls[:slate_chunks] = chunks
    return nothing
end
_logio(::DemuxCapture) = stderr            # stderr IS the demux → routes to this task's :slate_err
function _finish_capture!(c::DemuxCapture)
    tls = task_local_storage()
    for k in (:slate_out, :slate_err, :slate_chunks); haskey(tls, k) && delete!(tls, k); end
    return (String(take!(c.out)), String(take!(c.err)))
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
# Slate's task-local EXECUTION CONTEXT, exposed to cell code as `task_local_storage()[:slate_ctx]` — a
# generic `(; region, notebook, side, emit, regions)` any package can read WITHOUT depending on
# KaimonSlate (a zero-dependency convention: e.g. a region-aware DSL that defaults its `region`/`emit`
# args from it). `emit` is the module's OWN `slate_emit` (worker → gate stream; in-process → SSE), so a
# value pushed through it lands on the right transport. `region` is the effective side as a Symbol
# (`nothing` on the main kernel), `side` its string spelling (`""` = main), `regions` the declared
# region names. Built on the eval side (only there is the module's live `slate_emit` known).
# The OUTBOUND half of the seam (code → Slate): a running cell / a package it calls DECLARES an effect
# ("establish this on every worker", "memoize me", …) which the hub harvests and acts on. Transport-free —
# just pushes to the task-local `:slate_effects` sink, attributed to the executing statement
# (`:slate_stmt`); `run_capture` resolves the statement index → source and returns the records in the wire.
# A no-op outside a harvesting eval (no sink), so a package can call it unconditionally.
function _slate_effect(kind::Symbol; names = Symbol[], data...)
    sink = get(task_local_storage(), :slate_effects, nothing)
    sink === nothing && return nothing
    push!(sink, (; kind = Symbol(kind),
                   names = Symbol[Symbol(n) for n in names],
                   stmt = Int(get(task_local_storage(), :slate_stmt, 0)),
                   data = NamedTuple(data)))
    return nothing
end

# Resolve the raw `:slate_effects` records (statement INDEX) against the deparsed statement sources into
# wire records (`stmt_src` — the replay unit), deduped by (kind, names, stmt_src). Empty when the cell
# declared nothing. Robust to an out-of-range index (→ "") so a bad marker can't error the harvest.
function _harvest_effects(raw, srcs::AbstractVector)
    (raw === nothing || isempty(raw)) && return Any[]
    out = Any[]; seen = Set{Tuple{Symbol,Vector{Symbol},String}}()
    for e in raw
        src = (1 <= e.stmt <= length(srcs)) ? String(srcs[e.stmt]) : ""
        key = (e.kind, e.names, src)
        key in seen && continue
        push!(seen, key)
        push!(out, (; kind = e.kind, names = e.names, stmt_src = src, data = e.data))
    end
    return out
end

function _build_slate_ctx(mod::Module, notebook::AbstractString, region::AbstractString,
                          regions::AbstractVector)
    emit = isdefined(mod, :slate_emit) ? getfield(mod, :slate_emit) : (channel, value) -> nothing
    return (; region   = isempty(region) ? nothing : Symbol(region),
              notebook = String(notebook),
              side     = String(region),
              emit     = emit,
              regions  = Symbol[Symbol(r) for r in regions],
              effect   = _slate_effect)          # code→Slate declaration channel (zero-dep for packages)
end

function run_capture(mod::Module, source::AbstractString, filename::AbstractString = "string";
                     capture::OutputCapture = RedirectCapture(), slate_ctx = nothing)
    chunks = Tuple{String,Vector{UInt8}}[]
    # Begin output capture (stdout/stderr + display) via the strategy: process-global redirect for the
    # in-process/serial kernel, or task-local demux for the worker's parallel evaluators. The strategy
    # captures the SAME `chunks` (display) + provides the stderr the logger writes to.
    _begin_capture!(capture, chunks)

    # Collect `@bind` controls declared during this eval into a TASK-LOCAL sink, so concurrently
    # evaluated cells (the parallel batch) never race on one shared vector. `__slate_bind` (widgets.jl)
    # pushes to `task_local_storage(:__slate_binds)`; bare modules that never bind just leave it empty.
    task_local_storage(:__slate_binds, NamedTuple[])

    # Slate's task-local execution context for THIS eval (see `_build_slate_ctx`). Set here and cleared
    # in the `finally` so it never leaks across cells that share a task (the parallel batch reuses tasks);
    # `nothing` ⇒ leave it unset (a plain `run_capture` with no notebook context, e.g. `__slate_interp`).
    slate_ctx === nothing || task_local_storage(:slate_ctx, slate_ctx)

    # Cell-effects sink (see `_slate_effect`): declarations a cell / a package it calls makes during eval,
    # attributed to the executing statement. Seeded here, harvested + cleared after the eval — like the
    # `@bind` sink. `:slate_stmt`/`:slate_stmt_srcs` are (re)set by `_eval_cell_source`'s statement markers.
    task_local_storage(:slate_effects, Any[])

    # `@trace` publishes its row buffer here (one per traced cell). Reset before eval; read after.
    tracesink = isdefined(mod, :__slate_trace_sink) ? getfield(mod, :__slate_trace_sink) : nothing
    tracesink === nothing || (tracesink[] = nothing)

    value = nothing
    err = nothing
    btrace = nothing
    raw_out = ""; raw_err = ""
    t0 = time_ns()
    try
        # ConsoleLogger on the captured stderr (`_logio`), so @warn/@info/@error land in this cell's
        # stream. Non-colored (not a color tty), wrapped so ProgressLogging `@progress` records drive
        # the cell meter instead of printing.
        _logger = _ProgressLogger(Logging.ConsoleLogger(_logio(capture)), _progress_sink(mod))
        Logging.with_logger(_logger) do
            value = _eval_cell_source(mod, source, filename)
        end
    catch e
        err = e
        btrace = catch_backtrace()
    finally
        raw_out, raw_err = _finish_capture!(capture)
        slate_ctx === nothing || delete!(task_local_storage(), :slate_ctx)   # never outlive this eval
    end
    binds = copy(get(task_local_storage(), :__slate_binds, NamedTuple[]))
    delete!(task_local_storage(), :__slate_binds)
    # Harvest the cell-effect declarations: resolve each record's statement index → its deparsed source
    # (the replay unit), dedup by (kind, names, stmt_src). Then clear the eval-scoped task-local keys.
    effects = _harvest_effects(get(task_local_storage(), :slate_effects, nothing),
                               get(task_local_storage(), :slate_stmt_srcs, String[]))
    for k in (:slate_effects, :slate_stmt, :slate_stmt_srcs)
        haskey(task_local_storage(), k) && delete!(task_local_storage(), k)
    end
    # Trace rows the cell recorded (empty unless it was `@trace`-wrapped). JSON-safe Dicts, like `tables`.
    trace = (tracesink === nothing || tracesink[] === nothing) ? Any[] : _trace_wire(tracesink[])
    tracesink === nothing || (tracesink[] = nothing)
    overflow = NamedTuple[]                       # full results saved to disk for "open full output"
    stdout_str = _cap_keep!(overflow, "stdout", raw_out, "txt")
    stderr_str = _cap_keep!(overflow, "stderr", raw_err, "txt")
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
    animations = Any[]
    if err === nothing && value !== nothing && !quiet
        # A bare Matrix/SparseMatrixCSC/structured-LinearAlgebra return auto-renders via
        # slate_matrix (KaTeX / dotted notation / downsampled heatmap, picked by size and
        # type) instead of dumping the terminal grid below — replace, then fall through the
        # SAME dispatch (a heatmap comes back as an EChart; the KaTeX forms fall to the
        # generic rich-MIME branch below via their `show(io, MIME"text/latex", …)` method).
        if value isa AbstractMatrix
            value = try; Base.invokelatest(slate_matrix, value); catch; value; end
        end
        if value isa EChart
            push!(echarts, value.option)
        elseif value isa Animation
            push!(animations, (manifest = value.manifest, frames = value.frames, lut = value.lut))
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
    if err === nothing && value !== nothing && !quiet && isempty(chunks) && isempty(echarts) && isempty(tables) && isempty(animations)
        try
            # `:displaysize` bounds how much `show` even generates for big containers (≈40 rows),
            # then `_cap_text` is the hard ceiling for anything still huge (e.g. a giant String value).
            value_repr = Base.invokelatest(sprint, show, MIME("text/plain"), value;
                                           context = (:limit => true, :displaysize => (40, 160)))
            value_repr = _cap_keep!(overflow, "value", value_repr, "txt")
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
            info = _write_overflow(String(copy(data)), "html")
            info === nothing || push!(overflow, (kind = "output", path = info[1], bytes = info[2], clipped = info[3]))
            kb = round(Int, length(data) / 1024)
            chunks[i] = ("text/html",
                Vector{UInt8}("<div class=\"disp html\"><em>⚠ output too large to render ($(kb) KB) — full result available below.</em></div>"))
        end
    end

    return (stdout = stdout_str, mime = chunks, echarts = echarts, tables = tables,
            binds = binds, value_repr = value_repr, exception = exc, backtrace = bt,
            duration_ms = dur_ms, trace = trace, stderr = stderr_str, overflow = overflow,
            animations = animations, effects = effects)
end
