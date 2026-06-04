# Isolated-module evaluation (engine, §6/D2). Included into `module ReportEngine`.
#
# Code cells execute in document order inside a per-report `Module()`. The process
# stays warm (all JIT-compiled methods kept); only the namespace is fresh, so the
# report is reproducible without losing the warm benefit. This slice captures
# stdout + a text/plain value repr + errors; MIME/figure capture (§7) and the
# dependency model (§6) layer on later without changing this loop.

export eval_report!, eval_cell!, report_module, reset_module!
export Kernel, InProcessKernel, run_capture, shutdown!
export register_refresh!, unregister_refresh!

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

# A fresh report namespace with the report-builder helpers (e.g. `echart`)
# injected, so cells can call them without importing anything.
#
# `@bind` is injected as a real (no-op-ish) macro: recognized bind/group cells are
# intercepted by the engine and never run as code, but a cell that *contains*
# `@bind` yet isn't recognized as a pure bind cell (e.g. mixed code) would
# otherwise hit `UndefVarError: @bind`. Here it expands to assigning the variable
# its widget's default (extracted syntactically — no need for `Slider` et al. to
# exist), so such cells evaluate harmlessly instead of erroring.
function _new_module(report::Report)
    m = Module(Symbol(:Report_, report.id))
    Core.eval(m, :(const echart = $(echart)))
    Core.eval(m, :(const EChart = $(EChart)))
    Core.eval(m, :(const slate_table = $(slate_table)))
    Core.eval(m, :(const SlateTable = $(SlateTable)))
    Core.eval(m, :(const slate_query = $(slate_query)))
    Core.eval(m, :(const __slate_bind_default = $(_bind_default)))
    Core.eval(m, :(macro bind(name, widget)
        esc(Expr(:(=), name, __slate_bind_default(widget)))
    end))
    # `slate_refresh(:a, :b)` — from a cell's async task, announce that globals
    # a/b changed so the server recomputes their readers and pushes a live update.
    let rid = report.id
        Core.eval(m, :(const slate_refresh = $((vars...) -> _do_refresh(rid, vars))))
    end
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
    return CellOutput(r.stdout, chunks, r.echarts, r.tables, r.value_repr, r.exception,
                      r.backtrace, r.duration_ms)
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

"Assign `name = value` (a `@bind` widget value) into the kernel's namespace."
assign!(::InProcessKernel, report::Report, name::Symbol, value) =
    Core.eval(report_module(report), Expr(:(=), name, value))

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
    isempty(cell.binds) && (cell.binds = parse_binds(cell.source))   # lazily detect
    if !isempty(cell.binds)
        # bind/group cells aren't run as code — each widget value is assigned directly
        for b in cell.binds
            assign!(kernel, report, b.name, b.value)
        end
        cell.state = FRESH
        return cell
    end
    cell.state = RUNNING
    cell.output = eval_capture(kernel, report, cell.source)
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
