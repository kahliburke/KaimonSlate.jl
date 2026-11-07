# src/sshtransport.jl — the learned keyboard-interactive prompt shapes, and what the module is
# allowed to depend on to keep them.
#
# The session itself needs a server, so what is covered here is the part that does not: what the
# transport remembers about a host's login and when it rewrites it. That bookkeeping decides how
# many second-factor codes a person is asked for.
using ReTest
import Base64
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

@testset "a key's certificate is offered before its plain public key" begin
    mktempdir() do d
        priv = joinpath(d, "id")
        write(priv, "")
        @test T._pubkey_candidates(priv) == [nothing]
        write(priv * ".pub", "")
        @test T._pubkey_candidates(priv) == [priv * ".pub"]
        write(priv * "-cert.pub", "")
        @test T._pubkey_candidates(priv) == [priv * "-cert.pub", priv * ".pub"]
    end
end

@testset "ssh-agent keys" begin
    # Blobs are runs of length-prefixed fields; a key's first field is its type.
    field(x) = (v = Vector{UInt8}(x); vcat(reinterpret(UInt8, [hton(UInt32(length(v)))]), v))
    b64(v) = String(Base64.base64encode(v))
    e, n = UInt8[1, 0, 1], UInt8[9, 8, 7]
    plain = vcat(field("ssh-rsa"), field(e), field(n))
    cert = vcat(field("ssh-rsa-cert-v01@openssh.com"), field("nonce"), field(e), field(n), field(UInt8[0, 0, 0, 1]))
    stale = vcat(field("ssh-rsa"), field(e), field(UInt8[5, 5]))
    other = vcat(field("ssh-ed25519"), field(UInt8[6]))

    @test T._b64decode(b64(cert)) == cert
    @test T._blob_type(cert) == "ssh-rsa-cert-v01@openssh.com"
    @test T._blob_type(UInt8[0, 0]) == ""
    @test T._certified_key(cert) == plain
    @test T._certified_key(plain) === nothing

    withenv("SSH_AUTH_SOCK" => "/run/agent.sock", "OTHER_SOCK" => "/run/other.sock") do
        @test T._agent_socket("") == "/run/agent.sock"
        @test T._agent_socket("SSH_AUTH_SOCK") == "/run/agent.sock"
        @test T._agent_socket("\$OTHER_SOCK") == "/run/other.sock"
        @test T._agent_socket("none") == ""
        @test T._agent_socket("~/a.sock") == joinpath(homedir(), "a.sock")
    end

    mktempdir() do d
        priv = joinpath(d, "id")
        write(priv * ".pub", "ssh-rsa $(b64(plain)) me\n")
        write(priv * "-cert.pub", "ssh-rsa-cert-v01@openssh.com $(b64(cert)) me\n")
        blobs = [other, stale, plain, cert]
        # The certificate, then the key it certifies, then the rest in the agent's order.
        @test T._agent_order(blobs, [priv], false) == [4, 3, 1, 2]
        # With IdentitiesOnly, only the keys that belong to the host's identity files.
        @test T._agent_order(blobs, [priv], true) == [4, 3]
        @test T._agent_order(blobs, String[], true) == Int[]
    end
end

@testset "a command written for bash runs the same under another login shell" begin
    # The server parses a command in the account's login shell. Under zsh an unmatched glob is an
    # error, so a session whose login shell is not bash hands commands to bash.
    ep = T.Endpoint("shell-test", "shell-test", 22, "u", String[], "", false, "")
    s = T.Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, T.Prompter("shell-test"), true, "", T.Fwd[])
    cmd = "ls /nonexistent-slate-test/* 2>/dev/null; x='a b'; v=abc/def; echo \"\$x\" \"it's\" \${v%%/*}"
    @test T._as_sent(s, cmd) == cmd                     # a bash login shell gets it as written
    s.in_bash = true
    want = read(`bash -c $cmd`, String)
    @test want == "a b it's abc\n"
    zsh = Sys.which("zsh")
    zsh === nothing || @test read(`$zsh -c $(T._as_sent(s, cmd))`, String) == want
end

@testset "a server refusing channels with none of ours open ends the session" begin
    # A server that counts sessions this side has already let go refuses every command from then on, while
    # the forwards on the connection keep working. A minute of that, with no channel of ours open, ends the
    # session so the next command connects afresh. No server is needed: the rule reads only what this side
    # holds.
    host = "refusal-test"
    ep = T.Endpoint(host, host, 22, "u", String[], "", false, "")
    fresh() = T.Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, T.Prompter(host), true, "", T.Fwd[])
    clear!() = lock(() -> (empty!(T._IDLE_REFUSAL_SINCE); filter!(kv -> last(kv)[1].ep.alias != host, T._OPEN_CMDS)), T._OPEN_CMDS_LOCK)
    clear!()
    s = fresh()
    @test !T._refused_with_none_open!(s, "connect failed")            # the first refusal starts the clock
    @test s.alive
    lock(() -> (T._IDLE_REFUSAL_SINCE[s] -= T.IDLE_REFUSAL_S + 1), T._OPEN_CMDS_LOCK)
    @test T._refused_with_none_open!(s, "connect failed")             # still refused a minute on: ended
    @test !s.alive && occursin("refuses every channel", s.err)
    # A command channel of ours still open means the server's count may be ours: the session stays.
    clear!()
    s2 = fresh()
    T._note_open!(s2, Ptr{Cvoid}(UInt(0x1)), "sleep 600")
    @test !T._refused_with_none_open!(s2, "connect failed")
    lock(() -> (T._IDLE_REFUSAL_SINCE[s2] = time() - T.IDLE_REFUSAL_S - 1), T._OPEN_CMDS_LOCK)
    @test !T._refused_with_none_open!(s2, "connect failed")
    @test s2.alive
    # A channel opening in between resets the clock.
    T._note_freed!(Ptr{Cvoid}(UInt(0x1)))
    @test !T._refused_with_none_open!(s2, "connect failed")
    T._note_open!(s2, Ptr{Cvoid}(UInt(0x2)), "true"); T._note_freed!(Ptr{Cvoid}(UInt(0x2)))
    @test !haskey(T._IDLE_REFUSAL_SINCE, s2)
    # Entries of another session never count: a session freed with its channels leaves none behind, and a
    # bulk connection to the same host is a connection of its own.
    clear!()
    old, s3 = fresh(), fresh()
    T._note_open!(old, Ptr{Cvoid}(UInt(0x3)), "sleep 600")
    T._forget_session_cmds!(old)
    T._note_open!(fresh(), Ptr{Cvoid}(UInt(0x4)), "cat big.blob")
    @test !T._refused_with_none_open!(s3, "connect failed")
    lock(() -> (T._IDLE_REFUSAL_SINCE[s3] = time() - T.IDLE_REFUSAL_S - 1), T._OPEN_CMDS_LOCK)
    @test T._refused_with_none_open!(s3, "connect failed") && !s3.alive
    clear!()
end

@testset "every channel open holds the session's open lock" begin
    # libssh2 keeps a half-opened channel on the session, so two opens in flight at once mix their
    # replies: a probe of a port nobody listens on, opened beside a command, handed the command its
    # "connect failed" and left the session refusing every command after. Every function that opens a
    # channel (a command's session channel, a forward, a probe) does it inside `lock(s.openlk)`.
    src = read(joinpath(@__DIR__, "..", "src", "sshtransport.jl"), String)
    calls(ex, name) = ex isa Expr && (any(a -> a isa QuoteNode && a.value === name, ex.args) || any(a -> calls(a, name), ex.args))
    holds_openlk(ex) = ex isa Expr && ((ex.head === :call && ex.args[1] === :lock && any(a -> a == :(s.openlk), ex.args)) ||
                                       any(holds_openlk, ex.args))
    defs = Expr[]                                 # every definition, inside the module too
    collect_defs(ex) = ex isa Expr && (ex.head in (:function, :(=)) ? push!(defs, ex) : foreach(collect_defs, ex.args))
    collect_defs(Meta.parseall(src))
    opens = [d for d in defs if calls(d, :libssh2_channel_open_ex) || calls(d, :libssh2_channel_direct_tcpip_ex)]
    @test length(opens) >= 3                      # the command open, the forward open, the probe
    for d in opens
        @test holds_openlk(d)
    end
end

# Needs a server: set KAIMONSLATE_SSH_TEST_HOST to a host this machine signs in to by key.
@testset "commands on one session run side by side" begin
    host = get(ENV, "KAIMONSLATE_SSH_TEST_HOST", "")
    if isempty(host)
        @test_skip "KAIMONSLATE_SSH_TEST_HOST is not set"
    else
        ask = (_...) -> nothing
        try
            @test first(T.exec(host, "true"; ask))                     # signed in
            slow = Threads.@spawn T.exec(host, "sleep 6; echo slow"; ask)
            sleep(1.0)
            t0 = time(); ok, out = T.exec(host, "echo quick"; ask)
            @test ok && strip(out) == "quick" && time() - t0 < 4      # not behind the sleep
            # A forward carries a connection while a command runs: the far side's ssh banner arrives.
            busy = Threads.@spawn T.exec(host, "sleep 4"; ask)
            lp = let s = T.Sockets.listen(T.Sockets.localhost, 0); p = Int(T.Sockets.getsockname(s)[2]); close(s); p end
            @test first(T.forward!(host, lp, "127.0.0.1", 22; ask))
            sock = T.Sockets.connect(T.Sockets.localhost, lp)
            t0 = time(); banner = readline(sock)
            @test startswith(banner, "SSH-") && time() - t0 < 3
            close(sock); T.unforward!(host, lp)
            ok2, out2 = fetch(slow)
            @test ok2 && strip(out2) == "slow" && first(fetch(busy))
        finally
            T.disconnect!(host)
        end
    end
end

# A sink whose reader has already stopped wanting the output.
struct _StoppedSink <: IO end
T.stop_requested(::_StoppedSink) = true
Base.unsafe_write(::_StoppedSink, ::Ptr{UInt8}, n::UInt) = n

# Needs a server with python3, as above.
@testset "bulk data arrives whole, and a stopped transfer leaves the session usable" begin
    host = get(ENV, "KAIMONSLATE_SSH_TEST_HOST", "")
    if isempty(host)
        @test_skip "KAIMONSLATE_SSH_TEST_HOST is not set"
    else
        ask = (_...) -> nothing
        n = 24 * 1024 * 1024
        try
            # A command's output, into a file as it arrives.
            f = tempname()
            ok = open(io -> first(T.exec_io(host, "head -c $n /dev/zero", nothing; ask, sink = io)), f, "w")
            @test ok && filesize(f) == n
            # Stopped: the channel is closed, the command ends, the session carries on.
            ok2, _, _ = T.exec_io(host, "head -c $n /dev/zero", nothing; ask, sink = _StoppedSink())
            @test !ok2
            @test first(T.exec(host, "echo still"; ask))
            # A tunnel whose far side sends a stream and closes: every byte is delivered before the
            # local end sees the close.
            fp = 40000 + rand(0:9999)
            py = "import socket\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);" *
                 "s.bind(('127.0.0.1',$fp));s.listen(1)\nc,_=s.accept();b=bytes(1<<20)\n" *
                 "for _ in range($(n >> 20)): c.sendall(b)\nc.close()"
            @test first(T.exec(host, "nohup python3 -c '$(replace(py, "'" => "'\\''"))' >/dev/null 2>&1 & sleep 0.5"; ask))
            lp = let s = T.Sockets.listen(T.Sockets.localhost, 0); p = Int(T.Sockets.getsockname(s)[2]); close(s); p end
            @test first(T.forward!(host, lp, "127.0.0.1", fp; ask))
            sock = T.Sockets.connect(T.Sockets.localhost, lp)
            got = 0
            while !eof(sock); got += length(readavailable(sock)); end
            close(sock); T.unforward!(host, lp)
            @test got == n
            @test first(T.exec(host, "echo after"; ask))
        finally
            T.disconnect!(host)
        end
    end
end
