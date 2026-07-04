# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Agent sessions (consumer of Kaimon's agent service) ──────────────────────
#
# Kaimon owns the AI agent: it spawns/owns a headless `claude`, normalizes its
# output to a vendor-neutral `{kind,turn,data}` event model, and streams those on
# the gate event bus channel `agent:<id>` (see Kaimon AGENT_SESSION_SERVICE_*.md).
# We are a *consumer*: drive it with the `agent_*` MCP tools (via the gate service
# endpoint) and relay its stream onto the matching notebook's SSE as `agent:<json>`.
#
# Calling the core agent tools needs `Kaimon.KaimonGate.call_tool` — present only
# inside the extension subprocess. Standalone (`serve_notebook`) has no Kaimon, so
# chat degrades to a friendly "unavailable".

# agent_id → notebook, so a gate-bus `agent:<id>` event finds its SSE clients.
const _AGENT_ROUTES = Dict{String,LiveNotebook}()
const _AGENT_LOCK = ReentrantLock()
# agent_id → crew label ("" = default/solo). Lets the relay tag each event with the
# speaking crew member so the UI can lane multiple agents and replay stays attributed.
const _AGENT_CREW = Dict{String,String}()
# notebook id → buffered relayed envelopes (crew-tagged, in arrival order), so a
# browser reload can replay the whole conversation across ALL crew agents (agentMsgs
# is in-memory JS, lost on reload). One ordered ring per notebook. Capped.
const _AGENT_LOG = Dict{String,Vector{String}}()
const _AGENT_LOG_CAP = 4000

# Durable chat transcript: the in-memory `_AGENT_LOG` replays across a browser reload,
# but is lost on a SERVER restart. Mirror it to a per-notebook JSONL (keyed by abspath,
# in the cache dir) so the conversation survives a restart too. Loaded on open; appended
# as each (non-delta) envelope is relayed; compacted to the cap; wiped by "clear chat".
_chat_log_file(path) = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                                "kaimonslate", "chat", SlateHistory._sha(abspath(String(path)))[1:16] * ".jsonl")
function _load_chat_log!(nb::LiveNotebook)
    f = _chat_log_file(nb.path)
    isfile(f) || return
    try
        lines = filter(!isempty, readlines(f))
        length(lines) > _AGENT_LOG_CAP && (lines = last(lines, _AGENT_LOG_CAP))
        lock(_AGENT_LOCK) do; _AGENT_LOG[nb.id] = collect(String, lines); end
    catch e
        @warn "slate: chat-log load failed" exception = (e, catch_backtrace())
    end
    return nothing
end
_append_chat_log(nb::LiveNotebook, line::AbstractString) =
    (f = _chat_log_file(nb.path); try; mkpath(dirname(f)); open(f, "a") do io; println(io, line); end; catch; end; nothing)
_rewrite_chat_log(nb::LiveNotebook, lines) =
    (f = _chat_log_file(nb.path); try; mkpath(dirname(f)); open(f, "w") do io; for l in lines; println(io, l); end; end; catch; end; nothing)
function _clear_chat_log!(nb::LiveNotebook)
    lock(_AGENT_LOCK) do; delete!(_AGENT_LOG, nb.id); end
    f = _chat_log_file(nb.path)
    try; isfile(f) && rm(f); catch; end
    return nothing
end

# Buffer a relayed envelope for reload-replay and mirror it to the durable transcript.
# The live SSE push (`_broadcast`) is the caller's job — this is only the persistence half,
# shared by the built-in relay (`relay_agent_event`) and the external-tool surfacer.
function _buffer_agent_log!(nb::LiveNotebook, s::AbstractString)
    compact = false; bufcopy = String[]
    lock(_AGENT_LOCK) do
        buf = get!(_AGENT_LOG, nb.id, String[])
        push!(buf, s)
        length(buf) > _AGENT_LOG_CAP && (popfirst!(buf); compact = true; bufcopy = copy(buf))
    end
    compact ? _rewrite_chat_log(nb, bufcopy) : _append_chat_log(nb, s)
    return nothing
end

# ── External tool calls (surfaced in the chat panel) ─────────────────────────
#
# The built-in crew's tool calls stream into the chat pane over the `agent:<id>` gate bus
# (relay_agent_event). An EXTERNAL driver — an outside MCP client, or an agent Kaimon spawned
# for a different notebook — reaches the same `slate.*` tools directly, on its own anonymous
# session, with no event stream. So the user never sees an outside agent editing their cells.
# We close that gap: emit the SAME `tool_use`/`tool_result` envelopes here, tagged
# `external:true` so the UI badges them, and buffer them alongside the crew's for replay.

# A unique id for a synthetic (external) tool-call envelope — external clients carry no
# Kaimon toolCallId, so we mint our own. `time_ns` keeps it unique across a server restart,
# so a replayed transcript never merges a fresh call onto a persisted one with the same id.
const _EXT_TOOL_SEQ = Threads.Atomic{Int}(0)
_ext_tool_id() = "ext-" * string(time_ns(), base = 36) * "-" *
                 string(Threads.atomic_add!(_EXT_TOOL_SEQ, 1), base = 36)

"""
    emit_external_tool!(nb, toolname, args, result; ok=true)

Surface a `slate.*` tool call made by an external driver as a tool entry in the chat panel,
so the user SEES what an outside agent is doing to their notebook. Emits a `tool_use` +
`tool_result` pair — the same shape the built-in relay produces — tagged `external:true`, then
broadcasts and buffers both (so a reload replays them). `args` becomes the call's `rawInput`
(the front-end mines it for the code preview + the navigate-to-cell chip); `result` is the
tool's return string; `ok=false` renders the row as an error.
"""
# Build the `tool_use` + `tool_result` envelope pair (as JSON strings) for one external tool
# call — the same shape `agentEvent` consumes, sharing `toolCallId` so the pane pairs them.
# Pure (`id` passed in) so it can be unit-tested without a live notebook.
function _external_tool_envelopes(id::AbstractString, toolname::AbstractString,
                                  args::AbstractDict, result::AbstractString; ok::Bool = true)
    # title == "slate_<tool>" so the pane's `_prettyTool` maps it to its icon + label.
    call = Dict{String,Any}("toolCallId" => id, "title" => "slate_$toolname",
                            "kind" => "slate_$toolname", "rawInput" => args)
    use = JSON.json(Dict{String,Any}("kind" => "tool_use", "external" => true,
                                     "data" => Dict{String,Any}("call" => call)))
    upd = Dict{String,Any}("toolCallId" => id, "status" => ok ? "completed" : "failed",
                           "content" => Any[Dict{String,Any}("content" =>
                               Dict{String,Any}("type" => "text", "text" => String(result)))])
    res = JSON.json(Dict{String,Any}("kind" => "tool_result", "external" => true,
                                     "data" => Dict{String,Any}("update" => upd)))
    return (use, res)
end

function emit_external_tool!(nb::LiveNotebook, toolname::AbstractString, args::AbstractDict,
                             result::AbstractString; ok::Bool = true)
    use, res = _external_tool_envelopes(_ext_tool_id(), toolname, args, result; ok = ok)
    for s in (use, res)
        _broadcast(nb, "agent:" * s)
        _buffer_agent_log!(nb, s)
    end
    return nothing
end

"""
    note_external_tool!(nb, agent_id, toolname, args, result; ok=true)

Gate on caller identity, then surface the write if it came from outside this notebook's crew.
`agent_id` is `KaimonGate.current_agent_id()` for the call: `""` for an outside MCP client
(always external), or the owning Kaimon agent's id — external only when it is NOT one of THIS
notebook's crew agents, whose calls the `agent:<id>` relay already streams into the pane
(surfacing those here would double them).
"""
function note_external_tool!(nb::LiveNotebook, agent_id::AbstractString, toolname::AbstractString,
                             args::AbstractDict, result::AbstractString; ok::Bool = true)
    if !isempty(agent_id)
        is_crew = lock(_AGENT_LOCK) do; String(agent_id) in values(nb.agents); end
        is_crew && return nothing
    end
    try
        emit_external_tool!(nb, toolname, args, result; ok = ok)
    catch e
        @warn "slate: external-tool surface failed" exception = (e, catch_backtrace())
    end
    return nothing
end

_agent_available() = isdefined(Main, :Kaimon) &&
    isdefined(getfield(Main, :Kaimon), :KaimonGate) &&
    isdefined(getfield(Main, :Kaimon).KaimonGate, :call_tool)

# Call a core Kaimon `agent_*` tool over the gate service endpoint. The handlers
# return a JSON string on success (e.g. `{"agent_id":…}`/`{"turn":…}`) or a plain
# `"Error …"` string on failure — parse the former, raise the latter.
function _agent_call(tool::Symbol, args::Dict{String,Any})
    raw = getfield(Main, :Kaimon).KaimonGate.call_tool(tool, args)
    s = raw isa AbstractString ? String(raw) : string(raw)
    parsed = try; JSON.parse(s); catch; nothing; end
    (parsed isa AbstractDict) || error(s)   # non-JSON ⇒ the handler's error text
    return parsed
end

