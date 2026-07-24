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
# Extra Julia flags appended to every spawned worker's command line (e.g. "--gcthreads=4,1
# --heap-size-hint=4G") — anything `julia` accepts that isn't already covered by a dedicated
# setting (--project/--threads are derived elsewhere and can't be overridden this way). Same
# tiering as WORKER_THREADS: per-notebook override → this global (panel/slate.json) → env → none.
const WORKER_EXTRA_FLAGS = Ref{String}("")
# Durable memo-store cap in GB (panel/slate.json → here → worker env at spawn). 0 = unset:
# the worker falls back to KAIMONSLATE_MEMO_CAP_GB from ITS env, else an adaptive default
# (a quarter of free disk, clamped 2–20 GB — see worker.jl `_memo_cap`).
const MEMO_CAP_GB = Ref{Float64}(0.0)

# The machine-adaptive default thread spec: min(cores, 8) compute + 2 interactive (idle threads park;
# the cap avoids oversubscription across several open notebooks). Two interactive threads keep the gate
# loop (heartbeats/cancels) + reactive handling responsive even while a data transfer (blob push/pull,
# the worker→worker mesh) or a compute batch is in flight — with one, a heavy transfer could starve the
# heartbeat and time out the hub's watchdog. Used both at spawn and to report the effective count.
default_worker_threads() = string(min(Sys.CPU_THREADS, 8), ",2")

# The thread spec a worker would actually spawn with, given a per-kernel override `kthreads`:
# per-kernel override → global setting → adaptive default.
function effective_worker_threads(kthreads::AbstractString)
    !isempty(kthreads)        && return String(kthreads)
    !isempty(WORKER_THREADS[]) && return WORKER_THREADS[]
    return get(ENV, "KAIMONSLATE_JULIA_THREADS", default_worker_threads())
end

# The extra-flags string a worker would actually spawn with, given a per-kernel override
# `kflags`: per-kernel override → global setting → env → "" (none). Mirrors `effective_worker_threads`.
function effective_worker_extra_flags(kflags::AbstractString)
    !isempty(kflags)              && return String(kflags)
    !isempty(WORKER_EXTRA_FLAGS[]) && return WORKER_EXTRA_FLAGS[]
    return get(ENV, "KAIMONSLATE_JULIA_EXTRA_FLAGS", "")
end

# Self-identifying process tag for `ps` — "slate:<region>@<notebook>:<port>". Either part may be absent:
# a WARM-POOL worker has a region but no notebook yet (label is empty), a notebook's own worker has no
# region. The kernel label encodes "<notebook>[#region]" — split the notebook off it. Sanitised to a
# single shell-safe token (used as a KAIMONSLATE_WORKER env var and a trailing cmdline arg).
function _worker_tag(label::AbstractString, region::AbstractString, port::Integer)
    nb = first(split(String(label), '#'))
    ident = join(filter(!isempty, String[String(region), String(nb)]), "@")
    isempty(ident) && (ident = "worker")
    return "slate:" * replace(ident, r"[^\w.@=+-]" => "_") * ":" * string(port)
end

const _WORKER_JL = joinpath(@__DIR__, "worker.jl")
# Slate-owned WORKER INFRA env — Revise (hot-reload the parent project's /src), ExpressionExplorer
# (macro-aware dep recovery, pinned to the engine's version — see macroexpand.jl), and
# SlateExtensionsBase (the extension SDK: Widget/Choice/WebPage/slate_context). Carried in ONE env
# (was three single-package dirs) so the worker gets them without the user's project declaring them.
# Stacked AFTER the notebook project on LOAD_PATH so the notebook's own copies always win.
const _INFRA_ENV = joinpath(@__DIR__, "worker_infra")

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

# ── Worker INFRA env materialisation ─────────────────────────────────────────────
# Same rationale as `_kgate_env()`. `worker_infra` is consumed by the worker on its LOAD_PATH, so it
# must be RESOLVED for the local machine + Julia. Shipping a committed `Manifest.toml` there is a
# lockfile stamped for ONE Julia version + depot state — it breaks the instant someone is on a
# different Julia patch ("SlateExtensionsBase … is required but does not seem to be installed"). So the
# Manifest is NOT committed; instead materialise the env ONCE per (Project.toml + SEB Project.toml +
# Julia version) by instantiating a copy in a subprocess into a scratchspace, and put THAT on LOAD_PATH.
# `worker_infra/Project.toml` (deps + [compat] + the SEB [sources] path) is the source of truth; the
# SEB path-dev tracks source edits live, so only a deps/Julia change rebuilds.
const _INFRA_ENV_ROOT = joinpath(get(DEPOT_PATH, 1, joinpath(homedir(), ".julia")),
                                 "scratchspaces", "kaimonslate-infra")
const _INFRA_ENV_LOCK = ReentrantLock()

function _infra_env()::String
    proj = joinpath(_INFRA_ENV, "Project.toml")
    isfile(proj) || return _INFRA_ENV
    ptoml = read(proj, String)
    # The committed `[sources]` path is RELATIVE to src/worker_infra; rewrite it to ABSOLUTE so it still
    # resolves once the Project.toml is copied into the scratchspace.
    seb = normpath(joinpath(_INFRA_ENV, "..", "..", "lib", "SlateExtensionsBase"))
    sebproj = joinpath(seb, "Project.toml")
    # Key by BOTH Project.tomls (a new dep/compat here or in SEB) + the SEB path + Julia — a source edit
    # inside SEB needs no rebuild (path-dev tracks it live), mirroring `_kgate_env()`.
    key = string(hash((ptoml, isfile(sebproj) ? read(sebproj, String) : "", seb, string(VERSION))); base = 16)
    dir = joinpath(_INFRA_ENV_ROOT, key)
    lock(_INFRA_ENV_LOCK) do
        isfile(joinpath(dir, ".ready")) && return dir
        @info "slate: preparing the worker's infra environment (Revise + ExpressionExplorer + SlateExtensionsBase; once per Julia version)…" dir
        buildlog = joinpath(dir, "build.log")
        try
            mkpath(dir)
            write(joinpath(dir, "Project.toml"), replace(ptoml, "../../lib/SlateExtensionsBase" => seb))
            code = "using Pkg; Pkg.instantiate()"   # no Manifest ⇒ resolve for THIS Julia, then install
            open(buildlog, "w") do io
                run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$dir -e $code`;
                             stdout = io, stderr = io))
            end
            write(joinpath(dir, ".ready"), seb)
            return dir
        catch e
            @warn "slate: could not materialise the infra worker env — falling back to the raw dir (works only if it carries a resolvable Manifest, e.g. a dev checkout that instantiated it in place)" _INFRA_ENV buildlog exception = e
            return _INFRA_ENV
        end
    end
end

# Per-worker TCP ports. A simple counter (no Sockets dep); collisions are unlikely
# and surface as a worker bind error rather than silent crosstalk.
const _GATE_PORT = Ref(9100)
const _PORT_LOCK = ReentrantLock()
# A worker owns its GATE port `p` (main REP) and STREAM port `p+1` (PUB) — both HUB-DIALED, so the hub
# reserves them here. `reserve` is how many consecutive ports to burn. The DEFAULT is 2: a worker whose
# blob channel needs no reserved slot — a LOCAL worker (runs no blob server; `data_port` unset) or a
# `:tunnel` worker (its blob binds a worker-chosen VERIFIED-FREE port, discovered by the hub via
# `__slate_ports`, never `p+2`). A `:direct` worker DOES pin its blob at `p+2` (firewall-opened +
# peer-dialed), so those callers pass `reserve=3` — else the next worker's gate would land on this one's
# blob port (a 2-stride: ZMQ bind fails and the worker dies at boot; seen live). `floor` lets a caller who
# KNOWS ports are taken (the remote roster — warm workers survive an extension restart, which resets this
# counter) push the counter past them first.
function _next_ports(; floor::Int = 0, reserve::Int = 2)
    lock(_PORT_LOCK) do            # atomic bump — concurrent spawns must not grab the same port
        _GATE_PORT[] = max(_GATE_PORT[], floor)
        p = _GATE_PORT[]; _GATE_PORT[] += reserve
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
    extra_flags::String  # per-notebook extra Julia flags (e.g. "--gcthreads=4,1"); "" = use the global
    remote::Bool     # attached to a PRE-RUNNING worker (e.g. remote, forwarded to 127.0.0.1:port over
                     # an SSH tunnel) — `prepare!` CONNECTS, never spawns/reconstructs locally.
    label::String    # gate-session display label (the notebook's filename) — names the session in `ping`/TUI
    target::Any      # RunTarget: nothing ⇒ local spawn; RemoteTarget ⇒ provision + spawn on a host, connect over CURVE/tunnel
    tunnel::Any      # supervised SSH Tunnel for a :ssh_tunnel RemoteTarget (closed on teardown), else nothing
    ns_gen::Int      # namespace generation — bumped whenever a FRESH (empty) namespace is bound: a cold
                     # spawn, a pool ADOPTION (`__slate_adopt` swaps in a new namespace), a reprovision.
                     # NOT bumped on a reattach (park/record/probe reuse the SAME live process + namespace).
                     # The region dedups (prime / resource / datadir / synced) fold this into their key, so
                     # a swapped worker's blank namespace is correctly re-established instead of skipped.
    redial_hold::Bool # set when the liveness supervisor DROPS this wire as dead under the MANUAL retry
                     # policy: `prepare!` then refuses to re-dial/cold-spawn until an EXPLICIT run clears
                     # it (a reactive cascade errors instead), so a flaky region isn't silently replaced
                     # behind the user's back. Always false under the `auto` policy (eager re-dial).
    online::Any      # optional `line::String -> nothing` callback: a COLD LOCAL spawn's stdout/stderr,
                     # streamed line-by-line (mirrors the remote path's `_bringup_note`/`_run_streamed`) —
                     # so a slow first-run precompile narrates itself into the UI instead of looking hung.
                     # `nothing` (the default) skips the callback entirely; the log file write is unaffected.
    GateKernel(project::AbstractString; parent::AbstractString = "", envdir::AbstractString = "",
               pending::Vector = Any[], threads::AbstractString = "", extra_flags::AbstractString = "",
               label::AbstractString = "", target = nothing, online = nothing) =
        new(String(project), String(parent), String(envdir), collect(Any, pending), 0, 0, nothing, nothing, "", ReentrantLock(), String(threads), String(extra_flags), false, String(label), target, nothing, 0, false, online)
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
const _GATE_SESSION_LOCK = ReentrantLock()   # `_GATE_SESSION` is read by the poller task while prepare!/kill
                                             # mutate it from other threads — a Dict is not thread-safe, so an
                                             # unlocked concurrent access tears (UndefRefError) and kills the
                                             # poller cycle (dropping reactivity/stream events). Guard all access.
const _POLLER = Ref{Any}(nothing)

# conn name → rolling history of that worker's telemetry samples (newest last). Keyed PER-KERNEL
# by the stable connect-time `conn.name` — a notebook's main + region kernels each get their own
# series (they'd collide under a shared report id). Bounded ring: the watchdog needs a short window
# to read TRENDS (rss climbing, cpu sustained), not just the latest point. Idle/detached workers
# still surface theirs via `list_remote_workers` (the `.stats` sidecar).
const _KERNEL_STATS = Dict{String,Vector{Any}}()
# Ring cap per kernel — how many telemetry samples the hub keeps. Default ~1h at the worker's 2s cadence
# (each sample is a small NamedTuple, so an hour × a handful of kernels is a few MB). Tunable; the watchdog
# reads only bounded TAILS of this (see `_watchdog_scan!`), so a long ring doesn't change its trend windows.
_kernel_stats_max() = max(30, something(tryparse(Int, get(ENV, "KAIMONSLATE_TELEMETRY_HISTORY", "")), 1800))
const _STATS_LOCK = ReentrantLock()

# Server-injected push hooks (same inversion as `_BRINGUP_SINK` / `register_emit!`): after a telemetry
# sample is recorded — and for each worker log line — fire these so the hub can PUSH the value over the
# per-page WebSocket instead of the browser polling. ReportEngine stays HTTP-agnostic; the server injects
# the impls and re-registers them in `_hub()` for Revise reload-safety. Both fire on the poller task.
const _TELEMETRY_SINK = Ref{Any}(nothing)   # (conn_name::String, sample::NamedTuple) -> nothing
const _LOG_SINK = Ref{Any}(nothing)         # (conn_name::String, line::String)       -> nothing

# Parse one `slate_telemetry` line into a flat NamedTuple + hub arrival time; nothing on garbage.
function _parse_telemetry(raw::AbstractString)
    try
        d = JSON.parse(String(raw))
        (cpu     = Float64(get(d, "cpu", -1.0)),
         rss     = Int(get(d, "rss", 0)),
         gc_ms   = Int(get(d, "gc_ms", 0)),
         evals   = Int(get(d, "evals", 0)),
         running = String[String(x) for x in get(d, "running", Any[])],
         warm    = String(get(d, "warm", "")),
         memo    = Int(get(d, "memo_bytes", -1)),
         # System-wide (the whole host) — carried through so the worker/region popup can show them.
         sys_cpu = Float64(get(d, "sys_cpu", -1.0)),
         load1   = Float64(get(d, "load1", -1.0)),
         sys_mem_total = Int(get(d, "sys_mem_total", 0)),
         sys_mem_free  = Int(get(d, "sys_mem_free", 0)),
         ts      = Float64(get(d, "ts", 0.0)),
         rcv     = time())
    catch
        nothing
    end
end

function _record_telemetry!(conn_name::AbstractString, raw::AbstractString)
    s = _parse_telemetry(raw); s === nothing && return nothing
    lock(_STATS_LOCK) do
        h = get!(_KERNEL_STATS, String(conn_name), Any[])
        push!(h, s)
        mx = _kernel_stats_max()
        length(h) > mx && deleteat!(h, 1:(length(h) - mx))
    end
    # Push this fresh sample to any open page of the owning notebook (main/region pill + popup) — so an
    # IDLE worker's number updates live rather than lagging until the next notebook state version-bump.
    f = _TELEMETRY_SINK[]
    f === nothing || (try; f(String(conn_name), s); catch; end)
    return nothing
end

# Worker log record (`slate_log`) → server push hook. No hub-side history is kept: the `worker-<port>.log`
# file already holds the scrollback (`worker_log_tail`); this is only the live tail for an open popup.
function _relay_log!(conn_name::AbstractString, line::AbstractString)
    f = _LOG_SINK[]
    f === nothing || (try; f(String(conn_name), String(line)); catch; end)
    return nothing
end

# Latest sample + a copy of the recent history for one kernel connection (nothing if never seen).
function kernel_stats(conn_name::AbstractString)
    lock(_STATS_LOCK) do
        h = get(_KERNEL_STATS, String(conn_name), nothing)
        (h === nothing || isempty(h)) && return nothing
        return (latest = h[end], history = copy(h))
    end
end

# Forget a kernel's series when its connection is torn down (reap / respawn), so stale telemetry
# can't linger and mislead the watchdog into a phantom "unreachable".
forget_kernel_stats(conn_name::AbstractString) = lock(_STATS_LOCK) do
    delete!(_KERNEL_STATS, String(conn_name)); nothing
end

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
                emits = Tuple{String,String,Any}[]   # ordered slate_emit pushes (rid, channel, deserialized VALUE) — NOT coalesced; each event matters
                binemits = Tuple{String,Vector{UInt8}}[]   # ordered slate_emit_bin frames (rid, raw binary frame) — forwarded to the page WS as-is
                prepares = Dict{String,String}()     # notebook → LATEST env-prep status JSON (coalesced per wake; a burst collapses harmlessly)
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
                    rid = lock(_GATE_SESSION_LOCK) do; get(_GATE_SESSION, m.conn_name, nothing); end
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
                    elseif m.channel == "slate_emit"          # "channel\x1fb64" — base64(Serialization-serialized VALUE)
                        parts = split(String(m.data), '\x1f'; limit = 2)
                        if length(parts) == 2
                            val = try; Serialization.deserialize(IOBuffer(Base64.base64decode(String(parts[2])))); catch; nothing; end
                            push!(emits, (rid, String(parts[1]), val))
                        end
                    elseif m.channel == "slate_emit_bin"      # a raw binary numeric frame (bytes carry channel+meta+dtype+shape+payload)
                        m.data isa Vector{UInt8} && push!(binemits, (rid, m.data))
                    elseif m.channel == "slate_telemetry"     # worker's 2s sample — per-kernel ring + WS push
                        _record_telemetry!(m.conn_name, String(m.data))
                    elseif m.channel == "slate_log"           # worker log record → live tail push (no store)
                        _relay_log!(m.conn_name, String(m.data))
                    elseif m.channel == "slate_prepare"       # env precompile progress → "Preparing packages" banner
                        prepares[rid] = String(m.data)
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
                for (rid, json) in prepares
                    _do_prepare(rid, json)
                end
                for (rid, ch, d) in emits
                    _do_emit(rid, ch, d)
                end
                for (rid, frame) in binemits
                    _do_emit_bin(rid, frame)
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
    infra_dir = _infra_env()   # materialised (instantiated for THIS Julia) — see `_infra_env`
    # No LOAD_PATH stacking: the notebook runs in a SINGLE active env (`@`, set by
    # `--project`) — either the parent directly (base mode) or a forked env that already
    # contains the parent's deps (forked mode). `PARENT_PROJECT` is recorded only so the
    # worker can attribute package provenance (which deps are notebook adds vs parent).
    return """
    insert!(LOAD_PATH, 1, $(repr(kgate_dir)))
    insert!(LOAD_PATH, 3, $(repr(infra_dir)))   # slate-owned infra (Revise + ExpressionExplorer + SlateExtensionsBase) — after the notebook project (@), before globals
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
    k.ns_gen += 1   # a fresh LOCAL process ⇒ blank namespace (mirrors spawn_and_connect_remote!): the
                    # ns_gen-keyed re-establish re-primes it — main-kernel @bind registrations here, and
                    # region prime/resource/sync in the region layer. Without this a mid-session respawn
                    # (worker crash → prepare! replaces it) left a fresh namespace looking unchanged.
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
    # linear algebra). Julia's task threads PARK when idle — no spin; the interactive threads are
    # reserved for keeping the gate loop (heartbeats/cancels) + reactive handling snappy under load.
    blas = get(ENV, "KAIMONSLATE_BLAS_THREADS", "1")
    # Worker Julia threads ("<compute>,<interactive>"). Configurable via the Kaimon extension TUI panel
    # (NotebookServer sets WORKER_THREADS[]); env overrides; adaptive default below. More compute threads enable
    # true multi-core CPU parallelism for independent cells — note Julia 1.12's strict world-age for
    # global bindings is the correctness frontier to validate when raising this above 1.
    # Default compute-thread count adapts to the machine but stays bounded: min(cores, 8) compute + 2 interactive.
    # (`auto` would grab ALL cores per worker → oversubscription with several open notebooks; idle Julia
    # threads park, so the cost is memory not spin, but a cap is tidier. Over-estimating cores is safe —
    # Julia just timeslices.) Order: explicit config (panel) wins, then env, then this adaptive default.
    # Precedence: this notebook's own override (k.threads, set at open) → global panel/config setting
    # (WORKER_THREADS[]) → env → the adaptive default.
    jthreads = effective_worker_threads(k.threads)
    # Extra Julia flags (e.g. "--gcthreads=4,1 --heap-size-hint=4G") — same tiering as threads above,
    # via `effective_worker_extra_flags`. Shell-split so multiple flags/values become separate argv
    # entries (a raw string interpolated into a backtick would land as ONE mangled argument). Must
    # precede `-e` — Julia stops parsing its own flags there.
    extra_args = Base.shell_split(effective_worker_extra_flags(k.extra_flags))
    cmd = `$(Base.julia_cmd()) --project=$(k.project) --startup-file=no --threads=$jthreads $extra_args -e $(_worker_script(port, stream_port, k.parent))`
    cmd = addenv(cmd, "OPENBLAS_NUM_THREADS" => blas, "OMP_NUM_THREADS" => blas,
                 "KAIMON_SESSION_LABEL" => k.label,   # worker reports this as its gate-session name (notebook filename)
                 # Self-identifying process tag (see the remote path) — in `ps e` / /proc/<pid>/environ.
                 "KAIMONSLATE_WORKER" => _worker_tag(k.label, "", port))
    # Memo-store cap: forward the panel/config setting into the worker (its env/adaptive default
    # applies when unset — passing nothing keeps the worker's own resolution intact).
    MEMO_CAP_GB[] > 0 && (cmd = addenv(cmd, "KAIMONSLATE_MEMO_CAP_GB" => string(MEMO_CAP_GB[])))
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
    online = k.online   # captured once — a respawn gets a fresh GateKernel, so this can't go stale mid-pump
    Threads.@spawn begin
        io = open(k.logpath, "w")
        Sys.isunix() && (try; chmod(k.logpath, 0o600); catch; end)
        try
            # Line-by-line (not chunked `readavailable`) so a slow first-run precompile can narrate
            # itself live via `online`, mirroring the remote path's `_run_streamed`. Net effect on the
            # log file is the same content, just written one newline-terminated line at a time.
            for line in eachline(out)
                println(io, line); flush(io)
                if online !== nothing
                    s = strip(line)
                    isempty(s) || (try; online(String(s)); catch; end)
                end
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
    deadline = time() + _connect_deadline_local()   # worker Julia startup + KaimonGate load is slow
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
function _kill_worker!(k::GateKernel; kill_remote::Bool = false)
    # Detaching from a spawned-remote worker PARKS the wire: the live conn + tunnel move into the
    # park cache (see `park_remote!`) so reopening this notebook skips tunnel + dial entirely.
    # The park owns them from here — teardown must not close the tunnel, and the disconnect
    # below must not fire. Everything else (sync stop, state=idle) still runs via teardown.
    parked = !kill_remote && k.target isa RemoteTarget && park_remote!(k)
    parked && (k.tunnel = nothing)
    # Remote target: close the supervised tunnel and stop the /src sync; the worker itself is
    # detached (kept warm for reattach) unless `kill_remote` — see `teardown_remote!`.
    (k.target isa RemoteTarget || k.tunnel !== nothing) && teardown_remote!(k; kill = kill_remote)
    if k.conn !== nothing
        try; lock(_GATE_SESSION_LOCK) do; delete!(_GATE_SESSION, k.conn.name); end; catch; end
        # Tear the client connection DOWN, not just drop the reference: `disconnect!` closes the
        # DEALER, stops its background reader task, and parks/closes the ZMQ context. Without it the
        # reader keeps `recv`-ing on the now-dead worker port — throwing every iteration (an
        # exception-driven busy-poll) — and each respawn leaks another context. That accumulation is
        # what pegged the extension at ~70% CPU across a handful of leaked reader loops.
        parked || (try; _kaimon().disconnect!(k.conn); catch; end)
    end
    p = k.proc
    if p !== nothing
        try; process_running(p) && kill(p); catch; end   # SIGTERM — ask nicely first
        # DON'T block waiting for it to actually die: this runs inside `close_notebook!`'s
        # `lock(h.lock)`, and a worker wedged in precompile/codegen can take real time to exit
        # even after SIGTERM. A blocking wait here serializes EVERY other hub operation (any
        # open/close on ANY notebook needs the same lock) behind however long this one process
        # takes to die. Register it for the background reaper instead (see `reap_pending_kills!`,
        # ridden on the hub's existing 5s supervisor sweep) — it escalates to SIGKILL and logs,
        # without holding anything up. `_kill_worker!` itself returns essentially instantly.
        register_pending_kill!(p)
    end
    k.conn = nothing; k.proc = nothing
    return nothing
end

# ── Background process reaper ─────────────────────────────────────────────────────────────────
# A worker asked to exit (SIGTERM, above) is tracked here until it's CONFIRMED dead — escalating
# to SIGKILL if it outlives its grace period, and logging either way — instead of a caller
# blocking on it (see `_kill_worker!`). `reap_pending_kills!()` is called once per hub-wide 5s
# sweep tick (server.jl `_supervise_runs!`), not per-notebook.
const _PENDING_KILLS = Dict{Int,NamedTuple}()   # pid → (proc, term_at, kill_at::Union{Float64,Nothing})
const _PENDING_KILLS_LOCK = ReentrantLock()
const _KILL_GRACE_S = 3.0            # how long a SIGTERM'd process gets before SIGKILL
const _KILL_GIVEUP_S = 15.0          # how long AFTER SIGKILL before we stop watching + warn once

function register_pending_kill!(p)
    pid = try; getpid(p); catch; return nothing; end
    lock(_PENDING_KILLS_LOCK) do
        _PENDING_KILLS[pid] = (proc = p, term_at = time(), kill_at = nothing)
    end
    return nothing
end

function reap_pending_kills!()
    snap = lock(_PENDING_KILLS_LOCK) do; collect(_PENDING_KILLS); end
    isempty(snap) && return nothing
    now = time()
    for (pid, rec) in snap
        alive = try; process_running(rec.proc); catch; false; end
        if !alive
            lock(_PENDING_KILLS_LOCK) do; delete!(_PENDING_KILLS, pid); end
            continue
        end
        if rec.kill_at === nothing
            (now - rec.term_at < _KILL_GRACE_S) && continue    # still within SIGTERM grace
            try; kill(rec.proc, Base.SIGKILL); catch; end
            _rlog("worker reaper: pid $pid still alive $(round(now - rec.term_at; digits=1))s after SIGTERM — sent SIGKILL")
            lock(_PENDING_KILLS_LOCK) do
                haskey(_PENDING_KILLS, pid) && (_PENDING_KILLS[pid] = (proc = rec.proc, term_at = rec.term_at, kill_at = now))
            end
        elseif now - rec.kill_at > _KILL_GIVEUP_S
            @warn "slate: worker process would not die even after SIGKILL — giving up on it" pid = pid
            lock(_PENDING_KILLS_LOCK) do; delete!(_PENDING_KILLS, pid); end
        end
    end
    return nothing
end

# Drop a kernel's LIVE gate connection without killing the worker — the dead-wire self-heal. Unlike
# `_kill_worker!` this never parks the wire (a silent wire must not be cached for reuse) and never
# touches the remote process (it may be alive-but-unreachable, or already gone). It just tears the
# local side down: `disconnect!` closes the DEALER and — crucially — fails every pending caller fast
# (`_close_request_channel!` closes their inboxes), so an eval BLOCKED on this wire wakes immediately
# and errors instead of hanging out the full eval timeout. Closing the tunnel forces a fresh transport,
# and nulling `conn` makes the next `prepare!` re-dial (reconnect/re-adopt). Idempotent; returns whether
# a live connection was actually dropped. Called by the hub's liveness supervisor and by an explicit reap.
function _drop_kernel_conn!(k::GateKernel)
    lock(k.lock) do
        c = k.conn
        c === nothing && return false
        try; lock(_GATE_SESSION_LOCK) do; delete!(_GATE_SESSION, c.name); end; catch; end
        try; _kaimon().disconnect!(c); catch; end   # wakes any eval blocked on this wire
        if k.tunnel !== nothing
            try; close_tunnel(k.tunnel); catch; end
            k.tunnel = nothing
        end
        k.conn = nothing
        return true
    end
end

function prepare!(k::GateKernel, report::Report)
    lock(k.lock) do                               # serialize: concurrent callers must not double-spawn
        # MANUAL retry policy: the liveness supervisor dropped this remote wire as dead and flagged it to
        # await an explicit run. A reactive cascade must NOT silently re-dial/cold-spawn a replacement
        # (a flaky worker shouldn't be resurrected behind the user's back) — error clearly instead. An
        # explicit run clears the flag first (see `_eval_one!`), so this only bites the automatic path.
        if k.redial_hold && k.conn === nothing && (k.target isa RemoteTarget || k.remote)
            error("region worker is disconnected (a previous worker went unresponsive) — re-run to reconnect")
        end
        if k.target isa RemoteTarget
            # Provision (idempotent) + spawn the worker on the host + connect over CURVE (:direct) or a
            # supervised SSH tunnel (:ssh_tunnel), keeping the parent project synced. A dropped
            # connection reconnects on the next prepare (gate on `conn === nothing`).
            if k.conn === nothing
                k.conn, k.tunnel = spawn_and_connect_remote!(k, k.target, k.parent)
                lock(_GATE_SESSION_LOCK) do; _GATE_SESSION[k.conn.name] = report.id; end
                _ensure_poller!()
                # Carry the local memo store over NOW — the eval that triggered this prepare
                # dispatches next, and a push after it races the recompute (same-key clobber).
                _sync_memo_boot!(k, report)
            end
        elseif k.remote
            # Attached to a pre-running (e.g. tunneled remote) worker: connect ONCE, never spawn or
            # reconstruct locally — the worker owns its process + environment. A dropped connection
            # reconnects (we can't respawn someone else's worker), so gate on `conn === nothing`.
            if k.conn === nothing
                _connect!(k)
                lock(_GATE_SESSION_LOCK) do; _GATE_SESSION[k.conn.name] = report.id; end
                _ensure_poller!()
            end
        # Spawn if never started, OR respawn if the worker died (OOM / segfault / user exit()) —
        # otherwise a crashed worker would no-op here forever and every eval would error.
        elseif k.conn === nothing || (k.proc !== nothing && !process_running(k.proc))
            _kill_worker!(k)                      # tear down a dead/old proc before replacing (no leak/orphan)
            _spawn_worker!(k)
            _connect!(k)
            lock(_GATE_SESSION_LOCK) do; _GATE_SESSION[k.conn.name] = report.id; end   # route this worker's stream events back to the notebook
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

# ── Remote/connect timing config ──────────────────────────────────────────────────────────────
# The SSH/connect/tunnel/transfer timings scattered through gate_kernel.jl + remote.jl default to
# values that are fine on a LAN but can be too tight for a slow-auth, high-latency, or cold
# (heavy-precompile) host. They're tunable WITHOUT a rebuild via a `"remote"` object in slate.json —
# e.g. {"remote": {"dial_deadline_cold": 300, "ssh_connect_timeout": 30}} — which KaimonSlate installs
# here at init (it reads slate.json; ReportEngine loads before it, so the table is pushed IN, exactly
# as RUNON_DEFAULT / the transfer refs are). Precedence per key: slate.json value → KAIMONSLATE_<ENV>
# env var → the hardcoded default. Values are SECONDS unless the name says otherwise. Every key/env/
# default is tabulated over the helpers in remote.jl (the `_ssh_*`/`_dial_*`/… cluster); the two below
# live here because their call sites do.
const _REMOTE_CFG = Ref{Dict{String,Any}}(Dict{String,Any}())
function _rcfg(key::AbstractString, env::AbstractString, default::Real)
    v = get(_REMOTE_CFG[], key, nothing)
    if v !== nothing
        fv = tryparse(Float64, string(v)); fv !== nothing && return fv
    end
    something(tryparse(Float64, get(ENV, env, "")), Float64(default))
end
# Local (127.0.0.1) worker connect deadline — worker Julia startup + KaimonGate load is slow.
_connect_deadline_local() = _rcfg("connect_deadline_local", "KAIMONSLATE_CONNECT_DEADLINE_LOCAL", 90.0)
# Gate timeout for a package op (add/rm/reconstruct) — a heavy stack's resolve + precompile is minutes.
_pkg_op_timeout()         = _rcfg("pkg_op_timeout",         "KAIMONSLATE_PKG_OP_TIMEOUT",         900.0)
# Gate timeout for a parent-project /src sync.
_sync_parent_timeout()    = _rcfg("sync_parent_timeout",    "KAIMONSLATE_SYNC_PARENT_TIMEOUT",    600.0)

# Synchronous gate tool call → the tool's raw return value (binary wire-form).
function _tool(k::GateKernel, name::String, args::Dict; timeout::Float64 = 120.0)
    # A clear, retryable error instead of a cryptic `_req_send_recv(::Nothing,…)` MethodError when the
    # kernel is mid-swap (a reprovision transiently nulls `conn`). Best-effort callers (datadir sync)
    # skip and the next presync re-establishes on the fresh worker (its ns_gen already bumped).
    k.conn === nothing && error("gate $name: kernel '$(k.label)' has no connection (worker reprovisioning?)")
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
    effects = hasproperty(wire, :effects) ? collect(wire.effects) : Any[]
    assets = hasproperty(wire, :assets) ? collect(wire.assets) : Any[]
    return CellOutput(String(wire.stdout), chunks, collect(wire.echarts), collect(wire.tables),
                      binds, String(wire.value_repr), wire.exception, wire.backtrace, Float64(wire.duration_ms),
                      collect(wire.trace), String(wire.stderr), overflow, animations,
                      hasproperty(wire, :memo) ? String(wire.memo) : "",
                      hasproperty(wire, :memo_why) ? String(wire.memo_why) : "",
                      effects, assets)
end

function eval_capture(k::GateKernel, report::Report, source::AbstractString, filename::AbstractString = "string";
                      region::AbstractString = "", regions::AbstractVector = String[])
    wire = try
        # prepare! is INSIDE the try: a worker spawn/connect or env-reconstruction failure must
        # surface as this cell's error, NOT propagate up through eval_stale!/sync_from_file! and 500
        # the whole `state` request (which bricks the notebook in the browser).
        prepare!(k, report)
        # `filename` is a kwarg on the worker tool — GateTool strips optional POSITIONAL args, so it
        # must ride as a keyword (Dict key → kwarg) to survive the hop. See worker.jl `__slate_eval`.
        # `ctx_*` seed the worker's task-local Slate execution context (see `_build_slate_ctx`).
        _tool(k, "__slate_eval", Dict{String,Any}("source" => String(source), "filename" => String(filename),
              _ctx_args(report, region, regions)...); timeout = _eval_timeout())
    catch e
        return CellOutput("", MimeChunk[], Any[], Any[], BindSpec[], "", sprint(showerror, e), nothing, 0.0)
    end
    return _wire_to_output(wire)
end

# Memo-aware: ask the worker to restore an expensive cell from disk (no recompute) or persist it
# after a run exceeding `memo.threshold` ms. The key digests this cell + its upstream sources +
# bind inputs; the worker folds in the Revise'd src + Manifest digests (see worker.jl `__slate_eval`).
# Build the `ctx_*` tool-args carrying the Slate execution context to the worker: the effective side
# (`""` = main), the notebook id, and the declared region names — the worker rebuilds the full context
# (adding its own `slate_emit`) from these. See worker.jl `__slate_eval` / `_build_slate_ctx`.
_ctx_args(report::Report, region::AbstractString, regions::AbstractVector) = (
    "ctx_region"   => String(region),
    "ctx_notebook" => String(report.id),
    "ctx_regions"  => String[String(r) for r in regions])

# Ask the worker to re-render a native (Makie) figure cell under a Slate PALETTE, for a themed PDF
# export that overrides the notebook's live theme (see worker.jl `__slate_rerender_fig`). Returns
# `(bytes, ext)` with `ext ∈ ("pdf","svg","png")`, or `nothing` when Makie isn't loaded, the cell has
# no figure, or the round-trip fails — the caller then falls back to the already-rendered bytes.
function rerender_fig(k::GateKernel, report::Report, source::AbstractString, theme::AbstractString;
                      cellid::AbstractString = "export", raster::Bool = false)
    res = try
        prepare!(k, report)
        _tool(k, "__slate_rerender_fig", Dict{String,Any}(
            "source" => String(source), "theme" => String(theme), "raster" => raster,
            "filename" => "cell:" * String(cellid)); timeout = _eval_timeout())
    catch
        return nothing
    end
    (res !== nothing && hasproperty(res, :ok) && res.ok === true) || return nothing
    b64 = hasproperty(res, :b64) ? String(res.b64) : ""
    ext = hasproperty(res, :ext) ? String(res.ext) : ""
    (isempty(b64) || isempty(ext)) && return nothing
    bytes = try; Vector{UInt8}(Base64.base64decode(b64)); catch; return nothing; end
    return (bytes, ext)
end
# In-process / non-gate kernels have no worker to round-trip — themed re-render is a gate-worker
# capability, so fall back to the already-rendered figure bytes (no override for the in-process kernel).
rerender_fig(::Kernel, ::Report, ::AbstractString, ::AbstractString; cellid::AbstractString = "export", raster::Bool = false) = nothing

# Fetch a byte asset an extension registered on the WORKER via `provide_served_asset!` (keyed by content
# hash), so the hub can serve it at a stable URL. Returns `(mime, bytes)` or `nothing`. The hub caches by
# hash after the first fetch (content-addressed → immutable), so this round-trips at most once per asset.
function get_served_asset(k::GateKernel, report::Report, hash::AbstractString)
    res = try
        prepare!(k, report)
        _tool(k, "__slate_get_served_asset", Dict{String,Any}("hash" => String(hash)); timeout = 30.0)
    catch
        return nothing
    end
    (res !== nothing && hasproperty(res, :ok) && res.ok === true) || return nothing
    b64 = hasproperty(res, :b64) ? String(res.b64) : ""
    isempty(b64) && return nothing
    bytes = try; Vector{UInt8}(Base64.base64decode(b64)); catch; return nothing; end
    return (hasproperty(res, :mime) ? String(res.mime) : "application/octet-stream", bytes)
end
get_served_asset(::Kernel, ::Report, ::AbstractString) = nothing

# Ask the worker to re-render its retained LIVE (session-bound) outputs — WGLMakie figures — for a browser
# page that just connected, the way a Bonito server serves a fresh session per page. Returns `[(cid, wire),
# …]` (empty if there's no live worker or nothing is live); the hub applies each via `server_celldone`. No
# `prepare!` — this must NOT spawn a worker just because a page connected; if the worker's down it no-ops.
function rerender_live(k::GateKernel, report::Report)
    res = try
        _tool(k, "__slate_rerender_live", Dict{String,Any}(); timeout = _eval_timeout())
    catch
        return Tuple{String,Any}[]
    end
    (res !== nothing && hasproperty(res, :cids)) || return Tuple{String,Any}[]
    cids, mts, b64s = res.cids, res.mimetypes, res.b64s
    out = Tuple{String,Any}[]
    for i in eachindex(cids)
        bytes = try; Vector{UInt8}(Base64.base64decode(String(b64s[i]))); catch; continue; end
        # Rebuild the minimal cell wire `_wire_to_output` expects (the fresh live figure's one rich chunk).
        wire = (stdout = "", mime = [(String(mts[i]), bytes)], echarts = Any[], tables = Any[],
                binds = NamedTuple[], value_repr = "", exception = nothing, backtrace = nothing,
                duration_ms = 0.0, trace = Any[], stderr = "", overflow = NamedTuple[],
                animations = Any[], effects = Any[], assets = Any[])
        push!(out, (String(cids[i]), wire))
    end
    return out
end
rerender_live(::Kernel, ::Report) = Tuple{String,Any}[]

function eval_capture(k::GateKernel, report::Report, source::AbstractString, filename::AbstractString, memo;
                      region::AbstractString = "", regions::AbstractVector = String[])
    (memo === nothing || isempty(memo.key)) && return eval_capture(k, report, source, filename; region = region, regions = regions)
    wire = try
        prepare!(k, report)
        _tool(k, "__slate_eval", Dict{String,Any}(
            "source" => String(source), "filename" => String(filename),
            _ctx_args(report, region, regions)...,
            "memo_key" => String(memo.key), "memo_names" => collect(String, memo.names),
            "memo_threshold" => Float64(memo.threshold),
            # ▶ force: skip the restore (an explicit play must re-evaluate) but still store the fresh
            # result. `always`: the `cache` tag — persist regardless of runtime. Both hasproperty-guarded
            # so older 3-field memo tuples (agent scratch evals) still work.
            "memo_force" => (hasproperty(memo, :force) && memo.force === true),
            "memo_always" => (hasproperty(memo, :always) && memo.always === true),
            # names nothing downstream reads — display objects among them store as wire-image only
            "memo_unread" => (hasproperty(memo, :unread) ? collect(String, memo.unread) : String[]),
            # names nothing downstream MUTATES — restore may zero-copy (mmap/arrow view)
            "memo_safe" => (hasproperty(memo, :safe) ? collect(String, memo.safe) : String[])); timeout = _eval_timeout())
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

# Short timeout: this rides inside edit paths holding nb.lock — a stalled worker must not wedge
# the editor for the default 120 s. No prepare!: no worker ⇒ nothing is in flight to cancel.
function cancel_cells(k::GateKernel, report::Report, ids)
    k.conn === nothing && return 0
    wire = try
        _tool(k, "__slate_cancel_cells",
              Dict{String,Any}("ids" => String[String(i) for i in ids]); timeout = 5.0)
    catch e
        @debug "slate: cancel_cells gate call failed" exception = e
        return 0
    end
    return wire isa Integer ? Int(wire) : 0
end

function macroexpand_cells(k::GateKernel, report::Report, srcs::AbstractDict)
    prepare!(k, report)
    wire = try
        _tool(k, "__slate_macroexpand", Dict{String,Any}("cells" => Dict{String,String}(srcs)))
    catch e
        @warn "slate: __slate_macroexpand gate call failed" notebook = report.id exception = e
        return Dict{String,Tuple{Set{Symbol},Set{Symbol}}}()
    end
    out = Dict{String,Tuple{Set{Symbol},Set{Symbol}}}()
    wire === nothing && return out
    # The wire may re-key Dicts with SYMBOL keys (same caveat as `_module_exports`) — `pairs` +
    # dual-key lookup read both shapes.
    _names(v, key) = begin
        x = v isa AbstractDict ? (haskey(v, key) ? v[key] : get(v, Symbol(key), nothing)) : nothing
        x isa AbstractVector ? Set{Symbol}(Symbol(String(s)) for s in x) : nothing
    end
    for (k2, v) in pairs(wire)
        r = _names(v, "reads"); w = _names(v, "writes")
        (r === nothing || w === nothing) || (out[String(k2)] = (r, w))
    end
    return out
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

# The worker's SlateExtensionsBase extension manifest — what its loaded packages registered for the
# page to mirror (`frontend` scripts now; more fields as SEB grows). Pulled once per run drain (see
# `_refresh_extensions!`); returns `nothing` when there's no live worker, so the caller keeps its
# current registry. No `prepare!`: we only ask a worker that just ran, never spawn one to query.
function extension_manifest(k::GateKernel)
    k.conn === nothing && return nothing
    return try
        _tool(k, "__slate_extension_manifest", Dict{String,Any}(); timeout = 15.0)
    catch e
        @debug "slate: extension manifest gate call failed" exception = e
        nothing
    end
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

# Best-effort: a dead/reconnecting worker just means the pin doesn't (yet) apply — never surfaces
# as a cell error (called from tag-editing / bookkeeping paths, not an eval).
function memo_pin!(k::GateKernel, report::Report, key::AbstractString, pin::Bool)
    isempty(key) && return nothing
    try
        prepare!(k, report)
        _tool(k, "__slate_memo_pin", Dict{String,Any}("key" => String(key), "pin" => pin))
    catch
    end
    return nothing
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
            _tool(k, "__slate_pkg_parent", Dict{String,Any}("op" => String(op), "name" => String(name), "parent" => k.parent); timeout = _pkg_op_timeout())
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
        # well past the 120s default, especially on a fresh remote env. Tunable via _pkg_op_timeout().
        r = _tool(k, "__slate_pkg", Dict{String,Any}("op" => String(op), "name" => String(name)); timeout = _pkg_op_timeout())
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
              timeout = _pkg_op_timeout())
        _write_parent_marker!(k)
        empty!(k.pending)   # clear ONLY on success — a failed rebuild keeps `pending` so the next use retries
    catch e
        e isa InterruptException && rethrow()
        @warn "KaimonSlate: notebook env reconstruction failed — keeping pending packages to retry" exception = (e, catch_backtrace())
    end
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
        _tool(k, "__slate_sync_parent", Dict{String,Any}("envdir" => k.envdir, "parent" => k.parent); timeout = _sync_parent_timeout())
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

# The worker's memo decision record for one cell (or all: cell = "") — see worker.jl _MEMO_TRACE.
# Requires a live conn (the record lives IN the worker); nothing when the worker isn't up.
function memo_trace(k::GateKernel, cell::AbstractString = "")
    k.conn === nothing && return nothing
    return _tool(k, "__slate_memo_trace", Dict{String,Any}("cell" => String(cell)); timeout = 30.0)
end

# Force-snapshot the CURRENT namespace values for `cells` (id → {key,names,unread,safe,ms}) into
# the worker's durable store, threshold-free, for a standalone export. Returns id → {fullkey,
# bytes, stored}, or `nothing` if the worker isn't up. See worker.jl `__slate_memo_snapshot`.
function memo_snapshot(k::GateKernel, cells::AbstractDict)
    k.conn === nothing && return nothing
    return _tool(k, "__slate_memo_snapshot", Dict{String,Any}("cells" => cells); timeout = 120.0)
end

# Reset the worker namespace and mark every cell stale (mirrors `reset_module!`).
function reset!(k::GateKernel, report::Report)
    k.conn === nothing || (try; _tool(k, "__slate_reset", Dict{String,Any}()); catch; end)
    reset_all!(report)
    return nothing
end

# Fire deleted cells' cleanup callbacks in the WORKER namespace (see worker.jl `__slate_cleanup_cells`).
# Best-effort + fire-and-forget: a teardown must never block or fail an edit. No-op if the worker is down
# (its namespace — and the sessions — died with it).
function run_cleanups!(k::GateKernel, ::Report, ids)
    k.conn === nothing && return nothing
    sids = String[String(i) for i in ids]
    isempty(sids) && return nothing
    try; _tool(k, "__slate_cleanup_cells", Dict{String,Any}("ids" => sids); timeout = 20.0); catch; end
    return nothing
end

"""
Shut the kernel down and clear gate state. A LOCAL worker is killed (clean exit request +
SIGTERM/SIGKILL backstop). A spawned-remote worker is DETACHED by default — tunnel/sync closed,
process left running warm (namespace + packages + memo store) with its state sidecar flipped to
`idle`, so reopening the notebook reattaches instantly. `kill_remote=true` is for the paths where
a surviving worker would be wrong: an explicit restart (reattach would make it a no-op), the
preflight probe, and reap. An ATTACHED worker (`k.remote`) is never ours to kill either way.
"""
function shutdown!(k::GateKernel; kill_remote::Bool = false)
    K = _kaimon()
    lock(k.lock) do
        # `send_shutdown!` tells the worker process to EXIT — only a local worker (or an explicit
        # remote kill) gets it. An attached worker isn't ours; a detaching remote must keep running.
        wants_exit = !(k.remote || (k.target isa RemoteTarget && !kill_remote))
        (wants_exit && k.conn !== nothing) && (try; K.send_shutdown!(k.conn); catch; end)
        _kill_worker!(k; kill_remote)   # proc === nothing for remote → no process kill; clears conn + routing
    end
    return nothing
end
