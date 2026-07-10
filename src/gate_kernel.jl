# Per-notebook gate-worker kernel (Phase 2). Dispatches cell eval to a `SlateWorker`
# subprocess over Kaimon's ZMQ gate, so capture happens where the live value lives
# and each notebook gets its own project env + crash isolation.
#
# Used only when `Main.Kaimon` is present (the extension context); it references
# Kaimon *dynamically* so `ReportEngine` keeps no Kaimon/KaimonGate dependency.
# Included into `module ReportEngine` (after eval.jl — needs `Kernel`/`CellOutput`).

export GateKernel

# Worker Julia-thread spec ("<compute>,<interactive>"), set by the server from persisted config /
# the Kaimon TUI panel. Empty → fall back to env / the adaptive default. Read at each worker spawn.
const WORKER_THREADS = Ref{String}("")

# The machine-adaptive default thread spec: min(cores, 8) compute + 1 interactive (idle threads park;
# the cap avoids oversubscription across several open notebooks). Used both at spawn and to report the
# effective count in state_json.
default_worker_threads() = string(min(Sys.CPU_THREADS, 8), ",1")

# The thread spec a worker would actually spawn with, given a per-kernel override `kthreads`:
# per-kernel override → global setting → adaptive default.
function effective_worker_threads(kthreads::AbstractString)
    !isempty(kthreads)        && return String(kthreads)
    !isempty(WORKER_THREADS[]) && return WORKER_THREADS[]
    return get(ENV, "KAIMONSLATE_JULIA_THREADS", default_worker_threads())
end

const _WORKER_JL = joinpath(@__DIR__, "worker.jl")
# Slate-owned env carrying ONLY Revise (+ its deps), so the worker can hot-reload the
# notebook's parent-project /src without adding Revise to the user's project. Stacked AFTER
# the notebook project on LOAD_PATH so the notebook's own deps always win.
const _REVISE_ENV = joinpath(@__DIR__, "worker_revise")

# ── Worker KaimonGate env ──────────────────────────────────────────────────────
# The worker imports KaimonGate (the ZMQ bridge) from LOAD_PATH[1]. Pointing that at
# Kaimon's lib/KaimonGate PROJECT DIR only works when the dir carries an instantiated
# Manifest — true for a dev checkout, FALSE for a registry install of Kaimon (read-only,
# shipped without a Manifest): there KaimonGate failed to precompile ("ZMQ … is required
# but does not seem to be installed") and the worker died — the standalone run.jl path
# lost all interactivity. So materialise a slate-owned env ONCE per KaimonGate version
# (`Pkg.develop(path) + instantiate` in a subprocess — never Pkg.activate in-process) and
# put THAT on the worker's LOAD_PATH. Falls back to the raw dir (the old behaviour, fine
# for a dev checkout) when the build fails; the build log stays in the env dir.
const _KGATE_ENV_ROOT = joinpath(get(DEPOT_PATH, 1, joinpath(homedir(), ".julia")),
                                 "scratchspaces", "kaimonslate-kgate")
const _KGATE_ENV_LOCK = ReentrantLock()

function _kgate_env()::String
    kgate = joinpath(Base.pkgdir(_kaimon()), "lib", "KaimonGate")
    proj = joinpath(kgate, "Project.toml")
    isfile(proj) || return kgate
    # Key by source path + declared deps + Julia version: a Kaimon upgrade (new pkgdir or
    # changed deps) or a Julia bump rebuilds; source edits in a dev checkout need no rebuild
    # (develop(path) tracks them live).
    key = string(hash((kgate, read(proj, String), string(VERSION))); base = 16)
    dir = joinpath(_KGATE_ENV_ROOT, key)
    lock(_KGATE_ENV_LOCK) do
        isfile(joinpath(dir, ".ready")) && return dir
        @info "slate: preparing the worker's KaimonGate environment (once per Kaimon version)…" dir
        buildlog = joinpath(dir, "build.log")
        try
            mkpath(dir)
            code = "using Pkg; Pkg.develop(path = ARGS[1]); Pkg.instantiate()"
            open(buildlog, "w") do io
                run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$dir -e $code $kgate`;
                             stdout = io, stderr = io))
            end
            write(joinpath(dir, ".ready"), kgate)
            return dir
        catch e
            @warn "slate: could not materialise the KaimonGate worker env — falling back to the raw project dir (the worker may fail if its deps aren't installed)" kgate buildlog exception = e
            return kgate
        end
    end
end

# Per-worker TCP ports. A simple counter (no Sockets dep); collisions are unlikely
# and surface as a worker bind error rather than silent crosstalk.
const _GATE_PORT = Ref(9100)
const _PORT_LOCK = ReentrantLock()
function _next_ports()
    lock(_PORT_LOCK) do            # atomic bump — concurrent spawns must not grab the same port
        p = _GATE_PORT[]; _GATE_PORT[] += 2
        return (p, p + 1)
    end
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
    pending::Vector{Any}  # footer packages to reconstruct on first use (env dir absent on disk)
    port::Int
    stream_port::Int
    proc::Any        # worker Base.Process
    conn::Any        # Main.Kaimon REPLConnection
    logpath::String  # worker stdout/stderr log
    lock::ReentrantLock   # serializes prepare!/respawn so concurrent callers can't double-spawn
    threads::String  # per-notebook worker thread override ("<compute>,<interactive>"); "" = use the global
    remote::Bool     # attached to a PRE-RUNNING worker (e.g. remote, forwarded to 127.0.0.1:port over
                     # an SSH tunnel) — `prepare!` CONNECTS, never spawns/reconstructs locally.
    label::String    # gate-session display label (the notebook's filename) — names the session in `ping`/TUI
    target::Any      # RunTarget: nothing ⇒ local spawn; RemoteTarget ⇒ provision + spawn on a host, connect over CURVE/tunnel
    tunnel::Any      # supervised SSH Tunnel for a :ssh_tunnel RemoteTarget (closed on teardown), else nothing
    GateKernel(project::AbstractString; parent::AbstractString = "", envdir::AbstractString = "",
               pending::Vector = Any[], threads::AbstractString = "", label::AbstractString = "",
               target = nothing) =
        new(String(project), String(parent), String(envdir), collect(Any, pending), 0, 0, nothing, nothing, "", ReentrantLock(), String(threads), false, String(label), target, nothing)
end

"""
    attach_gate_kernel(port, stream_port; project=".") -> GateKernel

A kernel bound to an ALREADY-RUNNING `SlateWorker` reachable at `127.0.0.1:port` (+ `stream_port`) —
e.g. a worker on another machine forwarded here over an SSH tunnel
(`ssh -N -L port:localhost:port -L stream:localhost:stream host`). `prepare!` CONNECTS instead of
spawning: no local process, no env reconstruction — the worker owns its process + environment. The
transport is unchanged (the hub always connects to `127.0.0.1:port`), so the tunnel is transparent.
Remote execution for a notebook is then: start the worker there, forward the two ports, hand the
notebook this kernel.
"""
function attach_gate_kernel(port::Integer, stream_port::Integer; project::AbstractString = ".")
    k = GateKernel(project)
    k.remote = true
    k.port = Int(port); k.stream_port = Int(stream_port)
    return k
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

# Pull the next batch of gate-stream messages. Prefer the event-driven blocking
# `wait_stream_messages!` (parks on the SUB FDs — near-zero idle CPU) when the Kaimon build
# provides it; otherwise fall back to the non-blocking `drain_stream_messages!` + a short sleep.
# Without this fallback, a Kaimon that only exposes `drain_stream_messages!` makes the poller
# throw every loop — silently swallowed below — so ALL worker stream events (slate_refresh /
# slate_progress / hot-reload) are dropped and reactivity + the progress meter go dead.
function _stream_messages(K, mgr)
    if isdefined(K, Symbol("wait_stream_messages!"))
        return K.wait_stream_messages!(mgr; idle_timeout = 0.25)
    end
    msgs = K.drain_stream_messages!(mgr)
    isempty(msgs) && sleep(0.05)         # avoid a busy-spin while idle
    return msgs
end

# Single background task: drain the gate stream and dispatch `slate_refresh`
# events (published by a worker's async cell) to the matching notebook.
function _ensure_poller!()
    _POLLER[] === nothing || return
    _POLLER[] = Threads.@spawn begin
        K = _kaimon()
        while true
            try
                # Coalesce a burst: a worker's async loop can PUB many `slate_refresh`
                # events at once. Union the changed vars per notebook and fire ONE recompute
                # per notebook per wake instead of one per message — otherwise a tight async
                # loop floods every SSE client with redundant re-renders.
                pending = Dict{String,Set{String}}()
                srcnames = Dict{String,Set{String}}()   # parent /src edits → changed def-names
                srcerr = Dict{String,String}()          # parent /src parse/apply errors
                prog = Dict{Tuple{String,String},Tuple{Float64,String,Bool}}()   # (notebook, bar id) → LATEST (frac,msg,done)
                # Block until a gate-stream message arrives (drain-first, then park in poll() on
                # the SUB FDs up to a 250 ms idle ceiling) instead of busy-polling at 20 Hz: an
                # idle extension now costs ~no CPU, and a streaming cell wakes us on arrival (lower
                # latency than a timer). The ceiling self-heals a park left stale if the health
                # task recreates a SUB socket. (Was: drain + sleep(0.05) → ~28% idle CPU on -t auto.)
                for m in _stream_messages(K, _manager())
                    # Route on the STABLE connect-time `conn_name`, NOT `session_name`. `_GATE_SESSION`
                    # is keyed by `k.conn.name` ("slate-<port>"), but a message's `session_name` is the
                    # human DISPLAY label (`display_name`) — once a session carries a notebook-filename
                    # label, display_name diverges from name and a `session_name` lookup silently misses,
                    # dropping every slate_refresh/progress/hot-reload event (dead reactivity).
                    rid = get(_GATE_SESSION, m.conn_name, nothing)
                    rid === nothing && continue
                    if m.channel == "slate_refresh"
                        s = get!(pending, rid, Set{String}())
                        for v in split(m.data, ","; keepempty = false)
                            push!(s, String(v))
                        end
                    elseif m.channel == "slate_revise"        # worker's hot-reload watcher: applied; here are the changed names
                        s = get!(srcnames, rid, Set{String}())
                        for v in split(m.data, ","; keepempty = false)
                            push!(s, String(v))
                        end
                    elseif m.channel == "slate_revise_err"    # a /src save didn't parse/apply
                        srcerr[rid] = String(m.data)
                    elseif m.channel == "slate_progress"      # "id|frac|done|msg" — one bar per id
                        parts = split(String(m.data), "|"; limit = 4)
                        if length(parts) == 4
                            prog[(rid, String(parts[1]))] =
                                (something(tryparse(Float64, parts[2]), 0.0), String(parts[4]), parts[3] == "1")
                        end
                    end
                end
                for (rid, vars) in pending
                    isempty(vars) || _do_refresh(rid, collect(vars))
                end
                for (rid, names) in srcnames
                    isempty(names) || _do_src_changed(rid, collect(names))
                end
                for (rid, msg) in srcerr
                    _do_src_error(rid, msg)
                end
                for ((rid, bid), (frac, msg, done)) in prog
                    _do_userprog(rid, frac, msg, bid, done)
                end
            catch e
                # Surface a persistent failure (this class of bug — a missing/renamed Kaimon
                # stream API — silently killed all worker events before). maxlog keeps it quiet.
                @warn "Kaimon Slate: gate-stream poller error — worker events (reactivity/progress/hot-reload) may be lost" exception = (e, catch_backtrace()) maxlog = 3
                sleep(0.25)   # backoff
            end
        end
    end
    return nothing
end

# Worker boot: put KaimonGate on LOAD_PATH (via the slate-owned env), load the SlateWorker
# capture payload, and serve its tools over TCP. Pinned to the notebook's project.
function _worker_script(port::Int, stream_port::Int, parent::AbstractString = "")
    # Put ONLY KaimonGate (the ZMQ bridge) on the worker's LOAD_PATH — from its own
    # minimal project (ZMQ/Serialization/…, no HTTP), NOT Kaimon's full env. Kaimon's
    # Manifest pins the custom HTTP 2.0 (Reseau); prepending it would shadow a notebook
    # project's standard HTTP v1 and break packages that need it (WGLMakie→Bonito, …).
    # `_kgate_env()` hands back an INSTANTIATED env for it (see above) — the raw
    # lib/KaimonGate dir only resolves from a dev checkout.
    kgate_dir = _kgate_env()
    # No LOAD_PATH stacking: the notebook runs in a SINGLE active env (`@`, set by
    # `--project`) — either the parent directly (base mode) or a forked env that already
    # contains the parent's deps (forked mode). `PARENT_PROJECT` is recorded only so the
    # worker can attribute package provenance (which deps are notebook adds vs parent).
    return """
    insert!(LOAD_PATH, 1, $(repr(kgate_dir)))
    insert!(LOAD_PATH, 3, $(repr(_REVISE_ENV)))   # slate-owned Revise — after the notebook project (@), before globals
    import KaimonGate
    # Load Revise BEFORE the notebook loads packages so it tracks the parent project's /src.
    # KaimonGate.serve auto-starts a watcher that PUBs `files_changed` on Revise.revision_event.
    try; @eval using Revise; catch e; @warn "slate: Revise unavailable in worker (hot-reload off)" exception=e; end
    include($(repr(_WORKER_JL)))
    SlateWorker.PARENT_PROJECT[] = $(repr(String(parent)))
    SlateWorker.start(; host = "127.0.0.1", port = $port, stream_port = $stream_port)
    """
end

function _spawn_worker!(k::GateKernel)
    port, stream_port = _next_ports()
    k.port = port; k.stream_port = stream_port
    logdir = joinpath(tempdir(), "kaimonslate"); mkpath(logdir)
    # Worker stdout/stderr can carry notebook data — keep the shared tmp dir private (0700) so
    # other local users can't read the logs; the file itself is locked to 0600 when opened below.
    Sys.isunix() && (try; chmod(logdir, 0o700); catch; end)
    k.logpath = joinpath(logdir, "worker-$port.log")
    # Thread config. OpenBLAS spawns a pool of ~ncores whose IDLE threads busy-spin (polling the
    # clock against a park timeout) — for an interactive notebook firing many tiny BLAS ops they
    # never reach the timeout and peg the cores doing no work. Cap the BLAS pool to 1 by default
    # (small ops are faster single-threaded anyway; bump KAIMONSLATE_BLAS_THREADS for big dense
    # linear algebra). Julia's own task threads (default "1,1" = 1 compute + 1 interactive) PARK
    # when idle — no spin; the interactive thread is reserved for keeping reactive handling snappy.
    blas = get(ENV, "KAIMONSLATE_BLAS_THREADS", "1")
    # Worker Julia threads ("<compute>,<interactive>"). Configurable via the Kaimon extension TUI panel
    # (NotebookServer sets WORKER_THREADS[]); env overrides; default "1,1". More compute threads enable
    # true multi-core CPU parallelism for independent cells — note Julia 1.12's strict world-age for
    # global bindings is the correctness frontier to validate when raising this above 1.
    # Default compute-thread count adapts to the machine but stays bounded: min(cores, 8) + 1 interactive.
    # (`auto` would grab ALL cores per worker → oversubscription with several open notebooks; idle Julia
    # threads park, so the cost is memory not spin, but a cap is tidier. Over-estimating cores is safe —
    # Julia just timeslices.) Order: explicit config (panel) wins, then env, then this adaptive default.
    # Precedence: this notebook's own override (k.threads, set at open) → global panel/config setting
    # (WORKER_THREADS[]) → env → the adaptive default.
    jthreads = !isempty(k.threads)         ? k.threads :
               !isempty(WORKER_THREADS[])  ? WORKER_THREADS[] :
               get(ENV, "KAIMONSLATE_JULIA_THREADS", default_worker_threads())
    cmd = `$(Base.julia_cmd()) --project=$(k.project) --startup-file=no --threads=$jthreads -e $(_worker_script(port, stream_port, k.parent))`
    cmd = addenv(cmd, "OPENBLAS_NUM_THREADS" => blas, "OMP_NUM_THREADS" => blas,
                 "KAIMON_SESSION_LABEL" => k.label)   # worker reports this as its gate-session name (notebook filename)
    # Stream the worker's stdout/stderr through a pipe into the log file, flushing
    # each chunk, so the log is tailable in real time. A plain `stdout=<file>`
    # redirect is block-buffered and only lands on disk when the worker exits —
    # useless for watching a live worker (the worker also flushes its own buffer
    # periodically; see SlateWorker.start).
    out = Pipe()
    # stdin = devnull is LOAD-BEARING: an inherited terminal stdin lets the child Julia
    # re-initialise the tty's termios, silently knocking the standalone server's raw mode
    # (its Ctrl-C-as-byte quit; see serve_notebook) back to cooked — ^C became an ignored
    # SIGINT again. Workers must never touch the operator's terminal.
    k.proc = run(pipeline(cmd; stdin = devnull, stdout = out, stderr = out); wait = false)
    close(out.in)
    Threads.@spawn begin
        io = open(k.logpath, "w")
        Sys.isunix() && (try; chmod(k.logpath, 0o600); catch; end)
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
                                    name = "slate-$(k.port)", stream_port = k.stream_port,
                                    label = k.label)
            return k
        catch e
            last = sprint(showerror, e); sleep(0.5)
        end
    end
    error("GateKernel: could not reach worker on port $(k.port): $last")
end

# Kill a worker process (SIGTERM, then SIGKILL if it ignores it — e.g. wedged in precompile),
# drop its routing entry, and clear conn/proc. Killing the process EOFs its stdout pipe, which
# ends the log-pump task (no leak). Shared by respawn (prepare!) and shutdown!.
function _kill_worker!(k::GateKernel)
    # Remote target: close the supervised tunnel, stop the /src sync, and best-effort kill the
    # remote worker so nothing is orphaned (no local proc to reap in that case).
    (k.target isa RemoteTarget || k.tunnel !== nothing) && teardown_remote!(k)
    if k.conn !== nothing
        try; delete!(_GATE_SESSION, k.conn.name); catch; end
        # Tear the client connection DOWN, not just drop the reference: `disconnect!` closes the
        # DEALER, stops its background reader task, and parks/closes the ZMQ context. Without it the
        # reader keeps `recv`-ing on the now-dead worker port — throwing every iteration (an
        # exception-driven busy-poll) — and each respawn leaks another context. That accumulation is
        # what pegged the extension at ~70% CPU across a handful of leaked reader loops.
        try; _kaimon().disconnect!(k.conn); catch; end
    end
    p = k.proc
    if p !== nothing
        try; process_running(p) && kill(p); catch; end
        for _ in 1:20                              # up to ~1s grace
            (try; !process_running(p); catch; true; end) && break
            sleep(0.05)
        end
        try; process_running(p) && kill(p, Base.SIGKILL); catch; end
    end
    k.conn = nothing; k.proc = nothing
    return nothing
end

function prepare!(k::GateKernel, report::Report)
    lock(k.lock) do                               # serialize: concurrent callers must not double-spawn
        if k.target isa RemoteTarget
            # Provision (idempotent) + spawn the worker on the host + connect over CURVE (:direct) or a
            # supervised SSH tunnel (:ssh_tunnel), keeping the parent project synced. A dropped
            # connection reconnects on the next prepare (gate on `conn === nothing`).
            if k.conn === nothing
                k.conn, k.tunnel = spawn_and_connect_remote!(k, k.target, k.parent)
                _GATE_SESSION[k.conn.name] = report.id
                _ensure_poller!()
            end
        elseif k.remote
            # Attached to a pre-running (e.g. tunneled remote) worker: connect ONCE, never spawn or
            # reconstruct locally — the worker owns its process + environment. A dropped connection
            # reconnects (we can't respawn someone else's worker), so gate on `conn === nothing`.
            if k.conn === nothing
                _connect!(k)
                _GATE_SESSION[k.conn.name] = report.id
                _ensure_poller!()
            end
        # Spawn if never started, OR respawn if the worker died (OOM / segfault / user exit()) —
        # otherwise a crashed worker would no-op here forever and every eval would error.
        elseif k.conn === nothing || (k.proc !== nothing && !process_running(k.proc))
            _kill_worker!(k)                      # tear down a dead/old proc before replacing (no leak/orphan)
            _spawn_worker!(k)
            _connect!(k)
            _GATE_SESSION[k.conn.name] = report.id   # route this worker's stream events back to the notebook
            _ensure_poller!()
            _reconstruct_env!(k)                  # env dir absent but footer has a delta → rebuild it
            _maybe_sync_parent!(k)                # forked + parent drifted → re-resolve once, up front
        end
    end
    return nothing
end

# How long a CELL eval may run before the gate request gives up. Heavy scientific cells (a long
# propagation, a parameter sweep) legitimately exceed the old 120 s request cap, which surfaced as a
# spurious timeout even though the worker kept computing. Generous + finite (so a true runaway still
# frees eventually; the worker-restart escape hatch remains), overridable via env. Interactive tool
# calls (complete / table-page / docs) keep the short default.
_eval_timeout() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_EVAL_TIMEOUT", "")), 3600.0)

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
    overflow = hasproperty(wire, :overflow) ? collect(wire.overflow) : Any[]
    animations = hasproperty(wire, :animations) ? collect(wire.animations) : Any[]
    return CellOutput(String(wire.stdout), chunks, collect(wire.echarts), collect(wire.tables),
                      binds, String(wire.value_repr), wire.exception, wire.backtrace, Float64(wire.duration_ms),
                      collect(wire.trace), String(wire.stderr), overflow, animations,
                      hasproperty(wire, :memo) ? String(wire.memo) : "")
end

function eval_capture(k::GateKernel, report::Report, source::AbstractString, filename::AbstractString = "string")
    wire = try
        # prepare! is INSIDE the try: a worker spawn/connect or env-reconstruction failure must
        # surface as this cell's error, NOT propagate up through eval_stale!/sync_from_file! and 500
        # the whole `state` request (which bricks the notebook in the browser).
        prepare!(k, report)
        # `filename` is a kwarg on the worker tool — GateTool strips optional POSITIONAL args, so it
        # must ride as a keyword (Dict key → kwarg) to survive the hop. See worker.jl `__slate_eval`.
        _tool(k, "__slate_eval", Dict("source" => String(source), "filename" => String(filename)); timeout = _eval_timeout())
    catch e
        return CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", sprint(showerror, e), nothing, 0.0)
    end
    return _wire_to_output(wire)
end

# Memo-aware: ask the worker to restore an expensive cell from disk (no recompute) or persist it
# after a run exceeding `memo.threshold` ms. The key digests this cell + its upstream sources +
# bind inputs; the worker folds in the Revise'd src + Manifest digests (see worker.jl `__slate_eval`).
function eval_capture(k::GateKernel, report::Report, source::AbstractString, filename::AbstractString, memo)
    (memo === nothing || isempty(memo.key)) && return eval_capture(k, report, source, filename)
    wire = try
        prepare!(k, report)
        _tool(k, "__slate_eval", Dict{String,Any}(
            "source" => String(source), "filename" => String(filename),
            "memo_key" => String(memo.key), "memo_names" => collect(String, memo.names),
            "memo_threshold" => Float64(memo.threshold),
            # ▶ force: skip the restore (an explicit play must re-evaluate) but still store the fresh
            # result. `always`: the `cache` tag — persist regardless of runtime. Both hasproperty-guarded
            # so older 3-field memo tuples (agent scratch evals) still work.
            "memo_force" => (hasproperty(memo, :force) && memo.force === true),
            "memo_always" => (hasproperty(memo, :always) && memo.always === true)); timeout = _eval_timeout())
    catch e
        return CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", sprint(showerror, e), nothing, 0.0)
    end
    return _wire_to_output(wire)
end

# Run a batch of stale cells in PARALLEL in the worker (inter-cell, in-process). `batch` is a vector of
# per-cell Dicts (id, source, filename, deps, reads, writes, opaque, memo_*) built by the server. The
# worker schedules them (par_blockers) and STREAMS each result on the `slate_celldone` channel as it
# finishes — the poller routes those to `server_celldone` for a version-guarded live merge. This call
# blocks on the ACK (the worker returns once the whole batch has drained), so by the time it returns,
# every result has been published; the merge itself happens asynchronously in the poller. Returns the
# worker's ack `(; run_id, ids)` (or rethrows — the caller restales any cell left RUNNING).
function eval_batch(k::GateKernel, report::Report, run_id::AbstractString, batch::Vector)
    prepare!(k, report)
    # NOTE: `cells` is a nested Vector{Dict}. This depends on the gate delivering structured tool-call
    # arguments intact — currently it does NOT (they arrive empty; see GATE_STRUCTURED_ARGS_ISSUE.md).
    # Until the fabric fix lands the worker gets an empty batch and the caller falls back to serial.
    # The RESULT rides back binary in the REQ/REP value field (return values aren't schema-filtered).
    return _tool(k, "__slate_eval_batch",
                 Dict{String,Any}("cells" => batch, "run_id" => String(run_id), "npool" => 0);
                 timeout = _eval_timeout())
end

# Interrupt the worker's currently-running batch cells (the stop button). Deliberately does NOT
# `prepare!` — if the worker is gone there's nothing to cancel, and we must not respawn one here. Runs
# as its own gate request, which the worker handles on a separate task (the message loop spawns every
# request), so it lands WHILE the blocking `eval_batch` is still in flight. Returns the count of cells
# interrupted, or -1 if there's no live worker to talk to.
function cancel_eval(k::GateKernel)
    k.conn === nothing && return -1
    return try
        Int(_tool(k, "__slate_cancel", Dict{String,Any}(); timeout = 30.0))
    catch e
        @warn "slate cancel: worker did not acknowledge" exception = e
        -1
    end
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

# Completion runs in the worker (where `using`'d packages + evaluated bindings live).
# Best-effort and never blocks the UI: if the worker isn't up yet, or the call errors or
# times out, return nothing — the server still offers cell-local completions. No `prepare!`
# here on purpose: a keystroke must never trigger a cold (~90s) worker spawn.
function complete(k::GateKernel, report::Report, code::AbstractString, pos::Integer)
    empty = (items = Tuple{String,String}[], from = Int(pos), to = Int(pos))
    k.conn === nothing && return empty
    wire = try
        _tool(k, "__slate_complete", Dict("code" => String(code), "pos" => Int(pos)); timeout = 10.0)
    catch
        return empty
    end
    wire === nothing && return empty
    return (items = Tuple{String,String}[(String(t), String(kd)) for (t, kd) in wire.items],
            from = Int(wire.from), to = Int(wire.to))
end

"Apply pending parent-/src revisions in the worker (Revise) → the changed top-level def-names."
function revise_apply!(k::GateKernel)
    k.conn === nothing && return String[]
    wire = try
        _tool(k, "__slate_revise", Dict{String,Any}(); timeout = 60.0)
    catch
        return String[]
    end
    return wire === nothing ? String[] : String[String(x) for x in wire]
end

function module_help(k::GateKernel, report::Report, name::AbstractString)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_module_help", Dict("name" => String(name)))
    catch
        return Dict{String,Any}()
    end
    wire === nothing && return Dict{String,Any}()
    return Dict{String,Any}(String(k2) => v for (k2, v) in wire)
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

# Filesystem coordinates for a self-contained export (active project dir + path-dep sources).
function bundle_info(k::GateKernel, report::Report)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_bundle_info", Dict{String,Any}())
    catch
        return (projectdir = "", pathdeps = NamedTuple[])
    end
    wire === nothing && return (projectdir = "", pathdeps = NamedTuple[])
    pd = [(name = String(get(p, :name, get(p, "name", ""))), source = String(get(p, :source, get(p, "source", ""))))
          for p in get(wire, :pathdeps, get(wire, "pathdeps", Any[]))]
    return (projectdir = String(get(wire, :projectdir, get(wire, "projectdir", ""))), pathdeps = pd)
end

# Add/remove a package in the notebook's own env. Adding the FIRST package while in base
# mode forks the notebook off its parent (seed + activate a single extended env) before the
# add, so the parent's `Project.toml` is never touched and there's one consistent resolution.
function pkg_op(k::GateKernel, report::Report, op::AbstractString, name::AbstractString;
               target::AbstractString = "notebook")
    prepare!(k, report)
    # "project" target: add to the SHARED parent project (no fork), then re-resolve the notebook env.
    if String(target) == "project"
        isempty(k.parent) && return Dict{String,Any}("ok" => false, "message" => "this notebook has no parent project")
        r = try
            _tool(k, "__slate_pkg_parent", Dict{String,Any}("op" => String(op), "name" => String(name), "parent" => k.parent); timeout = 900.0)
        catch e
            return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
        end
        r === nothing && return Dict{String,Any}("ok" => false, "message" => "no response from worker")
        return Dict{String,Any}(String(kk) => v for (kk, v) in r)
    end
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
        # Generous timeout — Pkg.add of a heavy package (a full Makie stack, etc.) resolves + precompiles
        # well past the 120s default, especially on a fresh remote env.
        r = _tool(k, "__slate_pkg", Dict{String,Any}("op" => String(op), "name" => String(name)); timeout = 900.0)
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

# Rebuild a notebook env from its `.jl` footer when the env dir is absent (e.g. a fresh
# git clone of a notebook that records package adds) — seed from the parent and add the
# footer's pinned packages. Runs once, before the first eval.
function _reconstruct_env!(k::GateKernel)
    isempty(k.pending) && return
    try
        _tool(k, "__slate_reconstruct",
              Dict{String,Any}("envdir" => k.envdir, "parent" => k.parent, "pkgs" => k.pending);
              timeout = 900.0)
        _write_parent_marker!(k)
    catch
    end
    empty!(k.pending)
    return
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

"Kill the worker (local) or just drop the connection (remote), and clear gate state."
function shutdown!(k::GateKernel)
    K = _kaimon()
    lock(k.lock) do
        # A remote/attached worker isn't ours to kill — skip `send_shutdown!` (which tells the worker
        # to EXIT) and just drop our connection so it stays alive for the next attach; the tunnel owner
        # manages its lifecycle. A LOCAL worker gets the clean exit request + SIGTERM/SIGKILL backstop.
        (k.remote || k.conn === nothing) || (try; K.send_shutdown!(k.conn); catch; end)
        _kill_worker!(k)     # proc === nothing for remote → no process kill; just clears conn + routing
    end
    return nothing
end
