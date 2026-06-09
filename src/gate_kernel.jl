# Per-notebook gate-worker kernel (Phase 2). Dispatches cell eval to a `SlateWorker`
# subprocess over Kaimon's ZMQ gate, so capture happens where the live value lives
# and each notebook gets its own project env + crash isolation.
#
# Used only when `Main.Kaimon` is present (the extension context); it references
# Kaimon *dynamically* so `ReportEngine` keeps no Kaimon/KaimonGate dependency.
# Included into `module ReportEngine` (after eval.jl — needs `Kernel`/`CellOutput`).

export GateKernel

const _WORKER_JL = joinpath(@__DIR__, "worker.jl")

# Per-worker TCP ports. A simple counter (no Sockets dep); collisions are unlikely
# and surface as a worker bind error rather than silent crosstalk.
const _GATE_PORT = Ref(9100)
function _next_ports()
    p = _GATE_PORT[]; _GATE_PORT[] += 2
    return (p, p + 1)
end

_kaimon() = getfield(Main, :Kaimon)
"True when running inside the Kaimon extension (gate client available)."
gate_available() = isdefined(Main, :Kaimon) &&
    isdefined(_kaimon(), :ConnectionManager) && isdefined(_kaimon(), :connect_tcp!)

# A slate-owned ZMQ connection manager. The extension is its *own* subprocess, so
# the TUI's `GATE_CONN_MGR` isn't present here — we run our own manager (one,
# shared across all notebooks) to spawn/connect workers.
const _MGR = Ref{Any}(nothing)
function _manager()
    _MGR[] === nothing && (_MGR[] = _kaimon().ConnectionManager())
    return _MGR[]
end

"""
    GateKernel(project; parent="", envdir="") <: Kernel

Evaluate cells in a `SlateWorker` subprocess pinned to the single environment `project`.

Environment model (fork-and-extend, never `LOAD_PATH`-stacked):
- **Base mode** (`project == parent`): the notebook has no packages of its own, so it runs
  *directly* in the enclosing `parent` project — zero overhead, exactly like a plain script.
- **Forked mode** (`project == envdir`): once the notebook adds a package, it gets its OWN
  env (`envdir`) seeded from the parent (parent package dev'd in, parent deps + Manifest
  copied) and resolved as ONE consistent environment — so the notebook can override the
  base and there are never two versions of a shared dep. Adds never touch the parent.
- **Detached** (`parent == ""`): no enclosing project; the notebook env is everything.

`envdir` is the fork target (the per-notebook env dir); `parent` is recorded for provenance
and re-seeding. Lazily spawns + connects on first use (`prepare!`).
"""
mutable struct GateKernel <: Kernel
    project::String  # the single active environment (== parent in base mode, == envdir when forked)
    parent::String   # enclosing project dir ("" = detached) — base + provenance source
    envdir::String   # this notebook's own env dir (fork target); active once forked
    port::Int
    stream_port::Int
    proc::Any        # worker Base.Process
    conn::Any        # Main.Kaimon REPLConnection
    logpath::String  # worker stdout/stderr log
    GateKernel(project::AbstractString; parent::AbstractString = "", envdir::AbstractString = "") =
        new(String(project), String(parent), String(envdir), 0, 0, nothing, nothing, "")
end

# True when the notebook is running directly in its parent (no own packages yet).
_base_mode(k::GateKernel) = !isempty(k.parent) && k.project == k.parent

# The notebook's OWN environment directory — a per-notebook env materialised under the
# depot, keyed by the notebook's absolute path. It carries the notebook-specific package
# adds (stacked on the parent project) and is the source for the reproducibility footer.
# Reconstructable from that footer, so repos stay free of sidecar env dirs.
function notebook_env_dir(path::AbstractString)
    ap = abspath(String(path))
    key = replace(splitext(basename(ap))[1], r"[^A-Za-z0-9_-]" => "_") *
          "-" * string(hash(ap) % 0xffffffff; base = 16, pad = 8)
    return joinpath(first(DEPOT_PATH), "environments", "kaimonslate", key)
end

# Ensure a notebook env exists on disk (an empty `Project.toml` is enough for the worker
# to activate it and for `Pkg.add` to populate it). Seeds `[deps]` from `seed_toml` when
# given (the reproducibility footer's embedded notebook Project.toml).
function ensure_notebook_env!(dir::AbstractString; seed_toml::AbstractString = "")
    mkpath(dir)
    proj = joinpath(dir, "Project.toml")
    isfile(proj) || write(proj, isempty(seed_toml) ? "" : seed_toml)
    return dir
end

# Worker connection name → report id, for routing gate-stream `slate_refresh`
# events back to the right notebook's recompute callback.
const _GATE_SESSION = Dict{String,String}()
const _POLLER = Ref{Any}(nothing)

# Single background task: drain the gate stream and dispatch `slate_refresh`
# events (published by a worker's async cell) to the matching notebook.
function _ensure_poller!()
    _POLLER[] === nothing || return
    _POLLER[] = Threads.@spawn begin
        K = _kaimon()
        while true
            try
                # Coalesce a burst: a worker's async loop can PUB many `slate_refresh`
                # events between polls. Union the changed vars per notebook and fire
                # ONE recompute per notebook per poll (≈ one refresh / 50 ms) instead
                # of one per message — otherwise a tight async loop floods every SSE
                # client with redundant re-renders.
                pending = Dict{String,Set{String}}()
                for m in K.drain_stream_messages!(_manager())
                    m.channel == "slate_refresh" || continue
                    rid = get(_GATE_SESSION, m.session_name, nothing)
                    rid === nothing && continue
                    s = get!(pending, rid, Set{String}())
                    for v in split(m.data, ","; keepempty = false)
                        push!(s, String(v))
                    end
                end
                for (rid, vars) in pending
                    isempty(vars) || _do_refresh(rid, collect(vars))
                end
            catch
            end
            sleep(0.05)
        end
    end
    return nothing
end

# Worker boot: put KaimonGate on LOAD_PATH (via Kaimon's env), load the SlateWorker
# capture payload, and serve its tools over TCP. Pinned to the notebook's project.
function _worker_script(port::Int, stream_port::Int, parent::AbstractString = "")
    # Put ONLY KaimonGate (the ZMQ bridge) on the worker's LOAD_PATH — from its own
    # minimal project (ZMQ/Serialization/…, no HTTP), NOT Kaimon's full env. Kaimon's
    # Manifest pins the custom HTTP 2.0 (Reseau); prepending it would shadow a notebook
    # project's standard HTTP v1 and break packages that need it (WGLMakie→Bonito, …).
    kgate_dir = joinpath(Base.pkgdir(_kaimon()), "lib", "KaimonGate")
    # No LOAD_PATH stacking: the notebook runs in a SINGLE active env (`@`, set by
    # `--project`) — either the parent directly (base mode) or a forked env that already
    # contains the parent's deps (forked mode). `PARENT_PROJECT` is recorded only so the
    # worker can attribute package provenance (which deps are notebook adds vs parent).
    return """
    insert!(LOAD_PATH, 1, $(repr(kgate_dir)))
    import KaimonGate
    include($(repr(_WORKER_JL)))
    SlateWorker.PARENT_PROJECT[] = $(repr(String(parent)))
    SlateWorker.start(; host = "127.0.0.1", port = $port, stream_port = $stream_port)
    """
end

function _spawn_worker!(k::GateKernel)
    port, stream_port = _next_ports()
    k.port = port; k.stream_port = stream_port
    logdir = joinpath(tempdir(), "kaimonslate"); mkpath(logdir)
    k.logpath = joinpath(logdir, "worker-$port.log")
    cmd = `$(Base.julia_cmd()) --project=$(k.project) --startup-file=no -e $(_worker_script(port, stream_port, k.parent))`
    # Stream the worker's stdout/stderr through a pipe into the log file, flushing
    # each chunk, so the log is tailable in real time. A plain `stdout=<file>`
    # redirect is block-buffered and only lands on disk when the worker exits —
    # useless for watching a live worker (the worker also flushes its own buffer
    # periodically; see SlateWorker.start).
    out = Pipe()
    k.proc = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    close(out.in)
    Threads.@spawn begin
        io = open(k.logpath, "w")
        try
            while !eof(out)
                write(io, readavailable(out)); flush(io)
            end
        catch
        finally
            close(io)
        end
    end
    @info "SlateWorker spawned" project = k.project port = port log = k.logpath
    return k
end

function _connect!(k::GateKernel)
    K = _kaimon()
    mgr = _manager()
    deadline = time() + 90             # worker Julia startup + KaimonGate load is slow
    last = ""
    while time() < deadline
        try
            k.conn = K.connect_tcp!(mgr, "127.0.0.1", k.port;
                                    name = "slate-$(k.port)", stream_port = k.stream_port)
            return k
        catch e
            last = sprint(showerror, e); sleep(0.5)
        end
    end
    error("GateKernel: could not reach worker on port $(k.port): $last")
end

function prepare!(k::GateKernel, report::Report)
    if k.conn === nothing
        _spawn_worker!(k)
        _connect!(k)
        _GATE_SESSION[k.conn.name] = report.id   # route this worker's stream events back to the notebook
        _ensure_poller!()
        _maybe_sync_parent!(k)                   # forked + parent drifted → re-resolve once, up front
    end
    return nothing
end

# Synchronous gate tool call → the tool's raw return value (binary wire-form).
function _tool(k::GateKernel, name::String, args::Dict; timeout::Float64 = 120.0)
    K = _kaimon()
    req = (type = :tool_call, name = name, arguments = Dict{String,Any}(args))
    r = K._req_send_recv(k.conn, req; caller_timeout = timeout)
    r.ok || error("gate $name failed: $(r.error)")
    get(r.response, :type, :error) === :error &&
        error("gate $name error: $(get(r.response, :message, "unknown"))")
    return get(r.response, :value, nothing)
end

# Rebuild the engine's `CellOutput` from the worker's wire-form NamedTuple
# (`run_capture`'s output), the same mapping as the in-process `_eval_capture`.
function _wire_to_output(wire)
    wire === nothing &&
        return CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", "gate returned no value", nothing, 0.0)
    chunks = MimeChunk[MimeChunk(String(m), Vector{UInt8}(bytes)) for (m, bytes) in wire.mime]
    binds = BindSpec[BindSpec(b.name, b.kind, b.params, b.value) for b in wire.binds]
    return CellOutput(String(wire.stdout), chunks, collect(wire.echarts), collect(wire.tables),
                      binds, String(wire.value_repr), wire.exception, wire.backtrace, Float64(wire.duration_ms))
end

function eval_capture(k::GateKernel, report::Report, source::AbstractString)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_eval", Dict("source" => String(source)))
    catch e
        return CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", sprint(showerror, e), nothing, 0.0)
    end
    return _wire_to_output(wire)
end

# Forward a paged-table page request to the worker (where the provider lives).
# Normalize/clamp the request once here, then pass flat scalars over the gate.
function table_page(k::GateKernel, report::Report, table_id::AbstractString, request::AbstractDict)
    prepare!(k, report)
    req = _page_request(request)
    wire = try
        _tool(k, "__slate_table_page", Dict{String,Any}(
            "table_id" => String(table_id), "page" => req.page, "page_size" => req.page_size,
            "sort_col" => req.sort_col, "sort_desc" => req.sort_desc, "search" => req.search))
    catch
        return (rows = Vector{Any}[], total = 0)
    end
    wire === nothing && return (rows = Vector{Any}[], total = 0)
    return (rows = collect(wire.rows), total = Int(wire.total))
end

# Capture markdown interpolation expressions in the worker (rich, one each).
function interpolate(k::GateKernel, report::Report, exprs::Vector{String})
    prepare!(k, report)
    wires = try
        _tool(k, "__slate_interp", Dict("exprs" => exprs))
    catch
        return CellOutput[]
    end
    wires === nothing && return CellOutput[]
    return CellOutput[_wire_to_output(w) for w in wires]
end

function harvest_docs(k::GateKernel, report::Report, mod_names)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_harvest_docs", Dict("mod_names" => collect(String, mod_names)))
    catch
        return Dict{String,Any}[]
    end
    wire === nothing && return Dict{String,Any}[]
    return Dict{String,Any}[Dict{String,Any}(String(k) => v for (k, v) in r) for r in wire]
end

function project_deps(k::GateKernel, report::Report)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_project_deps", Dict{String,Any}())
    catch
        return Dict{String,Any}[]
    end
    wire === nothing && return Dict{String,Any}[]
    return Dict{String,Any}[Dict{String,Any}(String(k) => v for (k, v) in r) for r in wire]
end

# Environment provenance: the notebook's own deps + the parent project's deps (for the
# package viewer). Returns `(notebook=(path, deps), parent=(path, deps)|nothing)`.
function env_info(k::GateKernel, report::Report)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_env_info", Dict{String,Any}())
    catch
        return (notebook = (path = "", deps = Dict{String,Any}[]), parent = nothing)
    end
    _grp(g) = g === nothing ? nothing :
        (path = String(get(g, :path, get(g, "path", ""))),
         name = String(get(g, :name, get(g, "name", ""))),
         deps = Dict{String,Any}[Dict{String,Any}(String(kk) => v for (kk, v) in d)
                                 for d in get(g, :deps, get(g, "deps", Any[]))])
    nb = _grp(get(wire, :notebook, get(wire, "notebook", nothing)))
    par = _grp(get(wire, :parent, get(wire, "parent", nothing)))
    return (notebook = nb === nothing ? (path = "", name = "", deps = Dict{String,Any}[]) : nb, parent = par)
end

# Add/remove a package in the notebook's own env. Adding the FIRST package while in base
# mode forks the notebook off its parent (seed + activate a single extended env) before the
# add, so the parent's `Project.toml` is never touched and there's one consistent resolution.
function pkg_op(k::GateKernel, report::Report, op::AbstractString, name::AbstractString)
    prepare!(k, report)
    if String(op) == "add" && _base_mode(k)
        r = try
            _tool(k, "__slate_fork", Dict{String,Any}("envdir" => k.envdir, "parent" => k.parent))
        catch e
            return Dict{String,Any}("ok" => false, "message" => "fork failed: " * sprint(showerror, e))
        end
        (r isa AbstractDict && get(r, :ok, get(r, "ok", false)) == false) &&
            return Dict{String,Any}("ok" => false, "message" => "fork failed: " * string(get(r, :message, get(r, "message", "?"))))
        k.project = k.envdir                        # the worker is now on the forked env
        _write_parent_marker!(k)                    # record the parent baseline we seeded from
    end
    try
        r = _tool(k, "__slate_pkg", Dict{String,Any}("op" => String(op), "name" => String(name)))
        r === nothing && return Dict{String,Any}("ok" => false, "message" => "no response from worker")
        return Dict{String,Any}(String(kk) => v for (kk, v) in r)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

# Hash of the parent's Manifest (its content) — the baseline a forked env was seeded from.
# Stored in the env as a marker so we can detect parent drift and auto re-resolve on open.
_parent_manifest_hash(parent::AbstractString) =
    (isempty(parent) || !isfile(joinpath(parent, "Manifest.toml"))) ? "" :
    string(hash(read(joinpath(parent, "Manifest.toml"), String)); base = 16)
_parent_marker_path(k::GateKernel) = joinpath(k.envdir, ".slate_parent_manifest")
function _write_parent_marker!(k::GateKernel)
    try; isempty(k.envdir) || write(_parent_marker_path(k), _parent_manifest_hash(k.parent)); catch; end
end

# Auto re-resolve a forked notebook env when its parent's Manifest has changed since we
# seeded it (keeps the one-env invariant: parent updates flow in, notebook adds preserved).
function _maybe_sync_parent!(k::GateKernel)
    (isempty(k.parent) || _base_mode(k)) && return
    cur = _parent_manifest_hash(k.parent)
    isempty(cur) && return
    prev = try; isfile(_parent_marker_path(k)) ? read(_parent_marker_path(k), String) : ""; catch; ""; end
    cur == prev && return
    try
        _tool(k, "__slate_sync_parent", Dict{String,Any}("envdir" => k.envdir, "parent" => k.parent); timeout = 600.0)
        _write_parent_marker!(k)
    catch
    end
    return
end

function assign_bind!(k::GateKernel, report::Report, name::Symbol, value)
    prepare!(k, report)
    try
        return _tool(k, "__slate_set_bind", Dict("name" => string(name), "value" => value))
    catch
        return value
    end
end

# Reset the worker namespace and mark every cell stale (mirrors `reset_module!`).
function reset!(k::GateKernel, report::Report)
    k.conn === nothing || (try; _tool(k, "__slate_reset", Dict{String,Any}()); catch; end)
    for c in report.cells
        c.state = STALE
        c.output = nothing
    end
    return nothing
end

"Kill the worker and close its gate connection."
function shutdown!(k::GateKernel)
    K = _kaimon()
    k.conn === nothing || (delete!(_GATE_SESSION, k.conn.name); try; K.send_shutdown!(k.conn); catch; end)
    k.proc === nothing || (try; kill(k.proc); catch; end)
    k.conn = nothing; k.proc = nothing
    return nothing
end
