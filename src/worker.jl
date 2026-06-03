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

include(joinpath(@__DIR__, "capture.jl"))   # run_capture — uses EChart above

# Per-notebook execution namespace (warm; reset by replacing the module). `echart`
# is injected so cells can call it without importing anything.
function _new_ns()
    m = Module(:NB)
    Core.eval(m, :(const echart = $echart))
    Core.eval(m, :(const EChart = $EChart))
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

"GateTools exposed to the KaimonSlate server."
function tools()
    return KaimonGate.GateTool[
        KaimonGate.GateTool("__slate_eval", __slate_eval),
        KaimonGate.GateTool("__slate_assign", __slate_assign),
        KaimonGate.GateTool("__slate_reset", __slate_reset),
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
end

end # module SlateWorker
