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
import Dates                                  # publish dates for the multi-doc site manifest
import Logging                                # standalone serve: route hub log detail to a file
import REPL                                   # standalone serve: raw-mode ^C byte (see _wait_for_ctrl_c)
import Tar
import Typst_jll
import Pkg
using ..ReportEngine
using ..ReportRender
import ..SlateHome
import ..PublishLedger

include("history.jl")   # module SlateHistory — durable content-addressed time machine
include("parsched.jl")  # ParCell / par_blockers / run_scheduled — the parallel dataflow scheduler

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub
export find_live, notebook_digest, agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!, agent_delete_cells!, agent_rename_cell!, agent_scratch_eval!, agent_scratch_eval_bg!, scratch_check, agent_surface_controls!
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
    scratch::Vector{Cell}                # in-memory scratchpad cells (slate.eval) — never persisted/exported/graphed
    # Inner constructor takes the original 13 fields and starts an empty scratchpad, so every existing
    # positional call site (server + tests) is unchanged; scratch is populated at runtime by slate.eval.
    LiveNotebook(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents) =
        new(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents, Cell[])
end

# Wire/unwire the engine's out-of-band callback registry (eval.jl) for one notebook — the seam
# between the dependency-light engine and the HTTP/SSE layer. Both `load_notebook` paths (fresh
# `.jl` bundle vs. ordinary notebook) wire the identical set; close/restart paths unwire it. Kept
# as ONE place so the two never drift out of sync with each other.
function _wire_callbacks!(nb::LiveNotebook)
    register_refresh!(nb.report.id, vars -> server_refresh(nb, vars))                      # async slate_refresh → recompute readers
    register_srcchange!(nb.report.id, (names, err) -> server_src_changed(nb, names, err))  # parent /src reloaded (Revise)
    register_progress!(nb.report.id, c -> _broadcast_progress(nb, c))                      # stream per-cell run status to the UI
    register_runbatch!(nb.report.id, n -> (try; _broadcast(nb, "runbatch:$n"); catch; end))   # run size → stable k/N
    register_userprog!(nb.report.id, (frac, msg, id, done) -> (try; _broadcast(nb, "cellprog:" * JSON.json(Dict("frac" => frac, "msg" => msg, "id" => id, "done" => done))); catch; end))
    register_celldone!(nb.report.id, (run_id, cid, wire) -> server_celldone(nb, run_id, cid, wire))   # parallel-batch result merge
    return nb
end
function _unwire_callbacks!(nb::LiveNotebook)
    unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id)
    unregister_progress!(nb.report.id); unregister_runbatch!(nb.report.id)
    unregister_userprog!(nb.report.id); unregister_celldone!(nb.report.id)
    return nb
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
function _select_kernel(path::AbstractString, report; threads::AbstractString = "")
    if ReportEngine.gate_available()
        ReportEngine._rlog("_select_kernel nb=$(basename(String(path))) runon=[$(get(report.meta, "runon", ""))] remoteworker=[$(get(report.meta, "remoteworker", ""))]")
        # Remote-worker opt-in: run this notebook's cells on an ALREADY-RUNNING worker reached at
        # 127.0.0.1:<port> (e.g. on another machine, forwarded over an SSH tunnel). Set as
        # meta["remoteworker"] = "port,stream_port". Machine-specific (the ports/tunnel are local),
        # so it's RUNTIME-ONLY — never written to the `.jl` footer. `prepare!` attaches, doesn't spawn.
        rw = strip(String(get(report.meta, "remoteworker", "")))
        if !isempty(rw)
            ps = split(rw, ','; limit = 2)
            port = length(ps) == 2 ? tryparse(Int, strip(ps[1])) : nothing
            sp   = length(ps) == 2 ? tryparse(Int, strip(ps[2])) : nothing
            (port !== nothing && sp !== nothing) &&
                return ReportEngine.attach_gate_kernel(port, sp)
            @warn "slate: ignoring malformed remoteworker spec (want \"port,stream_port\")" spec = rw
        end
        # Remote-SPAWN, PER NOTEBOOK: PROVISION + run THIS notebook's worker on an SSH host, connecting
        # over CURVE (:direct) or a supervised SSH tunnel (default). The destination is resolved from three
        # layers — a runtime SESSION override, the notebook's DURABLE footer override, then the machine
        # GLOBAL default (see `_effective_runon`). Value = "ssh_host[,transport]". `prepare!` provisions +
        # spawns + connects, keeping the parent synced.
        ro = _effective_runon(report)
        if !isempty(ro)
            # spec = "host[,transport[,port,stream]]" — transport tunnel|direct (default tunnel); the two
            # optional ports pin the remote main/stream ports (mainly for :direct behind a firewall).
            parts = split(ro, ',')
            rhost = String(strip(parts[1]))
            transport = length(parts) >= 2 && !isempty(strip(parts[2])) ? Symbol(strip(parts[2])) : :tunnel
            pport  = length(parts) >= 3 ? something(tryparse(Int, strip(parts[3])), 0) : 0
            psport = length(parts) >= 4 ? something(tryparse(Int, strip(parts[4])), 0) : 0
            proj = Base.current_project(dirname(abspath(path)))
            parent = proj === nothing ? "" : dirname(proj)
            report.meta["assetbase"] = parent
            # per-host remote project dir keyed by the local parent's basename (avoid cross-notebook clash)
            rproj = "~/.cache/kaimonslate/remote/" * (isempty(parent) ? "detached" : basename(parent))
            # The LOCAL env to REPLICATE on the remote so packages/dev-sources match exactly: the notebook's
            # own fork env (its added packages) when it has one, else the parent project. Empty ⇒ nothing to
            # replicate (bare notebook) — the worker just gets Slate's payload + KaimonGate.
            envdir = ReportEngine.notebook_env_dir(path)
            origin_env = isfile(joinpath(envdir, "Project.toml")) ? envdir :
                         (!isempty(parent) && isfile(joinpath(parent, "Project.toml")) ? parent : "")
            target = ReportEngine.RemoteTarget(rhost; transport = transport, project = rproj,
                                               port = pport, stream_port = psport, origin_env = origin_env)
            ReportEngine._rlog("_select_kernel → REMOTE kernel host=$rhost transport=$transport rproj=$rproj parent=$parent")
            # `label` = the notebook filename → the worker's manifest records WHICH notebook it serves
            # (else the remote-workers list shows "?"). Also the gate-session display name, like local kernels.
            return ReportEngine.GateKernel(rproj; parent = parent, threads = threads, target = target,
                                           label = basename(abspath(path)))
        end
        proj = Base.current_project(dirname(abspath(path)))
        parent = proj === nothing ? "" : dirname(proj)
        # Base dir for `@asset "rel/path"` resolution + memo hashing — the notebook's project dir,
        # matching the worker's PARENT_PROJECT. Runtime-derived (absolute, machine-specific), so it
        # lives in meta (never the `.jl` footer, which only persists _CONFIG_KEYS).
        report.meta["assetbase"] = parent
        envdir = ReportEngine.notebook_env_dir(path)
        env_exists = isfile(joinpath(envdir, "Project.toml"))   # the fork is materialised on first add
        delta = get(report.meta, "env", Dict{String,Any}[])     # footer-recorded notebook packages
        # Per-notebook worker-thread override: explicit `threads` arg wins, else a persisted
        # meta["threads"] (set at a prior open / footer), else "" → the kernel falls back to the global.
        th = isempty(threads) ? String(get(report.meta, "threads", "")) : String(threads)
        lbl = basename(abspath(path))   # gate-session display label: the notebook's filename
        if !env_exists && !isempty(delta)
            # The `.jl` records package adds but the env dir is gone (e.g. a fresh git clone):
            # reconstruct it from the footer on first use (pending). Only `mkdir` here — the
            # Project.toml is written by the reconstruction itself, so a worker that never ran
            # leaves the env "absent" and reconstruction retries on the next open.
            mkpath(envdir)
            return GateKernel(envdir; parent = parent, envdir = envdir, pending = delta, threads = th, label = lbl)
        elseif parent == ""
            # Detached: the notebook env IS the whole world (everything is a "notebook add").
            ReportEngine.ensure_notebook_env!(envdir)
            return GateKernel(envdir; parent = "", envdir = envdir, threads = th, label = lbl)
        elseif env_exists
            # Already has its own packages → run in the forked env (extends the parent).
            return GateKernel(envdir; parent = parent, envdir = envdir, threads = th, label = lbl)
        else
            # Base mode: no notebook-specific packages yet → run directly in the parent.
            return GateKernel(parent; parent = parent, envdir = envdir, threads = th, label = lbl)
        end
    end
    return InProcessKernel()
end

function load_notebook(path::AbstractString; id::AbstractString = "", threads::AbstractString = "",
                       runon::AbstractString = "")
    src = read(path, String)
    base = splitext(basename(path))[1]
    rid = replace(base, r"[^A-Za-z0-9]" => "_")
    nbid = isempty(id) ? rid : String(id)
    r = parse_report(src; id = rid, title = base)
    # Per-notebook worker-thread override (from slate.open) → meta, where _select_kernel reads it (and
    # state_json round-trips it). The `.jl` footer carries it across restarts when present.
    isempty(threads) || (r.meta["threads"] = String(threads))
    # Run-location chosen at open/create time (the new-notebook / import picker) → the DURABLE notebook
    # override, so _select_kernel boots the worker on that host directly (no wasteful local-then-remote).
    # Only overrides the FOOTER value when explicitly given; an empty runon leaves the file's own choice.
    isempty(strip(String(runon))) || (r.meta["runon"] = String(strip(String(runon))))
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
        _wire_callbacks!(nb)
        _load_chat_log!(nb)
        @async _hydrate_standalone!(nb, String(path))   # reconstruct + run live, then push
        return nb
    end
    # Open INSTANTLY: hand the browser the notebook with cells un-run and boot the kernel + do the
    # initial full run in the BACKGROUND, pushing results live as they land (same hydrate pattern as
    # a self-contained `.jl`). A heavy notebook — slow worker boot, long-running cells — no longer
    # blocks the user from getting in. The `hydrating` flag tells the UI a background run is underway.
    r.meta["hydrating"] = true
    nb = LiveNotebook(nbid, String(path), r, InProcessKernel(), 0, String[], String[],
                      ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                      Dict{String,String}())
    _wire_callbacks!(nb)
    _load_chat_log!(nb)                  # restore any prior agent transcript (survives server restart)
    @async begin
        try
            kernel = _select_kernel(path, r)         # boot the (gate) worker
            lock(nb.lock) do; nb.kernel = kernel; nb.version += 1; end
            try; _broadcast(nb, string(nb.version)); catch; end   # worker is up → refresh the dot to "connected" BEFORE the (possibly long) run, so it's not stale
            _drain!(nb)                              # initial full run — WAIT for it to fully complete, so
                                                     # `hydrating` (and its banner) stays up for the whole run
            lock(nb.lock) do
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
            # Seed the durable history with the initial run state, so the first edit has a parent to
            # diff against and the "buildup" replay starts from the true origin.
            _history!(nb; source = "open")
            _autoindex!(nb)                          # background: index project deps + used packages' docs
        catch e
            lock(nb.lock) do
                nb.report.meta["hydrate_error"] = sprint(showerror, e)
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
            @warn "KaimonSlate: initial run failed" exception = (e, catch_backtrace())
        end
        try; _broadcast(nb, string(nb.version)); catch; end   # nudge the browser to pull the now-live cells
    end
    return nb
end

# Background env reconstruction for a preview-standalone (see load_notebook): reconstruct the
# bundle into the depot cache, instantiate, swap in the real gate kernel, run the cells live,
# then push — the client swaps the frozen preview for live cells. On failure, surface it and
# drop the hydrating state (the preview stays visible as the last-known render).
function _hydrate_standalone!(nb::LiveNotebook, path::AbstractString)
    try
        rc = _reconstruct_bundle!(path)
        rc.fresh && _instantiate_env!(rc.envdir)
        kernel = GateKernel(rc.envdir; parent = rc.parent, envdir = rc.envdir, label = basename(abspath(path)))
        lock(nb.lock) do
            nb.kernel = kernel
            # A durable INSTALL (SLATE_INSTALL_DIR) → serve the notebook FROM the installed project, so
            # edits save there (and land in its git checkout), not into the throwaway downloaded `.jl`.
            (rc.install && !isempty(rc.notebook) && isfile(rc.notebook)) && (nb.path = rc.notebook)
            delete!(nb.report.meta, "preview")       # live cells supersede the frozen render
        end
        _drain!(nb)                                  # run everything + WAIT, so `hydrating` stays up for it
        lock(nb.lock) do
            delete!(nb.report.meta, "hydrating")
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
    msg = ""
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            # MARKDOWN readers seed too: a `{{ level[] }}` interpolation is a reader like any code
            # cell (md never writes, so the don't-retrigger guard passes trivially). Skipping them
            # left prose silently frozen at the last non-reactive render while charts moved.
            (!isdisjoint(c.reads, syms) && isdisjoint(c.writes, syms)) || continue
            c.state = STALE
            push!(seed, c.id)
        end
        isempty(seed) && return
        changed = Set(seed)
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing || (nb.report.cells[i].state = STALE; push!(changed, id))
        end
        _eval!(nb)
        # Push ONLY the cells that recomputed (seed + dependents), inline in the event — the browser
        # patches just those (charts `setOption`, output swap) instead of pulling the whole state.
        bindref, hostednames = _bind_index(nb.report)
        bibctx = _bib_link_ctx(nb)
        figidx = figure_index(nb.report)
        cells = [cell_json(c, bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx) for c in nb.report.cells if c.id in changed]
        msg = "refresh:" * JSON.json(Dict("cells" => cells))
    end
    isempty(msg) || _broadcast(nb, msg)
    return nothing
end

# Reactive push triggered by the asset watcher (`_start_asset_watcher!`): one or more `@asset`
# files a cell READS changed on disk → restale those cells + their dependents, recompute, and push
# the same lightweight `refresh:` patch as a `@bind` change. `changed` are absolute paths; a cell's
# `inputs` are notebook-relative (or absolute), resolved against `assetbase` (its project dir).
function server_asset_changed(nb::LiveNotebook, changed::Vector{String})
    base = String(get(nb.report.meta, "assetbase", ""))
    chset = Set{String}(changed)
    _resolve(rel) = isabspath(rel) ? String(rel) : (isempty(base) ? String(rel) : joinpath(base, rel))
    _inputs_changed(c) = any(rel -> _resolve(rel) in chset, c.inputs)
    msg = ""
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            _inputs_changed(c) || continue
            c.state = STALE; push!(seed, c.id)
        end
        isempty(seed) && return
        changedids = Set(seed)
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing || (nb.report.cells[i].state = STALE; push!(changedids, id))
        end
        _eval!(nb)
        bindref, hostednames = _bind_index(nb.report)
        bibctx = _bib_link_ctx(nb)
        figidx = figure_index(nb.report)
        cells = [cell_json(c, bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx)
                 for c in nb.report.cells if c.id in changedids]
        msg = "refresh:" * JSON.json(Dict("cells" => cells))
    end
    isempty(msg) || _broadcast(nb, msg)
    return nothing
end

# Live per-cell run status (registered via `register_progress!` per notebook): `eval_cell!` calls
# this as each cell STARTS and FINISHES running. A start pushes a lightweight `cellrun:<id>` so the
# UI marks that cell live (spinner + ticking timer + the topbar run pill); a finish pushes the single
# cell's fresh `celldone:<cell_json>` so its result/error lights up the INSTANT it lands, mid-run,
# instead of only when the whole run ends. Best-effort — a push must never disturb evaluation.
function _broadcast_progress(nb::LiveNotebook, cell)
    try
        if cell.state == RUNNING
            _broadcast(nb, "cellrun:" * cell.id)
        else
            bindref, hostednames = _bind_index(nb.report)
            bibctx = _bib_link_ctx(nb)
            figidx = figure_index(nb.report)
            _broadcast(nb, "celldone:" * JSON.json(cell_json(cell, bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx)))
        end
    catch
    end
    return nothing
end

# ── Async eval runner ─────────────────────────────────────────────────────────────────────────
# Cell eval used to run synchronously on the caller's thread, holding nb.lock and bounded by the
# gate request timeout — so a long cell blocked the whole notebook (no add/edit while running) and
# could time out mid-compute. Instead, a SINGLE per-notebook background runner drains stale cells
# serially; it holds nb.lock only to mutate cell state / merge a result, and RELEASES it during the
# (long) eval_capture. So structural edits proceed while a cell computes, results stream over SSE
# (cellrun/celldone) exactly as before, and the gate request is no longer the wall (see _eval_timeout).
# Serial = one runner per notebook (the worker is single-namespace); new stale cells are picked up by
# the running loop. Version-guarded: a cell edited/deleted mid-run discards its in-flight result.
const _RUNNERS = Dict{String,Bool}()          # nb.id → a runner task is active
const _RUNNER_LOCK = ReentrantLock()

# Per-notebook mutex serialising WORKER EVALUATION: the runner's per-cell / per-batch steps take
# it, and so does any out-of-band eval (slate.eval scratch pokes). Without it a scratch eval can
# land on the worker CONCURRENTLY with a parallel cell batch and trip a `ConcurrencyViolationError`
# deep in shared non-thread-safe state (CairoMakie buffers, etc.). Uncontended on the common path
# (one runner, no scratch), so it adds only an atomic acquire per eval step.
const _EVAL_MUTEX = Dict{String,ReentrantLock}()
const _EVAL_MUTEX_LOCK = ReentrantLock()
_eval_mutex(nb::LiveNotebook) = lock(_EVAL_MUTEX_LOCK) do; get!(() -> ReentrantLock(), _EVAL_MUTEX, nb.id); end

# Next stale cell to run, in eval_stale!'s order: static markdown (no reads) first, then doc order.
function _next_stale_cell(report)
    for c in report.cells
        c.kind == MARKDOWN && c.state == STALE && isempty(c.reads) && return c
    end
    for c in report.cells
        c.state == STALE && return c
    end
    return nothing
end

# ── Per-cell run statistics (session-scoped) ──────────────────────────────────────────────────────
# Updated at every cell-completion merge and embedded in cell_json["stats"], so the DAG's heat map
# and stats card stream live over the same celldone/refresh events as everything else. `pulls`
# counts downstream USE: every time a dependent cell actually computes, each cell in its upstream
# dependency closure gets a tick — "how often were this cell's definitions consumed downstream".
mutable struct CellStats
    evals::Int              # actual computations (memo restores excluded)
    restores::Int           # durable-cache restores (no recompute)
    pulls::Int              # downstream evals that consumed this cell's definitions
    total_ms::Float64       # accumulated compute time (evals only)
    sumsq::Float64          # Σ duration² — std dev without a history
    min_ms::Float64
    max_ms::Float64
    recent::Vector{Float64} # ring of recent durations → percentiles
    last_ms::Float64
    last_ts::Float64        # epoch seconds of the last completion
    last_memo::String       # "" | "restored" | "stored"
end
CellStats() = CellStats(0, 0, 0, 0.0, 0.0, Inf, 0.0, Float64[], 0.0, 0.0, "")
const _CELL_STATS = Dict{String,Dict{String,CellStats}}()   # nb.id → cell.id → stats
const _CELL_STATS_LOCK = ReentrantLock()

# Transitive upstream ids of `id` (BFS over deps). Callers hold nb.lock (deps stable).
function _upstream_closure(report, id::String)
    seen = Set{String}(); queue = String[id]
    while !isempty(queue)
        c = get(report.byid, popfirst!(queue), nothing); c === nothing && continue
        for d in c.deps
            d in seen && continue
            push!(seen, d); push!(queue, d)
        end
    end
    return seen
end

# Record a completed run. Called at the merge points (serial + parallel) BEFORE the celldone
# broadcast, so the pushed cell_json already carries the fresh numbers. Callers hold nb.lock.
function _stats_record!(nb::LiveNotebook, cell)
    out = cell.output; out === nothing && return nothing
    lock(_CELL_STATS_LOCK) do
        stats = get!(Dict{String,CellStats}, _CELL_STATS, nb.id)
        s = get!(CellStats, stats, cell.id)
        s.last_ts = time(); s.last_ms = out.duration_ms; s.last_memo = out.memo
        if out.memo == "restored"
            s.restores += 1
        else
            s.evals += 1
            s.total_ms += out.duration_ms; s.sumsq += out.duration_ms^2
            s.min_ms = min(s.min_ms, out.duration_ms); s.max_ms = max(s.max_ms, out.duration_ms)
            push!(s.recent, out.duration_ms)
            length(s.recent) > 64 && popfirst!(s.recent)
        end
        if out.memo != "restored" && out.exception === nothing
            for up in _upstream_closure(nb.report, cell.id)
                get!(CellStats, stats, up).pulls += 1
            end
        end
    end
    return nothing
end

# The JSON view for cell_json["stats"] (nothing when the cell has never completed). Percentiles are
# over the recent ring (last ≤64 computes) — labeled "recent", not lifetime.
function _cell_stats_json(nbid::AbstractString, cid::AbstractString)
    lock(_CELL_STATS_LOCK) do
        nbstats = get(_CELL_STATS, String(nbid), nothing)
        nbstats === nothing && return nothing
        s = get(nbstats, String(cid), nothing)
        s === nothing && return nothing
        n = s.evals
        mean = n > 0 ? s.total_ms / n : 0.0
        sd = n > 1 ? sqrt(max(0.0, s.sumsq / n - mean^2)) : 0.0
        q = sort(s.recent)
        pct = p -> isempty(q) ? 0.0 : q[clamp(ceil(Int, p * length(q)), 1, length(q))]
        r1(x) = round(x; digits = 1)
        return Dict{String,Any}(
            "evals" => n, "restores" => s.restores, "pulls" => s.pulls,
            "total_ms" => r1(s.total_ms), "mean_ms" => r1(mean), "std_ms" => r1(sd),
            "min_ms" => n > 0 ? r1(s.min_ms) : 0.0, "max_ms" => r1(s.max_ms),
            "p50_ms" => r1(pct(0.5)), "p90_ms" => r1(pct(0.9)),
            "last_ms" => r1(s.last_ms), "last_ts" => r1(s.last_ts), "memo" => s.last_memo,
            "recent" => [r1(x) for x in s.recent])   # the raw ring — the stats card's sparkline
    end
end

# Evaluate ONE cell with the lock-release discipline. Markdown (fast interp) runs under the lock;
# code marks RUNNING + announces under the lock, evals WITHOUT it, then merges under the lock iff the
# cell still exists unchanged (src_hash match) — else the result is from a superseded run, discarded.
function _eval_one!(nb::LiveNotebook, cell::Cell)
    if cell.kind == MARKDOWN
        lock(nb.lock) do; ReportEngine.eval_cell!(nb.report, cell, nb.kernel); end
        return nothing
    end
    src, srchash, memo = lock(nb.lock) do
        cell.state = RUNNING
        _broadcast_progress(nb, cell)
        s = (:trace in cell.flags) ? string("@trace begin ", cell.source, "\nend") : cell.source
        frc = let ids = get(_FORCE_RUN, nb.id, nothing)   # consume a one-shot ▶ force marker
            ids !== nothing && cell.id in ids ?
                (delete!(ids, cell.id); isempty(ids) && delete!(_FORCE_RUN, nb.id); true) : false
        end
        m = (key = ReportEngine._memo_key(nb.report, cell),
             names = String[string(w) for w in cell.writes],
             threshold = ReportEngine._MEMO_THRESHOLD_MS,
             force = frc,
             always = (:cache in cell.flags))   # `cache` tag → persist regardless of runtime
        (s, cell.src_hash, m)
    end
    out = try
        ReportEngine.eval_capture(nb.kernel, nb.report, src, "cell:" * cell.id, memo)
    catch e
        ReportEngine.CellOutput("", ReportEngine.MimeChunk[], Any[], Any[], ReportEngine.BindSpec[],
                                "", sprint(showerror, e), nothing, 0.0)
    end
    lock(nb.lock) do
        i = _index_of(nb.report.cells, cell.id)
        i === nothing && return                          # deleted mid-run → drop
        c = nb.report.cells[i]
        if c.src_hash != srchash
            # Edited mid-run: the in-flight result is for the OLD source — discard it AND mark the
            # cell STALE so the runner re-runs it with the new source (it may have been left RUNNING).
            c.state == RUNNING && (c.state = STALE)
            return
        end
        c.output = out; c.binds = out.binds
        c.state = out.exception === nothing ? FRESH : ERRORED
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        _broadcast_progress(nb, c)
    end
    return nothing
end

# Tell the UI how many cells are still pending (stale or running) — the run-batch signal. The frontend
# adds its own completed-count, so the pill's N grows as cells are queued mid-run (not frozen).
_emit_pending(nb::LiveNotebook, pending::Integer) = ReportEngine._emit_run_batch(nb.report.id, pending)

# ── Parallel (inter-cell) batch execution — opt-in via meta["parallel"] ──────────────────────────
# When enabled and a gate worker backs the notebook, the runner hands ALL stale code cells to the
# worker AT ONCE; the worker schedules them (par_blockers) so independent cells run concurrently in
# its one warm namespace while any conflicting pair serialises, and streams each result back as it
# lands (slate_celldone → server_celldone). This is the genuine novelty: notebooks have never run
# cells in parallel. Off by default — the proven serial path is untouched unless the flag is set.
# Default for notebooks that haven't explicitly set meta["parallel"]. That per-notebook flag is
# IN-MEMORY and resets whenever the notebook is re-opened/rebuilt from its .jl (every extension restart
# / kernel respawn) — which is why a Settings toggle kept getting wiped. KaimonSlate loads this default
# from slate.json at init so the choice persists; the per-notebook Settings toggle still overrides.
const PARALLEL_DEFAULT = Ref(true)
_parallel_enabled(nb::LiveNotebook) = get(nb.report.meta, "parallel", PARALLEL_DEFAULT[]) === true

# ── Run-location: three layers → one effective value ──────────────────────────────────────────────
# Where a notebook's worker runs is resolved from (highest precedence first):
#   1. SESSION override   — meta["runon_session"], runtime-only, never persisted (the toolbar "just for
#                           now" pick). Wins for this browser session.
#   2. NOTEBOOK override  — meta["runon"], DURABLE in the .jl Slate.config footer (author baked a host in).
#   3. GLOBAL default     — RUNON_DEFAULT[], a per-machine default from slate.json ("where new notebooks
#                           run"), configurable in Settings + the new-notebook/import dialogs.
#   4. else               — "" ⇒ LOCAL.
# The value is "host[,transport]" (transport = tunnel|direct, default tunnel). RUNON_DEFAULT is a
# machine-specific ssh alias, so like PARALLEL_DEFAULT it's an in-memory global loaded from slate.json.
const RUNON_DEFAULT = Ref("")
# Persist hook: KaimonSlate installs a `spec -> nothing` that writes slate.json (NotebookServer has no
# business knowing the config path). `set_runon_default!` sets the live ref and calls it.
const _RUNON_PERSIST = Ref{Any}(nothing)
function set_runon_default!(spec::AbstractString)
    RUNON_DEFAULT[] = String(strip(String(spec)))
    p = _RUNON_PERSIST[]
    p === nothing || (try; p(RUNON_DEFAULT[]); catch e; @warn "slate: could not persist run-location default" exception = e; end)
    return RUNON_DEFAULT[]
end

# A layer value of "local" (case-insensitive) is an EXPLICIT local pick — it forces local even when a
# lower layer (e.g. the global default) names a host. An empty value = "no override at this layer".
_norm_runon(s) = lowercase(strip(String(s))) == "local" ? "" : String(strip(String(s)))

# The effective run-location for a report's meta (see the layer list above). "" ⇒ local.
function _effective_runon(report)
    s = strip(String(get(report.meta, "runon_session", "")))
    isempty(s) || return _norm_runon(s)
    n = strip(String(get(report.meta, "runon", "")))
    isempty(n) || return _norm_runon(n)
    return _norm_runon(strip(String(RUNON_DEFAULT[])))
end
# Which layer supplied the effective value — labels the toolbar's source badge.
function _runon_source(report)
    isempty(strip(String(get(report.meta, "runon_session", "")))) || return "session"
    isempty(strip(String(get(report.meta, "runon", ""))))         || return "notebook"
    isempty(strip(String(RUNON_DEFAULT[])))                        || return "global"
    return "default"   # local
end

# Per-(notebook,run) snapshot of each batched cell's src_hash at launch — the version guard for a
# streamed result (a cell edited mid-batch has its in-flight result discarded; see server_celldone).
const _BATCH_SNAPS = Dict{String,Dict{String,UInt64}}()
const _BATCH_SEQ = Threads.Atomic{Int}(0)

# Does a code cell DEFINE methods / types / macros? Such cells mutate the worker's method & type
# tables, which is unsafe to do concurrently with other evals — so they run as a serial barrier
# (sent `opaque`, which par_blockers treats two-way). def→use is ALSO already serialised by dataflow
# (the defined name is a write the user reads downstream); this guards the independent-def case.
function _cell_defines(cell::Cell)
    top = try; Meta.parseall(cell.source); catch; return true; end   # unparseable → conservative barrier
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    for s in stmts
        s isa Expr || continue
        # `:incomplete`/`:error` nodes (parseall reports bad syntax as a node, not a throw) → barrier.
        s.head in (:function, :struct, :macro, :abstract, :primitive, :incomplete, :error) && return true
        # short-form `f(x) = …` / `f(x) where T = …` (a method def, not a plain binding)
        (s.head === :(=) && s.args[1] isa Expr && s.args[1].head in (:call, :where)) && return true
    end
    return false
end

# Per-notebook flag: a stop request sets it so the scheduler short-circuits cells that haven't started
# yet (in-flight cells are interrupted via the worker's __slate_cancel). Keyed by nb.id.
const _PARALLEL_CANCEL = Dict{String,Bool}()

# Cell ids whose NEXT eval must skip the memo restore (nb.id → ids). The explicit ▶ play button is a
# re-evaluation request — restoring the cached result there reads as "the button does nothing" — but
# the fresh result is still STORED, so the entry stays warm. Registered by edit_cell!(force=true),
# consumed (under nb.lock) by _eval_one!'s memo build. Dependents are NOT registered: they restale
# normally and may restore when their inputs are unchanged.
const _FORCE_RUN = Dict{String,Set{String}}()

# Preempt superseded in-flight cells: an edit/delete of a RUNNING cell makes the computation in
# flight worthless — its result is already version-guarded away on completion (the src_hash compare
# in `_eval_one!`/`server_celldone`) — so all it can do is burn worker time and delay the fresh
# run. Best-effort interrupt of just those cells' evaluator tasks; NEVER a correctness dependency
# (a tight allocation-free loop has no safepoint and won't stop — discard-on-completion remains the
# backstop). Exclusions: a method/type/macro-DEFINING cell is never preempted (a half-applied
# method table is worse than a wasted run), nor a graphics cell (an interrupt mid-plot can wedge
# Makie's display stack). Callers hold nb.lock and pass the PRE-EDIT cells (in-flight source/state).
_preempt_victims(cells) = String[c.id for c in cells
                                 if c.kind == CODE && c.state == RUNNING &&
                                    !_cell_defines(c) && !_uses_shared_graphics(c.source)]
function _preempt_superseded!(nb::LiveNotebook, cells)
    victims = _preempt_victims(cells)
    isempty(victims) && return nothing
    n = try
        ReportEngine.cancel_cells(nb.kernel, nb.report, victims)
    catch e
        @debug "slate: preempt failed (discard-on-completion still applies)" exception = e
        0
    end
    n > 0 && @info "slate: preempted superseded in-flight cells" notebook = nb.id cells = join(victims, ",")
    return nothing
end

# Build the parallel-batch scheduler specs for `code` cells (document order). Plotting cells share
# Makie's non-thread-safe globals (theme / current-figure / display stack), invisible to dataflow
# analysis — so they get a synthetic shared write (`_GRAPHICS_SENTINEL`), making par_blockers serialise
# graphics-vs-graphics (else two plots run concurrently → `ConcurrencyViolationError` deep in
# Observables). Mirrors the worker's `__slate_eval_batch`; extracted so it's unit-testable.
function _batch_specs(code)
    specs = ParCell[]
    # Lexical regex OR provenance (reads/provides an export of a resolved Makie-family module) —
    # the provenance half catches aliased/re-exported plot verbs the regex can't (crash-on-miss).
    gnames = ReportEngine._graphics_export_names()
    for c in code
        w = copy(c.writes)
        ReportEngine._is_graphics_cell(c, gnames) && push!(w, _GRAPHICS_SENTINEL)
        push!(specs, ParCell(c.id, copy(c.deps), copy(c.reads), w, (:opaque in c.flags) || _cell_defines(c)))
    end
    return specs
end

# Run every stale CODE cell as a PARALLEL dataflow batch. Independent cells evaluate CONCURRENTLY —
# each on its own task making its own gate `__slate_eval` call (the request channel muxes them by
# correlation id; each runs on its own worker task with task-local DemuxCapture) — while par_blockers
# serialises any dependent/conflicting pair. Each cell goes through the SAME `_eval_one!` as the serial
# path, so it renders running→done and merges version-guarded the INSTANT it finishes (true per-cell
# streaming). Returns true if a batch (≥2 cells) ran; false for the 0/1-cell case or a non-gate kernel.
function _run_code_batch!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return false
    specs, npending = lock(nb.lock) do
        code = [c for c in nb.report.cells if c.kind == CODE && c.state == STALE]
        length(code) < 2 && return (nothing, 0)
        ss = _batch_specs(code)
        (ss, count(c -> c.state in (STALE, RUNNING), nb.report.cells))
    end
    specs === nothing && return false
    # Bring the worker up ONCE (prepare! is locked + idempotent, so the concurrent per-cell evals just
    # no-op it). If it can't start, fall back to the serial path rather than spinning.
    try
        ReportEngine.prepare!(nb.kernel, nb.report)
    catch e
        @warn "slate parallel: worker not ready — falling back to serial" notebook = nb.id exception = e
        return false
    end
    _PARALLEL_CANCEL[nb.id] = false
    _emit_pending(nb, npending)
    pool = something(tryparse(Int, get(ENV, "KAIMONSLATE_PARALLEL_POOL", "")), 8)
    run_scheduled(specs, pool, function (id)
        cell = lock(nb.lock) do
            i = _index_of(nb.report.cells, id)
            i === nothing ? nothing : nb.report.cells[i]
        end
        cell === nothing && return nothing
        if get(_PARALLEL_CANCEL, nb.id, false)
            # Cancelled before this cell started → mark it interrupted, don't run.
            lock(nb.lock) do
                (cell.state in (STALE, RUNNING)) || return
                cell.output = ReportEngine.CellOutput("", ReportEngine.MimeChunk[], Any[], Any[],
                    ReportEngine.BindSpec[], "", "InterruptException: run cancelled", nothing, 0.0)
                cell.state = ERRORED
                _broadcast_progress(nb, cell)
            end
            return nothing
        end
        _eval_one!(nb, cell)   # marks RUNNING + broadcasts, evals OFF-lock, merges version-guarded + broadcasts
    end)
    delete!(_PARALLEL_CANCEL, nb.id)
    return true
end

# Merge one streamed parallel-batch result (from the worker's slate_celldone) into the notebook,
# version-guarded against a mid-batch edit, and push the single-cell live patch — mirrors _eval_one!'s
# merge so a parallel cell lands in the UI exactly like a serial one.
function server_celldone(nb::LiveNotebook, run_id::AbstractString, cid::AbstractString, wire)
    out = ReportEngine._wire_to_output(wire)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, cid)
        i === nothing && return                          # deleted mid-batch → drop
        c = nb.report.cells[i]
        snap = get(_BATCH_SNAPS, string(nb.report.id, "|", run_id), nothing)
        expect = snap === nothing ? nothing : get(snap, String(cid), nothing)
        if expect !== nothing && c.src_hash != expect
            c.state == RUNNING && (c.state = STALE)       # edited mid-batch → re-run with new source
            return
        end
        c.output = out; c.binds = out.binds
        c.state = out.exception === nothing ? FRESH : ERRORED
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        _broadcast_progress(nb, c)
    end
    return nothing
end

function _run_loop!(nb::LiveNotebook)
    try
        # Resolve bare-`using` exports BEFORE the first eval of a session, so the dependency graph —
        # and every memo key derived from it — is precise from the FIRST run. Otherwise the post-drain
        # barrier→precise flip (refine_usings!) changed downstream cells' memo keys between the first
        # and second run of each session, and the durable cache missed exactly on cold opens. Phased:
        # the import round-trip (a possible worker spawn + package load, seconds) runs OUTSIDE nb.lock
        # so UI state requests stay live; only the graph rebuild takes the lock. No-op after the first
        # drain that sees each module.
        paths = lock(nb.lock) do; ReportEngine.unresolved_using_paths(nb.report); end
        if !isempty(paths) && ReportEngine.resolve_usings!(nb.report, nb.kernel, paths)
            lock(nb.lock) do; ReportEngine.rebuild_precise!(nb.report); end
        end
        # Same pre-run phasing for macro-recovered bindings: package macros (`@kwdef`, `@enum`,
        # `@chain`, …) are expandable as soon as their modules are imported (just above), so the
        # graph + memo keys see macro-hidden writes from the FIRST eval. Notebook-defined macros
        # resolve post-drain (refine_macros! below). Round-trip outside nb.lock, like the usings.
        pending = lock(nb.lock) do; ReportEngine.pending_macro_cells(nb.report); end
        if !isempty(pending) && ReportEngine.resolve_macros!(nb.report, nb.kernel, pending)
            lock(nb.lock) do; ReportEngine.rebuild_precise!(nb.report); end
        end
        while true
            # Parallel fast-path: hand all stale code cells to the worker at once (opt-in). Falls through
            # to the serial step for markdown, reactive restales, and the 0/1-code-cell case. Held under
            # the eval mutex so a concurrent slate.eval scratch poke can't race the batch.
            if _parallel_enabled(nb) && lock(_eval_mutex(nb)) do; _run_code_batch!(nb); end
                continue
            end
            target, pending = lock(nb.lock) do
                t = _next_stale_cell(nb.report)
                t, count(c -> c.state in (STALE, RUNNING), nb.report.cells)
            end
            target === nothing && break
            _emit_pending(nb, pending)          # k/N pill: PENDING (stale+running); frontend adds done
            lock(_eval_mutex(nb)) do; _eval_one!(nb, target); end
        end
        # Drained: any bare-`using` barrier cells have now run, so resolve their exports and rebuild
        # the graph precisely (no restale — see refine_usings!). Push fresh state so the UI drops the
        # "barrier" marking. Kept off the hot per-cell path — it fires once per drain and no-ops unless
        # a NEW module got resolved.
        refined = lock(nb.lock) do
            a = ReportEngine.refine_usings!(nb.report, nb.kernel)
            # Notebook-defined macros now exist; a PARALLEL drain may have raced a reader past its
            # just-recovered producer, so restale those — the `again` re-arm below re-drains them.
            b = ReportEngine.refine_macros!(nb.report, nb.kernel;
                                            restale_racers = _parallel_enabled(nb))
            a || b
        end
        if refined
            lock(nb.lock) do; nb.version += 1; end
            _broadcast(nb, string(nb.version))   # version token → browser re-pulls the precise-graph state
        end
    catch e
        @warn "slate async runner error" notebook = nb.id exception = (e, catch_backtrace())
    finally
        lock(_RUNNER_LOCK) do; delete!(_RUNNERS, nb.id); end
        # Re-arm if work appeared between our last empty check and clearing the flag.
        again = lock(nb.lock) do; _next_stale_cell(nb.report) !== nothing; end
        again && _ensure_runner!(nb)
    end
    return nothing
end

# Start the runner if one isn't already draining (idempotent). Announces the batch size for the k/N pill.
function _ensure_runner!(nb::LiveNotebook)
    started = lock(_RUNNER_LOCK) do
        get(_RUNNERS, nb.id, false) && return false
        _RUNNERS[nb.id] = true; return true
    end
    started || return nothing
    Threads.@spawn _run_loop!(nb)        # the loop emits the live run-batch size each iteration
    return nothing
end

# Kick the runner; optionally BLOCK (no lock held) until a specific cell finishes, or until the whole
# notebook drains (wait_for=""+wait_all). Callers that need a synchronous result (the agent tools,
# startup/restore) wait; interactive UI paths don't (results stream over SSE).
function _eval!(nb::LiveNotebook; wait_for::AbstractString = "", wait_all::Bool = false)
    # Refresh the pill's pending count NOW (e.g. a cell queued while a long cell is mid-run, before
    # the runner reaches its next iteration), so the k/N updates immediately rather than at 1/1.
    p = lock(nb.lock) do; count(c -> c.state in (STALE, RUNNING), nb.report.cells); end
    p > 0 && _emit_pending(nb, p)
    _ensure_runner!(nb)
    (isempty(wait_for) && !wait_all) && return nb
    while true
        done = lock(nb.lock) do
            if !isempty(wait_for)
                i = _index_of(nb.report.cells, wait_for)
                return i === nothing || nb.report.cells[i].state in (FRESH, ERRORED)
            end
            return _next_stale_cell(nb.report) === nothing
        end
        if done
            wait_all || return nb
            # wait_all also waits for the runner task itself to clear (so callers can persist after).
            lock(_RUNNER_LOCK) do; get(_RUNNERS, nb.id, false); end || return nb
        end
        sleep(0.02)
    end
end

# Wait for the notebook to fully drain (no stale cells, runner idle).
_drain!(nb::LiveNotebook) = _eval!(nb; wait_all = true)

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
    # A cell reads a CHANGED def if a read matches a changed name directly, OR the read is a
    # QUALIFIED path (`SlateTest.Sub.greet`) whose leaf (`greet`) changed — reads record the
    # whole dotted path, while the worker reports the leaf def-name.
    _reads_changed(c) = any(c.reads) do r
        r in syms && return true
        s = string(r); i = findlast('.', s)
        i !== nothing && Symbol(SubString(s, nextind(s, i))) in syms
    end
    staled = Set{String}()
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            # Both code AND markdown join the reactive graph via `reads` (md from its {{ }}
            # free vars), and eval_stale! re-renders stale md — so include both.
            _reads_changed(c) || continue
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
#
# Each snapshot carries a human LABEL describing the op it precedes ("paste 3 cells",
# "delete cell", …) so the UI can say "Undo paste 3 cells" / toast "Undid cut 2 cells".
# The labels ride PARALLEL stacks keyed by nb.id (module-level, Revise-friendly — same pattern
# as the build-floor state), kept in lockstep with nb.undo/nb.redo by the three functions below
# (the only places that touch those stacks). A label travels with its snapshot across the stacks
# so a redo re-announces the same action.
const _UNDO_LBL = Dict{String,Vector{String}}()
const _REDO_LBL = Dict{String,Vector{String}}()
# These label dicts are MODULE-GLOBAL and shared across every open notebook AND the SSE / `/state`
# readers (`undo_label`/`redo_label`). Concurrent access is real: a `/state` read on one notebook can
# race a `_snapshot!` write on another, and an unguarded `get!`/`push!` on the same Dict corrupts its
# internal storage (UndefRefError → every `/state` 500s until restart). So ALL access goes through this
# lock, held only for the O(1) stack op — never across an eval/restore.
const _LBL_LOCK = ReentrantLock()
_lblstack(d, nb::LiveNotebook) = get!(() -> String[], d, nb.id)   # ONLY call while holding _LBL_LOCK
undo_label(nb::LiveNotebook) = lock(_LBL_LOCK) do
    s = _lblstack(_UNDO_LBL, nb); isempty(s) ? "" : last(s)
end
redo_label(nb::LiveNotebook) = lock(_LBL_LOCK) do
    s = _lblstack(_REDO_LBL, nb); isempty(s) ? "" : last(s)
end

function _snapshot!(nb::LiveNotebook; label::AbstractString = "change")
    push!(nb.undo, serialize_report(nb.report))
    lock(_LBL_LOCK) do
        push!(_lblstack(_UNDO_LBL, nb), String(label))
        if length(nb.undo) > 100
            popfirst!(nb.undo); ul = _lblstack(_UNDO_LBL, nb); isempty(ul) || popfirst!(ul)
        end
        empty!(nb.redo); empty!(_lblstack(_REDO_LBL, nb))
    end
end

function _restore!(nb::LiveNotebook, src::AbstractString)
    update_source!(nb.report, src)
    _eval!(nb)
    _persist!(nb; source = "restore")
end

# Returns the label of the action just undone (""/no-op when the stack is empty).
function undo!(nb::LiveNotebook)
    isempty(nb.undo) && return ""
    lbl = lock(_LBL_LOCK) do
        l = (ul = _lblstack(_UNDO_LBL, nb); isempty(ul) ? "change" : pop!(ul))
        push!(nb.redo, serialize_report(nb.report)); push!(_lblstack(_REDO_LBL, nb), l)
        l
    end
    _restore!(nb, pop!(nb.undo))
    return lbl
end

# Returns the label of the action just redone (""/no-op when the stack is empty).
function redo!(nb::LiveNotebook)
    isempty(nb.redo) && return ""
    lbl = lock(_LBL_LOCK) do
        l = (rl = _lblstack(_REDO_LBL, nb); isempty(rl) ? "change" : pop!(rl))
        push!(nb.undo, serialize_report(nb.report)); push!(_lblstack(_UNDO_LBL, nb), l)
        l
    end
    _restore!(nb, pop!(nb.redo))
    return lbl
end


include("server_history.jl")
include("server_agentops.jl")
include("server_sse_import.jl")
include("server_agentsessions.jl")
include("server_docs.jl")
include("server_snapshots.jl")
include("slate_api.jl")        # Slate notebook-API registry (SSOT for the api tool, search, prompt)
include("echarts_docs.jl")     # curated ECharts option reference, mapped to the DSL, indexed for search
include("server_export.jl")
include("publish_targets.jl")  # PublishTarget adapters (github-pages, generic-upload) + multi-target fan-out
include("publish_zenodo.jl")   # Zenodo archival target — versioned citable DOI
include("server_hub.jl")
include("server_publish.jl")   # Publishing manager service layer (ledger view, targets, secrets, SSE publish)
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

# Poll the running hub until it answers HTTP so the "it's live" banner is honest (the server is
# listening the moment `start_hub` returns, but a first request may still be warming up). Best-effort:
# give up after `timeout` seconds and show the banner anyway. `status < 500` = the route is up.
function _await_http_ready(url::AbstractString; timeout::Real = 10)
    t0 = time()
    while time() - t0 < timeout
        try
            r = HTTP.get(url; retry = false, redirect = false, status_exception = false, request_timeout = 2)
            r.status < 500 && return true
        catch
        end
        sleep(0.15)
    end
    return false
end

# A prominent, framed "your notebook is live" banner with the openable URL emphasized (bold + underline,
# the terminal's default hyperlinking makes it clickable). Printed once the hub answers HTTP.
function _print_ready_banner(url::AbstractString; logpath::AbstractString = "")
    rule = "─"^72
    printstyled("\n", rule, "\n"; color = :green)
    printstyled("  ✓  Your Kaimon Slate notebook is live\n\n"; color = :green, bold = true)
    print("      →  ")
    printstyled(url; color = :cyan, bold = true, underline = true)
    print("\n\n  Open the link above in a browser. Press q or Ctrl-C here to stop the server.\n")
    if !isempty(logpath)
        print("  Detailed server log: ")
        printstyled(logpath, "\n"; color = :light_black)
    end
    printstyled(rule, "\n\n"; color = :green)
    flush(stdout)
end

# ── Standalone console hygiene ─────────────────────────────────────────────────
# In the run.jl / serve_notebook path the console is the USER's surface: after the
# ready banner it should stay quiet unless something is genuinely wrong. Everything
# else (worker spawns, browser connects, slow-request warnings, …) goes — with full
# detail — to a log file in the same tmp dir as the worker logs; the banner says
# where. Errors still reach the console (forwarded to the original logger).
struct _FileDemuxLogger <: Logging.AbstractLogger
    io::IO
    console::Logging.AbstractLogger
end
Logging.min_enabled_level(::_FileDemuxLogger) = Logging.Info
Logging.shouldlog(::_FileDemuxLogger, args...) = true
Logging.catch_exceptions(::_FileDemuxLogger) = true
function Logging.handle_message(l::_FileDemuxLogger, lvl, msg, _mod, grp, id, file, line; kw...)
    try
        ts = Dates.format(Dates.now(), "HH:MM:SS")
        println(l.io, "[", ts, "] ", lvl, ": ", msg,
                isempty(kw) ? "" : string("  (", join(["$k=$(repr(v))" for (k, v) in kw], ", "), ")"))
        flush(l.io)
    catch
    end
    lvl >= Logging.Error &&
        Logging.handle_message(l.console, lvl, msg, _mod, grp, id, file, line; kw...)
    return nothing
end

# Open `url` in the viewer's default browser, best-effort. This is what makes a Windows double-click
# (run.bat → run.ps1 → run.jl) actually land in a browser rather than a bare console. Cross-platform:
# `start` on Windows, `open` on macOS, `xdg-open` on Linux. Opt out with KAIMONSLATE_NO_OPEN=1 (e.g.
# a headless/CI serve). Never fatal — if it fails, the printed URL still stands.
function _open_in_browser(url::AbstractString)
    get(ENV, "KAIMONSLATE_NO_OPEN", "0") == "1" && return false
    try
        cmd = Sys.iswindows() ? `cmd /c start "" $url` :
              Sys.isapple()   ? `open $url` :
                                `xdg-open $url`
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
        return true
    catch
        return false
    end
end

"""
    serve_notebook(path; host="127.0.0.1", port=8765, quiet=true)

Open the notebook at `path` in a hub and serve it. **Blocks** until stopped (Ctrl-C shuts the hub
and its workers down cleanly). Once the hub is answering HTTP, prints a framed banner with the
openable notebook URL (so a launcher like `run.jl` surfaces a ready, clickable link rather than a
bare port). With `quiet=true` (default) the console stays clean after the banner: the hub's log
detail (worker spawns, connects, warnings) goes to a file in the same tmp dir as the worker logs —
the banner shows the path; only errors still print.
"""
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765, quiet::Bool = true)
    # Swap the logger BEFORE anything spawns so worker-spawn infos land in the file.
    logpath = joinpath(tempdir(), "kaimonslate", "hub-$port.log")
    logio = nothing
    prevlogger = nothing
    if quiet
        try
            mkpath(dirname(logpath))
            # Private perms: the hub log records request/worker detail; keep other local users out.
            Sys.isunix() && (try; chmod(dirname(logpath), 0o700); catch; end)
            logio = open(logpath, "a")
            Sys.isunix() && (try; chmod(logpath, 0o600); catch; end)
            println(logio, "── serve_notebook  $(Dates.now())  $path ──")
            prevlogger = Logging.global_logger(_FileDemuxLogger(logio, Logging.global_logger()))
        catch
            logio = nothing                  # log hygiene must never block serving
        end
    end
    h = start_server(path; host = host, port = port)
    id = isempty(h.notebooks) ? "" : first(keys(h.notebooks))
    url = "$(_hub_url(h))/n/$id"
    _await_http_ready(_hub_url(h))          # wait until the server actually answers before announcing it
    _print_ready_banner(url; logpath = logio === nothing ? "" : logpath)
    _open_in_browser(url)                    # best-effort: land a double-click launch straight in a browser
    # Block until stopped — and make Ctrl-C actually stop it. Signals are a dead end
    # here (verified against a live hub): once the threaded HTTP listener runs, a
    # SIGINT is never delivered into this process at all in a `julia -e` run — ^C was
    # simply ignored, the hub kept serving and respawning the workers the terminal's
    # process-group SIGINT had killed. So do what Kaimon's headless server does: raw
    # mode turns ISIG off and ^C arrives as a plain BYTE (0x03) on stdin — read it,
    # tear down gracefully in a normal task context, and leave via `_exit` (Julia's
    # threaded exit machinery is itself wedge/crash-prone in this process). The
    # non-tty / interactive fallback blocks on the server; a REPL ^C lands there as a
    # regular InterruptException.
    cleaned = Ref(false)
    cleanup = function ()
        cleaned[] && return
        cleaned[] = true
        try; stop_hub(h); catch; end         # server + SSE + every worker — nothing left to respawn
        # Route logging away from the file, then only FLUSH it — a `close` can block
        # forever on the stream lock if a dying task held it mid-write.
        prevlogger === nothing || (try; Logging.global_logger(prevlogger); catch; end)
        logio === nothing || (try; flush(logio); catch; end)
        println("\n  Kaimon Slate stopped.")
        return
    end
    if !isinteractive() && stdin isa Base.TTY
        _wait_for_ctrl_c()                   # ^C / q (or ^Q / stdin EOF) as a raw byte
        println("\n  Stopping the notebook server…")
        cleanup()
        _hard_exit(0)
    end
    try
        wait(h.server)
    catch e
        e isa InterruptException || rethrow()
        println("\n  Stopping the notebook server…")
    finally
        cleanup()
    end
    return h
end

# Immediate process exit that SKIPS Julia's threaded exit machinery (which wedges or
# crashes in this process; see serve_notebook): POSIX `_exit`, or `ExitProcess` on
# Windows (the bare CRT `_exit` symbol isn't reliably resolvable there).
_hard_exit(code::Integer) = @static if Sys.iswindows()
    ccall((:ExitProcess, "kernel32"), stdcall, Cvoid, (UInt32,), UInt32(code))
else
    ccall(:_exit, Cvoid, (Cint,), Cint(code))
end

# Block until the operator presses Ctrl-C (0x03), q, or Ctrl-Q (0x11), read as raw
# bytes with ISIG off — the reliable stand-in for SIGINT (never delivered to this
# process; see serve_notebook). Raw mode is the same libuv tty mode the Windows REPL
# uses, so this path works there too (processed input off → ^C arrives as data); if
# raw mode can't be set at all we just block, and ^C falls back to the platform's
# default console kill. Mirrors Kaimon's `_wait_for_quit_key`. EOF (stdin closed)
# also returns — a detached operator can stop the server by closing the input. Raw
# mode is re-asserted on a timer: anything else touching the tty (a spawned child
# inheriting it, a stty from the shell) can knock it back to cooked, which would
# turn ^C back into an undeliverable SIGINT.
function _wait_for_ctrl_c()
    term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "dumb"), stdin, stdout, stderr)
    ok = try; REPL.Terminals.raw!(term, true); true; catch; false; end
    ok || (try; wait(Condition()); catch; end; return nothing)
    keepraw = Timer(2.0; interval = 2.0) do _
        try; REPL.Terminals.raw!(term, true); catch; end
    end
    try
        while true
            b = try
                read(stdin, UInt8)
            catch e
                e isa EOFError && return nothing
                rethrow()
            end
            (b == 0x03 || b == 0x11 || b == UInt8('q') || b == UInt8('Q')) && return nothing
        end
    finally
        close(keepraw)
        try; REPL.Terminals.raw!(term, false); catch; end
    end
end

end # module NotebookServer
