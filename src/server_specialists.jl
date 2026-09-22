# ── Specialists: narrow agents, summoned into a notebook ──────────────────────────────────────────
#
# A SPECIALIST is an agent given one job, the tools for exactly that job, and nothing else. The
# narrowness is the design rather than a safety rail: an agent that can only step, look and
# evaluate has nothing to do but debug, and that is what makes it good at it. It is also why a
# specialist must be able to ASK — it cannot know why the notebook exists, and cannot find out.
#
# Debugging is ONE such job. Profiling, data exploration, test writing and refactoring are the same
# shape with a different brief and a different verb list, so none of that shape is written here in
# terms of debugging. A new specialist is a `Specialist` value and a `register_specialist!` call;
# it needs no new machinery, no new routes and no new state.
#
# What IS general:
#   • the role registry, and resolving its verbs to the tool names an agent will see
#   • summoning: spawn a crew member with that brief and allowlist, hand it an opening turn
#   • asking: a blocking request that reaches BOTH the orchestrator and the person, either of
#     whom can answer
#   • the orchestrator: whoever briefed it, paged with a turn rather than left to poll
#   • signing off: it decides it is finished, and says what it found
#
# What is NOT general, and stays with each application: the resource it works on (the debugger's
# stepping session), the rules for sharing that resource, and the surface it is watched through.

"""
    Specialist(name; brief, verbs, briefing, permission)

One kind of specialist.

`name` is the crew label — it lanes the agent in the chat, keys its state, and is how everything
else refers to it. `brief` is the standing instruction it is spawned with. `verbs` are the BARE
tool names it may call; the namespace is applied at summon time, because this checkout serves as
`slate_dbg` and an installed one as `slate`, so a written-down tool name is right in exactly one
of them. `briefing(nb, subject, task) -> String` builds the opening turn from live context — the
part that makes a specialist start oriented rather than surveying. `permission` should be a preset
with no allowances of its own — `specialist`, which is also the only one that denies the CLI's own
shell and file tools. A preset that allows anything is UNIONED with `verbs` on the Claude Code path,
which widens the allowlist and undoes the narrowness that is the whole reason for the role.
"""
struct Specialist
    name::String
    brief::String
    verbs::Vector{String}
    briefing::Any          # (nb, subject, task) -> String
    permission::String
end
Specialist(name::AbstractString; brief::AbstractString, verbs::Vector{String}, briefing,
           permission::AbstractString = "specialist") =
    Specialist(String(name), String(brief), verbs, briefing, String(permission))

const SPECIALISTS = Dict{String,Specialist}()

"Register a kind of specialist. Re-registering replaces, so a reload does not stack duplicates."
register_specialist!(s::Specialist) = (SPECIALISTS[s.name] = s)
specialist(name::AbstractString) = get(SPECIALISTS, String(name), nothing)
specialist_names() = sort!(collect(keys(SPECIALISTS)))

"""
The gate namespace this extension is serving under, which prefixes every tool name an agent sees.

Read at call time, never written down: an allowlist naming tools that do not exist does not fail,
it silently stops restricting — which is how the first specialist came to call a tool that was
never meant to be in its world.
"""
function gate_namespace()
    ns = try
        String(Main.Kaimon.KaimonGate._session_namespace())
    catch
        ""
    end
    return isempty(ns) ? "slate" : ns
end

"The verbs of `s` as the agent will see them: `<namespace>_<verb>`."
tool_names(s::Specialist) = String[gate_namespace() * "_" * v for v in s.verbs]

# ── per (notebook, role) state ────────────────────────────────────────────────────────────────────
# Keyed by BOTH, so one notebook can host several specialists at once — a debugger and a profiler
# looking at the same cell is a thing to want, not a collision to prevent.

"""
Push a specialist-framework event to every open page, tagged with the role it belongs to.

Its own channel, not the debugger's. Everything here — a blocked question, a sign-off, a
specialist arriving — happens to every kind of specialist, and pushing it on `debug:` gave it only
a debugger-shaped place to appear. A surface listens on `specialist:` and filters on `role`, so a
profiler's question reaches a profiler's pane without either knowing about the other.
"""
function broadcast_specialist(nb::LiveNotebook, role::AbstractString, payload::Dict{String,Any})
    try
        _broadcast(nb, "specialist:" * JSON.json(merge(payload, Dict("role" => String(role)))))
    catch
    end
    return nothing
end

const _SPEC_LOCK = ReentrantLock()
const _SPEC_BRIEFING = Dict{Tuple{String,String},String}()   # (nb, role) → last opening turn
const _SPEC_ORCH = Dict{Tuple{String,String},String}()       # (nb, role) → orchestrator agent id
const _SPEC_SIGNOFF = Dict{String,Tuple{Float64,String,String,String}}()  # nb → (when, role, who, text)

specialist_here(nb::LiveNotebook, role::AbstractString) = get(nb.agents, String(role), "")

"""
    summon!(nb, role; subject, model, task, orchestrator) -> Dict

Bring a specialist of kind `role` into this notebook and hand it `subject`.

`model` is any id the chat picker offers — an `acp:<agent>:<model>` id runs it on an ACP backend,
which includes Claude Code itself. The turn is sent asynchronously: its reasoning and every tool
call stream into the notebook's chat as it works, which is the point of summoning one rather than
requesting a report.

`orchestrator` is the agent id doing the summoning. Registered only if it is a live Kaimon agent,
because the value of knowing it is being able to hand it a turn; an id that cannot be sent to is
worse than none, since a question would look delivered and never arrive.
"""
function summon!(nb::LiveNotebook, role::AbstractString; subject::AbstractString = "",
                 model::AbstractString = "", task::AbstractString = "",
                 orchestrator::AbstractString = "")
    s = specialist(role)
    s === nothing && return Dict{String,Any}("ok" => false,
        "error" => "no specialist kind '$role' — known: " * join(specialist_names(), ", "))
    # An explicit model wins; else the role's configured default; else the notebook's own agent
    # model, which is what `_ensure_agent!` falls back to for an empty string.
    m = isempty(strip(String(model))) ? specialist_model(s.name) : String(model)
    aid = _ensure_agent!(nb; crew = s.name, model = m, permission = s.permission,
                         system_prompt = s.brief, allowed_tools = tool_names(s))
    turn = Base.invokelatest(s.briefing, nb, String(subject), String(task))
    lock(_SPEC_LOCK) do; _SPEC_BRIEFING[(nb.id, s.name)] = turn; end
    register_orchestrator!(nb, s.name, orchestrator)
    _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => turn))
    broadcast_specialist(nb, s.name, Dict{String,Any}("specialist" => Dict{String,Any}(
        "agent_id" => aid, "crew" => s.name, "cell" => String(subject), "model" => m)))
    return Dict{String,Any}("ok" => true, "agent_id" => aid, "crew" => s.name,
                            "cell" => String(subject))
end

"""
    brief_of(nb, role) -> Dict

Everything a specialist was given: standing instructions, the tools it may call, and its opening
turn. The first two go in at spawn and never appear on the event bus, so without this they are
invisible — and an answer cannot be judged without seeing the question.
"""
function brief_of(nb::LiveNotebook, role::AbstractString)
    s = specialist(role)
    s === nothing && return Dict{String,Any}("error" => "no specialist kind '$role'")
    return Dict{String,Any}(
        "role" => s.name, "system" => s.brief, "tools" => tool_names(s),
        "opening" => lock(_SPEC_LOCK) do; get(_SPEC_BRIEFING, (nb.id, s.name), ""); end,
        "agent" => specialist_here(nb, s.name),
        "orchestrator" => orchestrator_of(nb, s.name))
end

# ── the orchestrator ──────────────────────────────────────────────────────────────────────────────

orchestrator_of(nb::LiveNotebook, role::AbstractString) =
    lock(_SPEC_LOCK) do; get(_SPEC_ORCH, (nb.id, String(role)), ""); end

"Remember who briefed this specialist, if they are an agent that can be sent to."
function register_orchestrator!(nb::LiveNotebook, role::AbstractString, aid::AbstractString)
    isempty(aid) && return false
    alive = try
        String(get(_agent_call(:agent_status, Dict{String,Any}("agent_id" => String(aid))), "status", "")) != "dead"
    catch
        false   # not a Kaimon agent at all (an external MCP client) — it will have to poll
    end
    alive && lock(_SPEC_LOCK) do; _SPEC_ORCH[(nb.id, String(role))] = String(aid); end
    return alive
end

"""
    tell!(nb, role, text) -> Dict

Send a specialist a turn.

Whether a message can land DURING a turn is the agent's own capability, not a fact about the
protocol. An agent that queues prompts takes it immediately; one that does not loses the reply in
progress when a second prompt arrives, so for those the message is refused and the caller told to
wait or interrupt. Asking beats assuming: refusing for everyone would borrow one agent's
limitation and impose it on every backend.
"""
function tell!(nb::LiveNotebook, role::AbstractString, text::AbstractString)
    aid = specialist_here(nb, role)
    isempty(aid) && return Dict{String,Any}("ok" => false,
                                            "error" => "no '$role' here — summon one first")
    st = try
        _agent_call(:agent_status, Dict{String,Any}("agent_id" => aid))
    catch
        Dict{String,Any}()
    end
    status = String(get(st, "status", ""))
    status == "dead" && return Dict{String,Any}("ok" => false, "error" => "the $role is gone — summon another")
    if status == "working" && get(st, "queues_prompts", false) !== true
        return Dict{String,Any}("ok" => false, "busy" => true,
                                "error" => "it is mid-turn and this agent does not queue prompts; " *
                                           "wait for it to finish, or interrupt it first")
    end
    _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => String(text)))
    return Dict{String,Any}("ok" => true, "agent_id" => aid)
end

"""
    sign_off!(nb, role, who, summary)

A specialist saying it is finished, and what it found.

Deciding to stop is its own call, so this is a report rather than a request. It goes to the
notebook's chat as a message from that agent — the same place its reasoning has been streaming —
so the findings survive in the transcript rather than living only in a tool result that whoever
asked may never read.
"""
function sign_off!(nb::LiveNotebook, role::AbstractString, who::AbstractString, summary::AbstractString)
    text = isempty(strip(summary)) ? "Finished, with nothing to report." : String(summary)
    lock(_SPEC_LOCK) do; _SPEC_SIGNOFF[nb.id] = (time(), String(role), String(who), text); end
    try
        env = JSON.json(Dict{String,Any}(
            "kind" => "assistant", "external" => true, "crew" => String(role),
            "data" => Dict{String,Any}("text" => "🐞 " * text)))
        _broadcast(nb, "agent:" * env)
        _buffer_agent_log!(nb, env)
    catch e
        @debug "specialist: sign-off could not reach the chat" exception = e
    end
    broadcast_specialist(nb, role, Dict{String,Any}("signoff" => Dict{String,Any}(
        "role" => String(role), "from" => String(who), "text" => text)))
    return nothing
end

last_signoff(nb::LiveNotebook) = lock(_SPEC_LOCK) do; get(_SPEC_SIGNOFF, nb.id, nothing); end

# ── asking, and waiting for the answer ────────────────────────────────────────────────────────────
#
# A specialist is deliberately short-sighted: it knows the job in front of it and nothing about why
# the notebook exists. So it has to be able to ask, and then WAIT — an answer it does not wait for
# is advice it cannot act on.
#
# One primitive covers both things any specialist needs to ask for: a question, and permission to
# disturb something it does not own. Both block the caller's tool call on a channel; both surface
# in the notebook AND page the orchestrator, because a request nobody can see is a hang.

const ASK_TIMEOUT = 900.0   # 15 minutes: long enough for a person to come back from lunch

mutable struct Ask
    id::String
    role::String        # which specialist is asking
    kind::String        # "question" | "consent" | "choice"
    from::String        # its agent id
    text::String
    # A "choice" offers these instead of a text box. Two beats of the same shape need it — pick a
    # model from a list, and decide whether to apply a proposed fix — and both are worse as free
    # text: an agent that has already worked out the options should not make you retype one, and a
    # typo in a model name is a failure you find out about a minute later.
    #
    # Each is `(value, label)`. The VALUE is what the asker receives, so it can be an id while the
    # label reads like a sentence.
    options::Vector{Tuple{String,String}}
    answer::Channel{String}
end

const _ASKS = Dict{String,Dict{String,Ask}}()   # nb.id → ask id → ask
const _ASK_SEQ = Ref(0)

ask_json(a::Ask) = Dict{String,Any}("id" => a.id, "role" => a.role, "kind" => a.kind,
                                    "from" => a.from, "text" => a.text,
                                    "options" => [Dict{String,Any}("value" => v, "label" => l)
                                                  for (v, l) in a.options])
asks_json(nb::LiveNotebook) = lock(_SPEC_LOCK) do
    [ask_json(a) for a in values(get(_ASKS, nb.id, Dict{String,Ask}()))]
end

# A default model per ROLE, so a specialist can be given a different one from the notebook agent
# without naming it at every summon. Which model suits a role is a property OF the role — a
# debugger reading traces and a reviewer reading prose are not obviously the same job — and it is
# not something to re-decide each time you need one.
const SPECIALIST_MODELS = Dict{String,String}()
const _SPECIALIST_MODELS_PERSIST = Ref{Any}(nothing)

"The model a role runs on, or `\"\"` to follow the notebook's own agent model."
specialist_model(role::AbstractString)::String =
    lock(_SPEC_LOCK) do; String(get(SPECIALIST_MODELS, String(role), "")); end

function set_specialist_model!(role::AbstractString, model::AbstractString)
    m = String(strip(model))
    lock(_SPEC_LOCK) do
        isempty(m) ? delete!(SPECIALIST_MODELS, String(role)) : (SPECIALIST_MODELS[String(role)] = m)
    end
    p = _SPECIALIST_MODELS_PERSIST[]
    p === nothing || (try; p(copy(SPECIALIST_MODELS)); catch e; @warn "slate: could not persist the role model" exception = e; end)
    return m
end

# Whether only the DEBUG specialist may drive a debug session. Named for the role it gates rather
# than for "specialist" in general: with more than one role registered, a policy about one of them
# has to say which. A live ref with a persist hook, the same way RUNON_DEFAULT is — NotebookServer
# has no business knowing where the config file lives, and KaimonSlate has no business owning a
# policy the server enforces.
const DEBUG_SPECIALIST_ONLY = Ref(false)
const _DEBUG_SPECIALIST_ONLY_PERSIST = Ref{Any}(nothing)

debug_specialist_only()::Bool = DEBUG_SPECIALIST_ONLY[]

function set_debug_specialist_only!(on::Bool)
    DEBUG_SPECIALIST_ONLY[] = on
    p = _DEBUG_SPECIALIST_ONLY_PERSIST[]
    p === nothing || (try; p(on); catch e; @warn "slate: could not persist the specialist-only setting" exception = e; end)
    return on
end

"""
Every registered specialist role, as the Settings panel shows them.

What a role IS, rather than what it is doing: its verbs, the permission preset it spawns under, and
the first line of its brief. The point of showing this is that a specialist's narrowness is the
reason to use one, and narrowness you cannot see is a claim rather than a fact.
"""
specialist_roles_json() = lock(_SPEC_LOCK) do
    [Dict{String,Any}(
        "name" => s.name,
        "verbs" => copy(s.verbs),
        "permission" => s.permission,
        "model" => specialist_model(s.name),
        # One line: the full brief is hundreds of words and belongs in `dbg_brief`, not a settings row.
        "summary" => (ls = split(strip(String(s.brief)), '\n'); isempty(ls) ? "" : String(first(ls))),
     ) for s in sort!(collect(values(SPECIALISTS)); by = x -> x.name)]
end

"Hand the orchestrator a blocked question as a turn — the push that makes this agent-to-agent."
function _page_orchestrator(nb::LiveNotebook, a::Ask)
    aid = orchestrator_of(nb, a.role)
    isempty(aid) && return false
    body = """
    The $(a.role) on notebook `$(nb.id)` is BLOCKED and waiting on you.

    $(a.kind == "consent" ? "It is asking permission" : "It asks") — ask id `$(a.id)`:

    $(a.text)

    Answer with the answering tool for this notebook, quoting that id. Its turn is stopped until
    you do. If you do not know, say so plainly — a guess it acts on is worse than an admission.
    """
    try
        _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => body))
        return true
    catch e
        @debug "specialist: could not page the orchestrator" exception = e
        return false
    end
end

"""
    ask_and_wait(nb, role, kind, from, text; timeout) -> String

Post a request and block until someone answers. A timeout answers on their behalf, so a specialist
is never wedged forever on an empty room; for consent that answer is NO, because silence is not
permission.
"""
function ask_and_wait(nb::LiveNotebook, role::AbstractString, kind::AbstractString,
                      from::AbstractString, text::AbstractString;
                      options = Tuple{String,String}[], timeout::Float64 = ASK_TIMEOUT)
    a = lock(_SPEC_LOCK) do
        id = string("ask", _ASK_SEQ[] += 1)
        ask = Ask(id, String(role), String(kind), String(from), String(text),
                  Tuple{String,String}[(String(v), String(l)) for (v, l) in options],
                  Channel{String}(1))
        get!(() -> Dict{String,Ask}(), _ASKS, nb.id)[id] = ask
        ask
    end
    broadcast_specialist(nb, a.role, Dict{String,Any}("ask" => ask_json(a)))
    _page_orchestrator(nb, a)
    reply = ""
    timer = Timer(timeout) do _
        isready(a.answer) || (try; put!(a.answer, kind == "consent" ? "no" : ""); catch; end)
    end
    try
        reply = take!(a.answer)
    finally
        close(timer)
        lock(_SPEC_LOCK) do
            d = get(_ASKS, nb.id, nothing)
            d === nothing || delete!(d, a.id)
        end
        broadcast_specialist(nb, a.role, Dict{String,Any}("asks" => asks_json(nb)))
    end
    return reply
end

"""
Answer a pending request. The ask is dropped HERE, by the answerer, not in the waiter's `finally`:
otherwise the two race, and the reply to whoever answered could still list the request they just
dismissed — arriving after the broadcast that cleared it, so the prompt reappears and sticks.
"""
function answer_ask!(nb::LiveNotebook, id::AbstractString, text::AbstractString)
    a = lock(_SPEC_LOCK) do
        d = get(_ASKS, nb.id, nothing)
        d === nothing && return nothing
        ask = get(d, String(id), nothing)
        ask === nothing || delete!(d, String(id))
        return ask
    end
    a === nothing && return false
    try; put!(a.answer, String(text)); catch; end
    return true
end

"Ask whether `who` may disturb something of someone else's. `true` only on an explicit yes."
function request_consent(nb::LiveNotebook, role::AbstractString, who::AbstractString,
                         what::AbstractString)
    reply = ask_and_wait(nb, role, "consent", String(who), String(what))
    return lowercase(strip(reply)) in ("yes", "y", "ok", "allow")
end

"""
    wait_for_specialist(nb; timeout, since) -> Dict

Block until a specialist needs something, or finishes.

An orchestrator reaching this notebook over MCP cannot be pushed at — MCP is request/response — so
a long poll is how that becomes a rendezvous. An orchestrator that IS a Kaimon agent gets paged
directly instead (see `_page_orchestrator`) and needs this only as a backstop.
"""
function wait_for_specialist(nb::LiveNotebook; timeout::Real = 300.0, since::Real = 0.0)
    t0 = time()
    mark = Float64(since)
    if mark <= 0
        so = last_signoff(nb)
        mark = so === nothing ? 0.0 : so[1]
    end
    while true
        as = asks_json(nb)
        isempty(as) || return Dict{String,Any}("kind" => "ask", "asks" => as)
        so = last_signoff(nb)
        if so !== nothing && so[1] > mark
            return Dict{String,Any}("kind" => "done", "at" => so[1], "role" => so[2],
                                    "from" => so[3], "text" => so[4])
        end
        time() - t0 >= timeout && return Dict{String,Any}("kind" => "timeout",
                                                          "waited" => time() - t0, "since" => mark)
        sleep(0.25)
    end
end

"Drop a closed notebook's specialist state — ids are reused when the same file is reopened."
function forget_specialists!(id::AbstractString)
    lock(_SPEC_LOCK) do
        for k in collect(keys(_SPEC_BRIEFING)); k[1] == id && delete!(_SPEC_BRIEFING, k); end
        for k in collect(keys(_SPEC_ORCH));     k[1] == id && delete!(_SPEC_ORCH, k);     end
        delete!(_SPEC_SIGNOFF, String(id))
    end
    return nothing
end
