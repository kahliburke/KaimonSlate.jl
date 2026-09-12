# A scripted stand-in for a debugging specialist.
#
# The specialist loop — summon, brief, the seven verbs, ask/answer, sign off — could until now
# only be exercised by a hub, a notebook, a real agent and a person watching. That is not a test,
# and it is why the server layer around the stepper has none: every change had to be checked by
# spawning a model and reading a transcript.
#
# Nothing about that loop needs a model. `summon!` reaches the agent service through exactly one
# call, `Main.Kaimon.KaimonGate.call_tool`, and a test process has no Kaimon — so defining that
# module IS the stub, with no production code aware of it. The "agent" becomes a Julia function
# handed a script of verbs, which makes the flow assertable: what it was briefed with, what it
# called, what came back, and whether signing off actually released the session.

"Everything the fake was asked to do, in order, so a test can assert on the conversation."
const FAKE_CALLS = Vector{Tuple{Symbol,Dict{String,Any}}}()

"The script the current fake runs when it is handed a turn: `f(notebook_id, text)`."
const FAKE_SCRIPT = Ref{Any}((nb, text) -> nothing)

"Turns delivered to the agent, newest last — the briefing is the first of them."
const FAKE_TURNS = Vector{String}()

"Tasks spawned for turns, so a test can wait for the script rather than sleep on it."
const FAKE_TASKS = Vector{Task}()

function fake_agent_reset!(script)
    empty!(FAKE_CALLS); empty!(FAKE_TURNS); empty!(FAKE_TASKS)
    FAKE_SCRIPT[] = script
    return nothing
end

"""
Mark an agent id as live without opening it through `summon!`.

An orchestrator is a caller, not something this notebook spawned, and `register_orchestrator!`
refuses an id it cannot send to — so a stand-in orchestrator has to exist before it can be
registered, or the test asserts on an authority that was silently never granted.
"""
fake_agent_alive!(aid::AbstractString) = (Main.Kaimon.KaimonGate.OPEN[String(aid)] = true; nothing)

"Block until every turn handed to the fake has finished running its script."
function fake_agent_settle!(; timeout = 30.0)
    deadline = time() + timeout
    while time() < deadline
        all(istaskdone, FAKE_TASKS) && length(FAKE_TASKS) > 0 && break
        sleep(0.02)
    end
    for t in FAKE_TASKS
        istaskdone(t) || continue
        # Surface a script failure as a test failure rather than as a silent no-op: a script that
        # threw looks exactly like a specialist that decided to do nothing.
        istaskfailed(t) && fetch(t)
    end
    return nothing
end

# `_agent_call` does `Main.Kaimon.KaimonGate.call_tool(tool, args)` and parses the JSON string it
# gets back, so the stub answers in that shape. Only the handful of tools the specialist framework
# actually reaches are implemented; anything else returns an error string, which `_agent_call`
# raises — an unimplemented tool should fail loudly rather than look like an empty success.
#
# The stub has to BE `Main.Kaimon`, since that is where the production lookup goes, but the state
# above belongs to whichever module included this file — `runtests.jl` gives every test file its
# own. So the stub is evaluated into `Main` and pointed back at its includer through `HOME`.
isdefined(Main, :Kaimon) || @eval Main module Kaimon
    module KaimonGate

    const HOME = Ref{Module}(Main)      # the test module holding FAKE_CALLS and friends
    const OPEN = Dict{String,Bool}()

    function call_tool(tool::Symbol, args::Dict{String,Any})
        H = HOME[]
        JSON = H.KaimonSlate.JSON
        push!(H.FAKE_CALLS, (tool, deepcopy(args)))
        if tool === :agent_open
            aid = String(get(args, "id", "fake-agent"))
            OPEN[aid] = true
            return JSON.json(Dict("agent_id" => aid))
        elseif tool === :agent_status
            aid = String(get(args, "agent_id", ""))
            return JSON.json(Dict("status" => get(OPEN, aid, false) ? "idle" : "dead",
                                  "model" => "fake"))
        elseif tool === :agent_close
            delete!(OPEN, String(get(args, "agent_id", "")))
            return JSON.json(Dict("closed" => true))
        elseif tool === :agent_send
            text = String(get(args, "text", ""))
            push!(H.FAKE_TURNS, text)
            # On a task, not inline: a script that calls `dbg_ask` blocks until someone answers,
            # and the answerer is the test — which is still inside this call if we run it here.
            push!(H.FAKE_TASKS, Threads.@spawn H.FAKE_SCRIPT[](args, text))
            return JSON.json(Dict("turn" => length(H.FAKE_TURNS)))
        elseif tool === :agent_interrupt
            return JSON.json(Dict("interrupted" => true))
        elseif tool === :agent_set_model
            return JSON.json(Dict("switched" => true))
        end
        # Built rather than interpolated: this module is defined through `@eval`, which would
        # substitute a `$` at macro-expansion time instead of leaving it for the string.
        return string("Error: the fake agent does not implement ", tool)
    end
    end # module KaimonGate
end # module Kaimon
Main.Kaimon.KaimonGate.HOME[] = @__MODULE__
