# Unit tests for the Phase-B remote bookkeeping (src/remote.jl + gate_kernel.jl): the port
# allocator (3-port stride, roster floor), warm-pool desired state + adoption matching, the
# claim set, parked-connection bookkeeping, and manifest parsing. Pure/local — no ssh, no
# workers; roster entries are hand-built Dicts shaped like `list_remote_workers` output.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine
const RE = ReportEngine

# A roster entry as `list_remote_workers` returns it. Pool/hub default to an adoptable-by-us shape.
mkworker(port; alive = true, state = "idle", pool = "1", hub = gethostname(),
         transport = "tunnel", project = "~/.cache/kaimonslate/remote/examples",
         stream_port = port + 1) = Dict{String,Any}(
    "port" => port, "alive" => alive, "state" => state, "lastActivity" => 0, "logBytes" => 0,
    "stateSince" => 0, "stats" => "",
    "manifest" => "{\"notebook\":\"\",\"pool\":\"$pool\",\"hub\":\"$hub\",\"transport\":\"$transport\"," *
                  "\"project\":\"$project\",\"stream_port\":\"$stream_port\"}")

@testset "remote pool + park bookkeeping" begin

    @testset "_next_ports: 3-port stride, floor pushes past a live roster" begin
        base, bstream = RE._next_ports()
        nxt, _ = RE._next_ports()
        @test nxt - base == 3                               # main/stream/data → stride 3, not 2
        @test bstream == base + 1
        floored, _ = RE._next_ports(floor = nxt + 100)
        @test floored == nxt + 100
        @test first(RE._next_ports()) == floored + 3        # counter advanced FROM the floor
        @test first(RE._next_ports(floor = 1)) > 9100       # a low floor never rewinds the counter
    end

    @testset "_port_floor: above every live worker's 3-port block; dead ports are free" begin
        @test RE._port_floor("h"; workers = Any[]) == 0
        ws = Any[mkworker(9100), mkworker(9106; alive = false), mkworker(9103)]
        @test RE._port_floor("h"; workers = ws) == 9103 + 2 + 1   # 9106 is dead → its block is free
    end

    @testset "pool config: round-trip, listing, target keyed by preload basename" begin
        host = "__pooltest-$(getpid())__"
        try
            RE._pool_config!(host; n = 2, preload = "/tmp/My Proj", transport = :direct)
            cfg = RE._pool_config(host)
            @test cfg == (n = 2, preload = "/tmp/My Proj", transport = :direct)
            t = RE._pool_target(host, cfg)
            @test t.project == "~/.cache/kaimonslate/remote/My Proj"   # same formula as _select_kernel
            @test t.transport === :direct && t.origin_env == "/tmp/My Proj"
            @test any(c -> c.host == host && c.n == 2, RE.pool_configs())
            RE._pool_config!(host; n = 0, preload = "", transport = :tunnel)
            @test RE._pool_config(host).preload == ""
            @test RE._pool_target(host, RE._pool_config(host)).project ==
                  "~/.cache/kaimonslate/remote/detached"
            @test RE._pool_config("__no-such-host__") === nothing
        finally
            rm(RE._pool_path(host); force = true)
        end
    end

    @testset "adoption predicates: candidate gate + env/transport fit" begin
        w = mkworker(9100)
        @test RE._pool_candidate(w)
        @test RE._adoptable(w, "~/.cache/kaimonslate/remote/examples", :tunnel)
        @test !RE._adoptable(w, "~/.cache/kaimonslate/remote/other", :tunnel)    # env mismatch
        @test !RE._adoptable(w, "~/.cache/kaimonslate/remote/examples", :direct) # transport mismatch
        @test !RE._pool_candidate(mkworker(9100; alive = false))                 # dead
        @test !RE._pool_candidate(mkworker(9100; state = "attached"))            # in use
        @test !RE._pool_candidate(mkworker(9100; pool = ""))                     # not a pool member
        @test !RE._pool_candidate(mkworker(9100; hub = "someone-else"))          # another hub's
    end

    @testset "claim set: exclusive, idempotent release" begin
        h = "__claimtest__"
        RE._release_pool_claim!(h, 9100)                    # clean slate (idempotent on absent)
        @test !RE._pool_claimed(h, 9100)
        lock(RE._POOL_CLAIM_LOCK) do; push!(RE._POOL_CLAIMS, (h, 9100)); end
        @test RE._pool_claimed(h, 9100)
        @test !RE._pool_claimed(h, 9103)                    # per-port
        @test !RE._pool_claimed("other-host", 9100)         # per-host
        RE._release_pool_claim!(h, 9100)
        @test !RE._pool_claimed(h, 9100)
    end

    @testset "parked wires: park on detach, unpark once, evict by port/label" begin
        t = RE.RemoteTarget("__parktest__")
        mkk(label, port) = (k = RE.GateKernel("~/proj"; label = label, target = t);
                            k.conn = :fake_conn; k.port = port; k.stream_port = port + 1; k)
        # park is refused without the preconditions (no conn / no port / not remote)
        k0 = RE.GateKernel("~/proj"; label = "np.jl", target = t); k0.port = 9100
        @test !RE.park_remote!(k0)                          # conn === nothing
        k1 = mkk("a.jl", 9100)
        @test RE.park_remote!(k1)
        k2 = mkk("b.jl", 9103)
        @test RE.park_remote!(k2)
        wires = RE.parked_wires()
        @test any(p -> p.host == "__parktest__" && p.label == "a.jl" && p.port == 9100, wires)
        # unpark pops — a second unpark misses
        p = RE.unpark_remote!("__parktest__", "a.jl")
        @test p !== nothing && p.port == 9100 && p.conn === :fake_conn
        @test RE.unpark_remote!("__parktest__", "a.jl") === nothing
        # evict by port (reap path) — the label is unknown there
        RE._evict_parked!("__parktest__"; port = 9103)
        @test RE.unpark_remote!("__parktest__", "b.jl") === nothing
        # evict by label (teardown-kill path)
        k3 = mkk("c.jl", 9106)
        @test RE.park_remote!(k3)
        RE._evict_parked!("__parktest__"; label = "c.jl")
        @test isempty([w for w in RE.parked_wires() if w.host == "__parktest__"])
    end

    @testset "_manifest_get: flat JSON field extraction incl. escapes" begin
        s = "{\"a\":\"x\",\"esc\":\"say \\\"hi\\\"\",\"back\":\"a\\\\b\",\"port\":\"9100\"}"
        @test RE._manifest_get(s, "a") == "x"
        @test RE._manifest_get(s, "esc") == "say \"hi\""
        @test RE._manifest_get(s, "back") == "a\\b"
        @test RE._manifest_get(s, "port") == "9100"
        @test RE._manifest_get(s, "missing") == ""
    end
end
