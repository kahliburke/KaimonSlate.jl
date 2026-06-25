# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

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
    _note_server_write!(nb.report.id, hash(s))   # register BEFORE writing: a watcher tick fired by
    write(nb.path, s)                             # this write must recognize it as OURS, not external
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

# `hosts` is the list of cell ids whose control strip surfaces this bind (usually one,
# possibly several, possibly the bind's OWN cell). `hosted` stays a simple bool for the
# common path; `hostedby` lets the frontend say *where* (jump link) and tell self-host apart.
_bind_json(spec::BindSpec, hosts::Vector{String}) =
    Dict{String,Any}("name" => String(spec.name), "widget" => spec.widget,
                     "params" => spec.params, "value" => spec.value,
                     "hosted" => !isempty(hosts), "hostedby" => hosts)

# `bindref`: var-name → (defining cell, its BindSpec). `hostednames`: variable name →
# the cell ids that surface it via `controls=` (so each can collapse to a chip / jump link).
function cell_json(c::Cell, bindref::Dict{String,Tuple{Cell,BindSpec}} = Dict{String,Tuple{Cell,BindSpec}}(),
                   hostednames::Dict{String,Vector{String}} = Dict{String,Vector{String}}())
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
        d["binds"] = [_bind_json(b, get(hostednames, String(b.name), String[])) for b in c.binds]
    end
    (:collapsed in c.flags) && (d["collapsed"] = true)   # folded in the UI (persisted in the .jl)
    (:hidecode in c.flags) && (d["codeHidden"] = true)   # code editor hidden, output shown
    (:trace in c.flags) && (d["trace"] = true)           # @trace-wrapped on eval (collects trace rows)
    if c.output !== nothing && c.output.exception !== nothing
        el = ReportRender._cell_error_line(c.output)     # offending cell line → editor highlight + jump
        el === nothing || (d["errorLine"] = el)
    end
    # The trace rows ({line,name,value}) for the inspector popup — the cell's normal output is shown
    # in place; this rides alongside for the modal. Present only when the cell ran traced.
    (c.output === nothing || isempty(c.output.trace)) || (d["traceData"] = c.output.trace)
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
    hostednames = Dict{String,Vector{String}}()
    for c in report.cells, col in c.controls, n in col
        haskey(bindref, n) && push!(get!(hostednames, n, String[]), c.id)
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
    # The project ROOT (dir holding the nearest Project.toml above the notebook) — so "open
    # project in VS Code" opens the project, not the notebooks/ subdir. Omitted when detached.
    let proj = Base.current_project(dirname(abspath(nb.path)))
        proj === nothing || (meta["project"] = dirname(proj))
    end
    meta["hotreload"] = get(nb.report.meta, "hotreload", true)   # /src auto-reload toggle (default on)
    meta["undoLabel"] = undo_label(nb)   # next undoable action ("paste 3 cells"/…) — labels the Undo button
    meta["redoLabel"] = redo_label(nb)
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

