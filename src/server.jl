"""
    NotebookServer

The live, interactive notebook backend (interactivity layer 1). Holds a notebook
bound to a `.jl` file and serves a browser SPA plus a small JSON API. Editing a
cell reconciles → reactively recomputes only stale cells → persists back to the
`.jl` (so the agent and the browser share one source). Runs CLI-side, wrapping
the engine (`ReportEngine`) and per-cell renderer (`ReportRender`).
"""
module NotebookServer

using HTTP, JSON, FileWatching
import REPL
using ..ReportEngine
using ..ReportRender

export serve_notebook, start_server, LiveNotebook

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")

mutable struct LiveNotebook
    path::String
    report::Report
    version::Int                         # bumps on external (file) changes
    undo::Vector{String}                 # source snapshots (most recent last)
    redo::Vector{String}
end

function load_notebook(path::AbstractString)
    src = read(path, String)
    base = splitext(basename(path))[1]
    id = replace(base, r"[^A-Za-z0-9]" => "_")
    r = parse_report(src; id = id, title = base)
    build_dependencies!(r)
    eval_stale!(r)                       # initial full run
    return LiveNotebook(String(path), r, 0, String[], String[])
end

# Undo/redo over source snapshots. Call _snapshot! *before* a mutating op.
function _snapshot!(nb::LiveNotebook)
    push!(nb.undo, serialize_report(nb.report))
    length(nb.undo) > 100 && popfirst!(nb.undo)
    empty!(nb.redo)
end

function _restore!(nb::LiveNotebook, src::AbstractString)
    update_source!(nb.report, src)
    eval_stale!(nb.report)
    write(nb.path, serialize_report(nb.report))
end

function undo!(nb::LiveNotebook)
    isempty(nb.undo) && return nb
    push!(nb.redo, serialize_report(nb.report))
    _restore!(nb, pop!(nb.undo))
    return nb
end

function redo!(nb::LiveNotebook)
    isempty(nb.redo) && return nb
    push!(nb.undo, serialize_report(nb.report))
    _restore!(nb, pop!(nb.redo))
    return nb
end

# Pull in external edits (VS Code, the agent, …). Re-reads the file; if it differs
# (canonically) from our state, reconciles → runs stale → bumps version. Returns
# true if changed. The server's own writes match canonically, so they don't loop.
function sync_from_file!(nb::LiveNotebook)
    isfile(nb.path) || return false
    disk = read(nb.path, String)
    norm = try
        serialize_report(parse_report(disk; id = nb.report.id))
    catch
        return false                     # mid-save / unparseable — skip this tick
    end
    norm == serialize_report(nb.report) && return false
    update_source!(nb.report, disk)
    eval_stale!(nb.report)
    nb.version += 1
    return true
end

_echarts_specs(c::Cell) = c.output === nothing ? Any[] : c.output.echarts

function cell_json(c::Cell)
    d = Dict{String,Any}(
        "id"      => c.id,
        "kind"    => c.kind == MARKDOWN ? "md" : "code",
        "source"  => c.source,
        "state"   => lowercase(string(c.state)),
        "output"  => c.kind == MARKDOWN ? markdown_html(c.source) : output_html(c),
        "echarts" => c.kind == MARKDOWN ? String[] : _echarts_specs(c),
        "duration" => c.output === nothing ? nothing : round(c.output.duration_ms; digits = 1),
        "deps"    => collect(c.deps),
    )
    if c.bind !== nothing
        d["bind"] = Dict("name" => String(c.bind.name), "widget" => c.bind.widget,
                         "params" => c.bind.params, "value" => c.bind.value)
    end
    return d
end

# Set a widget's value → recompute its dependents (the reactive heart of @bind).
function set_bind!(nb::LiveNotebook, id::AbstractString, value)
    idx = findfirst(c -> c.id == id, nb.report.cells)
    idx === nothing && return nb
    cell = nb.report.cells[idx]
    cell.bind === nothing && return nb
    set_bind_value!(nb.report, cell, value)
    for did in dependents_of(nb.report, Set([id]))
        did == id && continue
        j = findfirst(c -> c.id == did, nb.report.cells)
        j === nothing || (nb.report.cells[j].state = STALE)
    end
    eval_stale!(nb.report)
    return nb
end
state_json(nb::LiveNotebook) =
    Dict("title"   => nb.report.title,
         "path"    => abspath(nb.path),
         "version" => nb.version,
         "cells"   => [cell_json(c) for c in nb.report.cells])

# Edit a cell's source → reconcile (mark it + dependents stale) → run stale →
# persist back to the `.jl`.
function edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString)
    cells = nb.report.cells
    idx = findfirst(c -> c.id == id, cells)
    idx === nothing && return nb
    cells[idx].source == String(source) || _snapshot!(nb)
    # Build the new full source with this cell swapped, WITHOUT disturbing report
    # state first — otherwise update_source! compares the new source to itself,
    # sees "unchanged", and never marks the cell stale (so it never re-runs).
    saved = cells[idx].source
    cells[idx].source = String(source)
    new_full = serialize_report(nb.report)
    cells[idx].source = saved
    update_source!(nb.report, new_full)
    eval_stale!(nb.report)
    write(nb.path, serialize_report(nb.report))
    return nb
end

# ── Structural ops (add / delete / move / change type) ───────────────────────

function _gen_id(report::Report)
    existing = Set(c.id for c in report.cells)
    while true
        id = string(hash(time_ns()) % 0xffffff; base = 16, pad = 6)
        id in existing || return id
    end
end

# A structural change at index `idx` reorders state, so conservatively restale
# everything from there on, recompute, and persist.
function _commit_structure!(nb::LiveNotebook, idx::Int)
    build_dependencies!(nb.report)
    for (i, c) in enumerate(nb.report.cells)
        i >= idx && (c.state = STALE)
    end
    eval_stale!(nb.report)
    write(nb.path, serialize_report(nb.report))
    return nb
end

_index_of(cells, id) = findfirst(c -> c.id == id, cells)

function add_cell!(nb::LiveNotebook, after_id::AbstractString, kind::AbstractString)
    _snapshot!(nb)
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    cell = Cell(_gen_id(nb.report), kind == "md" ? MARKDOWN : CODE, "")
    insert!(cells, i + 1, cell)
    _commit_structure!(nb, i + 1)
    return cell.id
end

function delete_cell!(nb::LiveNotebook, id::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb)
    deleteat!(nb.report.cells, i)
    _commit_structure!(nb, max(1, i))
end

function move_cell!(nb::LiveNotebook, id::AbstractString, dir::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    j = dir == "up" ? i - 1 : i + 1
    (j < 1 || j > length(cells)) && return nb
    _snapshot!(nb)
    cells[i], cells[j] = cells[j], cells[i]
    _commit_structure!(nb, min(i, j))
end

# Move `id` to just before/after `target_id` (drag-and-drop).
function move_cell_rel!(nb::LiveNotebook, id::AbstractString, target_id::AbstractString, before::Bool)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    c = cells[i]; deleteat!(cells, i)
    j = _index_of(cells, target_id)
    p = j === nothing ? length(cells) + 1 : (before ? j : j + 1)
    insert!(cells, p, c)
    _commit_structure!(nb, min(i, p))
end

function set_kind!(nb::LiveNotebook, id::AbstractString, kind::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    old = cells[i]
    cells[i] = Cell(old.id, kind == "md" ? MARKDOWN : CODE, old.source)
    _commit_structure!(nb, i)
end

_json(x) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(x))

# HTTP 2.0: request body is a BytesBody wrapper; read it as a String.
function _body(req)
    s = String(req.body)
    return isempty(s) ? Dict{String,Any}() : JSON.parse(s)
end

# ── Live push over SSE ───────────────────────────────────────────────────────
const _LISTENERS = Channel{String}[]
const _LLOCK = ReentrantLock()

function _broadcast(msg::AbstractString)
    lock(_LLOCK) do
        for ch in _LISTENERS
            try
                isopen(ch) && Base.n_avail(ch) < 32 && put!(ch, String(msg))
            catch
            end
        end
    end
end

# One SSE connection over a raw `HTTP.Stream` (HTTP 2.0's documented streaming
# pattern — `listen!` + a `Stream` handler). Registers a channel, streams the
# current version on connect, then `data: <version>` on each change and `: hb`
# comment-line heartbeats (which the browser ignores) so a dead connection
# surfaces as a failed write that ends the loop. Each `write` flushes as its own
# chunk — unlike the high-level `sse_stream`/`SSEStream`, whose chunked writer
# blocks for a full 16 KiB buffer before flushing and so can't drive a long-lived
# push connection.
function _sse(stream::HTTP.Stream, nb::LiveNotebook)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    ch = Channel{String}(32)
    lock(_LLOCK) do; push!(_LISTENERS, ch); end
    try
        write(stream, "data: $(nb.version)\n\n")
        while true
            msg = take!(ch)
            write(stream, msg == "hb" ? ": hb\n\n" : "data: $msg\n\n")
        end
    catch
    finally
        lock(_LLOCK) do; filter!(c -> c !== ch, _LISTENERS); end
        close(ch)
    end
    return nothing
end

# Watch the file for external edits (VS Code / agent) → sync → push instantly.
# `watch_file` returns on change (instant) or after a 2s safety timeout (covers
# editors that save via atomic rename). Server's own writes match canonically in
# `sync_from_file!`, so they don't echo back.
function _start_watcher!(nb::LiveNotebook)
    @async while true
        try
            FileWatching.watch_file(nb.path, 2.0)
            sync_from_file!(nb) && _broadcast(string(nb.version))
        catch
            sleep(0.5)
        end
    end
    @async while true
        sleep(15)
        _broadcast("hb")
    end
end

function _make_router(nb::LiveNotebook)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/",
        _ -> HTTP.Response(200, ["Content-Type" => "text/html"], read(_ASSET, String)))
    HTTP.register!(router, "GET", "/api/state", _ -> (sync_from_file!(nb); _json(state_json(nb))))
    HTTP.register!(router, "POST", "/api/cell/{id}", req -> begin
        id = HTTP.getparam(req, "id")
        body = _body(req)
        edit_cell!(nb, id, get(body, "source", ""))
        _json(state_json(nb))
    end)
    HTTP.register!(router, "POST", "/api/complete", req -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        pos = clamp(Int(get(body, "pos", ncodeunits(code))), 0, ncodeunits(code))
        mod = nb.report.mod === nothing ? Main : nb.report.mod
        texts, from, to = try
            comps, range, _ = REPL.REPLCompletions.completions(code, pos, mod)
            ([REPL.REPLCompletions.completion_text(c) for c in comps], first(range) - 1, last(range))
        catch
            (String[], pos, pos)
        end
        _json(Dict("completions" => texts, "from" => from, "to" => to))
    end)
    HTTP.register!(router, "POST", "/api/cell-add", req -> begin
        b = _body(req)
        add_cell!(nb, get(b, "after", ""), get(b, "kind", "code"))
        _json(state_json(nb))
    end)
    HTTP.register!(router, "POST", "/api/cell-delete/{id}", req ->
        (delete_cell!(nb, HTTP.getparam(req, "id")); _json(state_json(nb))))
    HTTP.register!(router, "POST", "/api/cell-move/{id}", req -> begin
        b = _body(req)
        id = HTTP.getparam(req, "id")
        haskey(b, "target") ? move_cell_rel!(nb, id, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, id, get(b, "dir", "up"))
        _json(state_json(nb))
    end)
    HTTP.register!(router, "POST", "/api/cell-type/{id}", req -> begin
        b = _body(req)
        set_kind!(nb, HTTP.getparam(req, "id"), get(b, "kind", "code"))
        _json(state_json(nb))
    end)
    HTTP.register!(router, "POST", "/api/bind/{id}", req -> begin
        id = HTTP.getparam(req, "id")
        body = _body(req)
        set_bind!(nb, id, get(body, "value", nothing))
        _json(state_json(nb))
    end)
    HTTP.register!(router, "POST", "/api/undo", _ -> (undo!(nb); _json(state_json(nb))))
    HTTP.register!(router, "POST", "/api/redo", _ -> (redo!(nb); _json(state_json(nb))))
    HTTP.register!(router, "POST", "/api/run", _ -> (eval_stale!(nb.report); _json(state_json(nb))))
    HTTP.register!(router, "POST", "/api/reset", _ -> begin
        reset_module!(nb.report); build_dependencies!(nb.report); eval_stale!(nb.report)
        _json(state_json(nb))
    end)
    return router
end

"""
    start_server(path; host="127.0.0.1", port=8765) -> HTTP.Server

Load the notebook at `path` and start serving its interactive browser UI.
**Non-blocking** — returns the running `HTTP.Server` immediately (call `close`
on it to stop). Use this when managing notebook servers programmatically (e.g.
the Kaimon extension). For a blocking launcher, use [`serve_notebook`](@ref).
"""
function start_server(path::AbstractString; host = "127.0.0.1", port = 8765)
    nb = load_notebook(path)
    handle = HTTP.streamhandler(_make_router(nb))   # normal routes as a stream handler
    _start_watcher!(nb)
    @info "Notebook server" url = "http://$host:$port" file = abspath(path) cells = length(nb.report.cells)
    return HTTP.listen!(host, port) do stream::HTTP.Stream
        stream.message.target == "/api/events" ? _sse(stream, nb) : handle(stream)
    end
end

"""
    serve_notebook(path; host="127.0.0.1", port=8765)

Load the notebook at `path` and serve the interactive browser UI. **Blocks** until
the server stops (wraps [`start_server`](@ref)).
"""
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765)
    server = start_server(path; host = host, port = port)
    wait(server)
    return server
end

end # module NotebookServer
