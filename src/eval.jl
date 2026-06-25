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
    cb = get(_REFRESH_REGISTRY, report_id, nothing)
    cb === nothing || cb(Symbol[Symbol(v) for v in vars])
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
        slate_query = slate_query, slate_refresh = (vars...) -> _do_refresh(rid, vars))
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
function _eval_capture(mod::Module, source::AbstractString)
    r = run_capture(mod, source)
    chunks = MimeChunk[MimeChunk(m, bytes) for (m, bytes) in r.mime]
    binds = BindSpec[BindSpec(b.name, b.kind, b.params, b.value) for b in r.binds]
    return CellOutput(r.stdout, chunks, r.echarts, r.tables, binds, r.value_repr, r.exception,
                      r.backtrace, r.duration_ms, collect(r.trace))
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
eval_capture(::InProcessKernel, report::Report, source::AbstractString) =
    _eval_capture(report_module(report), source)

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
function eval_cell!(report::Report, cell::Cell, kernel::Kernel = InProcessKernel())
    if cell.kind == MARKDOWN
        exprs = _md_interp_exprs(cell.source)
        cell.interp = isempty(exprs) ? CellOutput[] : interpolate(kernel, report, exprs)
        cell.state = FRESH
        return cell
    end
    # Bind cells are ordinary code now: `@bind x W(…)` runs, assigns `x`, and reports
    # its control through the capture channel (`output.binds`). No special path.
    cell.state = RUNNING
    # `trace` flag: wrap the source in `@trace begin … end` so eval returns a SlateTrace of
    # inline values (the cell's normal output is replaced by the trace table). Dependency
    # analysis is untouched — it parses the ORIGINAL `cell.source`, never this wrapped form.
    # Both kernels honour it: each notebook namespace has `@trace` injected (widgets.jl).
    # `begin ` joins on ONE line (no leading newline) so parsed line numbers align 1:1 with the
    # cell's source lines — the trace inspector maps each recorded value back to its source line.
    src = (:trace in cell.flags) ? string("@trace begin ", cell.source, "\nend") : cell.source
    cell.output = eval_capture(kernel, report, src)
    cell.binds = cell.output.binds
    cell.state = cell.output.exception === nothing ? FRESH : ERRORED
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
    for cell in report.cells
        eval_cell!(report, cell, kernel)
    end
    return report
end
