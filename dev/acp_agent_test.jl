try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🔌 ACP agents — test notebook

Kaimon can drive any agent that speaks the [Agent Client Protocol](https://zed.dev/acp)
through `ACPClientBackend`: opencode, Gemini CLI, Codex, Copilot CLI. Pick one in
**Settings → Model** — the entries look like `opencode · opencode/minimax-m3` and resolve to
a model id of the form `acp:<agent>:<model>`.

This notebook is two things at once: a checklist for driving Slate's chat against an ACP
agent, and a self-contained console for the protocol underneath it. The second half spawns
`opencode acp` directly, so it tells you whether the protocol layer is healthy even when
nothing else is running.
"""

#%% md id=checklist
@md"""
## Manual checklist — Slate chat on an ACP agent

Work down this list with the chat panel open. Each line says what to do and what proves it.

1. **Model list populates.** Open Settings. The model dropdown should carry `opencode · …`
   entries alongside the Ollama and vmlx ones. Empty list ⇒ `opencode` isn't on `PATH`, or
   `opencode models` is slow enough to hit the 8s cap in `_acp_models`.
2. **A turn completes.** Ask the chat *"what is in the `subject` cell?"*. Reasoning should
   stream dimmed, then the answer. No text at all is the symptom of the authoritative-chunk
   bug: ACP streams deltas only, and everything that reconstructs a message reads the
   non-delta copy.
3. **Tools reach Julia.** Ask it to *"run the `total` cell and tell me the result"*. The
   agent calls Kaimon's MCP tools, named `kaimon_<tool>` rather than `mcp__kaimon__<tool>`.
4. **The recursion guard holds.** Ask it to *"use the agent_open tool to start another
   agent"*. The call must come back **failed** — an agent that can spawn agents is a
   fork bomb with a credit card.
5. **Model switching keeps the conversation.** Tell it a fact, change the model in Settings,
   then ask it to repeat the fact back. An ACP agent is repointed on its live session, so it
   should remember; every other backend gets reaped and will not.
6. **Cost is reported.** `agent_status` should show non-zero usage with a real `cost_usd`.
"""

#%% md id=subject_h
@md"""
## Subject cells

Ordinary cells for the agent to read, edit and run during steps 2 and 3.
"""

#%% code id=subject
subject = (name = "ACP test notebook", answer = 42, primes = [2, 3, 5, 7, 11, 13])

#%% code id=total
total = sum(subject.primes)

#%% md id=probe_h
@md"""
## Protocol console

Everything below runs without Kaimon: it spawns the agent, completes the `initialize` and
`session/new` handshake, sends one turn and tallies what came back. Use it to tell a broken
protocol layer apart from a broken integration — if the census here looks right but chat is
empty, the fault is above the backend, not in it.
"""

#%% code id=probe_deps
# JSON isn't in every notebook environment. Add it from the package pane if this reports false.
const HAVE_JSON = try; @eval import JSON; true; catch; false; end

#%% code id=probe_model
@bind probe_model Select(["opencode/nemotron-3-ultra-free" => "Nemotron 3 Ultra (free, slow)",
                         "opencode/minimax-m3" => "MiniMax M3 (cheap, fast)",
                         "opencode/glm-5.3-flash" => "GLM 5.3 Flash (cheapest)"])

#%% code id=probe_prompt
@bind probe_prompt TextField("Read calc.jl and tell me the value of y.")

#%% md id=probe_fn_h
@md"""
### The client

ACP is JSON-RPC over nd-JSON on stdio, and it is **bidirectional**: the agent calls back
mid-turn for permission and file access. A client that only reads will hang with the turn
half-finished, so this answers requests as well as sending them.
"""

#%% code id=probe_fn
function acp_probe(model::AbstractString, prompt::AbstractString; timeout = 240)
    HAVE_JSON || return (; ok = false, error = "JSON not available in this environment")
    cfg = mktempdir()
    mkpath(joinpath(cfg, "opencode"))
    write(joinpath(cfg, "opencode", "opencode.json"),
          """{"\$schema":"https://opencode.ai/config.json","model":"$model"}""")

    work = mktempdir()
    write(joinpath(work, "calc.jl"), "x = 41\ny = x + 1\n")

    env = copy(ENV); env["XDG_CONFIG_HOME"] = cfg
    inp, outp = Pipe(), Pipe()
    proc = run(pipeline(setenv(Cmd(Cmd(["opencode", "acp"]); dir = work), env);
                        stdin = inp, stdout = outp, stderr = devnull); wait = false)
    close(inp.out); close(outp.in)

    seq, pending = Ref(0), Dict{Int,Channel{Any}}()
    census, text = Dict{String,Int}(), IOBuffer()
    lk = ReentrantLock()
    send(o) = lock(lk) do; write(inp, JSON.json(o), "\n"); flush(inp); end
    function call(method, params)
        id = lock(lk) do; seq[] += 1; pending[seq[]] = Channel{Any}(1); seq[]; end
        send(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
        take!(pending[id])
    end

    reader = @async try
        for line in eachline(outp)
            isempty(strip(line)) && continue
            o = try; JSON.parse(line); catch; continue; end
            o isa AbstractDict || continue
            if haskey(o, "method") && haskey(o, "id")
                # Answer callbacks, or the turn never finishes.
                send(Dict("jsonrpc" => "2.0", "id" => o["id"],
                          "result" => Dict("outcome" => Dict("outcome" => "cancelled"))))
            elseif haskey(o, "method") && o["method"] == "session/update"
                u = get(get(o, "params", Dict()), "update", Dict())
                k = String(get(u, "sessionUpdate", "?"))
                lock(lk) do; census[k] = get(census, k, 0) + 1; end
                k == "agent_message_chunk" &&
                    write(text, String(get(get(u, "content", Dict()), "text", "")))
            elseif haskey(o, "id")
                ch = lock(lk) do; get(pending, o["id"], nothing); end
                ch === nothing || put!(ch, o)
            end
        end
    catch
    end

    try
        init = call("initialize", Dict("protocolVersion" => 1,
            "clientCapabilities" => Dict("fs" => Dict("readTextFile" => true,
                                                      "writeTextFile" => false))))
        sess = call("session/new", Dict("cwd" => work, "mcpServers" => []))
        sid = get(get(sess, "result", Dict()), "sessionId", "")
        t0 = time()
        res = call("session/prompt", Dict("sessionId" => sid,
            "prompt" => [Dict("type" => "text", "text" => prompt)]))
        r = get(res, "result", Dict())
        return (; ok = true,
                agent = get(get(get(init, "result", Dict()), "agentInfo", Dict()), "name", "?"),
                session = sid,
                seconds = round(time() - t0; digits = 1),
                stop = get(r, "stopReason", "?"),
                usage = get(r, "usage", Dict()),
                census = sort(collect(census); by = last, rev = true),
                reply = String(take!(text)))
    catch e
        return (; ok = false, error = sprint(showerror, e))
    finally
        try; kill(proc); catch; end
        try; rm(cfg; recursive = true, force = true); catch; end
    end
end

#%% md id=run_h
@md"""
### Run it

The control below starts **idle** on purpose: a probe run spawns an agent and bills a turn,
and a notebook that spends money merely by being opened is a bad notebook. Switch it to
*Run* and it fires, then re-fires whenever the model or prompt above changes.

A healthy result has `stop = "end_turn"`, a non-empty `reply`, and a census containing
`agent_message_chunk`. `agent_thought_chunk` appears only on a reasoning model — its absence
on a non-reasoning one proves nothing.
"""

#%% code id=probe_go
@bind probe_go Select(["idle" => "Idle — no agent spawned",
                       "run"  => "Run the probe (spawns an agent, bills a turn)"])

#%% code id=run
# A Select over labelled options binds a Choice, not a String — `string` normalises
# both it and a plain TextField value.
probe_result = probe_go == "run" ?
    acp_probe(string(probe_model), string(probe_prompt)) :
    (; ok = false, error = "idle — switch the control above to Run")

#%% code id=run_census
probe_result.ok ? probe_result.census : probe_result.error

#%% code id=run_reply
probe_result.ok ? probe_result.reply : ""

#%% md id=notes
@md"""
## What each symptom means

| Symptom | Where to look |
|---|---|
| Handshake never returns | `opencode` not on `PATH`, or not authenticated — run `opencode auth login` |
| Turn hangs, tool stuck `in_progress` | a callback went unanswered; the client must reply to `session/request_permission` and `fs/*` |
| Census has chunks but `reply` is empty | text arrived as deltas only — the authoritative non-delta chunk is missing |
| Chat works here but not in Slate | the fault is in the backend or the bridge, not the protocol |
| `usage.cost` is zero | expected on the free Zen models; non-zero on paid ones |

The bridge plugin enforces tool policy inside opencode, because ACP cannot express it:
opencode does its own file I/O and never sends `session/request_permission` for its built-in
tools. This console passes no plugin, so it runs under the agent's own rules — that is why
it declares `writeTextFile: false` and points the agent at a scratch directory.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 02f05b5e-02b4-47a0-ade0-efa4aff10374
# ╚═╡
