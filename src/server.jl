"""
    NotebookServer

The live, interactive notebook backend (interactivity layer 1). Holds a notebook
bound to a `.jl` file and serves a browser SPA plus a small JSON API. Editing a
cell reconciles → reactively recomputes only stale cells → persists back to the
`.jl` (so the agent and the browser share one source). Runs CLI-side, wrapping
the engine (`ReportEngine`) and per-cell renderer (`ReportRender`).
"""
module NotebookServer
# Base.expanduser is a no-op on Windows; this defines a working one for this module.
include(joinpath(@__DIR__, "expanduser_fix.jl"))


using HTTP, JSON, FileWatching, CodecZlib, CodecZstd
import Base64
import Serialization                          # a worker's cluster-operation results, back over the gate
import Sockets                                # claim the hub's port before HTTP's accept loop does
import SlateExtensionsBase                    # the dtype table the page's decoders are generated from
import Dates                                  # publish dates for the multi-doc site manifest
import Logging                                # standalone serve: route hub log detail to a file
import REPL                                   # standalone serve: raw-mode ^C byte (see _wait_for_ctrl_c)
import Tar
import Typst_jll
import Pkg
using ..ReportEngine
import ..SlateDiag                             # switchable instrumentation (off by default)
using ..ReportRender
import ..SlateHome
import ..EffectStore
import ..PublishLedger
import ..SshAuth                              # ssh prompts a cluster asks for, answered in the browser

include("history.jl")   # module SlateHistory — durable content-addressed time machine
include("parsched.jl")  # ParCell / par_blockers / run_scheduled — the parallel dataflow scheduler

export serve_notebook, start_server, stop_server, LiveNotebook
export export_app, app_defaults          # deploy a notebook as an application (server_app.jl / server_export.jl)
export Hub, start_hub, open_notebook!, close_notebook!, stop_hub
export find_live, notebook_digest, agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!, agent_delete_cells!, agent_rename_cell!, agent_scratch_eval!, agent_scratch_eval_bg!, scratch_check, agent_surface_controls!
export cell_image, set_snapshot!

const _ASSET = joinpath(@__DIR__, "assets", "notebook.html")
const _INDEX_ASSET = joinpath(@__DIR__, "assets", "index.html")
const _CSS_ASSET = joinpath(@__DIR__, "assets", "notebook.css")   # extracted from notebook.html
# The ANSI spans `ansi.js` emits. Its own file because TWO pages render captured output and they do
# not share a stylesheet: the notebook (which appends this to its own) and the operator status page,
# which is standalone and links it directly.
const _ANSI_CSS_ASSET = joinpath(@__DIR__, "assets", "ansi.css")
# What both pages need. They carry different stylesheets, so anything shared lives here.
const _SHARED_CSS = joinpath(@__DIR__, "assets", "shared.css")
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
    pkgimports::Dict{String,String}      # package-declared ES module imports (specifier → url), from the same manifest
                                         # (`provide_import!`) — an extension's own `@use`. Merged UNDER the notebook's
                                         # `@use` map wherever an import map is emitted. See `_register_import!`.
    fences::Set{String}                  # markdown fence languages an extension claims (`register_fence_renderer!`),
                                         # from the same manifest. Tracked only to notice a CHANGE: a markdown cell
                                         # caches its interpolation results, so cells holding a now-claimed (or
                                         # now-unclaimed) fence must be restaled. See `_refresh_fences!`.
    # Set the moment the notebook starts closing. Work started for it in the background (a prepare, a
    # placement, a connect) checks it before creating anything for the notebook or running its cells.
    closed::Bool
    # Inner constructor takes the original 13 fields and starts empty scratchpad + frontend/asset/import registries, so
    # every existing positional call site (server + tests) is unchanged; all are populated at runtime.
    LiveNotebook(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents) =
        new(id, path, report, kernel, version, undo, redo, lock, listeners, llock, agent_id, agent_busy, agents,
            Cell[], @NamedTuple{id::String, js::String, esm::Bool, kind::String}[], Dict{String,String}(),
            Dict{String,String}(), Set{String}(), false)
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
# A cluster operation a notebook's worker asked for. THIS process holds the ssh sessions, so it runs
# it here and hands the result back over the gate — one login per cluster, shared by every notebook,
# and the dialog is raised where the browser already is.
function _run_sshop(op::Symbol, a)
    S = ReportEngine.Sweep
    op === :connected  && return S.connected(a.host)
    op === :connect    && return S.connect!(a.host; interactive = a.interactive === true)
    op === :disconnect && return S.disconnect!(a.host)
    op === :exec       && return S.run_there(a.host, a.script; timeout = a.timeout)
    op === :io         && return S.run_io(a.host, a.script, a.input)
    op === :forward    && return S.forward!(a.host, a.localport, a.target, a.targetport)
    op === :unforward  && return S.unforward!(a.host, a.localport)
    error("unknown cluster operation :$op")
end

function _relay_sshop(nb::LiveNotebook, p)
    id = String(p.id)
    # Off the poller task: a connect waits for someone to answer a dialog, and everything else waits
    # for a cluster. Blocking here would stall every other notebook's worker events behind it.
    Threads.@spawn begin
        res = try
            _run_sshop(Symbol(p.op), p.args)
        catch e
            (; error = first(sprint(showerror, e), 300))
        end
        try
            ReportEngine._tool(nb.kernel, "__slate_sshop_reply",
                Dict{String,Any}("id" => id,
                                 "b64" => Base64.base64encode(Serialization.serialize, res)))
        catch e
            ReportEngine._rlog("cluster: could not return a result to the worker ($(first(sprint(showerror, e), 120)))")
        end
    end
    return nothing
end

function _wire_callbacks!(nb::LiveNotebook)
    register_refresh!(nb.report.id, vars -> server_refresh(nb, vars))                      # async slate_refresh → recompute readers
    register_srcchange!(nb.report.id, (names, err) -> server_src_changed(nb, names, err))  # parent /src reloaded (Revise)
    register_progress!(nb.report.id, c -> _broadcast_progress(nb, c))                      # stream per-cell run status to the UI
    register_runbatch!(nb.report.id, (n, fresh) -> (try; _broadcast(nb, "runbatch:$n:$(fresh ? 1 : 0)"); catch; end))   # run size + is-this-a-new-run → stable k/N
    register_userprog!(nb.report.id, (frac, msg, id, done) -> begin
        # Record before broadcasting: an agent BLOCKED on this run samples the latest reading
        # from its own task (see `_note_run_progress`) rather than being pushed every frame,
        # so a cell calling slate_progress at 10 Hz can't flood the agent's context. The
        # browser keeps the unthrottled stream below — it drives a live progress bar.
        lock(_USERPROG_LOCK) do
            _LAST_USERPROG[nb.id] = (Float64(frac), String(msg), String(id), done === true, time())
        end
        try; _broadcast(nb, "cellprog:" * JSON.json(Dict("frac" => frac, "msg" => msg, "id" => id, "done" => done))); catch; end
    end)
    # A running cell's output so far (already cooked worker-side). Sent as TEXT, not HTML: the page
    # renders it with the same `slateAnsiHtml` it uses for the build log and the worker log, and a
    # frame at 10 Hz has no business round-tripping through the report renderer.
    register_cellout!(nb.report.id, (cid, out, err) ->
        (try; _broadcast(nb, "cellout:" * JSON.json(Dict("cid" => cid, "out" => out, "err" => err))); catch; end))
    register_prepare!(nb.report.id, json -> (try; _broadcast(nb, "prepare:" * json); catch; end))   # env precompile progress → "Preparing packages" banner
    register_emit!(nb.report.id, (channel, payload) -> (try
        # A worker reaching a cluster does it through here, because the sessions live in this
        # process. Everything else on this channel is an ordinary `slate_emit` bound for the page.
        channel == ReportEngine.Sweep.OP_CHANNEL ? _relay_sshop(nb, payload) :
                                                   _ws_emit!(nb, channel, payload)
    catch; end))   # slate_emit → push over the page WebSocket (NOT the coalescing SSE); payload is a Julia value, JSON-encoded in _ws_emit!
    register_bin_emit!(nb.report.id, frame -> (try; _ws_broadcast_bin!(nb, frame); catch; end))   # slate_emit_bin → forward the raw binary frame over the page WebSocket as-is
    register_celldone!(nb.report.id, (run_id, cid, wire) -> server_celldone(nb, run_id, cid, wire))   # parallel-batch result merge
    register_cleanup_cells!(nb.report.id, ids -> (try; _cleanup_deleted_cells(nb, ids); catch; end))   # deleted-cell slate_on_cleanup teardown
    register_toolcall!(nb.report.id, p -> (try; server_toolcall(nb, p); catch; end))   # an agent's tool call → a TOOL cell
    # `set_bind(:name, v)` from cell code → the SAME path the browser POST takes. Async because the
    # handler runs on the poller task and `set_bind!` does worker round-trips (coerce, then run the
    # readers): blocking the poller would stall every other notebook's reactivity behind this one.
    register_setbind!(nb.report.id, (name, value) ->
        (@async try; set_bind_by_name!(nb, name, value); catch e
            @warn "slate: set_bind from a cell failed" bind = name exception = e
        end))
    return nb
end
function _unwire_callbacks!(nb::LiveNotebook)
    # A notebook id is REUSED the instant the same file is reopened, so a leftover reading here
    # would be reported against the new notebook's first run as if it described it.
    lock(_USERPROG_LOCK) do; delete!(_LAST_USERPROG, nb.id); end
    unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id)
    unregister_progress!(nb.report.id); unregister_runbatch!(nb.report.id)
    unregister_userprog!(nb.report.id); unregister_emit!(nb.report.id); unregister_celldone!(nb.report.id)
    unregister_cellout!(nb.report.id)
    unregister_toolcall!(nb.report.id); unregister_setbind!(nb.report.id)
    unregister_prepare!(nb.report.id); unregister_bin_emit!(nb.report.id); unregister_cleanup_cells!(nb.report.id)
    return nb
end

# Run deleted cells' `slate_on_cleanup` callbacks wherever they might live. A cell can have run on the
# main kernel OR on any of the notebook's region kernels (its session lives on that worker), and we don't
# track which — so broadcast the removed ids to the main kernel AND every active region kernel. Each
# fires only the ids its own namespace holds (unknown ids no-op), so the broadcast is cheap + correct.
function _cleanup_deleted_cells(nb::LiveNotebook, ids)
    sids = String[String(i) for i in ids]
    isempty(sids) && return nothing
    # OFF-LOCK + fire-and-forget: this fires from `update_source!`, reachable from edit paths that hold
    # nb.lock, and a GateKernel teardown is a worker round-trip — which must NEVER run under the lock
    # (deadlock protocol). Teardown has no ordering constraint, so a detached task is safe.
    @async try
        ReportEngine.run_cleanups!(nb.kernel, nb.report, sids)
        regionks = lock(_REGION_LOCK) do
            Any[k for ((rid, _name), k) in _REGION_KERNELS if rid == nb.id]
        end
        for k in regionks
            try; ReportEngine.run_cleanups!(k, nb.report, sids); catch; end
        end
    catch e
        @debug "slate: deleted-cell cleanup failed" exception = e
    end
    return nothing
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
function _rebuild_notebook_env!(envdir::AbstractString, parent::AbstractString; online = nothing,
                                delta = Dict{String,Any}[])
    build = function ()
        pname = ReportEngine.seed_env_project!(envdir, parent)
        dev = isempty(pname) ? "" :
              "Pkg.develop(Pkg.PackageSpec(path=raw\"$(parent)\"); preserve=Pkg.PRESERVE_ALL); "
        ok = _instantiate_env!(envdir; online = online,
                               code = "using Pkg; $(dev)Pkg.instantiate()" *
                                      ReportEngine.env_add_code(delta))
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

# ── A forked env follows its parent project ─────────────────────────────────────────────────────
# A notebook that added packages of its own runs in a fork of its project's env. When the project
# changes (a dependency added to the package under development, a re-resolve), the fork is behind it,
# and a worker started in it fails to load the package: "does not have X in its dependencies". So the
# fork is re-resolved whenever it is found behind (`env_stale`): when the notebook opens, before any
# worker starts in it (a region's included, which is provisioned from it), and while the notebook is
# open, as soon as the project's files change. With the hub's own Julia, which is the workers'.
const _FORK_LOCK = ReentrantLock()

function _refresh_fork_env!(envdir::AbstractString, parent::AbstractString, delta; online = nothing)
    (isempty(parent) || isempty(envdir) || !isfile(joinpath(envdir, "Project.toml"))) && return false
    lock(_FORK_LOCK) do
        ReportEngine.env_stale(envdir, parent) || return false
        ReportEngine._rlog("fork: $(basename(envdir)) is behind its project $(basename(parent)) — re-resolving it")
        # `delta`: the re-seed comes from the PARENT, which knows nothing about what this notebook
        # added, so its own packages have to be put back.
        _rebuild_notebook_env!(envdir, parent; online = online, delta = delta)
        return true
    end
end

_refresh_nb_fork!(nb::LiveNotebook) = (k = nb.kernel; k isa ReportEngine.GateKernel &&
    _refresh_fork_env!(k.envdir, k.parent, get(nb.report.meta, "env", Dict{String,Any}[])))

# The parent project's files as last seen, per notebook, so the watch below re-reads them only when
# one has been written.
const _FORK_SEEN = Dict{String,Tuple{Float64,Float64}}()

# While a notebook is open: if its project's files changed and that left its fork behind, re-resolve
# the fork and bring each of its connected region workers' environments up to it. A local worker runs
# in the fork itself, so it can load the new packages at once; a region worker has a copy, which is
# what the provision updates.
function _watch_fork!(nb::LiveNotebook)
    k = nb.kernel
    (k isa ReportEngine.GateKernel && !isempty(k.parent)) || return nothing
    ppf = ReportEngine.project_file_in(k.parent)
    isempty(ppf) && return nothing
    pmf = ReportEngine._manifest_for(ppf)
    sig = (mtime(ppf), isempty(pmf) ? 0.0 : mtime(pmf))
    prev = get(_FORK_SEEN, nb.id, nothing)
    _FORK_SEEN[nb.id] = sig
    (prev === nothing || prev == sig) && return nothing
    _refresh_nb_fork!(nb) || return nothing
    for rk in _nb_kernels(nb)
        (rk isa ReportEngine.GateKernel && rk.conn !== nothing && rk.target isa ReportEngine.RemoteTarget) || continue
        Threads.@spawn try
            ReportEngine.provision_remote!(rk.target, rk.parent)
        catch e
            ReportEngine._rlog("fork: updating $(rk.target.ssh_host)'s copy of $(basename(k.envdir)) failed — " *
                               first(sprint(showerror, e), 160))
        end
    end
    return nothing
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
    proj = Base.current_project(dirname(abspath(path)))
    enclosing = proj === nothing ? "" : dirname(proj)
    report.meta["assetbase"] = isempty(enclosing) ? ReportEngine.notebook_env_dir(path) : enclosing
    # Where the `.jl` itself lives — the fallback for a relative read the asset base doesn't have
    # (`resolve_input_path`). It matters for a DETACHED notebook, whose asset base is the env dir
    # while `helpers.jl` sits next to the notebook. Runtime-derived, so meta only: the config footer
    # writes a fixed whitelist (`_CONFIG_KEYS`) and this is not on it.
    report.meta["notebookdir"] = dirname(abspath(path))
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
            ReportEngine.mark_notebook_env!(envdir, path)
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
        ReportEngine.mark_notebook_env!(envdir, path)
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
        nbdir = dirname(abspath(path))  # local worker: the read fallback for a detached notebook
        if !env_exists && !isempty(delta)
            # The `.jl` records package adds but the env dir is gone (e.g. a fresh git clone):
            # reconstruct it from the footer on first use (pending). Only `mkdir` here — the
            # Project.toml is written by the reconstruction itself, so a worker that never ran
            # leaves the env "absent" and reconstruction retries on the next open.
            mkpath(envdir)
            return GateKernel(envdir; parent = parent, envdir = envdir, nbdir = nbdir, pending = delta, threads = th, extra_flags = ef, label = lbl, online = online)
        elseif parent == ""
            # Detached: the notebook env IS the whole world (everything is a "notebook add").
            ReportEngine.ensure_notebook_env!(envdir; notebook = path)
            return GateKernel(envdir; parent = "", envdir = envdir, nbdir = nbdir, threads = th, extra_flags = ef, label = lbl, online = online)
        elseif env_exists
            # Already has its own packages → run in the forked env (extends the parent). But first, if
            # the PARENT changed since this fork was seeded (a dep added, a re-resolve — e.g. an
            # extension package that gained a dependency), REBUILD it: a stale fork would crash the
            # worker at boot on `using` a dep the fork never received. Self-healing, before spawn.
            _refresh_fork_env!(envdir, parent, delta; online = online)
            return GateKernel(envdir; parent = parent, envdir = envdir, nbdir = nbdir, threads = th, extra_flags = ef, label = lbl, online = online)
        else
            # Base mode: no notebook-specific packages yet → run directly in the parent.
            return GateKernel(parent; parent = parent, envdir = envdir, nbdir = nbdir, threads = th, extra_flags = ef, label = lbl, online = online)
        end
    end
    # Asked to run somewhere else, with no gate to do it with. Every remote path — `remoteworker`,
    # `runon`, and the region kernels — lives inside the branch above, so without a gate the request
    # is answered in the negative SILENTLY: the notebook runs here, the toolbar goes on showing the
    # host it is not using, and not even the `_rlog` line above is reached to record the decision.
    # Say it once, here. `remoteAvailable` in `state_json` tells the browser the same thing.
    let want = _effective_runon(report), rw = strip(String(get(report.meta, "remoteworker", "")))
        if !isempty(want) || !isempty(rw)
            asked = isempty(want) ? "remoteworker $rw" : want
            ReportEngine._rlog("_select_kernel nb=$(basename(String(path))) wanted=[$asked] but there is no compute gate — running LOCALLY in-process")
            @warn "slate: this notebook asked to run elsewhere, but this hub has no compute gate — running locally instead" notebook = basename(String(path)) requested = asked source = _runon_source(report) hint = "remote execution needs the Kaimon host; a standalone hub cannot spawn or dial a remote worker"
        end
    end
    # No gate (standalone `slate`, no Kaimon host): cells run in THIS process. The notebook gets the
    # same two environments a worker would be given — its own env and its enclosing project — but
    # stacked on LOAD_PATH rather than resolved into one, since there is no separate process whose
    # active project we could repoint. `_in_notebook_env` installs that stack around each eval and
    # takes it down again; nothing is layered here.
    #
    # The env is MATERIALISED now rather than on the first package add. It is what the notebook's
    # active project is set to while a cell runs, so creating it up front is what makes `Pkg.status()`
    # in a cell describe the notebook instead of the hub, from the very first cell rather than from
    # whenever a package happens to be added.
    k = InProcessKernel(enclosing, ReportEngine.ensure_notebook_env!(ReportEngine.notebook_env_dir(path); notebook = path))
    return k
end

function load_notebook(path::AbstractString; id::AbstractString = "", threads::AbstractString = "",
                       runon::AbstractString = "", autorun::Bool = true, inactive::Bool = false,
                       update::Bool = false)
    src = read(path, String)
    base = splitext(basename(path))[1]
    rid = replace(base, r"[^A-Za-z0-9]" => "_")
    nbid = isempty(id) ? rid : String(id)
    r = parse_report(src; id = rid, title = base)
    # A file in an older format whose update changes something opens only once the update is agreed
    # to: then the original is kept beside it and the file is written in the current format.
    ch = ReportEngine.format_changes(r)
    if !isempty(ch)
        update || throw(NotebookNeedsUpdate(abspath(path), get(r.meta, "format", 1), ch))
        update_notebook_format!(path)
        src = read(path, String)
        r = parse_report(src; id = rid, title = base)
    end
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
        # Before anything reads a per-notebook store: if this notebook carries a docid but its
        # data is still filed under the old path-derived key, move it across. One-shot, idempotent.
        try; _adopt_doc_stores!(path, r.meta); catch; end
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
    try; _adopt_doc_stores!(path, r.meta); catch; end   # legacy path key → docid key (see above)
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
                _opening_drain!(nb)                  # initial full run — WAIT for it to fully complete, so
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
        rehomed = ""
        lock(nb.lock) do
            nb.kernel = kernel
            # A durable INSTALL (SLATE_INSTALL_DIR) → serve the notebook FROM the installed project, so
            # edits save there (and land in its git checkout), not into the throwaway downloaded `.jl`.
            if rc.install && !isempty(rc.notebook) && isfile(rc.notebook)
                rehomed = abspath(String(nb.path)); nb.path = rc.notebook
            end
            # Read fallback (`resolve_input_path`), set from the path the notebook is SERVED from —
            # after any rehome, so a file beside the installed `.jl` resolves rather than one beside
            # the downloaded bundle. The worker is spawned lazily, so setting it here still reaches it.
            kernel.nbdir = dirname(abspath(String(nb.path)))
            nb.report.meta["notebookdir"] = kernel.nbdir
            delete!(nb.report.meta, "preview")       # live cells supersede the frozen render
        end
        # The downloaded bundle was this document's TRANSPORT, not a place it lived: it stays on disk
        # for the run, so left in the store the notebook we just installed reads as one document in two
        # places and the reader is asked to split a copy they never made. Re-point the store at the
        # install BEFORE `_drain!` — the first state push carries `sharedWith`, the client latches the
        # notice on first sight, and anything done after that is too late to unsay it.
        if !isempty(rehomed) && rehomed != abspath(String(nb.path))
            try; SlateHistory.rehome_path!(nbdoc(nb), rehomed, abspath(String(nb.path))); catch e
                @warn "KaimonSlate: could not re-point the history store at the install" exception = e
            end
        end
        pending isa PendingKernel && ReportEngine._resolve!(pending, kernel)   # unblock anyone who raced the boot window
        _opening_drain!(nb)                          # run everything + WAIT, so `hydrating` stays up for it
        lock(nb.lock) do
            delete!(nb.report.meta, "hydrating")
            delete!(nb.report.meta, "hydratingKind")
            nb.version += 1
        end
        _save_preview!(nb; force = true)             # freshly-run state → next reopen's interim preview
        _history!(nb; source = "open")
        _autoindex!(nb)
    catch e
        lock(nb.lock) do
            nb.report.meta["hydrate_error"] = sprint(showerror, e)
            delete!(nb.report.meta, "hydrating")
            delete!(nb.report.meta, "hydratingKind")
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
            # Note it BEFORE restaling — `restale!` overwrites RUNNING, so afterwards there is no
            # way to tell that this cell's in-flight run is now answering a stale question.
            c.state == RUNNING && push!(get!(Set{String}, _DIRTY_WHILE_RUNNING, nb.id), c.id)
            ReportEngine.restale!(c) && push!(seed, c.id)
        end
        isempty(seed) && return
        changed = Set(seed)
        for id in dependents_of(nb.report, Set(seed))
            i = _index_of(nb.report.cells, id)
            i === nothing && continue
            ReportEngine.restale!(nb.report.cells[i]) && push!(changed, id)
        end
        # A reactive push CONTINUES whatever is running rather than starting a run: a dashboard that
        # pushes every few steps produces a long train of these, and treating each as a new run would
        # reset the pill constantly (as treating none of them as one makes it count forever).
        _eval!(nb; fresh = false)
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
    # Wire form is `name` or `name:digest` — a `Reactive` write carries the identity of the value it
    # just stored (reactive.jl `_write_digest`), a bare `slate_refresh(:data)` from a cell's own async
    # task does not. Record the digest BEFORE restaling: the cells restaled below recompute their memo
    # keys on the way through, and those keys have to see the value that caused the push, not the one
    # before it. Restaling still happens on the bare NAME, exactly as it always has.
    syms = Set{Symbol}()
    for v in vars
        s = String(v)
        # `cell:<id>` — a producer announcing that its own value changed WITHOUT knowing what the
        # notebook named it. A batch sweep is the case: it returns as soon as the work is submitted
        # and finishes minutes or hours later, in a browser callback that has no way to know the
        # binding. The cell knows itself, and the report knows what that cell writes.
        if startswith(s, "cell:")
            # `cell:<id>` or `cell:<id>@<digest>`. The digest is the producer's answer to "what is
            # my value now" for a value that is NOT a function of its source — a sweep's landed
            # units. Recorded against every name the cell writes, so a reader's memo key moves with
            # the results instead of staying put while they arrive. Recorded BEFORE the restale
            # below, because the cells it wakes recompute their keys on the way through.
            rest = s[6:end]
            j = findlast(==('@'), rest)
            cid = j === nothing ? rest : rest[1:prevind(rest, j)]
            dig = j === nothing ? "" : rest[nextind(rest, j):end]
            for c in nb.report.cells
                c.id == cid || continue
                union!(syms, c.writes)
                isempty(dig) || for n in c.writes
                    ReportEngine.note_state_write!(nb.report.id, string(n), dig)
                end
            end
            continue
        end
        i = findfirst(==(':'), s)
        if i === nothing
            push!(syms, Symbol(s))
        else
            name = s[1:prevind(s, i)]
            push!(syms, Symbol(name))
            ReportEngine.note_state_write!(nb.report.id, name, s[nextind(s, i):end])
        end
    end
    return _reactive_refresh!(nb, c -> !isdisjoint(c.reads, syms) && isdisjoint(c.writes, syms))
end

# Reactive push triggered by the asset watcher (`_start_asset_watcher!`): one or more `@asset` or
# `include` files a cell READS changed on disk → restale those cells + their dependents, recompute,
# and push the same lightweight `refresh:` patch as a `@bind` change. `changed` are absolute paths; a
# cell's `inputs` are notebook-relative (or absolute) and resolve by `resolve_input_path`.
function server_asset_changed(nb::LiveNotebook, changed::Vector{String})
    chset = Set{String}(changed)
    reads_changed(c) = any(rel -> ReportEngine.resolve_input_path(nb.report.meta, rel) in chset, c.inputs)
    # An `include`d file is an input whose CONTENTS decide the cell's writes, so a change there
    # invalidates more than the cell's result: forget its cached expansion too, or a definition the
    # file just gained never reaches the graph.
    ReportEngine.forget_expansions!(nb.report, lock(nb.lock) do
        Cell[c for c in nb.report.cells if reads_changed(c)]
    end)
    return _reactive_refresh!(nb, reads_changed)
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
# nb.id → ids of cells that were RESTALED WHILE RUNNING by a reactive push, and so must run again.
#
# A cell's run reads its inputs once, at the start. If a reactive value it reads changes while that
# run is in flight, the result is already answering a stale question — and `mark_result!` then marks
# the cell FRESH, overwriting the STALE that `restale!` set mid-run. Nothing restales it again (the
# push has been and gone), so the cell sits FRESH holding output computed from values that have
# since moved, indefinitely.
#
# `_eval_one!` already handles the SOURCE version of this hazard by comparing `src_hash` across the
# run; this is the same idea for values, which carry no hash. A handler writing several reactives in
# a burst (`msg[] = …; result[] = …; busy[] = false`) is the case that hits it, and it hits the LAST
# write — so the symptom is a progress bar that never clears while every value behind it is correct.
# Guarded by `nb.lock`: every reader and writer here already holds it.
const _DIRTY_WHILE_RUNNING = Dict{String,Set{String}}()
const _RUNNER_STALE_AFTER = 600.0                     # 10 min with pending work + no progress ⇒ suspect
const _RUNNER_STALE_CONFIRMATIONS = 3                 # consecutive 5s sweeps before self-healing (~15s)

# Per-notebook MAIN-kernel worker identity we last re-established (`_worker_key` = objectid + ns_gen). A
# worker swap (cold spawn / pool adopt / reprovision — never a reattach) bumps `k.ns_gen`, handing us a
# BLANK namespace mid-session where every global (imports, theme, @bind registrations) is gone while the
# cells still read FRESH. We detect the change (see `_reestablish_fresh_namespace!`) and re-establish; a
# reattach (same worker key) is a no-op. Same key the region layer uses, for the main kernel.
const _MAIN_GEN = Dict{String,UInt}()
const _MAIN_GEN_LOCK = ReentrantLock()

# A small MONOTONIC counter of how many times this notebook's worker has been replaced. `_MAIN_GEN` holds an
# opaque worker key (good for "did it change?", useless for ordering), and the browser needs ordering: a page
# must react to a worker reset only if it happened AFTER the page loaded. A page that boots fresh against
# generation N has nothing belonging to any earlier worker, so a `workerreset:` for N (or lower) is not its
# business — and acting on it would tear down the sessions it just established (Bonito's `close_session` even
# removes their DOM). The page learns its boot generation from `state_json` (`workerGen`) and compares.
const _WORKER_GEN = Dict{String,Int}()
worker_generation(nb::LiveNotebook) = lock(_MAIN_GEN_LOCK) do; get(_WORKER_GEN, nb.id, 0); end
_bump_worker_generation!(nb::LiveNotebook) = lock(_MAIN_GEN_LOCK) do
    _WORKER_GEN[nb.id] = get(_WORKER_GEN, nb.id, 0) + 1
end

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

# Every completed cell run, per notebook and kernel side (`_kernel_side_label`), for the telemetry
# view's timeline: when each run actually started and ended. The worker's samples, two seconds apart,
# miss a short run entirely. A ring per kernel, kept for the session like the stats above.
const _RUN_LOG = Dict{Tuple{String,String},Vector{Any}}()
const _RUN_LOG_LOCK = ReentrantLock()
const _RUN_LOG_MAX = 2000

# `profile`: the id of the profile taken of this run (server_profile.jl), "" for an ordinary run.
function _run_log!(nb::LiveNotebook, side::AbstractString, cell; profile::AbstractString = "")
    out = cell.output; out === nothing && return nothing
    t1 = time()
    r = (id = String(cell.id), t0 = t1 - out.duration_ms / 1000, t1 = t1, memo = String(out.memo),
         err = out.exception !== nothing, profile = String(profile))
    lock(_RUN_LOG_LOCK) do
        v = get!(Vector{Any}, _RUN_LOG, (nb.id, String(side)))
        push!(v, r)
        length(v) > _RUN_LOG_MAX && popfirst!(v)
    end
    return nothing
end

_run_json(r) = Dict("id" => r.id, "t0" => r.t0, "t1" => r.t1, "memo" => r.memo, "err" => r.err, "profile" => r.profile)

# The runs on one kernel side that ended after `since`.
_runs_since(nbid::AbstractString, side::AbstractString, since::Real) = lock(_RUN_LOG_LOCK) do
    Any[r for r in get(_RUN_LOG, (String(nbid), String(side)), Any[]) if r.t1 > since]
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
const _REGION_PRIMED = Dict{Tuple{String,UInt},UInt}()     # (nb id, `_worker_key` of the kernel) → signature of primed `using` cells
# Keys currently being primed. `_prime_namespace!` stages each EVERYWHERE cell's data reads through
# `_region_presync!`, which primes both sides before its first transfer — so the two call each other.
# A nested prime for a key already in flight is a no-op: the outer call is establishing that kernel.
const _REGION_PRIMING = Set{Tuple{String,UInt}}()
const _REGION_LOCK = ReentrantLock()

# Codes a BLOCKED cell carries. The page turns each into words; nothing here is a sentence.
const WAIT_QUEUED = "queued"
const WAIT_NOT_SIGNED_IN = "not_signed_in"
const WAIT_CONNECTING = "connecting"
const WAIT_NOT_REQUESTED = "not_requested"
const WAIT_NEEDS_PREPARE = "needs_prepare"
const WAIT_PREPARING = "preparing"
# A locked cell with no frozen result to restore here. Only its own ▶ computes it; `blocked_host`
# carries its id, so a cell downstream says which locked cell it waits on.
const WAIT_LOCKED = "locked"

# Why a notebook's first worker on region `r` has to go through preparing it, or `""` when it need not.
# The machine's answer for this project on the kind of node the region gets (`env_readiness`), the same
# one a sweep on that machine is held by.
function _prepare_reason(r, origin_env::AbstractString)
    # A notebook with no environment of its own needs only the region prepared, and the site unchanged.
    isempty(origin_env) && !isempty(r.readiness) &&
        isempty(get(ReportEngine.host_facts(r.host), "stale", "")) && return ""
    why = ReportEngine.env_readiness(r.host, origin_env, ReportEngine.region_node_type(r);
                                     depot = ReportEngine.region_depot(r), by = r.name)
    isempty(why) || return why
    # A region that boots from a sysimage needs one built from what it lists now.
    r.sysimage || return ""
    img = get(r.readiness, "sysimage", nothing)
    img isa AbstractDict || return "The region's sysimage hasn't been built yet."
    String(get(img, "spec", "")) == ReportEngine.sysimage_spec_key(r.sysimage_pkgs) || return "The packages in the region's sysimage changed since it was built."
    return ""
end

# The environment a notebook's region workers replicate: its own fork env when it has one, else its
# project's; "" for a notebook with neither.
function _nb_origin_env(nb::LiveNotebook)
    envdir = ReportEngine.notebook_env_dir(nb.path)
    isfile(joinpath(envdir, "Project.toml")) && return envdir
    proj = Base.current_project(dirname(abspath(nb.path)))
    return proj === nothing ? "" : dirname(proj)
end

# The sysimages of the regions a notebook uses, for its packages pane: per region with sysimage on and
# an image built, the packages chosen for it and Slate's, each at the version baked, the version the
# notebook resolves ("" when it does not have it: the package loads only in that region's cells), and
# whether the two differ (then the notebook's workers there start without the image).
function _nb_sysimages(nb::LiveNotebook)
    origin = _nb_origin_env(nb)
    mine = Dict{String,String}()
    mf = isempty(origin) ? "" : ReportEngine.parent_manifest(origin)
    if !isempty(mf) && isfile(mf)
        for (name, es) in get(ReportEngine.Sweep.TOML.parsefile(mf), "deps", Dict{String,Any}()), e in es
            mine[String(name)] = String(get(e, "version", ""))
        end
    end
    out = Any[]
    for x in _regions_json(nb)
        r = ReportEngine.region_get(String(x["name"]))
        (r === nothing || !r.sysimage) && continue
        img = get(r.readiness, "sysimage", nothing)
        img isa AbstractDict || (push!(out, Dict("region" => r.name, "built" => false, "packages" => Any[])); continue)
        baked = Dict(String(get(v, "name", "")) => v for (_, v) in get(img, "packages", Dict()))
        names = unique(vcat([e["name"] for e in r.sysimage_pkgs], collect(ReportEngine._SYSIMAGE_INFRA)))
        pkgs = Any[]
        for n in sort(names; by = lowercase)
            b = get(baked, n, nothing); b === nothing && continue
            v = String(get(b, "version", "")); nv = get(mine, n, "")
            push!(pkgs, Dict("name" => n, "version" => v, "notebook" => nv,
                             "slate" => n in ReportEngine._SYSIMAGE_INFRA,
                             "path" => startswith(String(get(b, "tree", "")), "path:"),
                             "clash" => !isempty(nv) && nv != v))
        end
        push!(out, Dict("region" => r.name, "built" => true, "packages" => pkgs,
                        "built_at" => get(img, "built_at", 0), "bytes" => get(img, "bytes", 0),
                        "total" => length(baked)))
    end
    return out
end

# The project a notebook sits in, "" for none.
_nb_project(nb::LiveNotebook) = (p = Base.current_project(dirname(abspath(nb.path))); p === nothing ? "" : dirname(p))

# Ask the page to offer preparing the region (prepare.js). Pushed on every explicit run that meets the
# wait, so a dialog dismissed once comes back when the person runs the cell again.
function _announce_prepare!(nb::LiveNotebook, r; reason::AbstractString = "")
    try
        _broadcast(nb, "regionprep:" * JSON.json(Dict("region" => r.name, "host" => r.host,
                                                    "scheduler" => String(r.scheduler), "sysimage" => r.sysimage,
                                                    "reason" => reason)))
    catch
    end
    return nothing
end

# The notebook open in hub `h` at `path`, or `nothing`.
function _open_notebook_at(h, path::AbstractString)
    (h === nothing || isempty(strip(path))) && return nothing
    p = abspath(expanduser(strip(path)))
    nbs = lock(() -> collect(values(h.notebooks)), h.lock)
    i = findfirst(nb -> abspath(nb.path) == p, nbs)
    return i === nothing ? nothing : nbs[i]
end

"""
    _prepare_for_notebook!(nb, name; rebuild_sysimage = false)

Prepare region `name` for `nb`'s project, keeping the node it gets for the worker that follows, then
re-run the cells that were waiting. Background; progress is read from `/api/regions/prepare`. A
prepare asked for elsewhere that names an open notebook comes here too, so the node it waited for
goes to that notebook instead of back to the scheduler.
"""
function _prepare_for_notebook!(nb::LiveNotebook, name::AbstractString; rebuild_sysimage::Bool = false)
    r = ReportEngine.region_get(name)
    r === nothing && return nothing
    # The worker prepare starts and loads the packages in is the one this notebook's cells use.
    worker = (start = (fresh::Bool = false) -> begin
                  # Replacing a running worker: drop the hub's kernel for it and the process, so the
                  # one started below boots afresh (from the image this prepare just built).
                  if fresh
                      k0 = lock(() -> get(_REGION_KERNELS, (nb.id, String(r.name)), nothing), _REGION_LOCK)
                      if k0 isa ReportEngine.GateKernel && k0.conn !== nothing && k0.target isa ReportEngine.RemoteTarget
                          host, port = k0.target.ssh_host, k0.port
                          _forget_region_kernel!(nb, String(r.name))
                          try; ReportEngine._drop_kernel_conn!(k0); catch; end
                          try; ReportEngine.reap_remote_worker(host, port); catch; end
                          ReportEngine._rlog("prepare[$(r.name)]: replaced worker-$port on $host so it boots from the new sysimage")
                      end
                  end
                  k = _region_kernel!(nb, String(r.name); preparing = true)
                  was_up = k isa ReportEngine.GateKernel && k.conn !== nothing
                  try; facts_changed!(); catch; end          # the pill shows it starting
                  ReportEngine.prepare!(k, nb.report; explicit = true)
                  k.conn === nothing && error("the worker did not connect")
                  try; facts_changed!(); catch; end          # …and up, before the load
                  !was_up                                    # whether this started it
              end,
              run = code -> begin
                  k = _region_kernel!(nb, String(r.name); preparing = true)
                  out = lock(_eval_mutex(nb)) do
                      ReportEngine.eval_capture(k, nb.report, String(code), "prepare")
                  end
                  out.exception === nothing || error(first(String(out.exception), 400))
                  out.stdout
              end)
    # The cells say what they are waiting for from the moment it starts, not what they last ran into.
    _mark_region_preparing!(nb, r.name)
    try; facts_changed!(); catch; end
    Threads.@spawn try
        ReportEngine.prepare_region!(r.name; project = nb.path, keep_node = true, worker, rebuild_sysimage,
                                     node = r.scheduler === :none ? nothing : true)
        _restale_region_cells!(nb, r.name)
        _ensure_runner!(nb)
    catch e
        ReportEngine.prepare_failed_to_start!(r.name, e)
    finally
        try; facts_changed!(); catch; end
    end
    return nothing
end

# A region's waiting cells, shown as waiting for its prepare. Only cells already waiting: one that
# is fresh keeps its value, and the prepare's end re-runs what was held (`_restale_region_cells!`).
function _mark_region_preparing!(nb::LiveNotebook, name::AbstractString)
    lock(nb.lock) do
        for c in nb.report.cells
            (c.state == BLOCKED && _cell_region(c) == name && c.blocked != WAIT_PREPARING) || continue
            ReportEngine.mark_blocked!(c, WAIT_PREPARING, c.blocked_host, String(name))
            _broadcast_progress(nb, c)
        end
    end
    return nothing
end

# Notebooks in the run that opening them starts. A scheduler node bills from the moment it is held,
# so getting one is something a person asks for by running a cell, as signing in is: an open or a
# hub restart re-running a notebook must not queue for a node nobody asked for. A node already held
# is still used, since attaching to it costs nothing more.
const _OPENING_RUN = Set{String}()
const _OPENING_RUN_LOCK = ReentrantLock()
_in_opening_run(nbid) = lock(_OPENING_RUN_LOCK) do; String(nbid) in _OPENING_RUN; end

# The run a notebook gets when it opens, whichever way it was opened.
function _opening_drain!(nb::LiveNotebook)
    lock(_OPENING_RUN_LOCK) do; push!(_OPENING_RUN, nb.id); end
    _find_held_regions!(nb)
    try
        _drain!(nb)
    finally
        lock(_OPENING_RUN_LOCK) do; delete!(_OPENING_RUN, nb.id); end
    end
end

# The regions this notebook's cells use whose node may still be held, looked for in the background:
# after a hub restart the scheduler still holds the job and its worker still runs, and attaching to
# them costs nothing more. Only a host that takes a key is asked, as an open does not ask anyone to
# sign in, and nothing is requested: a region with no node keeps waiting for a run.
function _find_held_regions!(nb::LiveNotebook)
    names = lock(nb.lock) do; unique(filter(!isempty, [_cell_region(c) for c in nb.report.cells])); end
    for name in names
        r = ReportEngine.region_get(name)
        (r === nothing || r.scheduler === :none || !isempty(last(ReportEngine.region_where(r)))) && continue
        Threads.@spawn try
            ok = ReportEngine.Sweep.connected(r.host) || (try; ReportEngine.Sweep.connect!(r.host); catch; false; end)
            ok && _place_in_background!(name, nb; find_only = true)
        catch e
            ReportEngine._rlog("region[$name]: looking for its node failed — $(first(sprint(showerror, e), 160))")
        end
    end
    return nothing
end

# A region can take work now (its node was granted or found, or its host signed in): the cells that
# waited on it run, and a worker asked for from its panel starts.
function _region_ready!(nb::LiveNotebook, name::AbstractString)
    _restale_region_cells!(nb, String(name))
    _ensure_runner!(nb)
    lock(_START_LOCK) do; pop!(_START_ASKED, (nb.id, String(name)), nothing); end === nothing ||
        Threads.@spawn _start_region_worker!(nb, String(name))
    return nothing
end

# Region workers asked for from the worker panel's Start, until there is somewhere to start them.
const _START_ASKED = Dict{Tuple{String,String},Float64}()
const _START_LOCK = ReentrantLock()

"""
    _start_region_worker!(nb, name)

Start this notebook's worker on region `name` without running a cell: from the worker panel. A
region that needs a node first queues for one, as a cell's run does, and the worker starts when the
node is granted or the host is signed in to (`_region_ready!`).
"""
function _start_region_worker!(nb::LiveNotebook, name::String)
    try
        k = _region_kernel!(nb, name)
        try; facts_changed!(); catch; end
        ReportEngine.prepare!(k, nb.report; explicit = true)
    catch e
        if e isa RegionWaiting
            e.why in (WAIT_QUEUED, WAIT_CONNECTING) &&
                lock(_START_LOCK) do; _START_ASKED[(nb.id, name)] = time(); end
        else
            ReportEngine._rlog("region[$name]: starting its worker failed — $(first(sprint(showerror, e), 160))")
        end
    end
    try; facts_changed!(); catch; end
    return nothing
end

# Cells left waiting are picked up by an explicit run of the notebook. Without this a run request
# skips them, since the runner only takes STALE cells and a waiting cell is BLOCKED.
function _restale_blocked!(nb::LiveNotebook)
    # A run of the notebook is a request, so it ends the opening run's restraint even mid-way.
    lock(_OPENING_RUN_LOCK) do; delete!(_OPENING_RUN, nb.id); end
    n = lock(nb.lock) do
        k = 0
        for c in nb.report.cells
            c.state == BLOCKED && ReportEngine.restale!(c) && (k += 1)
        end
        k > 0 && (nb.version += 1)
        k
    end
    return n
end

"""
    RegionWaiting(why, host, region)

A region cell cannot run YET, and nothing is wrong. Thrown where the wait is discovered (under
`nb.lock`, which must never block), caught where the cell's state is set, and turned into `BLOCKED`
rather than `ERRORED`.

A distinct TYPE rather than a message match: the same call path also raises genuine failures — a
region that is not defined, a worker that could not start — and telling them apart by reading the
text would go wrong the first time someone rewords one.

`why` is a code, `host` is the machine it is about and `region` the region waited for. None is
written for a reader: the page words the wait, beside the chip that shows it.
"""
struct RegionWaiting <: Exception
    why::String
    host::String
    region::String
end
Base.showerror(io::IO, e::RegionWaiting) =
    print(io, e.why, isempty(e.host) ? "" : " (" * e.host * ")")

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

"This machine's named compute targets for the browser — a job cell's `cluster=` picker."
_clusters_json() =
    Any[Dict{String,Any}(String(k) => string(v) for (k, v) in c) for c in ReportEngine.clusters_all()]

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
                             "transport" => "tunnel", "root" => "", "warm" => 0,
                             "scheduler" => "none") :
            # `scheduler` rides along because the region panel decides what to SHOW from it — an
            # allocation and a queue mean nothing on an ordinary host — and asking the server per
            # region just to find that out would render the panel a round trip late.
            Dict{String,Any}("name" => r.name, "defined" => true, "host" => r.host,
                             "transport" => String(r.transport), "base_port" => r.base_port,
                             "root" => r.data_root, "cache_root" => r.cache_root,
                             "warm" => r.warm, "preload" => r.preload,
                             "scheduler" => String(r.scheduler),
                             # The machine it runs on: its own name for the machine itself, another
                             # for a variant of one, "" for a region with a host of its own.
                             "machine" => r.machine))
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
    # `data` is the declaration's payload (`slate_effect(kind; k = v)`). Kept, because a declaration
    # that carries a VALUE — an identity for a result the source cannot reproduce — has nowhere else
    # to put it, and dropping it silently made the channel look like it only carried a label.
    dat = _effect_field(e, :data)
    return (; kind = kind, names = names, stmt_src = src, data = dat)
end

# One field out of an effect's `data`, tolerant of the NamedTuple (in-process) and Dict (off the
# gate) shapes the wire produces.
function _effect_data(r, f::Symbol)
    d = r.data
    d === nothing && return nothing
    v = d isa AbstractDict ? get(d, f, get(d, String(f), nothing)) :
        (hasproperty(d, f) ? getproperty(d, f) : nothing)
    return v === nothing ? nothing : String(v)
end

# A `:pick` effect aims a pick control at an axis. The calibration has TWO consumers and they need
# it for different reasons, so it goes to both from this one declaration: the widget's params, so
# coercion can clamp a click into the axis and `bind_domain` can enumerate a snapped grid; and the
# cell's wire payload (see `_picks_json`), so the browser can put a click target over the figure.
# Writing it onto the widget is what keeps a pick honest — an uncalibrated control cannot clamp,
# and a stale one would clamp to an axis that is no longer on screen.
function _apply_pick_effect!(nb::LiveNotebook, c::Cell, r, e)
    data = _effect_field(e, :data)
    cal = data === nothing ? nothing : _effect_field(data, :calibration)
    cal === nothing && return nothing
    for nm in r.names
        id = ReportEngine.bind_owner(nb.report, String(nm))
        if isempty(id)
            ReportEngine._rlog("pick_on!: cell $(c.id) aimed at ':$(nm)', which no cell declares — ignored")
            continue
        end
        idx = findfirst(cc -> cc.id == id, nb.report.cells)
        idx === nothing && continue
        for b in nb.report.cells[idx].binds
            b.name === nm || continue
            if b.widget != "pick"
                ReportEngine._rlog("pick_on!: ':$(nm)' is a $(b.widget), not a pick control — ignored")
                continue
            end
            for (k, v) in pairs(cal)
                b.params[String(k)] = v
            end
        end
    end
    return nothing
end

function _apply_cell_effects!(nb::LiveNotebook, c::Cell, out)
    (out === nothing || isempty(out.effects)) && return nothing
    recs = [_effect_record(e) for e in out.effects]
    for (r, e) in zip(recs, out.effects)
        if r.kind === :everywhere
            :everywhere_declared in c.flags || push!(c.flags, :everywhere_declared)
        elseif r.kind === :volatile
            # This cell read live state that its source does not determine (a host session, a command
            # run somewhere). Marking it here is enough to stop the NEXT key being computed — the
            # entry this run stores is keyed and then never asked for again.
            :volatile_declared in c.flags || push!(c.flags, :volatile_declared)
        elseif r.kind === :value_identity
            # This cell's value is not a function of its source — a sweep's is whatever has landed
            # in its store. Recorded against every name the cell writes, so a reader's memo key
            # moves with the results. Applied HERE because this runs under `nb.lock` before anything
            # downstream is dispatched, which is the ordering the key computation depends on.
            d = _effect_data(r, :digest)
            d === nothing || for n in c.writes
                ReportEngine.note_state_write!(nb.report.id, string(n), d)
            end
        elseif r.kind === :pick
            _apply_pick_effect!(nb, c, r, e)
        elseif r.kind !== nothing
            ReportEngine._rlog("cell effects: cell $(c.id) declared unhandled effect kind ':$(r.kind)' — ignored")
        end
    end
    # Persist DURABLY, keyed by the cell's own source digest — so the classification + statement-scoped
    # records survive a reload / fresh region worker WITHOUT this cell running on main again (see
    # `_reestablish_effects!`). Best-effort; off the hot path but cheap (one small TOML).
    #
    # `:value_identity` is excluded on purpose: the store is keyed by SOURCE, and this record exists
    # precisely because the value is not a function of the source. Persisting it would hand a later
    # session an identity for results that have since changed — the stale restore this prevents.
    durable = [r for r in recs if r.kind !== :value_identity]
    isempty(durable) && return nothing
    try; EffectStore.store!(SlateHome.effects_dir(), string(c.src_hash), durable); catch e
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
        any(r -> r.kind === :everywhere, recs) &&
            (:everywhere_declared in c.flags || push!(c.flags, :everywhere_declared))
        # The half that matters most on a RELOAD: a cell that asked a host something last session is
        # uncacheable from t=0 this one, so a run-all asks again instead of restoring the old answer.
        any(r -> r.kind === :volatile, recs) &&
            (:volatile_declared in c.flags || push!(c.flags, :volatile_declared))
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

# Add/replace one package-declared import-map entry (specifier → url) — an extension's `provide_import!`,
# the package-level counterpart of a cell's `@use`. Returns true if the registry CHANGED, so the caller
# bumps the version and the browser picks up a fresh head. A NEW specifier reaches an already-open page
# over the state push (`moduleImports`), which extends the page's import map — so an extension installed
# mid-session works without a reload. Changing the URL of a specifier already declared still needs one.
function _register_import!(nb::LiveNotebook, spec::AbstractString, url::AbstractString)
    (isempty(spec) || isempty(url)) && return false
    s, u = String(spec), String(url)
    get(nb.pkgimports, s, nothing) == u && return false
    nb.pkgimports[s] = u
    return true
end

# The fence languages a markdown cell actually uses — read through the SAME desugaring the renderer
# runs, so this can never disagree with what would be rendered (a language mentioned in prose, or a
# fence nested inside another, doesn't count; only a block that really became an interpolation).
function _cell_fence_langs(c::Cell)
    c.kind == MARKDOWN || return String[]
    out = String[]
    for e in ReportEngine._md_interp_exprs(c.source)
        f = ReportEngine._fence_call(e)
        f === nothing || push!(out, f.lang)
    end
    return out
end

# Reconcile the notebook against the fence languages extensions currently claim, restaling any markdown
# cell whose fences just changed hands. This is what makes installing (or removing) a fence-providing
# extension VISIBLE: a markdown cell caches its `{{ }}` results, and a fence is one of those — so a
# block rendered while nobody claimed `mermaid` holds a plain-code fallback, and stays FRESH holding it,
# forever. Nothing about reloading the page, restarting the worker, or fixing the extension touches it;
# only a re-run does. Without this an extension reads as simply broken on first install.
# Returns whether anything changed. Caller holds `nb.lock`.
function _refresh_fences!(nb::LiveNotebook, claimed::Set{String})
    moved = symdiff(claimed, nb.fences)          # newly claimed OR newly released
    isempty(moved) && return false
    empty!(nb.fences); union!(nb.fences, claimed)
    hit = false
    for c in nb.report.cells
        any(l -> l in moved, _cell_fence_langs(c)) || continue
        ReportEngine.restale!(c) && (hit = true)
    end
    return hit
end

# The notebook's effective import map: package declarations UNDER the notebook's own `@use`, so an
# author's `@use` of a specifier always wins over the package that shipped it. Shared by the live shell
# head and the export, so the two can't drift.
function _effective_imports(nb::LiveNotebook)
    uses = get(nb.report.meta, "imports", nothing)
    usemap = uses === nothing ? Dict{String,String}() :
             Dict{String,String}(String(k) => String(v) for (k, v) in uses)
    return merge(nb.pkgimports, usemap)
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
    im = _manifest_field(manifest, :imports)
    if im !== nothing
        for e in im
            spec = _manifest_field(e, :spec); url = _manifest_field(e, :url)
            (spec === nothing || url === nothing) && continue
            lock(nb.lock) do
                _register_import!(nb, String(spec), String(url))
            end && (changed = true)
        end
    end
    fl = _manifest_field(manifest, :fences)
    fl === nothing || (lock(nb.lock) do
        _refresh_fences!(nb, Set{String}(String(f) for f in fl))
    end && (changed = true))
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

# How long the first cell on a scheduler region waits for a node before saying the queue is busy.
# Long enough that a test cluster or an idle partition just works; short enough that a busy one
# reports rather than hangs the run. The allocation is not cancelled either way — the next run
# attaches to it by name.
_alloc_wait_s() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_ALLOC_WAIT", "")), 180.0)

# Ask for a node without holding anything. One request per region at a time — a run loop that
# retries every second must not queue a hundred allocations, or raise a hundred password dialogs.
const _PLACING = Set{String}()
const _PLACING_LOCK = ReentrantLock()

# When the placement task of each region started, and when the request of each region was last
# withdrawn, both under `_PLACING_LOCK`. A withdrawal can arrive before the task has submitted the
# job, and the release then finds nothing to cancel. The task learns from these stamps that its
# request is no longer wanted.
const _PLACING_SINCE = Dict{String,Float64}()
const _WITHDRAWN_AT = Dict{String,Float64}()

_withdrawn_while_placing(name::AbstractString) = lock(_PLACING_LOCK) do
    since = get(_PLACING_SINCE, String(name), nothing)
    since !== nothing && get(_WITHDRAWN_AT, String(name), 0.0) >= since
end

# Stamp a withdrawal of region `name`, and return the stamp it replaced.
_stamp_withdraw!(name::AbstractString, t::Float64 = time()) = lock(_PLACING_LOCK) do
    prev = get(_WITHDRAWN_AT, String(name), nothing)
    _WITHDRAWN_AT[String(name)] = t
    prev
end

# When each notebook last asked for work (`_eval!` with `fresh`: a run, an edit, a restart), under
# `_PLACING_LOCK`. A withdrawal after it means the run still going was asked for before the request
# was withdrawn, so its cells do not ask for a node again; only a later request does.
const _RUN_ASKED_AT = Dict{String,Float64}()
_run_asked!(nb::LiveNotebook) = lock(_PLACING_LOCK) do; _RUN_ASKED_AT[nb.id] = time(); end
_withdrawn_since_asked(nb::LiveNotebook, name::AbstractString) = lock(_PLACING_LOCK) do
    get(_WITHDRAWN_AT, String(name), 0.0) > get(_RUN_ASKED_AT, nb.id, 0.0)
end

# A request for a node is still wanted when a placement task runs for it and no withdrawal has
# arrived since that task started.
_region_queued(name::AbstractString) =
    lock(_PLACING_LOCK) do; String(name) in _PLACING; end && !_withdrawn_while_placing(name)

# After a request for region `name` was withdrawn, the cells of `nb` waiting in its queue wait for a
# run instead. Left waiting as queued, the supervisor (`_reconcile_blocked_regions!`) would ask for a
# node again within `_REPLACE_EVERY`; a cell that waits to be run is one it leaves alone.
function _withdraw_region_waits!(nb::LiveNotebook, name::AbstractString)
    n = 0
    lock(nb.lock) do
        for c in nb.report.cells
            (c.state == BLOCKED && c.blocked == WAIT_QUEUED && c.blocked_region == name) || continue
            ReportEngine.mark_blocked!(c, WAIT_NOT_REQUESTED, c.blocked_host, name)
            n += 1
        end
        n > 0 && (nb.version += 1)
    end
    n > 0 && (try; _broadcast(nb, string(nb.version)); catch; end)
    return n
end

# The cells that were waiting on this region: mark them stale so the next drain picks them up.
# BLOCKED is the state a wait leaves behind; ERRORED is included too because a cell that failed for
# its own reasons simply fails again, which is cheaper than matching on error text that is free to
# be reworded.
_region_recoverable(c) = c.state == BLOCKED || c.state == ERRORED

function _restale_region_cells!(nb::LiveNotebook, name::AbstractString)
    nb.closed && return 0
    n = 0
    lock(nb.lock) do
        # Every cell that RUNS on this region, whether or not it is still waiting — then everything
        # downstream of them that stalled. A cell reading a value from the region is blocked by the
        # same missing node but carries no region tag of its own, so keying this off a tagged cell
        # that is STILL blocked strands the reader whenever the tagged cell recovers first: the
        # region comes back, the cell that named it runs, and its reader stays stuck needing a hand
        # it should not need. Which cells are then recovered is still decided by their state.
        tagged = String[c.id for c in nb.report.cells if _cell_region(c) == name]
        isempty(tagged) && return
        blast = ReportEngine.dependents_of(nb.report, tagged)
        for c in nb.report.cells
            (c.id in blast && _region_recoverable(c)) || continue
            ReportEngine.restale!(c) && (n += 1)
        end
        n > 0 && (nb.version += 1)
    end
    n > 0 && (try; _broadcast(nb, string(nb.version)); catch; end)
    return n
end

# Kernels whose wire went down with a LOST ssh session (not a sign-out), with that session's host.
# Their next run waits on a key sign-in to the host instead of failing on the missing session.
const _LOST_SESSION = WeakKeyDict{Any,String}()
const _LOST_SESSION_LOCK = ReentrantLock()

_session_lost!(k, host::AbstractString) = lock(_LOST_SESSION_LOCK) do; _LOST_SESSION[k] = String(host); end
_session_regained!(host::AbstractString) = lock(_LOST_SESSION_LOCK) do
    for k in [k for (k, h) in _LOST_SESSION if h == host]; delete!(_LOST_SESSION, k); end
end

# The host whose session `k` is waiting on, or "" when it is not waiting on one: never lost, wire
# back up, or the session already open again.
function _lost_session_of(k)
    (k isa ReportEngine.GateKernel && k.conn === nothing) || return ""
    h = lock(_LOST_SESSION_LOCK) do; get(_LOST_SESSION, k, ""); end
    isempty(h) && return ""
    ReportEngine.Sweep.connected(h) || return h
    _session_regained!(h)
    return ""
end

# Key-only connects in flight, per host, with the regions waiting on each. One attempt serves every
# region on the host, and all of them are re-run when it ends.
const _CONNECTING = Dict{String,Vector{Tuple{Any,String}}}()
const _CONNECTING_LOCK = ReentrantLock()

function _connect_in_background!(name::AbstractString, nb::Union{LiveNotebook,Nothing}, host::AbstractString)
    h = String(host)
    starts = lock(_CONNECTING_LOCK) do
        w = get(_CONNECTING, h, nothing)
        w === nothing || (push!(w, (nb, String(name))); return false)
        _CONNECTING[h] = Tuple{Any,String}[(nb, String(name))]
        true
    end
    starts || return nothing
    Threads.@spawn begin
        ok = try; ReportEngine.Sweep.connect!(h); catch; false; end
        ReportEngine._rlog("region: key-only connect to $h " * (ok ? "succeeded" : "failed — waiting for a sign-in"))
        ok && _session_regained!(h)
        waiters = lock(_CONNECTING_LOCK) do; pop!(_CONNECTING, h, Tuple{Any,String}[]); end
        # Re-run whoever was waiting: connected, they queue for a node; refused, the failure just
        # recorded turns their wait into a sign-in. A failure that recorded nothing (a login someone
        # else started is still open) is left alone, since re-running would only start this again.
        if ok || ReportEngine.Sweep.connect_failed_recently(h)
            for (w, n) in unique(waiters)
                w === nothing && continue
                try; _region_ready!(w, n); catch; end
            end
        end
    end
    return nothing
end

# `by_run` says that a cell run asks, rather than the supervisor. A run wants the node again even when
# the request of the task still in flight was withdrawn, so that task keeps what it gets.
function _place_in_background!(name::AbstractString, nb::Union{LiveNotebook,Nothing} = nothing;
                               by_run::Bool = false, find_only::Bool = false)
    lock(_PLACING_LOCK) do
        if String(name) in _PLACING
            by_run && _withdrawn_while_placing(name) && (_PLACING_SINCE[String(name)] = time())
            return false
        end
        push!(_PLACING, String(name))
        _PLACING_SINCE[String(name)] = time()
        true
    end || return nothing
    Threads.@spawn try
        # This task exists only to bring `name` up, so tag every _rlog it emits into that region's
        # acquisition trace, and clear any trace from a previous bring-up so this one reads clean.
        ReportEngine.region_trace_reset!(name)
        ReportEngine.set_rlog_region!(name)
        r = ReportEngine.region_get(name)
        if r !== nothing
            # Anchor the acquisition trace at the queue start. The queue wait itself is otherwise
            # silent until a node lands, so without this line the worker panel would show nothing for
            # the minutes a busy cluster can take to grant one.
            if find_only
                ReportEngine._rlog("region[$name]: looking for a node it still holds on $(r.host)")
            else
                ReportEngine._rlog("region[$name]: queued for a node on $(r.host) - waiting for the scheduler to grant one")
                if nb !== nothing
                    try; _broadcast(nb, "bringup:region '$name': queued for a node on $(r.host)…"); catch; end
                    try; facts_changed!(); catch; end   # the pill says "queued" NOW, not once it lands
                end
            end
            _, alloc = ReportEngine.region_place!(r; wait_s = _alloc_wait_s(), submit = !find_only)
            # Withdrawn while this task submitted the request or waited on it: whatever the scheduler
            # holds for it is given back, and the cells that waited on it wait for a run.
            if _withdrawn_while_placing(name)
                ReportEngine._rlog("region[$name]: the request was withdrawn while it was placed — releasing it")
                # The withdrawal usually cancelled the job already, leaving this release nothing to do.
                if !ReportEngine.region_release!(r)
                    left = ReportEngine.region_allocation(r)
                    (left === nothing || left.state !== :none) &&
                        ReportEngine._rlog("region[$name]: releasing the withdrawn request failed; " *
                                           "the scheduler may still hold it")
                end
                return
            end
            if find_only && !ReportEngine._region_holds_node(r)
                ReportEngine._rlog("region[$name]: no node held")
            elseif !ReportEngine._region_holds_node(r)
                p = ReportEngine.placement_note(r, alloc)
                ReportEngine._rlog("region[$name]: " * p.text)
                p.state === :queued ||
                    (nb === nothing || (try; _broadcast(nb, "bringup:region '$name': could not get a node: $(p.text)"); catch; end))
            end
            # A NODE JUST ARRIVED, so the idle clock starts now. Without this it carries over the
            # wait that preceded the grant — time when nothing was held and nothing could be idle —
            # and a region that queued longer than its own timeout is released the moment it lands.
            # Whether a node is held is asked of the placement itself, never inferred from the node
            # name: a single-node cluster grants a node named like the front door (`clima`), so
            # `region_host(r) == r.host` would read "unplaced" even with a node in hand.
            ReportEngine._region_holds_node(r) && _region_used!(String(name))
            # Queue waits are measured in minutes on a real cluster, so the cell that asked must not
            # be left saying "run me again" — nobody should have to poll a notebook by hand. The
            # node landing is the event; re-arm the runner and the waiting cells run themselves.
            if nb !== nothing && ReportEngine._region_holds_node(r)
                # A job that has already spent part of its walltime was there before this asked: found,
                # not granted (a hub restart finding its region's node by name, say).
                found = alloc !== nothing && !isempty(alloc.timeleft) &&
                        ReportEngine._sched_seconds(alloc.timeleft) < ReportEngine._sched_seconds(ReportEngine._alloc_walltime(r)) - 120
                ReportEngine._rlog("region[$name]: " * (found ? "found its node still held" : "node granted") *
                                   " ($(ReportEngine.region_host(r))) — re-running the cells that were waiting")
                _region_ready!(nb, String(name))
            end
        end
    catch e
        ReportEngine._rlog("region[$name]: placement failed — $(first(sprint(showerror, e), 160))")
        nb === nothing || (try; _broadcast(nb, "bringup:region '$name': could not get a node — $(first(sprint(showerror, e), 120))"); catch; end)
    finally
        lock(_PLACING_LOCK) do
            delete!(_PLACING, String(name))
            delete!(_PLACING_SINCE, String(name))
        end
        nb === nothing || (try; facts_changed!(); catch; end)   # …and stops saying it afterwards
    end
    return nothing
end

# The notebook's kernel for region `name`, created lazily from its footer spec (spawn/adopt
# happens at its first prepare!, so a warm-pool worker makes this ~1s). Label carries the
# region so the worker roster + attach records distinguish kernels.
# `preparing`: the caller is the region's prepare, starting the worker it hands to this notebook.
function _region_kernel!(nb::LiveNotebook, name::String; preparing::Bool = false)
    lock(_REGION_LOCK) do
        # Checked under the lock its teardown takes, so a closing notebook gets no kernel after it.
        nb.closed && error("$(basename(nb.path)) was closed")
        r = ReportEngine.region_get(name)
        r === nothing && error("region '$name' is not defined — create it in the registry: " *
                               "region(\"$name\"; host=…, warm=…) or the home-page Regions manager")
        isempty(r.host) && error("region '$name' has no host — set one in the Regions manager")
        # While the region is being prepared its cells wait for it: a prepare for this notebook starts
        # the worker they will use, and a second one started beside it competes for the same node.
        (!preparing && ReportEngine.prepare_running(r.name)) && throw(RegionWaiting(WAIT_PREPARING, r.host, r.name))
        at = ReportEngine.region_where(r)
        k = get(_REGION_KERNELS, (nb.id, name), nothing)
        # A cached kernel's target names the node it runs on and, on a scheduler region, the job that
        # node was granted in. Either can go stale: the next allocation may land on another node, or on
        # the same one (a single-node cluster grants its only node every time, so the name alone cannot
        # tell two allocations apart), and a released allocation leaves no job at all. In each case the
        # worker ended with its allocation, so the kernel is rebuilt rather than retried forever.
        if k !== nothing
            tgt = k.target
            if !(tgt isa ReportEngine.RemoteTarget) || (tgt.ssh_host, tgt.job) == at
                # Still where it should be, but its wire went down with a lost ssh session: it is
                # reached again through a new one. A key sign-in is tried once, in the background (this
                # runs under `nb.lock`), for every cell waiting on the host, and they are re-run when it
                # ends. A kernel whose node is gone is not reconnected; it is rebuilt below.
                if (sh = _lost_session_of(k)) != ""
                    ReportEngine.Sweep.connect_failed_recently(sh) &&
                        throw(RegionWaiting(WAIT_NOT_SIGNED_IN, sh, r.name))
                    _connect_in_background!(name, nb, sh)
                    throw(RegionWaiting(WAIT_CONNECTING, sh, r.name))
                end
                return k
            end
            ReportEngine._rlog("region: '$name' moved off $(_at_label(tgt.ssh_host, tgt.job)) " *
                               "to $(_at_label(at...)) — rebuilding its kernel")
            _forget_region_kernel!(nb, name)
            # Its wire is dropped on a task of its own: the drop takes the kernel's lock, which a spawn
            # in progress holds, and this runs under `_REGION_LOCK` and the notebook's lock.
            let old = k
                Threads.@spawn try; ReportEngine._drop_kernel_conn!(old); catch; end
            end
        end
        proj = Base.current_project(dirname(abspath(nb.path)))
        parent = proj === nothing ? "" : dirname(proj)   # notebook's own /src synced for hot-reload provenance
        # The region worker replicates the NOTEBOOK's exact env — its own fork env if it has one, else the
        # parent project (identical resolution to `_select_kernel`'s whole-notebook remote path). The region's
        # `preload` is only a warm-pool key, never the env a region cell runs — so a region cell gets the
        # notebook's packages + dev'd path deps even when the region has no preload configured.
        envdir = ReportEngine.notebook_env_dir(nb.path)
        origin_env = isfile(joinpath(envdir, "Project.toml")) ? envdir :
                     (!isempty(parent) && isfile(joinpath(parent, "Project.toml")) ? parent : "")
        # A notebook's first worker on a region goes through preparing it, step by step and in view,
        # rather than meeting the site's first-time problems inside the run.
        why = preparing ? "" : _prepare_reason(r, origin_env)
        if !isempty(why)
            (_in_opening_run(nb.id) && isempty(get(_FORCE_RUN, nb.id, ()))) || _announce_prepare!(nb, r; reason = why)
            throw(RegionWaiting(WAIT_NEEDS_PREPARE, r.host, r.name))
        end
        # Where the worker goes. On a scheduler region `r.host` is the front door, not the address —
        # the node is granted, not configured. Getting one can mean queueing, and on a gated cluster
        # it can mean waiting for a person to read a code off a phone. THIS RUNS UNDER `nb.lock`, so
        # it must never wait for either: it reads the placement already held, and otherwise starts
        # one in the background and says so. The cell is run again when there is somewhere to run it.
        host = first(at)
        if r.scheduler !== :none
            # Placed-or-not is asked of the placement, never inferred from the node name: a single-node
            # cluster grants a node named like the front door, so `region_host(r) == r.host` misreads.
            # It is read from `at`, the placement the target is built from, so the two cannot differ.
            if isempty(last(at))   # nothing placed yet
                # A cell someone ran by hand during the opening run is a request all the same.
                (_in_opening_run(nb.id) && isempty(get(_FORCE_RUN, nb.id, ()))) &&
                    throw(RegionWaiting(WAIT_NOT_REQUESTED, r.host, r.name))
                # Asking for a node needs the cluster, and reaching the cluster may need a password
                # that only a person can supply — which background work is not allowed to ask for.
                # A host that takes a key needs nobody, so that is tried first, in the background
                # because this runs under `nb.lock`. Only once it has failed is the cell told to wait
                # on a sign-in; queueing and signing in need different things from you.
                if !ReportEngine.Sweep.connected(r.host)
                    ReportEngine.Sweep.connect_failed_recently(r.host) &&
                        throw(RegionWaiting(WAIT_NOT_SIGNED_IN, r.host, r.name))
                    _connect_in_background!(name, nb, r.host)
                    throw(RegionWaiting(WAIT_CONNECTING, r.host, r.name))
                end
                _withdrawn_since_asked(nb, name) && throw(RegionWaiting(WAIT_NOT_REQUESTED, r.host, r.name))
                _place_in_background!(name, nb; by_run = true)
                # A queue wait is minutes on a busy cluster, so this is not a "try again" — the
                # placement task re-runs this cell itself when the scheduler grants a node.
                throw(RegionWaiting(WAIT_QUEUED, r.host, r.name))
            end
        end
        target = ReportEngine._region_target(r; origin_env = origin_env, at = at)   # transport/datadir/region from the def; env = the notebook's
        ReportEngine._rlog("region: kernel '$name' for $(nb.id) → $host ($(r.transport))" *
                           (host == r.host ? "" : " via $(r.host)") *
                           (isempty(r.data_root) ? "" : " root=$(r.data_root)"))
        k = ReportEngine.GateKernel(target.project; parent = parent, target = target, threads = ReportEngine.region_threads(r),
                                    label = basename(abspath(nb.path)) * "#" * name)
        _REGION_KERNELS[(nb.id, name)] = k
        return k
    end
end

_at_label(host, job) = isempty(job) ? String(host) : "$host (job $job)"

# Forget one of a notebook's region kernels, along with what the hub remembers about it: that its
# imports were primed, and which boundary values it already holds. The kernel that replaces it is a
# fresh namespace whose generation count starts over, so a sync record left behind can match the new
# kernel's key and skip shipping a value the new worker never received. Returns the kernel, which the
# caller shuts down or disconnects as the situation needs.
function _forget_region_kernel!(nb::LiveNotebook, side::AbstractString)
    lock(_REGION_LOCK) do
        k = pop!(_REGION_KERNELS, (nb.id, String(side)), nothing)
        if k !== nothing
            delete!(_REGION_PRIMED, (nb.id, _worker_key(k)))
            lock(_LOST_SESSION_LOCK) do; delete!(_LOST_SESSION, k); end   # its session is no one's to wait on now
        end
        synced = get(_REGION_SYNCED, nb.id, nothing)
        synced === nothing || filter!(kv -> !startswith(kv[1], side * ":"), synced)
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
# The cells a region worker loads before it runs anything (`_prime_namespace!`), and their signature.
function _prime_env(nb::LiveNotebook)
    env = [c for c in nb.report.cells if ReportEngine._cell_effect(c) == ReportEngine.EVERYWHERE]
    return env, hash([c.src_hash for c in env])
end

# Whether a region worker still has bringing up to do for this notebook: it is not connected yet, or
# has not loaded the notebook's imports.
function _region_bringup_pending(nb::LiveNotebook, k)
    k isa ReportEngine.GateKernel || return false
    k.conn === nothing && return true
    env, sig = _prime_env(nb)
    isempty(env) && return false
    return lock(_REGION_LOCK) do; get(_REGION_PRIMED, (nb.id, _worker_key(k)), UInt(0)); end != sig
end

function _prime_namespace!(nb::LiveNotebook, k, side::AbstractString)
    # Cells that ESTABLISH state on every side — pure `using`/`import`, the import scaffold, a `set_theme!`
    # setter — re-run (never transferred) in document order so imports precede a scaffold/effect that
    # builds on them. This is exactly the `EVERYWHERE` category of the single `_cell_effect` classifier
    # (deps.jl), so the region prime and the memo replay read the SAME definition — a standalone
    # `set_theme!` can no longer silently miss the region. `RESOURCE` runs on every side too but has data
    # deps, so it replays at READ (`_ensure_resource_on!`), not here.
    env, sig = _prime_env(nb)
    isempty(env) && return nothing
    key = (nb.id, _worker_key(k))
    lock(_REGION_LOCK) do; get(_REGION_PRIMED, key, UInt(0)); end == sig && return nothing
    # Re-entrancy: the presync below primes both sides before its first transfer, which lands back
    # here. Bail if this key is already in flight rather than re-running the loop underneath it.
    lock(_REGION_LOCK) do
        key in _REGION_PRIMING ? true : (push!(_REGION_PRIMING, key); false)
    end && return nothing
    try
        for c in env
            # Stage this cell's cross-boundary DATA reads before replaying it. A definition primed here may
            # reference an upstream global, and presync only ever stages the reads of the cell it is called
            # FOR — a downstream region cell reads the FUNCTION, not what the function's body reads, so
            # nothing else would bring those values over. Values written by EVERYWHERE cells are skipped
            # inside presync (they prime, never ship), so only genuine data crosses. Conservative inference
            # over-approximates the reads here, which is the safe direction: a surplus value is one
            # content-addressed transfer that dedups to nothing on the next prime.
            # Best-effort — a miss surfaces as an UndefVarError when the definition is CALLED, not here.
            try; _region_presync!(nb, c, k; dst_side = side); catch e
                ReportEngine._rlog("region: presync for prime of $(c.id) on $(_side_label(nb, side)) failed: " *
                                   first(sprint(showerror, e), 160))
            end
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
    finally
        lock(_REGION_LOCK) do; delete!(_REGION_PRIMING, key); end
    end
    lock(_REGION_LOCK) do; _REGION_PRIMED[key] = sig; end
    return nothing
end

# What to REPLAY to re-establish an EVERYWHERE cell's effect on another namespace. Only the cell's
# EFFECT belongs on the other side, never its compute, so the replay is assembled from two sources:
#   • the SCAFFOLD — its top-level `using`/`import` statements and theme-setter calls, which is what
#     makes a cell statically EVERYWHERE in the first place (`_scaffold_replay_source`);
#   • the statements that DECLARED an `:everywhere` effect at runtime (this session's harvest, or the
#     durable store across a reload).
# A pure-`using` cell is all scaffold, so it replays whole. Whole-cell replay is otherwise only the
# LAST RESORT (nothing to extract) — a MIXED cell that opens with `using Plotting` and then plots from
# an upstream cell's data must not re-run the plot here: it reads names this namespace doesn't have
# (they live in a cell that isn't itself EVERYWHERE), so replaying it whole throws on a binding the
# scaffold never needed. The caller still falls back to whole-cell if the extracted source throws.
function _everywhere_replay_source(c::Cell)
    # The author TAG is an explicit "all of this belongs on every side" — replay the cell whole and
    # skip the extraction entirely. It exists for the cell that neither the definitional-statement
    # rule nor a runtime declaration can recognise.
    :everywhere in c.flags && return c.source
    scaffold = ReportEngine._is_pure_using(c.source) ? c.source :
               ReportEngine._scaffold_replay_source(c.source)
    (:everywhere_declared in c.flags) || return isempty(scaffold) ? c.source : scaffold
    recs = (c.output !== nothing && !isempty(c.output.effects)) ? c.output.effects :
           try; EffectStore.load(SlateHome.effects_dir(), string(c.src_hash)); catch; nothing; end
    stmts = String[]; seen = Set{String}()
    isempty(scaffold) || (push!(seen, scaffold); push!(stmts, scaffold))
    for r in (recs === nothing ? () : recs)
        s = strip(String(something(_effect_field(r, :stmt_src), "")))
        (isempty(s) || s in seen) && continue
        push!(seen, s); push!(stmts, s)
    end
    isempty(stmts) ? c.source : join(stmts, "\n")
end

# Detach (default) or kill every region kernel + forget the boundary sync state.
function _teardown_region!(nb::LiveNotebook; kill::Bool = false, wait::Bool = true)
    ks = lock(_REGION_LOCK) do
        got = [pop!(_REGION_KERNELS, key) for key in collect(keys(_REGION_KERNELS)) if key[1] == nb.id]
        delete!(_REGION_SYNCED, nb.id)
        filter!(kv -> kv[1][1] != nb.id, _REGION_PRIMED)   # forget priming so a re-setup re-primes fresh kernels
        got
    end
    for k in ks
        try; ReportEngine.shutdown!(k; kill_remote = kill, wait); catch e
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
    k = _forget_region_kernel!(nb, side)
    k === nothing || try; ReportEngine.shutdown!(k; kill_remote = true); catch e
        @warn "slate region: restart teardown failed" notebook = nb.id side = side exception = e
    end
    ids = String[]
    lock(nb.lock) do
        for cell in nb.report.cells
            (cell.kind == CODE && _cell_side(nb, cell) == side) || continue
            cell.state = STALE; push!(ids, cell.id)
        end
        # The re-run below serves no ▶: one still pending on these cells would compute a locked cell
        # nobody just asked for (see `restart_kernel!`).
        frc = get(_FORCE_RUN, nb.id, nothing)
        frc === nothing || setdiff!(frc, ids)
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
# Region cells marked RUNNING but not yet handed to a worker — see `_prepare_region_for_cell!`. Held
# only for that window, and dropped defensively when the cell stops running, so a preparation that
# dies without reaching its dispatch cannot make a cell permanently unhealable.
const _REGION_PREPARING = Set{Tuple{String,String}}()
const _REGION_PREPARING_LOCK = ReentrantLock()
_region_preparing(nbid, cid) =
    lock(_REGION_PREPARING_LOCK) do; (String(nbid), String(cid)) in _REGION_PREPARING; end
_region_prepared!(nbid, cid) =
    (lock(_REGION_PREPARING_LOCK) do; delete!(_REGION_PREPARING, (String(nbid), String(cid))); end; nothing)
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
# The silence a remote wire may keep before it is dropped. A region worker takes its region's own
# setting; else what preparing the region measured for this worker's project, whose packages are what
# a busy worker is loading; else what it measured for the site; anything else gets the hub's default.
# Never shorter than the default: a measurement only ever adds patience.
# While its region is being prepared, a worker is loading the notebook's packages for the prepare,
# which can leave it silent for longer than any grace measured before; the prepare's steps carry their
# own time limits, so its silence is shown but its wire is kept.
function _prepare_holds(k)
    t = try; k.target; catch; nothing; end
    return t isa ReportEngine.RemoteTarget && !isempty(t.region) && ReportEngine.prepare_running(t.region)
end

function _dead_wire_grace(k)
    t = try; k.target; catch; nothing; end
    t isa ReportEngine.RemoteTarget || return _DEAD_WIRE_GRACE
    r = isempty(t.region) ? nothing : ReportEngine.region_get(t.region)
    r === nothing && return _DEAD_WIRE_GRACE
    r.liveness_grace > 0 && return Float64(r.liveness_grace)
    e = ReportEngine.env_report(r, t.origin_env)
    m = e === nothing ? get(r.readiness, "liveness_grace_s", nothing) : get(e, "liveness_grace_s", nothing)
    return m isa Real ? max(_DEAD_WIRE_GRACE, Float64(m)) : _DEAD_WIRE_GRACE
end
# A worker that missed a ping while its telemetry kept arriving: the gate answers each request on a
# default-pool thread, which cells can keep busy, while telemetry is sent from an interactive one. Busy,
# not gone, so no countdown runs; the time is kept for the pill.
const _KERNEL_BUSY_SINCE = WeakKeyDict{Any,Float64}()
const _TELEMETRY_FRESH_S = 10.0
function _telemetry_fresh(k)
    cn = try; String(k.conn.name); catch; return false; end
    st = ReportEngine.kernel_stats(cn)
    (st === nothing || time() - st.latest.rcv >= _TELEMETRY_FRESH_S) && return false
    # A reading taken from outside says the process is there; only CPU time going up says it is working.
    s = st.latest
    return !(hasproperty(s, :src) && s.src == "host") || s.cpu >= _HOST_BUSY_CPU
end

# ── telemetry from outside a silent worker ──────────────────────────────────────────────────────
# A worker sends its own samples, and nothing in its process runs while a garbage collection waits for
# a thread inside code with no GC safepoint (one long loop, a call into a library). For as long as a
# LOCAL worker's own samples are missing, the hub reads its process from the operating system and
# records that reading in their place, marked `src = "host"`: the charts keep moving, and liveness can
# tell a worker that is computing from one that is gone. A remote worker's process is out of reach.
const _HOST_STALE_S = 5.0          # no sample from the worker for this long: read it from outside
const _HOST_SAMPLE_S = 2.0         # how often the hub looks, the workers' own sampling rate
const _HOST_SAMPLER = Ref{Any}(nothing)
const _HOST_BUSY_CPU = 5.0         # % of a core, as read from outside, that counts as working
const _HOST_LAST = WeakKeyDict{Any,Tuple{Float64,Float64}}()   # kernel → (wall time, cpu seconds) at the last look

# CPU seconds and RSS bytes of a local process, read from the system without starting anything, or
# `nothing`. The same sources the worker samples itself from (worker.jl `_telemetry_loop!`).
function _proc_cpu_rss(pid::Integer)
    if Sys.islinux()
        try
            s = read("/proc/$pid/stat", String)
            f = split(s[findlast(')', s)+2:end])            # fields from 3 on (the name may hold spaces)
            clk = ccall(:sysconf, Clong, (Cint,), 2)          # _SC_CLK_TCK
            pg = ccall(:sysconf, Clong, (Cint,), 30)          # _SC_PAGESIZE
            rss = parse(Int, split(read("/proc/$pid/statm", String))[2]) * pg
            return ((parse(Int, f[12]) + parse(Int, f[13])) / clk, rss)
        catch
            return nothing
        end
    elseif Sys.isapple()
        buf = Vector{UInt8}(undef, 256)                       # rusage_info_v0
        ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt8}), Int32(pid), Cint(0), buf) == 0 || return nothing
        user, sys, rss = (reinterpret(UInt64, @view buf[r])[1] for r in (17:24, 25:32, 65:72))
        # Mach ticks, nanoseconds only on Intel (see the worker's `_telemetry_loop!`).
        tb = zeros(UInt32, 2)
        ccall(:mach_timebase_info, Cint, (Ptr{UInt32},), tb)
        return ((user + sys) * (tb[2] > 0 ? tb[1] / tb[2] : 1.0) / 1e9, Int(rss))
    end
    return nothing
end

# When the worker itself last sent a sample, from the kernel's ring.
function _last_worker_sample(st)
    for s in Iterators.reverse(st.history)
        (hasproperty(s, :src) && s.src == "host") || return s
    end
    return nothing
end

function _host_sample!(k)
    (k isa ReportEngine.GateKernel && k.conn !== nothing) || return nothing
    p = k.proc
    (p === nothing || !process_running(p)) && return nothing   # a local worker: its process is ours
    cn = String(k.conn.name)
    st = ReportEngine.kernel_stats(cn)
    st === nothing && return nothing
    r = _proc_cpu_rss(getpid(p))
    r === nothing && return nothing
    # The baseline is kept current on every look, so the first look after the worker falls silent
    # already has a rate to report.
    now = time()
    prev = get(_HOST_LAST, k, nothing)
    _HOST_LAST[k] = (now, r[1])
    w = _last_worker_sample(st)
    (w === nothing || now - w.rcv < _HOST_STALE_S || prev === nothing) && return nothing
    cpu = round(100 * (r[1] - prev[2]) / max(now - prev[1], 1e-3); digits = 1)
    ReportEngine.record_sample!(cn, merge(st.latest, (cpu = cpu, rss = r[2], ts = now, rcv = now, src = "host")))
    return nothing
end
const _LIVENESS_PING_TIMEOUT = 8.0   # per-ping timeout; also how far to BACKDATE first-silence — when a ping first fails the worker has already been silent this long, so the countdown starts at ~8s, not 0
const _LAST_RUNNING = Dict{String,Tuple{Set{String},Set{String},Set{String}}}()   # nb id → (running ids, sides that answered, sides asked) from the last sweep
# Repeat-suppression for the unresponsive log. A wire that stays silent used to write one identical
# line per sweep — an outage lasting a working day produced hundreds of KB of the same sentence, which
# buries the events that actually explain it. Log the FIRST failure, one line per interval while it
# stays silent (carrying the elapsed time, so the log says how long rather than how many times), and
# one line when it answers again.
const _LIVENESS_LOG_EVERY = 300.0                     # s between repeat "still silent" lines
const _LIVENESS_LOG_LAST = WeakKeyDict{Any,Float64}() # kernel → when we last logged its silence

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
# Has this kernel's worker PROCESS exited? Decidable instantly and with certainty, unlike silence —
# which a busy worker and a dead one produce identically. `false` for anything we didn't spawn (a
# remote or attached kernel has no local handle), so callers keep their existing remote-only rules.
function _kernel_proc_dead(k)
    p = try; getfield(k, :proc); catch; nothing; end
    p === nothing && return false
    return try; !process_running(p); catch; false; end
end

# A wire severed with its ssh session is not an unresponsive worker, and must not be reported as one:
# the worker on the far side is very likely fine. So it is dropped WITHOUT the unresponsive clock — no
# countdown, no "stopped responding". `hold` is for a deliberate sign-out: the kernel then reconnects
# only on an explicit run after a sign-in. A session that died under it is not held, so the next run
# signs in again with a key where it can and re-attaches to the same worker.
function _drop_signed_out_wire!(nb::LiveNotebook, k, host::AbstractString; hold::Bool = true)
    delete!(_KERNEL_UNRESPONSIVE_SINCE, k)     # never a health story; don't leave a phantom countdown
    delete!(_LIVENESS_LOG_LAST, k)
    dropped = try; ReportEngine._drop_kernel_conn!(k)
    catch e
        ReportEngine._rlog("liveness: dropping the signed-out wire on $(nb.id)/$(_kernel_side_label(nb, k)) failed: " *
                           first(sprint(showerror, e), 120)); false
    end
    dropped || return false
    hold ? (try; k.redial_hold = true; catch; end) : _session_lost!(k, host)
    ReportEngine._rlog("liveness: $(nb.id)/$(_kernel_side_label(nb, k)) rides the session for $host, " *
                       (hold ? "which is signed out — dropped its wire (reconnects on an explicit run after a sign-in)" :
                               "which was lost — dropped its wire (the next run re-attaches)"))
    try; facts_changed!(); catch; end
    return true
end

# Every wire an ssh session was carrying, dropped the moment that session goes. The answer is known
# immediately, so nothing should have to time out to reach it. Installed on the transport's drop
# announcement (see `ReportEngine._session_dropped!`).
function _install_session_drop!(h)
    ReportEngine._SESSION_DROP_SINK[] = function (host, hosts, died = false)
        nbs = lock(h.lock) do; collect(values(h.notebooks)); end
        n = 0
        for nb in nbs, k in _nb_kernels(nb)
            (k isa ReportEngine.GateKernel && k.conn !== nothing) || continue
            ReportEngine.rides_session(k, hosts) || continue
            _drop_signed_out_wire!(nb, k, String(host); hold = !died) && (n += 1)
        end
        n == 0 || ReportEngine._rlog("session drop on $host: dropped $n worker wire(s) it was carrying")
        facts_changed!()
        return nothing
    end
    # …and back, whatever signed the host in again.
    ReportEngine.Sweep.SshTransport.on_connect!() do host
        _session_regained!(host)
        facts_changed!()
    end
    return nothing
end

function _heal_dead_wire!(nb::LiveNotebook, k, unresp_s::Real = 0.0)
    side = _kernel_side_label(nb, k)
    auto = _region_autoretry()
    ReportEngine._rlog("liveness: dead wire on $(nb.id)/$(side) — worker unresponsive for $(round(Int, unresp_s))s (grace $(round(Int, _dead_wire_grace(k)))s); dropping the connection ($(auto ? "auto-retry: next run re-dials" : "manual: holds until an explicit re-run"))")
    dropped = try; ReportEngine._drop_kernel_conn!(k)
    catch e; ReportEngine._rlog("liveness: drop failed on $(nb.id)/$(side): " * first(sprint(showerror, e), 120)); false
    end
    dropped && !auto && (try; k.redial_hold = true; catch; end)
    dropped && (try; facts_changed!(); catch; end)   # pill flips to amber "reconnecting" NOW, not at the next state
    return dropped
end

# Ping every connected kernel: refresh the heartbeat, track failures, heal dead remote wires, and
# stash the running cell ids, with which kernels answered, for the orphan reconciler. Runs every sweep (idle or busy) so a
# wire that dies while nothing is running is still healed before the next cell is dispatched onto it.
function _liveness_sweep!(nb::LiveNotebook)
    ids = Set{String}(); answered = Set{String}(); asked = Set{String}()
    for k in _nb_kernels(nb)
        (k isa ReportEngine.GateKernel && k.conn !== nothing) || continue
        push!(asked, _kernel_side_label(nb, k))
        # Don't ping down a wire we KNOW is severed. A `:tunnel` worker's connection is a forward on
        # its host's ssh session, so once nobody is signed in to that host the wire cannot answer —
        # and pinging it anyway spends 8s per sweep to rediscover, over 45s of countdown, a fact that
        # signing out established instantly. Say so and drop it; the `_SESSION_DROP_SINK` normally
        # gets there first, and this covers a session that died without being dropped through us.
        if (h = ReportEngine.session_host(k)) != "" && !ReportEngine.Sweep.connected(h)
            _drop_signed_out_wire!(nb, k, h; hold = false)
            continue
        end
        ok = false; err = nothing
        conn0 = k.conn
        try
            t1 = time_ns()
            r = ReportEngine._tool(k, "__slate_running", Dict{String,Any}(); timeout = _LIVENESS_PING_TIMEOUT)
            _note_clock!(k, r, t1, time_ns())   # the heartbeat is already a round trip; measure it
            run = r isa NamedTuple ? get(r, :running, nothing) :
                  r isa AbstractDict ? get(r, "running", get(r, :running, nothing)) : nothing
            if run !== nothing
                for id in run; push!(ids, String(id)); end
                push!(answered, _kernel_side_label(nb, k)); ok = true
            end
        catch e
            err = e
        end
        if ok && haskey(_KERNEL_BUSY_SINCE, k)
            delete!(_KERNEL_BUSY_SINCE, k)
            try; facts_changed!(); catch; end
        end
        if ok
            if haskey(_KERNEL_UNRESPONSIVE_SINCE, k)   # was unwell → recovered this sweep
                el = round(Int, time() - _KERNEL_UNRESPONSIVE_SINCE[k])
                delete!(_KERNEL_UNRESPONSIVE_SINCE, k) # any reply resets the clock — a blip is forgiven
                if pop!(_LIVENESS_LOG_LAST, k, nothing) !== nothing   # we said it went silent — say it came back
                    ReportEngine._rlog("liveness: $(nb.id)/$(_kernel_side_label(nb, k)) is answering again after $(el)s")
                end
                try; facts_changed!(); catch; end    # pill back to green immediately
            end
        elseif _telemetry_fresh(k)
            delete!(_KERNEL_UNRESPONSIVE_SINCE, k); delete!(_LIVENESS_LOG_LAST, k)
            if !haskey(_KERNEL_BUSY_SINCE, k)
                _KERNEL_BUSY_SINCE[k] = time() - _LIVENESS_PING_TIMEOUT
                ReportEngine._rlog("liveness: $(nb.id)/$(_kernel_side_label(nb, k)) missed a ping but its telemetry is arriving — busy, not gone")
                try; facts_changed!(); catch; end
            end
        elseif k.conn !== conn0
            # The connection was replaced while the ping was out (a worker running older code is being
            # swapped for a fresh one). Its old wire going quiet is the swap, not a silent worker.
            continue
        else
            # Stamp the first silent sweep — backdated by the ping timeout it already waited — for EVERY
            # kernel, LOCAL included. The clock used to be remote-only, which meant a local worker that
            # stopped answering showed a healthy green pill indefinitely while the log filled up: the one
            # state nobody could see was the one that mattered. The auto-DROP stays remote-only for a
            # worker that is merely SILENT — a local process is ours to inspect, and re-dialling a
            # wedged-but-alive worker reconnects to the same wedge — but a local process that has EXITED
            # is neither inspectable nor re-dialable, and holding its connection open only feeds an
            # unbounded wait to everything that reaches for it. `_kernel_proc_dead` separates the two;
            # silence alone can't, which is why a crashed local worker used to sit "silent for Ns" for
            # as long as the hub was up.
            since = get!(() -> time() - _LIVENESS_PING_TIMEOUT, _KERNEL_UNRESPONSIVE_SINCE, k)
            unresp = time() - since
            logged = _log_liveness_silence(nb, k, err, unresp)
            if (k.target isa ReportEngine.RemoteTarget || k.remote || _kernel_proc_dead(k)) &&
               unresp >= _dead_wire_grace(k) && !_prepare_holds(k)
                delete!(_KERNEL_UNRESPONSIVE_SINCE, k); delete!(_LIVENESS_LOG_LAST, k)
                _heal_dead_wire!(nb, k, unresp)        # → amber "disconnected" (pushes inside)
            elseif k.target isa ReportEngine.RemoteTarget || k.remote
                # Still CONNECTED but missing pings: surface it as a muted-yellow "degraded" pill NOW (an
                # early warning, well before the drop), and re-push each sweep so its unresponsive-countdown
                # ticks live in the pill/popup.
                try; facts_changed!(); catch; end
            elseif logged
                # Local: nothing counts down, so push only when the state actually changed rather than
                # re-sending the same pill every 8s for as long as the worker stays silent.
                try; facts_changed!(); catch; end
            end
        end
    end
    _LAST_RUNNING[nb.id] = (ids, answered, asked)
    return nothing
end

# Is this kernel's silence due to be logged? The first failure always is; after that, once per
# interval. Stamps the clock when it says yes, so callers must not ask twice for one sweep.
function _liveness_due_to_log!(k, now::Float64 = time())
    last = get(_LIVENESS_LOG_LAST, k, nothing)
    (last !== nothing && now - last < _LIVENESS_LOG_EVERY) && return false
    _LIVENESS_LOG_LAST[k] = now
    return true
end

# Log a kernel's silence at most once per `_LIVENESS_LOG_EVERY`. Returns whether it logged, which the
# sweep uses as its "the state changed" signal.
function _log_liveness_silence(nb::LiveNotebook, k, err, unresp::Real)
    _liveness_due_to_log!(k) || return false
    reason = err === nothing ? "no running-set in the reply" : first(sprint(showerror, err), 120)
    ReportEngine._rlog("liveness: __slate_running failed on $(nb.id)/$(_kernel_side_label(nb, k)) " *
                       "(silent for $(round(Int, unresp))s): " * reason)
    return true
end

# The cell ids the connected kernels said they are evaluating on the last liveness sweep, the sides
# (`_kernel_side_label`) whose kernel answered, and those that were asked; `nothing` if none answered.
# A cell is judged only by its own kernel: a busy region worker that misses a ping says nothing about
# its cells, whatever the main kernel answered, while a side with no connected kernel at all cannot
# be running anything. Reads the sweep's cache (populated just before the reconciler runs).
function _worker_running_ids(nb::LiveNotebook)
    cached = get(_LAST_RUNNING, nb.id, nothing)
    cached === nothing && return nothing
    ids, answered, asked = cached
    return isempty(answered) ? nothing : (; ids, answered, asked)
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
        # Named by the node it runs on, or by the login host it is reached through.
        (k.port == Int(port) && (k.target.ssh_host == host ||
            (v = ReportEngine.via(k.target.ssh_host); v !== nothing && v.host == host))) || continue
        try
            if ReportEngine._drop_kernel_conn!(k)
                n += 1
                ReportEngine._rlog("reap: dropped live wire on $(nb.id)/$(_kernel_side_label(nb, k)) (worker-$port on $host reaped)")
                try; facts_changed!(); catch; end   # pill flips to amber "reconnecting" immediately
            end
        catch; end
    end
    # Diagnostic when the fast-path misses: the liveness sweep still backstops it, but with the generous
    # dead-wire grace that's a slow path for an EXPLICIT reap — so surface the actual live endpoints to
    # show why the host/port didn't match (e.g. a base-port vs slot-port drift on a :direct region).
    n == 0 && ReportEngine._rlog("reap: no live kernel matched $host:$port (live remote kernels: $(isempty(seen) ? "none" : join(seen, ", "))) — liveness sweep will backstop")
    return n
end

# Restart ONE worker, named the way the roster names it: a host and a port. Reap answers "make it go
# away"; this answers the far commoner "make it work again" — a wedged process, a namespace someone
# polluted, a region worker on a node that has gone strange — without touching the other workers a
# notebook is using, which is what the whole-notebook restart would do.
#
# The main kernel and a region kernel need different handling and it is not cosmetic: restarting the
# main kernel re-runs the notebook from the top, while a region kernel owns only the cells tagged for
# it. Re-running everything to recover one region worker would discard results that were never in
# doubt, so a region restart re-arms exactly that region's cells and leaves the rest alone.
#
# A worker on a compute node answers to TWO host names and they must not be confused. The roster
# lists it under the LOGIN host — the manifests live on the cluster's shared filesystem, so that is
# where the probe reads them — while its kernel records the NODE, which is where the process
# actually is. Matching on the login name alone finds no kernel, and reaping by the login name kills
# nothing, because the process is not on that machine. So: match either name, and do the killing
# against the node when a kernel tells us there is one.
function restart_worker!(h, host::AbstractString, port::Integer)
    h === nothing && return (0, "no hub")
    hostname = String(host)
    # `host` may be the login node this worker is REACHED through rather than the one it runs on.
    _same_worker(k) = k.port == Int(port) &&
        (k.target.ssh_host == hostname ||
         (v = ReportEngine.via(k.target.ssh_host); v !== nothing && v.host == hostname))
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    hits = Tuple{LiveNotebook,String}[]
    node = hostname
    for nb in nbs, k in _nb_kernels(nb)
        k isa ReportEngine.GateKernel || continue
        k.target isa ReportEngine.RemoteTarget || continue
        _same_worker(k) || continue
        node = k.target.ssh_host                  # the machine the process is actually on
        push!(hits, (nb, _kernel_side_label(nb, k)))
    end
    try; _drop_kernels_for_worker!(h, node, port); catch; end
    ReportEngine.reap_remote_worker(node, Int(port))
    # Nothing was bound to it: the worker is gone and there is nothing to re-run. That is a complete
    # answer for an idle or abandoned worker, which is most of what a roster lists.
    isempty(hits) && return (0, "reaped worker-$port on $node (nothing was using it)")
    for (nb, side) in hits
        if side == "local"
            try; restart_kernel!(nb); catch; end
        else
            _forget_region_kernel!(nb, side)
            n = lock(nb.lock) do
                m = 0
                for c in nb.report.cells
                    _cell_region(c) == side || continue
                    ReportEngine.restale!(c) && (m += 1)
                end
                m > 0 && (nb.version += 1)
                m
            end
            n > 0 && (try; _broadcast(nb, string(nb.version)); catch; end)
            try; _ensure_runner!(nb); catch; end   # the re-armed cells run themselves from here
        end
    end
    return (length(hits), "restarted " * join(("$(nb.id)/$side" for (nb, side) in hits), ", "))
end

function _reconcile_nb_runs!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return nothing
    now = time()
    running = [c for c in nb.report.cells if c.state == RUNNING]
    ids = Set(c.id for c in running)
    for c in running; get!(_RUN_SINCE, (nb.id, c.id), now); end   # stamp first-seen-running
    for key in collect(keys(_RUN_SINCE))                          # drop records for cells no longer running
        (key[1] == nb.id && !(key[2] in ids)) &&
            (delete!(_RUN_SINCE, key); delete!(_RUN_ORPHAN_HITS, key); _region_prepared!(key...))
    end
    suspects = [c for c in running if now - get(_RUN_SINCE, (nb.id, c.id), now) > _RECONCILE_GRACE]
    isempty(suspects) && return nothing
    actual = _worker_running_ids(nb)
    actual === nothing && return nothing                         # no kernel could confirm → leave to the session layer
    for c in suspects
        key = (nb.id, c.id)
        if c.id in actual.ids                                    # genuinely running → clear any strike
            delete!(_RUN_ORPHAN_HITS, key); continue
        end
        # Its own kernel was asked and did not answer this sweep: nothing is known about it either way.
        side = _cell_side(nb, c); side = isempty(side) ? "local" : side
        (side in actual.asked && !(side in actual.answered)) && continue
        # A region cell is marked RUNNING before it reaches a worker: the spawn, the prime and the
        # input transfer come first, and until the dispatch nothing can report it as running — which
        # is indistinguishable from an orphan from here. `_prepare_region_for_cell!` says while that
        # is happening, so this is exact rather than a guess about how long a bring-up takes.
        _region_preparing(nb.id, c.id) && continue
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
    # A cold region is BRINGING UP a worker: nothing is running because the thing that would run it
    # does not exist yet, and installing a notebook's environment on the far side takes minutes —
    # comfortably past the wedge threshold. The provisioner narrates every step, so a recent line is
    # proof of progress. Without this the supervisor tore down a healthy run for taking as long as
    # the work honestly takes.
    isempty(ReportEngine.last_bringup_line()) ||
        (delete!(_RUNNER_STALE_HITS, nb.id); return nothing)
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

# Keep a queued cell moving when the thing that was watching for it has gone.
#
# `_place_in_background!` asks the cluster until the node lands and then re-runs the waiting cells —
# but only while it is still running. It gives up after `_alloc_wait_s()`, and a hub restart takes
# it with it. Past that point the job is still queued, nobody is asking, and nobody would re-run the
# cell even if they were: a queue wait longer than the watch window used to end with the cell parked
# on "queued" forever, which is every wait that mattered.
#
# Two different failures, so two branches: no placement means resume ASKING, a placement with cells
# still on it means re-ARM them.
#
# The sweep runs every 5 s, so what each branch COSTS decides what it may do.
#
# Deciding is free: it returns immediately unless a cell is BLOCKED, and `region_host` reads the
# cached placement rather than asking the scheduler. Keeping it free means reading `r.scheduler` and
# NOT `region_scheduler(r)` (which ssh's to the host for an `:auto` region), and never reaching for
# `region_place!` here (which queues a job).
#
# Re-arming is free too, and throttled only to stop it repeating: a cell that re-blocks for the same
# reason keeps its original `blocked_at`, so there is nothing on the cell to tell a first re-arm from
# a fifth, and a cell stuck for some OTHER reason would otherwise be re-armed on every sweep.
const _REARM_AT = Dict{Tuple{String,String},Float64}()
const _REARM_EVERY = 30.0

# Asking the cluster is the one that costs, and it is unavoidable: schedulers do not call back, so a
# granted job is discovered only by asking, and the task that submitted it stops asking after
# `_alloc_wait_s()`. Past that the job is still queued with nobody looking.
#
# Re-kicking the placement task resumes the asking, and is safe to repeat: `request_allocation!`
# resolves the job BY NAME and returns the existing one rather than submitting a second, and
# `_PLACING` makes a re-kick a no-op while one is already running. The throttle here bounds how often
# a NEW attempt may start; the cadence within an attempt is `_POLL_BACKOFF` (allocation.jl).
const _REPLACE_AT = Dict{Tuple{String,String},Float64}()
const _REPLACE_EVERY = 30.0

function _reconcile_blocked_regions!(nb::LiveNotebook)
    _rearm_after_prepare!(nb)
    # Only a QUEUE wait. A cell blocked because nobody has signed in to the cluster is waiting on a
    # person, and asking the scheduler about it every half minute answers a question nobody asked.
    names = Set{String}()
    lock(nb.lock) do
        for c in nb.report.cells
            (c.state == BLOCKED && c.blocked == WAIT_QUEUED) || continue
            isempty(c.blocked_region) || push!(names, c.blocked_region)
        end
    end
    for name in names
        r = ReportEngine.region_get(name)
        (r === nothing || r.scheduler === :none) && continue
        key = (nb.id, name)
        if !ReportEngine._region_holds_node(r)
            # Nothing placed. Resume asking the cluster — this is the only branch here that costs a
            # round trip, so it runs on a cadence sized for a shared login node, not for the sweep.
            time() - get(_REPLACE_AT, key, 0.0) < _REPLACE_EVERY && continue
            _REPLACE_AT[key] = time()
            _place_in_background!(name, nb)
            continue
        end
        time() - get(_REARM_AT, key, 0.0) < _REARM_EVERY && continue
        _REARM_AT[key] = time()
        n = _restale_region_cells!(nb, name)
        n > 0 || continue
        ReportEngine._rlog("region[$name]: node is held ($(ReportEngine.region_host(r))) but " *
                           "$n cell(s) were still waiting — re-armed by the supervisor")
        _ensure_runner!(nb)
    end
    return nothing
end

# Cells that waited while their region was prepared run once it is done. A prepare started for this
# notebook re-runs them itself; one started from the regions panel or by a tool does not know them.
function _rearm_after_prepare!(nb::LiveNotebook)
    for name in _prepared_regions_waiting(nb)
        _restale_region_cells!(nb, name) > 0 && _ensure_runner!(nb)
    end
    return nothing
end

# Regions with cells still waiting on a prepare that has ended: one that was running when they met
# it, or one they were told was needed and that has since succeeded.
function _prepared_regions_waiting(nb::LiveNotebook)
    done = Set{String}()
    lock(nb.lock) do
        for c in nb.report.cells
            c.state == BLOCKED || continue
            r = c.blocked_region
            (isempty(r) || ReportEngine.prepare_running(r)) && continue
            if c.blocked == WAIT_PREPARING
                push!(done, r)
            elseif c.blocked == WAIT_NEEDS_PREPARE
                _prepared_since(r, c.blocked_at) && push!(done, r)
            end
        end
    end
    return done
end

# Whether region `name` has a successful prepare recorded after time `t`.
function _prepared_since(name::AbstractString, t::Real)
    r = ReportEngine.region_get(name)
    r === nothing && return false
    rec = r.readiness
    return get(rec, "ok", false) === true && Float64(get(rec, "prepared_at", 0.0)) > t
end

# Give a node back when nothing is left on it. `_region_reconcile_impl!` releases a scheduler region
# that holds one with no live workers, and an allocation bills for the time it is HELD — but nothing
# ever called it, so a node outlived its work by whatever its walltime had left.
#
# Two regions must be skipped, and neither is visible from the registry alone: one whose placement is
# still in flight, and one a BLOCKED cell is waiting on. A node is granted BEFORE the worker that
# will use it exists, so releasing on "no workers yet" would take back the node a queued cell had
# just been given and send it round the queue again, indefinitely.
#
# Deciding is local — `_region_holds_node` reads the cached placement — but confirming costs an ssh
# round trip per held region, so this runs on its own minute-scale clock rather than the 5s sweep.
const _REGION_SWEEP_AT = Ref(0.0)
const _REGION_SWEEP_EVERY = 60.0
# The supervisor's own interval, so a deadline check can round UP to it. Sampling on a tick can only
# ever notice a deadline late; anticipating one tick means a warning lands a little early instead,
# and a minute's notice is worth more than a minute is worth being exact.
const _SUPERVISOR_TICK_S = 5.0

# When a region's cells last ran, and which regions have been warned their node is about to go.
# Idle is measured from the last region CELL, not from the worker: the hub polls every worker for
# telemetry, so by that measure nothing is ever idle.
const _REGION_LAST_USED = Dict{String,Float64}()
const _REGION_RELEASE_WARNED = Dict{String,Float64}()
const _REGION_USE_LOCK = ReentrantLock()

# Stamped when a region cell starts as well as when it finishes, so a cell running longer than the
# idle window does not have its own region released underneath it.
_region_used!(name::AbstractString) = isempty(name) ? nothing : lock(_REGION_USE_LOCK) do
    _REGION_LAST_USED[String(name)] = time()
    delete!(_REGION_RELEASE_WARNED, String(name))    # any use cancels a pending release
    nothing
end

# How long a region has gone unused. One never seen used starts its clock now, so a hub restart
# cannot release a node the moment it comes back.
function _region_idle_for(name::AbstractString; reg = nothing)
    hub = lock(_REGION_USE_LOCK) do
        get!(_REGION_LAST_USED, String(name), time())
    end
    # A node cannot have been idle longer than we have HELD it. Without this floor a region carries
    # its pre-grant wait into the new allocation — the queue wait, when nothing was held and nothing
    # could be idle — and one that queued longer than its own timeout is released on arrival. Covers
    # adoption too, where a reopened notebook attaches to a job without a grant happening here.
    try
        r = reg === nothing ? ReportEngine.region_get(String(name)) : reg
        if r !== nothing
            p = ReportEngine.region_placement(r)
            p === nothing || (hub = max(hub, p.ts))
        end
    catch
    end
    # The worker's own account of when it last had work, fused in. It sees evals the hub never
    # dispatched, so it can only ever move the clock FORWARD — and a silent worker (dead, or a
    # network blip) reports nothing, which must not read as "maximally idle" and release its node.
    return time() - max(hub, _worker_last_eval(String(name)))
end

# The newest `last_eval` any live kernel for this region has reported. 0 when none has.
function _worker_last_eval(name::AbstractString)
    best = 0.0
    try
        for (key, k) in (lock(_REGION_LOCK) do; collect(_REGION_KERNELS); end)
            key[2] == name || continue
            cn = (k isa ReportEngine.GateKernel && k.conn !== nothing) ? k.conn.name : ""
            isempty(cn) && continue
            st = ReportEngine.kernel_stats(cn)
            st === nothing && continue
            wm = try; Float64(st.latest.last_eval_mono); catch; -1.0; end
            wm < 0 && continue                        # worker predates the field — nothing to fuse
            hub_ns = ReportEngine.ClockTrack.to_hub_ns(cn, wm)
            hub_ns === nothing && continue            # unmeasured mapping — fall back to our own stamp
            # Monotonic ns on this machine → wall seconds on this machine.
            le = time() - (Float64(time_ns()) - hub_ns) / 1e9
            le > best && (best = le)
        end
    catch
    end
    return best
end

# Runs on the 5 s supervisor tick, not the minute clock: every decision below reads local state, so
# sampling is free, and a deadline is only ever as accurate as the interval that checks it — on a
# minute's cadence a one-minute warning could arrive with seconds left. What costs a round trip is
# the notice and the release, and each of those happens once per idle stretch.
# A reader that failed while its region was still waiting can stay failed. The re-arm that fires
# when the node lands may run BEFORE the reader has errored — the runner is still working down the
# notebook — and nothing looks again, so the cell sits red holding a value nobody recomputed.
#
# Once the region cell is FRESH, a downstream cell still ERRORED or BLOCKED is stale by definition.
# Re-armed ONCE per failure: a reader that fails again is failing for its own reasons, and retrying
# it every tick would be a loop rather than a repair.
const _READER_REARMED = Set{Tuple{String,String}}()

function _reconcile_stranded_readers!(nb::LiveNotebook)
    n = 0
    lock(nb.lock) do
        ready = String[c.id for c in nb.report.cells
                       if !isempty(_cell_region(c)) && c.state == FRESH]
        isempty(ready) && return
        blast = ReportEngine.dependents_of(nb.report, ready)
        for c in nb.report.cells
            (c.id in blast && !(c.id in ready)) || continue
            key = (nb.id, c.id)
            if c.state == FRESH || c.state == STALE || c.state == RUNNING
                delete!(_READER_REARMED, key)             # recovered — a later failure gets its own go
                continue
            end
            _region_recoverable(c) || continue
            key in _READER_REARMED && continue
            push!(_READER_REARMED, key)
            ReportEngine.restale!(c) && (n += 1)
        end
        n > 0 && (nb.version += 1)
    end
    n > 0 || return nothing
    try; _broadcast(nb, string(nb.version)); catch; end
    ReportEngine._rlog("supervisor: $n reader(s) were left failed while a region was waiting — re-armed")
    _ensure_runner!(nb)
    return nothing
end

# One measured exchange, from a `__slate_running` reply that carried the worker's monotonic bracket.
# Silently ignored for a worker too old to report them — the caller then has no mapping and says so,
# rather than inventing one.
function _note_clock!(k, r, t1::UInt64, t4::UInt64)
    cn = try; (k isa ReportEngine.GateKernel && k.conn !== nothing) ? String(k.conn.name) : ""; catch; ""; end
    isempty(cn) && return nothing
    g(sym) = r isa NamedTuple ? get(r, sym, nothing) :
             r isa AbstractDict ? get(r, String(sym), get(r, sym, nothing)) : nothing
    t2 = g(:mono_recv); t3 = g(:mono_send)
    (t2 === nothing || t3 === nothing) && return nothing
    try; ReportEngine.ClockTrack.note_exchange!(cn, Float64(t1), Float64(t2), Float64(t3), Float64(t4)); catch; end
    return nothing
end

# Converge the mapping AT CONNECT instead of waiting for the heartbeat to accumulate enough samples,
# which at one every few seconds is most of a minute. A short burst costs a handful of tiny round
# trips once, and the fastest of them is the one the fit leans on.
const _CLOCK_SEED_N = 8

function _seed_clock!(k)
    Threads.@spawn try
        for _ in 1:_CLOCK_SEED_N
            t1 = time_ns()
            r = ReportEngine._tool(k, "__slate_running", Dict{String,Any}(); timeout = 10.0)
            _note_clock!(k, r, t1, time_ns())
            sleep(0.05)          # spread them enough that a single stall cannot skew the whole burst
        end
        cn = try; k.conn === nothing ? "" : String(k.conn.name); catch; ""; end
        if !isempty(cn)
            q = ReportEngine.ClockTrack.clock_quality(cn)
            q.ok && ReportEngine._rlog("clock: $cn mapped — best rtt $(round(q.rtt_ns / 1e6; digits = 2))ms, " *
                                       "drift " * (q.drift_ppm === nothing ? "not yet fitted" :
                                                   "$(round(q.drift_ppm; digits = 1))ppm") *
                                       ", $(q.samples) samples")
        end
    catch e
        ReportEngine._rlog("clock: seeding the worker mapping failed — " * first(sprint(showerror, e), 120))
    end
    return nothing
end

# Per-connection state — a worker's clock mapping and its telemetry ring — is keyed by the gate
# connection name, and every respawn mints a new one. Both registries shipped with a `forget`
# function and no caller, so a hub that restarted a worker all afternoon kept a series for every
# worker it had ever had, none of them reachable.
#
# SWEPT rather than dropped at teardown. Six paths clear a kernel's connection, and the bug was a
# teardown function nobody called: adding a seventh call site invites the eighth path to forget
# again. Comparing against what is actually attached cannot be forgotten.
#
# A name is never reused, so a name no live kernel holds is dead. A wire that drops and comes back
# loses its history here, which is the same thing `forget_kernel_stats` was written to do: stale
# telemetry that outlives its worker is what misleads the watchdog.
function _sweep_stale_conn_state!(h)
    live = Set{String}()
    for snb in lock(h.lock) do; collect(values(h.notebooks)); end
        k = snb.kernel
        (k isa ReportEngine.GateKernel && k.conn !== nothing) && push!(live, String(k.conn.name))
    end
    for (_, k) in lock(_REGION_LOCK) do; collect(_REGION_KERNELS); end
        (k isa ReportEngine.GateKernel && k.conn !== nothing) && push!(live, String(k.conn.name))
    end
    union!(live, ReportEngine.held_conns())
    for name in ReportEngine.kernel_stats_conns()
        name in live || ReportEngine.forget_kernel_stats(name)
    end
    for name in ReportEngine.ClockTrack.tracked_conns()
        name in live || ReportEngine.ClockTrack.forget_clock!(name)
    end
    return nothing
end

function _sweep_idle_regions!(h)
    nbs_of, busy = _regions_in_use(h)
    _warn_expiring_regions!(nbs_of)
    _release_idle_regions!(nbs_of, busy)
    # Reaching the cluster to reconcile a region that holds a node with nothing on it is the one
    # thing here that is not free, so it keeps its own minute clock.
    if time() - _REGION_SWEEP_AT[] >= _REGION_SWEEP_EVERY
        _REGION_SWEEP_AT[] = time()
        _sweep_dead_regions!(busy)
    end
    return nothing
end

# The open notebooks using each region, and the regions whose node must not be given back now.
function _regions_in_use(h)
    busy = lock(_PLACING_LOCK) do; Set{String}(_PLACING); end
    nbs_of = Dict{String,Vector{LiveNotebook}}()      # region → the open notebooks using it
    for nb in lock(h.lock) do; collect(values(h.notebooks)); end
        lock(nb.lock) do
            for c in nb.report.cells
                r = _cell_region(c)
                isempty(r) && continue
                let v = get!(Vector{LiveNotebook}, nbs_of, r); nb in v || push!(v, nb); end
                # A cell that is RUNNING on the region means the region is in use whatever the clock
                # says.
                c.state == RUNNING && (push!(busy, r); _region_used!(r))
            end
            # So does a cell waiting for one, which may be a cell on another region, or on none,
            # reading a value this one produces.
            for c in nb.report.cells
                (c.state == BLOCKED && !isempty(c.blocked_region)) && push!(busy, c.blocked_region)
            end
        end
    end
    # A node is in use while a prepare installs onto it, which may have been started from the panel
    # with no notebook's cells involved, and in the minutes after its grant, before the cells that
    # waited for it reach the runner.
    for r in ReportEngine.regions()
        r.scheduler === :none && continue
        (ReportEngine.prepare_running(r.name) || _granted_within(r, _GRANT_GRACE_S)) && push!(busy, r.name)
    end
    return nbs_of, busy
end

# Remote work the supervisor starts for a region runs on a task of its own, one per region and kind at
# a time: a slow cluster then delays that region's next turn rather than the whole tick, which also
# runs every notebook's liveness check. Returns whether the work was started.
const _REGION_WORK = Set{Tuple{String,Symbol}}()
const _REGION_WORK_LOCK = ReentrantLock()
function _region_work!(f, name::AbstractString, kind::Symbol)
    key = (String(name), kind)
    lock(_REGION_WORK_LOCK) do
        key in _REGION_WORK ? false : (push!(_REGION_WORK, key); true)
    end || return false
    Threads.@spawn try
        f()
    catch e
        ReportEngine._rlog("supervisor: $kind for region '$name' failed: " * first(sprint(showerror, e), 160))
    finally
        lock(() -> delete!(_REGION_WORK, key), _REGION_WORK_LOCK)
    end
    return true
end

# How much warning a walltime gets. Unlike the idle timer this is not opt-in: the job ends whatever
# anyone configured, and the only thing worse than losing the node is losing it unannounced.
# Two notices per allocation: one with time to act, one with time to save. Not opt-in — the job ends
# whatever anyone configured. Ascending, so the tightest threshold that applies is the one that fires.
const _WALLTIME_WARN_AT = (60.0, 300.0)
const _WALLTIME_WARNED = Dict{Tuple{String,Float64},Float64}()   # (region, threshold) → deadline announced

# The allocation's own end, from the lease `region_place!` recorded off the scheduler. Reading it
# costs nothing, so every held node is checked on every tick.
function _warn_expiring_regions!(nbs_of)
    for r in ReportEngine.regions()
        r.scheduler === :none && continue
        p = ReportEngine.region_placement(r)
        p === nothing && continue
        left = p.until - time()
        left > 0 || continue
        for thr in _WALLTIME_WARN_AT
            left <= thr + _SUPERVISOR_TICK_S || continue
            key = (r.name, thr)
            prev = get(_WALLTIME_WARNED, key, 0.0)
            # The placement is re-read off the scheduler every `_PLACE_TTL`, and the deadline it
            # recomputes drifts by a second or two each time. Exact equality made every refresh look
            # like a new deadline and re-fired the notice; only a move larger than the smallest
            # extension anyone can ask for is a real one.
            (prev > 0 && p.until <= prev + 30) && break
            _WALLTIME_WARNED[key] = p.until
            nbs = get(nbs_of, r.name, LiveNotebook[])
            _region_work!(r.name, :notice) do
                _push_alloc_notice!(nbs, r, Dict{String,Any}("kind" => "walltime", "seconds_left" => round(Int, left)))
            end
            break
        end
    end
    return nothing
end

# The node is held, nothing has used it for `idle_release` minutes, and the region asked to have it
# taken back. Opt-in (0 = never) because getting one again costs a queue wait, and someone iterating
# on a cell between thinks is exactly who must not pay that by surprise.
#
# The region's `idle_warn` lead decides how long before the release the question goes out. Running
# any cell on the region cancels it (`_region_used!`). This is what separates an idle notebook from
# a person reading output between runs, which look identical from here.
function _release_idle_regions!(nbs_of, busy)
    for r in ReportEngine.regions()
        (r.scheduler === :none || r.idle_release <= 0 || r.name in busy) && continue
        ReportEngine._region_holds_node(r) || continue
        idle = _region_idle_for(r.name)
        nbs = get(nbs_of, r.name, LiveNotebook[])
        # Ask before the deadline, by the region's own lead, so the answer can still change the
        # outcome. Once per idle stretch; any cell on the region clears it.
        # Past the deadline there is nothing left to ask: the release below says what happened.
        if r.idle_warn > 0 && idle < r.idle_release && idle + _SUPERVISOR_TICK_S >= r.idle_release - r.idle_warn
            warned = lock(_REGION_USE_LOCK) do; get(_REGION_RELEASE_WARNED, r.name, 0.0); end
            if warned == 0.0
                lock(_REGION_USE_LOCK) do; _REGION_RELEASE_WARNED[r.name] = time(); end
                left = max(0, r.idle_release - idle)
                _region_work!(() -> _ask_still_there!(nbs, r, round(Int, left)), r.name, :notice)
            end
        end
        idle >= r.idle_release || continue
        _region_work!(r.name, :release) do
            ReportEngine._rlog("region[$(r.name)]: idle $(ReportEngine.Sweep.format_duration(idle)) past " *
                               "its $(ReportEngine.Sweep.format_duration(r.idle_release)) limit — " *
                               "releasing its node")
            try
                ReportEngine.region_release!(r)
                lock(_REGION_USE_LOCK) do; delete!(_REGION_RELEASE_WARNED, r.name); end
                # Nobody was here to see it — that is why it happened — so the notice is KEPT and pushed
                # again when a page next connects, rather than broadcast once into an empty room.
                _hold_released_notice!(nbs, r, "idle")
                _push_alloc_event!(nbs, r.name, "released"; reason = "idle")
                for nb in nbs; try; facts_changed!(); catch; end; end
            catch e
                ReportEngine._rlog("region[$(r.name)]: idle release failed — " *
                                   first(sprint(showerror, e), 120))
            end
        end
    end
    return nothing
end

# Ask whoever is there whether the region's node is still wanted.
#
# Pushed as fields: which region, on what node, how long is left, whether this site will let the
# allocation be lengthened. The page renders it, since the page knows which buttons it is offering.
#
# `extendable` comes from a real minimum-size extension (`extend_allocation!`), because no site
# advertises the permission. It costs one round trip, taken only when someone is about to be asked a
# question whose options depend on the answer.
# What just happened to a region's node, to whoever is looking. The popup is one consumer; the pills
# and the region panel are others, and none of them should have to be told separately.
function _push_alloc_event!(nbs, region::AbstractString, event::AbstractString; extra...)
    payload = merge(Dict{String,Any}("region" => String(region), "event" => String(event)),
                    Dict{String,Any}(String(k) => v for (k, v) in extra))
    for nb in nbs
        try; _broadcast(nb, "allocevent:" * JSON.json(payload)); catch; end
        try; facts_changed!(); catch; end
    end
    return nothing
end

# Whether a site lets a running allocation be lengthened, per (scheduler, login host). The only way to
# find out adds a minute to the job, and a longer job moves the deadline the walltime notices are keyed
# on, so the question is put once per site rather than on every notice.
const _EXTENDABLE = Dict{Tuple{Symbol,String},Any}()
const _EXTENDABLE_LOCK = ReentrantLock()

function _site_extendable!(r)
    key = (ReportEngine.region_scheduler(r), String(r.host))
    hit = lock(_EXTENDABLE_LOCK) do; get(_EXTENDABLE, key, nothing); end
    hit === nothing || return hit
    ext = try
        ReportEngine.Sweep.can_extend_allocation!(key[1], r.host, ReportEngine.region_alloc_name(r))
    catch e
        (; ok = false, reason = :unreachable, said = first(sprint(showerror, e), 200), added_s = 0)
    end
    # The probe really did lengthen the job, so the hub's lease moves with it, or the hub stops
    # trusting a node it still holds and asks for a second one.
    ext.ok === true && ReportEngine.region_extend_lease!(r, ext.added_s)
    # Only a definite answer describes the site. An unreachable host or a missing job says nothing.
    ext.reason in (:ok, :refused) && lock(_EXTENDABLE_LOCK) do; _EXTENDABLE[key] = ext; end
    return ext
end

function _push_alloc_notice!(nbs, r, extra::Dict{String,Any})
    # The popup offers the extend control only where the site allows one.
    ext = _site_extendable!(r)
    p = ReportEngine.region_placement(r)
    payload = merge(Dict{String,Any}("region" => r.name, "host" => r.host,
                                     "node" => ReportEngine.region_host(r),
                                     "walltime_left" => (p === nothing || !isfinite(p.until)) ? -1 :
                                                       max(0, round(Int, p.until - time())),
                                     "idle_release" => r.idle_release, "idle_warn" => r.idle_warn,
                                     "extendable" => ext.ok === true,
                                     "extend_reason" => String(ext.reason),
                                     "scheduler_said" => ext.said), extra)
    ReportEngine._rlog("region[$(r.name)]: $(payload["kind"]) notice — " *
                       "$(payload["seconds_left"])s left, extendable=$(ext.ok === true) ($(ext.reason))")
    for nb in nbs
        try; _broadcast(nb, "allocnotice:" * JSON.json(payload)); catch; end
    end
    return nothing
end

_ask_still_there!(nbs, r, left_s::Int) =
    _push_alloc_notice!(nbs, r, Dict{String,Any}("kind" => "idle", "seconds_left" => left_s))

# A node that went while nobody was looking. Held per notebook until a page acknowledges it: the
# release happens BECAUSE the notebook was idle, so pushing it once would announce it to no one.
const _RELEASED_NOTICE = Dict{String,Dict{String,Any}}()   # nb id → payload
const _RELEASED_LOCK = ReentrantLock()

function _hold_released_notice!(nbs, r, reason::AbstractString)
    payload = Dict{String,Any}("kind" => "released", "reason" => reason, "region" => r.name,
                               "host" => r.host, "node" => "", "seconds_left" => 0,
                               "idle_release" => r.idle_release, "idle_warn" => r.idle_warn,
                               "extendable" => false, "extend_reason" => "no_allocation",
                               "scheduler_said" => "")
    for nb in nbs
        lock(_RELEASED_LOCK) do; _RELEASED_NOTICE[nb.id] = payload; end
        try; _broadcast(nb, "allocnotice:" * JSON.json(payload)); catch; end
    end
    return nothing
end

"A release the notebook has not been told about yet, or `nothing`."
pending_released_notice(nbid) = lock(_RELEASED_LOCK) do; get(_RELEASED_NOTICE, String(nbid), nothing); end
clear_released_notice!(nbid) = (lock(_RELEASED_LOCK) do; delete!(_RELEASED_NOTICE, String(nbid)); end; nothing)

# How long a newly granted node is kept while nothing runs on it. The grant re-arms the cells that
# were waiting, and until the runner reaches one and starts preparing the worker, no cell marks the
# region busy: the waiting cell may be a local reader, and the region's own cells may still be fresh
# from an earlier node. Once a region cell is preparing it is RUNNING, which `busy` already covers.
const _GRANT_GRACE_S = 300.0

_granted_within(r, s) = (p = ReportEngine.region_placement(r); p !== nothing && time() - p.ts < s)

# A region holding a node with nothing left on it at all — no workers, idle timer or not.
function _sweep_dead_regions!(busy)
    for r in ReportEngine.regions()
        (r.scheduler === :none || r.name in busy) && continue
        ReportEngine._region_holds_node(r) || continue
        # Reconciling lists the workers on the node, which on a scheduler is a job step: a request to
        # the site's controller and a row in its accounting, every minute the node is held. A node
        # with one of our workers connected to it is in use, and its wire says so already.
        _region_serves_kernel(r) && continue
        _region_work!(() -> ReportEngine.region_reconcile!(r.name), r.name, :reconcile)
    end
    return nothing
end

# Whether a region kernel of this hub is connected to a worker on the region's current node.
function _region_serves_kernel(r)
    at = ReportEngine.region_where(r)
    return lock(_REGION_LOCK) do
        for ((_, side), k) in _REGION_KERNELS
            side == r.name || continue
            tgt = k.target
            (tgt isa ReportEngine.RemoteTarget && (tgt.ssh_host, tgt.job) == at && k.conn !== nothing) &&
                return true
        end
        return false
    end
end

function _supervise_runs!(h)   # NOTE: `Hub` is defined later (server_hub.jl, included at ~1510) — untyped so this loads
    try; ReportEngine.reap_pending_kills!()   # hub-wide, not per-notebook — see gate_kernel.jl
    catch e; ReportEngine._rlog("supervisor: pending-kill reap error: " * first(sprint(showerror, e), 120))
    end
    try; _sweep_idle_regions!(h)              # hub-wide too: a region is not a notebook's to release
    catch e; ReportEngine._rlog("supervisor: region sweep error: " * first(sprint(showerror, e), 120))
    end
    try; _sweep_stale_conn_state!(h)          # drop the series of workers that are gone
    catch e; ReportEngine._rlog("supervisor: conn-state sweep error: " * first(sprint(showerror, e), 120))
    end
    # Release the next wave of any started sweep, for every cluster this MACHINE knows — not just
    # the notebooks that happen to be open. A sweep's second wave used to wait on a sweep card
    # polling, so closing the tab left the rest of a grid unsubmitted until someone came back.
    try; ReportEngine.Sweep.advance_started!()
    catch e; ReportEngine._rlog("supervisor: sweep advance error: " * first(sprint(showerror, e), 120))
    end
    try                                       # a leak is only visible as a series, so write one
        line = SlateDiag.diag_log_line()
        line === nothing || ReportEngine._rlog(line)
    catch e; ReportEngine._rlog("supervisor: diag log error: " * first(sprint(showerror, e), 120))
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
        try; _reconcile_blocked_regions!(nb)
        catch e; ReportEngine._rlog("supervisor: blocked-region reconcile error on $(nb.id): " * first(sprint(showerror, e), 120))
        end
        try; _reconcile_stranded_readers!(nb)
        catch e; ReportEngine._rlog("supervisor: stranded-reader reconcile error on $(nb.id): " * first(sprint(showerror, e), 120))
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
# cells no worker is evaluating), the watchdog CLASSIFIES trouble on kernels that are still alive. It
# judges by capacity and behaviour, not by absolute size: memory against the limit that would actually
# stop the worker (its job's cgroup, else what the host has available), and CPU by whether anything is
# running. A cell that keeps a node busy for an hour is doing its job; a node busy with nothing
# running, or a cell running with nothing happening, is not. It only reports (into `_NB_HEALTH`, for
# the health panel); acting on an alert is the user's choice.
const _WD_MEM_WARN     = 0.15         # memory headroom below this share of the limit → warning
const _WD_MEM_CRIT     = 0.05         # ... below this → critical
const _WD_MEM_ETA_WARN = 300.0        # growth that runs out of memory within this many seconds → warning
const _WD_MEM_ETA_CRIT = 60.0         # ... within this → critical
const _WD_PSI_MEM      = 10.0         # % of the last 10 s spent waiting on memory → memory pressure
const _WD_IDLE_HOT     = 90.0         # cpu% that counts as busy...
const _WD_IDLE_SAMPLES = 15           # ...for this many samples (~30 s) with no cell running → busy-idle
const _WD_QUIET_S      = 300.0        # a code cell running this long with no cpu, gpu or I/O → no-activity
const _WD_GPU_MEM      = 0.95         # GPU memory this full → the next allocation is likely to fail
const _WD_STALE_TEL    = 20.0         # telemetry silent this long while a cell runs → unreachable
const _WD_TEL_FRESH    = 10.0         # a telemetry sample older than this isn't trusted as "current"
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

_gib(b::Real) = string(round(b / 2^30; digits = 1), " GiB")

# Memory in use and the limit it counts against, with which limit that is: the job's cgroup where the
# worker has one (on a cluster the allocation, not the node, is what ends it), else the host's total
# less what is available. `nothing` where the sample cannot say.
function _memory_state(s)
    job = _sample_part(s, :job); host = _sample_part(s, :host)
    mx, cur = get(job, "mem_max", -1), get(job, "mem_cur", -1)
    (mx isa Real && mx > 0 && cur isa Real && cur >= 0) && return (used = Float64(cur), limit = Float64(mx), of = "job")
    av = get(host, "mem_avail", -1)
    (av isa Real && av >= 0 && s.sys_mem_total > 0) &&
        return (used = Float64(s.sys_mem_total - av), limit = Float64(s.sys_mem_total), of = "host")
    return nothing
end

# The least-squares rate of change of `f` over samples `win`, per second; 0 when fewer than three
# samples have a value or they span under ten seconds.
function _rate(win, f)
    pts = [(s.rcv, f(s)) for s in win]
    filter!(p -> isfinite(p[2]), pts)
    length(pts) >= 3 || return 0.0
    t̄ = sum(first, pts) / length(pts); ȳ = sum(last, pts) / length(pts)
    stt = sum(p -> (p[1] - t̄)^2, pts)
    (last(pts)[1] - first(pts)[1] >= 10 && stt > 0) || return 0.0
    return sum(p -> (p[1] - t̄) * (p[2] - ȳ), pts) / stt
end

# Whether anything was happening in a sample: CPU, a GPU, or storage I/O.
function _active(s)
    s.cpu >= 3 && return true
    any(g -> g.util >= 3, _sample_gpus(s)) && return true
    p = _sample_part(s, :proc)
    return max(get(p, "io_read", 0), get(p, "io_write", 0)) >= 2^20
end

"""
    _kernel_alerts(side, hist; now = time(), quiet_cells = String[]) -> Vector

The watchdog's alerts for one kernel from its telemetry history (oldest first). `quiet_cells` are the
code cells that sample says are running, checked for no activity. Each alert is
`(; kind, sev, scope, target, since, detail)`, `sev` one of "crit", "warn", "info".
"""
function _kernel_alerts(side::AbstractString, hist; now::Real = time(), quiet_cells = String[])
    out = Any[]
    isempty(hist) && return out
    l = hist[end]
    al(kind, sev, since, detail; scope = "kernel", target = side) =
        push!(out, (kind = kind, sev = sev, scope = scope, target = String(target), since = since, detail = detail))
    stale = now - l.rcv
    if stale > _WD_STALE_TEL && !isempty(l.running)
        al("unreachable", "crit", l.rcv, "no telemetry for $(round(Int, stale))s while a cell runs")
        return out                       # a silent kernel's figures are stale too
    end
    win = hist[max(1, length(hist) - 29):end]     # the last minute or so
    # Memory: headroom against the limit that applies, and where its growth is heading.
    m = _memory_state(l)
    if m !== nothing && m.limit > 0
        free = (m.limit - m.used) / m.limit
        # Where growth is heading, fitted over the window rather than read off its two ends. Against a
        # job's limit the job's own total is the right figure. Against the host's, only this kernel's
        # growth is: the host total moves with every other program on the machine, and its swings
        # read as a deadline that comes and goes every few seconds.
        slope = m.of == "job" ? _rate(win, s -> (x = _memory_state(s); x === nothing ? NaN : x.used)) :
                                _rate(win, s -> s.rss > 0 ? Float64(s.rss) : NaN)
        eta = slope > 0 ? (m.limit - m.used) / slope : Inf
        what = "$(m.of == "job" ? "job" : "host") memory $(_gib(m.used)) of $(_gib(m.limit)) ($(round(Int, 100 * free))% free)"
        if free < _WD_MEM_CRIT || eta < _WD_MEM_ETA_CRIT
            al("memory-low", "crit", win[1].rcv, eta < _WD_MEM_ETA_WARN ? "$what, out in about $(round(Int, eta))s at this rate" : what)
        elseif free < _WD_MEM_WARN || (eta < _WD_MEM_ETA_WARN && free < 0.5)
            al("memory-low", "warn", win[1].rcv,
               eta < _WD_MEM_ETA_WARN ? "$what, out in about $(max(1, round(Int, eta / 60))) min at this rate" : what)
        end
    end
    host = _sample_part(l, :host)
    psi = get(host, "psi_mem", -1.0)
    psi isa Real && psi >= _WD_PSI_MEM &&
        al("memory-pressure", "warn", l.rcv, "waiting on memory $(round(psi; digits = 1))% of the last 10 s")
    sw0 = get(_sample_part(win[1], :host), "swap_used", -1); sw = get(host, "swap_used", -1)
    (sw isa Real && sw0 isa Real && sw0 >= 0 && sw - sw0 > 64 * 2^20) &&
        al("memory-pressure", "warn", win[1].rcv, "swapping: $(_gib(sw - sw0)) more swap in the last minute")
    # CPU busy with nothing running: work nobody asked for (a background task that will not stop).
    busy = hist[max(1, length(hist) - _WD_IDLE_SAMPLES + 1):end]
    (length(busy) >= _WD_IDLE_SAMPLES && all(s -> s.cpu >= _WD_IDLE_HOT && isempty(s.running), busy)) &&
        al("busy-idle", "warn", busy[1].rcv, "cpu ≥$(round(Int, _WD_IDLE_HOT))% for $(round(Int, l.rcv - busy[1].rcv))s with no cell running")
    # A code cell running with nothing happening: waiting on something that may never come.
    if !isempty(quiet_cells) && l.rcv - hist[1].rcv >= _WD_QUIET_S
        recent = [s for s in hist if l.rcv - s.rcv <= _WD_QUIET_S]
        if !any(_active, recent)
            for c in quiet_cells
                all(s -> c in s.running, recent) &&
                    al("no-activity", "info", recent[1].rcv, "running with no CPU, GPU or I/O for $(round(Int, (l.rcv - recent[1].rcv) / 60)) min";
                       scope = "cell", target = c)
            end
        end
    end
    if length(win) >= 10
        dgc = (win[end].gc_ms - win[1].gc_ms) / 1000; dwall = win[end].rcv - win[1].rcv
        (dwall > 0 && dgc / dwall > 0.5) &&
            al("gc-thrash", "warn", win[1].rcv, "garbage collection $(round(Int, 100 * dgc / dwall))% of the last $(round(Int, dwall))s")
    end
    for g in _sample_gpus(l)
        (g.mem_total > 0 && g.mem_used / g.mem_total >= _WD_GPU_MEM) &&
            al("gpu-memory", "warn", l.rcv, "gpu$(g.i) memory $(round(Int, 100 * g.mem_used / g.mem_total))% full ($(_gib(g.mem_used)) of $(_gib(g.mem_total)))")
        held = filter(!=("power cap"), hasproperty(g, :throttle) ? g.throttle : String[])
        isempty(held) || al("gpu-throttle", "info", l.rcv, "gpu$(g.i) clocks held down: $(join(held, ", "))")
    end
    return out
end

function _watchdog_scan!(nb::LiveNotebook)
    nb.kernel isa ReportEngine.GateKernel || return nothing   # in-process kernels have no worker to watch
    now = time()
    alerts = Any[]
    code = Set(c.id for c in nb.report.cells if c.state == RUNNING && c.kind == CODE)
    for (side, latest, hist) in _nb_kernel_stats(nb)
        append!(alerts, _kernel_alerts(side, hist; now, quiet_cells = [id for id in latest.running if id in code]))
    end
    status = any(a -> a.sev == "crit", alerts) ? "critical" :
             any(a -> a.sev == "warn", alerts) ? "warning" :
             isempty(alerts) ? "ok" : "info"
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
    (try; ReportEngine._src_sha() != _HUB_START_SHA[]; catch; false; end)

# ── Revise in the hub ────────────────────────────────────────────────────────────────────────────
#
# The extension boot script already does `using Revise`, so Revise loads and watches. What was
# missing is that nothing ever ASKED it to revise: the automatic trigger lives in the REPL backend,
# and a server process has no REPL — so every source edit meant a restart, and the health panel's
# "Revise applies function edits live" was aspirational.
#
# Same shape as Kaimon's TUI (tui/lifecycle.jl): a task waits on Revise's own `revision_event` and
# raises a flag (event-driven — no polling, nothing to pay for while idle), and the flag is applied
# at ONE well-defined point, the top of the request handler. Never from the watcher task itself: a
# revision landing in the middle of an eval is how you get a half-updated method table.
#
# What it does NOT do is make the restart hint obsolete. New routes are registered once when the
# router is built, `const`s don't change, and a struct redefinition (which Julia 1.12 does allow)
# leaves every ALREADY-CONSTRUCTED object on the old layout — the running `Hub` included. So the
# panel keeps saying what changed and when, and leaves the judgement to whoever is editing.
const _REVISE_MOD = Ref{Any}(nothing)
const _REVISE_PENDING = Threads.Atomic{Bool}(false)
const _REVISE_LAST = Ref(0.0)        # when a pass last applied changes
const _REVISE_ERR = Ref("")          # last failure text ("" when the last pass was clean)
const _REVISE_ERR_AT = Ref(0.0)

# A depot install is read-only and never edited in place, so watching it is pure overhead.
_hub_is_dev_checkout() = (p = pkgdir(@__MODULE__);
    p !== nothing && !occursin(joinpath("julia", "packages"), abspath(p)))

# Newest mtime across the hub's own sources — the same set `_src_sha` hashes, and the cheap half
# of it (a stat per file, no reads).
function _src_mtime()
    d = dirname(@__FILE__)
    try
        maximum((mtime(joinpath(d, f)) for f in readdir(d) if endswith(f, ".jl")); init = 0.0)
    catch
        0.0
    end
end

# Has Revise already caught up with what's on disk? True when a pass succeeded no earlier than the
# newest source file. That covers every change Revise CAN apply — function bodies — and says nothing
# about the ones it can't (new routes, `const`s, live objects of a redefined struct), which is why
# the panel still names them rather than declaring the hub up to date.
revise_covers_source() = _REVISE_MOD[] !== nothing && isempty(_REVISE_ERR[]) &&
    _REVISE_LAST[] > 0 && !_REVISE_PENDING[] && _REVISE_LAST[] >= _src_mtime()

revise_status() = Dict{String,Any}(
    "active" => _REVISE_MOD[] !== nothing,
    "last" => _REVISE_LAST[],
    "error" => _REVISE_ERR[],
    "errorAt" => _REVISE_ERR_AT[],
    "covers" => revise_covers_source())

"""Load Revise (if it's reachable) and start the file-change watcher. No-op for an app or a depot
install. Best-effort throughout: a hub that cannot revise must still serve."""
function _start_revise!()
    _REVISE_MOD[] === nothing || return nothing
    _hub_is_dev_checkout() || return nothing
    R = try
        Base.require(Base.PkgId(Base.UUID("295af30f-e4ad-537b-8983-00126c2a3abe"), "Revise"))
    catch
        return nothing    # not installed here — the restart hint carries on alone
    end
    try
        Base.invokelatest(R.watch_package, Base.PkgId(@__MODULE__))
    catch e
        @debug "Revise: watch_package failed" exception = e
    end
    _REVISE_MOD[] = R
    Threads.@spawn begin
        while true
            try
                wait(R.revision_event)
                reset(R.revision_event)
                _REVISE_PENDING[] = true
            catch e
                e isa InterruptException && break
                sleep(0.5)
            end
        end
    end
    return nothing
end

"""Apply any pending revision. Called before routing, so it lands between requests rather than
inside one. Costs an atomic read when nothing changed."""
function _apply_pending_revise!()
    _REVISE_PENDING[] || return nothing
    R = _REVISE_MOD[]; R === nothing && return nothing
    _REVISE_PENDING[] = false
    try
        Base.invokelatest(R.revise)
        _REVISE_LAST[] = time(); _REVISE_ERR[] = ""
        @info "Slate: Revise applied source changes"
    catch e
        _REVISE_ERR[] = first(sprint(showerror, e), 400); _REVISE_ERR_AT[] = time()
        @warn "Slate: Revise.revise() failed" exception = e
    end
    return nothing
end

function _health_json(nb::LiveNotebook)
    rec = nb_health(nb.id)
    stale = _hub_src_stale()
    rev = revise_status()
    rec === nothing && return Dict{String,Any}("status" => "ok", "alerts" => Any[],
                                               "src_stale" => stale, "revise" => rev)
    now = time()
    Dict{String,Any}("status" => rec.status, "ts" => rec.ts, "src_stale" => stale, "revise" => rev,
        "alerts" => Any[Dict{String,Any}("kind" => a.kind, "sev" => a.sev, "scope" => a.scope, "target" => a.target,
                                          "since" => a.since, "age" => round(Int, now - a.since),
                                          "detail" => a.detail) for a in rec.alerts])
end

# One shared 5 s sweeper for the whole hub (started once at serve). Timer catches its own errors so a
# transient failure can't kill the loop.
function _ensure_run_supervisor!(h)   # NOTE: `Hub` defined later (server_hub.jl) — untyped so this loads
    _RUN_SUPERVISOR[] === nothing || return nothing
    _RUN_SUPERVISOR[] = Timer(_SUPERVISOR_TICK_S; interval = _SUPERVISOR_TICK_S) do _
        try; _supervise_runs!(h); catch; end
    end
    # Its own timer, at the workers' sampling rate: a supervisor tick waits on each worker's liveness
    # reply, so on the tick it would see a silent worker only every so often.
    _HOST_SAMPLER[] = Timer(_HOST_SAMPLE_S; interval = _HOST_SAMPLE_S) do _
        try
            for nb in lock(h.lock) do; collect(values(h.notebooks)); end, k in _nb_kernels(nb)
                _host_sample!(k)
            end
        catch e
            ReportEngine._rlog("outside sample error: " * first(sprint(showerror, e), 120))
        end
    end
    return nothing
end

# Release the sweeper on hub shutdown. Its closure captures the hub, so leaving it running would keep
# supervising a torn-down one — and, because `_ensure_run_supervisor!` is a no-op while the ref is set,
# a hub restarted in the SAME process (the TUI's `[r]`) would come up with no supervisor at all.
function _stop_run_supervisor!()
    t = _RUN_SUPERVISOR[]
    _RUN_SUPERVISOR[] = nothing
    t === nothing || (try; close(t); catch; end)
    t = _HOST_SAMPLER[]
    _HOST_SAMPLER[] = nothing
    t === nothing || (try; close(t); catch; end)
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
            "for cell $(cell.id) [$(t.phases)]")
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
# Narrate a region bring-up. A cold region installs the notebook's whole environment on the far side
# and precompiles it — minutes during which a spinning cell is the only sign of life. The bring-up
# lines go out through `_bringup_broadcast`; the banner that renders them keys off `hydrating`, so set
# it for the duration. `remote` is the kind that says where the work is. Every region cell is
# dispatched through here, so only a bring-up still to happen is narrated: announcing one for a worker
# that is up holds the banner over cells already running on it. Returns the function that ends it.
#
# A browser refetches state only when the version it is sent moves, so setting and clearing the flag
# each bump it.
function _narrate_region_bringup!(nb::LiveNotebook, kernel, side::AbstractString, host::AbstractString)
    narrating = _region_bringup_pending(nb, kernel) && lock(nb.lock) do
        get(nb.report.meta, "hydrating", false) === true && return false
        nb.report.meta["hydrating"] = true
        nb.report.meta["hydratingKind"] = "remote"
        nb.report.meta["hydratingSide"] = String(side)   # whose worker panel narrates it
        nb.version += 1
        true
    end
    narrating || return () -> nothing
    try
        _broadcast(nb, string(nb.version))
        _broadcast(nb, "bringup:starting a worker for region '$side' on $host")
    catch
    end
    return () -> lock(nb.lock) do
        delete!(nb.report.meta, "hydrating"); delete!(nb.report.meta, "hydratingKind")
        delete!(nb.report.meta, "hydratingSide")
        nb.version += 1
        try; _broadcast(nb, string(nb.version)); catch; end
        nothing
    end
end

# Whether the allocation this hub has placed region `side` on is gone, asked of the scheduler. A
# worker that cannot start on a scheduler region is most often a node the cluster took back (a
# cancelled job, a walltime that ran out), and the placement goes on naming it until something asks:
# every run would be sent to the same dead node. When it is gone the placement is forgotten, so the
# next one requests a node. An unreachable scheduler answers nothing and changes nothing. A `kernel`
# built in an allocation the region no longer names is gone without asking anyone: the placement has
# already moved on, and the next run builds its kernel from the new one.
function _allocation_gone!(side::AbstractString, kernel = nothing)
    r = ReportEngine.region_get(String(side))
    (r === nothing || r.scheduler === :none) && return false
    at = ReportEngine.region_where(r)
    tgt = kernel isa ReportEngine.GateKernel ? kernel.target : nothing
    (tgt isa ReportEngine.RemoteTarget && !isempty(tgt.job) && (tgt.ssh_host, tgt.job) != at) && return true
    job = last(at)
    isempty(job) && return false
    a = ReportEngine.region_allocation(r)
    (a === nothing || a.state === :unreachable) && return false
    (a.state === :running && a.id == job) && return false
    ReportEngine.region_forget_placement!(r)
    ReportEngine._rlog("region[$(r.name)]: job $job is no longer held — dropped its placement")
    return true
end

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
        # Held for two different reasons (see `_drop_signed_out_wire!`): a worker that went silent, or
        # a session that was signed out from under a perfectly healthy one. Only the first is the
        # worker's fault, and only the second is fixed with the padlock.
        sh = ReportEngine.session_host(kernel)
        lock(nb.lock) do
            ReportEngine.mark_errored!(cell,
                (!isempty(sh) && !ReportEngine.Sweep.connected(sh)) ?
                    "region '$side' needs $sh, which is signed out — use the padlock at the top of the page" :
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
    # From here the cell is RUNNING but is NOT yet on a worker: the spawn, the namespace prime and
    # its input transfer all still have to happen, and only then is it dispatched. Nothing can report
    # it as running during that window, which is exactly what the orphan reconciler looks for — so
    # say that it is being prepared and let it skip this cell. Cleared at the dispatch itself.
    lock(_REGION_PREPARING_LOCK) do; push!(_REGION_PREPARING, (nb.id, cell.id)); end
    lock(nb.lock) do
        ReportEngine.mark_running!(cell)
        _broadcast_progress(nb, cell)
    end
    try; facts_changed!(); catch; end   # pill appears NOW as "starting", not after the run completes
    stop_narrating = _narrate_region_bringup!(nb, kernel, side, host)
    # Every region cell passes through here, so what belongs to a worker COMING UP (seeding its clock,
    # giving held locked cells their restore) happens only when this call brought it up. A held cell
    # re-armed on every pass would run, be held, and be re-armed again without end.
    came_up = kernel isa ReportEngine.GateKernel && kernel.conn === nothing
    try
        came_up && _refresh_nb_fork!(nb)       # the region's copy of the env is made from the fork
        ReportEngine.prepare!(kernel, nb.report; explicit = forced)
        came_up && _seed_clock!(kernel)   # converge the clock mapping now, not over the next minute
        _prime_namespace!(nb, kernel, side)
        stop_narrating()
        try; facts_changed!(); catch; end   # connected → pill flips out of "starting"; telemetry takes over
        came_up && _rearm_locked!(nb, side, kernel)
        return true
    catch e
        stop_narrating()
        ReportEngine._rlog("region: prime before $(cell.id) on $host failed: " *
                           first(sprint(showerror, e), 160))
        # The node went with its allocation: the cell waits for a new one instead of failing, and is
        # re-run when it is granted. An allocation released on request during this start leaves the
        # cell waiting for a run instead, like every other cell of the withdrawn request.
        if !isempty(side) && _allocation_gone!(side, kernel)
            r = ReportEngine.region_get(String(side))
            withdrawn = _withdrawn_since_asked(nb, side)
            lock(nb.lock) do
                ReportEngine.mark_blocked!(cell, withdrawn ? WAIT_NOT_REQUESTED : WAIT_QUEUED, r.host, r.name)
                _broadcast_progress(nb, cell)
            end
            withdrawn || _place_in_background!(String(side), nb; by_run = true)
            try; facts_changed!(); catch; end
            return false
        end
        # The region worker couldn't come up — surface it AS the cell's error and STOP. Running on the
        # dead kernel just errors anyway, but leaving the cell unresolved let the runner re-arm and churn.
        lock(nb.lock) do
            ReportEngine.mark_errored!(cell, "region worker on $host could not start: " *
                first(sprint(showerror, e), 160))
            _broadcast_progress(nb, cell)
        end
        try; facts_changed!(); catch; end   # push the failure → pill goes amber/disconnected, not stuck "starting"
        return false
    end
end

# A locked cell computes only on its own ▶, the one-shot force marker. Every other run of it (opening
# the notebook, an upstream change, a run of the notebook, a restart) may only restore its frozen result.
_restore_only(nb::LiveNotebook, cell::Cell) = :locked in cell.flags && !lock(nb.lock) do
    ids = get(_FORCE_RUN, nb.id, nothing); ids !== nothing && cell.id in ids
end

# Whether the worker for `side` is up: the main kernel always counts, a region only once its kernel
# has a wire.
function _side_up(nb::LiveNotebook, side::AbstractString)
    isempty(side) && return true
    k = lock(_REGION_LOCK) do; get(_REGION_KERNELS, (nb.id, String(side)), nothing); end
    return k isa ReportEngine.GateKernel && k.conn !== nothing
end

# Hold a locked cell that had nothing to restore. It keeps whatever it showed, cells reading it wait
# on it, and its own ▶ computes it.
function _hold_locked!(nb::LiveNotebook, cell::Cell)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, cell.id)
        i === nothing && return
        c = nb.report.cells[i]
        pop!(get!(Set{String}, _DIRTY_WHILE_RUNNING, nb.id), c.id, nothing)
        ReportEngine.mark_blocked!(c, WAIT_LOCKED, c.id)
        _broadcast_progress(nb, c)
    end
    return nothing
end

# A region worker just came up: locked cells held because it was not, and the cells waiting on them,
# try their restore again. Once per worker connection, whoever calls it.
const _REARMED = Dict{Tuple{String,String},String}()   # (nb id, side) → the connection last re-armed for
const _REARMED_LOCK = ReentrantLock()

function _rearm_locked!(nb::LiveNotebook, side::AbstractString, kernel)
    cn = try; kernel.conn === nothing ? "" : String(kernel.conn.name); catch; ""; end
    isempty(cn) && return 0
    lock(_REARMED_LOCK) do
        get(_REARMED, (nb.id, String(side)), "") == cn ? true : (_REARMED[(nb.id, String(side))] = cn; false)
    end && return 0
    n = lock(nb.lock) do
        held = Set{String}(c.id for c in nb.report.cells
                           if c.state == BLOCKED && c.blocked == WAIT_LOCKED && _cell_region(c) == side)
        isempty(held) && return 0
        m = 0
        for c in nb.report.cells
            (c.state == BLOCKED && c.blocked == WAIT_LOCKED && c.blocked_host in held) || continue
            ReportEngine.restale!(c) && (m += 1)
        end
        m > 0 && (nb.version += 1)
        m
    end
    n > 0 && (try; _broadcast(nb, string(nb.version)); _ensure_runner!(nb); catch; end)
    return n
end

# A ▶ force marker is for one run of the cell. A cell left waiting keeps it, so the run it waits for
# is forced as asked; every other way out of the run, an error before the cell reached its kernel
# included, uses it up.
function _eval_one!(nb::LiveNotebook, cell::Cell)
    try
        _eval_one_run!(nb, cell)
    finally
        lock(nb.lock) do; cell.state == BLOCKED || _take_force!(nb.id, cell.id); end
    end
end

function _eval_one_run!(nb::LiveNotebook, cell::Cell)
    # A cell whose input is waiting waits too, for the same thing. Run now it could only fail on a
    # name its upstream has not produced. Whatever re-runs the upstream re-runs this cell with it:
    # a granted node re-arms the region's dependents, and a run of the notebook takes up every wait.
    # Checked and marked under one hold of the lock, so a grant re-arming the region's cells cannot
    # land between the two and leave this cell marked after its re-arm.
    waits, passed_on = lock(nb.lock) do
        u = nothing
        for d in cell.deps
            j = _index_of(nb.report.cells, d)
            (j !== nothing && nb.report.cells[j].state == BLOCKED) && (u = nb.report.cells[j]; break)
        end
        u === nothing && return (false, false)
        ReportEngine.mark_blocked!(cell, u.blocked, u.blocked_host, u.blocked_region)
        _broadcast_progress(nb, cell)
        # A ▶ on this cell asks for what it waits on. A node nobody has asked for yet, or a prepare
        # nobody has been offered, comes from running the cell that needs it, so the force passes there.
        forced = _take_force!(nb.id, cell.id)
        (forced && u.blocked in (WAIT_NOT_REQUESTED, WAIT_NEEDS_PREPARE) && ReportEngine.restale!(u)) ||
            return (true, false)
        push!(get!(Set{String}, _FORCE_RUN, nb.id), u.id)
        nb.version += 1
        (true, true)
    end
    passed_on && _ensure_runner!(nb)
    waits && return nothing
    # A locked cell computes only on its own ▶. Any other run restores the result it froze on, and only
    # where its worker is already up: it does not start one, since a region worker can mean a queue wait.
    cell.kind == CODE && _restore_only(nb, cell) && !_side_up(nb, _cell_region(cell)) &&
        return _hold_locked!(nb, cell)
    # Region dispatch: the `region=` tag decides the kernel; a mutation auto-follows its data (see
    # _region_route). Markdown honors its tag too — its `$(…)` interpolation runs on that region's worker.
    #
    # Having nowhere to run is THIS CELL's error, not the pass's. Raised, it aborts the drain before
    # the cell is even marked: the cell (and everything downstream) is left STALE with the reason
    # nowhere a reader can see it, the runner re-arms until it gives up, and anything waiting on the
    # drain — the open-time banner — waits for a run that never finishes. A region on a cluster
    # nobody has signed in to is the ordinary way to reach this, and it reads as one red cell.
    kernel, side = try
        _region_route(nb, cell)
    catch e
        msg = first(sprint(showerror, e), 300)
        # A WAIT is not a failure. The cell keeps whatever it last produced, says why in its header,
        # and is re-run by the thing it is waiting for (`_restale_region_cells!`) — so it must not be
        # left looking like broken code, and must not be retried in a loop by the runner.
        wait = e isa RegionWaiting
        ReportEngine._rlog("region: " * (wait ? "holding " : "cannot route ") * cell.id * ": " * msg)
        lock(nb.lock) do
            wait ? ReportEngine.mark_blocked!(cell, e.why, e.host, e.region) :
                   ReportEngine.mark_errored!(cell, msg)
            _broadcast_progress(nb, cell)
        end
        # The region's pill says what it is waiting for too (queued, prepare needed, preparing).
        wait && (try; facts_changed!(); catch; end)
        return nothing
    end
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
        e
    end
    if presync_err !== nothing
        # A wait arrives here too, and by the same route: reading a value that lives on a region
        # needs that region's kernel, so a node that has not been granted raises `RegionWaiting`
        # from the transfer rather than from the run. Reported as a failure it puts the spurious
        # red back on the DOWNSTREAM cell, which is the symptom BLOCKED exists to remove.
        wait = presync_err isa RegionWaiting
        wait && ReportEngine._rlog("region: holding " * cell.id * " (input transfer): " *
                                   sprint(showerror, presync_err))
        lock(nb.lock) do
            wait ? ReportEngine.mark_blocked!(cell, presync_err.why, presync_err.host, presync_err.region) :
                   ReportEngine.mark_errored!(cell, "region boundary transfer failed: " *
                                                    sprint(showerror, presync_err))
            _broadcast_progress(nb, cell)
        end
        return nothing
    end
    # Everything a region cell had to wait for is done; from here it is on a worker like any other,
    # and the orphan reconciler should judge it normally again.
    _region_prepared!(nb.id, cell.id)
    let rg = _cell_region(cell)
        if !isempty(rg)
            _region_used!(rg)              # the idle clock runs from region CELLS, not worker traffic
            try; facts_changed!(); catch; end   # …and the panel is showing that clock
        end
    end
    src, srchash, memo, locked = lock(nb.lock) do
        ReportEngine.mark_running!(cell)
        _broadcast_progress(nb, cell)
        s = (:trace in cell.flags) ? string("@trace begin ", cell.source, "\nend") : cell.source
        frc = _take_force!(nb.id, cell.id)   # consume a one-shot ▶ force marker
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
             restore_only = locked && !frc,               # a locked cell computes only on its own ▶
             unread = unread, safe = safe)
        (s, cell.src_hash, m, locked)
    end
    # Nothing to restore from: a locked cell with no key is held without asking the worker.
    (memo.restore_only && isempty(memo.key)) && return _hold_locked!(nb, cell)
    armed = _arm_requested_profile!(nb, cell, kernel, side)   # server_profile.jl: a profile asked of this run
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
    profiled = armed === nothing ? "" : _collect_requested_profile!(nb, cell, kernel, side, armed)
    # Namespace parity: a pure `using`/`import` cell runs on EVERY active side when a region is
    # in play — region cells need the same modules loaded. Mirrors run on main + each region any
    # cell references, except the side that just ran. Results discarded (the main run's output
    # stands); a failure logs rather than erroring the cell (that side surfaces it on first use).
    out.memo == "absent" && return _hold_locked!(nb, cell)   # restore-only, and nothing was stored
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
        # …and the same for VALUES: a reactive push restaled this cell while it was running, so the
        # result in hand was computed from inputs that have since changed. KEEP it (a stale answer
        # still beats a blank cell while the re-run lands) but leave the cell STALE afterwards so the
        # runner comes back to it — the state is what decides whether anything ever recomputes.
        _dirty = pop!(get!(Set{String}, _DIRTY_WHILE_RUNNING, nb.id), c.id, nothing) !== nothing
        ReportEngine.mark_result!(c, out)
        _dirty && ReportEngine.restale!(c)
        c.binds = out.binds
        _apply_cell_effects!(nb, c, out)                 # code→Slate declarations (e.g. :everywhere classification)
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        _run_log!(nb, isempty(side) ? "local" : side, c; profile = profiled)   # the side as `_kernel_side_label` names it
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
_emit_pending(nb::LiveNotebook, pending::Integer; fresh::Bool = false) =
    ReportEngine._emit_run_batch(nb.report.id, pending, fresh)

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

# Consume cell `cid`'s force marker, if it has one (call with nb.lock held).
function _take_force!(nbid::AbstractString, cid::AbstractString)
    ids = get(_FORCE_RUN, nbid, nothing)
    (ids !== nothing && cid in ids) || return false
    delete!(ids, cid)
    isempty(ids) && delete!(_FORCE_RUN, nbid)
    return true
end

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

# The cells a parallel drain will evaluate, in document order — EVERY one of them, which is what
# makes the batch safe to schedule from. `par_blockers` derives ordering from the batch alone: a dep
# on a cell outside it is silently dropped, and the read/write backstop can only see writers that are
# present. Selecting just the CODE kind therefore ran cells BEFORE the WEB or JOB cell they read —
# a plot downstream of a sweep raised `UndefVarError` on every cold open, then worked when re-run by
# hand, because by then its producer had run in the serial pass.
#
# MARKDOWN is excluded because the serial path renders it (static prose first, interpolating prose
# after its deps); TOOL because it never runs automatically, so deferring its readers would strand
# them rather than order them.
_batch_cells(cells) = [c for c in cells if c.state == STALE && c.kind !== MARKDOWN &&
                       ReportEngine.runs_automatically(c.kind)]

# Build the parallel-batch scheduler specs for the cells about to run (document order). Plotting cells share
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
        runnable = _batch_cells(nb.report.cells)
        length(runnable) < 2 && return (nothing, 0)
        ss = _batch_specs(runnable)
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

# Where a recorded call belongs.
#
# Appending every one at the tail turns a working session into a growing pile of unrelated calls at
# the bottom of the document, each of them far from the cell it actually relates to. A recorded call
# goes after the last cell that already concerns the SAME tool — the hand-written `@tool` cell it
# echoes, or the previous recording of it — so repeated calls stack in call order, in the part of
# the notebook the reader is already looking at. A tool the document has not mentioned yet has no
# such place, and the tail is the only honest answer for it.
#
# Only code and tool cells count: prose that happens to NAME a tool is not a call site.
function _toolcall_slot(cells, name::AbstractString)
    needles = ("@tool " * name * "(", "slate_tool(\"" * name * "\"")
    slot = length(cells) + 1
    for (i, c) in enumerate(cells)
        (c.kind === ReportEngine.CODE || c.kind === ReportEngine.TOOL) || continue
        any(n -> occursin(n, c.source), needles) && (slot = i + 1)
    end
    return slot
end

# Record one agent tool call as a TOOL cell.
#
# The cell lands STALE and is NOT run: the call already happened, and running it would fire the
# tool a second time, which for a tool that starts work is a second job. What it carries instead is
# the outcome of the call that DID happen, written straight into the cell's output, plus the
# `@tool` source so the reader can re-fire it deliberately from the panel's Invoke button.
function server_toolcall(nb::LiveNotebook, p)
    name = String(get(p, :name, ""))
    isempty(name) && return nothing
    args = get(p, :args, Pair{String,Any}[])
    src = ReportEngine.toolcall_source(name, args)
    ok = get(p, :ok, true) === true
    text = String(get(p, :text, ""))
    secs = Float64(get(p, :seconds, 0.0))
    at = String(get(p, :at, ""))
    head = ok ? "called by an agent" : "called by an agent, failed"
    # The worker renders the panel (it has the tool registry and the notebook's call-back handlers);
    # the hub only attributes it. Without a panel — no gate, a worker that could not build one — the
    # reply text is shown as it came, which is all the hub can say about it.
    panel = String(get(p, :html, ""))
    body = isempty(panel) ?
        "<pre style=\"margin:0;padding:8px 12px;white-space:pre-wrap;" *
        "font-family:ui-monospace,monospace\">$(ReportEngine._h(text))</pre>" : panel
    html = "<div style=\"border-left:2px solid color-mix(in srgb, var(--accent) 55%, transparent);" *
        "padding-left:8px;font-size:13px\">" *
        "<div style=\"padding:2px 0 4px;color:var(--muted);font-size:11px\">$(head)</div>" *
        body * "</div>"
    out = ReportEngine.CellOutput("", ReportEngine.MimeChunk[
                ReportEngine.MimeChunk("text/html", Vector{UInt8}(html))],
            Any[], Any[], ReportEngine.BindSpec[], "", nothing, nothing, secs * 1000)
    lock(nb.lock) do
        cells = nb.report.cells
        cid = _gen_id(nb.report)
        cell = ReportEngine.Cell(cid, ReportEngine.TOOL, src)
        cell.output = out
        ReportEngine.mark_fresh!(cell)
        insert!(cells, _toolcall_slot(cells, name), cell)
        _commit_reorder!(nb)
    end
    _persist!(nb)
    try; _broadcast(nb, "reload"); catch; end
    return nothing
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
        # Restaled by a reactive push mid-batch → keep the result, but stay STALE so it runs again
        # (see `_DIRTY_WHILE_RUNNING`; the same hazard as the src_hash check above, for values).
        _dirty = pop!(get!(Set{String}, _DIRTY_WHILE_RUNNING, nb.id), c.id, nothing) !== nothing
        ReportEngine.mark_result!(c, out)
        _dirty && ReportEngine.restale!(c)
        # A live re-render (`run_id == "reconnect"`) delivers only the fresh fragment for a browser
        # that just connected. Its wire carries no binds, because it is not a cell evaluation
        # result — so assigning them here DELETES the controls of any cell that both declares
        # `@bind`s and returns a session-bound output. That is exactly the shape of a figure drawn
        # with its own controls: they stayed declared in Julia but vanished from the page the
        # moment a browser connected, so nothing on the client could drive them.
        run_id == "reconnect" || (c.binds = out.binds)
        _apply_cell_effects!(nb, c, out)                 # code→Slate declarations (e.g. :everywhere classification)
        _stats_record!(nb, c)                            # before the broadcast — the push carries fresh stats
        run_id == "reconnect" || _run_log!(nb, "local", c)   # a parallel batch runs on the main kernel
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
    # NOT NOTIFIED HERE — deliberately. This fires on any `_worker_key` change, which lumps together two
    # cases that need OPPOSITE handling from an extension holding browser-side state:
    #   • a namespace REBUILD keeps the same worker PROCESS, so a live renderer's Bonito root (a process
    #     global) survives. The page must KEEP its sessions; telling it to drop them makes Julia and the
    #     page disagree, and the next figure attaches to a root the page just threw away — silent stall.
    #     `_rewire_page_root!` (re-registering the namespace handler) is the correct response, and it is
    #     what the extension already does from `enable!`.
    #   • a worker PROCESS replacement genuinely orphans everything the page holds — but then a partial
    #     teardown cannot work either, because the page's WGLMakie scene-order executor survives and its
    #     numbering can no longer be matched from Julia (see BonitoSlate connection.jl). A page reload is
    #     the only coherent response.
    # So a useful notification has to distinguish PROCESS replacement from namespace rebuild, and the
    # process case wants "reload", not "clean up". `SlateExtensionsBase.on_worker_reset` /
    # `slateOnWorkerReset` (panels.js, generation-gated) are in place for it; the trigger is not wired.
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
        # A blank namespace ⇒ every global is gone: re-run/restore all. EVERY kind that runs, not
        # just CODE — a WEB cell defines bindings too, and a JOB cell registers the channel its
        # card's buttons call. Leaving a job cell `fresh` across a worker restart left a card on
        # screen whose Submit reached a handler that no longer existed.
        for c in nb.report.cells
            (c.kind !== ReportEngine.MARKDOWN && ReportEngine.runs_automatically(c.kind)) &&
                ReportEngine.restale!(c)
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
        # Each module is loaded where the cells that use it run: a region's on its worker once that is up,
        # and never on this machine for cells that do not run here.
        bys = lock(nb.lock) do; ReportEngine.unresolved_using_paths_by_side(nb.report, c -> _cell_side(nb, c)); end
        resolved = false
        for (side, paths) in bys
            isempty(paths) && continue
            k = isempty(side) ? nb.kernel : _region_kernel_if_active(nb, side)
            k === nothing && continue
            ReportEngine.resolve_usings!(nb.report, k, paths) && (resolved = true)
        end
        resolved && lock(nb.lock) do; ReportEngine.rebuild_precise!(nb.report); end
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
    nb.closed && return nothing
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
function _eval!(nb::LiveNotebook; wait_for::AbstractString = "", wait_all::Bool = false,
                fresh::Bool = true)
    # Refresh the pill's pending count NOW (e.g. a cell queued while a long cell is mid-run, before
    # the runner reaches its next iteration), so the k/N updates immediately rather than at 1/1.
    #
    # `fresh` defaults TRUE because almost every caller is a user asking for work — a run request, an
    # edit, an agent's add/edit, a restart. The exception is a reactive cascade, which continues the
    # run in progress and says so; making that the explicit case rather than the default means a new
    # call site is counted as a run rather than silently folded into the previous one.
    fresh && _run_asked!(nb)
    p = lock(nb.lock) do; count(c -> c.state in (STALE, RUNNING), nb.report.cells); end
    p > 0 && _emit_pending(nb, p; fresh = fresh)
    _ensure_runner!(nb)
    (isempty(wait_for) && !wait_all) && return nb
    t0 = time()
    last_note = t0
    while true
        nb.closed && return nb                 # nothing will settle its cells now
        done = lock(nb.lock) do
            if !isempty(wait_for)
                i = _index_of(nb.report.cells, wait_for)
                # BLOCKED counts as settled: the cell is not going to progress on its own, and the
                # thing it waits for re-runs it later. Without it, a caller waiting on a cell queued
                # for a cluster node spins until its own timeout.
                return i === nothing || nb.report.cells[i].state in (FRESH, ERRORED, BLOCKED)
            end
            return _next_stale_cell(nb.report) === nothing
        end
        if done
            wait_all || return nb
            # wait_all also waits for the runner task itself to clear (so callers can persist after).
            lock(_RUNNER_LOCK) do; get(_RUNNERS, nb.id, false); end || return nb
        end
        # Liveness for a BLOCKED agent caller. This loop runs on the caller's own task, so the
        # gate request id that `progress` keys off is already bound here — no re-seeding needed
        # (unlike a callback firing on the stream-poller task). Emitting from here also means a
        # SILENT cell still reports "running <id> (Ns)", so waiting stays distinguishable from
        # wedged even when the cell never calls slate_progress.
        if time() - last_note >= _AGENT_PROGRESS_EVERY
            last_note = time()
            _note_run_progress(nb, wait_for, t0)
        end
        sleep(0.02)
    end
end

# How often a blocking agent call reports upstream. Deliberately coarse: the job is to refresh
# the caller's deadline and say what's happening, NOT to mirror the browser's progress bar. The
# reading is latest-value-wins, so a burst of slate_progress frames collapses into one line.
const _AGENT_PROGRESS_EVERY = 15.0
# nb.id → the most recent slate_progress reading (frac, msg, bar id, done, when).
const _LAST_USERPROG = Dict{String,Tuple{Float64,String,String,Bool,Float64}}()
const _USERPROG_LOCK = ReentrantLock()

# One agent-visible status line for a run we're blocked on: which cell, how far in, how much is
# left, and whatever the cell last reported through `slate_progress`.
function _note_run_progress(nb::LiveNotebook, wait_for::AbstractString, t0::Float64)
    running, pending = lock(nb.lock) do
        ([c.id for c in nb.report.cells if c.state == RUNNING],
         count(c -> c.state in (STALE, RUNNING), nb.report.cells))
    end
    parts = String[isempty(running) ?
                   (isempty(wait_for) ? "draining" : "waiting on $wait_for") :
                   "running " * join(running, ", ")]
    pending > 1 && push!(parts, "$pending pending")
    up = lock(_USERPROG_LOCK) do; get(_LAST_USERPROG, nb.id, nothing); end
    # Ignore a stale reading: a leftover from an earlier cell would otherwise be reported as if
    # it described the one running now.
    if up !== nothing && !up[4] && time() - up[5] <= 2 * _AGENT_PROGRESS_EVERY
        frac, msg = up[1], up[2]
        pct = (isfinite(frac) && 0.0 <= frac <= 1.0) ? "$(round(Int, 100 * frac))%" : ""
        detail = strip(join(filter(!isempty, [pct, strip(msg)]), " "))
        isempty(detail) || push!(parts, detail)
    end
    ReportEngine._gate_progress("⏳ " * join(parts, " · ") * "  ($(round(Int, time() - t0))s)")
    return nothing
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
include("server_facts.jl")     # the one description of the hub's state that pages render from
include("server_agentops.jl")
include("server_sse_import.jl")
include("server_agentsessions.jl")
include("server_docs.jl")
include("server_snapshots.jl")
include("server_catalog.jl")   # extension catalog: the published artifact, its cache, and installs
include("slate_api.jl")        # Slate notebook-API registry (SSOT for the api tool, search, prompt)
include("echarts_docs.jl")     # curated ECharts option reference, mapped to the DSL, indexed for search
include("server_export.jl")
include("publish_targets.jl")  # PublishTarget adapters (github-pages, generic-upload) + multi-target fan-out
include("publish_zenodo.jl")   # Zenodo archival target — versioned citable DOI
include("server_hub.jl")
# After server_hub.jl: its signatures dispatch on `Hub`, which is defined there.
include("server_app.jl")       # app mode (served-as-an-application posture) + the /status page
include("server_keymap.jl")    # the user's keyboard shortcuts, in their own config file
include("server_publish.jl")   # Publishing manager service layer (ledger view, targets, secrets, SSE publish)
include("server_specialists.jl") # narrow agents summoned into a notebook: roles, briefs, the ask channel
include("server_debug.jl")     # cell debugger: route the stepping verbs to the kernel the cell runs on
include("server_profile.jl")   # cell profiler: prepare and profile a cell on the kernel it runs on
include("server_findings.jl")  # a specialist's conclusion as a record: claim, cell, verdict, disposition
include("server_checker.jl")   # the checker: a specialist nobody summons — triggered, unsupervised, read-only
include("server_format.jl")    # a notebook in an older file format: updated, with a copy kept, before it opens
include("server_complete.jl")

# ── Standalone convenience (one notebook) ─────────────────────────────────────

"""
    start_server(path; host="127.0.0.1", port=8765, app=false, appdefaults=Dict()) -> Hub

Start a hub and open the single notebook at `path`. Non-blocking; returns the
`Hub` (stop it with [`stop_hub`](@ref)). The notebook is served at `/n/<id>`
(printed); `/` is the index. For a blocking launcher use [`serve_notebook`](@ref).

`app=true` serves the notebook as an **application**: the reading view (markdown, output,
figures and live `@bind` controls — no code, no cell chrome) with the authoring API refused
server-side. Presentation defaults for visitors go in `appdefaults`; build it with
[`app_defaults`](@ref). See `server_app.jl` for what app mode does and does not guarantee.
"""
function start_server(path::AbstractString; host = "127.0.0.1", port = 8765, inactive::Bool = false,
                      app::Bool = false, workbook::Bool = false,
                      appdefaults::AbstractDict = Dict{String,Any}())
    h = start_hub(; host = host, port = port, app = app, workbook = workbook, appdefaults = appdefaults)
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
                             keys::Bool = false, inactive::Bool = false, app::Bool = false,
                             apptitle::AbstractString = "", io::IO = stdout)
    rule = "─"^72
    printstyled(io, "\n", rule, "\n"; color = :green)
    printstyled(io, app ? "  ✓  " * (isempty(apptitle) ? "Your app" : apptitle) * " is running\n\n" :
                    inactive ? "  ✓  Your Kaimon Slate notebook is ready (inactive)\n\n" :
                               "  ✓  Your Kaimon Slate notebook is live\n\n"; color = :green, bold = true)
    print(io, "      →  ")
    printstyled(io, url; color = :cyan, bold = true, underline = true)
    if keys && app
        # `b`/`p` below distinguish "open AND launch" from "open, stay a preview" — a lifecycle an app
        # does not have: it is warmed before this banner prints (see `_await_app_warm`), so there is
        # nothing to launch and no preview to stay in. One key to open it, one to stop it.
        print(io, "\n\n  Press  ")
        printstyled(io, "b"; color = :cyan, bold = true); print(io, " open in a browser    ")
        printstyled(io, "q"; color = :cyan, bold = true); print(io, " stop the app\n")
        print(io, "  Tip: set ")
        printstyled(io, "SLATE_BROWSER"; color = :light_black)
        print(io, " (e.g. \"Google Chrome\") to choose which browser b opens.\n")
    elseif keys
        print(io, "\n\n")
        inactive && print(io, "  It opens as a static preview — nothing runs until you launch it.\n\n")
        print(io, "  Press  ")
        printstyled(io, "b"; color = :cyan, bold = true); print(io, " browser + launch (go live)    ")
        printstyled(io, "p"; color = :cyan, bold = true); print(io, " browser, stay a preview    ")
        printstyled(io, "q"; color = :cyan, bold = true); print(io, " stop the server\n")
        print(io, "  Tip: set ")
        printstyled(io, "SLATE_BROWSER"; color = :light_black)
        print(io, " (e.g. \"Google Chrome\") to choose which browser b/p open.\n")
    else
        print(io, "\n\n  Open the link above in a browser. Press q or Ctrl-C here to stop the server.\n")
    end
    # `/status` for EVERY app path, not just the interactive one. A deployed app is normally started
    # without a terminal — backgrounded, under a unit file, output piped to a log — which is exactly
    # the case where nobody can ask it how it's doing, and exactly the branch that used to omit the
    # one address that answers. It's also what someone reads back out of that log later.
    if app
        print(io, "  Operator page (vitals, logs): ")
        printstyled(io, replace(rstrip(url, '/'), r"/n/[^/]+$" => "") * "/status", "\n"; color = :light_black)
    end
    if !isempty(logpath)
        print(io, "  Detailed server log: ")
        printstyled(io, logpath, "\n"; color = :light_black)
    end
    printstyled(io, rule, "\n\n"; color = :green)
    flush(io)
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
    serve_notebook(path; host="127.0.0.1", port=8765, quiet=true, app=false, appdefaults=Dict())

Open the notebook at `path` in a hub and serve it. **Blocks** until stopped (Ctrl-C shuts the hub
and its workers down cleanly). Once the hub is answering HTTP, prints a framed banner with the
openable notebook URL (so a launcher like `run.jl` surfaces a ready, clickable link rather than a
bare port). With `quiet=true` (default) the console stays clean after the banner: the hub's log
detail (worker spawns, connects, warnings) goes to a file in the same tmp dir as the worker logs —
the banner shows the path; only errors still print.
"""
function serve_notebook(path::AbstractString; host = "127.0.0.1", port = 8765, quiet::Bool = true,
                        inactive::Bool = false, app::Bool = false, workbook::Bool = false,
                        appdefaults::AbstractDict = Dict{String,Any}())
    # Swap the logger BEFORE anything spawns so worker-spawn infos land in the file.
    logdir = ReportEngine._slate_logdir()
    logpath = isempty(logdir) ? "" : joinpath(logdir, "hub-$port.log")
    logio = nothing
    prevlogger = nothing
    # `_slate_logdir` has already guaranteed the directory is ours and 0700 (the hub log records
    # request/worker detail, so other local users stay out); the file is locked to 0600 below. An
    # empty path means it found nowhere private at all — then the banner reports no log.
    if quiet && !isempty(logpath)
        try
            logio = open(logpath, "a")
            Sys.isunix() && (try; chmod(logpath, 0o600); catch; end)
            println(logio, "── serve_notebook  $(Dates.now())  $path ──")
            prevlogger = Logging.global_logger(_FileDemuxLogger(logio, Logging.global_logger()))
        catch
            logio = nothing                  # log hygiene must never block serving
        end
    end
    h = start_server(path; host = host, port = port, inactive = inactive,
                     app = app, workbook = workbook, appdefaults = appdefaults)
    id = isempty(h.notebooks) ? "" : first(keys(h.notebooks))
    # An APP advertises the server ROOT. `/` on an app hub redirects to its notebook (see
    # `_app_root_target`), so the two land in the same place — but the root is the address someone
    # types, bookmarks, puts on a wiki, or reads out loud. `/n/<id>` exposes an internal id that is
    # derived from a filename and means nothing to the person using the thing.
    url = app ? _hub_url(h) : "$(_hub_url(h))/n/$id"
    _await_http_ready(_hub_url(h))          # wait until the server actually answers before announcing it
    # …and, for an app, until it has something to SHOW: its reader has no cell-level progress to read,
    # so a URL handed out mid-bring-up looks broken. Times out rather than hangs (see _await_app_warm).
    app && _await_app_warm(h)
    # Interactive keys (b/p/q) only work on the raw-tty path below (a `julia run.jl` launch), not a REPL.
    # (Named `showkeys`, not `keys` — a local `keys` would shadow `Base.keys` used just above.)
    showkeys = !isinteractive() && stdin isa Base.TTY
    # An app is named by its DOCUMENT (the `role=title` cell), not by the file it lives in — the same
    # title the browser tab and the app bar carry.
    apptitle = !app ? "" : try
        nb1 = lock(h.lock) do; isempty(h.notebooks) ? nothing : first(values(h.notebooks)); end
        nb1 === nothing ? "" : strip(report_frontmatter(nb1.report).title)
    catch; ""; end
    _print_ready_banner(url; logpath = logio === nothing ? "" : logpath, keys = showkeys,
                        inactive = inactive, app = app, apptitle = apptitle)
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
