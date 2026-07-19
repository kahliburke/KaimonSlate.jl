# Isolated-module evaluation (engine, §6/D2). Included into `module ReportEngine`.
#
# Code cells execute in document order inside a per-report `Module()`. The process
# stays warm (all JIT-compiled methods kept); only the namespace is fresh, so the
# report is reproducible without losing the warm benefit. This slice captures
# stdout + a text/plain value repr + errors; MIME/figure capture (§7) and the
# dependency model (§6) layer on later without changing this loop.

export eval_report!, eval_cell!, report_module, reset_module!
export Kernel, InProcessKernel, PendingKernel, run_capture, shutdown!
export register_refresh!, unregister_refresh!, register_srcchange!, unregister_srcchange!, revise_apply!
export register_progress!, unregister_progress!, register_runbatch!, unregister_runbatch!
export register_userprog!, unregister_userprog!
export register_prepare!, unregister_prepare!
export register_emit!, unregister_emit!
export register_celldone!, unregister_celldone!

# ── Async reactivity hook ─────────────────────────────────────────────────────
#
# A cell's background task can call `slate_refresh(:data, …)` to announce that
# some globals changed; the server (which registers a callback per report id)
# then recomputes the cells that *read* those names and pushes a live update.
# The callback is registered out-of-band so the dependency-light engine needn't
# know about the HTTP/SSE layer.
const _REFRESH_REGISTRY = Dict{String,Any}()
register_refresh!(report_id::AbstractString, cb) = (_REFRESH_REGISTRY[String(report_id)] = cb; nothing)
unregister_refresh!(report_id::AbstractString) = (delete!(_REFRESH_REGISTRY, String(report_id)); nothing)
function _do_refresh(report_id::AbstractString, vars)
    cb = get(_REFRESH_REGISTRY, String(report_id), nothing)   # registry keys are String (sibling _do_* convert too)
    cb === nothing || cb(Symbol[Symbol(v) for v in vars])
    return nothing
end

# Live run progress: `eval_cell!` announces each cell as it STARTS running and when it FINISHES,
# so the server can stream a per-cell status to the browser (which cell is live, its result the
# instant it lands) instead of one update at the end of a whole run. Registered per report id,
# out-of-band, so the engine needn't know about the SSE layer. The callback takes the Cell.
const _PROGRESS_REGISTRY = Dict{String,Any}()
register_progress!(report_id::AbstractString, cb) = (_PROGRESS_REGISTRY[String(report_id)] = cb; nothing)
unregister_progress!(report_id::AbstractString) = (delete!(_PROGRESS_REGISTRY, String(report_id)); nothing)
function _emit_progress(report_id::AbstractString, cell)
    cb = get(_PROGRESS_REGISTRY, report_id, nothing)
    cb === nothing && return nothing
    try; cb(cell); catch e; @debug "eval: progress callback failed" report_id exception = e; end   # best-effort — a push failure must never break eval
    return nothing
end

# Run-batch size: how many cells `eval_stale!` is about to evaluate, announced ONCE at the start of a
# run so the UI's progress reads a stable "k / N" (N = total to run) instead of guessing from the
# sequential per-cell stream. Same out-of-band registry pattern.
const _RUNBATCH_REGISTRY = Dict{String,Any}()
register_runbatch!(report_id::AbstractString, cb) = (_RUNBATCH_REGISTRY[String(report_id)] = cb; nothing)
unregister_runbatch!(report_id::AbstractString) = (delete!(_RUNBATCH_REGISTRY, String(report_id)); nothing)
function _emit_run_batch(report_id::AbstractString, n::Integer)
    cb = get(_RUNBATCH_REGISTRY, report_id, nothing)
    cb === nothing && return nothing
    try; cb(n); catch e; @debug "eval: run-batch callback failed" report_id exception = e; end
    return nothing
end

# In-cell progress: a running cell can call `slate_progress(frac; msg)` (frac ∈ 0..1) to report how
# far along it is; the server relays it to the UI (a bar on the cell + the "currently running" chip).
# Same out-of-band registry pattern; the callback takes (frac::Float64, msg::String).
const _USERPROG_REGISTRY = Dict{String,Any}()
register_userprog!(report_id::AbstractString, cb) = (_USERPROG_REGISTRY[String(report_id)] = cb; nothing)
unregister_userprog!(report_id::AbstractString) = (delete!(_USERPROG_REGISTRY, String(report_id)); nothing)
function _do_userprog(report_id::AbstractString, frac, msg, id = "", done = false)
    cb = get(_USERPROG_REGISTRY, String(report_id), nothing)
    cb === nothing && return nothing
    f = try; clamp(Float64(frac), 0.0, 1.0); catch; 0.0; end
    try; cb(f, String(msg), String(id), done === true); catch e; @debug "eval: user-progress callback failed" report_id exception = e; end
    return nothing
end

# Environment prep progress: a booting worker precompiles a cold env in the background and PUBs a
# structured status (JSON: phase/k/n/pkg/…) on `slate_prepare`; the poller routes it here by report id
# and the server relays it to the browser's "Preparing packages" banner. Same out-of-band registry; the
# callback takes the JSON string verbatim (the worker already encoded it — the hub just forwards).
const _PREPARE_REGISTRY = Dict{String,Any}()
register_prepare!(report_id::AbstractString, cb) = (_PREPARE_REGISTRY[String(report_id)] = cb; nothing)
unregister_prepare!(report_id::AbstractString) = (delete!(_PREPARE_REGISTRY, String(report_id)); nothing)
function _do_prepare(report_id::AbstractString, json::AbstractString)
    cb = get(_PREPARE_REGISTRY, String(report_id), nothing)
    cb === nothing && return nothing
    try; cb(String(json)); catch e; @debug "eval: prepare callback failed" report_id exception = e; end
    return nothing
end

# Custom per-channel live stream: a running cell calls `slate_emit(channel, data)` to push an
# arbitrary JSON-serializable value straight to a browser-side handler registered on that channel
# (`slateOnStream(channel, fn)`), with NO cell recompute and NO output swap — the low-latency path
# for a custom `@asset` renderer that owns its cell's output. Same out-of-band registry pattern; the
# server callback JSON-encodes and broadcasts a `cellstream:` frame. The callback takes (channel, data).
const _EMIT_REGISTRY = Dict{String,Any}()
register_emit!(report_id::AbstractString, cb) = (_EMIT_REGISTRY[String(report_id)] = cb; nothing)
unregister_emit!(report_id::AbstractString) = (delete!(_EMIT_REGISTRY, String(report_id)); nothing)
function _do_emit(report_id::AbstractString, channel, payload)
    cb = get(_EMIT_REGISTRY, String(report_id), nothing)
    cb === nothing && return nothing
    try; cb(String(channel), payload); catch e; @debug "eval: emit callback failed" report_id exception = e; end   # payload is a Julia VALUE (gate: deserialized; in-process: passed straight through) — the emit callback JSON-encodes it
    return nothing
end

# Parallel batch results: the gate worker evaluates a batch of stale cells CONCURRENTLY and PUBs each
# cell's wire-form result on the `slate_celldone` channel the instant it finishes (see worker.jl
# `__slate_eval_batch`). The poller routes each here; the server merges it version-guarded and pushes a
# single-cell patch — so a fast cell renders while a slow sibling is still running. Same out-of-band
# registry. The callback takes (run_id, cell_id, wire).
const _CELLDONE_REGISTRY = Dict{String,Any}()
register_celldone!(report_id::AbstractString, cb) = (_CELLDONE_REGISTRY[String(report_id)] = cb; nothing)
unregister_celldone!(report_id::AbstractString) = (delete!(_CELLDONE_REGISTRY, String(report_id)); nothing)
function _do_celldone(report_id::AbstractString, run_id, cell_id, wire)
    cb = get(_CELLDONE_REGISTRY, String(report_id), nothing)
    cb === nothing && return nothing
    try; cb(String(run_id), String(cell_id), wire); catch e; @warn "slate: celldone merge failed" cell = cell_id exception = e; end
    return nothing
end

# Parent-project /src hot-reload: the worker's Revise watcher fires `files_changed`; the
# server registers a per-report callback (out-of-band, like refresh) that applies the
# revisions and invalidates the cells that read the changed definitions.
const _SRCCHANGE_REGISTRY = Dict{String,Any}()
register_srcchange!(report_id::AbstractString, cb) = (_SRCCHANGE_REGISTRY[String(report_id)] = cb; nothing)
unregister_srcchange!(report_id::AbstractString) = (delete!(_SRCCHANGE_REGISTRY, String(report_id)); nothing)
# The callback takes (changed_names, error_msg): a normal reload passes the names + ""; a
# parse/apply error passes [] + the message. One registry covers both.
function _do_src_changed(report_id::AbstractString, names)
    cb = get(_SRCCHANGE_REGISTRY, String(report_id), nothing)
    cb === nothing || cb(String[String(n) for n in names], "")
    return nothing
end
function _do_src_error(report_id::AbstractString, msg)
    cb = get(_SRCCHANGE_REGISTRY, String(report_id), nothing)
    cb === nothing || cb(String[], String(msg))
    return nothing
end

# A fresh report namespace, built by the SINGLE shared contract `_populate_notebook_ns!`
# (widgets.jl) — the same one the gate worker uses, so the two namespaces can't drift.
# Only the context-specific helper implementations differ: here `slate_refresh` fires
# the in-process recompute callback (the worker PUBs on the gate stream instead).
function _new_module(report::Report)
    m = Module(Symbol(:Report_, report.id))
    rid = report.id
    _populate_notebook_ns!(m;
        echart = echart, EChart = EChart, slate_table = slate_table, SlateTable = SlateTable,
        slate_query = slate_query, slate_refresh = (vars...) -> _do_refresh(rid, vars),
        slate_progress = (frac; msg = "", id = "", done = false) -> _do_userprog(rid, frac, msg, id, done),
        slate_emit = (channel, data) -> _do_emit(rid, channel, data),
        assetbase = () -> String(get(report.meta, "assetbase", "")))   # `@asset` base (notebook project dir)
    return m
end

"Get (creating if needed) the report's execution namespace."
function report_module(report::Report)
    report.mod === nothing && (report.mod = _new_module(report))
    return report.mod
end

"""
    reset_module!(report) -> Module

Discard the report's namespace and mark every cell stale — the basis of a full
rebuild (ground truth, §6). Returns the fresh module.
"""
function reset_module!(report::Report)
    report.mod = _new_module(report)
    reset_all!(report)
    return report.mod
end

# Run a cell and capture its output. The capture machinery lives in `capture.jl`
# (shared with the gate worker) and returns a wire-form NamedTuple; here we wrap
# it into the engine's `CellOutput` (mapping mime tuples → `MimeChunk`).
function _eval_capture(mod::Module, source::AbstractString, filename::AbstractString = "string"; slate_ctx = nothing)
    r = run_capture(mod, source, filename; slate_ctx = slate_ctx)
    chunks = MimeChunk[MimeChunk(m, bytes) for (m, bytes) in r.mime]
    binds = BindSpec[BindSpec(b.name, b.kind, b.params, b.value) for b in r.binds]
    overflow = hasproperty(r, :overflow) ? collect(r.overflow) : Any[]   # full results saved to disk (gate worker too)
    animations = hasproperty(r, :animations) ? collect(r.animations) : Any[]
    effects = hasproperty(r, :effects) ? collect(r.effects) : Any[]
    assets = hasproperty(r, :assets) ? collect(r.assets) : Any[]
    return CellOutput(r.stdout, chunks, r.echarts, r.tables, binds, r.value_repr, r.exception,
                      r.backtrace, r.duration_ms, collect(r.trace), r.stderr, overflow, animations,
                      "", "", effects, assets)   # in-process has no memo; effects/assets from their channels
end

# ── Kernel: the execution backend ─────────────────────────────────────────────
#
# A `Kernel` is *where* and *how* cells run. The whole engine touches the live
# execution environment through this one seam: prepare a namespace, reset it,
# evaluate-and-capture a cell, and assign a `@bind` value. The reactive layer
# (parse, dep graph, staleness, ordering, render) is kernel-agnostic.
#
# `InProcessKernel` (the default, and the standalone backend) runs cells in the
# report's own in-process `Module` (`report.mod`). A `GateKernel` (added with the
# Kaimon extension) dispatches the same four operations to a per-notebook gate
# worker over ZMQ, so capture happens where the live value lives.

abstract type Kernel end

"Release a kernel's resources (kill a local gate worker; detach a spawned-remote one unless
`kill_remote=true` — see the GateKernel method). No-op for in-process."
shutdown!(::Kernel; kill_remote::Bool = false) = nothing

"""
    InProcessKernel <: Kernel

Evaluate cells in the report's own in-process `Module`. Stateless — the namespace
lives on `report.mod`, managed by [`report_module`](@ref) / [`reset_module!`](@ref).
"""
struct InProcessKernel <: Kernel end

"Ensure the kernel's namespace exists and is ready to evaluate into."
prepare!(::InProcessKernel, report::Report) = report_module(report)

"Discard the kernel's namespace (full rebuild); cells are marked stale by the caller."
reset!(::InProcessKernel, report::Report) = reset_module!(report)

"Evaluate `source` in the kernel and capture stdout + rich output → `CellOutput`. `region`/`regions`
seed the task-local Slate execution context (see `_build_slate_ctx`); `region=\"\"` ⇒ the main kernel."
eval_capture(::InProcessKernel, report::Report, source::AbstractString, filename::AbstractString = "string";
             region::AbstractString = "", regions::AbstractVector = String[]) =
    _eval_capture(report_module(report), source, filename;
                  slate_ctx = _build_slate_ctx(report_module(report), report.id, region, regions))

# Memo-aware entry (5-arg `memo` = (; key, names, threshold)). Default: ignore caching and just
# evaluate — only the gate kernel (real notebooks) implements durable memoization. Keeps in-process
# and test kernels working unchanged. `region`/`regions` flow through to the execution context.
eval_capture(k::Kernel, report::Report, source::AbstractString, filename::AbstractString, memo;
             region::AbstractString = "", regions::AbstractVector = String[]) =
    eval_capture(k, report, source, filename; region = region, regions = regions)

"""
    PendingKernel <: Kernel

Placeholder installed on `LiveNotebook.kernel` while the real kernel is booting (a worker
spawn) or being reconstructed (a standalone bundle's environment). Every dispatched call
BLOCKS until [`_resolve!`](@ref)/[`_reject!`](@ref) fires, then forwards to the real kernel —
so a run/edit request that races the boot window queues transparently instead of silently
evaluating in-process against the wrong (extension's own) environment, or erroring on a
worker that doesn't exist yet. Mirrors `GateKernel`'s own lock-guarded `prepare!` (which
blocks concurrent callers on a reconnect), generalized to "any kernel op, before the real
kernel is known."
"""
mutable struct PendingKernel <: Kernel
    ready::Base.Event
    real::Union{Kernel,Nothing}
    err::Union{String,Nothing}
    PendingKernel() = new(Base.Event(), nothing, nothing)
end

"Unblock every waiter on `k` — subsequent (and in-flight) calls forward to `real`."
function _resolve!(k::PendingKernel, real::Kernel)
    k.real = real
    notify(k.ready)
    return nothing
end

"Unblock every waiter on `k` with a boot failure — forwarded calls raise `err` instead of hanging forever."
function _reject!(k::PendingKernel, err::AbstractString)
    k.err = err
    notify(k.ready)
    return nothing
end

function _await_real(k::PendingKernel)
    wait(k.ready)
    k.err === nothing || error(k.err)
    return k.real::Kernel
end

# The 14 Kernel operations with no generic `::Kernel` fallback — each blocks for the real
# kernel, then forwards. (`shutdown!`, `cancel_cells`, `memo_pin!`, `worker_log_tail`, the
# 5-arg memo `eval_capture`, and `_kernel_status` already have safe non-blocking `::Kernel`
# fallbacks above/elsewhere and need no override here.)
prepare!(k::PendingKernel, report::Report) = prepare!(_await_real(k), report)
reset!(k::PendingKernel, report::Report) = reset!(_await_real(k), report)
eval_capture(k::PendingKernel, report::Report, source::AbstractString, filename::AbstractString = "string";
             region::AbstractString = "", regions::AbstractVector = String[]) =
    eval_capture(_await_real(k), report, source, filename; region = region, regions = regions)
eval_capture(k::PendingKernel, report::Report, source::AbstractString, filename::AbstractString, memo;
             region::AbstractString = "", regions::AbstractVector = String[]) =
    eval_capture(_await_real(k), report, source, filename, memo; region = region, regions = regions)
complete(k::PendingKernel, report::Report, code::AbstractString, pos::Integer) =
    complete(_await_real(k), report, code, pos)
assign_bind!(k::PendingKernel, report::Report, name::Symbol, value) =
    assign_bind!(_await_real(k), report, name, value)
table_page(k::PendingKernel, report::Report, table_id::AbstractString, request::AbstractDict) =
    table_page(_await_real(k), report, table_id, request)
interpolate(k::PendingKernel, report::Report, exprs::Vector{String}) =
    interpolate(_await_real(k), report, exprs)
harvest_docs(k::PendingKernel, report::Report, mod_names) =
    harvest_docs(_await_real(k), report, mod_names)
module_help(k::PendingKernel, report::Report, name::AbstractString) =
    module_help(_await_real(k), report, name)
macroexpand_cells(k::PendingKernel, report::Report, srcs::AbstractDict) =
    macroexpand_cells(_await_real(k), report, srcs)
project_deps(k::PendingKernel, report::Report) = project_deps(_await_real(k), report)
env_info(k::PendingKernel, report::Report) = env_info(_await_real(k), report)
bundle_info(k::PendingKernel, report::Report) = bundle_info(_await_real(k), report)
pkg_op(k::PendingKernel, report::Report, op::AbstractString, name::AbstractString; target::AbstractString = "notebook") =
    pkg_op(_await_real(k), report, op, name; target)

"""
    complete(kernel, report, code, pos) -> (; items, from, to)

Completion candidates for `code` at byte offset `pos`, resolved WHERE the kernel's
bindings live — so `using`'d packages and evaluated-cell bindings complete, not just
`Base`. `items` is a `Vector{Tuple{String,String}}` of `(text, kind)`; `from`/`to` are
0-based byte offsets of the replaced range. The in-process kernel completes locally.
"""
complete(::InProcessKernel, report::Report, code::AbstractString, pos::Integer) =
    slate_completions(report_module(report), code, pos)

"""
Set a `@bind` control's value from the browser: coerce it against the widget, update
the per-notebook registry (so a later re-run preserves it), and assign the global so
readers see it. Returns the coerced value. Routed through the namespace's injected
`__slate_set_bind` so the logic lives in exactly one place (widgets.jl)."""
assign_bind!(::InProcessKernel, report::Report, name::Symbol, value) =
    Base.invokelatest(getfield(report_module(report), :__slate_set_bind), name, value)

"""
    table_page(kernel, report, table_id, request) -> (rows, total)

Fetch one page of a server-paged table (a `slate_table(…; paged=true)` /
`slate_query` result), routing to the provider registered where cells eval. The
`request` is the frontend's JSON body (page / page_size / sort_col / sort_desc /
search). In-process providers live here; the gate kernel forwards to its worker.
"""
table_page(::InProcessKernel, ::Report, table_id::AbstractString, request::AbstractDict) =
    _provider_page(table_id, _page_request(request))

"""
    interpolate(kernel, report, exprs) -> Vector{CellOutput}

Capture each markdown `{{ expr }}` in the kernel (rich output, like a mini code
cell). The gate kernel forwards to its worker.
"""
interpolate(::InProcessKernel, report::Report, exprs::Vector{String}) =
    CellOutput[_eval_capture(report_module(report), e) for e in exprs]

"""
    harvest_docs(kernel, report, mod_names) -> Vector{Dict}

Harvest `{module, name, doc}` for documented exported bindings of the named modules,
resolved WHERE cells evaluate (so the modules must be `using`'d in the notebook). The
gate kernel forwards to its worker, where the notebook's packages live.
"""
harvest_docs(::InProcessKernel, report::Report, mod_names) =
    harvest_module_docs(report_module(report), mod_names)

"""
    module_help(kernel, report, name) -> Dict

Live help lookup for `name` (a binding or module), resolved WHERE cells evaluate —
`{name, module, doc, kind, exports}`. Powers the docs palette's `?Module` drill-down
(list a package's exports) + cross-reference links. The gate kernel forwards to its
worker, where the notebook's packages live.
"""
module_help(::InProcessKernel, report::Report, name::AbstractString) =
    module_help(report_module(report), name)

"""
    cancel_cells(kernel, report, ids) -> Int

Best-effort interrupt of the named cells' IN-FLIGHT evaluator tasks (superseded-edit
preemption — see `_preempt_superseded!`). Never a correctness dependency: the src-hash version
guard still discards a stale result on completion. In-process evals are synchronous with their
caller — nothing to preempt — so the base method no-ops; the gate kernel forwards to its worker.
"""
cancel_cells(::Kernel, ::Report, ids) = 0

"""
    macroexpand_cells(kernel, report, srcs) -> Dict{String,Tuple{Set{Symbol},Set{Symbol}}}

Macro-expand each cell source (`id => source`) in the namespace where cells evaluate —
recursively, NEVER evaluating — and ANALYZE the expansion there, returning
`id => (reads, writes)`. Cells whose expansion/analysis fails are omitted (the caller keeps
its conservative static analysis). The gate kernel forwards to its worker, where the
notebook's macros are actually defined; only name lists cross the wire (see macroexpand.jl).
"""
function macroexpand_cells(::InProcessKernel, report::Report, srcs::AbstractDict)
    m = report_module(report)
    out = Dict{String,Tuple{Set{Symbol},Set{Symbol}}}()
    for (id, src) in srcs
        b = _expanded_bindings_of(EE, _expand_cell_statements(m, String(src)))
        b === nothing || (out[String(id)] = b)
    end
    return out
end

"The in-process kernel's own active project's direct deps as `{name, version, uuid}` — the
same project `pkg_op` mutates. Mirrors the gate worker's `__slate_project_deps`."
function _active_project_deps()
    out = Dict{String,Any}[]
    try
        proj = Pkg.project()
        info = Pkg.dependencies()
        for (name, uuid) in proj.dependencies
            pi = get(info, uuid, nothing)
            ver = (pi === nothing || pi.version === nothing) ? "" : string(pi.version)
            push!(out, Dict{String,Any}("name" => name, "version" => ver, "uuid" => string(uuid)))
        end
    catch
    end
    return out
end

# The in-process kernel's dependency baseline — whatever was already in the active project
# when the process started, i.e. the running app's OWN footprint (KaimonSlate + its deps
# standalone, or Kaimon + its deps as an extension). Captured once (KaimonSlate's `__init__`,
# before any notebook could ever call `pkg_op`), so the app's own deps never masquerade as
# something a notebook added — mirrors `_WORKER_INFRA_PKGS` filtering a GateKernel's env.
const _INPROCESS_BASE_DEPS = Ref{Set{String}}(Set{String}())
function _snapshot_inprocess_base_deps!()
    d = Set{String}()
    try
        for (name, _) in Pkg.project().dependencies
            push!(d, name)
        end
    catch
    end
    _INPROCESS_BASE_DEPS[] = d
    return d
end

"""
    project_deps(kernel, report) -> Vector{Dict}

The notebook project's direct dependencies as `{name, version}` (for eager docs
auto-indexing — everything reachable is worth indexing, so this is intentionally
unfiltered). The gate kernel reads its worker's active project; the in-process
kernel has no separate worker, so it reads the host's own active project — the same
one `pkg_op` adds/removes into.
"""
project_deps(::InProcessKernel, ::Report) = _active_project_deps()

# In-process has no parent to fork from (cells already run in the host's active
# project — same "env IS the whole world" semantics as a GateKernel detached notebook) —
# but unlike a GateKernel's fresh worker env, that active project already carries the
# running app's OWN deps, so filter those out via the startup baseline: only what a
# notebook itself added should show in the package panel / reproducibility footer.
function env_info(::InProcessKernel, ::Report)
    base = _INPROCESS_BASE_DEPS[]
    deps = filter(d -> !(string(get(d, "name", "")) in base), _active_project_deps())
    return (notebook = (path = dirname(Pkg.project().path), deps = deps), parent = nothing)
end
bundle_info(::InProcessKernel, ::Report) = (projectdir = "", pathdeps = NamedTuple[])

"""
    memo_pin!(kernel, report, key::AbstractString, pin::Bool) -> nothing

Pin (`pin=true`) or release (`pin=false`) a memo entry against `gc` eviction — the `locked` cell
tag's durability guarantee (§ `set_cell_tags!`). The in-process kernel has no durable memo store,
so this is a no-op there.
"""
memo_pin!(::Kernel, ::Report, ::AbstractString, ::Bool) = nothing

"""
    pkg_op(kernel, report, op, name) -> Dict{String,Any}

Add (`op="add"`) or remove (`op="rm"`) a package in the kernel's active project — the
notebook's own dependency environment. The gate kernel mutates its worker's project; the
in-process kernel has no separate worker to fork an env in, so cells already run in the
process's own active project — same "env IS the whole world" semantics as a GateKernel's
detached notebook (`server.jl`'s `parent == ""` case). `target` is accepted for API parity
with `GateKernel` but has no separate object to select (no parent to add to instead).
Returns `{ok, message}`.
"""
function pkg_op(::InProcessKernel, ::Report, op::AbstractString, name::AbstractString;
                target::AbstractString = "notebook")
    op in ("add", "rm") || return Dict{String,Any}("ok" => false, "message" => "bad op '$op'")
    try
        op == "add" ? Pkg.add(String(name)) : Pkg.rm(String(name))
        return Dict{String,Any}("ok" => true, "message" => "")
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"""
    eval_cell!(report, cell, kernel=InProcessKernel()) -> Cell

Evaluate one cell through `kernel`. Markdown cells are inert (marked `FRESH`). A
code cell becomes `FRESH` on success or `ERRORED` if it threw; the error is
captured, never propagated, so one bad cell doesn't abort the report.
"""
# ── Durable memoization key (server side) ─────────────────────────────────────────────────────
const _MEMO_THRESHOLD_MS = 150.0    # only cells slower than this are worth persisting to disk (export ignores it)

# A cell is memoizable if its result is a pure function of its source + upstream sources + bind
# inputs. Excluded: markdown, `using`/`import` barriers (:opaque — namespace effects not captured by
# `writes`), control-DECLARING cells (their value comes from the UI), and explicit opt-outs.
function _memoizable(cell::Cell)
    cell.kind == CODE || return false
    # `:opaque` (unresolved `using` / macro barrier) and `:nocache` (explicit opt-out) are memo-specific.
    (:opaque in cell.flags || :nocache in cell.flags) && return false
    # Process-state and non-deterministic cells are never cached — read off the SAME `_cell_effect`
    # classifier the REGION layer uses to decide re-run-vs-transfer, so the two determinations can't
    # drift (the theme regression). RESOURCE — a live DB/socket/file handle that can't/shouldn't be
    # serialized (re-inits cheaply every open, like `:nocache`); its downstream is unlocked separately
    # in `_memo_key`, where a `:resource` upstream is key-transparent, not a purity barrier. VOLATILE —
    # non-deterministic (`rand`/`now`); a cached value would be a lie.
    _cell_effect(cell) in (RESOURCE, VOLATILE, IMPURE) && return false
    # A cell that PROVIDES names (`using`/`import`) is memoizable via IMPORT SCAFFOLD: cache its
    # genuinely-defined values (writes ∖ provides) and, on restore, replay just its `using`/`import`
    # statements (the worker does this from the source) to re-establish the import's name-in-scope /
    # method-table effect. `:import_scaffold` is set on every non-opaque provider (see
    # build_dependencies!); `:using_redundant` is the subset whose replay is a proven no-op. A
    # provider reaching here is non-opaque (an unresolved `using` is `:opaque` and returned above).
    (isempty(cell.provides) || :import_scaffold in cell.flags) || return false
    # A global-theme setter (`set_theme!`/`update_theme!`, marked by the synthetic `_THEME_SENTINEL`
    # write) is memoizable via the SAME import-scaffold trick: its `set_theme!` effect is process
    # state (not a binding), so on restore the worker REPLAYS the theme call from source — cheap,
    # idempotent — to re-establish the global theme for any downstream cell that re-runs. The
    # rendered figure itself rides the cached wire image; `_THEME_SENTINEL` is dropped from the memo
    # names server-side (a synthetic marker, never a real global). Invalidation is already handled:
    # graphics cells READ the sentinel, so a theme edit bumps their key. This unlocks the expensive
    # self-theming plots (a `set_theme!(theme_dark())` before a heavy render) that dominate startup.
    #
    # A cell that DECLARES a `@bind` is memoizable via the SAME scaffold trick: cache the cell's
    # genuinely-computed writes and, on restore, REPLAY just its `@bind` statement (`_replay_scaffold!`)
    # to re-register the widget + re-assign the control global — the expensive body never re-runs. This
    # is what makes a MIXED cell (a `@bind` beside real compute) cacheable. The control's current value
    # is already folded into the memo key (`_memo_key`), so changing the control invalidates the entry;
    # and the fresh-namespace re-establish seeds the registry with the host's value first, so the replay
    # reconciles to it rather than the widget default (values and cached compute can't drift).
    return true
end

# Is this source purely `using`/`import` statements (comments/whitespace aside)? Such a cell is
# deterministic given the resolved environment — the one :opaque shape that is safe to digest
# into a downstream memo key (see the closure loop in `_memo_key`). Conservative: any other
# top-level expression (or a parse error) → false.
function _is_pure_using(src::AbstractString)
    ex = try; Meta.parseall(String(src)); catch; return false; end
    ex isa Expr || return false
    seen = false
    for a in (ex.head === :toplevel ? ex.args : Any[ex])
        a isa LineNumberNode && continue
        (a isa Expr && a.head in (:using, :import)) || return false
        seen = true
    end
    return seen
end

# A total-ish cache key: this cell's source + the sources of its transitive upstream cells + the
# values of any @bind variables in the read-closure. The worker folds in the Revise'd `src/` digest
# and the resolved Manifest, completing the key so a src/dep/package change invalidates the entry.
# The transitive upstream-cell id closure of `cell` (its `deps`, followed to a fixpoint). Pure graph
# walk (no I/O); shared by `_memo_key` and the badge classifier `_memo_status`.
function _dep_closure(byid, cell::Cell)
    closure = Set{String}(); stack = collect(cell.deps)
    while !isempty(stack)
        id = pop!(stack); (id in closure || !haskey(byid, id)) && continue
        push!(closure, id); union!(stack, byid[id].deps)
    end
    return closure
end

# True if any upstream cell in `closure` POISONS the memo key. Impurity propagates: the key digests
# upstream SOURCES, so it's only total if every upstream value is a function of its source. A
# `nocache`/`volatile` upstream (re-runs produce fresh values from the same source) or an :opaque
# barrier (include(): effects from outside the source) breaks that — restoring downstream against a
# re-run impure producer would silently resurrect the PREVIOUS run's values. EXCEPTION: an :opaque
# upstream that is PURELY `using`/`import` — its effect is a function of (source, resolved env), both
# already in the key. `:resource` is DETERMINISTIC-external (key-transparent: its source is still
# digested, so an edit invalidates dependents). Shared cheap check (no I/O) for `_memo_key` (→
# unkeyable) and `_memo_status` (→ the badge reason), so the two can't drift.
function _key_poisoned(byid, closure)
    for id in closure
        f = byid[id].flags
        :resource in f && continue
        (:nocache in f || :volatile in f) && return true
        (:opaque in f && !_is_pure_using(byid[id].source)) && return true
    end
    return false
end

function _memo_key(report::Report, cell::Cell)
    _memoizable(cell) || return ""
    byid = report.byid
    closure = _dep_closure(byid, cell)
    _key_poisoned(byid, closure) && return ""    # an impure upstream makes the key non-total
    depsrc = sort!([(id, byid[id].src_hash) for id in closure])
    readnames = copy(cell.reads); for id in closure; union!(readnames, byid[id].reads); end
    bvals = Tuple{String,Any}[]
    for c in report.cells, b in c.binds
        b.name in readnames && push!(bvals, (string(b.name), b.value))
    end
    sort!(bvals; by = first)
    # `@asset` file deps (this cell + its transitive upstream, mirroring `depsrc`): fold each
    # referenced file's CURRENT content hash into the key so editing an asset invalidates the memo
    # entry (no stale restore on cold start). Paths resolve against `assetbase` (the notebook's
    # project dir, set at kernel selection) — the same base the worker's `@asset` reads from.
    base = String(get(report.meta, "assetbase", ""))
    relpaths = String[]; append!(relpaths, cell.inputs)
    for id in closure; append!(relpaths, byid[id].inputs); end
    assets = Tuple{String,UInt}[]
    for rel in sort!(unique!(relpaths))
        ap = isabspath(rel) ? rel : (isempty(base) ? rel : joinpath(base, rel))
        h = try; isfile(ap) ? hash(read(ap)) : UInt(0); catch; UInt(0); end
        push!(assets, (rel, h))
    end
    core = (cell.source, (:trace in cell.flags), depsrc, bvals)
    return string(hash(isempty(assets) ? core : (core..., assets)); base = 16)   # asset-free cells keep their old key
end

# ── Memo status for the UI cache badge ─────────────────────────────────────────────────────────
# A human-facing classification of a code cell's durable-cache disposition, for the notebook's cache
# badge. Returns (state, why): state ∈ "cacheable" | "uncacheable" | "" (not a badge target —
# markdown). Reuses the ACTUAL `_memoizable`/`_memo_key` decision so the badge can never disagree with
# whether the cell truly caches; it only ADDS the reason text. A RUNTIME verdict (restored/stored/
# handle from the run wire) takes precedence over this static view where present.
function _memo_status(report::Report, cell::Cell)
    cell.kind == CODE || return ("", "")
    # A pure `using`/`import` cell is namespace plumbing, not a caching STAGE — no badge (it's
    # transiently `:opaque` before macro refinement, so it would otherwise flip to a noisy reason).
    _is_pure_using(cell.source) && return ("", "")
    if _memoizable(cell)
        # Memoizable by shape — but an impure UPSTREAM still poisons the key (→ never cached). Use the
        # cheap poison check, NOT `_memo_key` (which hashes @asset files) — the badge runs per state push.
        _key_poisoned(report.byid, _dep_closure(report.byid, cell)) &&
            return ("uncacheable", "depends on an uncacheable upstream cell")
        return ("cacheable", "")
    end
    # Not memoizable — surface WHICH of `_memoizable`'s conditions failed (message only; the decision
    # already happened above, so this can't drift from it). Same order as `_memoizable`.
    :nocache in cell.flags && return ("uncacheable", "opted out with the `nocache` tag")
    :opaque in cell.flags && return ("uncacheable", "an unresolved `using`/macro barrier — its effects can't be tracked")
    eff = _cell_effect(cell)
    eff == VOLATILE && return ("uncacheable", "non-deterministic (e.g. `rand`/`time`) — a cached value would be stale")
    eff == RESOURCE && return ("uncacheable", "opens a live handle (DB/socket/file) — tag it `resource`; it re-opens each run")
    return ("uncacheable", "not a pure function of its source and inputs")
end

function eval_cell!(report::Report, cell::Cell, kernel::Kernel = InProcessKernel())
    if cell.kind == MARKDOWN
        exprs = _md_interp_exprs(cell.source)
        cell.interp = isempty(exprs) ? CellOutput[] : interpolate(kernel, report, exprs)
        mark_fresh!(cell)
        _emit_progress(report.id, cell)   # md renders instantly → patch it live (don't leave it "stale")
        return cell
    end
    # Bind cells are ordinary code now: `@bind x W(…)` runs, assigns `x`, and reports
    # its control through the capture channel (`output.binds`). No special path.
    mark_running!(cell)
    _emit_progress(report.id, cell)   # announce: this cell is now running (live status stream)
    # `trace` flag: wrap the source in `@trace begin … end` so eval returns a SlateTrace of
    # inline values (the cell's normal output is replaced by the trace table). Dependency
    # analysis is untouched — it parses the ORIGINAL `cell.source`, never this wrapped form.
    # Both kernels honour it: each notebook namespace has `@trace` injected (widgets.jl).
    # `begin ` joins on ONE line (no leading newline) so parsed line numbers align 1:1 with the
    # cell's source lines — the trace inspector maps each recorded value back to its source line.
    src = (:trace in cell.flags) ? string("@trace begin ", cell.source, "\nend") : cell.source
    # filename = `cell:<id>` → backtrace frames read `cell:<id>:N`, so an error in code defined in
    # ANOTHER cell still names its source cell (cross-cell error jump). Trace wrap shifts no lines
    # (`begin ` is on the cell's line 1), so the recorded line numbers stay 1:1 with the source.
    # names = writes ∪ mutates (mutates ⊆ writes natively — the union enforces the invariant the
    # entry's faithfulness depends on; see the server-side twin in _eval_one!).
    memo = (key = _memo_key(report, cell),
            names = unique!(String[string(w) for w in Iterators.flatten((cell.writes, cell.mutates))]),
            threshold = _MEMO_THRESHOLD_MS,
            force = false,
            # `cache` tag: a pipeline stage whose result must persist REGARDLESS of runtime — the
            # explicit opposite of `nocache` (auto-caching only catches cells over the threshold).
            always = (:cache in cell.flags))
    out = eval_capture(kernel, report, src, "cell:" * cell.id, memo)
    mark_result!(cell, out)
    cell.binds = out.binds
    _emit_progress(report.id, cell)   # announce: finished (the result/error can light up immediately)
    return cell
end

"""
    eval_report!(report; reset=false, kernel=InProcessKernel()) -> Report

Evaluate all code cells in document order through `kernel`. `reset=true` does a
full rebuild in a fresh namespace first. (No dependency pruning here — that's
[`eval_stale!`](@ref); this runs every code cell.)
"""
function eval_report!(report::Report; reset::Bool = false, kernel::Kernel = InProcessKernel())
    reset && reset!(kernel, report)
    prepare!(kernel, report)
    prewarm_usings!(report, kernel)   # precise graph BEFORE keys are computed → stable memo keys
    prewarm_macros!(report, kernel)   # …and macro-recovered bindings (package macros expand pre-run)
    for cell in report.cells
        eval_cell!(report, cell, kernel)
    end
    return report
end
