# The specialist loop, driven without a model.
#
# `test_debugger.jl` covers the stepper. This covers everything wrapped around it: who owns a
# session, what a specialist is briefed with, whether the verbs it calls reach the kernel, whether
# a blocking question actually blocks and is actually released, and whether signing off gives the
# session back. That layer had no tests at all, because exercising it meant spawning an agent.

using ReTest
using Sockets
using KaimonSlate
const NS = KaimonSlate.NotebookServer
# What an agent caller looks like. `may_disturb` asks `_is_agent`, which keys on this prefix, so a
# bare role name is treated as a PERSON and waved through — the distinction the consent rule turns
# on is the prefix, not the name.
const AGENT = "agent:fake-agent"

include("debug_fake_agent.jl")

@testset "specialist loop" begin
    NS.SlateHistory._ROOT[] = mktempdir()
    # Ask the OS for a free one rather than naming a port. A fixed port is shared with another
    # suite in this same run, and a hub that cannot bind used to be indistinguishable from one that
    # could — the suite hung instead of failing, and left the port held for the next run too.
    port = let s = Sockets.listen(Sockets.localhost, 0)
        p = Int(Sockets.getsockname(s)[2]); close(s); p
    end
    hub = NS.start_hub(; port = port)
    try
        nbp = tempname() * ".jl"
        # A loop long enough that stepping to the interesting iteration is not an option — which
        # is the situation the predicate exists for.
        write(nbp, """
              #%% code id=drive
              total = 0
              for i in 1:5000
                  global total += i
              end
              total
              """)
        nb = hub.notebooks[NS.open_notebook!(hub, nbp)]

        @testset "a summoned specialist is briefed and answers" begin
            fake_agent_reset!((args, text) -> nothing)
            r = NS.summon!(nb, "debugger"; subject = "drive", model = "fake")
            @test get(r, "ok", false) === true
            @test get(r, "crew", "") == "debugger"
            fake_agent_settle!()

            # It was OPENED with the seven verbs and nothing else — the restriction is the whole
            # design, so assert the list that was actually sent rather than the one we meant.
            open_call = only(a for (t, a) in FAKE_CALLS if t === :agent_open)
            allowed = String[String(x) for x in get(open_call, "allowed_tools", String[])]
            @test !isempty(allowed)
            @test all(v -> any(endswith(a, v) for a in allowed),
                      ["dbg_start", "dbg_step", "dbg_frame", "dbg_eval", "dbg_break",
                       "dbg_ask", "dbg_done"])
            @test !any(a -> endswith(a, "_read") || endswith(a, "_edit_cell"), allowed)

            # And BRIEFED with the cell it was handed: an opening turn that does not say which
            # cell leaves the specialist to guess.
            brief = first(FAKE_TURNS)
            @test occursin("drive", brief)
            @test occursin(nb.id, brief)
        end

        @testset "the verbs a specialist calls reach the kernel" begin
            # The script IS the specialist: arm a predicate, continue, read the frame.
            seen = Ref{Any}(nothing)
            fake_agent_reset!((args, text) -> begin
                NS.mark_debug!(nb, "cell:drive", 3; on = true, cond = "i == 4200")
                NS.start_debug!(nb, "drive"; by = AGENT)
                NS.step_debug!(nb, "continue")
                seen[] = NS.eval_debug(nb, "i")
            end)
            NS.tell!(nb, "debugger", "find where it goes wrong")
            fake_agent_settle!()

            @test seen[] !== nothing
            @test get(seen[], "ok", false) === true
            # One `continue` reached iteration 4200. Stepping there was never an option.
            @test get(get(seen[], "value", Dict()), "repr", "") == "4200"
            st = NS.frame_debug(nb)
            @test get(st, "at_breakpoint", false) === true
            @test get(st, "line", 0) == 3
        end

        @testset "a blocking question blocks until answered" begin
            answered = Ref("")
            fake_agent_reset!((args, text) -> begin
                # It answers with the reply itself, not a wrapper — the caller is blocked, so
                # there is nothing to report except what came back.
                answered[] = NS.ask_and_wait(nb, "debugger", "question", AGENT,
                                             "is `total` meant to be a running sum?")
            end)
            NS.tell!(nb, "debugger", "ask me something")

            # The ask must be VISIBLE while it blocks — a question nobody can see is a hang.
            waited = false
            for _ in 1:200
                as = NS.asks_json(nb)
                if !isempty(as)
                    waited = true
                    NS.answer_ask!(nb, String(get(first(as), "id", "")), "Yes, a running sum.")
                    break
                end
                sleep(0.02)
            end
            @test waited
            fake_agent_settle!()
            @test occursin("running sum", answered[])
            @test isempty(NS.asks_json(nb))   # answering clears it, so the dialog can dismiss
        end

        @testset "signing off reports without closing" begin
            # `sign_off!` announces; it does not stop. Closing is `dbg_done`'s, and only when the
            # session was the specialist's own — a session a person opened stays open for them.
            fake_agent_reset!((args, text) -> nothing)
            @test !isempty(NS._debug_session(nb).cell)          # still held from above
            NS.sign_off!(nb, "debugger", AGENT, "off-by-one in the accumulator")
            @test !isempty(NS._debug_session(nb).cell)
            sg = NS.last_signoff(nb)
            @test sg !== nothing && occursin("off-by-one", sg[4])
            NS.stop_debug!(nb; by = AGENT)                      # its own session: no consent needed
            @test isempty(NS._debug_session(nb).cell)
        end

        @testset "a choice is answered by picking, not by typing" begin
            picked = Ref("")
            fake_agent_reset!((args, text) -> begin
                picked[] = NS.ask_and_wait(nb, "debugger", "choice", AGENT,
                                           "Which model should the specialist use?";
                                           options = [("acp:claude:sonnet", "Sonnet — fast"),
                                                      ("acp:claude:default", "Opus — better at coupling")])
            end)
            NS.tell!(nb, "debugger", "offer me a model")
            chosen = ""
            for _ in 1:200
                as = NS.asks_json(nb)
                if !isempty(as)
                    a = first(as)
                    @test a["kind"] == "choice"
                    # The options ride with the question: a client cannot render buttons for
                    # alternatives it was not told about.
                    @test length(a["options"]) == 2
                    @test first(a["options"])["label"] == "Sonnet — fast"
                    chosen = String(first(a["options"])["value"])
                    NS.answer_ask!(nb, String(a["id"]), chosen)
                    break
                end
                sleep(0.02)
            end
            fake_agent_settle!()
            # The asker gets the VALUE, so it can be an id while the label reads like a sentence.
            @test picked[] == "acp:claude:sonnet"
        end

        @testset "file access is granted to the notebook's agent, not to a specialist" begin
            # The agent has no shell or file tools until it asks and is told yes. What it asks for
            # is a preset, and the preset binds at spawn — so the grant has to outlive the turn and
            # then replace the agent, or "allowed" means nothing until the hub restarts.
            @test NS._effective_perm(nb, "", "") == "notebook"
            @test NS._effective_perm(nb, "bypass", "") == "bypass"   # the picker, when there's no grant
            try
                NS.grant_agent_permission!(nb, "lab")
                @test NS._effective_perm(nb, "", "") == "lab"
                @test NS._effective_perm(nb, "notebook", "") == "lab"   # a grant outranks the picker
                # A specialist's preset comes from its role. Widening it here would undo the
                # allowlist that is the reason to summon one.
                @test NS._effective_perm(nb, "specialist", "debugger") == "specialist"
            finally
                delete!(NS._PERM_GRANT, nb.id)
            end
            @test NS._effective_perm(nb, "", "") == "notebook"
        end

        @testset "the summoning orchestrator may end its specialist's session" begin
            # Registering an orchestrator means later asks are PAGED to it as a turn, which runs
            # whatever script is loaded. Leave the asking one in place and a consent request below
            # spawns a specialist that asks its own question and blocks on it for the full timeout,
            # outliving the suite.
            fake_agent_reset!((args, text) -> nothing)
            fake_agent_alive!(AGENT)                     # an orchestrator it cannot send to is not one
            @test NS.register_orchestrator!(nb, "debugger", AGENT)
            NS.start_debug!(nb, "drive"; by = "agent:the-specialist")
            try
                @test NS._debug_session(nb).owner == "agent:the-specialist"
                # No consent round trip: supervising includes deciding the work is done, and an
                # agent that can start a specialist but not stop one is not supervising it.
                @test NS.may_disturb(nb, AGENT)
                @test NS.stop_debug!(nb; by = AGENT)
                @test isempty(NS._debug_session(nb).cell)
                @test isempty(NS.asks_json(nb))          # nobody was asked anything
            finally
                NS.stop_debug!(nb; by = NS.HUMAN)
            end
        end

        @testset "an unrelated agent still may not" begin
            NS.start_debug!(nb, "drive"; by = "agent:the-specialist")
            try
                @test !NS.may_disturb(nb, "agent:a-stranger")
            finally
                NS.stop_debug!(nb; by = NS.HUMAN)
            end
        end

        @testset "a specialist may not end a session it does not own" begin
            NS.start_debug!(nb, "drive"; by = NS.HUMAN)
            try
                # Consent is asked of the owner, so with nobody to answer this must not just take
                # it. The session stays exactly where it was.
                @test NS._debug_session(nb).owner == NS.HUMAN
                r = @async NS.stop_debug!(nb; by = AGENT)
                sleep(0.3)
                @test NS._debug_session(nb).owner == NS.HUMAN   # not taken while unanswered
                # By kind, not `first`: other asks can be open at the same time, and answering the
                # wrong one leaves this turn blocked until the timeout.
                as = filter(a -> get(a, "kind", "") == "consent", NS.asks_json(nb))
                @test !isempty(as)                              # it ASKED rather than acted
                NS.answer_ask!(nb, String(get(first(as), "id", "")), "no")
                wait(r)
                @test !isempty(NS._debug_session(nb).cell)      # refused: still running
            finally
                NS.stop_debug!(nb; by = NS.HUMAN)
            end
        end
    finally
        try; NS.stop_hub(hub); catch; end
    end
end
