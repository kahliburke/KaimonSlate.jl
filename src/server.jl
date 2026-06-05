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

include("history.jl")   # module SlateHistory — durable content-addressed time machine

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")

mutable struct LiveNotebook
    id::String                           # hub id (unique; used in /n/<id> + /api/<id>/…)
    path::String
    report::Report
    kernel::Kernel                       # where cells eval (in-process or per-notebook gate worker)
    version::Int                         # bumps on external (file) changes
    undo::Vector{String}                 # source snapshots (most recent last)
    redo::Vector{String}
    lock::ReentrantLock                  # serializes eval (UI actions vs. async refresh)
    listeners::Vector{Channel{String}}   # this notebook's live SSE connections
    llock::ReentrantLock                 # protects `listeners`
    agent_id::String                     # Kaimon agent session bound to this notebook ("" = none)
    agent_busy::Bool                     # true while the bound agent has a turn in flight (for history attribution)
end

# GateKernel when running as the Kaimon extension AND the notebook is inside a
# Julia project (cells eval in a per-notebook worker); else in-process.
function _select_kernel(path::AbstractString)
    if ReportEngine.gate_available()
        proj = Base.current_project(dirname(abspath(path)))
        proj === nothing ?
            (@warn "KaimonSlate: no enclosing project for $path — using in-process kernel") :
            return GateKernel(dirname(proj))
    end
    return InProcessKernel()
end

function load_notebook(path::AbstractString; id::AbstractString = "")
    src = read(path, String)
    base = splitext(basename(path))[1]
    rid = replace(base, r"[^A-Za-z0-9]" => "_")
    nbid = isempty(id) ? rid : String(id)
    r = parse_report(src; id = rid, title = base)
    build_dependencies!(r)
    kernel = _select_kernel(path)
    eval_stale!(r, kernel)               # initial full run
    nb = LiveNotebook(nbid, String(path), r, kernel, 0, String[], String[],
                      ReentrantLock(), Channel{String}[], ReentrantLock(), "", false)
    # Seed the durable history with the initial state, so the very first edit has a
    # parent to diff against and the "buildup" replay starts from the true origin.
    _history!(nb; source = "open")
    # Async cells call `slate_refresh(:x)` → recompute readers of x + push live.
    register_refresh!(r.id, vars -> server_refresh(nb, vars))
    return nb
end

# Reactive push triggered by a cell's async task (`slate_refresh(:data, …)`):
# restale the cells that READ those vars (but not the producers that WRITE them,
# so we don't re-trigger the task), recompute, and push a lightweight live update.
function server_refresh(nb::LiveNotebook, vars)
    syms = Set{Symbol}(vars)
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            c.kind == CODE || continue
            (!isdisjoint(c.reads, syms) && isdisjoint(c.writes, syms)) || continue
            c.state = STALE
            push!(seed, c.id)
        end
        isempty(seed) && return
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing || (nb.report.cells[i].state = STALE)
        end
        eval_stale!(nb.report, nb.kernel)
    end
    _broadcast(nb, "refresh")
    return nothing
end

# Undo/redo over source snapshots. Call _snapshot! *before* a mutating op.
function _snapshot!(nb::LiveNotebook)
    push!(nb.undo, serialize_report(nb.report))
    length(nb.undo) > 100 && popfirst!(nb.undo)
    empty!(nb.redo)
end

function _restore!(nb::LiveNotebook, src::AbstractString)
    update_source!(nb.report, src)
    eval_stale!(nb.report, nb.kernel)
    _persist!(nb; source = "restore")
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

# ── Durable history (the time machine) ───────────────────────────────────────
# Capture the *current* notebook state into the append-only store. Dedup-by-hash
# makes a no-op capture free, so this is safe to call liberally (every op, every
# sync, the periodic draft net). Per-cell digests let the UI attribute + recover
# individual cells. Never throws into the caller.
_cells_of(report) = [(c.id, c.kind == MARKDOWN ? "md" : "code", c.source) for c in report.cells]
function _history!(nb::LiveNotebook; source::AbstractString = "browser", kind::AbstractString = "checkpoint")
    try
        SlateHistory.record!(nb.path, serialize_report(nb.report);
                             source_label = source, kind = kind, cells = _cells_of(nb.report))
    catch e
        @warn "KaimonSlate: history capture failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# Persist the notebook to its `.jl` AND record a durable checkpoint. The single
# write+capture chokepoint for in-app mutations (replaces bare `write(...)`).
function _persist!(nb::LiveNotebook; source::AbstractString = "browser")
    write(nb.path, serialize_report(nb.report))
    _history!(nb; source = source)
    return nb
end

# Restore the notebook to a recorded state (by content hash). Append-only and
# non-destructive: the current state goes onto the in-memory undo stack and the
# restore is itself recorded as a new "restore" checkpoint — you can always come
# straight back. Returns true on success.
function restore_history!(nb::LiveNotebook, hash::AbstractString)
    src = SlateHistory.content(nb.path, hash)
    src === nothing && return false
    lock(nb.lock) do
        _snapshot!(nb)
        _restore!(nb, src)            # applies, runs, persists as source="restore"
        nb.version += 1
    end
    _broadcast(nb, string(nb.version))
    return true
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
    eval_stale!(nb.report, nb.kernel)
    nb.version += 1
    # External write (agent mid-turn → "agent", else a human in another editor).
    _history!(nb; source = nb.agent_busy ? "agent" : "external")
    return true
end

_echarts_specs(c::Cell) = c.output === nothing ? Any[] : c.output.echarts
_table_specs(c::Cell) = c.output === nothing ? Any[] : c.output.tables
# Specs from a markdown cell's `{{ }}` interpolations, in document order (matches
# the `.ichart`/`.itable` placeholder indices the renderer emits).
_md_interp_echarts(c::Cell) = (e = Any[]; for o in c.interp; append!(e, o.echarts); end; e)
_md_interp_tables(c::Cell) = (t = Any[]; for o in c.interp; append!(t, o.tables); end; t)

# A bound control resolved for the frontend: enough to render the widget *and*
# POST value changes to `/api/bind/<id>` (the *defining* cell's id) keyed by
# variable name, regardless of which cell surfaces it.
_control_spec(cell::Cell, spec::BindSpec) =
    Dict{String,Any}("id" => cell.id, "name" => String(spec.name),
                     "widget" => spec.widget, "params" => spec.params, "value" => spec.value)

_bind_json(spec::BindSpec, hosted::Bool) =
    Dict{String,Any}("name" => String(spec.name), "widget" => spec.widget,
                     "params" => spec.params, "value" => spec.value, "hosted" => hosted)

# `bindref`: var-name → (defining cell, its BindSpec). `hostednames`: variable
# names surfaced via some cell's `controls=` (so each collapses to a chip).
function cell_json(c::Cell, bindref::Dict{String,Tuple{Cell,BindSpec}} = Dict{String,Tuple{Cell,BindSpec}}(),
                   hostednames::Set{String} = Set{String}())
    d = Dict{String,Any}(
        "id"      => c.id,
        "kind"    => c.kind == MARKDOWN ? "md" : "code",
        "source"  => c.source,
        "state"   => lowercase(string(c.state)),
        "output"  => c.kind == MARKDOWN ? markdown_html(c.source, c.interp) : output_html(c),
        "echarts" => c.kind == MARKDOWN ? _md_interp_echarts(c) : _echarts_specs(c),
        "tables" => c.kind == MARKDOWN ? _md_interp_tables(c) : _table_specs(c),
        "duration" => c.output === nothing ? nothing : round(c.output.duration_ms; digits = 1),
        "deps"    => collect(c.deps),
    )
    if !isempty(c.controls)
        # resolve each column's names to (defining cell, spec); drop unknown names + empty columns
        cols = [[_control_spec(bindref[n]...) for n in col if haskey(bindref, n)] for col in c.controls]
        cols = filter(!isempty, cols)
        isempty(cols) || (d["controls"] = cols)
    end
    if !isempty(c.binds)
        d["binds"] = [_bind_json(b, String(b.name) in hostednames) for b in c.binds]
    end
    return d
end

# Set widget `name` (defined by cell `id`) → recompute its dependents (the
# reactive heart of @bind). A group cell's blast radius is by cell id, which is
# conservative (touches readers of any of its vars) but never under-invalidates.
function set_bind!(nb::LiveNotebook, id::AbstractString, name::AbstractString, value)
    idx = findfirst(c -> c.id == id, nb.report.cells)
    idx === nothing && return nb
    cell = nb.report.cells[idx]
    isempty(cell.binds) && return nb
    lock(nb.lock) do
        set_bind_value!(nb.report, cell, Symbol(name), value, nb.kernel)
        for did in dependents_of(nb.report, Set([id]))
            did == id && continue
            j = findfirst(c -> c.id == did, nb.report.cells)
            j === nothing || (nb.report.cells[j].state = STALE)
        end
        eval_stale!(nb.report, nb.kernel)
    end
    return nb
end

# Index every bound variable by name → (defining cell, spec), and the set of
# variable names surfaced in some cell's control strip.
function _bind_index(report::Report)
    bindref = Dict{String,Tuple{Cell,BindSpec}}()
    for c in report.cells, b in c.binds
        bindref[String(b.name)] = (c, b)
    end
    hostednames = Set{String}()
    for c in report.cells, col in c.controls, n in col
        haskey(bindref, n) && push!(hostednames, n)
    end
    return bindref, hostednames
end

# Worker/kernel status for the topbar dot.
_kernel_status(k::GateKernel) = Dict{String,Any}("kind" => "gate", "port" => k.port, "connected" => (k.conn !== nothing))
_kernel_status(::Kernel) = Dict{String,Any}("kind" => "inproc", "port" => 0, "connected" => true)

function state_json(nb::LiveNotebook)
    bindref, hostednames = _bind_index(nb.report)
    return Dict("id"      => nb.id,
                "title"   => nb.report.title,
                "path"    => abspath(nb.path),
                "version" => nb.version,
                "worker"  => _kernel_status(nb.kernel),
                "cells"   => [cell_json(c, bindref, hostednames) for c in nb.report.cells])
end

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
    eval_stale!(nb.report, nb.kernel)
    _persist!(nb)
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
    eval_stale!(nb.report, nb.kernel)
    _persist!(nb)
    return nb
end

_index_of(cells, id) = findfirst(c -> c.id == id, cells)

function add_cell!(nb::LiveNotebook, after_id::AbstractString, kind::AbstractString; before::Bool = false)
    _snapshot!(nb)
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    cell = Cell(_gen_id(nb.report), kind == "md" ? MARKDOWN : CODE, "")
    pos = before ? max(1, i) : i + 1                 # insert above (at `i`) or below the reference
    insert!(cells, pos, cell)
    _commit_structure!(nb, pos)
    return cell.id
end

# Split a cell into two at the editor cursor (frontend sends the before/after text).
function split_cell!(nb::LiveNotebook, id::AbstractString, before::AbstractString, after::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb)
    cells = nb.report.cells
    cells[i].source = String(before)
    insert!(cells, i + 1, Cell(_gen_id(nb.report), cells[i].kind, String(after)))
    _commit_structure!(nb, i)
    return nb
end

# Merge a cell with the one below it (frontend sends the already-combined source).
function merge_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString)
    i = _index_of(nb.report.cells, id)
    (i === nothing || i >= length(nb.report.cells)) && return nb
    _snapshot!(nb)
    cells = nb.report.cells
    cells[i].source = String(source)
    deleteat!(cells, i + 1)
    _commit_structure!(nb, i)
    return nb
end

# Rename a cell's id (its "label"). Ids must be unique and `#%%`-header-safe
# (letters/digits/underscore). Dependencies are by id, so rebuild them after.
function rename_cell!(nb::LiveNotebook, oldid::AbstractString, newid::AbstractString)
    nid = replace(strip(String(newid)), r"[^A-Za-z0-9_]+" => "_")   # fold spaces/punctuation to _
    isempty(nid) && return (false, "id cannot be empty")
    i = _index_of(nb.report.cells, oldid)
    i === nothing && return (false, "no such cell")
    nid == oldid && return (true, "")
    any(c -> c.id == nid, nb.report.cells) && return (false, "id $(nid) is already in use")
    _snapshot!(nb)
    nb.report.cells[i].id = String(nid)
    build_dependencies!(nb.report)
    _persist!(nb)
    return (true, "")
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

# Set the `controls=` layout of one or more cells (drag-to-host: add / move /
# reorder / remove / re-column). Presentation only — no re-eval; just rewrite the
# `.jl`. The caller sends each affected cell's *full desired* layout as columns of
# names (`[[a,b],[c]]`); empty columns are dropped.
function set_controls_map!(nb::LiveNotebook, map)
    isempty(map) && return nb
    _snapshot!(nb)
    for (id, cols) in map
        i = _index_of(nb.report.cells, id); i === nothing && continue
        cleaned = Vector{String}[String[String(n) for n in col] for col in cols]
        nb.report.cells[i].controls = filter(!isempty, cleaned)
    end
    _persist!(nb)
    return nb
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

# ── Live push over SSE (per notebook) ────────────────────────────────────────
function _broadcast(nb::LiveNotebook, msg::AbstractString)
    lock(nb.llock) do
        for ch in nb.listeners
            try
                isopen(ch) && Base.n_avail(ch) < 32 && put!(ch, String(msg))
            catch
            end
        end
    end
end

# Close this notebook's live SSE channels so each `_sse` loop's `take!` throws and
# returns, ending its long-lived connection. Without this, `close(server)` blocks
# waiting for those streams to drain (a browser tab left open hangs the close).
function _close_listeners(nb::LiveNotebook)
    lock(nb.llock) do
        for ch in nb.listeners
            try; close(ch); catch; end
        end
        empty!(nb.listeners)
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
    lock(nb.llock) do; push!(nb.listeners, ch); end
    try
        write(stream, "data: $(nb.version)\n\n")
        while true
            msg = take!(ch)
            write(stream, msg == "hb" ? ": hb\n\n" : "data: $msg\n\n")
        end
    catch
    finally
        lock(nb.llock) do; filter!(c -> c !== ch, nb.listeners); end
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
            sync_from_file!(nb) && _broadcast(nb, string(nb.version))
        catch
            sleep(0.5)
        end
    end
    @async while true
        sleep(15)
        _broadcast(nb, "hb")
    end
    # Periodic safety net: a low-frequency snapshot of the current state, deduped by
    # hash so it's free when nothing changed. Catches any state that slipped past the
    # op-level checkpoints (and guarantees the "at least every minute" capture).
    @async while true
        sleep(60)
        try; _history!(nb; source = "auto", kind = "draft"); catch; end
    end
end

# ── Agent sessions (consumer of Kaimon's agent service) ──────────────────────
#
# Kaimon owns the AI agent: it spawns/owns a headless `claude`, normalizes its
# output to a vendor-neutral `{kind,turn,data}` event model, and streams those on
# the gate event bus channel `agent:<id>` (see Kaimon AGENT_SESSION_SERVICE_*.md).
# We are a *consumer*: drive it with the `agent_*` MCP tools (via the gate service
# endpoint) and relay its stream onto the matching notebook's SSE as `agent:<json>`.
#
# Calling the core agent tools needs `Kaimon.KaimonGate.call_tool` — present only
# inside the extension subprocess. Standalone (`serve_notebook`) has no Kaimon, so
# chat degrades to a friendly "unavailable".

# agent_id → notebook, so a gate-bus `agent:<id>` event finds its SSE clients.
const _AGENT_ROUTES = Dict{String,LiveNotebook}()
const _AGENT_LOCK = ReentrantLock()
# agent_id → buffered relayed envelopes, so a browser reload can replay the
# conversation (agentMsgs is in-memory JS, lost on reload). Capped ring.
const _AGENT_LOG = Dict{String,Vector{String}}()
const _AGENT_LOG_CAP = 4000

_agent_available() = isdefined(Main, :Kaimon) &&
    isdefined(getfield(Main, :Kaimon), :KaimonGate) &&
    isdefined(getfield(Main, :Kaimon).KaimonGate, :call_tool)

# Call a core Kaimon `agent_*` tool over the gate service endpoint. The handlers
# return a JSON string on success (e.g. `{"agent_id":…}`/`{"turn":…}`) or a plain
# `"Error …"` string on failure — parse the former, raise the latter.
function _agent_call(tool::Symbol, args::Dict{String,Any})
    raw = getfield(Main, :Kaimon).KaimonGate.call_tool(tool, args)
    s = raw isa AbstractString ? String(raw) : string(raw)
    parsed = try; JSON.parse(s); catch; nothing; end
    (parsed isa AbstractDict) || error(s)   # non-JSON ⇒ the handler's error text
    return parsed
end

# The notebook-priming system prompt for a session, set once at `agent_open` (the
# `system_prompt` arg → `claude --append-system-prompt`, so it's ADDED to the agent's
# default Claude Code prompt, not a replacement). A fresh `claude` otherwise doesn't
# know it's wired to a notebook — tell it which file is the
# notebook, the cell-delimited format, and that file edits stream live to the
# browser. Editing the file is the cell-driving path (no MCP needed); `acceptEdits`
# auto-accepts those edits, so this runs unattended.
function _agent_system_prompt(nb::LiveNotebook)
    return """
    You are wired into a live **KaimonSlate** reactive notebook. THE NOTEBOOK IS THE FILE:
        $(abspath(nb.path))
    It is a plain Julia file whose cells are delimited by header lines:
        #%% code id=<id>      — a Julia code cell
        #%% md id=<id>        — a markdown cell
    Each cell's body follows its header until the next header. `id`s are short and unique.
    Cells are REACTIVE: a code cell that reads a variable re-runs when an upstream cell
    rewrites it. Markdown can embed live values with `{{ expr }}`.

    To build or change the notebook, EDIT THAT FILE directly with your file tools — your
    edits appear in the user's browser instantly. Make only the edits the user asks for,
    keep the cell format exactly, and don't touch other files. Be concise in chat.

    You are a focused notebook assistant, NOT a developer-onboarding agent. Ignore any
    global or project instructions about Kaimon usage quizzes, tool onboarding, taking a
    "usage_quiz" before starting, or Revise/Infiltrator workflows — they do not apply to
    you. Never run a quiz or setup step; just help with the notebook straight away.
    """
end

# Ensure an agent is bound to this notebook, spawning one (keyed `slate-<id>`,
# cwd = the notebook's directory) on first use and registering its event route.
# The agent inherits the host's MCP config (Kaimon included), so it can also call
# `slate.*`/`ex` — no explicit `mcp_config` needed (passing one with --strict would
# instead cut it off from the live Kaimon). Cell editing goes through the file.
function _ensure_agent!(nb::LiveNotebook)
    isempty(nb.agent_id) || return nb.agent_id
    aid = "slate-$(nb.id)"
    res = try
        _agent_call(:agent_open, Dict{String,Any}(
            "cwd" => dirname(abspath(nb.path)),
            "id"  => aid,
            # Kaimon M4 permission preset. "lab" allows the agent the Kaimon MCP tools
            # (slate.*/ex/qdrant) + file edits — enough to drive + introspect the
            # notebook, without arbitrary shell/web. Runs unattended (no prompt to stall
            # a headless agent); the agent_* recursion guard is always applied.
            "permission" => "lab",
            "system_prompt" => _agent_system_prompt(nb)))
    catch e
        # Agent already running (e.g. it outlived an extension restart — agents are
        # Kaimon-owned) → re-adopt it rather than failing the chat.
        occursin("in use", lowercase(sprint(showerror, e))) || rethrow()
        Dict("agent_id" => aid)
    end
    aid = String(get(res, "agent_id", aid))
    isempty(aid) && error("agent_open returned no id")
    nb.agent_id = aid
    lock(_AGENT_LOCK) do; _AGENT_ROUTES[aid] = nb; end
    return aid
end

# Close + deregister a notebook's agent (best effort), on notebook close.
function _close_agent!(nb::LiveNotebook)
    isempty(nb.agent_id) && return
    aid = nb.agent_id
    lock(_AGENT_LOCK) do; delete!(_AGENT_ROUTES, aid); delete!(_AGENT_LOG, aid); end
    nb.agent_id = ""
    _agent_available() && (try; _agent_call(:agent_close, Dict{String,Any}("agent_id" => aid)); catch; end)
    return nothing
end

"""
    relay_agent_event(channel, data)

Gate-bus callback for an `agent:<id>` event: forward the raw `{kind,turn,data}`
JSON onto the bound notebook's SSE, prefixed `agent:` so the SPA's live-event
handler routes it to the chat pane. `data` already rides the bus as a JSON string.
"""
function relay_agent_event(channel::AbstractString, data)
    startswith(channel, "agent:") || return
    aid = String(channel)[length("agent:")+1:end]
    nb = lock(_AGENT_LOCK) do; get(_AGENT_ROUTES, aid, nothing); end
    nb === nothing && return
    s = data isa AbstractString ? String(data) : String(JSON.json(data))
    # Mark the agent busy across a turn so the file-watcher attributes the edits it
    # makes to "agent" (not "external"). Clear shortly AFTER the turn ends, so the
    # watcher tick that picks up the agent's final save is still inside the window.
    kind = try; get(JSON.parse(s), "kind", ""); catch; ""; end
    if kind == "turn_started"
        nb.agent_busy = true
    elseif kind == "result"
        @async (sleep(3.0); nb.agent_busy = false)
    end
    # Buffer for reload-replay, then push live.
    lock(_AGENT_LOCK) do
        buf = get!(_AGENT_LOG, aid, String[])
        push!(buf, s)
        length(buf) > _AGENT_LOG_CAP && popfirst!(buf)
    end
    _broadcast(nb, "agent:" * s)
    return nothing
end

# ── Hub: one server, one port, many notebooks ────────────────────────────────
#
# Notebooks live in a registry keyed by a unique hub `id`. Routes are
# notebook-scoped (`/n/<id>` SPA, `/api/<id>/…`, `/api/<id>/events` SSE); `/` is
# an index/switcher page. One HTTP 2.0 server replaces the old one-port-per-file.
mutable struct Hub
    notebooks::Dict{String,LiveNotebook}
    server::Any
    host::String
    port::Int
    lock::ReentrantLock
end

_hub_url(h::Hub) = "http://$(h.host):$(h.port)"
_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# A unique id from the filename (deduped against the registry).
function _unique_id(h::Hub, path::AbstractString)
    base = replace(splitext(basename(path))[1], r"[^A-Za-z0-9]" => "_")
    isempty(base) && (base = "nb")
    id = base; i = 1
    while haskey(h.notebooks, id); i += 1; id = "$(base)_$i"; end
    return id
end

_notebooks_json(h::Hub) = lock(h.lock) do
    [Dict("id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
          "cells" => length(nb.report.cells)) for nb in values(h.notebooks)]
end

# A short "worker :port" tag for the index, when a notebook runs on a gate worker.
_worker_label(nb::LiveNotebook) =
    nb.kernel isa GateKernel && nb.kernel.port != 0 ? " · worker&nbsp;:$(nb.kernel.port)" : ""

# The index / switcher page: a Pluto-style list of open notebooks/sessions, each
# with a shutdown button; an open box (with Tab-completion) sits on top.
function _index_html(h::Hub)
    rows = lock(h.lock) do
        isempty(h.notebooks) ?
            "<p class=\"empty\">No notebooks open — open one above.</p>" :
            join(("<div class=\"nb\"><a class=\"nbmain\" href=\"/n/$(nb.id)\">" *
                  "<span class=\"t\">$(_esc(nb.report.title))</span>" *
                  "<span class=\"p\">$(_esc(abspath(nb.path)))</span>" *
                  "<span class=\"c\">$(length(nb.report.cells)) cells$(_worker_label(nb))</span></a>" *
                  "<button class=\"kill\" data-id=\"$(nb.id)\" title=\"shut down this session\">⨯ shutdown</button></div>"
                  for nb in values(h.notebooks)))
    end
    return """<!DOCTYPE html><html><head><meta charset="UTF-8"/><title>Kaimon Slate</title>
    <style>body{background:#0d1120;color:#d4d8e8;font-family:system-ui,sans-serif;margin:0;padding:40px;}
    h1{color:#fff;font-size:1.3rem;} .empty{color:#6a7090;}
    .nb{display:flex;align-items:center;gap:12px;padding:12px 16px;margin:8px 0;background:#141828;
        border:1px solid #2a2e40;border-left:3px solid #569cd6;border-radius:8px;max-width:760px;}
    .nb:hover{border-color:#569cd6;}
    .nbmain{display:flex;flex-direction:column;gap:2px;flex:1;min-width:0;text-decoration:none;color:inherit;}
    .nb .t{color:#fff;font-weight:600;} .nb .p{color:#6a7090;font-family:monospace;font-size:.8rem;overflow:hidden;text-overflow:ellipsis;}
    .nb .c{color:#56d364;font-size:.75rem;}
    .sect{color:#8a90b0;font-size:.78rem;font-weight:600;margin:20px 0 6px;max-width:760px;text-transform:uppercase;letter-spacing:.05em;}
    .recent{max-width:760px;}
    .ritem{display:flex;align-items:center;gap:10px;padding:7px 12px;margin:5px 0;background:#10131f;border:1px solid #21253a;border-radius:7px;cursor:pointer;}
    .ritem:hover{border-color:#569cd6;}
    .ritem .rt{flex:1;min-width:0;display:flex;flex-direction:column;}
    .ritem .rb{color:#cdd3e6;font-size:.85rem;}
    .ritem .rp{color:#6a7090;font-family:monospace;font-size:.72rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    .ritem .rx{background:none;border:none;color:#6a7090;cursor:pointer;font-size:.95rem;padding:2px 6px;border-radius:5px;line-height:1;}
    .ritem .rx:hover{color:#e57575;background:rgba(229,117,117,.1);}
    .nb .kill{background:#141828;color:#e57575;border:1px solid #3a2030;border-radius:6px;padding:5px 10px;cursor:pointer;font-size:.78rem;white-space:nowrap;}
    .nb .kill:hover{border-color:#e57575;background:rgba(229,117,117,.1);}
    .open{display:flex;gap:8px;margin:8px 0 18px;max-width:760px;}
    .pathwrap{position:relative;flex:1;}
    .pathwrap input{width:100%;background:#141828;color:#d4d8e8;border:1px solid #2a2e40;border-radius:8px;padding:8px 12px;font-family:monospace;font-size:.85rem;}
    .pathwrap input:focus{outline:none;border-color:#569cd6;}
    .comp{position:absolute;top:calc(100% + 3px);left:0;right:0;z-index:5;list-style:none;margin:0;padding:4px;
      background:#141828;border:1px solid #2a2e40;border-radius:8px;max-height:300px;overflow:auto;display:none;box-shadow:0 8px 24px rgba(0,0,0,.4);}
    .comp li{padding:4px 10px;border-radius:5px;cursor:pointer;font-family:monospace;font-size:.82rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .comp li.on{background:#569cd6;color:#0d1120;} .comp li:hover{background:#1a1e2e;}
    .open button{background:#141828;color:#d4d8e8;border:1px solid #2a2e40;border-radius:8px;padding:8px 16px;cursor:pointer;}
    .open button:hover{border-color:#569cd6;color:#569cd6;}
    .modal-bg{position:fixed;inset:0;background:rgba(5,8,16,.66);display:none;align-items:center;justify-content:center;z-index:50;}
    .modal-bg.show{display:flex;}
    .modal{background:#141828;border:1px solid #2a2e40;border-radius:10px;padding:18px 20px;max-width:520px;width:90%;box-shadow:0 16px 48px rgba(0,0,0,.55);}
    .modal .msg{color:#d4d8e8;font-size:.92rem;line-height:1.5;margin-bottom:16px;white-space:pre-wrap;word-break:break-word;}
    .modal .row{display:flex;justify-content:flex-end;gap:10px;}
    .modal button{background:#1a1e2e;color:#d4d8e8;border:1px solid #2a2e40;border-radius:7px;padding:7px 16px;cursor:pointer;font-size:.85rem;}
    .modal button:hover{border-color:#569cd6;color:#569cd6;}
    .modal button.primary{background:#569cd6;color:#0d1120;border-color:#569cd6;font-weight:600;}
    .modal button.primary:hover{background:#6cb0e6;color:#0d1120;}
    .modal button.danger{color:#e57575;border-color:#3a2030;} .modal button.danger:hover{background:rgba(229,117,117,.12);border-color:#e57575;color:#e57575;}
    .loading{position:fixed;inset:0;background:rgba(5,8,16,.72);display:none;flex-direction:column;align-items:center;justify-content:center;gap:14px;z-index:60;}
    .loading.show{display:flex;}
    .spinner{width:38px;height:38px;border:3px solid #2a2e40;border-top-color:#569cd6;border-radius:50%;animation:spin .8s linear infinite;}
    @keyframes spin{to{transform:rotate(360deg);}}
    .loading .lmsg{color:#d4d8e8;font-size:.9rem;}</style></head>
    <body><h1>📓 Kaimon Slate — notebooks</h1>
    <div class="open">
      <div class="pathwrap">
        <input id="pathin" autocomplete="off" spellcheck="false"
               placeholder="~/path/to/notebook.jl — Tab to complete, Enter to open"/>
        <ul id="comp" class="comp"></ul>
      </div>
      <button id="openbtn">Open</button>
    </div>
    <div id="recent" class="recent"></div>
    <div class="modal-bg" id="modalbg"><div class="modal"><div class="msg" id="modalmsg"></div><div class="row" id="modalrow"></div></div></div>
    <div class="loading" id="loading"><div class="spinner"></div><div class="lmsg" id="lmsg"></div></div>
    <script>
    (function(){
      var inp=document.getElementById('pathin'), comp=document.getElementById('comp'), items=[], sel=-1;
      var modalBg=document.getElementById('modalbg'), modalMsg=document.getElementById('modalmsg'),
          modalRow=document.getElementById('modalrow'), loadEl=document.getElementById('loading'),
          loadMsg=document.getElementById('lmsg'), _resolve=null;
      var esc=function(s){return s.replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});};
      var isdir=function(p){return p.slice(-1)==='/';};
      // Dark-themed modal (returns a Promise) replacing native confirm/alert.
      function _close(v){if(_resolve){var r=_resolve;_resolve=null;modalBg.classList.remove('show');r(v);}}
      function modal(message,buttons){return new Promise(function(resolve){_resolve=resolve;
        modalMsg.textContent=message;modalRow.innerHTML='';
        buttons.forEach(function(b){var el=document.createElement('button');el.textContent=b.label;if(b.cls)el.className=b.cls;
          el.onclick=function(){_close(b.value);};modalRow.appendChild(el);});
        modalBg.classList.add('show');var pr=modalRow.querySelector('.primary')||modalRow.lastChild;if(pr)pr.focus();});}
      function confirmDark(msg,okLabel,okCls){return modal(msg,[{label:'Cancel',value:false},{label:okLabel||'OK',value:true,cls:okCls||'primary'}]);}
      function alertDark(msg){return modal(msg,[{label:'OK',value:true,cls:'primary'}]);}
      modalBg.addEventListener('mousedown',function(e){if(e.target===modalBg)_close(false);});
      document.addEventListener('keydown',function(e){if(modalBg.classList.contains('show')&&e.key==='Escape')_close(false);});
      function showLoading(m){loadMsg.textContent=m||'Working…';loadEl.classList.add('show');}
      function hideLoading(){loadEl.classList.remove('show');}
      function openPath(p){p=(p||'').trim();if(!p)return;
        try{localStorage.setItem('slateLastDir', p.replace(/[^/]*\$/,''));}catch(e){}   // remember the directory
        showLoading('Opening “'+p+'” — starting the worker…');
        fetch('/api/open',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p})})
          .then(function(r){return r.ok?r.json():r.text().then(function(t){return Promise.reject(t);});})
          .then(function(d){pushRecent(d.path||p);location.href=d.url;}).catch(function(e){hideLoading();alertDark('Open failed: '+e);});}
      function render(){comp.innerHTML=items.map(function(c,i){return '<li class="'+(i===sel?'on':'')+'" data-i="'+i+'">'+esc(c)+'</li>';}).join('');
        comp.style.display=items.length?'block':'none';}
      function fetchComp(){return fetch('/api/path-complete?q='+encodeURIComponent(inp.value))
        .then(function(r){return r.json();}).then(function(d){items=d.completions||[];sel=-1;render();});}
      function commonPrefix(a){if(!a.length)return '';var p=a[0];for(var k=0;k<a.length;k++){var s=a[k],i=0;
        while(i<p.length&&i<s.length&&p[i]===s[i])i++;p=p.slice(0,i);}return p;}
      // Enter / Open: act on the active suggestion (highlighted, else the first),
      // else on the typed text. Directories are descended (never opened); a new
      // path is confirmed and offered a .jl extension before creating.
      async function submit(){
        var idx = sel>=0?sel:(items.length?0:-1);
        if(idx>=0){var pick=items[idx];inp.value=pick;
          if(isdir(pick)){fetchComp();return;}     // commit dir + show subpaths, don't open
          openPath(pick);return;}                  // file suggestion → open
        var p=inp.value.trim(); if(!p)return;
        var info=await fetch('/api/path-info?q='+encodeURIComponent(p)).then(function(r){return r.json();});
        if(info.isdir){if(p.slice(-1)!=='/')inp.value=p+'/';fetchComp();return;}        // never open a directory
        if(info.isfile){openPath(p);return;}
        if(!await confirmDark('Create new notebook “'+p+'”?','Create'))return;          // confirm new file
        if(p.slice(-3).toLowerCase()!=='.jl'){ if(await confirmDark('“'+p+'” has no .jl extension. Add it?','Add .jl'))p=p+'.jl'; }
        openPath(p);
      }
      var t;inp.addEventListener('input',function(){clearTimeout(t);t=setTimeout(fetchComp,110);});
      inp.addEventListener('keydown',function(e){
        if(e.key==='Tab'){e.preventDefault();
          if(items.length===1){inp.value=items[0];fetchComp();}
          else if(items.length>1){var cp=commonPrefix(items);
            if(cp.length>inp.value.length){inp.value=cp;fetchComp();}
            else{sel=(sel+1)%items.length;inp.value=items[sel];render();}}}
        else if(e.key==='/'){var idx=sel>=0?sel:(items.length?0:-1);   // commit a dir + descend
          if(idx>=0&&isdir(items[idx])){e.preventDefault();inp.value=items[idx];fetchComp();}}
        else if(e.key==='ArrowDown'){e.preventDefault();if(items.length){sel=(sel+1)%items.length;inp.value=items[sel];render();}}
        else if(e.key==='ArrowUp'){e.preventDefault();if(items.length){sel=(sel-1+items.length)%items.length;inp.value=items[sel];render();}}
        else if(e.key==='Enter'){e.preventDefault();submit();}
        else if(e.key==='Escape'){items=[];render();}});
      comp.addEventListener('mousedown',function(e){var li=e.target.closest('li');if(!li)return;e.preventDefault();
        var pick=items[+li.dataset.i];inp.value=pick;inp.focus();
        isdir(pick)?fetchComp():openPath(pick);});   // click dir = descend, click file = open
      document.getElementById('openbtn').onclick=function(){submit();};
      // Per-session shutdown buttons (event-delegated over the rows).
      document.addEventListener('click',async function(e){var b=e.target.closest('.kill');if(!b)return;
        var id=b.dataset.id;
        if(!await confirmDark('Shut down session “'+id+'”? Its worker stops and the notebook closes.','Shutdown','danger'))return;
        showLoading('Shutting down “'+id+'”…');
        fetch('/api/'+encodeURIComponent(id)+'/shutdown',{method:'POST'}).then(function(){location.reload();});});
      // Recently opened notebooks (per-browser, localStorage). Click to re-open;
      // ones already open are hidden (they're listed below). ✕ forgets an entry.
      var RECENT_KEY='slateRecents';
      function getRecents(){try{return JSON.parse(localStorage.getItem(RECENT_KEY)||'[]');}catch(e){return [];}}
      function saveRecents(a){try{localStorage.setItem(RECENT_KEY,JSON.stringify(a.slice(0,12)));}catch(e){}}
      function pushRecent(p){if(!p)return;var a=getRecents().filter(function(x){return x!==p;});a.unshift(p);saveRecents(a);}
      function forgetRecent(p){saveRecents(getRecents().filter(function(x){return x!==p;}));renderRecents();}
      function openPaths(){var s={};document.querySelectorAll('.nb .p').forEach(function(e){s[e.textContent]=1;});return s;}
      function baseName(p){var q=p.replace(/\\/+\$/,'');var i=q.lastIndexOf('/');return i<0?q:q.slice(i+1);}
      function renderRecents(){
        var box=document.getElementById('recent'),open=openPaths();
        var list=getRecents().filter(function(p){return !open[p];});
        box.innerHTML=list.length? '<h2 class="sect">Recent</h2>'+list.map(function(p){
          return '<div class="ritem" data-p="'+esc(p)+'"><div class="rt"><span class="rb">'+esc(baseName(p))+
            '</span><span class="rp">'+esc(p)+'</span></div><button class="rx" data-p="'+esc(p)+'" title="remove from recents">✕</button></div>';
        }).join('') : '';
      }
      document.getElementById('recent').addEventListener('click',function(e){
        var x=e.target.closest('.rx'); if(x){e.stopPropagation();forgetRecent(x.dataset.p);return;}
        var it=e.target.closest('.ritem'); if(it)openPath(it.dataset.p);});
      renderRecents();
      // Prefill the last directory we opened from and show its files for one-click reopen.
      try{var last=localStorage.getItem('slateLastDir'); if(last){inp.value=last; fetchComp();}}catch(e){}
      inp.focus();
    })();
    </script>
    $rows</body></html>"""
end

_html(body) = HTTP.Response(200, ["Content-Type" => "text/html", "Cache-Control" => "no-store"], body)

# Run `f(nb)` for the notebook named by the request's `id` path param, else 404.
function _withnb(h::Hub, req, f)
    id = HTTP.getparam(req, "id")
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    nb === nothing && return HTTP.Response(404, "no such notebook: $id")
    return f(nb)
end

# Filesystem path completions for the open box. Expands a leading `~`, lists the
# directory implied by the typed prefix, and returns full suggestions that PRESERVE
# the user's `~` (directories suffixed `/`). Dirs and `.jl` files surface first;
# dotfiles are hidden unless the prefix itself starts with a dot.
function _path_completions(q::AbstractString; limit::Int = 40)
    s = String(q)
    isempty(s) && (s = "~/")
    s == "~" && return ["~/"]
    slash = findlast('/', s)
    prefix = slash === nothing ? "" : s[1:slash]
    leaf   = slash === nothing ? s : s[nextind(s, slash):end]
    base   = isempty(prefix) ? pwd() : expanduser(prefix)
    isdir(base) || return String[]
    entries = try
        readdir(base)
    catch
        return String[]
    end
    keep = String[]
    for e in entries
        startswith(e, leaf) || continue
        (startswith(e, ".") && !startswith(leaf, ".")) && continue
        full = joinpath(base, e)
        push!(keep, isdir(full) ? prefix * e * "/" : prefix * e)
    end
    sort!(keep; by = p -> (endswith(p, "/") ? 0 : (endswith(p, ".jl") ? 1 : 2), lowercase(p)))
    return first(keep, limit)
end

# ── Cell-local completion ─────────────────────────────────────────────────────
# `REPLCompletions` only sees the live module, so identifiers a cell BINDS before
# it has run (assignments, `for`/`let`/`function`/generator vars, params) don't
# complete. We parse the cell's complete leading statements and union their bound
# names in — an over-approximation (ignores nested-scope visibility), which is fine
# for completion. Only for bare identifiers; field access (after `.`) is left to
# REPLCompletions.
_isidcu(b::UInt8) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
                    (UInt8('0') <= b <= UInt8('9')) || b == UInt8('_') || b == UInt8('!')

# (token-start-0based, typed-prefix, is-field-access) for the identifier at `pos`.
function _id_prefix(code::String, pos::Int)
    cu = codeunits(code)
    i = pos
    while i > 0 && _isidcu(cu[i]); i -= 1; end
    dotted = i >= 1 && cu[i] == UInt8('.')
    return (i, String(cu[(i + 1):pos]), dotted)
end

# Text to insert for a completion. `completion_text` throws on `BslashCompletion`
# (Julia ≥1.12 — that's the LaTeX/emoji `\pi`→π path), so fall back to the struct's
# symbol field. Robust across Julia versions: normal path first, field access on throw.
function _comp_text(c)
    try
        return REPL.REPLCompletions.completion_text(c)::AbstractString
    catch
        for f in (:completion, :name)               # BslashCompletion holds the symbol here
            hasproperty(c, f) && return String(getfield(c, f))
        end
        return ""
    end
end

# Names introduced at a binding site (LHS of `=`, params, `f(a,b)` def, `x::T`, …).
function _bind_names!(out::Set{Symbol}, x)
    if x isa Symbol
        x === :_ || push!(out, x)
    elseif x isa Expr
        h = x.head
        if h === :(::) || h === :(<:) || h === :kw || h === :(=) || h === :(...) || h === :curly
            isempty(x.args) || _bind_names!(out, x.args[1])
        elseif h === :tuple || h === :parameters || h === :call   # destructuring / def LHS+params
            for a in x.args
                _bind_names!(out, a)
            end
        end
    end
end

function _collect_binds!(out::Set{Symbol}, ex)
    ex isa Expr || return
    h = ex.head
    if h === :(=)
        _bind_names!(out, ex.args[1]); _collect_binds!(out, ex.args[2])
    elseif h === :function || h === :(->)
        _bind_names!(out, ex.args[1])
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :for
        spec = ex.args[1]
        for b in (spec isa Expr && spec.head === :block ? spec.args : (spec,))
            b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1])
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :generator || h === :comprehension || h === :flatten
        for a in ex.args
            (a isa Expr && a.head === :(=)) ? _bind_names!(out, a.args[1]) : _collect_binds!(out, a)
        end
    elseif h === :let
        binds = ex.args[1]
        for b in (binds isa Expr && binds.head === :block ? binds.args : (binds,))
            b isa Symbol ? push!(out, b) : (b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1]))
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :local || h === :global
        for a in ex.args; _bind_names!(out, a); end
    else
        for a in ex.args; _collect_binds!(out, a); end
    end
end

# All names bound by the cell's complete leading statements (stops at the first
# incomplete/erroring statement — typically the line being typed).
function _cell_locals(code::AbstractString)
    out = Set{Symbol}()
    s = String(code); n = ncodeunits(s); idx = 1
    while idx <= n
        ex, nxt = try
            Meta.parse(s, idx; raise = false)
        catch
            break
        end
        ex === nothing && break
        (ex isa Expr && (ex.head === :incomplete || ex.head === :error)) && break
        _collect_binds!(out, ex)
        nxt <= idx && break
        idx = nxt
    end
    return out
end

# Restart a notebook's kernel: kill its worker (a gate worker is a real subprocess;
# no-op in-process), then re-evaluate from a fresh namespace. The gate kernel
# respawns a worker on the next `prepare!`.
function restart_kernel!(nb::LiveNotebook)
    lock(nb.lock) do
        try; ReportEngine.shutdown!(nb.kernel); catch; end
        ReportEngine.reset!(nb.kernel, nb.report)
        build_dependencies!(nb.report)
        eval_stale!(nb.report, nb.kernel)
    end
    _broadcast(nb, "restart")
    return nb
end

function _make_router(h::Hub)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", _ -> _html(_index_html(h)))
    HTTP.register!(router, "GET", "/api/notebooks", _ -> _json(_notebooks_json(h)))
    # Open/close a notebook by path over HTTP — lets the index page (and any
    # caller) bring up a notebook without the `slate.*` MCP tools. Mirrors
    # `KaimonSlate.create_tools`'s open: creates the file if it doesn't exist.
    HTTP.register!(router, "POST", "/api/open", req -> begin
        path = expanduser(strip(String(get(_body(req), "path", ""))))   # resolve ~ (tab-complete emits ~ paths)
        isempty(path) && return HTTP.Response(400, "missing path")
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        id = open_notebook!(h, path)
        _json(Dict("id" => id, "url" => "/n/$id", "path" => abspath(path)))
    end)
    HTTP.register!(router, "POST", "/api/close", req -> begin
        file = abspath(expanduser(strip(String(get(_body(req), "path", "")))))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing ? HTTP.Response(404, "not open") : (close_notebook!(h, id); _json(Dict("closed" => file)))
    end)
    HTTP.register!(router, "GET", "/api/path-complete", req -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        _json(Dict("completions" => _path_completions(q)))
    end)
    # Stat a path (with ~ expansion) so the open box can decide: open file / show
    # subpaths for a directory / confirm-create for a new path.
    HTTP.register!(router, "GET", "/api/path-info", req -> begin
        p = expanduser(strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))))
        _json(Dict("path" => p, "exists" => ispath(p), "isdir" => isdir(p), "isfile" => isfile(p)))
    end)
    # Close a notebook by id (the index's per-session shutdown button).
    HTTP.register!(router, "POST", "/api/{id}/shutdown", req -> begin
        id = HTTP.getparam(req, "id")
        close_notebook!(h, id) ? _json(Dict("closed" => id)) : HTTP.Response(404, "no such notebook")
    end)
    HTTP.register!(router, "GET", "/n/{id}", req -> begin
        id = HTTP.getparam(req, "id")
        present = lock(h.lock) do; haskey(h.notebooks, id); end
        present ? _html(read(_ASSET, String)) : HTTP.Response(302, ["Location" => "/"])   # not open → home
    end)
    HTTP.register!(router, "GET", "/api/{id}/state", req -> _withnb(h, req, nb -> (sync_from_file!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cell/{cid}", req -> _withnb(h, req, nb -> begin
        edit_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/complete", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        pos = clamp(Int(get(body, "pos", ncodeunits(code))), 0, ncodeunits(code))
        mod = nb.report.mod === nothing ? Main : nb.report.mod
        pstart, prefix, dotted = _id_prefix(code, pos)
        texts, from, to = try
            comps, range, _ = REPL.REPLCompletions.completions(code, pos, mod)
            (filter(!isempty, String[_comp_text(c) for c in comps]), first(range) - 1, last(range))
        catch
            (String[], pstart, pos)
        end
        if !dotted                          # union in cell-local bindings (skip field access)
            have = Set(texts)
            locals = try; _cell_locals(code); catch; Set{Symbol}(); end
            extra = sort!(String[n for n in (String(s) for s in locals) if startswith(n, prefix) && !(n in have)])
            isempty(extra) || (texts = vcat(extra, texts))
        end
        _json(Dict("completions" => texts, "from" => from, "to" => to))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-add", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        add_cell!(nb, get(b, "after", ""), get(b, "kind", "code"); before = get(b, "before", false) === true)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-rename/{cid}", req -> _withnb(h, req, nb -> begin
        ok, msg = rename_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "newid", ""))
        ok ? _json(state_json(nb)) : HTTP.Response(400, msg)
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-split/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); split_cell!(nb, HTTP.getparam(req, "cid"), get(b, "before", ""), get(b, "after", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-merge/{cid}", req -> _withnb(h, req, nb -> begin
        merge_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-delete/{cid}", req -> _withnb(h, req, nb ->
        (delete_cell!(nb, HTTP.getparam(req, "cid")); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cell-move/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); cid = HTTP.getparam(req, "cid")
        haskey(b, "target") ? move_cell_rel!(nb, cid, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, cid, get(b, "dir", "up"))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-type/{cid}", req -> _withnb(h, req, nb -> begin
        set_kind!(nb, HTTP.getparam(req, "cid"), get(_body(req), "kind", "code")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/controls", req -> _withnb(h, req, nb -> begin
        set_controls_map!(nb, get(_body(req), "map", Dict{String,Any}())); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/bind/{cid}", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        set_bind!(nb, HTTP.getparam(req, "cid"), get(body, "name", ""), get(body, "value", nothing))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/table-page", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        res = lock(nb.lock) do                       # serialize vs eval (shared gate connection)
            ReportEngine.table_page(nb.kernel, nb.report, String(get(b, "table_id", "")), b)
        end
        _json(Dict("rows" => res.rows, "total" => res.total))
    end))
    HTTP.register!(router, "POST", "/api/{id}/undo", req -> _withnb(h, req, nb -> (undo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/redo", req -> _withnb(h, req, nb -> (redo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/run", req -> _withnb(h, req, nb -> (eval_stale!(nb.report, nb.kernel); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/restart", req -> _withnb(h, req, nb -> (restart_kernel!(nb); _json(state_json(nb)))))
    # Agent chat: forward the turn to Kaimon's agent service (spawning a session
    # bound to this notebook on first use); the agent's `{kind,turn,data}` events
    # arrive async on the gate bus and are relayed to this notebook's SSE by
    # `relay_agent_event` (wired via KaimonSlate.on_event). See AGENT_SESSION_*.md.
    HTTP.register!(router, "POST", "/api/{id}/chat", req -> _withnb(h, req, nb -> begin
        text = String(get(_body(req), "text", ""))
        isempty(strip(text)) && return _json(Dict("ok" => false, "error" => "empty message"))
        _agent_available() ||
            return _json(Dict("ok" => false, "error" => "agent service unavailable (run inside Kaimon, with a logged-in `claude` CLI)"))
        try
            aid = _ensure_agent!(nb)
            res = _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => text))
            _json(Dict("ok" => true, "agent_id" => aid, "turn" => get(res, "turn", nothing)))
        catch e
            _json(Dict("ok" => false, "error" => sprint(showerror, e)))
        end
    end))
    # Replay the agent conversation after a page reload (buffered as relayed).
    HTTP.register!(router, "GET", "/api/{id}/agent-log", req -> _withnb(h, req, nb -> begin
        log = isempty(nb.agent_id) ? String[] :
              lock(_AGENT_LOCK) do; copy(get(_AGENT_LOG, nb.agent_id, String[])); end
        _json(Dict("events" => log, "agent_id" => nb.agent_id))
    end))
    # Interrupt the agent's in-flight turn (best effort).
    HTTP.register!(router, "POST", "/api/{id}/chat-interrupt", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agent_id)) || return _json(Dict("ok" => false))
        r = try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => nb.agent_id)); catch; Dict("interrupted" => false); end
        _json(Dict("ok" => true, "interrupted" => get(r, "interrupted", false)))
    end))
    HTTP.register!(router, "POST", "/api/{id}/reset", req -> _withnb(h, req, nb -> begin
        ReportEngine.reset!(nb.kernel, nb.report); build_dependencies!(nb.report); eval_stale!(nb.report, nb.kernel); _json(state_json(nb))
    end))
    # ── Time machine: durable edit history ───────────────────────────────────
    # List checkpoints (newest data is appended last); `current` marks the live state.
    HTTP.register!(router, "GET", "/api/{id}/history", req -> _withnb(h, req, nb ->
        _json(Dict("entries" => SlateHistory.entries(nb.path),
                   "current" => SlateHistory.latest_hash(nb.path)))))
    # Full serialized source of one recorded state (for preview / diff / replay).
    HTTP.register!(router, "GET", "/api/{id}/history/{hash}", req -> _withnb(h, req, nb -> begin
        hash = HTTP.getparam(req, "hash")
        src = SlateHistory.content(nb.path, hash)
        src === nothing ? HTTP.Response(404, "no such snapshot") :
            _json(Dict("hash" => hash, "source" => src))
    end))
    # Restore a recorded state (non-destructive: recorded as a new checkpoint).
    HTTP.register!(router, "POST", "/api/{id}/history/restore", req -> _withnb(h, req, nb -> begin
        hash = String(get(_body(req), "hash", ""))
        restore_history!(nb, hash) ? _json(state_json(nb)) : HTTP.Response(404, "no such snapshot")
    end))
    return router
end

const _EVENTS_RE = r"^/api/([^/]+)/events$"

"""
    start_hub(; host="127.0.0.1", port=8765) -> Hub

Start the single notebook server with an empty registry. Add notebooks with
[`open_notebook!`](@ref). Non-blocking.
"""
function start_hub(; host = "127.0.0.1", port = 8765)
    h = Hub(Dict{String,LiveNotebook}(), nothing, host, port, ReentrantLock())
    handle = HTTP.streamhandler(_make_router(h))
    server = HTTP.listen!(host, port) do stream::HTTP.Stream
        m = match(_EVENTS_RE, stream.message.target)
        if m !== nothing
            nb = lock(h.lock) do; get(h.notebooks, m.captures[1], nothing); end
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        else
            handle(stream)
        end
    end
    h.server = server
    @info "Kaimon Slate hub" url = _hub_url(h)
    return h
end

"""
    open_notebook!(hub, path) -> id

Load the notebook at `path` into the hub (reusing the existing entry if already
open) and start its file watcher. Returns the hub id (its `/n/<id>` route).
"""
function open_notebook!(h::Hub, path::AbstractString)
    file = abspath(path)
    lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
end

"Remove a notebook from the hub: drain its SSE connections and drop it."
function close_notebook!(h::Hub, id::AbstractString)
    lock(h.lock) do
        nb = get(h.notebooks, id, nothing)
        nb === nothing && return false
        _close_listeners(nb)
        _close_agent!(nb)
        unregister_refresh!(nb.report.id)
        try; shutdown!(nb.kernel); catch; end
        delete!(h.notebooks, id)
        return true
    end
end

"Stop the hub: drain every notebook's SSE connections, then close the server."
function stop_hub(h::Hub)
    lock(h.lock) do
        for nb in values(h.notebooks)
            _close_listeners(nb); unregister_refresh!(nb.report.id)
            try; shutdown!(nb.kernel); catch; end
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

# ── Standalone convenience (one notebook) ─────────────────────────────────────

"""
    start_server(path; host="127.0.0.1", port=8765) -> Hub

Start a hub and open the single notebook at `path`. Non-blocking; returns the
`Hub` (stop it with [`stop_hub`](@ref)). The notebook is served at `/n/<id>`
(printed); `/` is the index. For a blocking launcher use [`serve_notebook`](@ref).
"""
function start_server(path::AbstractString; host = "127.0.0.1", port = 8765)
    h = start_hub(; host = host, port = port)
    id = open_notebook!(h, path)
    @info "Notebook" url = "$(_hub_url(h))/n/$id" file = abspath(path)
    return h
end

"Stop a hub started by [`start_server`](@ref) (drains SSE, frees the port)."
stop_server(h::Hub) = stop_hub(h)

"""
    serve_notebook(path; host="127.0.0.1", port=8765)

Open the notebook at `path` in a hub and serve it. **Blocks** until stopped.
"""
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765)
    h = start_server(path; host = host, port = port)
    wait(h.server)
    return h
end

end # module NotebookServer
