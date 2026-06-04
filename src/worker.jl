# Per-notebook gate worker payload (Phase 2). Loaded *standalone* into a worker
# Julia process pinned to the notebook's project (`julia --project=<nb project>`,
# with KaimonGate on LOAD_PATH). It runs KaimonGate as a TCP gate exposing capture
# tools; the KaimonSlate extension drives it over the gate via `:tool_call`.
#
# This is NOT part of `using KaimonSlate` — the extension server never loads it,
# and KaimonSlate gains no KaimonGate dependency. Only the worker process loads it,
# via `include(".../worker.jl")` in its boot script. It shares `capture.jl` with
# the engine, so there is exactly one capture implementation.

module SlateWorker

import KaimonGate

# Minimal ECharts marker so notebooks can `echart(opt)`. Only the struct + helper
# live here (no JSON); the server JSON-encodes the option Dict. `capture.jl`
# detects `value isa EChart` and ships back the raw Dict.
struct EChart
    option::Any
end
echart(option::AbstractDict) = EChart(Dict{String,Any}(string(k) => v for (k, v) in option))

include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table — uses no deps; soft-detects Tables.jl
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query (provider registry)
include(joinpath(@__DIR__, "capture.jl"))   # run_capture — uses EChart + SlateTable above

# Per-notebook execution namespace (warm; reset by replacing the module). `echart`
# is injected so cells can call it without importing anything.
function _new_ns()
    m = Module(:NB)
    Core.eval(m, :(const echart = $echart))
    Core.eval(m, :(const EChart = $EChart))
    Core.eval(m, :(const slate_table = $slate_table))
    Core.eval(m, :(const SlateTable = $SlateTable))
    Core.eval(m, :(const slate_query = $slate_query))
    # Async reactivity over the gate: a cell's background task calls
    # `slate_refresh(:data)`, which PUBs on the gate stream. The KaimonSlate server
    # (subscribed) recomputes the readers of those vars and pushes a live update.
    Core.eval(m, :(const slate_refresh =
        $((vars...) -> KaimonGate._publish_stream("slate_refresh", join(string.(vars), ",")))))
    return m
end
const _NS = Ref{Module}(_new_ns())

# ── Capture tools (invoked by the server via synchronous :tool_call) ───────────
# Each returns a serialization-friendly value that rides back binary in the gate
# response's `value` field.

"Evaluate a cell's source in the warm namespace; return the wire-form capture."
__slate_eval(source::String) = run_capture(_NS[], source)

"Assign a `@bind` widget value into the namespace."
function __slate_assign(name::String, value)
    Core.eval(_NS[], Expr(:(=), Symbol(name), value))
    return true
end

"Discard the namespace (full rebuild)."
__slate_reset() = (_NS[] = _new_ns(); true)

# Flat scalar args only (the gate reflects the signature into an MCP schema — a
# nested-Dict argument doesn't validate, so we pass page params individually).
"Fetch one page of a registered paged table (server-paged tables / `slate_query`)."
__slate_table_page(table_id::String, page::Int, page_size::Int, sort_col::Int, sort_desc::Bool, search::String) =
    _provider_page(table_id, PageRequest(page, page_size, sort_col, sort_desc, search))

"Capture markdown `{{ }}` interpolation expressions (rich) — one wire-form each."
__slate_interp(exprs::Vector{String}) = [run_capture(_NS[], e) for e in exprs]

"GateTools exposed to the KaimonSlate server."
function tools()
    return KaimonGate.GateTool[
        KaimonGate.GateTool("__slate_eval", __slate_eval),
        KaimonGate.GateTool("__slate_assign", __slate_assign),
        KaimonGate.GateTool("__slate_reset", __slate_reset),
        KaimonGate.GateTool("__slate_table_page", __slate_table_page),
        KaimonGate.GateTool("__slate_interp", __slate_interp),
    ]
end

"""
    start(; host="127.0.0.1", port, stream_port)

Run the worker gate over TCP, exposing the capture tools. Blocks (this is the
worker process's main loop).
"""
function start(; host::String = "127.0.0.1", port::Int, stream_port::Int)
    KaimonGate.serve(; mode = :tcp, host = host, port = port, stream_port = stream_port,
                     tools = tools(), force = true, allow_mirror = false,
                     allow_restart = false, spawned_by = "slate")
    # `serve` runs the message loop on a spawned thread and returns — but this is
    # a non-interactive `-e` process, so we must block to keep it alive until a
    # remote `:shutdown` (which calls `exit(0)` from the gate task). Flush each
    # tick so stdout/stderr (block-buffered when piped, not a TTY) reaches the
    # parent's log reader live rather than only on exit/crash.
    while true
        flush(stdout); flush(stderr)
        sleep(1)
    end
end

end # module SlateWorker
