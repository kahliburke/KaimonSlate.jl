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
import REPL, Base64
import Typst_jll
using ..ReportEngine
using ..ReportRender

include("history.jl")   # module SlateHistory — durable content-addressed time machine

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub
export find_live, notebook_digest, agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!
export cell_image, set_snapshot!

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")
const _INDEX_ASSET = joinpath(@__DIR__, "assets", "index.html")

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

# Recent server-written content hashes per notebook (report id → ring). The async
# file-watcher must recognize our OWN writes — including *intermediate* ones from a
# rapid sequence of cell ops — and not revert newer in-memory state to a stale disk
# read. Matching only the latest state (as `sync_from_file!` did) races: the watcher
# can read write N while the report is already at N+1 and roll it back.
const _SERVER_WRITES = Dict{String,Vector{UInt64}}()
const _SWRITES_LOCK = ReentrantLock()
function _note_server_write!(report_id::AbstractString, h::UInt64)
    lock(_SWRITES_LOCK) do
        v = get!(_SERVER_WRITES, String(report_id), UInt64[])
        push!(v, h); length(v) > 64 && popfirst!(v)
    end
end
_is_server_write(report_id, h::UInt64) =
    lock(_SWRITES_LOCK) do; h in get(_SERVER_WRITES, String(report_id), UInt64[]); end

# Persist the notebook to its `.jl` AND record a durable checkpoint. The single
# write+capture chokepoint for in-app mutations (replaces bare `write(...)`).
function _persist!(nb::LiveNotebook; source::AbstractString = "browser")
    s = serialize_report(nb.report)
    write(nb.path, s)
    _note_server_write!(nb.report.id, hash(s))   # so the watcher won't revert it
    nb.version += 1                               # every in-app commit advances the version (CAS basis)
    _history!(nb; source = source)
    return nb
end

# The notebook's OWN packages (the delta beyond the parent project) as sorted
# `{name, version, uuid}` — the set difference active − parent − parent-package. Shared by
# the package viewer's "notebook" group and the `.jl` reproducibility footer.
function _notebook_adds(nb::LiveNotebook)
    info = try
        ReportEngine.env_info(nb.kernel, nb.report)
    catch
        return (adds = Dict{String,Any}[], parent = Dict{String,Any}[], parentpath = "", detached = true)
    end
    pdeps = info.parent === nothing ? Dict{String,Any}[] : info.parent.deps
    pnames = Set(string(get(d, "name", "")) for d in pdeps)
    info.parent === nothing || push!(pnames, info.parent.name)
    adds = sort([d for d in info.notebook.deps if !(string(get(d, "name", "")) in pnames)];
                by = d -> string(get(d, "name", "")))
    return (adds = adds, parent = pdeps,
            parentpath = info.parent === nothing ? "" : info.parent.path,
            detached = info.parent === nothing)
end

# Sync the `.jl` reproducibility footer (`report.meta["env"]`) to the notebook's current
# package delta and persist if it changed. Called after package operations.
function _refresh_env_meta!(nb::LiveNotebook)
    env = Dict{String,Any}[Dict{String,Any}("name" => string(get(d, "name", "")),
                                             "version" => string(get(d, "version", "")),
                                             "uuid" => string(get(d, "uuid", "")))
                           for d in _notebook_adds(nb).adds]
    cur = get(nb.report.meta, "env", Dict{String,Any}[])
    if isempty(env)
        haskey(nb.report.meta, "env") || return nb
        delete!(nb.report.meta, "env")
    else
        env == cur && return nb
        nb.report.meta["env"] = env
    end
    return _persist!(nb; source = "packages")
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
    # An echo of one of OUR recent writes (incl. an intermediate one from a rapid
    # cell-op sequence) — never roll the live report back to it.
    _is_server_write(nb.report.id, hash(norm)) && return false
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
    (:collapsed in c.flags) && (d["collapsed"] = true)   # folded in the UI (persisted in the .jl)
    (:hidecode in c.flags) && (d["codeHidden"] = true)   # code editor hidden, output shown
    # `@bind` variables this cell READS (so the header can one-click surface their controls) —
    # excluding any it defines itself.
    if c.kind == CODE && !isempty(c.reads)
        own = Set(String(b.name) for b in c.binds)
        uses = sort!(unique!(String[String(s) for s in c.reads if haskey(bindref, String(s)) && !(String(s) in own)]))
        isempty(uses) || (d["binduses"] = uses)
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
        # Re-run the defining cell itself ONLY when it actually depends on the control
        # that changed — i.e. the changed var is in its `reads` (its own code or another
        # widget's args use it: `@bind a …; y = a*2`, or `@bind d Slider(1:a)`). The
        # registry preserves the value across that re-run. A cell that defines the control
        # but doesn't read it (incl. a pure bind cell) is skipped, so dragging its slider
        # never needlessly re-evaluates (and re-renders) the control.
        reruns_self = Symbol(name) in cell.reads
        for did in dependents_of(nb.report, Set([id]))
            (did == id && !reruns_self) && continue
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
    meta = Dict{String,Any}(
        "id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
        "version" => nb.version, "worker" => _kernel_status(nb.kernel))
    if get(nb.report.meta, "hydrating", false) === true
        # While the env reconstructs: show the embedded frozen render if present (already
        # cell_json-shaped), else the parsed cells un-run. Live cells replace these on hydrate.
        meta["cells"] = if haskey(nb.report.meta, "preview")
            nb.report.meta["preview"]
        else
            bindref, hostednames = _bind_index(nb.report)
            [cell_json(c, bindref, hostednames) for c in nb.report.cells]
        end
        meta["hydrating"] = true
        return meta
    end
    bindref, hostednames = _bind_index(nb.report)
    meta["cells"] = [cell_json(c, bindref, hostednames) for c in nb.report.cells]
    haskey(nb.report.meta, "hydrate_error") && (meta["hydrateError"] = nb.report.meta["hydrate_error"])
    return meta
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
    _autoindex!(nb)                      # a new `using` in this cell → pick up its docs
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
    _autoindex!(nb)                      # added/edited cell may introduce a new `using`
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

# ── Build-floor + version-CAS (multi-agent write safety) ─────────────────────
# The safety layer Slate owns so several agents can drive ONE notebook without
# clobbering each other (MULTIAGENT.md §3). Two composable mechanisms, both opt-in
# so the solo-agent path is completely unaffected (no token, no expected_version):
#
#   • Build-floor: a notebook-scoped lease. While held, only the holder (the agent
#     presenting the matching token) may commit — the Galley's "one voice at a time"
#     enforced at the Slate layer, for ANY agent, crew or not. Auto-expires after
#     FLOOR_TTL idle so a crashed holder can't deadlock the notebook.
#   • Version-CAS: when NO floor is held, a mutation may carry the `nb.version` it was
#     decided against; we reject if the notebook has moved since (lost-update guard).
#
# Floor state lives in a module-level map (not an AgentSession/LiveNotebook field) so
# it's Revise-friendly. Lock order is always nb.lock → _FLOOR_LOCK (never inverted).
mutable struct FloorLease
    holder::String
    token::String
    acquired_at::Float64
    renewed_at::Float64
end
const _NB_FLOOR = Dict{String,FloorLease}()   # notebook id → current lease
const _FLOOR_LOCK = ReentrantLock()
const FLOOR_TTL = 180.0                        # seconds of idleness before a lease is reclaimable

# Current live lease for `nb`, or nothing (reclaiming an expired one in passing).
function _live_floor(nb::LiveNotebook)
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        l === nothing && return nothing
        if time() - l.renewed_at > FLOOR_TTL
            delete!(_NB_FLOOR, nb.id)
            return nothing
        end
        return l
    end
end

# Grant (or re-grant to the same holder) the floor → (token, ""), or (nothing, why).
function acquire_floor!(nb::LiveNotebook, holder::AbstractString)
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        if l !== nothing && time() - l.renewed_at <= FLOOR_TTL && l.holder != String(holder)
            return (nothing, "held by '$(l.holder)' (≈$(round(Int, time() - l.acquired_at))s ago)")
        end
        tok = bytes2hex(rand(UInt8, 6))
        _NB_FLOOR[nb.id] = FloorLease(String(holder), tok, time(), time())
        return (tok, "")
    end
end

# Keep a held lease alive across a multi-op transaction (called after each commit).
function _renew_floor!(nb::LiveNotebook, token::AbstractString)
    isempty(token) && return
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        l !== nothing && l.token == token && (l.renewed_at = time())
    end
end

# Release a held lease (only the token holder can). Returns true if released.
function release_floor!(nb::LiveNotebook, token::AbstractString)
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        (l !== nothing && l.token == token) || return false
        delete!(_NB_FLOOR, nb.id)
        return true
    end
end

# Human-readable floor state for the read digest.
function floor_status(nb::LiveNotebook)
    l = _live_floor(nb)
    l === nothing ? "free" : "🔒 held by '$(l.holder)' (≈$(round(Int, time() - l.acquired_at))s)"
end

# Gate one agent commit. Returns nothing to proceed, or a rejection string (the op
# must NOT mutate). Call inside `nb.lock`. A verified floor holder skips version-CAS
# (exclusivity already guarantees freshness); otherwise the optional version check
# catches a lost update against another agent's (or an external) commit.
function _guard_commit(nb::LiveNotebook; token::AbstractString = "", expected_version::Int = -1)
    l = _live_floor(nb)
    if l !== nothing
        l.token == token && return nothing
        return "⛔ build-floor held by '$(l.holder)' — your change was NOT applied. Call slate.acquire_floor first (or wait for it to release / expire)."
    end
    if expected_version >= 0 && expected_version != nb.version
        return "⚠ stale write REJECTED — you decided against v$(expected_version) but the notebook is now at v$(nb.version). Nothing was applied; re-read (slate.read) and retry.\n\n" * notebook_digest(nb)
    end
    return nothing
end

# ── Agent cell operations (the incremental-build tool surface) ───────────────
# Cell-level ops the agent drives via `slate.*`: each mutates the live notebook,
# runs the affected cell, pushes the change to open browser tabs, and returns a
# compact TEXT result so the agent works in a tight read→add→run→observe loop —
# the cure for "compose everything in the head, then dump one big Edit."

# Compact text of a cell's result for the agent: the value/stdout, or the error,
# plus a note that rich output (image/chart/table) rendered (the agent can't see
# the pixels here, but knows it worked).
function _cell_result_text(c::Cell)
    o = c.output
    o === nothing && return "(not run)"
    o.exception === nothing ||
        return "ERROR: " * o.exception * (o.backtrace === nothing ? "" : "\n" * first(o.backtrace, 800))
    parts = String[]
    isempty(rstrip(o.stdout)) || push!(parts, rstrip(o.stdout))
    isempty(o.value_repr) || push!(parts, o.value_repr)
    rich = String[]
    isempty(o.display) || push!(rich, join(unique(ch.mime for ch in o.display), "+"))
    isempty(o.echarts) || push!(rich, "echart")
    isempty(o.tables)  || push!(rich, "table")
    isempty(rich) || push!(parts, "[rendered: " * join(rich, ", ") * "]")
    txt = rstrip(join(parts, "\n"))
    return isempty(txt) ? "(ok — no value)" : txt
end

# The notebook as the agent should see it: each cell's id, kind, state, source,
# and (for code) its result.
function notebook_digest(nb::LiveNotebook)
    lock(nb.lock) do
        io = IOBuffer()
        print(io, "Notebook '", nb.id, "' — ", abspath(nb.path), " — ", length(nb.report.cells),
              " cell(s) — v", nb.version, " — build-floor: ", floor_status(nb))
        for c in nb.report.cells
            kind = c.kind == MARKDOWN ? "md" : "code"
            print(io, "\n\n### id=", c.id, "  [", kind, ", ", lowercase(string(c.state)), "]\n")
            print(io, rstrip(c.source))
            c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
        end
        return String(take!(io))
    end
end

# Push an agent-driven change to open browser tabs (the watcher won't — our own
# file write is canonical, so it doesn't echo back as an external change).
_agent_push!(nb::LiveNotebook) = (nb.version += 1; _broadcast(nb, string(nb.version)))

_cell_exists(nb, id) = _index_of(nb.report.cells, id) !== nothing
function _result_of(nb, id)
    i = _index_of(nb.report.cells, id)
    i === nothing ? "(cell $id not found)" : _cell_result_text(nb.report.cells[i])
end

"Add a cell (default code) after `after` (end if empty) WITH `source`, run it,
return id + result. One file write (build the cell with its source up front) so the
async file-watcher can't race the intermediate empty-cell state."
function agent_add_cell!(nb::LiveNotebook, source::AbstractString;
                         after::AbstractString = "", kind::AbstractString = "code",
                         token::AbstractString = "", expected_version::Int = -1)
    rej = nothing
    cid = lock(nb.lock) do
        rej = _guard_commit(nb; token = token, expected_version = expected_version)
        rej === nothing || return ""
        cells = nb.report.cells
        i = isempty(after) ? length(cells) : something(_index_of(cells, after), length(cells))
        cell = Cell(_gen_id(nb.report), kind == "md" ? MARKDOWN : CODE, String(source))
        _snapshot!(nb)
        insert!(cells, i + 1, cell)
        _commit_structure!(nb, i + 1)        # build deps, restale from here, eval, one write
        return cell.id
    end
    rej === nothing || return rej
    _renew_floor!(nb, token)
    _agent_push!(nb)
    return "added id=$cid →\n$(_result_of(nb, cid))"
end

"Replace a cell's source, run it, return its result."
function agent_edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString;
                          token::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, id) || return "(no cell id=$id)"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; token = token, expected_version = expected_version)
        r === nothing || return r
        edit_cell!(nb, id, source)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, token)
    _agent_push!(nb)
    return "edited id=$id →\n$(_result_of(nb, id))"
end

"Run one cell (or recompute all stale if `id` empty); return the result(s)."
function agent_run!(nb::LiveNotebook, id::AbstractString = "";
                    token::AbstractString = "", expected_version::Int = -1)
    rej = lock(nb.lock) do
        r = _guard_commit(nb; token = token, expected_version = expected_version)
        r === nothing || return r
        eval_stale!(nb.report, nb.kernel)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, token)
    _agent_push!(nb)
    isempty(id) ? "ran stale cells; notebook is up to date" :
        (_cell_exists(nb, id) ? "id=$id →\n$(_result_of(nb, id))" : "(no cell id=$id)")
end

"Delete a cell."
function agent_delete_cell!(nb::LiveNotebook, id::AbstractString;
                            token::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, id) || return "(no cell id=$id)"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; token = token, expected_version = expected_version)
        r === nothing || return r
        delete_cell!(nb, id)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, token)
    _agent_push!(nb)
    return "deleted id=$id"
end

# Find a live notebook by hub id or by (expanded, absolute) path. (`h` is a `Hub`;
# untyped because `Hub` is defined later in this file.)
function find_live(h, key::AbstractString)
    lock(h.lock) do
        haskey(h.notebooks, key) && return h.notebooks[key]
        f = abspath(expanduser(String(key)))
        for nb in values(h.notebooks)
            abspath(nb.path) == f && return nb
        end
        return nothing
    end
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

# Fold / unfold a cell (view-only; persisted in the `.jl` header as the `collapsed` token, so it
# travels with the notebook). No re-eval — just flip the flag and rewrite the file.
function set_collapsed!(nb::LiveNotebook, id::AbstractString, collapsed::Bool)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, id); i === nothing && return nb
        f = nb.report.cells[i].flags
        collapsed ? push!(f, :collapsed) : delete!(f, :collapsed)
        _persist!(nb)
    end
    return nb
end

# Hide / show a cell's code editor (view-only; persisted in the `.jl` header as the `hidecode`
# token). The output (plot) stays visible — for clean, presentation-style cells. No re-eval.
function set_code_hidden!(nb::LiveNotebook, id::AbstractString, hidden::Bool)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, id); i === nothing && return nb
        f = nb.report.cells[i].flags
        hidden ? push!(f, :hidecode) : delete!(f, :hidecode)
        _persist!(nb)
    end
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

# ── Streaming import of a self-contained `.jl` (index page) ───────────────────
# A self-contained notebook is a transport artifact: before it can run it must be `expand`ed
# into a real project tree and its environment instantiated. `_sse_import` streams that whole
# flow over SSE (same raw-Stream pattern as `_sse`) so the open box shows live progress —
# expand → the actual package resolve/instantiate output → open.

# True if `path`'s file carries a `Slate.bundle` footer. Scans for the open marker only; never
# decodes the (potentially large) base64 payload.
function _has_bundle_footer(path::AbstractString)
    isfile(path) || return false
    try
        for line in eachline(path)
            startswith(line, _BUNDLE_OPEN) && return true
        end
    catch
    end
    return false
end

# The single notebook `.jl` at the root of an expanded bundle (Project/Manifest/local/repo are
# the only other root entries). "" if none found.
function _expanded_notebook(tdir::AbstractString)
    for f in readdir(tdir)
        (endswith(f, ".jl") && isfile(joinpath(tdir, f))) && return joinpath(tdir, f)
    end
    return ""
end

# SSE handler for `GET /api/import-standalone?path=&target=` — the **Import** flow: expand the
# bundle into `target` (a real project the user owns) and open it, streaming progress. ("Run
# (temporary)" is a plain open instead: load_notebook hydrates against the depot cache, so it
# needs no streamed instantiate here.) Events:
#   status <text>  — coarse phase label
#   log    <line>  — one line of expand / instantiate output
#   done   <json>  — {id,url,target}; the client redirects into the opened notebook
#   failed <text>  — a handled error (named `failed`, not `error`, to avoid clashing with
#                    EventSource's built-in transport `error` event on the client)
# `h` is the `Hub` (untyped here only because its struct is defined later in this file).
function _sse_import(stream::HTTP.Stream, h)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    # Returns false if the write failed (client disconnected / cancelled) so callers can stop.
    function emit(ev::AbstractString, data::AbstractString)
        io = IOBuffer()
        println(io, "event: ", ev)
        for ln in split(data, '\n'); println(io, "data: ", ln); end   # SSE: one data: per line
        println(io)
        try; write(stream, String(take!(io))); return true; catch; return false; end
    end
    # Stream `Pkg.instantiate()` for `projdir`; returns :ok / :aborted / :failed.
    function instantiate!(projdir)
        emit("status", "Resolving & instantiating packages — this can take a while…")
        jl = Base.julia_cmd()[1]
        out = Pipe()
        proc = run(pipeline(`$jl --project=$projdir --color=no --startup-file=no -e 'using Pkg; Pkg.instantiate()'`;
                            stdout = out, stderr = out); wait = false)
        close(out.in)                       # parent's write end; lets eachline see EOF on exit
        for line in eachline(out)
            emit("log", line) || (try; kill(proc); catch; end; return :aborted)
        end
        wait(proc)
        return proc.exitcode == 0 ? :ok : :failed
    end
    q = HTTP.queryparams(HTTP.URI(stream.message.target))
    path = expanduser(strip(get(q, "path", "")))
    target = let t = strip(get(q, "target", "")); isempty(t) ? "" : expanduser(t); end
    try
        (isfile(path) && _has_bundle_footer(path)) ||
            return emit("failed", "Not a self-contained notebook (no Slate.bundle footer):\n$path")
        (!isempty(target) && isdir(target) && !isempty(readdir(target))) &&
            return emit("failed", "Target directory already exists and isn't empty:\n$target")
        emit("status", "Expanding bundle…")
        tdir = expand(path; target = target)
        openpath = _expanded_notebook(tdir)
        isempty(openpath) && return emit("failed", "Expanded, but found no notebook .jl in $tdir")
        emit("log", "Expanded to $tdir")
        r = instantiate!(tdir)
        r === :aborted && return            # client gone
        r === :failed && return emit("failed",
            "Package instantiation failed.\nThe project is at $tdir — open it and retry there.")
        emit("status", "Opening notebook…")
        id = open_notebook!(h, openpath)
        emit("done", JSON.json(Dict("id" => id, "url" => "/n/$id", "target" => tdir)))
    catch e
        emit("failed", sprint(showerror, e))
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
# agent_id → crew label ("" = default/solo). Lets the relay tag each event with the
# speaking crew member so the UI can lane multiple agents and replay stays attributed.
const _AGENT_CREW = Dict{String,String}()
# notebook id → buffered relayed envelopes (crew-tagged, in arrival order), so a
# browser reload can replay the whole conversation across ALL crew agents (agentMsgs
# is in-memory JS, lost on reload). One ordered ring per notebook. Capped.
const _AGENT_LOG = Dict{String,Vector{String}}()
const _AGENT_LOG_CAP = 4000

# Durable chat transcript: the in-memory `_AGENT_LOG` replays across a browser reload,
# but is lost on a SERVER restart. Mirror it to a per-notebook JSONL (keyed by abspath,
# in the cache dir) so the conversation survives a restart too. Loaded on open; appended
# as each (non-delta) envelope is relayed; compacted to the cap; wiped by "clear chat".
_chat_log_file(path) = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                                "kaimonslate", "chat", SlateHistory._sha(abspath(String(path)))[1:16] * ".jsonl")
function _load_chat_log!(nb::LiveNotebook)
    f = _chat_log_file(nb.path)
    isfile(f) || return
    try
        lines = filter(!isempty, readlines(f))
        length(lines) > _AGENT_LOG_CAP && (lines = last(lines, _AGENT_LOG_CAP))
        lock(_AGENT_LOCK) do; _AGENT_LOG[nb.id] = collect(String, lines); end
    catch e
        @warn "slate: chat-log load failed" exception = (e, catch_backtrace())
    end
    return nothing
end
_append_chat_log(nb::LiveNotebook, line::AbstractString) =
    (f = _chat_log_file(nb.path); try; mkpath(dirname(f)); open(f, "a") do io; println(io, line); end; catch; end; nothing)
_rewrite_chat_log(nb::LiveNotebook, lines) =
    (f = _chat_log_file(nb.path); try; mkpath(dirname(f)); open(f, "w") do io; for l in lines; println(io, l); end; end; catch; end; nothing)
function _clear_chat_log!(nb::LiveNotebook)
    lock(_AGENT_LOCK) do; delete!(_AGENT_LOG, nb.id); end
    f = _chat_log_file(nb.path)
    try; isfile(f) && rm(f); catch; end
    return nothing
end

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

# ── Semantic docs search (docs v2) ────────────────────────────────────────────
# Index harvested docstrings into a Qdrant collection via Kaimon's Ollama+Qdrant
# tools (reached through the service endpoint), so the agent AND the UI can search
# the Julia/package API by meaning. Embeddings: qwen3-embedding:0.6b (1024-d, cosine).
const _DOCS_COLLECTION = "slate_docs"
const _DOCS_DIM = 1024
const _DOCS_MODEL = "qwen3-embedding:0.6b"

# Call a Kaimon MCP tool, RAW value (service endpoint uses Serialization, so
# vectors/dicts come back native; tolerate a JSON-string handler too).
_kt(tool::Symbol, args::Dict) = getfield(Main, :Kaimon).KaimonGate.call_tool(tool, Dict{String,Any}(args))
_kt_json(v) = v isa AbstractString ? JSON.parse(v) : v
# Tolerant field access — results may be Dicts (string or symbol keys) or NamedTuples.
_field(x, k) = x isa AbstractDict ? get(x, k, get(x, Symbol(k), nothing)) :
               (hasproperty(x, Symbol(k)) ? getproperty(x, Symbol(k)) : nothing)

_embed(text::AbstractString) = Float64[Float64(x) for x in
    _kt_json(_kt(:ollama_embed, Dict("text" => String(text), "model" => _DOCS_MODEL)))]

function _ensure_docs_collection()
    ex = _kt_json(_kt(:qdrant_collection_exists, Dict("collection" => _DOCS_COLLECTION)))
    (ex === true || ex == "true") && return
    _kt(:qdrant_create_collection, Dict("collection" => _DOCS_COLLECTION,
                                        "vector_size" => _DOCS_DIM, "distance" => "Cosine"))
    return
end

# Stable positive id for a doc record (first 60 bits of its SHA-256 → fits Int).
_doc_id(s) = parse(Int, SlateHistory._sha(s)[1:15]; base = 16)

"Embed + upsert harvested doc records into the search index. Returns the count indexed."
function index_docs!(records)
    _agent_available() || return 0
    isempty(records) && return 0
    _ensure_docs_collection()
    n = 0
    for r in records
        modname = string(get(r, "module", "")); name = string(get(r, "name", ""))
        doc = string(get(r, "doc", "")); text = "$modname.$name\n$doc"
        vec = try; _embed(text); catch; continue; end
        pt = Dict("id" => _doc_id(text), "vector" => vec,
                  "payload" => Dict("module" => modname, "name" => name, "doc" => doc))
        try; _kt(:qdrant_upsert_points, Dict("collection" => _DOCS_COLLECTION, "points" => [pt])); n += 1; catch; end
    end
    return n
end

"Semantic search the docs index → up to `limit` {module,name,doc,score} matches."
function search_docs(query::AbstractString; limit::Int = 8)
    _agent_available() || return Dict{String,Any}[]
    vec = try; _embed(query); catch; return Dict{String,Any}[]; end
    res = _kt_json(_kt(:qdrant_search, Dict("collection" => _DOCS_COLLECTION,
                                            "vector" => vec, "limit" => limit)))
    hits = res isa AbstractVector ? res :
           something(_field(res, "result"), _field(res, "hits"), Any[])
    out = Dict{String,Any}[]
    for h in hits
        p = something(_field(h, "payload"), h)
        push!(out, Dict("module" => string(something(_field(p, "module"), "")),
                        "name"   => string(something(_field(p, "name"), "")),
                        "doc"    => string(something(_field(p, "doc"), "")),
                        "score"  => something(_field(h, "score"), 0.0)))
    end
    return out
end

# ── Auto-indexing ─────────────────────────────────────────────────────────────
# Index docs WITHOUT the agent asking: on open, eagerly index the notebook's project
# deps; incrementally pick up any package a cell `using`s. Runs in the background and
# is version-cached (persistent), so re-opens are instant and only changed deps re-index.
const _DOC_CACHE = Dict{String,String}()                 # package name → last-indexed version
const _DOC_CACHE_LOCK = ReentrantLock()
_doc_cache_file() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                             "kaimonslate", "docindex.json")
function _doc_cache_load()
    lock(_DOC_CACHE_LOCK) do
        isempty(_DOC_CACHE) || return
        f = _doc_cache_file()
        isfile(f) || return
        try; merge!(_DOC_CACHE, Dict(String(k) => string(v) for (k, v) in JSON.parsefile(f))); catch; end
    end
end
function _doc_cache_put!(name, version)
    lock(_DOC_CACHE_LOCK) do
        _DOC_CACHE[String(name)] = String(version)
        f = _doc_cache_file()
        try; mkpath(dirname(f)); open(f, "w") do io; JSON.print(io, _DOC_CACHE); end; catch; end
    end
end

# Package names `using`/`import`ed across the notebook's code cells (`using X: y` → X).
function _used_packages(report::Report)
    pkgs = String[]
    for c in report.cells
        c.kind == CODE || continue
        top = try; Meta.parseall(c.source); catch; continue; end
        for s in (top isa Expr && top.head === :toplevel ? top.args : Any[top])
            (s isa Expr && (s.head === :using || s.head === :import)) || continue
            for a in s.args
                m = (a isa Expr && a.head === :(:)) ? a.args[1] : a
                if m isa Expr && m.head === :. && !isempty(m.args) && m.args[1] isa Symbol
                    nm = String(m.args[1])
                    nm in ("Base", "Core", "Main") || push!(pkgs, nm)
                end
            end
        end
    end
    return unique(pkgs)
end

"Background auto-index: project deps (eager) ∪ packages the cells use, version-cached."
function _autoindex!(nb::LiveNotebook)
    _agent_available() || return nothing
    Threads.@spawn try
        _doc_cache_load()
        want = Dict{String,String}()
        for d in (try; ReportEngine.project_deps(nb.kernel, nb.report); catch; Dict{String,Any}[]; end)
            n = string(get(d, "name", "")); isempty(n) || (want[n] = string(get(d, "version", "")))
        end
        for u in _used_packages(nb.report); haskey(want, u) || (want[u] = ""); end
        pending = String[n for (n, v) in want if get(_DOC_CACHE, n, nothing) != v]
        isempty(pending) && return
        recs = ReportEngine.harvest_docs(nb.kernel, nb.report, pending)
        index_docs!(recs)
        for n in pending; _doc_cache_put!(n, get(want, n, "")); end
        @info "slate: auto-indexed docs" notebook = nb.id packages = pending symbols = length(recs)
    catch e
        @warn "slate: auto-index failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# ── Client-rendered image snapshots ───────────────────────────────────────────
# Client-side visuals (ECharts) only render in the browser, so the SPA captures their
# PNG from the canvas and posts it here, keyed by (notebook, cell). That gives a
# UNIFORM image interface: `cell_image` returns a PNG whether the figure was produced
# server-side (CairoMakie's `image/png`) or client-side (ECharts) — one approach for
# the agent (`slate_view`) today, and the source of figure bytes for PDF export later.
const _SNAPSHOTS = Dict{String,Dict{String,Vector{UInt8}}}()   # nbid → cellid → latest PNG
const _SNAP_SVG = Dict{String,Dict{String,String}}()           # nbid → cellid → latest light-theme SVG (vector)
const _SNAP_SVG_DARK = Dict{String,Dict{String,String}}()      # nbid → cellid → latest dark-theme SVG (vector)
const _SNAP_LOCK = ReentrantLock()
function set_snapshot!(nbid::AbstractString, cell::AbstractString, png::Vector{UInt8};
                       svg::Union{AbstractString,Nothing} = nothing,
                       svg_dark::Union{AbstractString,Nothing} = nothing)
    lock(_SNAP_LOCK) do
        get!(_SNAPSHOTS, String(nbid), Dict{String,Vector{UInt8}}())[String(cell)] = png
        svg === nothing || (get!(_SNAP_SVG, String(nbid), Dict{String,String}())[String(cell)] = String(svg))
        svg_dark === nothing || (get!(_SNAP_SVG_DARK, String(nbid), Dict{String,String}())[String(cell)] = String(svg_dark))
    end
    return nothing
end
_snapshot(nbid, cell) = lock(_SNAP_LOCK) do
    get(get(_SNAPSHOTS, String(nbid), Dict{String,Vector{UInt8}}()), String(cell), nothing)
end
# Vector (SVG) snapshot of a client-rendered chart for PDF export — crisp at any scale.
# `dark` picks the dark-theme rendering (for a dark-mode PDF). `nothing` if absent.
_snapshot_svg(nbid, cell; dark::Bool = false) = lock(_SNAP_LOCK) do
    store = dark ? _SNAP_SVG_DARK : _SNAP_SVG
    get(get(store, String(nbid), Dict{String,String}()), String(cell), nothing)
end

"""
    cell_image(nb, cell) -> Vector{UInt8} | nothing

A PNG of the cell's rendered figure, regardless of where it was drawn: the server-side
raster (CairoMakie `image/png`) if present, else the latest client-captured snapshot
(ECharts). `nothing` if the cell has no viewable figure.
"""
function cell_image(nb::LiveNotebook, cell::AbstractString)
    i = findfirst(c -> c.id == cell, nb.report.cells)
    i === nothing && return nothing
    o = nb.report.cells[i].output
    if o !== nothing
        for ch in o.display
            ch.mime == "image/png" && return copy(ch.data)
        end
    end
    return _snapshot(nb.id, cell)
end

# ── Static export (HTML / print-to-PDF) ──────────────────────────────────────
# A self-contained HTML document of the notebook: markdown rendered, code shown,
# outputs embedded (images as base64), client-rendered ECharts frozen to their latest
# snapshot PNG, interactive tables flattened to static HTML. KaTeX from a CDN typesets
# math. No server, no scripts to boot — openable offline and printable to PDF.
const _EXPORT_CSS = """
:root{--bg:#0d1120;--bg2:#141828;--bg3:#1a1e2e;--border:#2a2e40;--text:#d4d8e8;--dim:#6a7090;
  --accent:#569cd6;--green:#56d364;--red:#e57575;--gold:#ffd700;}
*{box-sizing:border-box;} body{background:var(--bg);color:var(--text);margin:0;
  font-family:'Segoe UI',system-ui,sans-serif;line-height:1.6;}
.export{max-width:900px;margin:0 auto;padding:36px 24px 80px;}
.exp-title{color:#fff;font-size:1.9rem;margin:0 0 2px;}
.exp-meta{color:var(--dim);font-size:.78rem;font-family:monospace;margin-bottom:24px;
  border-bottom:1px solid var(--border);padding-bottom:14px;}
.exp-md{margin:14px 0;} .exp-md h1{font-size:1.6rem;border-bottom:1px solid var(--border);padding-bottom:.2em;}
.exp-md table,.exp-table{border-collapse:collapse;margin:8px 0;font-size:.84rem;}
.exp-md td,.exp-md th,.exp-table td,.exp-table th{border:1px solid var(--border);padding:4px 10px;text-align:left;}
.exp-table th{background:var(--bg3);color:var(--dim);} .exp-table td{font-variant-numeric:tabular-nums;}
.exp-md code{background:var(--bg3);padding:1px 5px;border-radius:4px;}
.exp-code{margin:14px 0;border:1px solid var(--border);border-radius:8px;background:var(--bg2);overflow:hidden;}
.exp-src{margin:0;padding:10px 14px;background:var(--bg3);border-bottom:1px solid var(--border);overflow-x:auto;}
.exp-src code{font-family:'Cascadia Code','Fira Code',monospace;font-size:.82rem;color:var(--text);white-space:pre;}
.exp-out{font-size:.86rem;} .exp-out .out,.exp-out .val,.exp-out .err{padding:8px 14px;}
.exp-out .out{color:var(--dim);} .exp-out .val{color:var(--green);} .exp-out .err{color:var(--red);}
.exp-out pre{margin:0;white-space:pre-wrap;} .exp-out .dispwrap,.disp.img{padding:10px 14px;}
.disp.img img{max-width:100%;height:auto;border-radius:4px;display:block;}
.disp.latex{padding:6px 14px;overflow-x:auto;} .katex{font-size:1.1em;}
@media print{ body{-webkit-print-color-adjust:exact;print-color-adjust:exact;} .exp-code{break-inside:avoid;} }
"""

function _export_table_html(spec)
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    io = IOBuffer()
    print(io, "<table class=\"exp-table\"><thead><tr>")
    for c in cols
        nm = c isa AbstractDict ? get(c, "name", "") : c
        print(io, "<th>", _esc(string(nm)), "</th>")
    end
    print(io, "</tr></thead><tbody>")
    for r in rows
        print(io, "<tr>")
        for v in r
            print(io, "<td>", v === nothing ? "" : _esc(string(v)), "</td>")
        end
        print(io, "</tr>")
    end
    print(io, "</tbody></table>")
    return String(take!(io))
end

function export_html(nb::LiveNotebook; include_source::Bool = true)
    lock(nb.lock) do
        title = _esc(nb.report.title)
        io = IOBuffer()
        print(io, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"/>",
              "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"/><title>", title, "</title>",
              "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css\"/>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js\"></script>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js\"></script>",
              "<style>", _EXPORT_CSS, "</style></head><body><article class=\"export\">")
        print(io, "<h1 class=\"exp-title\">", title, "</h1>")
        print(io, "<div class=\"exp-meta\">Exported from Kaimon Slate · ", _esc(abspath(nb.path)), "</div>")
        for c in nb.report.cells
            if c.kind == MARKDOWN
                print(io, "<section class=\"exp-md\">", markdown_html(c.source, c.interp), "</section>")
            else
                print(io, "<section class=\"exp-code\">")
                (include_source && !isempty(strip(c.source))) &&
                    print(io, "<pre class=\"exp-src\"><code>", _esc(c.source), "</code></pre>")
                print(io, "<div class=\"exp-out\">", output_html(c), "</div>")
                if !isempty(_echarts_specs(c))            # client-rendered chart → freeze to snapshot
                    png = _snapshot(nb.id, c.id)
                    png === nothing || print(io, "<div class=\"disp img\"><img alt=\"chart\" src=\"data:image/png;base64,",
                                                  Base64.base64encode(png), "\"/></div>")
                end
                for spec in _table_specs(c)
                    print(io, _export_table_html(spec))
                end
                print(io, "</section>")
            end
        end
        print(io, "</article><script>window.addEventListener('load',function(){",
              "if(window.renderMathInElement)renderMathInElement(document.body,{delimiters:[",
              "{left:'\$\$',right:'\$\$',display:true},{left:'\\\\[',right:'\\\\]',display:true},",
              "{left:'\$',right:'\$',display:false},{left:'\\\\(',right:'\\\\)',display:false}],throwOnError:false});});",
              "</script></body></html>")
        return String(take!(io))
    end
end

# The notebook-priming system prompt, set once at `agent_open` (the `system_prompt`
# arg → `claude --append-system-prompt`). It makes the agent a *live notebook
# operator* — driving the reactive notebook one cell at a time through the `slate.*`
# tools and reading each result — instead of a blind file-author that composes
# everything in its head and dumps one big Edit.
# DAG-scoped context for a per-cell ✨ turn: the target cell + its upstream dependency
# cone (what it reads, transitively, with sources) + downstream impact. Lets the agent
# work focused — edit this cell, branch upstream only when the cause is a precursor — and
# it knows WHERE the precursors are instead of grepping.
# Inline-reference expansion: a user can mention a cell by `@id` in chat (the UI offers
# autocomplete on `@`). For each @token that resolves to a real cell id, append that cell's
# source + current result, so the agent has the referenced cells in hand without surveying
# the whole notebook. Returns "" when nothing resolves.
function _mention_context(nb::LiveNotebook, text::AbstractString)
    byid = Dict(c.id => c for c in nb.report.cells)
    refs = String[]
    for m in eachmatch(r"@([A-Za-z0-9_]+)", String(text))
        id = String(m.captures[1])
        (haskey(byid, id) && !(id in refs)) && push!(refs, id)
    end
    isempty(refs) && return ""
    io = IOBuffer()
    print(io, "══ REFERENCED CELLS — the user mentioned these by @id; here is each one's source and current result. ══")
    for id in refs
        c = byid[id]
        kind = c.kind == MARKDOWN ? "md" : "code"
        print(io, "\n\n--- @", id, " [", kind, "] ---\n", rstrip(c.source))
        c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
    end
    return String(take!(io))
end

function _cell_context(nb::LiveNotebook, id::AbstractString)
    cells = nb.report.cells
    i = findfirst(c -> c.id == id, cells)
    i === nothing && return ""
    byid = Dict(c.id => c for c in cells)
    up = Set{String}(); frontier = String[id]
    while !isempty(frontier)
        c = get(byid, pop!(frontier), nothing); c === nothing && continue
        for d in c.deps
            (d == id || d in up) && continue
            push!(up, d); push!(frontier, d)
        end
    end
    down = setdiff(dependents_of(nb.report, Set([id])), Set([id]))
    io = IOBuffer()
    println(io, "══ SCOPED TURN — the user clicked ✨ on cell `", id, "`. This cell is your ENTIRE focus. ══")
    println(io, "- Answer about / modify ONLY cell `", id, "` (and, if a fix truly requires it, the upstream",
            " cells listed below that it reads from).")
    println(io, "- Do NOT review, critique, or touch any OTHER cell. Do NOT call `slate_read` to survey the",
            " whole notebook — this cell's source, output, its upstream dependency cone, and its downstream",
            " impact are ALL given below. Only read another cell if you genuinely need one not shown here.")
    println(io, "- If the request can't be satisfied within this cell + its precursors, say so briefly instead",
            " of widening scope. `slate_view(\"", id, "\")` shows this cell's figure if it has one.")
    tc = cells[i]
    println(io, "\n--- cell `", id, "` source ---\n", tc.source)
    o = tc.output
    if o !== nothing
        o.exception !== nothing ? println(io, "→ ERROR: ", first(split(o.exception, "\n"))) :
            (isempty(o.value_repr) || println(io, "→ ", o.value_repr))
    end
    upcells = [c for c in cells if c.id in up]
    if !isempty(upcells)
        println(io, "\n--- upstream cells it depends on (define what it reads) ---")
        for c in upcells
            println(io, "[`", c.id, "`] ", replace(strip(first(split(c.source, "\n"))), r"\s+" => " "))
        end
    end
    isempty(down) || println(io, "\n--- changing it re-runs downstream: ", join(sort(collect(down)), ", "))
    return String(take!(io))
end

function _agent_system_prompt(nb::LiveNotebook)
    return """
    You are pair-building a LIVE reactive Julia notebook with the user, in real time.
    Your notebook id is "$(nb.id)" (file: $(abspath(nb.path))). Pass that id as the
    `notebook` argument to every slate tool.

    OPERATE THE NOTEBOOK THROUGH THESE TOOLS — do NOT edit the .jl file directly:
      mcp__kaimon__slate_read(notebook)                          — all cells + their outputs/errors
      mcp__kaimon__slate_add_cell(notebook, source, after, kind) — append a cell, RUN it, return its result
      mcp__kaimon__slate_edit_cell(notebook, cell, source)       — revise a cell, run it, return its result
      mcp__kaimon__slate_run(notebook, cell)                     — run a cell ("" = all stale)
      mcp__kaimon__slate_delete_cell(notebook, cell)             — remove a cell
      mcp__kaimon__slate_view(notebook, cell)                    — SEE a cell's rendered
        figure (returns the image) — inspect a CairoMakie plot you made and fix it
    (`after`="" appends at the end; `kind` is "code" or "md".)

    LEARN THE API — you have NO file access, so do NOT grep/read source. Search docs:
      mcp__kaimon__slate_search_docs(notebook, query)  — fuzzy semantic search of the
        notebook's package docs ("a function that sorts in place") → signatures + docs.
        The project's packages are auto-indexed in the background, so usually just search.
      mcp__kaimon__slate_index_docs(notebook, modules) — force-index more packages
        (comma-separated) if a search comes up empty

    WORK INCREMENTALLY — this is the entire point of the project:
    - Call slate_read FIRST to see the current state.
    - Add ONE cell at a time with slate_add_cell, then LOOK at the result it returns.
    - If a cell errors, fix it with slate_edit_cell before moving on.
    - Choose the next cell from what you just saw. Do NOT compose the whole notebook
      in your head and write it all at once — small, visible steps the user can watch.
    - Cells are REACTIVE: a cell re-runs when an upstream variable it reads changes.
    - Charts: prefer **ECharts** for interactive data viz — `echart(Dict("series"=>[...], …))`
      returns a chart that is interactive IN THE BROWSER (hover, zoom, tooltips) and animates in
      place on reactive updates. Use **CairoMakie** (dark theme: `using CairoMakie;
      set_theme!(theme_dark())`; return the figure, e.g. `fig`) for static/scientific figures.
      NEVER GLMakie (needs a GPU window → hangs the worker) or WGLMakie (incompatible deps).
    - For controls / parameter interactivity, use the NOTEBOOK's reactivity, NOT Makie's: bind a
      control in one cell — `@bind N Slider(10:5:300)` (also `Toggle`, `ColorPicker`, …) — and
      have OTHER cells READ `N`; they re-run and re-render when it changes (works with both
      ECharts and CairoMakie). Do NOT use Makie `SliderGrid`/`@lift`/`Observable` — they need an
      interactive backend we don't have and render dead (static) under CairoMakie.

    SCOPED TURNS: if a turn begins with a "SCOPED TURN — the user clicked ✨ on cell `…`"
    block, that cell is your whole focus for the turn. Stay on it (and only the upstream cells
    that block lists); do NOT survey or comment on the rest of the notebook, and do NOT
    slate_read the whole thing — the relevant context is already in the block.

    Be concise in chat. You are a focused notebook assistant — ignore any global or
    project onboarding (Kaimon usage quizzes, "take the quiz", Revise/Infiltrator
    workflows); never run a quiz or setup step.
    """
end

# Ensure an agent is bound to this notebook, spawning one (keyed `slate-<id>`,
# cwd = the notebook's directory) on first use and registering its event route.
# The agent inherits the host's MCP config (Kaimon included), so it can also call
# `slate.*`/`ex` — no explicit `mcp_config` needed (passing one with --strict would
# instead cut it off from the live Kaimon). Cell editing goes through the file.
# Ensure a crew member's agent is bound to this notebook, spawning one on first use.
# `crew` is a crew label ("" = the default/solo agent — id stays `slate-<id>` for
# back-compat so a re-adopted agent matches across an extension restart). Multiple
# crew agents share one notebook; `_AGENT_ROUTES` already maps each id → this nb.
# `model` ("" = service default = sonnet) binds at spawn only — an already-running
# crew agent keeps its model until reaped (the UI kills it on a model-setting change).
function _ensure_agent!(nb::LiveNotebook; crew::AbstractString = "", model::AbstractString = "",
                        permission::AbstractString = "")
    label = String(crew)
    existing = get(nb.agents, label, "")
    isempty(existing) || return existing
    aid = isempty(label) ? "slate-$(nb.id)" : "slate-$(nb.id)-$(label)"
    open_args = Dict{String,Any}(
            "cwd" => dirname(abspath(nb.path)),
            "id"  => aid,
            # Kaimon M4 permission preset. "lab" (the default) allows the agent the Kaimon
            # MCP tools (slate.*/ex/qdrant) + file edits — enough to drive + introspect the
            # notebook, without arbitrary shell/web. Runs unattended (no prompt to stall a
            # headless agent); the agent_* recursion guard is always applied. The user can
            # pick another preset in Settings ("auto"/"default"/"bypass"); it binds at spawn,
            # so a change reaps the agent (chat-kill) and the next turn respawns on it.
            "permission" => (isempty(permission) ? "lab" : String(permission)),
            "system_prompt" => _agent_system_prompt(nb))
    isempty(model) || (open_args["model"] = model)   # omit → Kaimon's default (sonnet)
    res = try
        _agent_call(:agent_open, open_args)
    catch e
        # Agent already running (e.g. it outlived an extension restart — agents are
        # Kaimon-owned) → re-adopt it rather than failing the chat.
        occursin("in use", lowercase(sprint(showerror, e))) || rethrow()
        Dict("agent_id" => aid)
    end
    aid = String(get(res, "agent_id", aid))
    isempty(aid) && error("agent_open returned no id")
    lock(_AGENT_LOCK) do
        _AGENT_ROUTES[aid] = nb
        _AGENT_CREW[aid] = label
        nb.agents[label] = aid
    end
    isempty(label) && (nb.agent_id = aid)   # keep the back-compat alias in sync
    return aid
end

# Close + deregister a notebook's crew agents (best effort). `keep_log=true` preserves
# the replay transcript (hard-kill: agents gone, but the conversation stays visible and
# a fresh agent continues it); `false` wipes it (notebook close — nothing left to show).
function _reap_agents!(nb::LiveNotebook; keep_log::Bool = false)
    aids = lock(_AGENT_LOCK) do
        ids = collect(values(nb.agents))
        for aid in ids
            delete!(_AGENT_ROUTES, aid); delete!(_AGENT_CREW, aid)
        end
        empty!(nb.agents)
        keep_log || delete!(_AGENT_LOG, nb.id)
        ids
    end
    nb.agent_id = ""
    if _agent_available()
        for aid in aids
            try; _agent_call(:agent_close, Dict{String,Any}("agent_id" => aid)); catch; end
        end
    end
    return nothing
end
_close_agent!(nb::LiveNotebook) = _reap_agents!(nb; keep_log = false)   # on notebook close

"""
    relay_agent_event(channel, data)

Gate-bus callback for an `agent:<id>` event: forward the raw `{kind,turn,data}`
JSON onto the bound notebook's SSE, prefixed `agent:` so the SPA's live-event
handler routes it to the chat pane. `data` already rides the bus as a JSON string.
"""
function relay_agent_event(channel::AbstractString, data)
    startswith(channel, "agent:") || return
    aid = String(channel)[length("agent:")+1:end]
    nb, crew = lock(_AGENT_LOCK) do
        get(_AGENT_ROUTES, aid, nothing), get(_AGENT_CREW, aid, "")
    end
    nb === nothing && return
    s = data isa AbstractString ? String(data) : String(JSON.json(data))
    env = try; JSON.parse(s); catch; nothing; end
    kind = env === nothing ? "" : get(env, "kind", "")
    # Tag the envelope with the speaking crew member so the SPA can lane multiple
    # agents (and replay stays attributed). Re-serialize only when we parsed cleanly.
    if env !== nothing
        env["crew"] = crew
        s = JSON.json(env)
    end
    # Mark the agent busy across a turn so the file-watcher attributes the edits it
    # makes to "agent" (not "external"). Clear shortly AFTER the turn ends, so the
    # watcher tick that picks up the agent's final save is still inside the window.
    if kind == "turn_started"
        nb.agent_busy = true
    elseif kind == "result"
        # Keep attributing edits to the agent for a bit after the turn ends — the
        # final file-write often syncs a couple seconds late (watcher latency), and
        # would otherwise be mislabeled "external".
        @async (sleep(8.0); nb.agent_busy = false)
    end
    # Always push live (token + tool-input deltas stream to the pane). Buffer for
    # reload-replay, but SKIP the liveness chunks (`data.delta == true` and
    # `tool_input_delta`) — the authoritative copies (the `delta:false` block, the
    # `tool_result`) are buffered, so replay stays clean and the cap isn't burned.
    _broadcast(nb, "agent:" * s)
    is_delta = kind == "tool_input_delta" ||
        (env !== nothing && (d = get(env, "data", nothing); d isa AbstractDict && get(d, "delta", false) === true))
    if !is_delta
        compact = false; bufcopy = String[]
        lock(_AGENT_LOCK) do
            buf = get!(_AGENT_LOG, nb.id, String[])
            push!(buf, s)
            length(buf) > _AGENT_LOG_CAP && (popfirst!(buf); compact = true; bufcopy = copy(buf))
        end
        # Mirror to disk (outside the lock): append the new line, or compact the file to
        # the capped buffer once we start dropping the oldest (bounds the file to the cap).
        compact ? _rewrite_chat_log(nb, bufcopy) : _append_chat_log(nb, s)
    end
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
          "cells" => length(nb.report.cells), "worker" => _worker_label(nb))
     for nb in values(h.notebooks)]
end

# A short "worker :port" tag for the index, when a notebook runs on a gate worker.
_worker_label(nb::LiveNotebook) =
    nb.kernel isa GateKernel && nb.kernel.port != 0 ? " · worker&nbsp;:$(nb.kernel.port)" : ""


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
# Path completions for the open box's file-picker dropdown. Returns `(items, truncated)` —
# the (scrollable) dropdown shows every match in a directory; `limit` is a high guard against
# pathological dirs (node_modules, …), and `truncated` lets the UI say "keep typing to filter"
# rather than silently dropping entries. Directories sort first, then `.jl`, then the rest.
function _path_completions(q::AbstractString; limit::Int = 500)
    s = String(q)
    isempty(s) && (s = "~/")
    s == "~" && return (items = ["~/"], truncated = false)
    slash = findlast('/', s)
    prefix = slash === nothing ? "" : s[1:slash]
    leaf   = slash === nothing ? s : s[nextind(s, slash):end]
    base   = isempty(prefix) ? pwd() : expanduser(prefix)
    isdir(base) || return (items = String[], truncated = false)
    entries = try
        readdir(base)
    catch
        return (items = String[], truncated = false)
    end
    keep = String[]
    for e in entries
        startswith(e, leaf) || continue
        (startswith(e, ".") && !startswith(leaf, ".")) && continue
        full = joinpath(base, e)
        push!(keep, isdir(full) ? prefix * e * "/" : prefix * e)
    end
    sort!(keep; by = p -> (endswith(p, "/") ? 0 : (endswith(p, ".jl") ? 1 : 2), lowercase(p)))
    return (items = first(keep, limit), truncated = length(keep) > limit)
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

# The gate worker's stdout/stderr log (eval output, prints, errors, package loads)
# — the debugging surface for "what is the worker doing". In-process kernels have
# no separate log (cells eval in the extension process).
function worker_log(nb::LiveNotebook; maxbytes::Int = 100_000)
    if nb.kernel isa GateKernel                          # real subprocess → tail its raw log
        path = nb.kernel.logpath
        (isempty(path) || !isfile(path)) && return "(worker not started yet)"
        s = read(path, String)
        return ncodeunits(s) > maxbytes ? "…(truncated; last $(maxbytes ÷ 1000)KB)…\n" * String(last(s, maxbytes)) : s
    end
    # In-process kernel: no separate log file, so synthesize an eval console from the
    # cells' captured output (state · duration · stdout · error).
    io = IOBuffer()
    println(io, "# in-process kernel — this notebook isn't in a Julia project, so cells eval in")
    println(io, "# the extension. Open it inside a project dir for a separate gate worker + raw log.\n")
    ran = false
    for c in nb.report.cells
        c.kind == CODE || continue
        o = c.output; o === nothing && continue
        ran = true
        println(io, "[$(c.id)]  $(lowercase(string(c.state)))  ·  $(round(o.duration_ms; digits = 1))ms")
        st = rstrip(o.stdout)
        isempty(st) || println(io, "  " * replace(st, "\n" => "\n  "))
        o.exception === nothing || println(io, "  ERROR: " * replace(o.exception, "\n" => "\n  "))
        println(io)
    end
    ran || println(io, "(no code cells have run yet)")
    return String(take!(io))
end

# Locally-served models for the Settings dropdown, via an Ollama-compatible `/api/tags`.
# Both Ollama and vmlx (the MLX inference server for Apple Silicon) speak this protocol —
# Kaimon's OllamaBackend drives either, routed by an `ollama:` / `vmlx:` model prefix.
# Proxied through the server so the browser dodges cross-origin issues; best-effort —
# returns [] if that server isn't running.
function _tags_models(host::AbstractString)
    startswith(host, "http") || (host = "http://" * host)
    try
        r = HTTP.get(rstrip(host, '/') * "/api/tags"; connect_timeout = 2, request_timeout = 4, retry = false)
        d = JSON.parse(String(r.body))
        names = String[String(get(m, "name", "")) for m in get(d, "models", Any[])]
        # Drop embedding-only models — they can't run /api/chat, so they're useless as agents.
        return filter(n -> !isempty(n) && !occursin(r"embed"i, n), names)
    catch
        return String[]
    end
end
_ollama_models() = _tags_models(get(ENV, "OLLAMA_HOST", "http://127.0.0.1:11434"))
_vmlx_models()   = _tags_models(get(ENV, "VMLX_HOST", "http://127.0.0.1:8000"))

include("export_typst.jl")   # export_pdf(nb) — publication-quality PDF via Typst (uses types defined above)
include("export_bundle.jl")  # export_standalone(nb) / expand(jl) — self-contained single-source .jl

function _make_router(h::Hub)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", _ -> _html(read(_INDEX_ASSET, String)))   # static asset; sessions render client-side from /api/notebooks
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
        r = _path_completions(q)
        _json(Dict("completions" => r.items, "truncated" => r.truncated))
    end)
    # Stat a path (with ~ expansion) so the open box can decide: open file / show
    # subpaths for a directory / confirm-create for a new path.
    HTTP.register!(router, "GET", "/api/path-info", req -> begin
        p = expanduser(strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))))
        # `standalone`: a self-contained `.jl` (Slate.bundle footer) → the open box offers the
        # import-into-a-project helper instead of opening it bare.
        _json(Dict("path" => p, "exists" => ispath(p), "isdir" => isdir(p), "isfile" => isfile(p),
                   "standalone" => isfile(p) && _has_bundle_footer(p)))
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
    HTTP.register!(router, "POST", "/api/{id}/collapse/{cid}", req -> _withnb(h, req, nb -> begin
        set_collapsed!(nb, HTTP.getparam(req, "cid"), get(_body(req), "collapsed", true) === true); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/hidecode/{cid}", req -> _withnb(h, req, nb -> begin
        set_code_hidden!(nb, HTTP.getparam(req, "cid"), get(_body(req), "hidden", true) === true); _json(state_json(nb))
    end))
    # Static export: a self-contained HTML document of the notebook (also the print →
    # PDF path — the browser's print dialog saves it as PDF). `?dl=1` downloads; `?source=0`
    # hides code. No scripts/server needed; KaTeX (CDN) typesets math, figures are embedded.
    HTTP.register!(router, "GET", "/api/{id}/export.html", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        html = export_html(nb; include_source = get(qp, "source", "1") != "0")
        headers = Pair{String,String}["Content-Type" => "text/html; charset=utf-8"]
        if get(qp, "dl", "0") == "1"
            fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".html"
            push!(headers, "Content-Disposition" => "attachment; filename=\"$fn\"")
        end
        HTTP.Response(200, headers, html)
    end))
    # Publication-quality PDF via Typst (server-side). `?source=0` hides code listings.
    HTTP.register!(router, "GET", "/api/{id}/export.pdf", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        pdf = try
            export_pdf(nb; include_source = get(qp, "source", "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""))
        catch e
            return HTTP.Response(500, "PDF export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf"
        HTTP.Response(200, ["Content-Type" => "application/pdf",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], pdf)
    end))
    # Self-contained single-source .jl: cells + full Project/Manifest + local source (+ a
    # shallow git bundle when the project is a repo). Reinflate with `KaimonSlate.expand`.
    HTTP.register!(router, "GET", "/api/{id}/export.standalone.jl", req -> _withnb(h, req, nb -> begin
        jl = try
            export_standalone(nb)
        catch e
            return HTTP.Response(500, "Standalone export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".standalone.jl"
        HTTP.Response(200, ["Content-Type" => "text/x-julia; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], jl)
    end))
    # ── Notebook packages ─────────────────────────────────────────────────────
    # Show the environment with provenance: `notebook` deps (the notebook's own forked env,
    # where adds land — removable) and `parent` deps (inherited from the enclosing project,
    # which the forked env extends — read-only). `detached` is true when there's no parent
    # (the notebook env IS everything). `manageable` is false for an in-process kernel.
    HTTP.register!(router, "GET", "/api/{id}/packages", req -> _withnb(h, req, nb -> begin
        e = _notebook_adds(nb)
        _json(Dict("notebook" => e.adds,
                   "parent" => e.parent,
                   "parentPath" => e.parentpath,
                   "detached" => e.detached,
                   "manageable" => !(nb.kernel isa InProcessKernel)))
    end))
    HTTP.register!(router, "POST", "/api/{id}/package", req -> _withnb(h, req, nb -> begin
        b = _body(req); op = String(get(b, "op", "")); name = String(get(b, "name", ""))
        (op in ("add", "rm")) || return _json(Dict("ok" => false, "message" => "bad op '$op'"))
        res = lock(nb.lock) do
            r = ReportEngine.pkg_op(nb.kernel, nb.report, op, name)
            if get(r, "ok", false) === true              # env changed → re-run so `using` cells pick it up
                for c in nb.report.cells; c.kind == CODE && (c.state = STALE); end
                eval_stale!(nb.report, nb.kernel)
                _refresh_env_meta!(nb)                   # update the .jl reproducibility footer
            end
            r
        end
        get(res, "ok", false) === true && (_autoindex!(nb); _agent_push!(nb))
        _json(res)
    end))
    # The worker's stdout/stderr log — what the kernel is doing when evaluating cells.
    HTTP.register!(router, "GET", "/api/{id}/worker-log", req -> _withnb(h, req, nb ->
        _json(Dict("log" => worker_log(nb), "worker" => _kernel_status(nb.kernel)))))
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
        tgt = String(get(_body(req), "target", ""))   # per-cell ✨: scope the turn to a cell + its dep cone
        crew = String(get(_body(req), "crew", ""))     # crew label → route to that crew member's agent ("" = solo)
        model = String(get(_body(req), "model", ""))   # agent model ("" = service default = sonnet); binds at spawn
        perm = String(get(_body(req), "permission", "")) # permission preset (lab/auto/default/bypass); binds at spawn
        ment = _mention_context(nb, text)              # @id cell references → inline those cells' context
        isempty(ment) || (text = ment * "\n\n" * text)
        isempty(tgt) || (text = _cell_context(nb, tgt) * "\n\nUSER REQUEST:\n" * text)
        try
            aid = _ensure_agent!(nb; crew = crew, model = model, permission = perm)
            res = _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => text))
            _json(Dict("ok" => true, "agent_id" => aid, "crew" => crew, "turn" => get(res, "turn", nothing)))
        catch e
            _json(Dict("ok" => false, "error" => sprint(showerror, e)))
        end
    end))
    # Replay the conversation after a page reload (buffered as relayed, crew-tagged,
    # in arrival order across ALL crew agents on this notebook).
    HTTP.register!(router, "GET", "/api/{id}/agent-log", req -> _withnb(h, req, nb -> begin
        log = lock(_AGENT_LOCK) do; copy(get(_AGENT_LOG, nb.id, String[])); end
        _json(Dict("events" => log, "agents" => copy(nb.agents)))
    end))
    # Interrupt EVERY crew agent's in-flight turn (best effort, graceful).
    HTTP.register!(router, "POST", "/api/{id}/chat-interrupt", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        any_int = false
        for aid in collect(values(nb.agents))
            r = try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; Dict("interrupted" => false); end
            get(r, "interrupted", false) === true && (any_int = true)
        end
        _json(Dict("ok" => true, "interrupted" => any_int))
    end))
    # Hard stop: interrupt AND close (terminate) every crew agent — for a wedged agent
    # that `agent_interrupt` alone can't stop (it only cancels an in-flight LLM turn).
    # Reaps the whole crew so the next chat message spawns fresh.
    HTTP.register!(router, "POST", "/api/{id}/chat-kill", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        for aid in collect(values(nb.agents))
            try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
        end
        _reap_agents!(nb; keep_log = true)   # agents gone, transcript stays visible
        _json(Dict("ok" => true, "killed" => true))
    end))
    # Clear the conversation entirely: interrupt + reap every agent, then wipe the
    # transcript from memory AND disk. The next message starts a clean chat.
    HTTP.register!(router, "POST", "/api/{id}/chat-clear", req -> _withnb(h, req, nb -> begin
        if _agent_available() && !isempty(nb.agents)
            for aid in collect(values(nb.agents))
                try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
            end
        end
        _reap_agents!(nb; keep_log = false)   # agents gone + in-memory log dropped
        _clear_chat_log!(nb)                  # and the on-disk transcript
        _json(Dict("ok" => true, "cleared" => true))
    end))
    # Locally-served models → the Settings model dropdown (ollama:<name> / vmlx:<name>).
    HTTP.register!(router, "GET", "/api/{id}/ollama-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _ollama_models()))))
    HTTP.register!(router, "GET", "/api/{id}/vmlx-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _vmlx_models()))))
    # Semantic docs search (docs v2) — for the UI palette; the agent uses slate.search_docs.
    HTTP.register!(router, "GET", "/api/{id}/docsearch", req -> _withnb(h, req, nb -> begin
        q = strip(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))
        _json(Dict("results" => isempty(q) ? Dict{String,Any}[] : search_docs(String(q))))
    end))
    # Client-rendered figure snapshot (ECharts canvas → PNG) — feeds slate_view + PDF.
    HTTP.register!(router, "POST", "/api/{id}/snapshot", req -> _withnb(h, req, nb -> begin
        b = _body(req); cell = String(get(b, "cell", "")); img = String(get(b, "image", ""))
        getstr(k) = (v = get(b, k, nothing); (v isa AbstractString && !isempty(v)) ? String(v) : nothing)
        svg = getstr("svg"); svg_dark = getstr("svgDark")
        (isempty(cell) || isempty(img)) && return _json(Dict("ok" => false))
        try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(img)); svg = svg, svg_dark = svg_dark); catch; return _json(Dict("ok" => false)); end
        _json(Dict("ok" => true))
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
        target = stream.message.target
        m = match(_EVENTS_RE, target)
        if m !== nothing
            nb = lock(h.lock) do; get(h.notebooks, m.captures[1], nothing); end
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        elseif startswith(target, "/api/import-standalone")   # long-lived SSE; raw Stream, not router
            _sse_import(stream, h)
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
