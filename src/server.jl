"""
    NotebookServer

The live, interactive notebook backend (interactivity layer 1). Holds a notebook
bound to a `.jl` file and serves a browser SPA plus a small JSON API. Editing a
cell reconciles → reactively recomputes only stale cells → persists back to the
`.jl` (so the agent and the browser share one source). Runs CLI-side, wrapping
the engine (`ReportEngine`) and per-cell renderer (`ReportRender`).
"""
module NotebookServer

using HTTP, JSON, FileWatching, CodecZlib
import Base64
import Typst_jll
import Pkg
using ..ReportEngine
using ..ReportRender

include("history.jl")   # module SlateHistory — durable content-addressed time machine

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub
export find_live, notebook_digest, agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!
export cell_image, set_snapshot!

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")
const _INDEX_ASSET = joinpath(@__DIR__, "assets", "index.html")
const _CSS_ASSET = joinpath(@__DIR__, "assets", "notebook.css")   # extracted from notebook.html
const _JS_DIR = joinpath(@__DIR__, "assets", "js")                # notebook UI, split into modules

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
    agent_id::String                     # default/solo agent (crew "") — back-compat alias of agents[""]
    agent_busy::Bool                     # true while ANY bound agent has a turn in flight (history attribution)
    agents::Dict{String,String}          # crew label → Kaimon agent id (multi-agent crew; "" = default)
end

# GateKernel when running as the Kaimon extension AND the notebook is inside a
# Julia project (cells eval in a per-notebook worker); else in-process.
# Instantiate an env in a subprocess (isolated; best-effort). Blocking — used by the background
# hydrate on a fresh bundle reconstruction (the content-addressed cache makes every later open
# instant), so it never sits on the open path.
function _instantiate_env!(envdir::AbstractString)
    jl = Base.julia_cmd()[1]
    try
        run(pipeline(`$jl --project=$envdir --startup-file=no -e 'using Pkg; Pkg.instantiate()'`;
                     stdout = devnull, stderr = devnull))
    catch
    end
    return envdir
end

# Self-contained `.jl`s are intercepted earlier in `load_notebook` (background hydrate against
# the depot cache), so this only handles ordinary notebooks: base / forked / detached.
function _select_kernel(path::AbstractString, report)
    if ReportEngine.gate_available()
        proj = Base.current_project(dirname(abspath(path)))
        parent = proj === nothing ? "" : dirname(proj)
        envdir = ReportEngine.notebook_env_dir(path)
        env_exists = isfile(joinpath(envdir, "Project.toml"))   # the fork is materialised on first add
        delta = get(report.meta, "env", Dict{String,Any}[])     # footer-recorded notebook packages
        if !env_exists && !isempty(delta)
            # The `.jl` records package adds but the env dir is gone (e.g. a fresh git clone):
            # reconstruct it from the footer on first use (pending). Only `mkdir` here — the
            # Project.toml is written by the reconstruction itself, so a worker that never ran
            # leaves the env "absent" and reconstruction retries on the next open.
            mkpath(envdir)
            return GateKernel(envdir; parent = parent, envdir = envdir, pending = delta)
        elseif parent == ""
            # Detached: the notebook env IS the whole world (everything is a "notebook add").
            ReportEngine.ensure_notebook_env!(envdir)
            return GateKernel(envdir; parent = "", envdir = envdir)
        elseif env_exists
            # Already has its own packages → run in the forked env (extends the parent).
            return GateKernel(envdir; parent = parent, envdir = envdir)
        else
            # Base mode: no notebook-specific packages yet → run directly in the parent.
            return GateKernel(parent; parent = parent, envdir = envdir)
        end
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
    _note_server_write!(rid, hash(serialize_report(r)))   # the as-opened state is OURS — a watcher
                                                          # tick reading it must not "revert" to it
    # Any self-contained `.jl`: open INSTANTLY and reconstruct + run the env in the BACKGROUND
    # (hydrate), so a heavy bundle never blocks the open. If it embeds a frozen render that's
    # shown meanwhile; otherwise the cells show un-run until they go live. This is the single
    # path for opening a standalone — "Run (temporary)" is just a normal open.
    if ReportEngine.gate_available() && _has_bundle(src)
        p = _read_preview(src)
        p === nothing || (r.meta["preview"] = p)
        r.meta["hydrating"] = true
        nb = LiveNotebook(nbid, String(path), r, InProcessKernel(), 0, String[], String[],
                          ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                          Dict{String,String}())
        register_refresh!(r.id, vars -> server_refresh(nb, vars))
        register_srcchange!(r.id, (names, err) -> server_src_changed(nb, names, err))
        _load_chat_log!(nb)
        @async _hydrate_standalone!(nb, String(path))   # reconstruct + run live, then push
        return nb
    end
    kernel = _select_kernel(path, r)
    eval_stale!(r, kernel)               # initial full run
    nb = LiveNotebook(nbid, String(path), r, kernel, 0, String[], String[],
                      ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                      Dict{String,String}())
    # Seed the durable history with the initial state, so the very first edit has a
    # parent to diff against and the "buildup" replay starts from the true origin.
    _history!(nb; source = "open")
    # Async cells call `slate_refresh(:x)` → recompute readers of x + push live.
    register_refresh!(r.id, vars -> server_refresh(nb, vars))
    register_srcchange!(r.id, (names, err) -> server_src_changed(nb, names, err))   # parent /src reloaded (Revise)
    _load_chat_log!(nb)                  # restore any prior agent transcript (survives server restart)
    _autoindex!(nb)                      # background: index project deps + used packages' docs
    return nb
end

# Background env reconstruction for a preview-standalone (see load_notebook): reconstruct the
# bundle into the depot cache, instantiate, swap in the real gate kernel, run the cells live,
# then push — the client swaps the frozen preview for live cells. On failure, surface it and
# drop the hydrating state (the preview stays visible as the last-known render).
function _hydrate_standalone!(nb::LiveNotebook, path::AbstractString)
    try
        rc = _reconstruct_bundle!(path)
        rc.fresh && _instantiate_env!(rc.dir)
        kernel = GateKernel(rc.dir; parent = "", envdir = rc.dir)
        lock(nb.lock) do
            nb.kernel = kernel
            delete!(nb.report.meta, "preview")       # live cells supersede the frozen render
            delete!(nb.report.meta, "hydrating")
            eval_stale!(nb.report, kernel)           # run everything in the reconstructed env
            nb.version += 1
        end
        _history!(nb; source = "open")
        _autoindex!(nb)
    catch e
        lock(nb.lock) do
            nb.report.meta["hydrate_error"] = sprint(showerror, e)
            delete!(nb.report.meta, "hydrating")
            nb.version += 1
        end
    end
    try; _broadcast(nb, string(nb.version)); catch; end
    return nothing
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

# Parent-project /src hot-reload (Revise). A worker `files_changed` event → apply the pending
# revisions in the worker, learn which top-level defs changed, and mark the cells that READ them
# (plus their dependents) stale, then notify the browser (`srcreload:<n>`). Mark-stale, NOT
# auto-run — the user re-runs (Run stale / ⇧⏎). Per-notebook toggle via meta["hotreload"]
# (default on); only meaningful with a gate worker (Revise lives in the worker).
function server_src_changed(nb::LiveNotebook, names::Vector{String}, err::AbstractString = "")
    get(nb.report.meta, "hotreload", true) == false && return
    if !isempty(err)                              # a /src save didn't parse/apply → just notify
        _broadcast(nb, "srcerror:" * replace(strip(err), r"\s*\n\s*" => " "))
        return
    end
    isempty(names) && return
    syms = Set{Symbol}(Symbol(n) for n in names)
    staled = Set{String}()
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            # Both code AND markdown join the reactive graph via `reads` (md from its {{ }}
            # free vars), and eval_stale! re-renders stale md — so include both.
            isdisjoint(c.reads, syms) && continue
            c.state = STALE; push!(seed, c.id); push!(staled, c.id)
        end
        isempty(seed) && return
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing || (nb.report.cells[i].state = STALE; push!(staled, id))
        end
    end
    isempty(staled) && return
    _broadcast(nb, "srcreload:$(length(staled))")
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


include("server_history.jl")
include("server_agentops.jl")
include("server_sse_import.jl")
include("server_agentsessions.jl")
include("server_docs.jl")
include("server_snapshots.jl")
include("server_export.jl")
include("server_hub.jl")
include("server_complete.jl")

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
