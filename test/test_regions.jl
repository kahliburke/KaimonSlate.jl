# Region data-root wiring: the two things that stamp a region's pinned data root onto a worker —
# the `RemoteTarget.datadir` field and the cold-spawn boot script that exports it as
# `KAIMONSLATE_DATADIR` (src/remote.jl). Pure/local — no ssh, no workers. The receiving
# half (`datadir()` / `__slate_materialize_datadir` resolving the same env) lives in the
# worker process, exercised by the manual remote round-trip, not here. (Region defs themselves
# are covered in test_remote_pool.jl's registry testset.)
using ReTest
using KaimonSlate

const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

@testset "region data-root wiring" begin

    @testset "RemoteTarget.datadir/region: field defaults + kwarg round-trip" begin
        @test RE.RemoteTarget("h").datadir == "" && RE.RemoteTarget("h").region == ""   # defaults
        @test RE.RemoteTarget("h"; datadir = "/scratch/flights").datadir == "/scratch/flights"
        @test RE.RemoteTarget("h"; region = "gpu").region == "gpu"
    end

    @testset "_remote_worker_script: exports KAIMONSLATE_DATADIR iff a root is pinned" begin
        t0 = RE.RemoteTarget("h"; transport = :tunnel)
        t1 = RE.RemoteTarget("h"; transport = :tunnel, datadir = "/scratch/flights")
        s0 = RE._remote_worker_script(t0, 9100, 9101, "/home/me/proj", "PUB")
        s1 = RE._remote_worker_script(t1, 9100, 9101, "/home/me/proj", "PUB")
        @test !occursin("KAIMONSLATE_DATADIR", s0)                     # no root → no env line at all
        @test occursin("ENV[\"KAIMONSLATE_DATADIR\"] = expanduser(raw\"/scratch/flights\")", s1)  # expanded on the remote
        @test occursin("PARENT_PROJECT[] = expanduser(", s1)           # project base absolute → no tilde @asset/@sfile paths
        @test findfirst("KAIMONSLATE_DATADIR", s1)[1] < findfirst("SlateWorker.start(", s1)[1]  # set BEFORE the worker boots
        @test Meta.parseall(s1) isa Expr                               # the generated script is valid Julia
    end

    # The activity monitor joins two views of an off-machine worker — the per-host ssh roster and the
    # hub's own kernels — and that join is what makes a notebook run on a plain ssh host visible at all
    # (nothing else names that host). Pure JS, so it's asserted from node; skips when node is absent.
    @testset "activity.js roster merge (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping the activity.js merge assertions"
            @test true
        else
            io = IOBuffer()
            ok = success(pipeline(`$node $(joinpath(@__DIR__, "js", "worker_merge.mjs"))`; stdout = io, stderr = io))
            ok || print(String(take!(io)))
            @test ok
        end
    end

    # A wire that goes silent used to write one identical line per 8s sweep for as long as it stayed
    # silent — a worker unresponsive for a working day produced hundreds of KB of the same sentence,
    # which buries the events that would explain it. Log the first failure, then once per interval.
    @testset "liveness log is rate-limited per kernel" begin
        k1, k2 = Ref(1), Ref(2)          # stand-ins for kernels: any object works as a WeakKeyDict key
        try
            t0 = 1.0e9
            @test NS._liveness_due_to_log!(k1, t0)                       # first failure always speaks
            @test !NS._liveness_due_to_log!(k1, t0 + 1)                  # ...then stays quiet
            @test !NS._liveness_due_to_log!(k1, t0 + NS._LIVENESS_LOG_EVERY - 1)
            @test NS._liveness_due_to_log!(k1, t0 + NS._LIVENESS_LOG_EVERY)   # ...and speaks again on the interval
            @test !NS._liveness_due_to_log!(k1, t0 + NS._LIVENESS_LOG_EVERY + 1)
            @test NS._liveness_due_to_log!(k2, t0 + 1)                   # throttled PER kernel, not globally
            # Recovery clears the clock, so the next outage is reported immediately rather than
            # being swallowed by the previous one's interval.
            delete!(NS._LIVENESS_LOG_LAST, k1)
            @test NS._liveness_due_to_log!(k1, t0 + 2)
        finally
            delete!(NS._LIVENESS_LOG_LAST, k1); delete!(NS._LIVENESS_LOG_LAST, k2)
        end
    end

    @testset "a region on a cluster is placed, not addressed" begin
        # For an ordinary machine `host` IS where the worker goes. For a cluster's front door it is
        # only where you ASK — the node is an output of the allocation — so placement is a step, and
        # the read-only view must never take that step (listing regions cannot queue for a node).
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            plain = RE.region_set!("plain"; host = "workstation")
            @test RE.region_scheduler(plain) === :none
            @test RE.region_host(plain) == "workstation"
            @test RE.region_place!(plain) == ("workstation", nothing)
            @test !RE.region_release!(plain)              # nothing was ever held

            # A scheduler region with no allocation yet reads as its login node and holds nothing —
            # the honest answer for a UI, and the reason `region_host` is separate from `region_place!`.
            gpu = RE.region_set!("gpu"; host = "login", scheduler = :slurm, walltime = "00:30:00",
                                 partition = "gpus", gpus = "1")
            @test RE.region_scheduler(gpu) === :slurm
            @test RE.region_host(gpu) == "login"
            # The job name is stable across reopens — that is what lets a notebook ATTACH to the
            # allocation it was already using instead of queueing for a second one.
            @test RE.region_alloc_name(gpu) == "slate-gpu"
            @test RE.region_alloc_name(RE.region_set!("named"; host = "login", scheduler = :slurm,
                                                      alloc_name = "mine")) == "mine"
            # A record written before the walltime field existed still gets an end time: an
            # allocation with none is the one nobody notices they are still paying for.
            @test RE._alloc_walltime(RE.region_set!("nowall"; host = "login", scheduler = :slurm)) == "01:00:00"
            @test RE._alloc_walltime(gpu) == "00:30:00"
            # Nothing is held until a node is granted, so the idle sweep has nothing to give back —
            # and must not spend a `scancel` per tick saying so.
            @test !RE._region_holds_node(gpu)
            # Configurable for PBS, and honest that it cannot allocate there.
            pbs = RE.region_set!("pbs"; host = "login", scheduler = :pbs)
            @test_throws ErrorException RE.region_place!(pbs)
        end
    end

    @testset "every cache path resolves through SlateHome" begin
        # These live in different modules, and a nested one inherits no imports — so a path that
        # compiles can still throw at the first call. Several are reached only from a code path
        # that catches and warns, which is how a broken one stays invisible. Call them all.
        withenv("KAIMONSLATE_CACHE_HOME" => mktempdir()) do
            root = KaimonSlate.SlateHome.cache_home()
            under(p) = startswith(String(p), root)
            @test under(RE._slate_cache_dir())
            @test under(RE._overflow_dir())
            @test under(NS._memo_root())
            @test under(RE.Sweep._blob_cache_dir())
            @test under(RE.Sweep.RemoteStore("", "/x").mirror)
            @test under(NS._chat_log_file("k"))
            @test under(NS._doc_cache_file())
            @test under(NS._dblob_dir())
            @test under(NS._preview_file("k"))
            NS.SlateHistory._ROOT[] = ""                      # recompute rather than reuse
            @test under(NS.SlateHistory._root())
        end
    end

end
