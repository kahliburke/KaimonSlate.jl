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
import Tar
import Typst_jll
import Pkg
using ..ReportEngine
using ..ReportRender

include("history.jl")   # module SlateHistory — durable content-addressed time machine
include("parsched.jl")  # ParCell / par_blockers / run_scheduled — the parallel dataflow scheduler

export serve_notebook, start_server, stop_server, LiveNotebook
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub
export find_live, notebook_digest, agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!, agent_rename_cell!
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
        register_progress!(r.id, c -> _broadcast_progress(nb, c))   # stream per-cell run status to the UI
        register_runbatch!(r.id, n -> (try; _broadcast(nb, "runbatch:$n"); catch; end))
        register_userprog!(r.id, (frac, msg, id, done) -> (try; _broadcast(nb, "cellprog:" * JSON.json(Dict("frac" => frac, "msg" => msg, "id" => id, "done" => done))); catch; end))
        register_celldone!(r.id, (run_id, cid, wire) -> server_celldone(nb, run_id, cid, wire))   # parallel-batch result merge
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
    # Async cells call `slate_refresh(:x)` → recompute readers of x + push live.
    register_refresh!(r.id, vars -> server_refresh(nb, vars))
    register_srcchange!(r.id, (names, err) -> server_src_changed(nb, names, err))   # parent /src reloaded (Revise)
    register_progress!(r.id, c -> _broadcast_progress(nb, c))   # stream per-cell run status to the UI
    register_runbatch!(r.id, n -> (try; _broadcast(nb, "runbatch:$n"); catch; end))   # run size → stable k/N
    register_userprog!(r.id, (frac, msg, id, done) -> (try; _broadcast(nb, "cellprog:" * JSON.json(Dict("frac" => frac, "msg" => msg, "id" => id, "done" => done))); catch; end))
    register_celldone!(r.id, (run_id, cid, wire) -> server_celldone(nb, run_id, cid, wire))   # parallel-batch result merge
    _load_chat_log!(nb)                  # restore any prior agent transcript (survives server restart)
    @async begin
        try
            kernel = _select_kernel(path, r)         # boot the (gate) worker
            lock(nb.lock) do; nb.kernel = kernel; nb.version += 1; end
            try; _broadcast(nb, string(nb.version)); catch; end   # worker is up → refresh the dot to "connected" BEFORE the (possibly long) run, so it's not stale
            lock(nb.lock) do
                _eval!(nb)                           # initial full run (streams cells via the async runner)
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
        rc.fresh && _instantiate_env!(rc.dir)
        kernel = GateKernel(rc.dir; parent = "", envdir = rc.dir)
        lock(nb.lock) do
            nb.kernel = kernel
            delete!(nb.report.meta, "preview")       # live cells supersede the frozen render
            delete!(nb.report.meta, "hydrating")
            _eval!(nb)                               # run everything in the reconstructed env (async runner)
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
            c.kind == CODE || continue
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
        cells = [cell_json(c, bindref, hostednames; nbid = nb.id) for c in nb.report.cells if c.id in changed]
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
            _broadcast(nb, "celldone:" * JSON.json(cell_json(cell, bindref, hostednames; nbid = nb.id)))
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
        m = (key = ReportEngine._memo_key(nb.report, cell),
             names = String[string(w) for w in cell.writes],
             threshold = ReportEngine._MEMO_THRESHOLD_MS)
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
        ss = [ParCell(c.id, copy(c.deps), copy(c.reads), copy(c.writes),
                      (:opaque in c.flags) || _cell_defines(c)) for c in code]
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
        _broadcast_progress(nb, c)
    end
    return nothing
end

function _run_loop!(nb::LiveNotebook)
    try
        while true
            # Parallel fast-path: hand all stale code cells to the worker at once (opt-in). Falls through
            # to the serial step for markdown, reactive restales, and the 0/1-code-cell case.
            if _parallel_enabled(nb) && _run_code_batch!(nb)
                continue
            end
            target, pending = lock(nb.lock) do
                t = _next_stale_cell(nb.report)
                t, count(c -> c.state in (STALE, RUNNING), nb.report.cells)
            end
            target === nothing && break
            _emit_pending(nb, pending)          # k/N pill: PENDING (stale+running); frontend adds done
            _eval_one!(nb, target)
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
_lblstack(d, nb::LiveNotebook) = get!(() -> String[], d, nb.id)
undo_label(nb::LiveNotebook) = (s = _lblstack(_UNDO_LBL, nb); isempty(s) ? "" : last(s))
redo_label(nb::LiveNotebook) = (s = _lblstack(_REDO_LBL, nb); isempty(s) ? "" : last(s))

function _snapshot!(nb::LiveNotebook; label::AbstractString = "change")
    push!(nb.undo, serialize_report(nb.report))
    push!(_lblstack(_UNDO_LBL, nb), String(label))
    if length(nb.undo) > 100
        popfirst!(nb.undo); ul = _lblstack(_UNDO_LBL, nb); isempty(ul) || popfirst!(ul)
    end
    empty!(nb.redo); empty!(_lblstack(_REDO_LBL, nb))
end

function _restore!(nb::LiveNotebook, src::AbstractString)
    update_source!(nb.report, src)
    _eval!(nb)
    _persist!(nb; source = "restore")
end

# Returns the label of the action just undone (""/no-op when the stack is empty).
function undo!(nb::LiveNotebook)
    isempty(nb.undo) && return ""
    lbl = (ul = _lblstack(_UNDO_LBL, nb); isempty(ul) ? "change" : pop!(ul))
    push!(nb.redo, serialize_report(nb.report)); push!(_lblstack(_REDO_LBL, nb), lbl)
    _restore!(nb, pop!(nb.undo))
    return lbl
end

# Returns the label of the action just redone (""/no-op when the stack is empty).
function redo!(nb::LiveNotebook)
    isempty(nb.redo) && return ""
    lbl = (rl = _lblstack(_REDO_LBL, nb); isempty(rl) ? "change" : pop!(rl))
    push!(nb.undo, serialize_report(nb.report)); push!(_lblstack(_UNDO_LBL, nb), lbl)
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
