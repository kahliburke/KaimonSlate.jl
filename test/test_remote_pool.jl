# Unit tests for the remote bookkeeping (src/remote.jl + gate_kernel.jl): the port allocator
# (3-port stride, roster floor), the global region registry + warm-worker adoption matching, the
# claim set, parked-connection bookkeeping, and manifest parsing. Pure/local — no ssh, no
# workers; roster entries are hand-built Dicts shaped like `list_remote_workers` output.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl"))
using .ReportEngine
const RE = ReportEngine

# A roster entry as `list_remote_workers` returns it. Region/hub default to an adoptable-by-us shape.
mkworker(port; alive = true, state = "idle", region = "testreg", hub = gethostname(),
         transport = "tunnel", project = "~/.cache/kaimonslate/remote/examples",
         stream_port = port + 1) = Dict{String,Any}(
    "port" => port, "alive" => alive, "state" => state, "lastActivity" => 0, "logBytes" => 0,
    "stateSince" => 0, "stats" => "",
    "manifest" => "{\"notebook\":\"\",\"region\":\"$region\",\"hub\":\"$hub\",\"transport\":\"$transport\"," *
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

    @testset "region registry: round-trip, listing, target keyed by preload basename" begin
        name = "__regtest-$(getpid())__"
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do   # isolate regions.json from the real one
            RE.region_set!(name; host = "h1", transport = :direct, base_port = 9200,
                           preload = "/tmp/My Proj", data_root = "/scratch/flights", warm = 2, threads = "8,1")
            r = RE.region_get(name)
            @test r.host == "h1" && r.warm == 2 && r.transport === :direct && r.base_port == 9200
            @test r.preload == "/tmp/My Proj" && r.data_root == "/scratch/flights" && r.threads == "8,1"
            t = RE._region_target(r)
            @test t.project == "~/.cache/kaimonslate/remote/" * RE._proj_key("/tmp/My Proj")   # env dir isolated by preload path
            @test startswith(basename(t.project), "My_Proj-")          # readable prefix + a path hash (no cross-project collision)
            @test t.transport === :direct && t.origin_env == "/tmp/My Proj"
            @test t.datadir == "/scratch/flights" && t.region == RE._fold_region(name)  # worker is tagged with its (folded) region
            @test any(x -> x.name == RE._fold_region(name) && x.warm == 2 && x.data_root == "/scratch/flights", RE.regions())
            RE.region_set!(name; host = "h1")                          # full-record upsert clears the rest
            @test RE.region_get(name).preload == "" && RE.region_get(name).data_root == ""
            @test RE._region_target(RE.region_get(name)).project == "~/.cache/kaimonslate/remote/detached"
            @test RE._region_target(RE.region_get(name)).datadir == ""
            @test RE.region_get("__no-such-region__") === nothing
            RE.region_delete!(name)
            @test RE.region_get(name) === nothing
        end
    end

    @testset "warm-worker matching: region tag + idle + ours" begin
        @test RE._region_warm_worker(mkworker(9100; region = "gpu"), "gpu")
        @test !RE._region_warm_worker(mkworker(9100; region = "gpu"), "other")            # different region
        @test !RE._region_warm_worker(mkworker(9100; region = "", ), "gpu")               # untagged ≠ region gpu
        @test !RE._region_warm_worker(mkworker(9100; region = "gpu", alive = false), "gpu")   # dead
        @test !RE._region_warm_worker(mkworker(9100; region = "gpu", state = "attached"), "gpu") # in use
        @test !RE._region_warm_worker(mkworker(9100; region = "gpu", hub = "someone-else"), "gpu") # another hub's
    end

    @testset "claim set: exclusive, idempotent release" begin
        h = "__claimtest__"
        RE._release_region_claim!(h, 9100)                  # clean slate (idempotent on absent)
        @test !RE._region_claimed(h, 9100)
        lock(RE._REGION_CLAIM_LOCK) do; push!(RE._REGION_CLAIMS, (h, 9100)); end
        @test RE._region_claimed(h, 9100)
        @test !RE._region_claimed(h, 9103)                  # per-port
        @test !RE._region_claimed("other-host", 9100)       # per-host
        RE._release_region_claim!(h, 9100)
        @test !RE._region_claimed(h, 9100)
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

    @testset "carry cost gate: ship iff transfer beats recompute (with floors + ceiling)" begin
        MB = 2^20
        # cheap+small always ships (0.5s floor): 100KB @ 1MB/s ≈ 0.1s vs 5ms recompute
        @test RE._carry_should_ship(100_000, 5.0, 1.0e6, 30.0)
        # big+cheap skips: 80MB @ 1MB/s = 80s vs 0.3s recompute (the live case)
        @test !RE._carry_should_ship(80MB, 290.0, 1.0e6, 30.0)
        # big+expensive ships when the link affords it: 80MB @ 10MB/s = 8s vs 30min recompute
        @test RE._carry_should_ship(80MB, 1_800_000.0, 10.0e6, 30.0)
        # …but the hard ceiling still wins (never stall a notebook open): same entry, 1MB/s = 80s > cap
        @test !RE._carry_should_ship(80MB, 1_800_000.0, 1.0e6, 30.0)
        # bandwidth EMA memory round-trips per host
        h = "__bwtest-$(getpid())__"
        try
            @test RE._bw_get(h) == 0.0
            RE._bw_note!(h, 2.0e6)
            @test RE._bw_get(h) ≈ 2.0e6
            RE._bw_note!(h, 4.0e6)                      # EMA: 0.7·2e6 + 0.3·4e6 = 2.6e6
            @test RE._bw_get(h) ≈ 2.6e6
        finally
            rm(RE._bw_path(h); force = true)
        end
    end

    @testset "_manifest_get: flat JSON field extraction incl. escapes" begin
        s = "{\"a\":\"x\",\"esc\":\"say \\\"hi\\\"\",\"back\":\"a\\\\b\",\"port\":\"9100\"}"
        @test RE._manifest_get(s, "a") == "x"
        @test RE._manifest_get(s, "esc") == "say \"hi\""
        @test RE._manifest_get(s, "back") == "a\\b"
        @test RE._manifest_get(s, "port") == "9100"
        @test RE._manifest_get(s, "missing") == ""
    end

    @testset "_dev_deps: path deps detected; registry deps excluded" begin
        dir = mktempdir()
        write(joinpath(dir, "Manifest.toml"), """
        [[deps.JSON]]
        uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
        version = "0.21.4"

        [[deps.NeuroDSL]]
        deps = ["JSON"]
        path = "../NeuroDSL"
        uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

        [[deps.NeuroSlate]]
        path = "."
        uuid = "5e9a7c2b-1d4f-4a6e-b3c8-0f2a9d5e8b71"
        """)
        d = Dict(RE._dev_deps(joinpath(dir, "Manifest.toml"), dir))
        @test !haskey(d, "JSON")                                   # registry dep (no path) → not a dev dep
        @test d["NeuroDSL"] == abspath(joinpath(dir, "../NeuroDSL"))
        @test rstrip(d["NeuroSlate"], '/') == abspath(dir)         # path="." → the project itself (self-skip target)
    end

    @testset "_env_instantiate_script: rewrites Manifest AND Project.toml [sources]" begin
        s = RE._env_instantiate_script(".cache/kaimonslate/remote/NeuroSlate",
                                       [("NeuroDSL", ".cache/kaimonslate/devsrc/NeuroDSL")], false)
        @test !any(a -> a isa Expr && a.head === :error, Meta.parseall(s).args)   # valid Julia
        @test occursin("Manifest.toml", s) && occursin("Project.toml", s)
        @test occursin("\"sources\"", s)                           # the resolver-facing path (Julia ≥1.11)
        @test occursin("devsrc/NeuroDSL", s)
        # No dev deps → no TOML surgery at all, just activate + instantiate.
        s0 = RE._env_instantiate_script("x", Tuple{String,String}[], false)
        @test !occursin("sources", s0) && !occursin("parsefile", s0)
        @test occursin("Pkg.instantiate()", s0)
    end
end
