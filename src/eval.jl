# Isolated-module evaluation (engine, §6/D2). Included into `module ReportEngine`.
#
# Code cells execute in document order inside a per-report `Module()`. The process
# stays warm (all JIT-compiled methods kept); only the namespace is fresh, so the
# report is reproducible without losing the warm benefit. This slice captures
# stdout + a text/plain value repr + errors; MIME/figure capture (§7) and the
# dependency model (§6) layer on later without changing this loop.

export eval_report!, eval_cell!, report_module, reset_module!
export Kernel, InProcessKernel, run_capture, shutdown!
export register_refresh!, unregister_refresh!, register_srcchange!, unregister_srcchange!, revise_apply!
export register_progress!, unregister_progress!, register_runbatch!, unregister_runbatch!
export register_userprog!, unregister_userprog!
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
    for c in report.cells
        c.state = STALE
        c.output = nothing
    end
    return report.mod
end

# Run a cell and capture its output. The capture machinery lives in `capture.jl`
# (shared with the gate worker) and returns a wire-form NamedTuple; here we wrap
# it into the engine's `CellOutput` (mapping mime tuples → `MimeChunk`).
function _eval_capture(mod::Module, source::AbstractString, filename::AbstractString = "string")
    r = run_capture(mod, source, filename)
    chunks = MimeChunk[MimeChunk(m, bytes) for (m, bytes) in r.mime]
    binds = BindSpec[BindSpec(b.name, b.kind, b.params, b.value) for b in r.binds]
    overflow = hasproperty(r, :overflow) ? collect(r.overflow) : Any[]   # full results saved to disk (gate worker too)
    animations = hasproperty(r, :animations) ? collect(r.animations) : Any[]
    return CellOutput(r.stdout, chunks, r.echarts, r.tables, binds, r.value_repr, r.exception,
                      r.backtrace, r.duration_ms, collect(r.trace), r.stderr, overflow, animations)
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

"Release a kernel's resources (e.g. kill a gate worker). No-op for in-process."
shutdown!(::Kernel) = nothing

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

"Evaluate `source` in the kernel and capture stdout + rich output → `CellOutput`."
eval_capture(::InProcessKernel, report::Report, source::AbstractString, filename::AbstractString = "string") =
    _eval_capture(report_module(report), source, filename)

# Memo-aware entry (5-arg `memo` = (; key, names, threshold)). Default: ignore caching and just
# evaluate — only the gate kernel (real notebooks) implements durable memoization. Keeps in-process
# and test kernels working unchanged.
eval_capture(k::Kernel, report::Report, source::AbstractString, filename::AbstractString, memo) =
    eval_capture(k, report, source, filename)

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
    macroexpand_cells(kernel, report, srcs) -> Dict{String,String}

Macro-expand each cell source (`id => source`) in the namespace where cells evaluate —
recursively, NEVER evaluating — and return `id => expanded source string`. Cells whose
expansion fails are omitted (the caller keeps its conservative static analysis). The gate
kernel forwards to its worker, where the notebook's macros are actually defined.
"""
function macroexpand_cells(::InProcessKernel, report::Report, srcs::AbstractDict)
    m = report_module(report)
    out = Dict{String,String}()
    for (id, src) in srcs
        s = _expand_cell_source(m, String(src))
        s === nothing || (out[String(id)] = s)
    end
    return out
end

"""
    project_deps(kernel, report) -> Vector{Dict}

The notebook project's direct dependencies as `{name, version}` (for eager docs
auto-indexing). The gate kernel reads its worker's active project; in-process has no
distinct project, so it returns nothing (only `using`'d packages get indexed there).
"""
project_deps(::InProcessKernel, ::Report) = Dict{String,Any}[]

# In-process has no notebook/parent split (cells run in the host's active project).
env_info(::InProcessKernel, ::Report) = (notebook = (path = "", deps = Dict{String,Any}[]), parent = nothing)
bundle_info(::InProcessKernel, ::Report) = (projectdir = "", pathdeps = NamedTuple[])

"""
    pkg_op(kernel, report, op, name) -> Dict{String,Any}

Add (`op="add"`) or remove (`op="rm"`) a package in the kernel's active project — the
notebook's own dependency environment. The gate kernel mutates its worker's project;
the in-process kernel has NO distinct notebook project (cells eval in the extension), so
it refuses rather than touch the host environment. Returns `{ok, message}`.
"""
pkg_op(::InProcessKernel, ::Report, ::AbstractString, ::AbstractString) =
    Dict{String,Any}("ok" => false,
        "message" => "This notebook isn't inside a Julia project (in-process kernel), so it has no package environment to manage. Open it inside a project directory to add packages.")

"""
    eval_cell!(report, cell, kernel=InProcessKernel()) -> Cell

Evaluate one cell through `kernel`. Markdown cells are inert (marked `FRESH`). A
code cell becomes `FRESH` on success or `ERRORED` if it threw; the error is
captured, never propagated, so one bad cell doesn't abort the report.
"""
# ── Durable memoization key (server side) ─────────────────────────────────────────────────────
const _MEMO_THRESHOLD_MS = 400.0    # only cells slower than this are worth persisting to disk

# A cell is memoizable if its result is a pure function of its source + upstream sources + bind
# inputs. Excluded: markdown, `using`/`import` barriers (:opaque — namespace effects not captured by
# `writes`), control-DECLARING cells (their value comes from the UI), and explicit opt-outs.
function _memoizable(cell::Cell)
    cell.kind == CODE || return false
    (:opaque in cell.flags || :nocache in cell.flags || :volatile in cell.flags) && return false
    # A refined `using`/`import` cell is no longer :opaque, but restoring cached export BINDINGS is
    # not the same as executing the `using` (method-table effects, load order) — never memoize it.
    isempty(cell.provides) || return false
    # Same for a global-theme setter (`set_theme!`): its effect is process state, not a binding —
    # a restore would skip applying the theme. (Marked by the synthetic `_THEME_SENTINEL` write.)
    _THEME_SENTINEL in cell.writes && return false
    return isempty(cell.binds)
end

# A total-ish cache key: this cell's source + the sources of its transitive upstream cells + the
# values of any @bind variables in the read-closure. The worker folds in the Revise'd `src/` digest
# and the resolved Manifest, completing the key so a src/dep/package change invalidates the entry.
function _memo_key(report::Report, cell::Cell)
    _memoizable(cell) || return ""
    byid = report.byid
    closure = Set{String}(); stack = collect(cell.deps)
    while !isempty(stack)
        id = pop!(stack); (id in closure || !haskey(byid, id)) && continue
        push!(closure, id); union!(stack, byid[id].deps)
    end
    # Impurity propagates: the key digests upstream SOURCES, so it's only total if every upstream
    # value is a function of its source. A `nocache`/`volatile` upstream (impure by declaration —
    # re-runs produce fresh values from the same source) or an :opaque barrier (include(): effects
    # from outside the source) breaks that — restoring downstream against a re-run impure producer
    # would silently resurrect results computed from the PREVIOUS run's values. Unkeyable → no memo.
    for id in closure
        f = byid[id].flags
        (:nocache in f || :volatile in f || :opaque in f) && return ""
    end
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

function eval_cell!(report::Report, cell::Cell, kernel::Kernel = InProcessKernel())
    if cell.kind == MARKDOWN
        exprs = _md_interp_exprs(cell.source)
        cell.interp = isempty(exprs) ? CellOutput[] : interpolate(kernel, report, exprs)
        cell.state = FRESH
        _emit_progress(report.id, cell)   # md renders instantly → patch it live (don't leave it "stale")
        return cell
    end
    # Bind cells are ordinary code now: `@bind x W(…)` runs, assigns `x`, and reports
    # its control through the capture channel (`output.binds`). No special path.
    cell.state = RUNNING
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
    memo = (key = _memo_key(report, cell),
            names = String[string(w) for w in cell.writes],
            threshold = _MEMO_THRESHOLD_MS,
            force = false,
            # `cache` tag: a pipeline stage whose result must persist REGARDLESS of runtime — the
            # explicit opposite of `nocache` (auto-caching only catches cells over the threshold).
            always = (:cache in cell.flags))
    cell.output = eval_capture(kernel, report, src, "cell:" * cell.id, memo)
    cell.binds = cell.output.binds
    cell.state = cell.output.exception === nothing ? FRESH : ERRORED
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
