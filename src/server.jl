"""
    NotebookServer

The live, interactive notebook backend (interactivity layer 1). Holds a notebook
bound to a `.jl` file and serves a browser SPA plus a small JSON API. Editing a
cell reconciles → reactively recomputes only stale cells → persists back to the
`.jl` (so the agent and the browser share one source). Runs CLI-side, wrapping
the engine (`ReportEngine`) and per-cell renderer (`ReportRender`).
"""
module NotebookServer

using HTTP, JSON, FileWatching, CodecZlib, CodecZstd
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
import ..EffectStore
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
    frontend::Vector{@NamedTuple{id::String, js::String, esm::Bool, kind::String}}  # package-declared front-end
                                         # scripts, refreshed once per drain from the worker's SlateExtensionsBase
                                         # manifest (`_refresh_extensions!`); sticky within a session, id-deduped,
                                         # declaration order. `esm` ⇒ ES module; non-empty `kind` ⇒ a component whose
                                         # default export Slate wraps + registers. See `_frontend_scripts`.
    assets::Dict{String,String}          # package-vendored asset DIRECTORIES (pkg → absolute dir on disk), from the
                                         # same manifest (`provide_assets!`). Served at `/ext-assets/<pkg>/…` while the
                                         # package is loaded, and copied into a static export. See `_register_assets!`.
    # Inner constructor takes the original 13 fields and starts empty scratchpad + frontend/asset registries, so every
    # existing positional call site (server + tests) is unchanged; all are populated at runtime.
    LiveNotebook(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents) =
        new(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents,
            Cell[], @NamedTuple{id::String, js::String, esm::Bool, kind::String}[], Dict{String,String}())
end

# ── Notebook-lock protocol (`nb.lock`) ─────────────────────────────────────────────────────────────
# `nb.lock` serializes access to a notebook's in-memory `nb.report` (cells, deps, meta, version, the
# `kernel` field) — UI actions vs. the async runner vs. agent ops.
#
# THE INVARIANT: never hold `nb.lock` across a KERNEL round-trip or a BLOCKING call. Take the lock only
# to READ or MUTATE the report; do worker work (`prepare!`, `eval_cell!`, `refine_*`, `resolve_*`,
# `_module_exports`, `_dep_versions`, `cancel_eval`, …) and anything that blocks (network / subprocess /
# `wait` / `fetch`) OUTSIDE the lock, then RE-take the lock to apply the result. Holding the lock across a
# worker call is the teardown-deadlock hazard: a remote round-trip — or even a cold first-run compile of
# the callee — pins the lock while another task (teardown, a UI request) waits on it, and the whole hub
# wedges. The three-phase resolve→(unlocked kernel)→rebuild dance in `_run_loop!` is the reference.
#
# `with_report(nb) do report … end` is the ONE sanctioned way to take `nb.lock`. The closure is handed
# `report`, NOT `nb`, so reaching for `nb.kernel` (a round-trip) inside is a visible smell, not the
# default. `@report_op` adds a compile-time guard (below).
@inline with_report(f, nb::LiveNotebook) = lock(() -> f(nb.report), nb.lock)

# Kernel round-trip / blocking-boundary calls that must NEVER run while `nb.lock` is held.
const _KERNEL_BOUNDARY = Set{Symbol}((:prepare!, :eval_cell!, :eval_stale!, :_eval!, :_eval_one!,
    :_run_code_batch!, :refine_usings!, :refine_macros!, :resolve_usings!, :resolve_macros!,
    :_module_exports, :_dep_versions, :cancel_eval, :shutdown!))

# Scan an expression for a synchronous call to a boundary symbol (`f(…)` or `Mod.f(…)`). Skips
# `@async`/`@spawn` and `quote` subtrees — work scheduled there runs LATER, not under the held lock —
# so only calls that actually execute inside the locked region are flagged. Returns the Symbol or nothing.
function _find_boundary_call(ex)
    ex isa Expr || return nothing
    (ex.head === :quote) && return nothing
    if ex.head === :macrocall
        m = ex.args[1]
        (m === Symbol("@async") || m === Symbol("@spawn") || m === Symbol("@spawnat")) && return nothing
    end
    if ex.head === :call
        f = ex.args[1]
        fn = f isa Symbol ? f :
             (f isa Expr && f.head === :. && length(f.args) == 2 && f.args[2] isa QuoteNode ? f.args[2].value : nothing)
        fn isa Symbol && fn in _KERNEL_BOUNDARY && return fn
    end
    for a in ex.args
        r = _find_boundary_call(a)
        r === nothing || return r
    end
    return nothing
end

"""
    @report_op nb report begin … end

Guarded `with_report`: take `nb.lock`, bind `report = nb.report`, run the body — and at macro-expansion
REJECT any direct kernel round-trip / blocking call inside the locked region (see `_KERNEL_BOUNDARY`),
so the notebook-lock invariant can't be broken by a direct call (it would have caught the post-drain
`refine_usings!` bug). Indirect calls through a helper still rely on the protocol + review.
"""
macro report_op(nb, report, body)
    bad = _find_boundary_call(body)
    bad === nothing ||
        error("@report_op: `$bad` is a kernel round-trip / blocking call and must not run while nb.lock " *
              "is held — phase it out (read under lock → kernel work unlocked → re-lock to apply).")
    return quote
        with_report($(esc(nb))) do $(esc(report))
            $(esc(body))
        end
    end
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
    register_prepare!(nb.report.id, json -> (try; _broadcast(nb, "prepare:" * json); catch; end))   # env precompile progress → "Preparing packages" banner
    register_emit!(nb.report.id, (channel, payload) -> (try; _ws_emit!(nb, channel, payload); catch; end))   # slate_emit → push over the page WebSocket (NOT the coalescing SSE); payload is a Julia value, JSON-encoded in _ws_emit!
    register_bin_emit!(nb.report.id, frame -> (try; _ws_broadcast_bin!(nb, frame); catch; end))   # slate_emit_bin → forward the raw binary frame over the page WebSocket as-is
    register_celldone!(nb.report.id, (run_id, cid, wire) -> server_celldone(nb, run_id, cid, wire))   # parallel-batch result merge
    return nb
end
function _unwire_callbacks!(nb::LiveNotebook)
    unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id)
    unregister_progress!(nb.report.id); unregister_runbatch!(nb.report.id)
    unregister_userprog!(nb.report.id); unregister_emit!(nb.report.id); unregister_celldone!(nb.report.id)
    unregister_prepare!(nb.report.id); unregister_bin_emit!(nb.report.id)
    return nb
end

# GateKernel when running as the Kaimon extension AND the notebook is inside a
# Julia project (cells eval in a per-notebook worker); else in-process.
# Instantiate an env in a subprocess (isolated; best-effort). Blocking — used by the background
# hydrate on a fresh bundle reconstruction (the content-addressed cache makes every later open
# instant), so it never sits on the open path. `online` (optional): a `line::String -> nothing`
# callback fed the subprocess's stdout/stderr line-by-line as it precompiles — mirrors the
# remote-provision path's `_run_streamed`, so a slow first-run instantiate narrates itself into
# the boot banner instead of being silent for however long `Pkg.instantiate()` takes.
function _instantiate_env!(envdir::AbstractString; online = nothing,
                           code::AbstractString = "using Pkg; Pkg.instantiate()", quiet::Bool = true)
    jl = Base.julia_cmd()[1]
    ok = true
    try
        cmd = `$jl --project=$envdir --startup-file=no -e $code`
        if online === nothing
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        else
            out = Pipe()
            proc = run(pipeline(cmd; stdout = out, stderr = out); wait = false)
            close(out.in)
            for line in eachline(out)
                s = strip(line)
                isempty(s) || (try; online(String(s)); catch; end)
            end
            wait(proc)
            ok = success(proc)
        end
    catch
        ok = false
        quiet || rethrow()
    end
    return ok
end

# Rebuild a STALE or broken forked notebook env from its parent: re-seed via the shared policy
# (`seed_env_project!` — dev paths made absolute), then a subprocess `develop(parent)` + instantiate,
# with ONE reset-and-retry from the authoritative parent. The local mirror of the remote provisioner's
# self-healing `build_env!`, and the counterpart to the worker's in-process `_seed_notebook_env!` for
# when the worker can't run yet (a stale env would crash it at boot). Streams into the boot banner.
function _rebuild_notebook_env!(envdir::AbstractString, parent::AbstractString; online = nothing)
    build = function ()
        pname = ReportEngine.seed_env_project!(envdir, parent)
        dev = isempty(pname) ? "" :
              "Pkg.develop(Pkg.PackageSpec(path=raw\"$(parent)\"); preserve=Pkg.PRESERVE_ALL); "
        ok = _instantiate_env!(envdir; online = online, code = "using Pkg; $(dev)Pkg.instantiate()")
        ok && ReportEngine.stamp_env!(envdir, parent)
        return ok
    end
    if !build()
        # Reset the env + rebuild ONCE from the authoritative parent (a half-written / stale env dir
        # self-heals instead of wedging every future open — same policy as the remote provisioner).
        for f in ("Project.toml", "Manifest.toml"); try; rm(joinpath(envdir, f); force = true); catch; end; end
        build()
    end
    return envdir
end

# Self-contained `.jl`s are intercepted earlier in `load_notebook` (background hydrate against
# the depot cache), so this only handles ordinary notebooks: base / forked / detached.
function _select_kernel(path::AbstractString, report; threads::AbstractString = "", online = nothing)
    # `assetbase` — the `@asset` base, the datadir root, AND the target that dropped/pasted media attach
    # to — is derived for EVERY open, not just the gate path. Without it (e.g. an in-process hub with no
    # Kaimon gate), a notebook inside a project isn't recognised as one and media has nowhere to attach,
    # so it inlines as a huge base64 blob. Project ⇒ the project dir; detached ⇒ the per-notebook fork-env
    # dir (a stable location that resolves identically on the hub and every region worker). The gate
    # branches below re-affirm this with their own values; this makes the in-process path get it too.
    let proj = Base.current_project(dirname(abspath(path)))
        parent = proj === nothing ? "" : dirname(proj)
        report.meta["assetbase"] = isempty(parent) ? ReportEngine.notebook_env_dir(path) : parent
    end
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
            # The LOCAL env to REPLICATE on the remote so packages/dev-sources match exactly: the notebook's
            # own fork env (its added packages) when it has one, else the parent project. Empty ⇒ nothing to
            # replicate (bare notebook) — the worker just gets Slate's payload + KaimonGate.
            envdir = ReportEngine.notebook_env_dir(path)
            origin_env = isfile(joinpath(envdir, "Project.toml")) ? envdir :
                         (!isempty(parent) && isfile(joinpath(parent, "Project.toml")) ? parent : "")
            # Remote env dir keyed by the CONTENT it replicates (origin_env) or the parent project — a path
            # hash, so two unrelated notebooks (or a stale/failed provision) never share one mutable env and
            # poison each other. Truly bare (nothing to replicate) ⇒ the infra-only shared "detached".
            rproj = "~/.cache/kaimonslate/remote/" * ReportEngine._remote_env_key(origin_env, parent)
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
        envdir = ReportEngine.notebook_env_dir(path)
        # Base dir for `@asset "rel/path"` resolution + memo hashing AND the notebook's data root
        # (`datadir()`/`@sfile` → `<assetbase>/data`, matching the worker's PARENT_PROJECT). A DETACHED
        # notebook (no enclosing project) has no parent dir; anchor it to the per-notebook fork-env dir
        # — a stable location that resolves identically on the hub and every region worker, so `@sfile`
        # files content-sync to a remote region instead of silently living at a `pwd()/data` the datadir
        # sync never sees. Runtime-derived (absolute, machine-specific) → meta, never the `.jl` footer.
        report.meta["assetbase"] = isempty(parent) ? envdir : parent
        env_exists = isfile(joinpath(envdir, "Project.toml"))   # the fork is materialised on first add
        delta = get(report.meta, "env", Dict{String,Any}[])     # footer-recorded notebook packages
        # Per-notebook worker-thread override: explicit `threads` arg wins, else a persisted
        # meta["threads"] (set at a prior open / footer), else "" → the kernel falls back to the global.
        th = isempty(threads) ? String(get(report.meta, "threads", "")) : String(threads)
        # Per-notebook extra Julia flags (e.g. "--gcthreads=4,1"), persisted via the config panel
        # (meta["juliaflags"]); "" → the kernel falls back to the global (panel/slate.json) / env.
        ef = String(get(report.meta, "juliaflags", ""))
        lbl = basename(abspath(path))   # gate-session display label: the notebook's filename
        if !env_exists && !isempty(delta)
            # The `.jl` records package adds but the env dir is gone (e.g. a fresh git clone):
            # reconstruct it from the footer on first use (pending). Only `mkdir` here — the
            # Project.toml is written by the reconstruction itself, so a worker that never ran
            # leaves the env "absent" and reconstruction retries on the next open.
            mkpath(envdir)
            return GateKernel(envdir; parent = parent, envdir = envdir, pending = delta, threads = th, extra_flags = ef, label = lbl, online = online)
        elseif parent == ""
            # Detached: the notebook env IS the whole world (everything is a "notebook add").
            ReportEngine.ensure_notebook_env!(envdir)
            return GateKernel(envdir; parent = "", envdir = envdir, threads = th, extra_flags = ef, label = lbl, online = online)
        elseif env_exists
            # Already has its own packages → run in the forked env (extends the parent). But first, if
            # the PARENT changed since this fork was seeded (a dep added, a re-resolve — e.g. an
            # extension package that gained a dependency), REBUILD it: a stale fork would crash the
            # worker at boot on `using` a dep the fork never received. Self-healing, before spawn.
            if ReportEngine.env_stale(envdir, parent)
                ReportEngine._rlog("_select_kernel: notebook env stale vs parent → rebuilding $(basename(envdir))")
                _rebuild_notebook_env!(envdir, parent; online = online)
            end
            return GateKernel(envdir; parent = parent, envdir = envdir, threads = th, extra_flags = ef, label = lbl, online = online)
        else
            # Base mode: no notebook-specific packages yet → run directly in the parent.
            return GateKernel(parent; parent = parent, envdir = envdir, threads = th, extra_flags = ef, label = lbl, online = online)
        end
    end
    return InProcessKernel()
end

function load_notebook(path::AbstractString; id::AbstractString = "", threads::AbstractString = "",
                       runon::AbstractString = "", autorun::Bool = true, inactive::Bool = false)
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
    _reestablish_effects!(r)   # durable declared-effects: re-mark EVERYWHERE cells before any run (cold-start safe)
    _note_server_write!(rid, hash(serialize_report(r)))   # the as-opened state is OURS — a watcher
                                                          # tick reading it must not "revert" to it
    # Any self-contained `.jl`: open INSTANTLY and reconstruct + run the env in the BACKGROUND
    # (hydrate), so a heavy bundle never blocks the open. If it embeds a frozen render that's
    # shown meanwhile; otherwise the cells show un-run until they go live. This is the single
    # path for opening a standalone — "Run (temporary)" is just a normal open.
    if ReportEngine.gate_available() && _has_bundle(src)
        p = _read_preview(src)
        p === nothing || (r.meta["preview"] = p)
        nb = LiveNotebook(nbid, String(path), r, PendingKernel(), 0, String[], String[],
                          ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                          Dict{String,String}())
        _wire_callbacks!(nb)
        _load_chat_log!(nb)
        if inactive
            # INACTIVE open (the download/upload default): show the embedded frozen render and spawn
            # NOTHING — no worker, no env reconstruct, no precompile, no resource access. The static
            # preview is exactly what the exported page already showed; a grey "Inactive — click to
            # launch" pill defers the (possibly heavy) bring-up to `/api/launch` → `_hydrate_standalone!`,
            # which is the moment the notebook becomes live + interactive. See `launch`/`state_json`.
            r.meta["inactive"] = true
        else
            r.meta["hydrating"] = true
            @async _hydrate_standalone!(nb, String(path))   # reconstruct + run live, then push
        end
        return nb
    end
    # Open INSTANTLY: hand the browser the notebook with cells un-run and boot the kernel + do the
    # initial full run in the BACKGROUND, pushing results live as they land (same hydrate pattern as
    # a self-contained `.jl`). A heavy notebook — slow worker boot, long-running cells — no longer
    # blocks the user from getting in. The `hydrating` flag tells the UI a background run is underway.
    # `autorun=false` (the "open paused" escape hatch): still boots the kernel — editing/completion
    # want it live — but skips the initial run, so cells land STALE and untouched. The point is to
    # get INTO the notebook (e.g. to tag a cell `locked` first) before anything expensive runs; a
    # manual ▶/"Run stale" starts it whenever the user is ready.
    #
    # Interim render: if we persisted a snapshot of this notebook's last rendered figures, show it
    # AT ONCE while the worker boots + the initial run recomputes — the notebook springs to life
    # instead of showing every cell un-run. Marked entries carry a stored/stale badge; live cells
    # supersede them cell-by-cell (state_json's hydrating branch serves meta["preview"]).
    let p = _load_preview_marked(path, r)
        p === nothing || (r.meta["preview"] = p)
    end
    nb = LiveNotebook(nbid, String(path), r, PendingKernel(), 0, String[], String[],
                      ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                      Dict{String,String}())
    _wire_callbacks!(nb)
    _load_chat_log!(nb)                  # restore any prior agent transcript (survives server restart)
    if inactive
        # INACTIVE open of a plain notebook: show the last-rendered preview (if any) and boot NOTHING —
        # a grey "Inactive — click to launch" pill defers the (possibly heavy) worker spawn + run to
        # `launch_notebook!`. Distinct from `autorun=false`, which still boots the worker (editing/
        # completion want it live) and only skips the initial run.
        r.meta["inactive"] = true
    else
        # `hydrating` (+`hydratingKind="boot"`) is set regardless of `autorun` — a cold worker spawn can
        # be a multi-minute precompile that was invisible before (looked identical to a hang). It gates
        # nothing (editing works immediately via `PendingKernel`); it's a status banner narrating the
        # boot via the same `bringup:` stream the remote-provision path uses.
        r.meta["hydrating"] = true
        r.meta["hydratingKind"] = "boot"
        _boot_and_run!(nb; autorun = autorun)
    end
    return nb
end

# Boot `nb`'s worker (cold spawn / remote attach) and, when `autorun`, run the initial full pass — all
# in the BACKGROUND, streaming boot progress + results live. The plain-notebook counterpart to
# `_hydrate_standalone!` (which reconstructs a bundle env first). Shared by `load_notebook` (live open)
# and `launch_notebook!` (launching a notebook that was opened inactive). Assumes `nb.kernel` is the
# PendingKernel placeholder installed at open, and `hydrating`/`hydratingKind="boot"` are already set.
function _boot_and_run!(nb::LiveNotebook; autorun::Bool = true)
    pending = nb.kernel
    path = nb.path
    r = nb.report
    @async begin
        try
            # `online`: a cold local spawn's stdout/stderr streamed line-by-line into the boot banner
            # (see GateKernel.online / _spawn_worker! in gate_kernel.jl); a no-op for InProcessKernel,
            # an already-running remoteworker attach, or a remote-SPAWN (which already narrates itself
            # via `_bringup_note`/`_run_streamed` on its own "remote" hydratingKind).
            kernel = _select_kernel(path, r; online = line -> (try; _broadcast(nb, "bringup:" * line); catch; end))
            lock(nb.lock) do; nb.kernel = kernel; nb.version += 1; end
            pending isa PendingKernel && ReportEngine._resolve!(pending, kernel)   # unblock anyone who raced the boot window
            if autorun
                lock(nb.lock) do; delete!(nb.report.meta, "hydratingKind"); end   # boot done → falls back to the (bannerless) "run" default
                try; _broadcast(nb, string(nb.version)); catch; end   # worker is up → refresh the dot to "connected" BEFORE the (possibly long) run, so it's not stale
                _drain!(nb)                          # initial full run — WAIT for it to fully complete, so
                                                     # `hydrating` stays up for it (no banner though, see above)
                lock(nb.lock) do
                    delete!(nb.report.meta, "hydrating")
                    delete!(nb.report.meta, "hydratingKind")
                    delete!(nb.report.meta, "preview")   # live cells now stand — drop the interim render
                    nb.version += 1
                end
                # Capture the freshly-run state as the next reopen's interim preview (force past the debounce).
                _save_preview!(nb; force = true)
                # Seed the durable history with the initial run state, so the first edit has a parent to
                # diff against and the "buildup" replay starts from the true origin.
                _history!(nb; source = "open")
            else
                # Boot's done and there's no run phase to narrate — drop hydrating now rather than
                # leaving a banner up with nothing left to report.
                lock(nb.lock) do
                    delete!(nb.report.meta, "hydrating")
                    delete!(nb.report.meta, "hydratingKind")
                    nb.version += 1
                end
                try; _broadcast(nb, string(nb.version)); catch; end
                # A fresh process has nothing in memory, so cells parse STALE like everything else —
                # but a locked cell's restore is a near-instant memo hit, not the expensive re-run
                # `autorun=false` exists to avoid.
                _self_heal_locked!(nb)
            end
            _autoindex!(nb)                          # background: index project deps + used packages' docs
        catch e
            lock(nb.lock) do
                nb.report.meta["hydrate_error"] = sprint(showerror, e)
                delete!(nb.report.meta, "hydrating")
                delete!(nb.report.meta, "hydratingKind")
                nb.version += 1
            end
            pending isa PendingKernel && pending.real === nothing && pending.err === nothing &&
                ReportEngine._reject!(pending, "notebook failed to start: " * sprint(showerror, e))
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
    pending = nb.kernel   # the PendingKernel placeholder installed by load_notebook, unblocked below
    # The env reconstruct + precompile can run for minutes on a fresh machine — narrate it with the SAME
    # structured "Precompiling k/N · <pkg>" banner the local/remote worker boot uses, not just a raw log.
    # `hydratingKind="env"` guarantees the banner shows (a bundle with no embedded preview would otherwise
    # default hydratingKind to "run", which suppresses it). `online` runs each raw Pkg line through the
    # shared prepare classifier → a `prepare:` headline, and tucks the raw line into the collapsible log —
    # the piece the standalone path was missing (it precompiles in `_instantiate_env!`, outside the worker's
    # own `_prepare_env!` classifier, so without this only unstructured `bringup:` lines reached the banner).
    lock(nb.lock) do
        delete!(nb.report.meta, "inactive")   # launching supersedes the dormant state (defensive)
        nb.report.meta["hydratingKind"] = "env"
    end
    tr = ReportEngine.PrepareTracker(time())
    online = line -> begin
        s = strip(String(line)); isempty(s) && return nothing
        try
            (ReportEngine.prepare_feed!(tr, s) && ReportEngine.prepare_active(tr)) &&
                _broadcast(nb, "prepare:" * ReportEngine.prepare_json(tr))
        catch; end
        startswith(s, "@@SLATE_PREP") || (try; _broadcast(nb, "bringup:" * first(s, 200)); catch; end)
        return nothing
    end
    try
        rc = _reconstruct_bundle!(path)
        rc.fresh && _instantiate_env!(rc.envdir; online = online)
        # Embedded precomputed results → unpack into the local memo store BEFORE the drain, so the
        # expensive cells RESTORE instead of recompute (content-addressed: existing blobs are kept).
        # host-portable keys (manifest/src digests) make the exporter's fullkeys match here.
        try
            packed = _read_memo(read(path, String))
            if packed !== nothing
                n = MemoStore.unpack(_memo_root(), packed)
                n > 0 && ReportEngine._rlog("hydrate: unpacked $n memo files from the standalone bundle")
            end
        catch e
            @warn "KaimonSlate: embedded memo unpack failed (cells will recompute)" exception = (e, catch_backtrace())
        end
        kernel = GateKernel(rc.envdir; parent = rc.parent, envdir = rc.envdir, label = basename(abspath(path)),
                            online = online)
        lock(nb.lock) do
            nb.kernel = kernel
            # A durable INSTALL (SLATE_INSTALL_DIR) → serve the notebook FROM the installed project, so
            # edits save there (and land in its git checkout), not into the throwaway downloaded `.jl`.
            (rc.install && !isempty(rc.notebook) && isfile(rc.notebook)) && (nb.path = rc.notebook)
            delete!(nb.report.meta, "preview")       # live cells supersede the frozen render
        end
        pending isa PendingKernel && ReportEngine._resolve!(pending, kernel)   # unblock anyone who raced the boot window
        _drain!(nb)                                  # run everything + WAIT, so `hydrating` stays up for it
        lock(nb.lock) do
            delete!(nb.report.meta, "hydrating")
            nb.version += 1
        end
        _save_preview!(nb; force = true)             # freshly-run state → next reopen's interim preview
        _history!(nb; source = "open")
        _autoindex!(nb)
    catch e
        lock(nb.lock) do
            nb.report.meta["hydrate_error"] = sprint(showerror, e)
            delete!(nb.report.meta, "hydrating")
            nb.version += 1
        end
        pending isa PendingKernel && pending.real === nothing && pending.err === nothing &&
            ReportEngine._reject!(pending, "notebook failed to start: " * sprint(showerror, e))
    end
    try; _broadcast(nb, string(nb.version)); catch; end
    return nothing
end

# The shared body of a reactive push (a `@bind`/data/asset change): restale every cell the
# `seed_predicate` selects (the direct triggers), then their dependents, recompute, and broadcast a
# lightweight `refresh:` patch of ONLY the cells that recomputed — the browser patches just those
# (charts `setOption`, output swap) instead of pulling the whole state.
function _reactive_refresh!(nb::LiveNotebook, seed_predicate)
    msg = ""
    lock(nb.lock) do
        seed = String[]
        for c in nb.report.cells
            seed_predicate(c) || continue
            ReportEngine.restale!(c) && push!(seed, c.id)
        end
        isempty(seed) && return
        changed = Set(seed)
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing && continue
            ReportEngine.restale!(nb.report.cells[i]) && push!(changed, id)
        end
        _eval!(nb)
        bindref, hostednames = _bind_index(nb.report)
        bibctx = _bib_link_ctx(nb)
        figidx = figure_index(nb.report)
        cells = [cell_json(c, bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx, report = nb.report) for c in nb.report.cells if c.id in changed]
        msg = "refresh:" * JSON.json(Dict("cells" => cells))
    end
    isempty(msg) || _broadcast(nb, msg)
    return nothing
end

# Reactive push triggered by a cell's async task (`slate_refresh(:data, …)`): restale the cells that
# READ those vars (but NOT the producers that WRITE them, so we don't re-trigger the task). MARKDOWN
# readers seed too — a `{{ level[] }}` interpolation is a reader; md never writes, so the guard passes.
function server_refresh(nb::LiveNotebook, vars)
    syms = Set{Symbol}(vars)
    return _reactive_refresh!(nb, c -> !isdisjoint(c.reads, syms) && isdisjoint(c.writes, syms))
end

# Reactive push triggered by the asset watcher (`_start_asset_watcher!`): one or more `@asset`
# files a cell READS changed on disk → restale those cells + their dependents, recompute, and push
# the same lightweight `refresh:` patch as a `@bind` change. `changed` are absolute paths; a cell's
# `inputs` are notebook-relative (or absolute), resolved against `assetbase` (its project dir).
function server_asset_changed(nb::LiveNotebook, changed::Vector{String})
    base = String(get(nb.report.meta, "assetbase", ""))
    chset = Set{String}(changed)
    _resolve(rel) = isabspath(rel) ? String(rel) : (isempty(base) ? String(rel) : joinpath(base, rel))
    return _reactive_refresh!(nb, c -> any(rel -> _resolve(rel) in chset, c.inputs))
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
            _broadcast(nb, "celldone:" * JSON.json(cell_json(cell, bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx, report = nb.report)))
            # A cell just produced a result → refresh the interim-render preview sidecar (debounced),
            # so a later reopen springs to life showing the last-known figures. Best-effort.
            _save_preview!(nb)
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
const _RUNNER_FAILS = Dict{String,Int}()      # nb.id → consecutive runner failures; backs off + gives up so a
                                              # persistently-throwing drain can't re-arm in a tight loop (hub spin + log flood)
# Cooperative stop signal for `close_notebook!`: an id can be REUSED the instant the same file is
# reopened (once the old entry is gone from `h.notebooks`, `_unique_id` sees no conflict), but a
# runner's `Threads.@spawn` task isn't otherwise interruptible — without this, closing a notebook
# mid-drain orphans its task running forever against a torn-down `nb`, and it never clears
# `_RUNNERS[id]` (only the loop's own `finally` does that) — so the REOPENED notebook, same id,
# sees `_RUNNERS[id] == true` from the dead orphan and `_ensure_runner!` silently refuses to start
# a new one: every cell sits STALE forever even though the fresh worker is healthy and idle.
# Checked once per drain iteration (between cells, not mid-eval) — cheap and responsive enough.
const _RUNNER_CANCEL = Dict{String,Bool}()
# nb.id → epoch seconds a runner started — lets the supervisor sweep (`_reconcile_stale_runner!`)
# detect + self-heal a `_RUNNERS` entry that's survived implausibly long (a bug THIS fix hasn't
# anticipated, not just the close-race above, which `_RUNNER_CANCEL` already prevents) instead of
# leaving a notebook silently wedged until something notices and restarts the whole hub.
const _RUNNER_STARTED = Dict{String,Float64}()
const _RUNNER_STALE_HITS = Dict{String,Int}()         # nb.id → consecutive stuck-sweep confirmations
const _RUNNER_STALE_AFTER = 600.0                     # 10 min with pending work + no progress ⇒ suspect
const _RUNNER_STALE_CONFIRMATIONS = 3                 # consecutive 5s sweeps before self-healing (~15s)

# Per-notebook MAIN-kernel worker identity we last re-established (`_worker_key` = objectid + ns_gen). A
# worker swap (cold spawn / pool adopt / reprovision — never a reattach) bumps `k.ns_gen`, handing us a
# BLANK namespace mid-session where every global (imports, theme, @bind registrations) is gone while the
# cells still read FRESH. We detect the change (see `_reestablish_fresh_namespace!`) and re-establish; a
# reattach (same worker key) is a no-op. Same key the region layer uses, for the main kernel.
const _MAIN_GEN = Dict{String,UInt}()
const _MAIN_GEN_LOCK = ReentrantLock()

# Per-notebook mutex serialising WORKER EVALUATION: the runner's per-cell / per-batch steps take
# it, and so does any out-of-band eval (slate.eval scratch pokes). Without it a scratch eval can
# land on the worker CONCURRENTLY with a parallel cell batch and trip a `ConcurrencyViolationError`
# deep in shared non-thread-safe state (CairoMakie buffers, etc.). Uncontended on the common path
# (one runner, no scratch), so it adds only an atomic acquire per eval step.
const _EVAL_MUTEX = Dict{String,ReentrantLock}()
const _EVAL_MUTEX_LOCK = ReentrantLock()
_eval_mutex(nb::LiveNotebook) = lock(_EVAL_MUTEX_LOCK) do; get!(() -> ReentrantLock(), _EVAL_MUTEX, nb.id); end

# `locked` cells self-heal OUT OF DOCUMENT ORDER, ahead of whatever else is about to run: restoring a
# frozen key is a near-instant memo hit (no recompute), so it shouldn't have to wait behind slow
# unlocked cells queued in front of it in a normal document-order run — the whole point of locking is
# that its result is ALREADY available. Called before a full re-run kicks off (fresh open with
# `autorun=false`; a kernel restart, which wipes every cell to STALE before its own full `_drain!`).
# Best-effort per cell — one failure (e.g. a genuinely drifted key falling through to a real recompute
# that errors) doesn't stop the others.
function _self_heal_locked!(nb::LiveNotebook)
    # Snapshot targets UNDER nb.lock — the real runner (`_run_loop!`) is a `Threads.@spawn` task, true
    # OS-thread parallelism, so an unlocked read of `report.cells`/`c.flags` here would race its
    # mutations (a Set/Vector isn't safe to iterate on one thread while another mutates it — the kind
    # of race that can hang, not just misbehave). `_eval_one!` itself takes `nb.lock` internally per
    # cell, same as `_run_loop!`'s own `target = lock(nb.lock) do … end` before its `_eval_mutex` step.
    targets = lock(nb.lock) do
        [c for c in nb.report.cells
         if c.kind == CODE && c.state == STALE && :locked in c.flags && !isempty(ReportEngine._locked_key(c))]
    end
    for c in targets
        try
            lock(_eval_mutex(nb)) do; _eval_one!(nb, c); end
        catch e
            @warn "KaimonSlate: locked-cell self-heal failed" cell = c.id notebook = nb.id exception = e
        end
    end
    return nothing
end

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
    ran_on::String          # "" (never ran) | "local" | the region host — WHERE the last run executed
    xfer_bytes::Int         # session total: boundary bytes moved FOR this cell's inputs
    last_xfer::String       # latest boundary move, human-readable ("<name> <size> in <time> ← <host>")
end
CellStats() = CellStats(0, 0, 0, 0.0, 0.0, Inf, 0.0, Float64[], 0.0, 0.0, "", "", 0, "")
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
        d = Dict{String,Any}(
            "evals" => n, "restores" => s.restores, "pulls" => s.pulls,
            "total_ms" => r1(s.total_ms), "mean_ms" => r1(mean), "std_ms" => r1(sd),
            "min_ms" => n > 0 ? r1(s.min_ms) : 0.0, "max_ms" => r1(s.max_ms),
            "p50_ms" => r1(pct(0.5)), "p90_ms" => r1(pct(0.9)),
            "last_ms" => r1(s.last_ms), "last_ts" => r1(s.last_ts), "memo" => s.last_memo,
            "recent" => [r1(x) for x in s.recent])   # the raw ring — the stats card's sparkline
        # Region provenance (absent for a plain local notebook): where the last run executed and
        # what its inputs cost to move — the badges/stats the mental model needs (a user watched
        # their mutation "run locally" when it had auto-followed to the region; nothing said so).
        isempty(s.ran_on) || (d["ranOn"] = s.ran_on)
        s.xfer_bytes > 0 && (d["xferBytes"] = s.xfer_bytes)
        isempty(s.last_xfer) || (d["lastXfer"] = s.last_xfer)
        return d
    end
end

# Record where a cell just ran ("local" | region host) and any boundary move made for it —
# streamed to the browser inside cell_json["stats"] like every other stat.
function _stats_ran_on!(nb::LiveNotebook, cid::AbstractString, where::AbstractString)
    lock(_CELL_STATS_LOCK) do
        get!(CellStats, get!(Dict{String,CellStats}, _CELL_STATS, nb.id), String(cid)).ran_on = String(where)
    end
    return nothing
end
function _stats_xfer!(nb::LiveNotebook, cid::AbstractString, desc::AbstractString, bytes::Integer)
    lock(_CELL_STATS_LOCK) do
        s = get!(CellStats, get!(Dict{String,CellStats}, _CELL_STATS, nb.id), String(cid))
        s.xfer_bytes += Int(bytes)
        s.last_xfer = String(desc)
    end
    return nothing
end

# ── Region runner: `remote`-tagged cells run on a SECOND kernel ──────────────────────────────
# The notebook keeps its main kernel; cells tagged `remote` execute on a region kernel resolved
# from the durable `regionon` footer ("host[,transport[,port,stream]]" — same grammar as runon).
# Boundary values cross as content-addressed blobs (see ReportEngine.transfer_binding!): before a
# cell runs, any name it reads that was written on the OTHER kernel is shipped over — codec-picked
# (a DataFrame crosses as Arrow IPC) and deduped, so an unchanged value re-ships for one
# round-trip. Only the boundary crosses: a large frame produced AND queried remotely never moves;
# the small aggregate a local cell reads does. Pure `using` cells run on BOTH kernels (namespace
# parity); v1 rules: the main kernel should be local when a region is active, `@bind`-declaring
# cells stay local, cross-boundary MUTATION is undefined (same as the release-plan validity rule).
const _REGION_KERNELS = Dict{Tuple{String,String},Any}()   # (nb id, region name) → GateKernel
const _REGION_SYNCED = Dict{String,Dict{String,String}}()  # nb id → "side:name" → freshness token
const _REGION_PRIMED = Dict{Tuple{String,UInt},UInt}()     # (nb id, kernel objectid) → signature of primed `using` cells
const _REGION_LOCK = ReentrantLock()

# ── Consent-gated region introduction (PEER_TUNNEL_PLAN §5.1) ─────────────────────────────────────
# When a notebook's region set changes (via `region_on` OR a cell `region=` tag, UI or MCP alike), a new
# cross-host pair may need an SSH-bridged transfer route that isn't armed yet. Rather than install SSH keys
# silently, we stash the pending introduction and PUSH a consent popup to the browser; the mesh is armed
# only on the user's grant. Whole-group: adding one region makes it eligible to talk to every other remote,
# so one consent covers every cross-host pair. Declining leaves transfers on the hub relay (correctness never
# depends on the mesh — it's a speed path). Nothing here touches SSH; that waits for `/api/{id}/mesh-introduce`.
const _MESH_PENDING = Dict{String,Any}()        # nb id → consent payload awaiting the user (mesh_consent_status)
const _MESH_DISMISSED = Dict{String,String}()    # nb id → group signature the user said "not now" to
const _MESH_CONSENT_LOCK = ReentrantLock()

_mesh_group_sig(names) = join(sort(String[String(n) for n in names]), ",")
# The DEFINED region names a notebook uses (footer ∪ cell tags), resolved against the registry.
_nb_defined_regions(nb::LiveNotebook) =
    String[String(get(d, "name", "")) for d in _regions_json(nb) if get(d, "defined", false) === true]

_mesh_pending(nbid) = lock(_MESH_CONSENT_LOCK) do; get(_MESH_PENDING, String(nbid), nothing); end
# The unconnected episode ended (armed, or the group dropped below two hosts): forget both the pending
# payload and the "not now" — so a genuinely NEW disconnect on the same group later re-prompts.
_mesh_resolve!(nbid) = lock(_MESH_CONSENT_LOCK) do
    delete!(_MESH_PENDING, String(nbid)); delete!(_MESH_DISMISSED, String(nbid))
end
function _mesh_dismiss!(nb::LiveNotebook)
    sig = _mesh_group_sig(_nb_defined_regions(nb))
    lock(_MESH_CONSENT_LOCK) do; _MESH_DISMISSED[nb.id] = sig; delete!(_MESH_PENDING, nb.id); end
    return nothing
end
# Close the consent popup on EVERY open tab (a `connected` status makes the component unmount) — after the
# mesh is armed or dismissed from one tab, the others shouldn't keep offering it.
_mesh_broadcast_clear!(nb::LiveNotebook) =
    _broadcast(nb, "mesh-consent:" * JSON.json(Dict("connected" => true, "pairs" => Any[])))

# Off the request path: probe the live mesh and, if a cross-host pair is unconnected AND the user hasn't
# already dismissed THIS exact group, stash the consent payload + push the popup to open tabs. Adding a
# region changes the group signature, so a prior "not now" no longer suppresses (the new region genuinely
# needs a decision). Clears stale pending when the set becomes connected or drops below two hosts.
function _mesh_consent_check!(nb::LiveNotebook)
    names = _nb_defined_regions(nb)
    sig = _mesh_group_sig(names)
    @async try
        hosts = unique(String[ReportEngine.region_get(n).host for n in names])
        if length(hosts) < 2
            _mesh_resolve!(nb.id); return          # no cross-host pair — clear any stale pending/dismissal
        end
        status = ReportEngine.mesh_consent_status(names)
        if status["connected"]
            _mesh_resolve!(nb.id); return          # episode over — a fresh disconnect later re-prompts
        end
        raise = lock(_MESH_CONSENT_LOCK) do
            get(_MESH_DISMISSED, nb.id, "") == sig && return false
            _MESH_PENDING[nb.id] = status
            true
        end
        raise && _broadcast(nb, "mesh-consent:" * JSON.json(status))
    catch e
        @warn "mesh consent check failed" nb = nb.id exception = e
    end
    return nothing
end

# Split a comma-separated region-name list: strip each name, drop empties, dedup preserving order.
function _split_region_csv(s::AbstractString)
    seen = Set{String}(); out = String[]
    for seg in split(String(s), ',')
        n = String(strip(seg)); (isempty(n) || n in seen) && continue
        push!(seen, n); push!(out, n)
    end
    return out
end

# The region NAMES this notebook uses — a comma-separated list in the durable footer (`regions` meta).
# Each name references a GLOBAL region definition (the registry, remote.jl); the notebook stores only
# the reference, resolved at spawn time. Deduped, order-preserved.
_nb_region_names(nb::LiveNotebook) = _split_region_csv(String(get(nb.report.meta, "regions", "")))

# Set (or clear) which named regions this notebook uses. Tears the OLD region kernels down first (they
# detach warm), rewrites the `regions` footer, and persists. Shared core of the `region_on` tool and
# the `/api/{id}/regions` endpoint. Returns the normalized name list.
function set_notebook_regions!(nb::LiveNotebook, csv::AbstractString)
    _teardown_region!(nb)
    names = _split_region_csv(csv)
    joined = join(names, ",")
    lock(nb.lock) do
        isempty(joined) ? delete!(nb.report.meta, "regions") : (nb.report.meta["regions"] = joined)
        _persist!(nb; label = isempty(joined) ? "cleared regions" : "regions · $joined")
    end
    _mesh_consent_check!(nb)   # a new cross-host pair may need a consented SSH mesh (§5.1)
    return names
end

# The notebook's regions for the browser (tag editor + DAG zones): each USED name resolved against the
# global registry — host/transport/warm/root + whether it's actually defined. A name tagged on a cell
# but not in the notebook's `regions` list is included too, so a stray tag still surfaces.
function _regions_json(nb::LiveNotebook)
    names = _nb_region_names(nb); seen = Set(names)
    for c in nb.report.cells
        r = _cell_region(c); (isempty(r) || r in seen) && continue
        push!(seen, r); push!(names, r)
    end
    out = Vector{Any}()
    for name in sort!(collect(names))
        r = ReportEngine.region_get(name)
        push!(out, r === nothing ?
            Dict{String,Any}("name" => name, "defined" => false, "host" => "",
                             "transport" => "tunnel", "root" => "", "warm" => 0) :
            Dict{String,Any}("name" => r.name, "defined" => true, "host" => r.host,
                             "transport" => String(r.transport), "base_port" => r.base_port,
                             "root" => r.data_root, "cache_root" => r.cache_root,
                             "warm" => r.warm, "preload" => r.preload))
    end
    return out
end

# The region a cell is TAGGED into: `region=NAME`. "" = the main kernel.
function _cell_region(cell::Cell)
    for f in cell.flags
        s = String(f)
        startswith(s, "region=") && return String(chopprefix(s, "region="))
    end
    return ""
end

_region_active(nb::LiveNotebook) = any(c -> !isempty(_cell_region(c)), nb.report.cells)

# The EFFECTIVE side a cell executes on (region name; "" = main): its tag — except that an
# untagged MUTATOR follows the tagged writer of its mutation target (a mutation must run where
# the value lives; mutating a transferred copy forks the data, seen live). Depth-1 on purpose:
# explicit tags are the fixed points, so this can't chase chains. NOTE the static analysis
# marks `df[!, :c] = …` as a WRITE of df too — which is exactly why every ownership question
# below must ask THIS function and never the raw tag: judged by tag, that mutator becomes a
# phantom main-side "writer" of df, and a region reader's presync would ship the main kernel's
# stale copy back over the fresh one (seen live: the mutation vanished).
function _cell_side(nb::LiveNotebook, cell::Cell)
    r = _cell_region(cell)
    isempty(r) || return r
    for m in cell.mutates, o in nb.report.cells
        if o !== cell && m in o.writes && !ReportEngine._is_pure_using(o.source)
            ro = _cell_region(o)
            isempty(ro) || return ro
        end
    end
    return ""
end

_side_kernel!(nb::LiveNotebook, side::AbstractString) =
    isempty(side) ? nb.kernel : _region_kernel!(nb, String(side))

# Tolerant field read of a harvested effect record — a NamedTuple locally, tolerant of a Dict/JSON3 shape.
_effect_field(e, f::Symbol) = e isa AbstractDict ? get(e, f, get(e, String(f), nothing)) :
                              (hasproperty(e, f) ? getproperty(e, f) : nothing)

# Interpret a cell's harvested effect declarations (`out.effects`, from the code→Slate channel). v1: a
# `:everywhere` declaration marks the cell EVERYWHERE (`_cell_effect`) so `_prime_namespace!` primes it on every
# region worker — the generic replacement for the `import_scaffold`-piggyback + `_THEME_SENTINEL` special
# cases. Unknown kinds are ignored (forward-compatible), noted once. Runs under `nb.lock` (mutates c.flags).
# (Durable cross-session persistence + per-statement replay arrive with the effect store.)
# Normalise a harvested effect record (NamedTuple, or Dict/JSON3 over the gate) to `(; kind, names, stmt_src)`.
function _effect_record(e)
    kind = _effect_field(e, :kind); kind = kind isa AbstractString ? Symbol(kind) : kind
    names = _effect_field(e, :names); names = names === nothing ? Symbol[] : Symbol[Symbol(n) for n in names]
    src = _effect_field(e, :stmt_src); src = src === nothing ? "" : String(src)
    return (; kind = kind, names = names, stmt_src = src)
end

function _apply_cell_effects!(nb::LiveNotebook, c::Cell, out)
    (out === nothing || isempty(out.effects)) && return nothing
    recs = [_effect_record(e) for e in out.effects]
    for r in recs
        if r.kind === :everywhere
            :everywhere in c.flags || push!(c.flags, :everywhere)
        elseif r.kind !== nothing
            ReportEngine._rlog("cell effects: cell $(c.id) declared unhandled effect kind ':$(r.kind)' — ignored")
        end
    end
    # Persist DURABLY, keyed by the cell's own source digest — so the classification + statement-scoped
    # records survive a reload / fresh region worker WITHOUT this cell running on main again (see
    # `_reestablish_effects!`). Best-effort; off the hot path but cheap (one small TOML).
    try; EffectStore.store!(SlateHome.effects_dir(), string(c.src_hash), recs); catch e
        ReportEngine._rlog("cell effects: persist for $(c.id) failed: $(first(sprint(showerror, e), 120))")
    end
    return nothing
end

# Re-establish durable effect classifications when a notebook (re)loads — BEFORE any cell runs. For each
# code cell, load its persisted records (keyed by src digest); a stored `:everywhere` re-marks the cell
# EVERYWHERE from t=0, so `_prime_namespace!` primes it on region workers without the declaring cell running
# on main this session. Dissolves the cold-start gap durably. No-op when nothing is stored.
function _reestablish_effects!(report)
    root = SlateHome.effects_dir()
    for c in report.cells
        c.kind == CODE || continue
        recs = try; EffectStore.load(root, string(c.src_hash)); catch; nothing; end
        recs === nothing && continue
        any(r -> r.kind === :everywhere, recs) && (:everywhere in c.flags || push!(c.flags, :everywhere))
    end
    return nothing
end

# Read a field tolerant of a NamedTuple (local) or a Dict/JSON3 shape (off the gate) — for extension
# manifest entries (`(; id, js)`), which arrive as JSON3 objects across the gate.
_manifest_field(e, f::Symbol) = e isa AbstractDict ? get(e, f, get(e, String(f), nothing)) :
                                (hasproperty(e, f) ? getproperty(e, f) : nothing)

# Add/replace one front-end script in a notebook's sticky registry, deduped by `id` (a re-declaration
# replaces in place; declaration order is otherwise preserved). An empty/missing `id` keys on the
# script's content hash — matching SlateExtensionsBase `provide_frontend!`. `esm` marks an ES module;
# a non-empty `kind` marks a component (Slate wraps its default export under `kind`). Returns true if
# the registry CHANGED (new id, or an existing id's fields differ), so the caller can bump the version.
function _register_frontend!(nb::LiveNotebook, idv, js::AbstractString, esm::Bool = false,
                            kind::AbstractString = "")
    id = (idv === nothing || isempty(String(idv))) ? "fe:" * string(hash(js); base = 16) : String(idv)
    entry = (id = id, js = String(js), esm = esm, kind = String(kind))
    i = findfirst(e -> e.id == id, nb.frontend)
    if i === nothing
        push!(nb.frontend, entry); return true
    elseif nb.frontend[i] != entry
        nb.frontend[i] = entry; return true
    end
    return false
end

# Add/replace one package-vendored asset directory (pkg → absolute dir) in the notebook's registry — the
# files under `dir` are served at `/ext-assets/<pkg>/…` (see `_make_router`) and copied into a static
# export. Returns true if the registry CHANGED (new pkg, or the dir moved), so the caller bumps the version.
function _register_assets!(nb::LiveNotebook, pkg::AbstractString, dir::AbstractString)
    (isempty(pkg) || isempty(dir)) && return false
    p, d = String(pkg), String(dir)
    get(nb.assets, p, nothing) == d && return false
    nb.assets[p] = d
    return true
end

# Refresh the notebook's front-end registry from the worker's SlateExtensionsBase extension manifest
# (`{frontend: [{id, js}]}`) — the packages loaded this session declare their front-end from `__init__`,
# which may run during namespace priming (no harvestable eval), so the process-global registry is the
# authoritative source. Pulled ONCE per drain (see `_run_loop!`) — the gate worker is queried, the
# in-process kernel read directly. Merges each script (sticky, id-deduped); returns true if anything
# changed, so the caller pushes a fresh state for the browser to inject. Best-effort: a query failure
# leaves the registry as-is. Runs under `nb.lock`.
function _refresh_extensions!(nb::LiveNotebook)
    manifest = try
        nb.kernel isa ReportEngine.GateKernel ?
            ReportEngine.extension_manifest(nb.kernel) :
            ReportEngine.inprocess_extension_manifest(ReportEngine.report_module(nb.report))
    catch e
        ReportEngine._rlog("slate: extension manifest refresh failed: $(first(sprint(showerror, e), 120))")
        return false
    end
    manifest === nothing && return false
    changed = false
    # The manifest was pulled OFF nb.lock (a round-trip); take the lock only for each registry mutation,
    # so this stays protocol-safe when the runner calls `_refresh_extensions!` off-lock.
    fe = _manifest_field(manifest, :frontend)
    if fe !== nothing
        for e in fe
            js = _manifest_field(e, :js); js === nothing && continue
            esm = _manifest_field(e, :esm); esm = esm === true || esm == "true"
            kind = _manifest_field(e, :kind); kind = kind === nothing ? "" : String(kind)
            lock(nb.lock) do
                _register_frontend!(nb, _manifest_field(e, :id), String(js), esm, kind)
            end && (changed = true)
        end
    end
    as = _manifest_field(manifest, :assets)
    if as !== nothing
        for e in as
            pkg = _manifest_field(e, :pkg); dir = _manifest_field(e, :dir)
            (pkg === nothing || dir === nothing) && continue
            lock(nb.lock) do
                _register_assets!(nb, String(pkg), String(dir))
            end && (changed = true)
        end
    end
    return changed
end

# The notebook's package-declared front-end scripts, as `(; id, js, esm)` entries in declaration order.
# Slate injects each ONCE — live (`state_json` → the browser appends every unseen `<script>`, as a module
# when `esm`) and in a static export — so a package's widget renderer / editor extension registers with
# no boot cell. Populated by `_refresh_extensions!` from the worker's SlateExtensionsBase manifest.
_frontend_scripts(nb::LiveNotebook) = nb.frontend

_frontend_scripts_json(nb::LiveNotebook) =
    [Dict{String,Any}("id" => e.id, "js" => e.js, "esm" => e.esm, "kind" => e.kind) for e in nb.frontend]

# Read a table spec's declared id, tolerating both JSON3.Object (Symbol keys, as
# deserialized off the gate) and a plain Dict{String,Any} (server-built specs).
function _spec_tableid(t)
    try
        if t isa AbstractDict
            haskey(t, :tableId) && return t[:tableId]
            haskey(t, "tableId") && return t["tableId"]
            return nothing
        end
        return getproperty(t, :tableId)
    catch
        return nothing
    end
end

# Which side (region kernel; "" = main) owns a paged table? A paged table's provider
# is registered in the WORKER that ran the producing cell, so page requests must hit
# THAT kernel — a `region`-tagged cell's DataFrame can't paginate against the main
# kernel because the provider was never registered there. Resolve by finding the cell
# whose last output declared this tableId, then ask where that cell runs.
function _table_side(nb::LiveNotebook, table_id::AbstractString)
    (isempty(table_id) || !_region_active(nb)) && return ""
    for cell in nb.report.cells
        o = cell.output
        o === nothing && continue
        for t in o.tables
            tid = _spec_tableid(t)
            tid !== nothing && String(tid) == String(table_id) && return _cell_side(nb, cell)
        end
    end
    return ""
end

# Which kernel does `cell` run on? Its effective side. Returns (kernel, side::String).
function _region_route(nb::LiveNotebook, cell::Cell)
    _region_active(nb) || return (nb.kernel, "")
    side = _cell_side(nb, cell)
    (!isempty(side) && isempty(_cell_region(cell))) &&
        ReportEngine._rlog("region: cell $(cell.id) auto-follows its mutation target to region '$side' — a mutation runs where the value lives")
    return (_side_kernel!(nb, side), side)
end

# The notebook's kernel for region `name`, created lazily from its footer spec (spawn/adopt
# happens at its first prepare!, so a warm-pool worker makes this ~1s). Label carries the
# region so the worker roster + attach records distinguish kernels.
function _region_kernel!(nb::LiveNotebook, name::String)
    lock(_REGION_LOCK) do
        k = get(_REGION_KERNELS, (nb.id, name), nothing)
        k === nothing || return k
        r = ReportEngine.region_get(name)
        r === nothing && error("region '$name' is not defined — create it in the registry: " *
                               "region(\"$name\"; host=…, warm=…) or the home-page Regions manager")
        isempty(r.host) && error("region '$name' has no host — set one in the Regions manager")
        proj = Base.current_project(dirname(abspath(nb.path)))
        parent = proj === nothing ? "" : dirname(proj)   # notebook's own /src synced for hot-reload provenance
        # The region worker replicates the NOTEBOOK's exact env — its own fork env if it has one, else the
        # parent project (identical resolution to `_select_kernel`'s whole-notebook remote path). The region's
        # `preload` is only a warm-pool key, never the env a region cell runs — so a region cell gets the
        # notebook's packages + dev'd path deps even when the region has no preload configured.
        envdir = ReportEngine.notebook_env_dir(nb.path)
        origin_env = isfile(joinpath(envdir, "Project.toml")) ? envdir :
                     (!isempty(parent) && isfile(joinpath(parent, "Project.toml")) ? parent : "")
        target = ReportEngine._region_target(r; origin_env = origin_env)   # transport/datadir/region from the def; env = the notebook's
        ReportEngine._rlog("region: kernel '$name' for $(nb.id) → $(r.host) ($(r.transport))" *
                           (isempty(r.data_root) ? "" : " root=$(r.data_root)"))
        k = ReportEngine.GateKernel(target.project; parent = parent, target = target,
                                    label = basename(abspath(nb.path)) * "#" * name)
        _REGION_KERNELS[(nb.id, name)] = k
        return k
    end
end

# Human-facing location of a side: "local" or "name (host)" — resolved against the global registry.
function _side_label(nb::LiveNotebook, side::AbstractString)
    isempty(side) && return "local"
    r = ReportEngine.region_get(String(side))
    (r === nothing || isempty(r.host)) && return String(side)
    return "$side ($(r.host))"
end

# Namespace parity primer: run the notebook's pure-`using`/`import` cells on kernel `k` so a side
# that's about to RECEIVE a boundary value can DECODE it (a DataFrame needs DataFrames loaded there,
# an Arrow blob needs Arrow, a JLS blob needs whatever types it holds). The env is the SAME fork
# project on every side — this only executes the imports, it never installs anything. Idempotent:
# tracked per LIVE kernel against the imports' signature, so it fires once per kernel and again only
# if the notebook's imports change (a fresh/replaced kernel has a new objectid ⇒ re-primes).
function _prime_namespace!(nb::LiveNotebook, k, side::AbstractString)
    # Cells that ESTABLISH state on every side — pure `using`/`import`, the import scaffold, a `set_theme!`
    # setter — re-run (never transferred) in document order so imports precede a scaffold/effect that
    # builds on them. This is exactly the `EVERYWHERE` category of the single `_cell_effect` classifier
    # (deps.jl), so the region prime and the memo replay read the SAME definition — a standalone
    # `set_theme!` can no longer silently miss the region. `RESOURCE` runs on every side too but has data
    # deps, so it replays at READ (`_ensure_resource_on!`), not here.
    env = [c for c in nb.report.cells if ReportEngine._cell_effect(c) == ReportEngine.EVERYWHERE]
    isempty(env) && return nothing
    sig = hash([c.src_hash for c in env])
    key = (nb.id, _worker_key(k))
    lock(_REGION_LOCK) do; get(_REGION_PRIMED, key, UInt(0)); end == sig && return nothing
    for c in env
        prime_src = _everywhere_replay_source(c)   # the marked statements when safe, else the whole cell
        try
            ReportEngine.eval_capture(k, nb.report, prime_src, "cell:" * c.id * "#prime", nothing)
        catch e
            # Per-statement replay can throw if a marked statement referenced a cell-local name defined by
            # an UNMARKED earlier statement — fall back to the whole cell source (always sufficient).
            if prime_src != c.source
                try
                    ReportEngine.eval_capture(k, nb.report, c.source, "cell:" * c.id * "#prime", nothing)
                catch e2
                    ReportEngine._rlog("region: namespace prime of $(c.id) on $(_side_label(nb, side)) failed: " *
                                       first(sprint(showerror, e2), 160))
                end
            else
                ReportEngine._rlog("region: namespace prime of $(c.id) on $(_side_label(nb, side)) failed: " *
                                   first(sprint(showerror, e), 160))
            end
        end
    end
    lock(_REGION_LOCK) do; _REGION_PRIMED[key] = sig; end
    return nothing
end

# What to REPLAY to re-establish an EVERYWHERE cell's effect on a region worker. Per-statement replay —
# just the statements that DECLARED an `:everywhere` effect (from this session's harvest, or the durable
# store across a reload) — is used ONLY when the cell's EVERYWHERE-ness comes purely from those runtime
# declarations. A cell that is EVERYWHERE because it's an import scaffold / pure `using` / theme setter
# needs its WHOLE source (the import itself must run), so it replays whole-cell — as does a declared cell
# with no recorded statements. This avoids re-running expensive NON-effect statements of a mixed cell on
# every region worker, while staying correct (the caller falls back to whole-cell if an isolated statement
# throws for a missing intra-cell dependency).
function _everywhere_replay_source(c::Cell)
    (:everywhere in c.flags) || return c.source
    (:import_scaffold in c.flags || ReportEngine._is_pure_using(c.source) ||
        ReportEngine._THEME_SENTINEL in c.writes) && return c.source
    recs = (c.output !== nothing && !isempty(c.output.effects)) ? c.output.effects :
           try; EffectStore.load(SlateHome.effects_dir(), string(c.src_hash)); catch; nothing; end
    (recs === nothing || isempty(recs)) && return c.source
    stmts = String[]; seen = Set{String}()
    for r in recs
        s = strip(String(something(_effect_field(r, :stmt_src), "")))
        (isempty(s) || s in seen) && continue
        push!(seen, s); push!(stmts, s)
    end
    isempty(stmts) ? c.source : join(stmts, "\n")
end

# Detach (default) or kill every region kernel + forget the boundary sync state.
function _teardown_region!(nb::LiveNotebook; kill::Bool = false)
    ks = lock(_REGION_LOCK) do
        got = [pop!(_REGION_KERNELS, key) for key in collect(keys(_REGION_KERNELS)) if key[1] == nb.id]
        delete!(_REGION_SYNCED, nb.id)
        filter!(kv -> kv[1][1] != nb.id, _REGION_PRIMED)   # forget priming so a re-setup re-primes fresh kernels
        got
    end
    for k in ks
        try; ReportEngine.shutdown!(k; kill_remote = kill); catch e
            @warn "slate region: teardown failed" notebook = nb.id exception = e
        end
    end
    return nothing
end

# Restart JUST one region worker (the main kernel + other regions stay up): kill its worker, forget its
# prime + boundary-sync state, restale the cells that run on it, and re-run — async, same "instant"
# pattern as restart_kernel!. The region kernel is respawned lazily by `_region_kernel!` on the next
# eval. `side == ""` means the main kernel → fall back to a full restart.
function restart_region!(nb::LiveNotebook, side::AbstractString)
    isempty(side) && return restart_kernel!(nb)
    k = lock(_REGION_LOCK) do
        kk = pop!(_REGION_KERNELS, (nb.id, String(side)), nothing)
        kk === nothing || delete!(_REGION_PRIMED, (nb.id, objectid(kk)))   # fresh kernel re-primes itself
        delete!(_REGION_SYNCED, nb.id)   # coarse (keyed per-nb): re-ships boundary values to the fresh kernel
        kk
    end
    k === nothing || try; ReportEngine.shutdown!(k; kill_remote = true); catch e
        @warn "slate region: restart teardown failed" notebook = nb.id side = side exception = e
    end
    ids = String[]
    lock(nb.lock) do
        for cell in nb.report.cells
            (cell.kind == CODE && _cell_side(nb, cell) == side) || continue
            cell.state = STALE; push!(ids, cell.id)
        end
    end
    ReportEngine._rlog("region: restart '$side' for $(nb.id) — killed worker, restaled $(length(ids)) cell(s)")
    @async begin
        try
            _self_heal_locked!(nb)   # locked cells on this region restore first — see restart_kernel!
            _eval!(nb)
        catch e
            @warn "slate region: restart re-run failed" side = side exception = e
        end
    end
    return nb
end

# ── Run supervisor: eval-level self-healing ──────────────────────────────────────────────────
# Kaimon self-heals at the SESSION/connection level ("is the worker reachable"). This layer works
# BELOW that, per EVAL: a cell the hub marks RUNNING that no kernel is actually evaluating is an
# ORPHAN (its worker bounced under it, or a `celldone` was lost) — it wedges the notebook forever.
# A background sweep reconciles the hub's RUNNING cells against each kernel's authoritative
# in-flight set (`__slate_running`) and resets confirmed orphans to STALE so the run can proceed.
# Conservative by construction: a cell is only reset after it's been RUNNING past a grace window AND
# a SUCCESSFUL query confirms it absent on TWO consecutive sweeps — so a genuinely long-running cell
# (whose query would simply be slow, or return it as present) is never touched, and a transient
# dispatch race can't trip it. An unreachable worker yields no confirmation → left to the session layer.
const _RUN_SINCE = Dict{Tuple{String,String},Float64}()   # (nb id, cell id) → first time observed RUNNING
const _RUN_ORPHAN_HITS = Dict{Tuple{String,String},Int}()  # consecutive confirmed-absent sweeps
const _RECONCILE_GRACE = 8.0                               # s a cell must be RUNNING before it's judged
const _RUN_SUPERVISOR = Ref{Any}(nothing)

# A notebook's live GateKernels — main + any region kernels — for the authoritative in-flight query.
function _nb_kernels(nb::LiveNotebook)
    ks = Any[]
    nb.kernel isa ReportEngine.GateKernel && push!(ks, nb.kernel)
    lock(_REGION_LOCK) do
        for (key, k) in _REGION_KERNELS
            key[1] == nb.id && push!(ks, k)
        end
    end
    return ks
end

# ── Kernel liveness heartbeat + dead-wire self-heal ─────────────────────────────────────────
# Every sweep pings each connected kernel's authoritative in-flight set (`__slate_running`, 8s). It
# serves two purposes at once: (1) the union of running cell ids feeds the orphan reconciler below, and
# (2) it's the hub's DEAD-WIRE detector. A remote worker whose wire has gone silent — a half-open TCP,
# or an SSH `-L` forward left standing after the worker died or was reaped — answers nothing, yet ZMQ
# still reports the socket "connected"; an eval dispatched on it would then block for the full eval
# timeout (an hour), which surfaces as a wedged notebook and a zombie "Still executing…" in the TUI.
# A remote wire that stays CONTINUOUSLY unresponsive for `_DEAD_WIRE_GRACE` seconds is declared dead and
# DROPPED: the disconnect wakes any eval blocked on that wire (it errors cleanly), and a later run re-dials.
# The grace is deliberately generous — a brief network partition, a stop-the-world GC pause, or a
# suspended-then-resumed process should NOT tear the wire down. During such a blip the in-flight eval is
# simply WAITING on its own (long) timeout — a channel independent of the liveness ping — so when the
# worker comes back the reply arrives and the cell completes as if nothing happened. A single successful
# ping resets the clock, so only a wire silent the WHOLE window (genuinely gone) is dropped. This is also
# safe against the busy/dead ambiguity: `__slate_running` is served on the worker's reserved INTERACTIVE
# thread, so a busy-but-alive worker keeps answering. LOCAL kernels are left to `prepare!`'s process-death
# path (respawn on a dead proc); we only auto-drop REMOTE wires, where the process is out of our sight and
# the wire is the only signal. `WeakKeyDict` so a closed notebook's kernels don't pin the clock in memory.
const _KERNEL_UNRESPONSIVE_SINCE = WeakKeyDict{Any,Float64}()   # kernel → wall time it first went silent (cleared on any success)
const _DEAD_WIRE_GRACE = something(tryparse(Float64, get(ENV, "KAIMONSLATE_DEADWIRE_GRACE", "")), 45.0)  # s of continuous silence ⇒ dead
const _LIVENESS_PING_TIMEOUT = 8.0   # per-ping timeout; also how far to BACKDATE first-silence — when a ping first fails the worker has already been silent this long, so the countdown starts at ~8s, not 0
const _LAST_RUNNING = Dict{String,Tuple{Set{String},Bool}}()   # nb id → (running ids, anyok) from the last sweep

# Retry policy after a dead-wire drop (global for now; per-region later). `manual` (default): flag the
# dropped kernel `redial_hold` so ONLY an explicit run reconnects it — a reactive cascade errors rather
# than silently cold-spawning a replacement for a flaky worker. `auto`: no hold, the reactive path
# re-dials eagerly (storm-safe: a failed re-dial errors the cell → not stale → the runner stops).
const _REGION_AUTORETRY = Ref{Bool}(false)
_region_autoretry() = something(tryparse(Bool, get(ENV, "KAIMONSLATE_REGION_AUTORETRY", "")), _REGION_AUTORETRY[])
_kernel_held(k) = k isa ReportEngine.GateKernel && k.redial_hold
# Clear the reconnect-hold on all of a notebook's kernels — called when a cell is EXPLICITLY run, so an
# explicit play (even of a downstream cell) reconnects the upstream region it depends on.
function _clear_region_holds!(nb::LiveNotebook)
    for k in _nb_kernels(nb)
        k isa ReportEngine.GateKernel && (k.redial_hold = false)
    end
    return nothing
end

# Tear down a remote kernel's silent wire and surface the auto-recovery (log + the woken eval's error).
# Under the manual policy also flag the kernel so prepare! won't auto-reconnect it until an explicit run.
function _heal_dead_wire!(nb::LiveNotebook, k, unresp_s::Real = 0.0)
    side = _kernel_side_label(nb, k)
    auto = _region_autoretry()
    ReportEngine._rlog("liveness: dead wire on $(nb.id)/$(side) — worker unresponsive for $(round(Int, unresp_s))s (grace $(round(Int, _DEAD_WIRE_GRACE))s); dropping the connection ($(auto ? "auto-retry: next run re-dials" : "manual: holds until an explicit re-run"))")
    dropped = try; ReportEngine._drop_kernel_conn!(k)
    catch e; ReportEngine._rlog("liveness: drop failed on $(nb.id)/$(side): " * first(sprint(showerror, e), 120)); false
    end
    dropped && !auto && (try; k.redial_hold = true; catch; end)
    dropped && (try; _workers_push!(nb); catch; end)   # pill flips to amber "reconnecting" NOW, not at the next state
    return dropped
end

# Ping every connected kernel: refresh the heartbeat, track failures, heal dead remote wires, and
# stash the union of running cell ids for the orphan reconciler. Runs every sweep (idle or busy) so a
# wire that dies while nothing is running is still healed before the next cell is dispatched onto it.
function _liveness_sweep!(nb::LiveNotebook)
    ids = Set{String}(); anyok = false
    for k in _nb_kernels(nb)
        (k isa ReportEngine.GateKernel && k.conn !== nothing) || continue
        ok = false
        try
            r = ReportEngine._tool(k, "__slate_running", Dict{String,Any}(); timeout = _LIVENESS_PING_TIMEOUT)
            run = r isa NamedTuple ? get(r, :running, nothing) :
                  r isa AbstractDict ? get(r, "running", get(r, :running, nothing)) : nothing
            if run !== nothing
                for id in run; push!(ids, String(id)); end
                anyok = true; ok = true
            end
        catch e
            ReportEngine._rlog("liveness: __slate_running failed on $(nb.id)/$(_kernel_side_label(nb, k)): " * first(sprint(showerror, e), 120))
        end
        if ok
            if haskey(_KERNEL_UNRESPONSIVE_SINCE, k)   # was unwell → recovered this sweep
                delete!(_KERNEL_UNRESPONSIVE_SINCE, k) # any reply resets the clock — a blip is forgiven
                try; _workers_push!(nb); catch; end    # pill back to green immediately
            end
        elseif k.target isa ReportEngine.RemoteTarget || k.remote   # remote-only auto-drop
            since = get!(() -> time() - _LIVENESS_PING_TIMEOUT, _KERNEL_UNRESPONSIVE_SINCE, k)   # stamp the first silent sweep, backdated by the ping timeout it already waited
            unresp = time() - since
            if unresp >= _DEAD_WIRE_GRACE
                delete!(_KERNEL_UNRESPONSIVE_SINCE, k)
                _heal_dead_wire!(nb, k, unresp)        # → amber "disconnected" (pushes inside)
            else
                # Still CONNECTED but missing pings: surface it as a muted-yellow "degraded" pill NOW (an
                # early warning, well before the drop), and re-push each sweep so its unresponsive-countdown
                # ticks live in the pill/popup.
                try; _workers_push!(nb); catch; end
            end
        end
    end
    _LAST_RUNNING[nb.id] = (ids, anyok)
    return nothing
end

# Union of the cell ids every connected kernel said it's evaluating on the last liveness sweep, or
# `nothing` if NO kernel could be queried (all unreachable) — in which case we must not judge anything
# orphaned. Reads the sweep's cache (populated just before the reconciler runs) to avoid double-pinging.
function _worker_running_ids(nb::LiveNotebook)
    cached = get(_LAST_RUNNING, nb.id, nothing)
    cached === nothing && return nothing
    ids, anyok = cached
    return anyok ? ids : nothing
end

# Explicit-reap fast-path: killing a worker on host:port leaves any LIVE kernel still bound to it holding
# a now-dead wire — an in-flight eval on it would otherwise block until the liveness sweep drops the wire
# (~15s) or, worst case, the full eval timeout. Drop those wires NOW so the eval wakes and errors at once.
# The liveness sweep remains the safety net if this host/port match is imperfect (e.g. a remapped tunnel).
function _drop_kernels_for_worker!(h, host::AbstractString, port::Integer)
    h === nothing && return 0   # the hub is PASSED IN — `_HUB` lives in the outer KaimonSlate module, not here
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    n = 0; seen = String[]
    for nb in nbs, k in _nb_kernels(nb)
        k isa ReportEngine.GateKernel && k.conn !== nothing || continue
        k.target isa ReportEngine.RemoteTarget || continue
        push!(seen, "$(nb.id)/$(_kernel_side_label(nb, k))@$(k.target.ssh_host):$(k.port)")
        (k.target.ssh_host == host && k.port == Int(port)) || continue
        try
            if ReportEngine._drop_kernel_conn!(k)
                n += 1
                ReportEngine._rlog("reap: dropped live wire on $(nb.id)/$(_kernel_side_label(nb, k)) (worker-$port on $host reaped)")
                try; _workers_push!(nb); catch; end   # pill flips to amber "reconnecting" immediately
            end
        catch; end
    end
    # Diagnostic when the fast-path misses: the liveness sweep still backstops it, but with the generous
    # dead-wire grace that's a slow path for an EXPLICIT reap — so surface the actual live endpoints to
    # show why the host/port didn't match (e.g. a base-port vs slot-port drift on a :direct region).
    n == 0 && ReportEngine._rlog("reap: no live kernel matched $host:$port (live remote kernels: $(isempty(seen) ? "none" : join(seen, ", "))) — liveness sweep will backstop")
    return n
end

function _reconcile_nb_runs!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return nothing
    now = time()
    running = [c for c in nb.report.cells if c.state == RUNNING]
    ids = Set(c.id for c in running)
    for c in running; get!(_RUN_SINCE, (nb.id, c.id), now); end   # stamp first-seen-running
    for key in collect(keys(_RUN_SINCE))                          # drop records for cells no longer running
        (key[1] == nb.id && !(key[2] in ids)) && (delete!(_RUN_SINCE, key); delete!(_RUN_ORPHAN_HITS, key))
    end
    suspects = [c for c in running if now - get(_RUN_SINCE, (nb.id, c.id), now) > _RECONCILE_GRACE]
    isempty(suspects) && return nothing
    actual = _worker_running_ids(nb)
    actual === nothing && return nothing                         # no kernel could confirm → leave to the session layer
    for c in suspects
        key = (nb.id, c.id)
        if c.id in actual                                        # genuinely running → clear any strike
            delete!(_RUN_ORPHAN_HITS, key); continue
        end
        hits = get(_RUN_ORPHAN_HITS, key, 0) + 1                 # confirmed absent this sweep
        _RUN_ORPHAN_HITS[key] = hits
        hits < 2 && continue                                     # need TWO consecutive confirmations
        idx = _index_of(nb.report.cells, c.id); idx === nothing && continue
        did = lock(nb.lock) do
            ReportEngine.revert_running!(c)
        end
        did || continue
        delete!(_RUN_SINCE, key); delete!(_RUN_ORPHAN_HITS, key)
        ReportEngine._rlog("supervisor: healed orphaned run — $(nb.id)/$(c.id) was RUNNING but no kernel is evaluating it → reset to stale")
        try; _announce_cell!(nb, idx); catch; end
    end
    return nothing
end

# Safety net alongside `_RUNNER_CANCEL` (which prevents the known cause — a close racing an
# in-flight drain): if `_RUNNERS[nb.id]` says a runner is active, there's pending stale work, but
# NOTHING is actually RUNNING, that's implausible for a genuinely active drain (which is always
# either mid-eval of a cell or picking up its next one within a fraction of a second) — sustained
# across several consecutive sweeps, it means the bookkeeping is lying: the real runner is gone
# (crashed past its `finally`, or some other bug this fix didn't anticipate) and the notebook is
# silently wedged. Self-heals by clearing the stale bookkeeping and re-arming, loudly logged since
# this is the sweep catching something that's already a bug, not routine behavior.
function _reconcile_stale_runner!(nb::LiveNotebook)
    active = lock(_RUNNER_LOCK) do; get(_RUNNERS, nb.id, false); end
    active || (delete!(_RUNNER_STALE_HITS, nb.id); return nothing)
    has_pending, any_running = lock(nb.lock) do
        _next_stale_cell(nb.report) !== nothing, any(c -> c.state == RUNNING, nb.report.cells)
    end
    if !has_pending || any_running
        delete!(_RUNNER_STALE_HITS, nb.id)
        return nothing
    end
    started = lock(_RUNNER_LOCK) do; get(_RUNNER_STARTED, nb.id, time()); end
    (time() - started > _RUNNER_STALE_AFTER) || return nothing   # a real cell can legitimately run this long — only suspect once implausible
    hits = get(_RUNNER_STALE_HITS, nb.id, 0) + 1
    _RUNNER_STALE_HITS[nb.id] = hits
    hits < _RUNNER_STALE_CONFIRMATIONS && return nothing
    delete!(_RUNNER_STALE_HITS, nb.id)
    lock(_RUNNER_LOCK) do
        delete!(_RUNNERS, nb.id); delete!(_RUNNER_STARTED, nb.id); delete!(_RUNNER_CANCEL, nb.id)
    end
    ReportEngine._rlog("supervisor: notebook $(nb.id) looked wedged — a runner was marked active for " *
                       "$(round(Int, time() - started))s with pending work and nothing actually running. " *
                       "Clearing the stale flag and restarting its runner.")
    @warn "slate: self-healed a wedged notebook runner" notebook = nb.id stuck_for_s = round(Int, time() - started)
    _ensure_runner!(nb)
    return nothing
end

function _supervise_runs!(h)   # NOTE: `Hub` is defined later (server_hub.jl, included at ~1510) — untyped so this loads
    try; ReportEngine.reap_pending_kills!()   # hub-wide, not per-notebook — see gate_kernel.jl
    catch e; ReportEngine._rlog("supervisor: pending-kill reap error: " * first(sprint(showerror, e), 120))
    end
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    for nb in nbs
        try; _liveness_sweep!(nb)   # heartbeat + dead-wire heal; caches running ids for the reconciler
        catch e; ReportEngine._rlog("supervisor: liveness error on $(nb.id): " * first(sprint(showerror, e), 120))
        end
        try; _reconcile_nb_runs!(nb)
        catch e; ReportEngine._rlog("supervisor: reconcile error on $(nb.id): " * first(sprint(showerror, e), 120))
        end
        try; _reconcile_stale_runner!(nb)
        catch e; ReportEngine._rlog("supervisor: stale-runner reconcile error on $(nb.id): " * first(sprint(showerror, e), 120))
        end
        try; _watchdog_scan!(nb)
        catch e; ReportEngine._rlog("watchdog: scan error on $(nb.id): " * first(sprint(showerror, e), 120))
        end
        try; _ws_health!(nb); catch; end   # push watchdog status to open pages over the WS (replaces the GET /api/health poll)
    end
    return nothing
end

# ── Watchdog: stall + runaway detection ─────────────────────────────────────────────────────
# Rides the same 5s sweep as the run-reconciler, but where the reconciler HEALS orphans (RUNNING
# cells no worker is evaluating), the watchdog CLASSIFIES trouble on cells that ARE still alive:
# slow/stalled by duration, and — where telemetry flows — runaway cpu/mem and gc-thrash. It only
# reports (into `_NB_HEALTH`, surfaced to the health panel); acting on an alert (interrupt/reboot)
# is a deliberate user gesture (the recovery buttons), never automatic. Thresholds are generous on
# purpose: a late "slow" is cheap, a false "stalled" cries wolf.
const _WD_SLOW        = 90.0          # a cell RUNNING this long (still confirmed alive) is "slow"
const _WD_STALL       = 300.0         # ... this long is "stalled"
const _WD_CPU_HOT     = 90.0          # cpu% at/above this counts as pegged
const _WD_CPU_SAMPLES = 5             # ...sustained across this many samples (~10s) → runaway-cpu
const _WD_RSS_CEIL    = 4 * 2^30      # rss above this AND climbing → runaway-mem
const _WD_STALE_TEL   = 20.0          # telemetry silent this long while a cell runs → unreachable
const _WD_TEL_FRESH   = 10.0          # a telemetry sample older than this isn't trusted as "current"
const _NB_HEALTH = Dict{String,Any}() # nb id → (; status, alerts, ts)
const _WD_LOCK   = ReentrantLock()

nb_health(id::AbstractString) = lock(_WD_LOCK) do; get(_NB_HEALTH, String(id), nothing); end

# Human side label for a kernel: "local" for the main kernel, else the region name it serves.
# (The name lookup returns from INSIDE the lock closure, so capture its value — a bare `return`
# in a `do` block returns from the closure, not the function.)
function _kernel_side_label(nb::LiveNotebook, k)
    k === nb.kernel && return "local"
    return lock(_REGION_LOCK) do
        for (key, rk) in _REGION_KERNELS
            key[1] == nb.id && rk === k && return key[2]
        end
        "region"
    end
end

# (side, latest, history) for each of a notebook's connected kernels that has telemetry.
function _nb_kernel_stats(nb::LiveNotebook)
    out = Any[]
    for k in _nb_kernels(nb)
        (k isa ReportEngine.GateKernel && k.conn !== nothing) || continue
        cn = try; k.conn.name; catch; ""; end
        isempty(cn) && continue
        st = ReportEngine.kernel_stats(cn)
        st === nothing && continue
        push!(out, (_kernel_side_label(nb, k), st.latest, st.history))
    end
    return out
end

# Union of cell ids the kernels' latest FRESH telemetry says are running, or `nothing` if no kernel
# has a current sample (then we can't confirm liveness → cells stay "unconfirmed", never "stalled").
function _running_from_telemetry(nb::LiveNotebook)
    ids = Set{String}(); any = false; now = time()
    for (_, latest, _) in _nb_kernel_stats(nb)
        now - latest.rcv <= _WD_TEL_FRESH || continue
        union!(ids, latest.running); any = true
    end
    return any ? ids : nothing
end

_gib(b::Integer) = string(round(b / 2^30; digits = 1), "GiB")

function _watchdog_scan!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return nothing   # in-process kernels have no worker to watch
    now = time()
    alerts = Any[]
    confirmed = _running_from_telemetry(nb)   # telemetry-derived liveness (no extra RPC)
    # Per running cell: slow / stalled. A cell absent from FRESH telemetry is an orphan the reconciler
    # owns — skip it here so the two supervisors don't both shout about the same cell.
    for c in nb.report.cells
        c.state == RUNNING || continue
        since = get(_RUN_SINCE, (nb.id, c.id), now)
        dur = now - since
        dur >= _WD_SLOW || continue
        (confirmed !== nothing && !(c.id in confirmed)) && continue
        kind = dur >= _WD_STALL ? "stalled" : "slow"
        note = confirmed === nothing ? " (unconfirmed — no telemetry)" : ""
        push!(alerts, (kind = kind, scope = "cell", target = c.id, since = since,
                       detail = "running $(round(Int, dur))s$note"))
    end
    # Per kernel: runaway cpu / mem, gc-thrash, unreachable.
    for (side, latest, hist) in _nb_kernel_stats(nb)
        stale = now - latest.rcv
        if stale > _WD_STALE_TEL && !isempty(latest.running)
            push!(alerts, (kind = "unreachable", scope = "kernel", target = side, since = latest.rcv,
                           detail = "no telemetry for $(round(Int, stale))s while a cell runs"))
            continue   # a silent kernel's cpu/rss are stale too — don't pile on runaway alerts
        end
        recent = length(hist) >= _WD_CPU_SAMPLES ? hist[end - _WD_CPU_SAMPLES + 1:end] : hist
        if length(recent) >= _WD_CPU_SAMPLES && all(s -> s.cpu >= _WD_CPU_HOT, recent) && !isempty(latest.running)
            push!(alerts, (kind = "runaway-cpu", scope = "kernel", target = side, since = recent[1].rcv,
                           detail = "cpu ≥$(round(Int, _WD_CPU_HOT))% for $(length(recent)) samples"))
        end
        # "climbing" over a BOUNDED recent window (~last 30 samples ≈ 60s), not hist[1] — the ring is now up
        # to ~1h long, and comparing against the oldest sample would flag any worker whose rss grew over the
        # hour as "runaway". mw0 is the window's start index.
        mw0 = max(1, length(hist) - 29)
        if latest.rss >= _WD_RSS_CEIL && length(hist) >= 3 && hist[end].rss > hist[mw0].rss
            push!(alerts, (kind = "runaway-mem", scope = "kernel", target = side, since = hist[mw0].rcv,
                           detail = "rss $(_gib(latest.rss)) and climbing"))
        end
        if length(hist) >= 3
            dgc = (hist[end].gc_ms - hist[1].gc_ms) / 1000
            dwall = hist[end].rcv - hist[1].rcv
            (dwall > 0 && dgc / dwall > 0.5) &&
                push!(alerts, (kind = "gc-thrash", scope = "kernel", target = side, since = hist[1].rcv,
                               detail = "gc $(round(Int, 100 * dgc / dwall))% of walltime"))
        end
    end
    status = isempty(alerts) ? "ok" :
             any(a -> a.kind in ("stalled", "runaway-mem", "unreachable"), alerts) ? "critical" :
             "warning"
    rec = (status = status, alerts = alerts, ts = now)
    _health_transition!(nb, rec)
    lock(_WD_LOCK) do; _NB_HEALTH[nb.id] = rec; end
    return rec
end

# Log a line only when an alert first appears or clears — the sweep runs every 5s, so we mustn't
# re-log a standing condition each pass.
function _health_transition!(nb::LiveNotebook, rec)
    prev = lock(_WD_LOCK) do; get(_NB_HEALTH, nb.id, nothing); end
    prevkeys = prev === nothing ? Set{String}() : Set(string(a.kind, ':', a.target) for a in prev.alerts)
    newkeys  = Set(string(a.kind, ':', a.target) for a in rec.alerts)
    for a in rec.alerts
        string(a.kind, ':', a.target) in prevkeys ||
            ReportEngine._rlog("watchdog: $(nb.id) $(a.kind) [$(a.scope) $(a.target)] — $(a.detail)")
    end
    for k in prevkeys
        k in newkeys || ReportEngine._rlog("watchdog: $(nb.id) cleared $k")
    end
    return nothing
end

# JSON view for the health panel / state meta.
# The worker-payload SHA the hub's OWN code was loaded from, stamped at `start_hub`. Compared to the
# live on-disk SHA to tell whether Slate's `src/` changed since THIS server process started. Revise
# applies function-body edits live, but struct/const/new-gate-tool changes don't take until a restart
# — and a silently-stale hub (edits not taking effect) is exactly the confusion that cost us today. So
# we surface a passive "restart to apply" hint rather than trying to hot-reload the live server.
const _HUB_START_SHA = Ref("")
_hub_src_stale() = !isempty(_HUB_START_SHA[]) &&
    (try; ReportEngine._payload_sha() != _HUB_START_SHA[]; catch; false; end)

function _health_json(nb::LiveNotebook)
    rec = nb_health(nb.id)
    stale = _hub_src_stale()
    rec === nothing && return Dict{String,Any}("status" => "ok", "alerts" => Any[], "src_stale" => stale)
    now = time()
    Dict{String,Any}("status" => rec.status, "ts" => rec.ts, "src_stale" => stale,
        "alerts" => Any[Dict{String,Any}("kind" => a.kind, "scope" => a.scope, "target" => a.target,
                                          "since" => a.since, "age" => round(Int, now - a.since),
                                          "detail" => a.detail) for a in rec.alerts])
end

# One shared 5 s sweeper for the whole hub (started once at serve). Timer catches its own errors so a
# transient failure can't kill the loop.
function _ensure_run_supervisor!(h)   # NOTE: `Hub` defined later (server_hub.jl) — untyped so this loads
    _RUN_SUPERVISOR[] === nothing || return nothing
    _RUN_SUPERVISOR[] = Timer(5.0; interval = 5.0) do _
        try; _supervise_runs!(h); catch; end
    end
    return nothing
end

# ── Transfer preview (approve-by-rerun) ─────────────────────────────────────────────────────
# Rides transfer_binding!'s `on_plan` hook, which fires AFTER the encode and the dedup check —
# so the preview quotes the EXACT bytes about to cross (an mmap-backed arrow frame prices as
# its real IPC size; content already on the other side is 0 and never warns). Over the confirm
# threshold, the cell errors ONCE with the preview and the same (cell, value-version) is
# remembered as offered — running the cell again proceeds; a new value version asks again.
# What turns "90 seconds of silent pulling for a typo'd cell" into an informed one-click choice.
const _XFER_OFFERED = Set{Tuple{String,String,String}}()   # (nb id, cell id, token)

function _xfer_plan_gate(nb::LiveNotebook, cell::Cell, host::AbstractString,
                         name, token::String)
    return function (bytes::Int, meta, rate = nothing)
        limit = ReportEngine._xfer_confirm_s()
        (limit <= 0 || bytes <= 0 || isempty(host)) && return nothing
        # `rate` (the caller-priced path bandwidth: peer for a direct move, uplink for relay) wins;
        # fall back to this host's uplink with the conservative floor when it isn't supplied.
        bw = (rate !== nothing && rate > 0) ? Float64(rate) : max(ReportEngine._bw_get(host), 1.0e6)
        secs = bytes / bw
        secs <= limit && return nothing
        key = (nb.id, cell.id, token)
        approved = lock(_REGION_LOCK) do
            key in _XFER_OFFERED ? (delete!(_XFER_OFFERED, key); true) : (push!(_XFER_OFFERED, key); false)
        end
        approved && return nothing
        error("this cell needs '$name' from the other kernel: $(round(Int, bytes / 2^20)) MB " *
              "($(meta === nothing ? "" : String(meta.codec) * ", ")exact) ≈ $(round(Int, secs))s " *
              "at the measured $(round(bw / 1e6; digits = 1)) MB/s to '$host'. Run the cell again " *
              "to transfer it — or tag the cell `remote` to compute where the data lives, or " *
              "derive something smaller over there first. (Threshold: $(round(Int, limit))s.)")
    end
end

# Fold a kernel's NAMESPACE GENERATION into the per-kernel dedup keys. On a worker SWAP (cold spawn /
# pool adopt / reprovision) `ns_gen` bumps → a key that includes it MISSES → the region layer
# re-establishes prime / resource / datadir / transfers on the fresh (empty) namespace. On a REATTACH
# the gen is unchanged → the key hits (the live worker still holds the state). Hashed into the existing
# `UInt` slot so no dedup-Dict type changes. `_kgen` tolerates a non-GateKernel (→ 0) for local kernels.
_kgen(k) = try; k.ns_gen; catch; 0; end
_worker_key(k)::UInt = hash((objectid(k), _kgen(k)))

# Tolerant field read off a gate-tool result — a NamedTuple locally, but a JSON3.Object (Symbol
# props) or a Dict (String/Symbol keys) once it's ridden back over the gate. Returns `dv` on any miss.
function _gf(o, k::Symbol, dv)
    try
        o isa AbstractDict && return haskey(o, k) ? o[k] : get(o, String(k), dv)
        return hasproperty(o, k) ? getproperty(o, k) : dv
    catch
        return dv
    end
end

# Established `:resource` handles, per (nb id, dst kernel objectid, resource cell src_hash) — a handle
# opens ONCE per kernel and is re-opened only if its source changes or the kernel is replaced.
const _REGION_RESOURCED = Dict{Tuple{String,UInt,UInt},Bool}()

# Establish a `:resource` cell's per-worker state (a live DB / file / socket handle) on `dst_k` by
# RE-RUNNING its source there — a live handle can't cross a region boundary (it deserializes to a
# dangling pointer), so each side opens its OWN. Same reason the memo layer re-inits a resource on
# restore instead of caching it (`_memoizable`); this is the region analogue, and it mirrors how
# `_prime_namespace!` re-establishes using/import/theme and `_replay_scaffold!` replays on restore.
# Each cross-side INPUT the resource needs is staged first: a `:resource` upstream is replayed
# recursively (e.g. `db` needs the side-local `dbpath = @sfile(…)`, which must resolve to THIS side's
# datadir, so it too replays rather than shipping main's path); anything else is portable data and is
# transferred. Dedup per (nb, dst kernel, source) so a shared handle opens exactly once per kernel.
function _ensure_resource_on!(nb::LiveNotebook, cell::Cell, dst_k, dst_side::AbstractString;
                              seen::Set{UInt} = Set{UInt}())
    key = (nb.id, _worker_key(dst_k), cell.src_hash)
    lock(_REGION_LOCK) do; get(_REGION_RESOURCED, key, false); end && return nothing
    cell.src_hash in seen && return nothing        # diamond/cycle guard within a single establish
    push!(seen, cell.src_hash)
    for r in cell.reads
        r === ReportEngine._THEME_SENTINEL && continue
        writer = nothing
        for o in nb.report.cells
            (o !== cell && r in o.writes && _cell_side(nb, o) != dst_side &&
             !ReportEngine._is_pure_using(o.source)) && (writer = o; break)
        end
        (writer === nothing || writer.output === nothing || r in writer.provides) && continue
        if ReportEngine._cell_effect(writer) == ReportEngine.RESOURCE
            _ensure_resource_on!(nb, writer, dst_k, dst_side; seen)      # a per-worker upstream → replay it too
        else
            src_k = _side_kernel!(nb, _cell_side(nb, writer))            # portable input → ship the value
            try
                ReportEngine.prepare!(src_k, nb.report)
                ReportEngine.transfer_binding!(src_k, dst_k, string(r);
                                               zc = !any(o -> r in o.mutates, nb.report.cells),
                                               mode = _region_xfer_mode())
            catch e
                ReportEngine._rlog("resource: staging '$r' for cell $(cell.id) on " *
                    "$(_side_label(nb, dst_side)) failed — $(first(sprint(showerror, e), 160))")
            end
        end
    end
    # Open the handle HERE by replaying the cell's source on `dst_k` — its value never crosses the wire.
    tag = "cell:" * cell.id * "#resource@" * (isempty(dst_side) ? "main" : dst_side)
    ReportEngine.eval_capture(dst_k, nb.report, cell.source, tag, nothing)
    opened = isempty(cell.writes) ? cell.id : join(cell.writes, ", ")
    ReportEngine._rlog("resource: opened $opened on $(_side_label(nb, dst_side)) — " *
                       "replayed cell $(cell.id) (handle not shipped)")
    lock(_REGION_LOCK) do; _REGION_RESOURCED[key] = true; end
    return nothing
end

# Which transport the region runner asks `transfer_binding!` to use for a cross-boundary value.
# Default `:auto` — try a direct worker→worker pull (one leg) and fall back to the hub relay when
# not viable (see WORKER_CHANNEL_SPIKE.md). `KAIMONSLATE_REGION_XFER=relay` is the kill switch (force
# the star); `=direct` forces strict direct (errors if not viable — useful when validating the path).
function _region_xfer_mode()
    v = lowercase(strip(get(ENV, "KAIMONSLATE_REGION_XFER", "")))
    v == "relay" ? :relay : v == "direct" ? :direct : :auto
end

# Ship every cross-boundary input of `cell` to the kernel it is about to run on: each read name
# whose latest WRITER lives on the other kernel, skipped when the writer's freshness token says
# the destination already holds that exact run's value (dedup makes a re-ship of an unchanged
# value one round-trip even when the token is lost). A `:resource` writer is the exception — its
# per-worker handle is REPLAYED on the reader (see `_ensure_resource_on!`), never shipped. Runs BEFORE
# the cell — DAG order guarantees writers already ran. Throws (→ the cell errors) if a value can't cross.
function _region_presync!(nb::LiveNotebook, cell::Cell, dst_k; dst_side::AbstractString = _cell_region(cell))
    _region_active(nb) || return nothing
    # ── Validity gate: cross-boundary MUTATION is invalid, and must fail FAST and clearly.
    # Without this, `df[!, :col] = …` in a local cell against a region-held df would pull the
    # whole value over the wire (minutes for a big frame), mutate the LOCAL COPY, and leave the
    # region's original untouched — remote re-runs then silently disagree with what the user
    # believes the value is. The fix is a choice only the author can make, so say so.
    for m in cell.mutates
        owner = nothing
        for o in nb.report.cells
            (o !== cell && m in o.writes && _cell_side(nb, o) != dst_side &&
             !ReportEngine._is_pure_using(o.source)) && (owner = o; break)
        end
        owner === nothing && continue
        error("cell mutates '$m', which lives on " * _side_label(nb, _cell_side(nb, owner)) *
              " (written by cell $(owner.id)) — but this cell runs on " * _side_label(nb, dst_side) *
              " (it mutates values owned elsewhere, or its region tag pins it away from its " *
              "data). Mutating across a region boundary would fork the value. Split the cell " *
              "so each mutation runs where its value lives, or derive a NEW binding instead " *
              "(e.g. $(m)2 = transform($m, …)).")
    end
    # Portable data: ensure this remote worker has the notebook's datadir() files (`@sfile`) before it
    # runs — content-addressed, dedup-aware, once per kernel. Best-effort; a miss just errors in-cell.
    try; _sync_datadir_to!(nb, dst_k; cell_id = cell.id); catch e; @warn "slate region: datadir sync failed" cell = cell.id exception = e; end
    prepared = false
    for r in cell.reads
        # The theme sentinel (`##makie_theme##`) is a synthetic ordering/effect token the graphics
        # analysis injects to chain `set_theme!` cells → figures — NOT a real global. Shipping it
        # errors ("no global named …"); the theme EFFECT belongs on each side, not the wire.
        r === ReportEngine._THEME_SENTINEL && continue
        writer = nothing
        for o in nb.report.cells
            (o !== cell && r in o.writes && _cell_side(nb, o) != dst_side) && (writer = o; break)
        end
        writer === nothing && continue                   # same-side (or bind/global) input — nothing to do
        writer.output === nothing && continue            # writer never ran (errored upstream) — its cell will show why
        # A name the writer PROVIDES — a `using`/`import` export or a Slate-injected helper harvested
        # into the import scaffold (`ylims!`, `Slider`, `Figure`, …) — is NAMESPACE, not data: it's
        # defined on EVERY kernel already (the using-mirror + helper injection). Shipping it errors
        # (assign-to-const, or JLS decode without the package). Only genuine data writes cross.
        # More broadly: a value WRITTEN BY A EVERYWHERE cell (pure `using`, an import SCAFFOLD like
        # `using X; render_graph(…) = …`, a theme setter) is re-established on each side by PRIMING
        # that cell's whole source (`_prime_namespace!`), so a FUNCTION/const it defines must not ship
        # either — such a value lives in the notebook's anonymous `NB` module, which JLS records as
        # `Main.NB.<name>` and the far side (no `Main.NB` binding) can't decode. Priming defines it
        # natively there instead. (Subsumes the old pure-`using` skip.)
        (r in writer.provides || ReportEngine._cell_effect(writer) == ReportEngine.EVERYWHERE) && continue
        src_side = _cell_side(nb, writer)
        src_k = _side_kernel!(nb, src_side)
        # A `:resource` writer is a live per-worker handle (DB / file / socket) — it must NOT cross the
        # wire (it would land as a dangling pointer). Open it on THIS side instead: replay the resource
        # cell's source on `dst_k` so the reader gets its own handle (its upstreams staged inside).
        if ReportEngine._cell_effect(writer) == ReportEngine.RESOURCE
            if !prepared
                ReportEngine.prepare!(src_k, nb.report); ReportEngine.prepare!(dst_k, nb.report)
                _prime_namespace!(nb, src_k, src_side); _prime_namespace!(nb, dst_k, dst_side)
                prepared = true
            end
            _ensure_resource_on!(nb, writer, dst_k, dst_side)
            continue
        end
        # Freshness token: the writer's latest run PLUS every same-side mutator's — a mutation
        # changes the value without touching the writer, and a stale transfer would resurrect
        # the pre-mutation bytes on the other side.
        token = string(writer.src_hash, ':', objectid(writer.output))
        # A `@bind` value changes WITHOUT its widget cell re-running — the output objectid is stable,
        # so fold the current bound value into the token. Else a slider move on one region never
        # re-ships the new value to a reader on ANOTHER region (dedup sees an unchanged token → the
        # downstream cell recomputes with the stale value).
        for b in writer.binds
            b.name === r && (token *= string('@', b.value))
        end
        for o in nb.report.cells
            (o !== cell && r in o.mutates && _cell_side(nb, o) == src_side && o.output !== nothing) &&
                (token *= string('+', o.src_hash, ':', objectid(o.output)))
        end
        # Manual `needs=` edges harden the boundary too: a linked predecessor running on the
        # writer's side may be the hidden mutator the edge exists to declare — fold its runs in,
        # so the single-kernel edge workaround keeps working across a region boundary. A false
        # positive just re-ships an unchanged value, which content addressing dedups.
        for t in ReportEngine._manual_needs(cell)
            j = _index_of(nb.report.cells, t); j === nothing && continue
            o = nb.report.cells[j]
            (o.output !== nothing && _cell_side(nb, o) == src_side) &&
                (token *= string('~', o.src_hash, ':', objectid(o.output)))
        end
        # `:g<gen>` folds the dst worker's namespace generation in, so a SWAP (fresh namespace) re-ships
        # this value (the new worker doesn't hold it) while a reattach still dedups.
        key = string(isempty(dst_side) ? "main" : dst_side, ':', r, ":g", _kgen(dst_k))
        seen = lock(_REGION_LOCK) do; get(get(_REGION_SYNCED, nb.id, Dict{String,String}()), key, ""); end
        seen == token && continue
        if !prepared                                      # both wires must be up before the first move
            ReportEngine.prepare!(src_k, nb.report)       # (idempotent + cheap when already connected;
            ReportEngine.prepare!(dst_k, nb.report)       #  a cold region kernel spawns/adopts here)
            # The env must be present on BOTH sides: prime each with the notebook's imports so the
            # receiver can decode what crosses (fixes "KeyError DataFrames" when a frame lands on a
            # kernel that never ran `using DataFrames`). Idempotent + tracked per kernel.
            _prime_namespace!(nb, src_k, src_side)
            _prime_namespace!(nb, dst_k, dst_side)
            prepared = true
        end
        # Portability guard: a live handle (DB / socket / file — a `Ptr`) shipped across a boundary
        # lands as a dangling pointer and throws a cryptic error on the far side (the "Failed to open
        # connection" trap). Catch it HERE, where we can name the binding and the fix, instead. Runs
        # only on an ACTUAL transfer (past the token dedup) → one cheap check per crossing value.
        port = try
            ReportEngine._tool(src_k, "__slate_portable", Dict{String,Any}("name" => string(r)); timeout = 20.0)
        catch; nothing; end
        if port !== nothing && _gf(port, :portable, true) === false
            ptype = string(_gf(port, :type, "a handle")); preason = string(_gf(port, :reason, "a live handle"))
            error("cell needs '$r' from " * _side_label(nb, src_side) * ", but it's a " * ptype *
                  " — " * preason * " that can't cross to " * _side_label(nb, dst_side) *
                  ". Tag the cell that creates '$r' as `resource` so each side opens its OWN handle " *
                  "(e.g. from `@sfile(...)`) rather than shipping it — a live DB/socket/file handle is " *
                  "process state, no more transferable than it is cacheable.")
        end
        # zero-copy materialization is safe when nothing anywhere mutates the name
        zc = !any(o -> r in o.mutates, nb.report.cells)
        # the wire host prices the preview: whichever side of this transfer is remote
        whost = src_k.target isa ReportEngine.RemoteTarget ? src_k.target.ssh_host :
                dst_k.target isa ReportEngine.RemoteTarget ? dst_k.target.ssh_host : ""
        # Live progress: chunk callbacks drive the cell's ordinary progress bar over the
        # notebook SSE stream — a 70s pull is a labeled bar, not a silent spinner. Throttled to
        # meaningful movement (≥2% or done) so a fast transfer doesn't flood the stream.
        lastfrac = Ref(0.0)
        arrow = isempty(dst_side) ? "←" : "→"
        onprog = (done, total) -> begin
            total <= 0 && return nothing
            f = done / total
            (f - lastfrac[] >= 0.02 || done >= total) || return nothing
            lastfrac[] = f
            ReportEngine._do_userprog(nb.report.id, f,
                "⇄ $(r): $(round(Int, done / 2^20))/$(round(Int, total / 2^20)) MB $arrow $whost",
                "xfer-" * cell.id, done >= total)
            return nothing
        end
        t0 = time()
        t = ReportEngine.transfer_binding!(src_k, dst_k, string(r); zc = zc, mode = _region_xfer_mode(),
                                           on_plan = _xfer_plan_gate(nb, cell, whost, r, token),
                                           on_progress = onprog,
                                           cellkey = ReportEngine._memo_key(nb.report, writer))   # lets the source restore from memo if its worker swapped
        secs = round(time() - t0; digits = 1)
        ReportEngine._rlog("region: '$(r)' → $(_side_label(nb, dst_side)) " *
            (t.bytes == 0 ? "(deduped — already in the destination CAS via $(t.mode), 0 bytes moved) " :
                            "($(t.bytes) bytes over the wire in $(secs)s, $(t.codec), $(t.mode)) ") *
            "for cell $(cell.id)")
        t.bytes > 0 && _stats_xfer!(nb, cell.id,
            "'$(r)' $(round(t.bytes / 2^20; digits = 1)) MB $(t.codec) in $(secs)s $arrow $whost", t.bytes)
        lock(_REGION_LOCK) do
            get!(_REGION_SYNCED, nb.id, Dict{String,String}())[key] = token
        end
    end
    return nothing
end

# Evaluate ONE cell with the lock-release discipline. Markdown (fast interp) runs under the lock;
# code marks RUNNING + announces under the lock, evals WITHOUT it, then merges under the lock iff the
# cell still exists unchanged (src_hash match) — else the result is from a superseded run, discarded.
# Ensure `cell`'s region kernel is reachable + primed before it runs there. Applies the reconnect-hold
# policy and the (possibly slow, cold) bring-up + namespace prime, surfacing any failure AS the cell's
# error. Returns true to proceed, false when the cell was already resolved (held/errored) and the caller
# should return. A no-op (returns true) for a main-kernel cell (`side == ""`). Shared by code + markdown.
function _prepare_region_for_cell!(nb::LiveNotebook, cell::Cell, kernel, side::AbstractString)
    isempty(side) && return true
    # Reconnect-hold policy (manual mode). A cell EXPLICITLY run (▶ force marker) reconnects a region that
    # was dropped as dead; a reactive cascade must not. Peek the force marker WITHOUT consuming it (the
    # memo build later consumes it): a forced cell clears the hold on ALL the notebook's kernels, so an
    # explicit run of even a DOWNSTREAM cell reconnects the upstream region it needs. A non-forced cell
    # whose OWN region is held errors here instead of silently cold-spawning a replacement worker.
    forced = lock(nb.lock) do
        ids = get(_FORCE_RUN, nb.id, nothing); ids !== nothing && cell.id in ids
    end
    if forced
        _clear_region_holds!(nb)
    elseif _kernel_held(kernel)
        lock(nb.lock) do
            ReportEngine.mark_errored!(cell,
                "region '$side' is disconnected — a previous worker went unresponsive; press ▶ (or re-run) to reconnect")
            _broadcast_progress(nb, cell)
        end
        return false
    end
    # A cell running on a REGION needs the notebook's environment established there first — its own
    # `using`/scaffold cells may live on the main kernel (they aren't cross-boundary READS, so a presync
    # won't ship them). Bring the kernel up and prime it (idempotent, once per kernel) so the package's
    # functions, the theme, … all resolve instead of an UndefVarError on the far side. Bringing up a
    # region worker can be SLOW — a COLD remote spawn boots Julia + KaimonGate (~90s) — so mark the cell
    # RUNNING now and push the worker list so the region PILL appears immediately as a pulsing "starting".
    host = _side_label(nb, side)
    lock(nb.lock) do
        ReportEngine.mark_running!(cell)
        _broadcast_progress(nb, cell)
    end
    try; _workers_push!(nb); catch; end   # pill appears NOW as "starting", not after the run completes
    try
        ReportEngine.prepare!(kernel, nb.report)
        _prime_namespace!(nb, kernel, side)
        try; _workers_push!(nb); catch; end   # connected → pill flips out of "starting"; telemetry takes over
        return true
    catch e
        ReportEngine._rlog("region: prime before $(cell.id) on $host failed: " *
                           first(sprint(showerror, e), 160))
        # The region worker couldn't come up — surface it AS the cell's error and STOP. Running on the
        # dead kernel just errors anyway, but leaving the cell unresolved let the runner re-arm and churn.
        lock(nb.lock) do
            ReportEngine.mark_errored!(cell, "region worker on $host could not start: " *
                first(sprint(showerror, e), 160))
            _broadcast_progress(nb, cell)
        end
        try; _workers_push!(nb); catch; end   # push the failure → pill goes amber/disconnected, not stuck "starting"
        return false
    end
end

function _eval_one!(nb::LiveNotebook, cell::Cell)
    # Region dispatch: the `region=` tag decides the kernel; a mutation auto-follows its data (see
    # _region_route). Markdown honors its tag too — its `$(…)` interpolation runs on that region's worker.
    kernel, side = _region_route(nb, cell)
    if cell.kind == MARKDOWN
        # Tagged markdown interpolates on its region (bring the kernel up first, like a code cell); an
        # untagged md (side=="") stays on main. Presync pulls any cross-boundary names it interpolates.
        _prepare_region_for_cell!(nb, cell, kernel, side) || return nothing
        _region_active(nb) && !isempty(side) && _stats_ran_on!(nb, cell.id, _side_label(nb, side))
        try; _region_presync!(nb, cell, kernel; dst_side = side); catch e; @warn "slate region: md presync failed" cell = cell.id exception = e; end
        # `eval_cell!` runs the md `$(…)` interpolation on the worker — a kernel round-trip — so it runs
        # OFF nb.lock (protocol; mirrors the code-cell branch below). Re-take the lock only to push state.
        ReportEngine.eval_cell!(nb.report, cell, kernel)
        isempty(side) || lock(nb.lock) do; _broadcast_progress(nb, cell); end   # region md set RUNNING above → push the final state
        return nothing
    end
    # The cell's cross-boundary inputs ship over after the kernel is primed. A presync failure is the
    # CELL's error — surfaced in place instead of a mystery UndefVarError on the other side.
    _prepare_region_for_cell!(nb, cell, kernel, side) || return nothing
    # Provenance for the DAG/stats: which kernel this run executes on (only meaningful — and
    # only recorded — while a region is active; users otherwise know where cells run).
    _region_active(nb) && _stats_ran_on!(nb, cell.id, _side_label(nb, side))
    presync_err = try
        _region_presync!(nb, cell, kernel; dst_side = side)
        nothing
    catch e
        sprint(showerror, e)
    end
    if presync_err !== nothing
        lock(nb.lock) do
            ReportEngine.mark_errored!(cell, "region boundary transfer failed: " * presync_err)
            _broadcast_progress(nb, cell)
        end
        return nothing
    end
    src, srchash, memo, locked = lock(nb.lock) do
        ReportEngine.mark_running!(cell)
        _broadcast_progress(nb, cell)
        s = (:trace in cell.flags) ? string("@trace begin ", cell.source, "\nend") : cell.source
        frc = let ids = get(_FORCE_RUN, nb.id, nothing)   # consume a one-shot ▶ force marker
            ids !== nothing && cell.id in ids ?
                (delete!(ids, cell.id); isempty(ids) && delete!(_FORCE_RUN, nb.id); true) : false
        end
        # The cell's genuinely-DEFINED names: writes minus `provides` (names brought in by
        # `using`/`import`) and minus @bind CONTROL variables. A provided name is a function/module
        # reference, not a value to cache; a bind variable is a UI `Choice`/value that the `@bind` REPLAY
        # re-establishes on restore (`_replay_scaffold!`) — snapshotting it would serialize a wrapper
        # object into the durable store (and a decode failure would sink the whole entry). Same
        # scaffold pattern as `using` exports. Matters for `:using_redundant` and MIXED (`@bind x W; y =
        # solve(x)`) cells: only the genuine compute (`v`/`y`) is cached. For ordinary cells both sets
        # are empty, so this is a no-op.
        bindnames = Set{Symbol}(b.name for b in cell.binds)
        defs = Set{Symbol}(w for w in cell.writes
                           if !(w in cell.provides) && !(w in bindnames) && w !== ReportEngine._THEME_SENTINEL)
        # Writes no OTHER cell reads — eligible for display-object elision at store time (the
        # worker decides by TYPE: a Makie Figure nobody reads stores as its wire image only, not
        # a multi-MB scene graph). Passed at restore time too: an entry that elided a name which
        # has SINCE gained a reader is treated as a miss, so the re-run re-stores the real object.
        unread = String[string(w) for w in defs
                        if !any(o -> o !== cell && w in o.reads, nb.report.cells)]
        # Writes no OTHER cell mutates — zero-copy-safe at restore time (mmap / arrow-backed view
        # instead of a materialized copy; a mutation attempt on one THROWS rather than corrupting
        # the immutable CAS blob — the graph's `mutates` analysis is the safety proof).
        safe = String[string(w) for w in defs
                      if !any(o -> o !== cell && w in o.mutates, nb.report.cells)]
        # Snapshot the defined names ∪ mutates. The analysis maintains mutates ⊆ writes (a mutator
        # IS a writer), so this union normally adds nothing — it ENFORCES the property the entry's
        # faithfulness depends on: an entry missing a mutated name restores the pre-mutation
        # namespace while downstream entries carry post-mutation results.
        # `locked`: reuse the FROZEN key from the run this cell locked on (instead of the freshly
        # computed one, which would reflect any upstream drift since) — unless this is the explicit
        # ▶ force re-run, which always re-keys fresh (it's the one thing allowed to move the lock).
        locked = :locked in cell.flags
        key = ReportEngine.target_key(cell, nb.report; forced = frc)
        m = (key = key,
             names = unique!(String[string(w) for w in Iterators.flatten((defs, cell.mutates))
                                    if w !== ReportEngine._THEME_SENTINEL && !(w in bindnames)]),
             threshold = ReportEngine._MEMO_THRESHOLD_MS,
             force = frc,
             always = (:cache in cell.flags) || locked,   # `cache`/`locked` → persist regardless of runtime
             unread = unread, safe = safe)
        (s, cell.src_hash, m, locked)
    end
    out = try
        # `region`/`regions` seed the cell's task-local Slate execution context (`slate_context()`): the
        # effective side it runs on ("" = main) + the notebook's declared regions. Generic — a region-aware
        # package reads it to default its own args; no package-specific knowledge lives here.
        ReportEngine.eval_capture(kernel, nb.report, src, "cell:" * cell.id, memo;
                                  region = side, regions = _nb_region_names(nb))
    catch e
        ReportEngine.CellOutput("", ReportEngine.MimeChunk[], Any[], Any[], ReportEngine.BindSpec[],
                                "", sprint(showerror, e), nothing, 0.0)
    end
    # Namespace parity: a pure `using`/`import` cell runs on EVERY active side when a region is
    # in play — region cells need the same modules loaded. Mirrors run on main + each region any
    # cell references, except the side that just ran. Results discarded (the main run's output
    # stands); a failure logs rather than erroring the cell (that side surfaces it on first use).
    if _region_active(nb) && ReportEngine._is_pure_using(cell.source) && out.exception === nothing
        sides = Set{String}([""])
        for c in nb.report.cells
            s = _cell_region(c); isempty(s) || push!(sides, s)
        end
        delete!(sides, side)
        for sd in sides
            try
                other = _side_kernel!(nb, sd)
                r2 = ReportEngine.eval_capture(other, nb.report, src, "cell:" * cell.id * "#mirror", nothing)
                r2.exception === nothing ||
                    ReportEngine._rlog("region: `using` mirror of $(cell.id) failed on $(_side_label(nb, sd)): $(first(String(r2.exception), 200))")
            catch e
                ReportEngine._rlog("region: `using` mirror of $(cell.id) errored on $(_side_label(nb, sd)): $(first(sprint(showerror, e), 200))")
            end
        end
    end
    relock = lock(nb.lock) do
        i = _index_of(nb.report.cells, cell.id)
        i === nothing && return nothing                  # deleted mid-run → drop
        c = nb.report.cells[i]
        if c.src_hash != srchash
            # Edited mid-run: the in-flight result is for the OLD source — discard it AND mark the
            # cell STALE so the runner re-runs it with the new source (it may have been left RUNNING).
            ReportEngine.revert_running!(c)
            return nothing
        end
        ReportEngine.mark_result!(c, out)
        c.binds = out.binds
        _apply_cell_effects!(nb, c, out)                 # code→Slate declarations (e.g. :everywhere classification)
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        _broadcast_progress(nb, c)
        # A successful `locked` run freezes ON this key: persist it (surviving a restart — the `.jl`
        # footer round-trips `c.flags`) and swap the durable-store pin, outside the lock (a gate RPC —
        # see `memo_pin!`). A forced re-run or the first freeze also bumps the FREEZE STAMP (code-key +
        # run time) so downstream memo keys track a new frozen value even when the source (hence the
        # computed key) didn't move — the benchmark / training-run case: same code, new output. A plain
        # restore-run is never forced and already has a key, so it leaves both untouched.
        if locked && c.state == FRESH
            old = ReportEngine._locked_key(c)
            moved = memo.key != old
            moved && ReportEngine._set_locked_key!(c, memo.key)
            # Freeze identity = a hash of the OUTPUT: stable across restores (same value → same stamp),
            # and it changes whenever the frozen value is refreshed (a force ▶, or any fresh compute that
            # yields a new value). Downstream memo keys fold this in, so a dependent re-keys ONLY when the
            # frozen value actually changes — the benchmark / training-run case (same code, new output).
            # Output-based, so it's independent of HOW the run was triggered (no reliance on the force
            # marker, which a non-`▶` re-run path may not set).
            oldstamp = ReportEngine._frozen_stamp(c)
            newstamp = string(hash(out === nothing ? "" : out.value_repr); base = 16)
            newstamp == oldstamp || ReportEngine._set_frozen_stamp!(c, newstamp)
            (moved || newstamp != oldstamp) && _persist!(nb; label = "locked · $(c.id)")
            (moved && !isempty(old)) ? (old, memo.key) : nothing
        else
            nothing
        end
    end
    if relock !== nothing
        old, new = relock
        isempty(old) || ReportEngine.memo_pin!(kernel, nb.report, old, false)
        ReportEngine.memo_pin!(kernel, nb.report, new, true)
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

# Persist hook for the Settings panel's data-transfer knobs (chunk MB, carry ceiling s) — same
# division of labor as _RUNON_PERSIST: KaimonSlate installs `(chunk_mb, carry_s) -> nothing`
# which sets the live ReportEngine refs AND writes slate.json.
const _XFER_PERSIST = Ref{Any}(nothing)

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
    # A notebook with an active region runs SERIALLY (v1): the batch hands all cells to ONE
    # worker, but region cells belong to another kernel and boundary values must cross between
    # dependency-ordered runs — the per-cell path handles both.
    _region_active(nb) && return false
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
                ReportEngine.mark_errored!(cell, "InterruptException: run cancelled")
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
            ReportEngine.revert_running!(c)                # edited mid-batch → re-run with new source
            return
        end
        ReportEngine.mark_result!(c, out)
        c.binds = out.binds
        _apply_cell_effects!(nb, c, out)                 # code→Slate declarations (e.g. :everywhere classification)
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        _broadcast_progress(nb, c)
    end
    return nothing
end

# Re-establish a fresh main-kernel namespace (see `_MAIN_GEN`). Called at the top of every drain: bring the
# worker up, and if its `ns_gen` advanced since we last primed it, (1) SEED the worker's bind registry with
# the host's authoritative control values — so a bind cell that re-runs OR restores reconciles to the user's
# selection, not the widget default (the value can't drift from the cached compute keyed on it) — and (2)
# re-stale every code cell so the drain re-runs/restores them against the blank namespace (memoized cells
# RESTORE, not recompute). In-process kernels (no `ns_gen`) and reattaches (gen unchanged) are no-ops. This is
# the main-kernel counterpart to the region layer's ns_gen-keyed re-priming.
function _reestablish_fresh_namespace!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return nothing               # in-process never swaps namespaces
    try; ReportEngine.prepare!(nb.kernel, nb.report); catch; return nothing; end   # up (bumps ns_gen if fresh)
    wk = _worker_key(nb.kernel)
    lock(_MAIN_GEN_LOCK) do; get(_MAIN_GEN, nb.id, UInt(0)); end == wk && return nothing   # reattach → unchanged
    # Genuinely re-execute EVERYWHERE cells' full source on the main kernel — the SAME mechanism
    # `_prepare_region_for_cell!` already uses for region kernels (`_prime_namespace!` is kernel-
    # agnostic: its own idempotency cache is keyed by `(nb.id, _worker_key(k))`, so calling it here
    # is safe and a no-op once already primed for this process). This establishes theme/using/
    # scaffold effects correctly EARLY, ahead of any dependent cell, rather than relying solely on
    # `_eval_one!`'s memo-restore replay (`_replay_scaffold!`) to catch every EVERYWHERE effect —
    # that replay only recognizes specific syntax forms (imports, `@bind`, a fixed theme-call
    # whitelist) and can silently miss one it wasn't taught about. EVERYWHERE cells still go through
    # the ordinary drain below too (full bookkeeping: stats, broadcast, region `using` mirroring) —
    # a harmless redundant re-run, since EVERYWHERE cells are cheap/effect-only by definition.
    try; _prime_namespace!(nb, nb.kernel, ""); catch e
        @debug "slate: main-kernel namespace prime failed" notebook = nb.id exception = e
    end
    binds = lock(nb.lock) do
        bs = Tuple{Symbol,Any}[(b.name, b.value) for c in nb.report.cells for b in c.binds]
        for c in nb.report.cells                       # a blank namespace ⇒ every global is gone: re-run/restore all
            c.kind == ReportEngine.CODE && ReportEngine.restale!(c)
        end
        bs
    end
    for (name, value) in binds                         # seed the fresh registry with the host's current values
        try; ReportEngine.assign_bind!(nb.kernel, nb.report, name, value)
        catch e; @debug "slate: bind re-seed failed on fresh namespace" name exception = e; end
    end
    lock(_MAIN_GEN_LOCK) do; _MAIN_GEN[nb.id] = wk; end
    return nothing
end

function _run_loop!(nb::LiveNotebook)
    try
        _reestablish_fresh_namespace!(nb)   # a swapped/fresh worker → seed binds from host + re-stale (before draining)
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
        cancelled = false
        while true
            # Checked between cells (not mid-eval) — the notebook was closed out from under this
            # drain (see `_RUNNER_CANCEL`'s docstring). Stop cleanly rather than keep running
            # against a torn-down `nb`, or worse, being unkillable and blocking a reopen forever.
            if lock(_RUNNER_LOCK) do; get(_RUNNER_CANCEL, nb.id, false); end
                cancelled = true
                ReportEngine._rlog("slate: runner for $(nb.id) stopped — notebook was closed mid-drain")
                break
            end
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
        cancelled && return nothing   # skip post-drain graph refinement/re-arm — the notebook is gone
        # Drained: any bare-`using` barrier cells have now run, so resolve their exports and rebuild
        # the graph precisely (no restale — see refine_usings!). Push fresh state so the UI drops the
        # "barrier" marking. Kept off the hot per-cell path — it fires once per drain and no-ops unless
        # a NEW module got resolved.
        # PROTOCOL: the export/macro RESOLVE and the extension-manifest pull are kernel round-trips, so
        # they run OFF nb.lock (`rebuild=false`); we re-take the lock ONLY for the graph rebuild + version
        # bump (report mutations). Holding nb.lock across these was the teardown-deadlock hazard. (`again`
        # re-arm below re-drains any cell left stale — covering the racer-restale refine_macros! skips.)
        resolved_u = ReportEngine.refine_usings!(nb.report, nb.kernel; rebuild = false)
        # `rebuild=false` returns before the racer-restale (it needs the rebuilt graph) — a parallel drain's
        # raced readers are re-drained by the `again` re-arm below instead.
        resolved_m = ReportEngine.refine_macros!(nb.report, nb.kernel; rebuild = false)
        # A package loaded this drain may have declared front-end scripts (widget renderers, editor
        # extensions) from `__init__` — pull the worker's extension manifest into the notebook registry so
        # the browser injects them. Once-per-drain; no-ops unless a NEW package registered something.
        resolved_x = _refresh_extensions!(nb)
        if resolved_u || resolved_m || resolved_x
            with_report(nb) do report
                (resolved_u || resolved_m) && ReportEngine.rebuild_precise!(report)   # rebuild only if the graph changed
                nb.version += 1
            end
            _broadcast(nb, string(nb.version))   # version token → browser re-pulls the precise-graph state
        end
        lock(_RUNNER_LOCK) do; delete!(_RUNNER_FAILS, nb.id); end   # clean drain (cells may have ERRORED, but no throw) → clear the streak
    catch e
        fails = lock(_RUNNER_LOCK) do; _RUNNER_FAILS[nb.id] = get(_RUNNER_FAILS, nb.id, 0) + 1; end
        @warn "slate async runner error" notebook = nb.id fails = fails exception = (e, catch_backtrace()) maxlog = 5
        # A throw that leaves work pending would re-arm INSTANTLY below → a tight busy-loop that pins the
        # hub and floods the log (seen: a dead region churned to a 1GB log). Back off (capped) so a wedged
        # drain retries slowly, not hot.
        sleep(min(0.5 * fails, 15.0))
    finally
        was_cancelled = lock(_RUNNER_LOCK) do
            delete!(_RUNNERS, nb.id)
            delete!(_RUNNER_STARTED, nb.id)
            delete!(_RUNNER_STALE_HITS, nb.id)
            c = get(_RUNNER_CANCEL, nb.id, false)
            delete!(_RUNNER_CANCEL, nb.id)         # don't poison a LATER reopen's fresh runner
            c
        end
        if !was_cancelled
            again = lock(nb.lock) do; _next_stale_cell(nb.report) !== nothing; end
            # Give up re-arming after too many consecutive failures — the work is wedged (a dead region, a cell
            # that can't resolve). A user edit / explicit re-run clears the counter (the drain path above) and
            # revives it. Without this cap a permanently-failing pass spins forever.
            giveup = lock(_RUNNER_LOCK) do; get(_RUNNER_FAILS, nb.id, 0) >= 20; end
            if again && !giveup
                _ensure_runner!(nb)
            elseif again && giveup
                ReportEngine._rlog("slate: notebook $(nb.id) runner gave up after 20 failed passes — edit or re-run a cell to retry")
            end
        end
    end
    return nothing
end

# Start the runner if one isn't already draining (idempotent). Announces the batch size for the k/N pill.
function _ensure_runner!(nb::LiveNotebook)
    started = lock(_RUNNER_LOCK) do
        get(_RUNNERS, nb.id, false) && return false
        _RUNNERS[nb.id] = true
        _RUNNER_CANCEL[nb.id] = false
        _RUNNER_STARTED[nb.id] = time()
        delete!(_RUNNER_STALE_HITS, nb.id)
        return true
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
    # A cell rarely reads the EXACT edited def — it calls a higher-level function that uses it (a cell
    # calls `f`, which internally calls the edited `g`). But editing any def in a package
    # changes the whole project's src digest, so every cell USING that package is affected — and would
    # recompute on rerun anyway (the memo key folds the src digest). So expand the changed set with all
    # names PROVIDED by a cell that provides one of the changed names — i.e. the `using <Pkg>` cell's
    # in-scope exports — turning "one exported name changed" into "everything using that package is stale".
    lock(nb.lock) do
        for c in nb.report.cells
            (isempty(c.provides) || !any(p -> p in syms, c.provides)) && continue
            union!(syms, c.provides)
        end
    end
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
            ReportEngine.restale!(c) && (push!(seed, c.id); push!(staled, c.id))
        end
        isempty(seed) && return
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing && continue
            ReportEngine.restale!(nb.report.cells[i]) && push!(staled, id)
        end
    end
    # Never silent: a real source def changed. If we mapped it to cells they're now stale (Run stale);
    # if we mapped it to NONE (a helper no cell uses by name, or an over-narrow match), broadcast 0 so
    # the UI still says "source changed — affected cells unknown, Run all to be safe" instead of leaving
    # the notebook looking untouched.
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
function start_server(path::AbstractString; host = "127.0.0.1", port = 8765, inactive::Bool = false)
    h = start_hub(; host = host, port = port)
    id = open_notebook!(h, path; inactive = inactive)
    @info "Notebook" url = "$(_hub_url(h))/n/$id" file = abspath(path)
    return h
end

# Flip a dormant (inactive) notebook to live and kick off its bring-up: a self-contained bundle
# reconstructs its env first (`_hydrate_standalone!`); a plain notebook just boots its worker + runs
# (`_boot_and_run!`). Both restore locked/memo results instead of recomputing. Returns true if it
# actually launched (false = already active). Shared by `/api/{id}/launch` and serve_notebook's `b` key.
function launch_notebook!(nb::LiveNotebook)
    hasbundle = try; _has_bundle(read(nb.path, String)); catch; false; end
    launched = lock(nb.lock) do
        (get(nb.report.meta, "inactive", false) === true) || return false
        delete!(nb.report.meta, "inactive")
        nb.report.meta["hydrating"] = true
        nb.report.meta["hydratingKind"] = hasbundle ? "env" : "boot"
        nb.version += 1
        return true
    end
    launched || return false
    try; _broadcast(nb, string(nb.version)); catch; end   # flip the pill + show the banner at once
    hasbundle ? (@async _hydrate_standalone!(nb, nb.path)) : _boot_and_run!(nb; autorun = true)
    return true
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
function _print_ready_banner(url::AbstractString; logpath::AbstractString = "",
                             keys::Bool = false, inactive::Bool = false)
    rule = "─"^72
    printstyled("\n", rule, "\n"; color = :green)
    printstyled(inactive ? "  ✓  Your Kaimon Slate notebook is ready (inactive)\n\n" :
                           "  ✓  Your Kaimon Slate notebook is live\n\n"; color = :green, bold = true)
    print("      →  ")
    printstyled(url; color = :cyan, bold = true, underline = true)
    if keys
        print("\n\n")
        inactive && print("  It opens as a static preview — nothing runs until you launch it.\n\n")
        print("  Press  ")
        printstyled("b"; color = :cyan, bold = true); print(" browser + launch (go live)    ")
        printstyled("p"; color = :cyan, bold = true); print(" browser, stay a preview    ")
        printstyled("q"; color = :cyan, bold = true); print(" stop the server\n")
        print("  Tip: set ")
        printstyled("SLATE_BROWSER"; color = :light_black)
        print(" (e.g. \"Google Chrome\") to choose which browser b/p open.\n")
    else
        print("\n\n  Open the link above in a browser. Press q or Ctrl-C here to stop the server.\n")
    end
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

# Open `url` in a browser, best-effort. This is what makes a Windows double-click (run.bat → run.ps1 →
# run.jl) actually land in a browser rather than a bare console. Cross-platform: `start` on Windows,
# `open` on macOS, `xdg-open` on Linux. `SLATE_BROWSER` picks a SPECIFIC browser instead of the OS
# default (macOS `open -a "Google Chrome"`; elsewhere the executable name) — for the common "my default
# is Safari but I want Chrome" case. `KAIMONSLATE_NO_OPEN=1` opts out of AUTOMATIC opens (headless/CI, or
# run.jl which drives its own `b`/`p` keys); `force=true` is an explicit user action (a key press) and
# ignores it. Never fatal — if it fails, the printed URL still stands.
function _open_in_browser(url::AbstractString; force::Bool = false)
    (!force && get(ENV, "KAIMONSLATE_NO_OPEN", "0") == "1") && return false
    br = strip(get(ENV, "SLATE_BROWSER", ""))
    try
        cmd = if !isempty(br)
            Sys.isapple()   ? `open -a $br $url` :
            Sys.iswindows() ? `cmd /c start "" $br $url` :
                              `$br $url`
        else
            Sys.iswindows() ? `cmd /c start "" $url` :
            Sys.isapple()   ? `open $url` :
                              `xdg-open $url`
        end
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
        return true
    catch
        return false
    end
end

# serve_notebook's interactive keys (raw-tty path): `b` opens the browser AND launches (go live);
# `p` opens the browser but leaves it inactive (a preview). Both honor SLATE_BROWSER and are explicit
# (force) opens, so they work even though run.jl sets KAIMONSLATE_NO_OPEN to suppress the auto-open.
function _serve_key(b::UInt8, h, url::AbstractString)
    c = Char(b)
    if c == 'b' || c == 'B'
        _open_in_browser(url; force = true)
        nbs = try; lock(h.lock) do; collect(values(h.notebooks)); end; catch; LiveNotebook[]; end
        for nb in nbs; try; launch_notebook!(nb); catch; end; end
    elseif c == 'p' || c == 'P'
        _open_in_browser(url; force = true)
    end
    return nothing
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
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765, quiet::Bool = true,
                        inactive::Bool = false)
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
    h = start_server(path; host = host, port = port, inactive = inactive)
    id = isempty(h.notebooks) ? "" : first(keys(h.notebooks))
    url = "$(_hub_url(h))/n/$id"
    _await_http_ready(_hub_url(h))          # wait until the server actually answers before announcing it
    # Interactive keys (b/p/q) only work on the raw-tty path below (a `julia run.jl` launch), not a REPL.
    # (Named `showkeys`, not `keys` — a local `keys` would shadow `Base.keys` used just above.)
    showkeys = !isinteractive() && stdin isa Base.TTY
    _print_ready_banner(url; logpath = logio === nothing ? "" : logpath, keys = showkeys, inactive = inactive)
    _open_in_browser(url)                    # best-effort auto-open (a no-op under KAIMONSLATE_NO_OPEN, which run.jl sets so its b/p keys drive opening instead)
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
        _wait_for_ctrl_c(on_key = b -> _serve_key(b, h, url))   # ^C / q / EOF quits; b / p act
        println("\n  Stopping the notebook server…")
        # BOUND the graceful teardown: stop_hub (worker shutdown / SSE drain / closing the HTTP server
        # with a live browser connection) can block on a condition/socket wait. Give it a short grace,
        # then leave via `_exit` regardless so `q` never hangs — the worker is already SIGTERM'd by
        # stop_hub, and any straggler is reaped by its own orphaned-hub spin-guard.
        done = Ref(false)
        @async (try; cleanup(); finally; done[] = true; end)
        t0 = time(); while !done[] && time() - t0 < 3.0; sleep(0.05); end
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
function _wait_for_ctrl_c(; on_key = nothing)
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
            on_key === nothing || (try; on_key(b); catch; end)   # other keys (b/p) act without ending the wait
        end
    finally
        close(keepraw)
        try; REPL.Terminals.raw!(term, false); catch; end
    end
end

end # module NotebookServer
