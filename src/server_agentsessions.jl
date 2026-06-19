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

