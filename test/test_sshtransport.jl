# src/sshtransport.jl — the learned keyboard-interactive prompt shapes, and what the module is
# allowed to depend on to keep them.
#
# The session itself needs a server, so what is covered here is the part that does not: what the
# transport remembers about a host's login and when it rewrites it. That bookkeeping decides how
# many second-factor codes a person is asked for.
using ReTest
include(joinpath(@__DIR__, "..", "src", "sshtransport.jl"))

const T = SshTransport

reset!() = lock(T._PROMPTS_LOCK) do
    empty!(T._PROMPTS); T._PROMPT_SAVE[] = nothing
end

@testset "a long command's output arrives line by line" begin
    # Provisioning runs for minutes; the tap is what lets each line be seen as it lands while the
    # whole output is still returned at the end.
    got = String[]
    t = T.LineTap(l -> push!(got, l))
    write(t, "Resolving pack"); write(t, "ages\nInstalled 3\r[====] 50%\rdone\n"); write(t, "tail")
    @test got == ["Resolving packages", "Installed 3", "[====] 50%", "done"]
    @test String(take!(t)) == "Resolving packages\nInstalled 3\r[====] 50%\rdone\ntail"
    @test got[end] == "tail"                    # the last line, unterminated, still arrives
    # stderr is merged into the stream the tap reads. libssh2.h: 0 normal, 1 IGNORE, 2 MERGE; with 1,
    # every command's stderr (all of Pkg's progress) was silently dropped.
    @test T.EXTENDED_DATA_MERGE == 2
    # A callback that throws loses its line and nothing else: the read goes on.
    t2 = T.LineTap(_ -> error("boom"))
    write(t2, "a\nb\n")
    @test String(take!(t2)) == "a\nb\n"
end

@testset "ssh prompt store" begin
    @testset "the module imports nothing a worker might not have" begin
        # This file ships to a cluster in the worker payload and is loaded against whatever
        # environment the remote has. A serialization dependency added here for the convenience of
        # the hub took down the whole batch fabric on a cluster whose env had no JSON: the module
        # failed to load, `Sweep` went with it, and the sweep body died on an undefined `paramgrid`.
        src = read(joinpath(@__DIR__, "..", "src", "sshtransport.jl"), String)
        imports = Set(m.captures[1] for m in eachmatch(r"(?m)^\s*(?:import|using)\s+(\w+)", src))
        @test imports ⊆ Set(["LibSSH2_jll", "FileWatching", "Sockets"])
    end

    @testset "what a host asks survives a restart" begin
        # Learning it again costs a login that fails on purpose. On a cluster that sends the code
        # when it ASKS rather than when it is answered, that failed login spends one.
        reset!()
        kept = Ref{Any}(nothing)
        T.set_prompt_store!(p -> kept[] = p)
        T._remember_prompts!("clus", [("Password: ", false), ("Duo passcode: ", false)])
        @test kept[]["clus"] == [("Password: ", false), ("Duo passcode: ", false)]

        reset!()                                     # a fresh hub
        T.adopt_prompts!(kept[])
        @test T.remembered_prompts("clus") == [("Password: ", false), ("Duo passcode: ", false)]
        @test isempty(T.remembered_prompts("never-met"))
        reset!()
    end

    @testset "a login that changes shape corrects the store" begin
        # The wedge this prevents: the remembered list was only ever written on SUCCESS, so a
        # cluster that gained a factor left every later attempt replaying a conversation the server
        # no longer wanted, with no path back to discovery short of restarting the hub.
        reset!()
        kept = Ref{Any}(nothing)
        T.set_prompt_store!(p -> kept[] = p)
        T._remember_prompts!("clus", [("Password: ", false)])
        T._remember_prompts!("clus", [("Password: ", false), ("Verification code: ", false)])
        reset!()
        T.adopt_prompts!(kept[])
        @test T.remembered_prompts("clus") == [("Password: ", false), ("Verification code: ", false)]
        reset!()
    end

    @testset "an unchanged login does not rewrite the store" begin
        reset!()
        saves = Ref(0)
        T.set_prompt_store!(_ -> saves[] += 1)
        for _ in 1:3
            T._remember_prompts!("clus", [("Password: ", false)])
        end
        @test saves[] == 1
        reset!()
    end

    @testset "kept prompts are advisory" begin
        # Nothing here is worth failing a login over: nonsense means discover again.
        reset!()
        T.adopt_prompts!("not a dict")
        T.adopt_prompts!(Dict("bad" => [["Password: ", "yes"]],     # echo flag is not a Bool
                              "short" => [["Password: "]],
                              "ok" => [["Password: ", true]]))
        @test isempty(T.remembered_prompts("bad"))
        @test isempty(T.remembered_prompts("short"))
        @test T.remembered_prompts("ok") == [("Password: ", true)]
        reset!()
    end

    @testset "a live conversation outranks what was kept" begin
        reset!()
        T._remember_prompts!("clus", [("Password: ", false)])
        T.adopt_prompts!(Dict("clus" => [["Something else: ", true]]))
        @test T.remembered_prompts("clus") == [("Password: ", false)]
        reset!()
    end

    @testset "an empty conversation is not remembered" begin
        # `pr.seen` is empty when the server refused keyboard-interactive outright, which says
        # nothing about what it asks — overwriting a good entry with it would force a rediscovery.
        reset!()
        T._remember_prompts!("clus", [("Password: ", false)])
        T._remember_prompts!("clus", Tuple{String,Bool}[])
        @test T.remembered_prompts("clus") == [("Password: ", false)]
        reset!()
    end

    @testset "with no store it is memory only" begin
        reset!()
        T._remember_prompts!("clus", [("Password: ", false)])
        @test T.remembered_prompts("clus") == [("Password: ", false)]
        reset!()
        @test isempty(T.remembered_prompts("clus"))
    end
end
