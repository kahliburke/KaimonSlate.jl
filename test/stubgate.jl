# Stands in for `KaimonGate.GateTool` so `create_tools` can be built without Kaimon loaded. The
# handlers reach the gate through `parentmodule(GateTool)`, so the caller/agent accessors live here.
module StubGate
struct GateTool
    name::String
    handler::Function
    timeout_ms::Union{Nothing,Int}
end
# Mirrors KaimonGate's constructor — `create_tools` declares a silence budget on the tools that
# block silently. There is no caller-facing override by design.
GateTool(name::AbstractString, handler::Function;
         timeout_ms::Union{Nothing,Integer} = nothing) =
    GateTool(String(name), handler, timeout_ms === nothing ? nothing : Int(timeout_ms))
current_caller() = nothing
current_agent_id() = nothing
end
