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
    GateKernel(project) <: Kernel

Evaluate cells in a `SlateWorker` subprocess pinned to `project`, over the gate.
Lazily spawns + connects on first use (`prepare!`).
"""
mutable struct GateKernel <: Kernel
    project::String
    port::Int
    stream_port::Int
    proc::Any        # worker Base.Process
    conn::Any        # Main.Kaimon REPLConnection
    logpath::String  # worker stdout/stderr log
    GateKernel(project::AbstractString) = new(String(project), 0, 0, nothing, nothing, "")
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
function _worker_script(port::Int, stream_port::Int)
    kaimon_dir = Base.pkgdir(_kaimon())
    return """
    insert!(LOAD_PATH, 1, $(repr(kaimon_dir)))
    import KaimonGate
    include($(repr(_WORKER_JL)))
    SlateWorker.start(; host = "127.0.0.1", port = $port, stream_port = $stream_port)
    """
end

function _spawn_worker!(k::GateKernel)
    port, stream_port = _next_ports()
    k.port = port; k.stream_port = stream_port
    logdir = joinpath(tempdir(), "kaimonslate"); mkpath(logdir)
    k.logpath = joinpath(logdir, "worker-$port.log")
    cmd = `$(Base.julia_cmd()) --project=$(k.project) --startup-file=no -e $(_worker_script(port, stream_port))`
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
        return CellOutput("", MimeChunk[], Any[], Any[], "", "gate returned no value", nothing, 0.0)
    chunks = MimeChunk[MimeChunk(String(m), Vector{UInt8}(bytes)) for (m, bytes) in wire.mime]
    return CellOutput(String(wire.stdout), chunks, collect(wire.echarts), collect(wire.tables),
                      String(wire.value_repr), wire.exception, wire.backtrace, Float64(wire.duration_ms))
end

function eval_capture(k::GateKernel, report::Report, source::AbstractString)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_eval", Dict("source" => String(source)))
    catch e
        return CellOutput("", MimeChunk[], Any[], Any[], "", sprint(showerror, e), nothing, 0.0)
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

function assign!(k::GateKernel, report::Report, name::Symbol, value)
    prepare!(k, report)
    try
        _tool(k, "__slate_assign", Dict("name" => string(name), "value" => value))
    catch
    end
    return nothing
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
