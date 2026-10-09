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
include("stubgate.jl")

# A Slurm on this machine, for a region whose `host` is "": `squeue` prints the file `queue`, and
# `scancel` appends its arguments to `cancelled` and empties the queue. A file `down` makes `squeue`
# fail, and a file `stuck` makes `scancel` fail.
function fake_slurm()
    bin = mktempdir()
    write(joinpath(bin, "squeue"), """
        #!/bin/sh
        [ -f '$bin/down' ] && exit 1
        cat '$bin/queue'
        """)
    write(joinpath(bin, "scancel"), """
        #!/bin/sh
        echo "\$*" >> '$bin/cancelled'
        [ -f '$bin/stuck' ] && exit 1
        : > '$bin/queue'
        """)
    foreach(f -> chmod(joinpath(bin, f), 0o755), ("squeue", "scancel"))
    touch(joinpath(bin, "queue"))
    return bin
end

@testset "region data-root wiring" begin

    @testset "RemoteTarget.datadir/region: field defaults + kwarg round-trip" begin
        @test RE.RemoteTarget("h").datadir == "" && RE.RemoteTarget("h").region == ""   # defaults
        @test RE.RemoteTarget("h"; datadir = "/scratch/flights").datadir == "/scratch/flights"
        @test RE.RemoteTarget("h"; region = "gpu").region == "gpu"
        @test RE.RemoteTarget("h").job == "" && RE.RemoteTarget("h"; job = "77").job == "77"
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

    @testset "a tunnelled worker still allow-lists its client" begin
        # SSH encrypts the forward, but the port it terminates on is open to every account on that
        # machine, and a NULL socket accepts whoever gets there first. CURVE is carried for the
        # allow-list, so it belongs on the tunnel transport too.
        s = RE._remote_worker_script(RE.RemoteTarget("h"; transport = :tunnel), 9100, 9101,
                                     "/home/me/proj", "CLIENTPUB")
        @test occursin("curve=true", s)
        @test occursin("allowed_clients=String[raw\"CLIENTPUB\"]", s)
        @test !occursin("allowed_clients=String[]", s)
        @test Meta.parseall(s) isa Expr
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

    # The one place that answers "is a node held", "is this worker alive", "how healthy is it" for
    # every pill, panel and roster. Four components used to answer the first for themselves, from
    # three different fields, and disagreed. Pure JS, so it's asserted from node; skips without it.
    @testset "model.js worker predicates (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping the model.js predicate assertions"
            @test true
        else
            io = IOBuffer()
            ok = success(pipeline(`$node $(joinpath(@__DIR__, "js", "worker_model.mjs"))`; stdout = io, stderr = io))
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

    @testset "a command routed into an allocation runs once" begin
        # A step inherits the job's task count, so a bare `srun` in a job asking for N tasks runs
        # the command N times. Pinned here because the allocation request and the step are written
        # in different files and neither reads as wrong on its own.
        v = (; host = "login", job = "4823", kind = :slurm)
        step = RE._in_allocation(v, "c1", "echo hi")
        @test occursin("--jobid=4823", step) && occursin("--ntasks=1", step)
        # PBS has no `srun`, so it reaches the node the way every PBS site already does.
        @test occursin("ssh ", RE._in_allocation((; host = "login", job = "9", kind = :pbs), "c1", "echo hi"))
    end

    @testset "a worker starts only inside the allocation it was built for" begin
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            RE.region_set!("node9"; host = "login", scheduler = :slurm)
            t = RE.RemoteTarget("c9"; job = "77", region = "node9")
            launch() = RE._launch_worker!(t, 9100, 9101; label = "nb", parent = "")
            place!(job) = lock(RE._REGION_PLACE_LOCK) do
                RE._REGION_PLACE["node9"] = (host = "c9", job = job, ts = time(), checked = time(),
                                             until = time() + 600)
            end
            # The allocation was released while its worker was starting, so the region holds no job.
            @test RE._allocation_route(t) === nothing
            @test_throws r"allocation 77 on c9 ended" launch()
            # Another region on the same node holds the route of the node, in its own job.
            place!("77")
            RE.route!("c9", "login", "78")
            try
                @test RE._allocation_route(t) == (host = "login", job = "77", kind = :slurm)
                # A later allocation of the region, on the same node.
                place!("79")
                @test RE._allocation_route(t) === nothing
                @test_throws r"allocation 77 on c9 ended" launch()
                # Forgetting one allocation leaves the route that names another job on the node.
                RE._unroute!("c9", "77")
                @test RE.via("c9") !== nothing
                RE._unroute!("c9", "78")
                @test RE.via("c9") === nothing
            finally
                lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "node9"); end
                RE.route!("c9", "")
            end
        end

        @testset "a node another of the user's jobs holds is launched into by a step" begin
            # `squeue -h -u $USER -w node -o %i`: the region's own job alone, or with its array and
            # het-job parts, is not shared; any other job is.
            @test !RE._other_jobs("88\n", "88") && !RE._other_jobs("88\n88_3\n88+1\n", "88") && !RE._other_jobs("", "88")
            @test RE._other_jobs("88\n91\n", "88") && RE._other_jobs("880\n", "88")
            v = (host = "login", job = "88", kind = :slurm)
            @test occursin("srun --jobid=88 --overlap", RE._srun_step(v, "true"))
            @test !RE._node_shared((host = "login", job = "7", kind = :pbs), "n1")
        end

        @testset "a worker listed under its login host is reaped on its node" begin
            man = "{\"notebook\":\"nb.jl\",\"node\":\"c7\",\"port\":\"9117\"}"
            RE.route!("c7", "login", "88")
            try
                @test RE._manifest_node(man, "login") == "c7"
            finally
                RE.route!("c7", "")
            end
            # A node no longer routed has no process left to kill; a plain host is its own node.
            @test RE._manifest_node(man, "login") == "login"
            @test RE._manifest_node("{\"node\":\"box\"}", "box") == "box" && RE._manifest_node("", "box") == "box"
        end
    end

    @testset "a sign-in that failed is not one under way" begin
        # A failed open leaves its owner task answering every request with the error, so a running
        # owner alone does not mean a login is in flight; read that way, every later sign-in to the
        # host is refused as "still under way".
        ST = KaimonSlate.SshTransport
        host = "openingtest.invalid"
        ep = ST.Endpoint(host, host, 22, "nobody", String[], "")
        s = ST.Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, ST.Prompter(host), false, "", ST.Fwd[])
        s.owner = @async sleep(30)
        try
            lock(ST._REG_LOCK) do; ST._SESSIONS[host] = s; end
            @test ST.opening(host)                   # no answer yet: in flight
            s.err = "connection refused"
            @test !ST.opening(host)                  # failed: nothing is under way
        finally
            lock(ST._REG_LOCK) do; delete!(ST._SESSIONS, host); end
        end
    end

    @testset "a session that cannot open a channel is dropped" begin
        # A transport dies quietly — the far side reboots, a NAT drops the flow, an idle timeout
        # fires — and nothing says so. `alive` is set once at authentication and never revalidated,
        # so `connected` keeps reporting a healthy session, `connect!` returns on that flag without
        # reconnecting, and every call after it fails at channel open. `session` will not replace
        # the entry either: it reuses one whose OWNER task is still running, which it is, serving a
        # transport that carries nothing. The only thing that cleared it was an interactive login,
        # which is why this is indistinguishable from broken key auth from the outside.
        ST = KaimonSlate.SshTransport
        host = "sessiontest.invalid"
        ep = ST.Endpoint(host, host, 22, "nobody", String[], "")
        s = ST.Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, ST.Prompter(host),
                       true, "", ST.Fwd[])
        try
            lock(ST._REG_LOCK) do; ST._SESSIONS[host] = s; end
            @test ST.connected(host)                       # the flag alone says healthy
            ST._channel_dead!(s, "channel_open: Unable to send channel-open request")
            @test !ST.connected(host)                      # …and now it does not
            @test !haskey(ST._SESSIONS, host)              # gone, so the next open builds a new one
            @test occursin("channel_open", s.err)          # and says why
            # Evicting only its OWN entry: a session replaced while this one was failing belongs to
            # whoever opened it, and dropping that would take a live connection down with a dead one.
            other = ST.Session(ep, Cint(-1), C_NULL, Channel{Any}(1), nothing, ST.Prompter(host),
                               true, "", ST.Fwd[])
            lock(ST._REG_LOCK) do; ST._SESSIONS[host] = other; end
            ST._channel_dead!(s, "channel_open: again")
            @test ST.connected(host) && ST._SESSIONS[host] === other
        finally
            lock(ST._REG_LOCK) do; delete!(ST._SESSIONS, host); end
        end
    end

    @testset "a region on a cluster is placed, not addressed" begin
        # For an ordinary machine `host` IS where the worker goes. For a cluster's front door it is
        # only where you ASK — the node is an output of the allocation — so placement is a step, and
        # the read-only view must never take that step (listing regions cannot queue for a node).
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            # A pinned base reaches the spawn whatever the transport. Worker records are named by
            # PORT under a directory with no host in it, so two hosts sharing a home filesystem
            # share those records — one overwrites the other's, and a reap or the roster GC then
            # deletes the files of a worker that is still running, which keeps its port and
            # vanishes from the floor the allocator reads. Disjoint bases keep both apart.
            for tr in (:tunnel, :direct)
                r = RE.region_set!("pinned_$(tr)"; host = "shared", transport = tr, base_port = 9400)
                @test RE._region_target(r).port == 9400
            end
            @test RE._region_target(RE.region_set!("unpinned"; host = "shared")).port == 0

            plain = RE.region_set!("plain"; host = "workstation")
            @test RE.region_scheduler(plain) === :none
            @test RE.region_host(plain) == "workstation"
            @test RE.region_place!(plain) == ("workstation", nothing)
            @test !RE.region_release!(plain)              # nothing was ever held

            # A scheduler region with no allocation yet reads as its login node and holds nothing —
            # the honest answer for a UI, and the reason `region_host` is separate from `region_place!`.
            # Prepared, so the tests below reach placement; preparing is tested on its own.
            gpu = RE.region_set!("gpu"; host = "login", scheduler = :slurm, walltime = "00:30:00",
                                 partition = "gpus", gpus = "1",
                                 readiness = Dict{String,Any}("prepared_at" => 1.0, "stale" => ""))
            @test RE.region_scheduler(gpu) === :slurm
            @test RE.region_host(gpu) == "login"
            # Its workers use the CPUs the allocation holds; an ordinary host keeps the shared default.
            @test RE.region_threads(RE.region_set!("thr"; host = "login", scheduler = :slurm, cpus = 32)) == "30,2"
            @test RE.region_threads(RE.region_set!("thr"; cpus = 2)) == "2,1"
            @test RE.region_threads(RE.region_set!("thr"; threads = "16,1")) == "16,1"
            @test RE.region_threads(plain) == ""

            @testset "an auto region asks its host which scheduler it runs" begin
                bin = mktempdir()
                write(joinpath(bin, "sinfo"), """
                    #!/bin/sh
                    case "\$*" in
                      *--version*) echo "slurm 24.05.1" ;;
                      *) echo "PART slurm batch|gpu:A100:8|infinite|up" ;;
                    esac
                    """)
                write(joinpath(bin, "sbatch"), "#!/bin/sh\nexit 0\n")
                foreach(f -> chmod(joinpath(bin, f), 0o755), ("sinfo", "sbatch"))
                withenv("PATH" => bin * ":" * ENV["PATH"]) do
                    det = RE.Sweep.detect_scheduler("")
                    @test RE.Sweep.SchedulerDetect.kinds(det) == [:slurm]
                    p = only(RE.Sweep.SchedulerDetect.scheduler(det, :slurm).partitions)
                    @test (p.name, p.gpus, p.maxtime, p.up) == ("batch", "gpu:A100:8", "infinite", true)
                    @test RE.region_scheduler(RE.region_set!("auto_local"; host = "", scheduler = :auto)) === :slurm
                end
            end
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

            # ── the record every panel reads ──────────────────────────────────────────────────
            # Four components used to work out "is a node held" for themselves, from four different
            # fields, and disagreed: the same worker read as held in one panel and free in another.
            # The answer is given here, once, so none of them has to derive it.
            @testset "allocation facts say held rather than implying it" begin
                # Absence means only one thing now: the question does not apply. The main kernel has
                # no region, and an ordinary host has no scheduler to hold anything.
                @test isempty(NS._region_alloc_facts(""))
                @test isempty(NS._region_alloc_facts("plain"))
                @test isempty(NS._region_alloc_facts("no-such-region"))

                # A scheduler region with no node SAYS so. Reading this as "not applicable" (which is
                # what an empty answer would have meant) is what hid a released node behind a Release
                # button.
                f = NS._region_alloc_facts("gpu")
                @test f["scheduler"] == "slurm"
                @test f["held"] === false && f["allocState"] == "none"
                # ...and nothing that only makes sense for a held node comes along with it.
                @test !any(haskey(f, k) for k in ("walltimeLeft", "idleFor", "idleRelease"))

                # Queued is HELD: a request in the scheduler's queue is withdrawn, not ignored, and a
                # panel that treated it as nothing offered no way to take it back.
                lock(NS._PLACING_LOCK) do; push!(NS._PLACING, "gpu"); end
                try
                    q = NS._region_alloc_facts("gpu")
                    @test q["held"] === true && q["allocState"] == "pending"
                finally
                    lock(NS._PLACING_LOCK) do; delete!(NS._PLACING, "gpu"); end
                end

                # A granted node is `running`, and only then do the clocks appear.
                RE.route!("c9", "login", "77")
                lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["gpu"] = (host = "c9", job = "77", ts = time(),
                                               checked = time(), until = time() + 600)
                end
                try
                    g = NS._region_alloc_facts("gpu")
                    @test g["held"] === true && g["allocState"] == "running"
                    @test 0 < g["walltimeLeft"] <= 600
                finally
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    RE.route!("c9", "")
                end
            end

            @testset "a region whose job the cluster took back is placed again" begin
                # The scheduler is asked only after a worker failed to start. A placement that names a
                # job it no longer holds is forgotten, so the next run asks for a node; one it still
                # holds, or a scheduler nobody could ask, is left alone.
                RE.region_set!("lost"; host = "", scheduler = :slurm, walltime = "00:30:00")
                bin = mktempdir()
                squeue(body) = (p = joinpath(bin, "squeue"); write(p, "#!/bin/sh\n" * body * "\n"); chmod(p, 0o755))
                place!() = lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["lost"] = (host = "c9", job = "77", ts = time(),
                                                checked = time(), until = time() + 600)
                end
                held() = lock(RE._REGION_PLACE_LOCK) do; haskey(RE._REGION_PLACE, "lost"); end
                try
                    withenv("PATH" => bin * ":" * ENV["PATH"]) do
                        squeue("echo '77|RUNNING|c9|20:00|N/A|None|32'")
                        place!()
                        @test !NS._allocation_gone!("lost") && held()
                        squeue("exit 1")                                     # nobody answered
                        @test !NS._allocation_gone!("lost") && held()
                        squeue("echo '78|RUNNING|c4|30:00|N/A|None|32'")     # a different job
                        @test NS._allocation_gone!("lost") && !held()
                        place!(); squeue("exit 0")                           # nothing at all
                        @test NS._allocation_gone!("lost") && !held()
                        @test !NS._allocation_gone!("lost")                  # nothing placed to forget
                        # A kernel built in a job the placement no longer names is gone, asked of nobody.
                        place!(); squeue("exit 1")
                        k = RE.GateKernel(mktempdir())
                        k.target = RE.RemoteTarget("c9"; job = "76", region = "lost")
                        @test NS._allocation_gone!("lost", k) && held()
                        k.target = RE.RemoteTarget("c9"; job = "77", region = "lost")
                        @test !NS._allocation_gone!("lost", k)
                        # The job of a forgotten placement is not placed on again while it is still ending.
                        @test RE.region_forget_placement!(RE.region_get("lost")) && RE._gave_up_recently("77")
                        @test !RE._gave_up_recently("78")
                    end
                finally
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "lost"); end
                    RE.region_delete!("lost")
                end
            end

            @testset "a region's cells go stale when its worker is replaced" begin
                # The new process has none of their bindings: the cells that ran there, a locked one
                # and an untagged mutator of a region value included, run again; the rest are kept.
                rep = RE.parse_report("#%% code id=v region=gpu\nv = [1]\n" *
                                      "#%% code id=f region=gpu locked\nf = 2\n" *
                                      "#%% code id=m\npush!(v, 3)\n" *
                                      "#%% code id=h\nh = 4\n")
                RE.build_dependencies!(rep)
                nb = NS.LiveNotebook("restale", joinpath(mktempdir(), "restale.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                for c in rep.cells; c.state = RE.FRESH; end
                @test sort(NS._restale_side!(nb, "gpu")) == ["f", "m", "v"]
                @test [c.state for c in rep.cells] == [RE.STALE, RE.STALE, RE.STALE, RE.FRESH]
            end

            @testset "a new allocation on the same node rebuilds the region kernel" begin
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n")
                nb = NS.LiveNotebook("alloc", joinpath(mktempdir(), "alloc.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                place!(job; host = "c9") = lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["gpu"] = (host = host, job = job, ts = time(),
                                               checked = time(), until = time() + 600)
                end
                synced() = lock(NS._REGION_LOCK) do; sort!(collect(keys(get(NS._REGION_SYNCED, "alloc", Dict())))); end
                RE.route!("c9", "login", "77")
                try
                    place!("77")
                    k = NS._region_kernel!(nb, "gpu")
                    @test (k.target.ssh_host, k.target.job) == ("c9", "77")
                    @test NS._region_kernel!(nb, "gpu") === k
                    # Values already shipped: one to this region's worker, one to the main kernel.
                    lock(NS._REGION_LOCK) do
                        NS._REGION_SYNCED["alloc"] = Dict("gpu:x:g1" => "t", "main:y:g1" => "t")
                    end
                    place!("78")
                    k2 = NS._region_kernel!(nb, "gpu")
                    @test k2 !== k && k2.target.job == "78"
                    @test NS._region_kernel!(nb, "gpu") === k2
                    # The new worker holds nothing yet, so only the region's sync record goes.
                    @test synced() == ["main:y:g1"]
                    # A grant on another node rebuilds too, even when the old kernel's session was lost:
                    # its node went with its allocation, so there is nothing there to sign in to again.
                    lock(NS._LOST_SESSION_LOCK) do; NS._LOST_SESSION[k2] = "c9"; end
                    place!("79"; host = "c10")
                    k3 = NS._region_kernel!(nb, "gpu")
                    @test k3 !== k2 && (k3.target.ssh_host, k3.target.job) == ("c10", "79")
                    @test lock(() -> !haskey(NS._LOST_SESSION, k2), NS._LOST_SESSION_LOCK)
                    # Released: no job left, so no cached kernel can match it.
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    @test RE.region_where(RE.region_get("gpu")) == ("login", "")
                finally
                    NS._forget_region_kernel!(nb, "gpu")
                    lock(NS._REGION_LOCK) do; delete!(NS._REGION_SYNCED, "alloc"); end
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    RE.route!("c9", "")
                end
            end

            @testset "a node is asked for by a run, not by opening" begin
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n#%% code id=d\n2\n")
                nb = NS.LiveNotebook("opening", joinpath(mktempdir(), "opening.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                lock(NS._OPENING_RUN_LOCK) do; push!(NS._OPENING_RUN, "opening"); end
                try
                    # Nothing held: the opening run leaves the cell waiting instead of queueing.
                    e = try; NS._region_kernel!(nb, "gpu"); nothing; catch err; err; end
                    @test e isa NS.RegionWaiting && e.why == NS.WAIT_NOT_REQUESTED
                    @test isempty(lock(() -> copy(NS._PLACING), NS._PLACING_LOCK))
                    # A node already held is used: attaching to it costs nothing more.
                    RE.route!("c9", "login", "77")
                    lock(RE._REGION_PLACE_LOCK) do
                        RE._REGION_PLACE["gpu"] = (host = "c9", job = "77", ts = time(),
                                                   checked = time(), until = time() + 600)
                    end
                    k = NS._region_kernel!(nb, "gpu")
                    @test k.target.job == "77" && !NS._region_kernel_released("gpu", k)
                    # The node is given back: the kernel's worker went with it, and its pill says so.
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    @test NS._region_kernel_released("gpu", k)
                    @test NS._worker_entry(nb, "gpu", k)["face"] == "node released"
                finally
                    lock(NS._OPENING_RUN_LOCK) do; delete!(NS._OPENING_RUN, "opening"); end
                    NS._forget_region_kernel!(nb, "gpu")
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    RE.route!("c9", "")
                end
                # A run of the notebook takes up the waiting cell; a settled one is left alone.
                c, d = rep.cells
                RE.mark_blocked!(c, NS.WAIT_NOT_REQUESTED, "login")
                d.state = RE.FRESH
                lock(NS._OPENING_RUN_LOCK) do; push!(NS._OPENING_RUN, "opening"); end
                @test NS._restale_blocked!(nb) == 1
                @test c.state == RE.STALE && d.state == RE.FRESH
                @test !NS._in_opening_run("opening")    # the run is the request, mid-opening or not
            end

            @testset "a first worker for a project waits for the region to be prepared" begin
                d = mktempdir()
                write(joinpath(d, "Project.toml"), "name = \"P\"\n")
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n")
                nb = NS.LiveNotebook("needsprep", joinpath(d, "nb.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                why() = try; NS._region_kernel!(nb, "gpu"); ""; catch e; e isa NS.RegionWaiting ? e.why : "error"; end
                saved = RE.region_get("gpu").readiness
                try
                    # The site is prepared but this project was never tried here.
                    @test why() == NS.WAIT_NEEDS_PREPARE
                    # Tried: it goes on to placement (here, the opening run's wait).
                    rg = RE.region_get("gpu")
                    RE.record_env_test!(rg.host, d, RE.region_node_type(rg); by = "gpu", status = "ok",
                                        depot = RE.region_depot(rg), load_s = 1.0)
                    lock(NS._OPENING_RUN_LOCK) do; push!(NS._OPENING_RUN, "needsprep"); end
                    @test why() == NS.WAIT_NOT_REQUESTED
                    # Its packages changed after they were tested: the install belongs in a prepare.
                    write(joinpath(d, "Project.toml"), "name = \"P\"\n[deps]\nX = \"1\"\n")
                    @test why() == NS.WAIT_NEEDS_PREPARE
                    r = RE.region_get("gpu")
                    @test NS._prepare_reason(r, d) == "Since the last prepare, X was added."
                    @test only(values(RE.readiness_view(r)["envs"]))["changed"] === true
                    write(joinpath(d, "Project.toml"), "name = \"P\"\n")
                    @test why() == NS.WAIT_NOT_REQUESTED
                    # A machine that changed since sends it back through preparing.
                    gh = RE.region_get("gpu").host
                    RE.host_facts_merge!(gh, Dict{String,Any}("stale" => "changed"))
                    @test why() == NS.WAIT_NEEDS_PREPARE
                    RE.host_facts_set!(gh, Dict{String,Any}())
                    # A region never prepared at all, likewise.
                    RE.region_set!("gpu"; readiness = Dict{String,Any}())
                    @test why() == NS.WAIT_NEEDS_PREPARE
                    # While it is being prepared its cells wait; the prepare's own start goes ahead.
                    c = only(nb.report.cells)
                    lock(RE._PREPARING_LOCK) do
                        RE._PREPARING[RE._fold_region("gpu")] = Dict{String,Any}("running" => true)
                    end
                    try
                        @test why() == NS.WAIT_PREPARING
                        # A cell already waiting says what for, and the pill says preparing, not queued.
                        RE.mark_blocked!(c, NS.WAIT_NEEDS_PREPARE, "login", "gpu")
                        NS._mark_region_preparing!(nb, "gpu")
                        @test c.blocked == NS.WAIT_PREPARING && c.blocked_region == "gpu"   # still the region it waits for
                        # (Signed out outranks it: nothing can start until someone signs in.)
                        w = only(filter(w -> w["side"] == "gpu", NS._workers_json(nb)))
                        @test w["face"] == (get(w, "noteCode", "") == "not_signed_in" ? "signed out" : "preparing")
                        @test get(w, "noteCode", "") == "not_signed_in" || occursin("being prepared", w["note"])
                        own = try; NS._region_kernel!(nb, "gpu"; preparing = true); ""
                              catch e; e isa NS.RegionWaiting ? e.why : "error"; end
                        @test own != NS.WAIT_PREPARING && own != NS.WAIT_NEEDS_PREPARE
                        RE.mark_blocked!(c, NS.WAIT_PREPARING, "login", "gpu")
                        @test isempty(NS._prepared_regions_waiting(nb))          # still preparing
                    finally
                        lock(RE._PREPARING_LOCK) do; delete!(RE._PREPARING, RE._fold_region("gpu")); end
                        NS._forget_region_kernel!(nb, "gpu")
                    end
                    @test NS._prepared_regions_waiting(nb) == Set(["gpu"])     # done: they run
                    # Told a prepare was needed, a cell waits for one to succeed, started from
                    # anywhere, rather than being re-run into the same answer every tick.
                    RE.mark_blocked!(c, NS.WAIT_NEEDS_PREPARE, "login", "gpu")
                    @test isempty(NS._prepared_regions_waiting(nb))
                    RE.region_set!("gpu"; readiness = Dict{String,Any}("ok" => false, "prepared_at" => time() + 1))
                    @test isempty(NS._prepared_regions_waiting(nb))              # a failed one does not count
                    RE.region_set!("gpu"; readiness = Dict{String,Any}("ok" => true, "prepared_at" => time() + 1))
                    @test NS._prepared_regions_waiting(nb) == Set(["gpu"])
                finally
                    lock(NS._OPENING_RUN_LOCK) do; delete!(NS._OPENING_RUN, "needsprep"); end
                    RE.region_set!("gpu"; readiness = saved)
                end
            end

            @testset "facts: one description of the hub, published as a diff" begin
                # A worker entry as a fact holds still between real changes: no telemetry, and the
                # instant a duration counts from rather than the duration.
                f = NS._worker_fact(Dict{String,Any}("side" => "gpu", "stats" => "{}", "clockSamples" => 9,
                                                     "clockRttMs" => 1.234, "walltimeLeft" => 600, "idleFor" => 12))
                @test !haskey(f, "stats") && !haskey(f, "clockSamples") && f["clockRttMs"] == 1.2
                @test abs(f["until"] - (time() + 600)) < 2 && abs(f["lastUsed"] - (time() - 12)) < 2
                @test !haskey(f, "walltimeLeft") && !haskey(f, "idleFor")

                rep = RE.parse_report("#%% code id=c\n1\n")
                nb = NS.LiveNotebook("factsnb", joinpath(mktempdir(), "factsnb.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                hub = (lock = ReentrantLock(), notebooks = Dict{String,Any}("factsnb" => nb))
                prev = NS._FACTS_HUB[]
                ch = Channel{String}(16)
                lock(() -> push!(NS._FACT_LISTENERS, ch), NS._FACT_LISTENERS_LOCK)
                try
                    NS._FACTS_HUB[] = hub
                    lock(() -> empty!(NS._FACTS), NS._FACTS_LOCK)
                    r1 = NS.facts_refresh!()
                    first_frame = KaimonSlate.JSON.parse(take!(ch))
                    r2 = NS.facts_refresh!()                      # nothing changed: nothing sent
                    quiet = !isready(ch)
                    delete!(hub.notebooks, "factsnb")
                    r3 = NS.facts_refresh!()
                    gone = KaimonSlate.JSON.parse(take!(ch))
                    @test haskey(first_frame["set"], "worker/factsnb/") && first_frame["rev"] == r1
                    # The region registry is published beside the workers.
                    @test all(haskey(first_frame["set"], "region/" * r.name) for r in RE.regions())
                    @test (r2, quiet) == (r1, true)
                    @test r3 == r1 + 1 && "worker/factsnb/" in gone["del"]
                    @test NS.facts_snapshot()["rev"] == r3
                    # A worker no notebook holds sends its samples under the host and port its roster
                    # lists it by.
                    NS._telemetry_push!(hub, "slate-login-node-9106", (cpu = 3.0,))
                    smp = KaimonSlate.JSON.parse(take!(ch))
                    @test (smp["t"], smp["key"]) == ("sample", "roster/login-node:9106")
                finally
                    NS._FACTS_HUB[] = prev
                    lock(() -> filter!(c -> c !== ch, NS._FACT_LISTENERS), NS._FACT_LISTENERS_LOCK)
                end
            end

            @testset "a source change reaches its host copy, and only the change travels" begin
                srcdir, dest = mktempdir(), mktempdir()
                mkpath(joinpath(srcdir, "src", "sub")); mkpath(joinpath(srcdir, "ext"))
                write(joinpath(srcdir, "src", "A.jl"), "a"); write(joinpath(srcdir, "src", "sub", "b.jl"), "b")
                write(joinpath(srcdir, "notes.txt"), "n"); write(joinpath(srcdir, "src", "x.cov"), "c")
                cp(srcdir, dest; force = true)                       # the copy as a provision left it
                ex = [".git", "*.cov"]
                @test sort!(collect(keys(RE._sync_files(srcdir, ex)))) == ["src/A.jl", "src/sub/b.jl"]
                s = RE.SyncSource(srcdir)
                d = RE.SyncDest("", dest, ex, "", RE._sync_files(srcdir, ex), Dict{String,Any}(), false)
                write(joinpath(srcdir, "src", "sub", "b.jl"), "bb")  # a subfolder, a new extension, a removal
                write(joinpath(srcdir, "ext", "E.jl"), "e"); rm(joinpath(srcdir, "src", "A.jl"))
                write(joinpath(srcdir, "notes.txt"), "changed")      # outside what is watched
                @test RE._sync_dest!(s, d, RE._sync_files(srcdir, ex))
                @test (read(joinpath(dest, "src", "sub", "b.jl"), String), isfile(joinpath(dest, "ext", "E.jl")),
                       isfile(joinpath(dest, "src", "A.jl")), read(joinpath(dest, "notes.txt"), String)) ==
                      ("bb", true, false, "n")
                @test d.sent == RE._sync_files(srcdir, ex)
            end

            @testset "each checkout of a package has its own copy on a host" begin
                # Named by the local path, so two worktrees of one package do not share a copy, and one
                # checkout keeps its copy whichever branch it is on.
                mktempdir() do d
                    a = mkpath(joinpath(d, "feature-a", "Pkg.jl")); b = mkpath(joinpath(d, "feature-b", "Pkg.jl"))
                    pa, pb = RE._devsrc_path(a), RE._devsrc_path(b)
                    @test pa != pb && startswith(pa, RE._REMOTE_DEVSRC * "/") && endswith(pa, "-feature-a-Pkg.jl")
                    symlink(a, joinpath(d, "link"))
                    @test RE._devsrc_path(joinpath(d, "link")) == pa && RE._devsrc_path(a * "/") == pa
                end
            end

            @testset "a copy taken up again sends only what changed since" begin
                # What a copy was sent is kept on disk, so after a reattach or a hub restart its first
                # comparison starts from that record rather than from nothing.
                srcdir, dest, cache = mktempdir(), mktempdir(), mktempdir()
                withenv("KAIMONSLATE_CACHE_HOME" => cache) do
                    mkpath(joinpath(srcdir, "src"))
                    write(joinpath(srcdir, "src", "A.jl"), "a"); write(joinpath(srcdir, "src", "B.jl"), "b")
                    ex = [".git"]; key = ":" * dest
                    s = RE.SyncSource(srcdir)
                    d = RE.SyncDest("", dest, ex, "", Dict{String,Tuple{Int,Float64}}(), Dict{String,Any}(), false)
                    @test RE._sync_dest!(s, d, RE._sync_files(srcdir, ex))          # all of it, the first time
                    @test RE._sent_record_load(srcdir, key) == d.sent
                    d2 = RE.SyncDest("", dest, ex, "", RE._sent_record_load(srcdir, key), Dict{String,Any}(), false)
                    rm(joinpath(dest, "src", "A.jl"))            # would come back if it were sent again
                    @test RE._sync_dest!(s, d2, RE._sync_files(srcdir, ex)) && !isfile(joinpath(dest, "src", "A.jl"))
                    write(joinpath(srcdir, "src", "B.jl"), "b2")  # edited meanwhile
                    @test RE._sync_dest!(s, d2, RE._sync_files(srcdir, ex)) && read(joinpath(dest, "src", "B.jl"), String) == "b2"
                    @test isempty(RE._sent_record_load(srcdir, ":/elsewhere"))     # another copy has its own
                end
            end

            @testset "a file removed in a git project is removed from its host copy" begin
                # git's verdict is read off the files that exist, so a deleted one must not be judged by it.
                srcdir, dest = mktempdir(), mktempdir()
                mkpath(joinpath(srcdir, "src"))
                write(joinpath(srcdir, "src", "A.jl"), "a"); write(joinpath(srcdir, "src", "B.jl"), "b")
                run(pipeline(`git -C $srcdir init -q`; stdout = devnull, stderr = devnull))
                cp(srcdir, dest; force = true)
                s = RE.SyncSource(srcdir)
                d = RE.SyncDest("", dest, [".git"], "", RE._sync_files(srcdir, [".git"]), Dict{String,Any}(), false)
                rm(joinpath(srcdir, "src", "B.jl"))
                @test RE._sync_dest!(s, d, RE._sync_files(srcdir, [".git"]))
                @test (isfile(joinpath(dest, "src", "A.jl")), isfile(joinpath(dest, "src", "B.jl"))) == (true, false)
            end

            @testset "the sync holds back what the transfer rules hold back" begin
                # A project with no `src/` syncs its top-level files, the notebook among them. The rules
                # a provision applies keep it off the host, and the sync honours them too, rather than
                # sending it for the next provision to remove.
                srcdir, dest = mktempdir(), mktempdir()
                write(joinpath(srcdir, "nb.jl"), "1"); write(joinpath(srcdir, "code.jl"), "c")
                write(joinpath(srcdir, ".slateignore"), "nb.jl\n")
                cp(joinpath(srcdir, "code.jl"), joinpath(dest, "code.jl"))
                ex = [".git", "*.cov"]
                s = RE.SyncSource(srcdir)
                d = RE.SyncDest("", dest, ex, "", RE._sync_files(srcdir, ex), Dict{String,Any}(), false)
                write(joinpath(srcdir, "nb.jl"), "2")
                @test RE._sync_dest!(s, d, RE._sync_files(srcdir, ex))
                @test !isfile(joinpath(dest, "nb.jl"))
                @test d.sent == RE._sync_files(srcdir, ex)          # seen, so not judged again until it changes
                write(joinpath(srcdir, "code.jl"), "c2")
                @test RE._sync_dest!(s, d, RE._sync_files(srcdir, ex))
                @test read(joinpath(dest, "code.jl"), String) == "c2"

                # A provision removes from the host what the rules hold back, and says so only when
                # something was there.
                write(joinpath(dest, "nb.jl"), "stale")
                RE._prune_remote!("", srcdir, dest, "", ex)
                @test !isfile(joinpath(dest, "nb.jl")) && isfile(joinpath(dest, "code.jl"))
                RE._prune_remote!("", srcdir, dest, "", ex)            # nothing there: nothing to do
                @test isfile(joinpath(dest, "code.jl"))
            end

            @testset "a worker host is sent the worker's code, not the hub's" begin
                files = RE._payload_files()
                # What worker.jl includes, directly, transitively, and through the name lists the
                # shared files include in a loop.
                @test all(in(files), ("worker.jl", "sweep.jl", "remotestore.jl", "sshtransport.jl",
                                      "sshauth.jl", "slate_home.jl", "memostore.jl", "capture.jl"))
                @test !any(in(files), ("server.jl", "server_export.jl", "KaimonSlate.jl", "remote.jl"))
                # Every file it names exists, so a worker never boots short of one.
                @test all(f -> isfile(joinpath(pkgdir(KaimonSlate), "src", f)), files)
                @test RE._payload_sha() != RE._src_sha()          # hub-only edits leave workers current
                # It arrives as the SlateWorker package, which the worker env develops and the boot loads.
                @test all(in(files), RE._WORKER_PKG_FILES)
                @test occursin(RE._remote_worker_pkg(), RE._worker_develop())
                # One directory per version of the worker code, so hubs on different versions keep theirs.
                @test startswith(RE._remote_worker_pkg(), RE._runtime_dir()) && occursin(RE._runtime_key(), RE._runtime_dir())
                s = RE._remote_worker_script(RE.RemoteTarget("h"; transport = :tunnel), 9100, 9101, "/p", "PUB")
                @test occursin("using SlateWorker", s) && !occursin("include(", s)
                @test findfirst("using SlateWorker", s)[1] < findfirst("using Revise", s)[1]
            end

            @testset "a reap is one command that kills the worker and not itself" begin
                # On a compute node every command is a hop from the login node, so the reap asks once.
                # `pkill -f` reads whole command lines, and the reap's own names the worker it kills.
                mktempdir() do home
                    cd(home) do
                        d = joinpath(home, RE._REMOTE_WORKER); mkpath(d)
                        port = 59871
                        for x in ("jl", "log", "json", "state", "stats")
                            write(joinpath(d, "worker-$port.$x"), "x")
                        end
                        # A compound command, so the shell stays (a lone `sleep` replaces it, and the
                        # process would no longer carry the worker's name).
                        proc = run(`sh -c "sleep 60; true" worker-$port.jl`; wait = false)
                        @test RE.reap_remote_worker("", port)
                        @test timedwait(() -> !process_running(proc), 5.0; pollint = 0.05) === :ok
                        @test !any(isfile(joinpath(d, "worker-$port.$x")) for x in ("jl", "log", "json", "state", "stats"))
                        @test !RE.reap_remote_worker("", port)        # nothing left: says so
                    end
                end
            end

            @testset "the scheduler-use view reads the history a host's commands left" begin
                withenv("KAIMONSLATE_CACHE_HOME" => mktempdir()) do
                    p = RE.Sweep._sched_history_path(); mkpath(dirname(p))
                    m = floor(Int, time() / 60) - 30
                    stamp = RE.Sweep.Dates.format(RE.Sweep.Dates.unix2datetime(m * 60), "yyyy-mm-ddTHH:MM")
                    write(p, "{\"minute\": \"$(stamp)Z\", \"host\": \"login\", \"total\": 3, \"by\": {\"squeue find_allocation\": 2, \"srun _in_allocation\": 1}}\n" *
                             "{\"minute\": \"$(stamp)Z\", \"host\": \"other\", \"total\": 9, \"by\": {\"squeue x\": 9}}\n")
                    v = NS._sched_calls_view("login", 1)
                    @test (v["in_window"], v["peak"], v["over"]) == (3, 3, 1) && only(v["series"])[2] == 3
                    @test [(r["command"], r["caller"], r["n"]) for r in v["by"]] ==
                          [("squeue", "find_allocation", 2), ("srun", "_in_allocation", 1)]
                    @test NS._sched_calls_view("login", 0.25)["in_window"] == 0      # older than the window
                end
            end

            @testset "a remote process match reads only the user's own processes" begin
                # Reading another user's command line can block on a login node, and `pgrep -f` reads them all.
                code = [l for f in ("remote.jl", "publish_targets.jl")
                        for l in eachline(joinpath(pkgdir(KaimonSlate), "src", f)) if !startswith(lstrip(l), "#")]
                @test !any(l -> occursin(r"\bp(grep|kill)( -[A-Z]+)? -f", l), code)
                @test occursin("pgrep -u \"\$USER\" -f", RE._WORKERS_PROBE_SH)
            end

            @testset "a prepare's compile is recorded in the environment's stamp" begin
                proj, home = mktempdir(), mktempdir()
                write(joinpath(proj, "Project.toml"), "name = \"P\"\n")
                t = RE.RemoteTarget(""; project = joinpath(home, "env"), origin_env = proj)
                jv = "julia version 1.12.7"
                @test RE.stamp_env_precompiled!(t, proj, jv)
                got = read(RE._env_stamp_path(t), String)
                @test got == RE._env_stamp_for(t, proj, jv; precompiled = true)
                # A start (which wants it compiled) finds nothing to build.
                @test RE._env_stamp_serves(got, RE._env_stamp_for(t, proj, jv; precompiled = true))
                # Only fetched, it serves a fetch and not a start.
                fetched = RE._env_stamp_for(t, proj, jv; precompiled = false)
                @test !RE._env_stamp_serves(fetched, RE._env_stamp_for(t, proj, jv; precompiled = true))
            end

            @testset "a save reaches the copy without anything asking for it" begin
                proj, dest = mktempdir(), mktempdir()
                mkpath(joinpath(proj, "src")); write(joinpath(proj, "src", "P.jl"), "p")
                cp(proj, dest; force = true)
                t = RE.RemoteTarget(""; project = dest)
                try
                    RE.start_sync!(t, proj; sent = true)
                    sleep(0.3)
                    write(joinpath(proj, "src", "P.jl"), "edited")
                    f = joinpath(dest, "src", "P.jl")
                    @test timedwait(() -> read(f, String) == "edited", 5.0; pollint = 0.05) === :ok
                finally
                    RE.stop_sync!(t)
                end
                @test !haskey(RE._SYNC_SOURCES, proj)
            end

            @testset "one watch per source directory, kept while a kernel uses a copy of it" begin
                proj = mktempdir(); mkpath(joinpath(proj, "src")); write(joinpath(proj, "src", "P.jl"), "p")
                t1 = RE.RemoteTarget("synchost"; project = "~/r/one", job = "5")
                t2 = RE.RemoteTarget("synchost"; project = "~/r/two", job = "5")
                RE.start_sync!(t1, proj; sent = true); RE.start_sync!(t2, proj; sent = true)
                @test length(lock(() -> RE._SYNC_SOURCES[proj].dests, RE._SYNC_LOCK)) == 2
                RE.stop_sync!(t1)
                @test haskey(RE._SYNC_SOURCES, proj)                 # the other kernel still uses it
                RE.stop_sync_job!("synchost", "5")
                @test !haskey(RE._SYNC_SOURCES, proj)
            end

            @testset "a worker's process is read from outside when it sends nothing" begin
                r = NS._proc_cpu_rss(getpid())
                @test r !== nothing && r[1] > 0 && r[2] > 0
                # In seconds: half a second spent computing reads as about that much CPU time.
                burn() = (t = time(); x = 0.0; while time() - t < 0.5; x += sin(x); end; x)
                c0 = NS._proc_cpu_rss(getpid())[1]; burn()
                @test NS._proc_cpu_rss(getpid())[1] - c0 > 0.3
                @test NS._proc_cpu_rss(typemax(Int32)) === nothing    # no such process
            end

            @testset "a worker's crash is reported where it happened" begin
                log = """
                [ Info: slate eval: ran cell
                └  cell = "more_imports"

                [44773] signal 11 (2): Segmentation fault: 11
                in expression starting at cell:model_cycles:2
                potential_derivatives at /src/potentialgrid.jl:0 [inlined]
                #_qfm_system#262 at /src/qfm.jl:81
                closed_orbit at /src/cycles.jl:35 [inlined]
                unknown function (ip: 0x70361d458b) at (unknown file)
                jl_apply at julia.h:2394 [inlined]
                start_task at task.c:1253
                Allocations: 136699565 (Pool: 136696745; Big: 2820); GC: 62
                """
                @test RE.crash_report(log) == "signal 11 (2): Segmentation fault: 11, in cell model_cycles\n" *
                    "  potential_derivatives at /src/potentialgrid.jl:0\n  #_qfm_system#262 at /src/qfm.jl:81\n" *
                    "  closed_orbit at /src/cycles.jl:35"
                @test RE.crash_report("[ Info: all fine\n") == ""
            end

            @testset "a node's worker is filed under its login host after its route is gone" begin
                RE.region_set!("filedtest"; host = "loginx", scheduler = :slurm)
                @test NS._filed_under(RE.RemoteTarget("nodey"; region = "filedtest")) == "loginx"
                @test NS._filed_under(RE.RemoteTarget("loginx"; region = "filedtest")) == ""
                @test NS._filed_under(RE.RemoteTarget("nodey")) == ""
                RE.region_delete!("filedtest")
            end

            @testset "telemetry is watched only on workers this hub started and nothing holds" begin
                ws = Any[Dict{String,Any}("port" => 9300, "alive" => true, "state" => "idle",
                                          "manifest" => "{\"hub\":\"elsewhere\",\"stream_port\":\"9301\"}")]
                RE._watch_roster!("not-signed-in.invalid", ws)     # no session: nothing to watch over
                RE._watch_roster!("x", ws)                          # not ours either way
                @test isempty(RE.watched_workers()) && isempty(RE._WATCH_DIALING)
            end

            @testset "a ▶ on a cell already running its code does not queue a second run" begin
                rep = RE.parse_report("#%% code id=r\n1\n")
                nb = NS.LiveNotebook("rerun", joinpath(mktempdir(), "rerun.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                nb.closed = true
                c = only(rep.cells)
                RE.mark_running!(c)
                try
                    NS.edit_cell!(nb, "r", c.source; force = true, run = false)
                    @test c.state == RE.RUNNING && !("r" in get(NS._FORCE_RUN, "rerun", Set{String}()))
                finally
                    delete!(NS._FORCE_RUN, "rerun")
                end
            end

            @testset "editing a locked cell without running it leaves no pending run" begin
                rep = RE.parse_report("#%% code id=k locked\n1\n")
                nb = NS.LiveNotebook("lockedit", joinpath(mktempdir(), "lockedit.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                nb.closed = true
                pending() = "k" in get(NS._FORCE_RUN, "lockedit", Set{String}())
                try
                    NS.edit_cell!(nb, "k", "2"; run = false)
                    quiet = pending()
                    NS.edit_cell!(nb, "k", "3"; run = true)
                    @test (quiet, pending()) == (false, true)
                finally
                    delete!(NS._FORCE_RUN, "lockedit")
                end
            end

            @testset "held locked cells are re-armed once per worker connection" begin
                rep = RE.parse_report("#%% code id=L locked region=gpu\n1\n")
                nb = NS.LiveNotebook("rearm", joinpath(mktempdir(), "rearm.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                nb.closed = true                                  # no runner: the restale is what is under test
                c = only(rep.cells)
                hold!() = RE.mark_blocked!(c, NS.WAIT_LOCKED, "L")
                k1, k2 = (conn = (name = "w1",),), (conn = (name = "w2",),)
                hold!(); first_up = NS._rearm_locked!(nb, "gpu", k1)
                hold!(); again = NS._rearm_locked!(nb, "gpu", k1)        # same worker: never again
                state_again = c.state
                new_worker = NS._rearm_locked!(nb, "gpu", k2)
                @test (first_up, again, state_again, new_worker, c.state) == (1, 0, RE.BLOCKED, 1, RE.STALE)
            end

            @testset "a failed reader is re-armed once, and a locked wait is left held" begin
                rep = RE.parse_report("#%% code id=s region=gpu\nx = 1\n#%% code id=L locked region=gpu\ny = x + 1\n" *
                                      "#%% code id=r\nz = y + 1\n#%% code id=e\nw = x + 2\n")
                RE.build_dependencies!(rep)
                nb = NS.LiveNotebook("stranded", joinpath(mktempdir(), "stranded.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                nb.closed = true
                cell(id) = only(c for c in rep.cells if c.id == id)
                try
                    cell("s").state = RE.FRESH
                    RE.mark_blocked!(cell("L"), NS.WAIT_LOCKED, "L")
                    RE.mark_blocked!(cell("r"), NS.WAIT_LOCKED, "L")
                    cell("e").state = RE.ERRORED
                    NS._reconcile_stranded_readers!(nb)
                    first = (cell("L").state, cell("r").state, cell("e").state)
                    cell("e").state = RE.ERRORED                         # it failed again, for its own reasons
                    NS._reconcile_stranded_readers!(nb)
                    @test first == (RE.BLOCKED, RE.BLOCKED, RE.STALE)
                    @test cell("e").state == RE.ERRORED
                finally
                    filter!(k -> k[1] != "stranded", NS._READER_REARMED)
                end
            end

            @testset "each completed run is kept with when it started and ended" begin
                rep = RE.parse_report("#%% code id=q\n1\n")
                nb = NS.LiveNotebook("runlog", joinpath(mktempdir(), "runlog.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                c = only(rep.cells)
                c.output = RE.CellOutput("", RE.MimeChunk[], Any[], Any[], RE.BindSpec[], "1", nothing, nothing, 250.0)
                NS._run_log!(nb, "gpu", c)
                r = only(NS._runs_since("runlog", "gpu", 0))
                @test (r.id, round(r.t1 - r.t0; digits = 3), r.err) == ("q", 0.25, false)
                @test isempty(NS._runs_since("runlog", "gpu", r.t1)) && isempty(NS._runs_since("runlog", "local", 0))
                # A profiled run names its profile, which the telemetry timeline opens.
                NS._run_log!(nb, "local", c; profile = "1700000000000")
                @test NS._run_json(only(NS._runs_since("runlog", "local", 0)))["profile"] == "1700000000000" &&
                      NS._run_json(r)["profile"] == ""
            end

            @testset "a kernel whose session was lost waits on that session" begin
                k = RE.GateKernel(mktempdir())
                @test NS._lost_session_of(k) == ""                    # never lost: nothing to wait on
                NS._session_lost!(k, "lost-host.invalid")
                waiting = NS._lost_session_of(k)
                NS._session_regained!("lost-host.invalid")
                @test (waiting, NS._lost_session_of(k)) == ("lost-host.invalid", "")
            end

            @testset "a region bring-up banner moves the version when it starts and ends" begin
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n")
                nb = NS.LiveNotebook("narrate", joinpath(mktempdir(), "narrate.jl"), rep, RE.GateKernel(mktempdir()), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                v0 = nb.version
                stop = NS._narrate_region_bringup!(nb, nb.kernel, "gpu", "gpu (node)")
                started = (nb.version, get(rep.meta, "hydrating", false), get(rep.meta, "hydratingKind", ""),
                           get(rep.meta, "hydratingSide", ""))
                # A second cell arriving during the same bring-up leaves the banner to the first.
                NS._narrate_region_bringup!(nb, nb.kernel, "gpu", "gpu (node)")()
                stop()
                @test (started, nb.version, haskey(rep.meta, "hydrating"), haskey(rep.meta, "hydratingSide")) ==
                      ((v0 + 1, true, "remote", "gpu"), v0 + 2, false, false)
                # No bring-up ahead: no banner and no version change.
                NS._narrate_region_bringup!(nb, RE.InProcessKernel(), "gpu", "gpu (node)")()
                @test nb.version == v0 + 2
            end

            @testset "a running region cell is judged only by its own kernel" begin
                rep = RE.parse_report("#%% code id=c region=gpu\nsleep(1)\n")
                nb = NS.LiveNotebook("orphan", joinpath(mktempdir(), "orphan.jl"), rep, RE.GateKernel(mktempdir()), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                c = only(rep.cells)
                # A worker not connected yet still has its bring-up ahead; an in-process kernel has none.
                @test NS._region_bringup_pending(nb, nb.kernel)
                @test !NS._region_bringup_pending(nb, RE.InProcessKernel())
                c.state = RE.RUNNING
                NS._RUN_SINCE[(nb.id, "c")] = time() - 60
                sweep!(answered, asked) = (NS._LAST_RUNNING[nb.id] = (Set{String}(), Set(answered), Set(asked));
                                           NS._reconcile_nb_runs!(nb))
                try
                    # The main kernel answers, the busy region worker misses its ping: nothing is known.
                    sweep!(["local"], ["local", "gpu"]); sweep!(["local"], ["local", "gpu"])
                    @test c.state == RE.RUNNING
                    # No kernel for its region at all: nothing can be running it.
                    sweep!(["local"], ["local"]); sweep!(["local"], ["local"])
                    @test c.state == RE.STALE
                finally
                    delete!(NS._LAST_RUNNING, nb.id); delete!(NS._RUN_SINCE, (nb.id, "c"))
                end
            end

            @testset "closing does not wait on a worker still starting" begin
                # A close finds the kernel's lock held (a spawn in progress) and returns at once; the
                # ending happens once the lock is free. A restart still waits, so it starts fresh.
                k = RE.GateKernel(mktempdir())
                held, release = Channel{Nothing}(1), Channel{Nothing}(1)
                spawn = Threads.@spawn lock(k.lock) do; put!(held, nothing); take!(release); end   # as a spawn holds it
                take!(held)
                t0 = time(); RE.shutdown!(k; wait = false)
                @test time() - t0 < 1.0 && k.closing
                put!(release, nothing); wait(spawn)
                t0 = time(); while k.closing && time() - t0 < 5; sleep(0.05); end
                @test !k.closing && !k.close_kill
                RE.shutdown!(k)                                  # wait = true takes the lock as before
                @test !k.closing
                # A closed notebook gets no region kernel, and its runner is not started.
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n")
                nb = NS.LiveNotebook("closed", joinpath(mktempdir(), "closed.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                nb.closed = true
                @test_throws ErrorException NS._region_kernel!(nb, "gpu")
                NS._ensure_runner!(nb)
                @test !get(NS._RUNNERS, nb.id, false)
                @test NS._restale_region_cells!(nb, "gpu") == 0
            end

            @testset "a notebook's opening run is not shown as a bundle being rebuilt" begin
                rep = RE.parse_report("#%% code id=c\n1\n")
                nb = NS.LiveNotebook("hyd", joinpath(mktempdir(), "hyd.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                # Hydrating with a saved preview and no kind: a live notebook's run, not a bundle's "env".
                rep.meta["hydrating"] = true; rep.meta["preview"] = Dict{String,Any}()
                kind() = (s = NS.state_json(nb); (s isa AbstractString ? KaimonSlate.JSON.parse(s) : s)["hydratingKind"])
                @test kind() == "run"
                rep.meta["hydratingKind"] = "env"; @test kind() == "env"        # a bundle says so itself
                rep.meta["hydratingKind"] = "boot"; @test kind() == "boot"
            end

            @testset "GPU readings ride the telemetry sample" begin
                # The sampler, loaded as the worker loads it. Without NVML (no NVIDIA driver here) it
                # reports no GPUs rather than failing; its JSON round-trips through the hub's parser.
                G = Module(:GpuStatsT)
                Base.invokelatest(Base.include, G, joinpath(pkgdir(KaimonSlate), "src", "gpustats.jl"))
                gs = Base.invokelatest(G.gpu_sample)
                @test gs isa Vector
                g1 = (i = 0, name = "A \"100\"", util = 80, util_max = 97, mem_util = 30, mem_used = Int64(4) << 30,
                      mem_total = Int64(40) << 30, temp = 70, power_w = 250.5, power_limit_w = 250.0,
                      sm_mhz = 1215, sm_max_mhz = 1410, throttle = ["power cap"], proc_mem = Int64(1) << 30)
                g2 = merge(g1, (i = 1, util = 40, mem_used = Int64(2) << 30, proc_mem = Int64(-1)))
                line = "{\"cpu\":1.0,\"gpus\":" * Base.invokelatest(G.gpu_sample_json, [g1, g2]) * ",\"ts\":1}"
                s = RE._parse_telemetry(line)
                @test length(s.gpus) == 2 && s.gpus[1].name == "A \"100\"" && s.gpus[2].util == 40
                @test NS._gpu_util(s) == 60.0 && NS._gpu_mem(s) == Int64(6) << 30
                @test Base.invokelatest(G.gpu_sample_json, NamedTuple[]) == "[]"
                # A sample without GPUs, or from a worker that predates them, charts as -1.
                s0 = RE._parse_telemetry("{\"cpu\":1.0,\"ts\":1}")
                @test isempty(s0.gpus) && NS._gpu_util(s0) == -1 && NS._gpu_mem(s0) == -1
                @test s.gpus[1].throttle == ["power cap"] && s.gpus[1].sm_max_mhz == 1410 && s.gpus[1].util_max == 97
                # A worker that sends no peak reads its utilization as the peak.
                @test RE._parse_telemetry("{\"cpu\":1.0,\"gpus\":[{\"i\":0,\"util\":12}],\"ts\":1}").gpus[1].util_max == 12
            end

            @testset "collections ride the sample, placed by their age" begin
                s = RE._parse_telemetry("{\"cpu\":1.0,\"gc\":[[500,12.5,1,1048576],[0,0.3,0,900]],\"ts\":1}")
                @test length(s.gc) == 2 && s.gc[1][2] == 12.5 && s.gc[1][3] == 1.0 && s.gc[2][4] == 900.0
                @test s.rcv - s.gc[1][1] ≈ 0.5 && s.gc[2][1] == s.rcv
                d = NS._sample_full(s)
                @test d["gc"][1][2] == 12.5 && length(d["gc"]) == 2
                # A worker that does not report them one by one is not one that had none.
                s0 = RE._parse_telemetry("{\"cpu\":1.0,\"ts\":1}")
                @test s0.gc === nothing && !haskey(NS._sample_full(s0), "gc")
                @test isempty(RE._parse_telemetry("{\"cpu\":1.0,\"gc\":[],\"ts\":1}").gc)
            end

            @testset "host, process and job figures ride the sample and are logged per notebook" begin
                S = Module(:SysStatsT)
                Base.invokelatest(Base.include, S, joinpath(pkgdir(KaimonSlate), "src", "sysstats.jl"))
                smp = Base.invokelatest(S.SysSampler)
                Base.invokelatest(S.sys_sample!, smp); sleep(0.2)
                x = Base.invokelatest(S.sys_sample!, smp)
                @test x.proc["threads"] >= 1 && haskey(x.proc, "alloc_rate") && x.host["ncpu"] >= 1   # on any OS
                @test haskey(x.proc, "compile_ms") && haskey(x.proc, "gc_pauses") && haskey(x.proc, "gc_full")
                # The job's throttling and memory events, read from its cgroup's own records.
                if Sys.islinux()
                    cg = mktempdir()
                    write(joinpath(cg, "memory.max"), "100\n"); write(joinpath(cg, "memory.current"), "40\n")
                    write(joinpath(cg, "cpu.stat"), "usage_usec 9\nnr_periods 5\nnr_throttled 3\nthrottled_usec 7000\n")
                    write(joinpath(cg, "memory.events"), "low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\n")
                    smc = Base.invokelatest(S.SysSampler); smc.cg = cg
                    jx = Base.invokelatest(S.sys_sample!, smc).job
                    @test jx["nr_throttled"] == 3 && jx["throttled_ms"] == 7
                    @test jx["mem_limit_hits"] == 2 && jx["oom_kills"] == 1
                end
                # Free space rides through the hub's parse to the page.
                sd = RE._parse_telemetry("{\"cpu\":1.0,\"disks\":[{\"label\":\"data\",\"path\":\"/d\",\"free\":5,\"total\":10}],\"ts\":1}")
                @test sd.disks[1]["free"] == 5 && sd.disks[1]["label"] == "data"
                @test isempty(RE._parse_telemetry("{\"cpu\":1.0,\"ts\":1}").disks)
                Sys.islinux() || @test !haskey(x.host, "cores")                  # Linux-only figures are absent
                line = "{\"cpu\":1.0,\"running\":[\"c1\"],\"host\":{\"cores\":[10.0,90.0,60.0],\"mem_avail\":5}," *
                       "\"proc\":" * Base.invokelatest(S.sys_json, x.proc) * ",\"job\":{\"mem_max\":100,\"mem_cur\":40},\"ts\":1}"
                s = RE._parse_telemetry(line)
                @test s.host["cores"] isa Vector{Float64} && s.job["mem_max"] == 100
                # The log keeps a summary of the cores, and which cells were running.
                d = KaimonSlate.JSON.parse(NS._telemetry_line("gpu", s))
                @test d["side"] == "gpu" && d["running"] == ["c1"] && !haskey(d["host"], "cores")
                @test d["host"]["cores_n"] == 3 && d["host"]["cores_max"] == 90.0 && d["host"]["cores_busy"] == 2
                # Written per notebook and day; an earlier day is compressed, one past retention removed.
                withenv("KAIMONSLATE_CACHE_HOME" => mktempdir()) do
                    rep = RE.parse_report("#%% code id=c1\n1\n")
                    nb = NS.LiveNotebook("tel", joinpath(mktempdir(), "tel nb.jl"), rep, RE.InProcessKernel(), 1,
                                         String[], String[], ReentrantLock(), Channel{String}[],
                                         ReentrantLock(), "", false, Dict{String,String}())
                    NS._telemetry_log!(nb, "gpu", s)
                    dir = NS.telemetry_dir(nb)
                    today = KaimonSlate.NotebookServer.Dates.format(KaimonSlate.NotebookServer.Dates.now(), "yyyy-mm-dd")
                    @test length(readlines(joinpath(dir, today * ".jsonl"))) == 1
                    old = joinpath(dir, "2000-01-01.jsonl"); write(old, "{}\n")
                    prev = string(KaimonSlate.NotebookServer.Dates.Date(today) - KaimonSlate.NotebookServer.Dates.Day(1))
                    write(joinpath(dir, prev * ".jsonl"), "{}\n")
                    NS._telemetry_tidy!(dir, today)
                    @test !isfile(old) && isfile(joinpath(dir, prev * ".jsonl.zst")) && !isfile(joinpath(dir, prev * ".jsonl"))
                end
            end

            @testset "the watchdog judges by capacity and behaviour" begin
                GiB = Int64(2)^30
                function smp(t; cpu = 50.0, running = String[], memmax = -1, memcur = -1, avail = -1,
                             total = 0, gpus = "[]", psi = 0.0, gc = 0, rss = 0)
                    job = memmax > 0 ? ",\"job\":{\"mem_max\":$memmax,\"mem_cur\":$memcur}" : ""
                    host = ",\"host\":{\"mem_avail\":$avail,\"psi_mem\":$psi}"
                    run = "[" * join(("\"$r\"" for r in running), ",") * "]"
                    x = RE._parse_telemetry("{\"cpu\":$cpu,\"gc_ms\":$gc,\"rss\":$rss,\"running\":$run,\"sys_mem_total\":$total," *
                                            "\"gpus\":$gpus$job$host,\"ts\":1}")
                    merge(x, (rcv = t,))
                end
                kinds(al) = sort!([(a.kind, a.sev) for a in al])
                T = 10_000.0
                hist(f; n = 30, dt = 2.0) = [f(T - (n - k) * dt) for k in 1:n]
                # Big work on a big box: 10 GiB of 250 GiB, a core pinned by a running cell. Nothing to say.
                h = hist(t -> smp(t; cpu = 100.0, running = ["c1"], avail = 240GiB, total = 250GiB))
                @test isempty(NS._kernel_alerts("pm", h; now = T))
                # The job's limit is what counts, not the node's.
                h = hist(t -> smp(t; memmax = 56GiB, memcur = 54GiB, avail = 150GiB, total = 250GiB))
                @test kinds(NS._kernel_alerts("pm", h; now = T)) == [("memory-low", "crit")]
                h = hist(t -> smp(t; memmax = 56GiB, memcur = 50GiB))
                @test kinds(NS._kernel_alerts("pm", h; now = T)) == [("memory-low", "warn")]
                # Growing toward the limit fast enough to run out within a minute.
                h = [smp(T - (30 - k) * 2.0; memmax = 56GiB, memcur = 20GiB + k * GiB) for k in 1:30]
                al = NS._kernel_alerts("pm", h; now = T)
                @test kinds(al) == [("memory-low", "crit")] && occursin("out in about", only(al).detail)
                # On a shared host, other programs taking memory are not this kernel running out: the
                # host's use climbs, with a GiB of jitter, while the kernel holds steady.
                h = [smp(T - (30 - k) * 2.0; avail = (26 + (isodd(k) ? 1 : -1) - k ÷ 5) * GiB, total = 64GiB,
                         rss = 2GiB) for k in 1:30]
                @test isempty(NS._kernel_alerts("pm", h; now = T))
                # …and the kernel itself growing is.
                h = [smp(T - (30 - k) * 2.0; avail = (30 - k) * GiB ÷ 2 + 8GiB, total = 64GiB,
                         rss = 2GiB + k * GiB ÷ 2) for k in 1:30]
                al = NS._kernel_alerts("pm", h; now = T)
                @test kinds(al) == [("memory-low", "crit")] && occursin("out in about", only(al).detail)
                # Busy with nothing running; and a cell running with nothing happening.
                h = hist(t -> smp(t; cpu = 97.0); n = 16)
                @test kinds(NS._kernel_alerts("pm", h; now = T)) == [("busy-idle", "warn")]
                h = hist(t -> smp(t; cpu = 0.5, running = ["c1"]); n = 200)
                al = NS._kernel_alerts("pm", h; now = T, quiet_cells = ["c1"])
                @test kinds(al) == [("no-activity", "info")] && only(al).scope == "cell" && only(al).target == "c1"
                @test isempty(NS._kernel_alerts("pm", h; now = T))          # not a code cell: a job waits by design
                # GPUs: nearly full memory warns; heat holding the clocks down is for information; the power
                # cap of a GPU working flat out is neither.
                g(used, thr) = "[{\"i\":0,\"util\":99,\"mem_used\":$used,\"mem_total\":$(40GiB),\"throttle\":[$thr]}]"
                @test kinds(NS._kernel_alerts("pm", hist(t -> smp(t; gpus = g(39GiB, "")); n = 3); now = T)) == [("gpu-memory", "warn")]
                @test kinds(NS._kernel_alerts("pm", hist(t -> smp(t; gpus = g(GiB, "\"thermal (hardware)\"")); n = 3); now = T)) ==
                      [("gpu-throttle", "info")]
                @test isempty(NS._kernel_alerts("pm", hist(t -> smp(t; gpus = g(GiB, "\"power cap\"")); n = 3); now = T))
                # Silent while a cell runs.
                h = hist(t -> smp(t; running = ["c1"]); n = 3)
                @test kinds(NS._kernel_alerts("pm", h; now = T + 60)) == [("unreachable", "crit")]
            end

            @testset "the supervisor's remote work for a region runs one at a time" begin
                gate = Channel{Nothing}(1)
                @test NS._region_work!(() -> take!(gate), "rw", :release)
                @test !NS._region_work!(() -> nothing, "rw", :release)      # one in flight already
                @test NS._region_work!(() -> nothing, "rw", :notice)        # another kind is its own
                put!(gate, nothing)
                t0 = time(); while ("rw", :release) in NS._REGION_WORK && time() - t0 < 5; sleep(0.02); end
                @test NS._region_work!(() -> nothing, "rw", :release)       # free again once it finished
            end

            @testset "a cell whose input is waiting waits with it" begin
                rep = RE.parse_report("#%% code id=a region=gpu\nx = 1\n#%% code id=b\ny = x + 1\n#%% code id=c\nz = y + 1\n")
                RE.build_dependencies!(rep)
                nb = NS.LiveNotebook("waits", joinpath(mktempdir(), "waits.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                a, b, c = rep.cells
                RE.mark_blocked!(a, NS.WAIT_NOT_REQUESTED, "login", "gpu")
                # Run, `b` could only fail on the `x` its upstream has not produced.
                NS._eval_one!(nb, b)
                @test b.state == RE.BLOCKED && b.blocked == NS.WAIT_NOT_REQUESTED && b.blocked_host == "login"
                NS._eval_one!(nb, c)                   # …and the wait carries down the chain
                @test c.state == RE.BLOCKED && c.blocked == NS.WAIT_NOT_REQUESTED
                # …for the region it is waiting on, whatever region (if any) the reader runs on, so the
                # supervisors ask for and keep that node rather than one the reader is tagged with.
                @test b.blocked_region == "gpu" && c.blocked_region == "gpu"
                hub = (lock = ReentrantLock(), notebooks = Dict{String,Any}("waits" => nb))
                @test "gpu" in last(NS._regions_in_use(hub))

                # ▶ on the reader asks for the node: the force passes to the cell that needs it, and the
                # reader runs again after it, waiting on what that run left. Its marker is then used up.
                lock(nb.lock) do; push!(get!(Set{String}, NS._FORCE_RUN, "waits"), "b"); end
                lock(NS._RUNNER_LOCK) do; NS._RUNNERS["waits"] = true; end   # no runner spawned here
                try
                    NS._eval_one!(nb, b)
                    @test (a.state, b.state) == (RE.STALE, RE.STALE)
                    @test get(NS._FORCE_RUN, "waits", Set{String}()) == Set(["a", "b"])
                    RE.mark_blocked!(a, NS.WAIT_QUEUED, "login", "gpu")           # as `a`'s run leaves it
                    NS._eval_one!(nb, b)
                    @test b.state == RE.BLOCKED && b.blocked == NS.WAIT_QUEUED
                    @test get(NS._FORCE_RUN, "waits", Set{String}()) == Set(["a"])
                    # Passed on once per run: an upstream that still waits after its run is not run again.
                    RE.mark_blocked!(a, NS.WAIT_NEEDS_PREPARE, "login", "gpu")
                    delete!(NS._FORCE_RUN, "waits"); push!(get!(Set{String}, NS._FORCE_RUN, "waits"), "b")
                    NS._eval_one!(nb, b); RE.mark_blocked!(a, NS.WAIT_NEEDS_PREPARE, "login", "gpu")
                    NS._eval_one!(nb, b)
                    @test b.state == RE.BLOCKED && b.blocked == NS.WAIT_NEEDS_PREPARE
                    # A region that needs preparing is offered one by running its cell, so the same.
                    delete!(NS._FORCE_RUN, "waits")
                    RE.mark_blocked!(a, NS.WAIT_NEEDS_PREPARE, "login", "gpu")
                    push!(get!(Set{String}, NS._FORCE_RUN, "waits"), "b")
                    NS._eval_one!(nb, b)
                    @test a.state == RE.STALE && get(NS._FORCE_RUN, "waits", Set{String}()) == Set(["a", "b"])
                    RE.mark_blocked!(a, NS.WAIT_NEEDS_PREPARE, "login", "gpu"); NS._eval_one!(nb, b)
                    # A queue wait is not helped by running anything; the marker is used up all the same.
                    delete!(NS._FORCE_RUN, "waits")
                    RE.mark_blocked!(a, NS.WAIT_QUEUED, "login", "gpu")
                    push!(get!(Set{String}, NS._FORCE_RUN, "waits"), "b")
                    NS._eval_one!(nb, b)
                    @test a.state == RE.BLOCKED && !haskey(NS._FORCE_RUN, "waits")
                    # A forced cell that errors before it reaches a kernel has had its run.
                    rep2 = RE.parse_report("#%% code id=e region=nosuchregion\n1\n")
                    nb2 = NS.LiveNotebook("errs", joinpath(mktempdir(), "errs.jl"), rep2, RE.InProcessKernel(), 1,
                                          String[], String[], ReentrantLock(), Channel{String}[],
                                          ReentrantLock(), "", false, Dict{String,String}())
                    push!(get!(Set{String}, NS._FORCE_RUN, "errs"), "e")
                    NS._eval_one!(nb2, only(rep2.cells))
                    @test only(rep2.cells).state == RE.ERRORED && !haskey(NS._FORCE_RUN, "errs")
                finally
                    delete!(NS._FORCE_RUN, "errs")
                    lock(NS._RUNNER_LOCK) do; delete!(NS._RUNNERS, "waits"); end
                    lock(nb.lock) do; delete!(NS._FORCE_RUN, "waits"); end
                end
            end

            @testset "a node just granted is not released for having no worker" begin
                # The grant re-arms the waiting cells, and until one reaches its worker nothing marks
                # the region busy. The sweep that gives back nodes with no workers leaves it alone.
                at(ts) = lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["gpu"] = (host = "c9", job = "77", ts = ts,
                                               checked = time(), until = time() + 600)
                end
                # No open notebook uses it, so only the region's own state can keep it.
                nohub = (lock = ReentrantLock(), notebooks = Dict{String,Any}())
                busy() = last(NS._regions_in_use(nohub))
                try
                    at(time())
                    @test NS._granted_within(RE.region_get("gpu"), NS._GRANT_GRACE_S)
                    @test "gpu" in busy()              # both the idle release and the sweep skip it
                    at(time() - NS._GRANT_GRACE_S - 1)
                    @test !NS._granted_within(RE.region_get("gpu"), NS._GRANT_GRACE_S)
                    @test !("gpu" in busy())
                    # A prepare installing onto the node holds it, started from a notebook or not.
                    lock(RE._PREPARING_LOCK) do; RE._PREPARING["gpu"] = Dict{String,Any}("running" => true); end
                    @test "gpu" in busy()
                finally
                    lock(RE._PREPARING_LOCK) do; delete!(RE._PREPARING, "gpu"); end
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                end
                @test !NS._granted_within(RE.region_get("gpu"), NS._GRANT_GRACE_S)   # nothing held
            end

            @testset "a node serving a connected worker is not asked about it" begin
                # The minute sweep's roster is a job step on the node; a worker connected over its own
                # wire already answers whether the node is in use.
                rep = RE.parse_report("#%% code id=c region=gpu\n1\n")
                nb = NS.LiveNotebook("serves", joinpath(mktempdir(), "nb.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                r() = RE.region_get("gpu")
                try
                    RE.route!("c9", "login", "77")
                    lock(RE._REGION_PLACE_LOCK) do
                        RE._REGION_PLACE["gpu"] = (host = "c9", job = "77", ts = time(),
                                                   checked = time(), until = time() + 600)
                    end
                    k = NS._region_kernel!(nb, "gpu")
                    @test !NS._region_serves_kernel(r())            # spawned, not connected
                    k.conn = :wire
                    @test NS._region_serves_kernel(r())
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    @test !NS._region_serves_kernel(r())            # its node is not the region's any more
                    k.conn = nothing
                finally
                    NS._forget_region_kernel!(nb, "gpu")
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    RE.route!("c9", "")
                end
            end

            @testset "a withdrawn request is not asked for again" begin
                rep = RE.parse_report("#%% code id=w region=queue\n1\n#%% code id=o region=other\n2\n")
                nb = NS.LiveNotebook("withdraw", joinpath(mktempdir(), "withdraw.jl"), rep, RE.InProcessKernel(), 1,
                                     String[], String[], ReentrantLock(), Channel{String}[],
                                     ReentrantLock(), "", false, Dict{String,String}())
                hub = (lock = ReentrantLock(), notebooks = Dict("withdraw" => nb))
                r = RE.region_set!("queue"; host = "", scheduler = :slurm)
                w, o = rep.cells
                waiting() = (RE.mark_blocked!(w, NS.WAIT_QUEUED, "", "queue");
                             RE.mark_blocked!(o, NS.WAIT_QUEUED, "", "other"))
                # The pages are told from a spawned task, which moves the waiting cells and then sets
                # the withdrawal stamp again. `release!` waits for that task.
                function release!()
                    res = NS._release_region!(hub, r)
                    return res, (res.told === nothing || timedwait(() -> istaskdone(res.told), 10.0) === :ok)
                end
                bin = fake_slurm()
                try
                    withenv("PATH" => bin * ":" * ENV["PATH"]) do
                        waiting()
                        write(joinpath(bin, "queue"), "124|PENDING||\n")
                        res, told = release!()
                        @test res.ok && told
                        @test readlines(joinpath(bin, "cancelled")) == ["-n slate-queue"]
                        # The cell waits for a run, which the supervisor leaves alone. The cell waiting
                        # on another region still waits in its queue.
                        @test w.state == RE.BLOCKED && w.blocked == NS.WAIT_NOT_REQUESTED && w.blocked_region == "queue"
                        @test o.state == RE.BLOCKED && o.blocked == NS.WAIT_QUEUED && o.blocked_region == "other"
                        @test NS._cell_result_text(w) == "(run it to request a node)"
                        # A run asked for before the withdrawal does not ask for a node again; a later one does.
                        @test NS._withdrawn_since_asked(nb, "queue")
                        NS._run_asked!(nb)
                        @test !NS._withdrawn_since_asked(nb, "queue")

                        # A request that has not reached the scheduler yet is withdrawn too. Its
                        # placement task finds the stamp and releases whatever it submits.
                        waiting()
                        lock(NS._PLACING_LOCK) do
                            push!(NS._PLACING, "queue"); NS._PLACING_SINCE["queue"] = time()
                        end
                        @test NS._region_queued("queue")
                        res, told = release!()
                        @test !res.ok && res.left.state === :none && told
                        @test NS._withdrawn_while_placing("queue") && !NS._region_queued("queue")
                        @test w.blocked == NS.WAIT_NOT_REQUESTED
                        # The supervisor asking again does not undo the withdrawal, and a run does, so
                        # the task in flight keeps what it gets.
                        @test NS._place_in_background!("queue", nb) === nothing
                        @test NS._withdrawn_while_placing("queue")
                        @test NS._place_in_background!("queue", nb; by_run = true) === nothing
                        @test NS._region_queued("queue")

                        # A cancellation that fails leaves the request standing, and the task keeps serving it.
                        waiting()
                        write(joinpath(bin, "queue"), "125|PENDING||\n")
                        touch(joinpath(bin, "stuck"))
                        res, told = release!()
                        rm(joinpath(bin, "stuck"))
                        @test !res.ok && res.left.state === :pending && told
                        @test NS._region_queued("queue") && w.state == RE.BLOCKED && w.blocked == NS.WAIT_QUEUED
                        # The agent reads what the cell waits for, not the output of its earlier run.
                        @test NS._cell_result_text(w) == "(queued for a node)"
                        # The cells still wait, which the agent tool reports as a queued request.
                        @test NS._region_waits(hub, "queue") && !NS._region_waits(hub, "elsewhere")
                    end
                finally
                    lock(NS._PLACING_LOCK) do
                        delete!(NS._PLACING, "queue"); delete!(NS._PLACING_SINCE, "queue")
                        delete!(NS._WITHDRAWN_AT, "queue"); delete!(NS._RUN_ASKED_AT, "withdraw")
                    end
                    RE.region_delete!("queue")
                end
            end

            @testset "the region tools report and act on an allocation" begin
                tools = KaimonSlate.create_tools(StubGate.GateTool)
                tool(name) = only(t for t in tools if t.name == name).handler
                regions, worker = tool("regions"), tool("worker")
                # The lines `regions()` prints under one region, up to the next one.
                block(name) = let m = match(Regex("• " * name * " .*\\n((?:      .*\\n)*)"), regions())
                    m === nothing ? "" : String(m.captures[1])
                end
                RE.region_set!("held"; host = "login", scheduler = :slurm, partition = "gpus",
                               walltime = "02:00:00", gpus = "1", idle_release = 1800, idle_warn = 300,
                               options = Dict("qos" => "debug", "exclusive" => "", "walltime" => "04:00:00"))
                RE.region_set!("steady"; host = "login", scheduler = :slurm)
                place!(name; ts = time(), until = time() + 600) = lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE[name] = (host = "c9", job = "77", ts = ts, checked = time(), until = until)
                end
                site = (:slurm, "login")
                site_was = lock(NS._EXTENDABLE_LOCK) do; get(NS._EXTENDABLE, site, nothing); end
                try
                    # A walltime among the options is dropped from the request, because the field owns it.
                    @test occursin("asks: scheduler=slurm  job_name=slate-held  partition=gpus  " *
                                   "walltime=02:00:00  gpus=1  exclusive  qos=debug  " *
                                   "idle_release=30m (warn 5m before)  (not sent: walltime=04:00:00)", block("held"))
                    @test occursin("allocation: none held by this hub", block("held"))
                    # An `auto` region drops what neither scheduler would send.
                    RE.region_set!("either"; host = "login", scheduler = :auto,
                                   options = Dict("qos" => "debug", "walltime" => "04:00:00"))
                    @test occursin("qos=debug  (not sent: walltime=04:00:00)", block("either"))
                    @test occursin("holds no allocation", worker(action = "keep", region = "held"))

                    # A queued request has no idle clock yet: it starts when the node is granted.
                    lock(NS._PLACING_LOCK) do; push!(NS._PLACING, "held"); end
                    try
                        @test occursin("allocation: queued for a node on login", block("held"))
                        @test occursin("is queued for a node", worker(action = "keep", region = "held"))
                    finally
                        lock(NS._PLACING_LOCK) do; delete!(NS._PLACING, "held"); end
                    end

                    RE.route!("c9", "login", "77")
                    place!("held"; ts = time() - 3600)
                    lock(NS._REGION_USE_LOCK) do; NS._REGION_LAST_USED["held"] = time() - 600; end
                    @test occursin(r"allocation: running as job 77 on c9, 00:(09|10):\d\d of walltime left, " *
                                   r"idle for 00:10:0\d of the 30m idle release", block("held"))
                    # Ten idle minutes become none.
                    @test startswith(worker(action = "keep", region = "held"), "✅ kept 'held'")
                    @test NS._region_idle_for("held") < 5
                    # A job with no time limit has no walltime to count down, and its idle clock still
                    # runs. The idle notice for it is sent without one.
                    place!("held"; until = Inf)
                    f = NS._region_alloc_facts("held")
                    @test !haskey(f, "walltimeLeft") && haskey(f, "idleFor")
                    @test occursin("allocation: running as job 77 on c9, with no walltime limit, idle for", block("held"))
                    lock(NS._EXTENDABLE_LOCK) do
                        NS._EXTENDABLE[site] = (; ok = false, reason = :refused, said = "", added_s = 0)
                    end
                    @test NS._push_alloc_notice!(NS.LiveNotebook[], RE.region_get("held"),
                                                 Dict{String,Any}("kind" => "idle", "seconds_left" => 60)) === nothing
                    place!("steady")
                    @test occursin("has no idle release", worker(action = "keep", region = "steady"))
                finally
                    lock(RE._REGION_PLACE_LOCK) do
                        foreach(n -> delete!(RE._REGION_PLACE, n), ("held", "steady"))
                    end
                    lock(NS._REGION_USE_LOCK) do
                        foreach(n -> delete!(NS._REGION_LAST_USED, n), ("held", "steady"))
                    end
                    lock(NS._EXTENDABLE_LOCK) do
                        site_was === nothing ? delete!(NS._EXTENDABLE, site) : (NS._EXTENDABLE[site] = site_was)
                    end
                    RE.route!("c9", "")
                end

                try
                    @test startswith(worker(action = "log", region = "held"), "No bring-up of 'held'")
                    RE.with_rlog_region(() -> RE._rlog("region[held]: queued for a node"), "held")
                    @test occursin("region[held]: queued for a node", worker(action = "log", region = "held"))
                    # A bring-up is not an allocation, so a region without a scheduler has a log too.
                    RE.with_rlog_region(() -> RE._rlog("region[plain]: spawning"), "plain")
                    @test occursin("region[plain]: spawning", worker(action = "log", region = "plain"))
                finally
                    foreach(RE.region_trace_reset!, ("held", "plain"))
                end

                # The scheduler is asked by job name, here on this machine (`host = ""`).
                bin = fake_slurm()
                queue, cancelled = joinpath(bin, "queue"), joinpath(bin, "cancelled")
                RE.region_set!("here"; host = "", scheduler = :slurm)
                release() = worker(action = "release", region = "here")
                withenv("PATH" => bin * ":" * ENV["PATH"]) do
                    write(queue, "123|RUNNING|c9|1:00:00\n")
                    lock(RE._REGION_PLACE_LOCK) do
                        RE._REGION_PLACE["here"] = (host = "", job = "123", ts = time(), checked = time(),
                                                    until = time() + 600)
                    end
                    try
                        @test startswith(release(), "✅ released job 123 of 'here'")
                        @test readlines(cancelled) == ["-n slate-here"]
                        @test RE.region_placement(RE.region_get("here")) === nothing
                    finally
                        lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "here"); end
                    end
                    # A job this hub does not hold, after a restart, is released by name.
                    write(queue, "126|RUNNING|c9|1:00:00\n")
                    @test startswith(release(), "✅ released the allocation of 'here' on this machine")
                    @test occursin("nothing to release", release())
                    @test length(readlines(cancelled)) == 2

                    write(queue, "124|PENDING||\n")
                    lock(NS._PLACING_LOCK) do; push!(NS._PLACING, "here"); end
                    try
                        @test startswith(release(), "✅ withdrew the queued request of 'here' on this machine")
                    finally
                        lock(NS._PLACING_LOCK) do; delete!(NS._PLACING, "here"); end
                    end

                    # Holding nothing and not being able to ask are different answers.
                    write(queue, "125|RUNNING|c9|1:00:00\n")
                    touch(joinpath(bin, "down"))
                    @test occursin("may still be held, because the scheduler on this machine did not answer",
                                   release())
                    rm(joinpath(bin, "down"))
                    touch(joinpath(bin, "stuck"))
                    @test occursin("the cancel request failed, and the scheduler on this machine still lists " *
                                   "job 125 of 'here' as running", release())
                    rm(joinpath(bin, "stuck"))
                end

                @test occursin("has no scheduler", worker(action = "release", region = "plain"))
                @test startswith(worker(action = "release", region = ""), "Give a region")
                @test startswith(worker(action = "release", region = "nope"), "No region 'nope'")
                @test occursin("release | keep | log", worker(action = "bogus"))
            end

            # ── what the fixed fields cannot say ──────────────────────────────────────────────
            # A region carries the same scheduler options a job cell does, spelled by the same
            # catalogue, so one cluster described for a sweep and for a region says one thing.
            @testset "a region's scheduler options reach the request" begin
                S = RE.Sweep
                opts = Dict("constraint" => "avx512", "exclusive" => "", "qos" => "high")
                sl = S._slurm_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                             mem = "", gpus = "", account = "", extra = "",
                                             options = opts)
                # Values are shell-quoted, so an option whose value has a space cannot become two arguments.
                @test occursin("--constraint='avx512'", sl)
                @test occursin("--qos='high'", sl)
                # A valueless option is a switch, not a flag with an empty argument: `--exclusive=`
                # is a different request, and some schedulers reject it outright.
                @test occursin("--exclusive", sl) && !occursin("--exclusive=", sl)
                # A value with a space stays ONE argument. Unquoted it would split and the
                # scheduler would read the tail as a separate option.
                spaced = S._slurm_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                                 mem = "", gpus = "", account = "", extra = "",
                                                 options = Dict("comment" => "two words"))
                @test occursin("--comment='two words'", spaced)

                # Sorted, so the same region asks the same question twice running.
                @test findfirst("--constraint", sl)[1] < findfirst("--qos", sl)[1]

                # PBS spells what it can and stays silent about the rest. `constraint` has no PBS
                # equivalent, and inventing one would fail the submission or quietly ask for
                # something else — the catalogue already records which those are.
                pb = S._pbs_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                           mem = "", gpus = "", account = "", extra = "",
                                           options = opts)
                @test occursin("-l qos='high'", pb)
                @test !occursin("constraint", pb)

                # A name the form already has a box for is DROPPED, not emitted a second time. The
                # request builds `--mem` from its own argument; an option repeating it would put the
                # flag on the command line twice and the scheduler would take whichever it took,
                # while the form went on showing the value that lost.
                dup = S._slurm_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                              mem = "8G", gpus = "", account = "", extra = "",
                                              options = Dict("mem" => "64G", "qos" => "high"))
                @test occursin("--mem '8G'", dup)          # the box
                @test !occursin("64G", dup)                # not the stale option
                @test occursin("--qos='high'", dup)        # and everything else still passes

                # No options is the request exactly as it was before any of this existed.
                bare = S._slurm_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                               mem = "", gpus = "", account = "", extra = "")
                @test !occursin("--constraint", bare) && !occursin("--qos", bare)
            end

            @testset "scheduler options written as text" begin
                # The agent tool's spelling of the form's key/value rows.
                @test RE.parse_region_options("constraint=gpu; qos=debug\nexclusive") ==
                      Dict("constraint" => "gpu", "qos" => "debug", "exclusive" => "")
                # Not split on commas or a second '=': sbatch values carry both.
                @test RE.parse_region_options("nodelist=nid[001-003],nid005; comment=a=b") ==
                      Dict("nodelist" => "nid[001-003],nid005", "comment" => "a=b")
                @test RE.parse_region_options("  ;  ") == Dict{String,String}()
                # A setting with its own field would be dropped from the request, so it is refused
                # here rather than stored where it does nothing.
                @test_throws ArgumentError RE.parse_region_options("qos=debug; account=m1")
                @test_throws ArgumentError RE.parse_region_options("=gpu")
                # So is anything the request sets itself, under any spelling sbatch would accept for
                # it: a second job name would hide the job from the lookup by name.
                for bad in ("job-name=x", "job=x", "J=x", "time=2:00:00", "t=5", "output=o.log",
                            "cpus-per-task=4", "ntasks=2", "select=1:ncpus=4")
                    @test_throws ArgumentError RE.parse_region_options(bad)
                end
                @test RE.parse_region_options("time-min=10; mem-per-cpu=2G; ntasks-per-node=1") ==
                      Dict("time-min" => "10", "mem-per-cpu" => "2G", "ntasks-per-node" => "1")
                # A stored one is dropped from the request rather than emitted.
                req = RE.Sweep._slurm_request_script("j"; walltime = "01:00:00", partition = "", cpus = 0,
                                              mem = "", gpus = "", account = "", extra = "",
                                              options = Dict("job-name" => "other", "qos" => "high"))
                @test !occursin("other", req) && occursin("--qos='high'", req)
            end

            @testset "a duration is read whole or refused" begin
                SW = RE.Sweep
                for (s, secs) in (("10m", 600), ("1h30m", 5400), ("90", 5400), ("2 h", 7200), ("0", 0), ("45s", 45))
                    @test SW.is_duration(s) && SW.parse_duration(s) == secs
                end
                # `parse_duration` adds up whatever parts it finds; these would have read as 5 minutes.
                for s in ("abc5m", "-5m", "5m later", "5x", "", "m")
                    @test !SW.is_duration(s)
                end
            end

            @testset "a region's prologue runs where it can matter" begin
                # In the worker's own shell, before the worker boots. Not in the allocation's job
                # body, which only sleeps, and not on `_run_on`, which carries every poll too.
                RE.region_set!("prol"; host = "login", scheduler = :slurm,
                               prologue = "module load cuda")
                try
                    p = RE._region_prologue("prol")
                    @test occursin("module load cuda", p)
                    # Chained, so a prologue that fails stops the boot rather than starting a worker
                    # into an environment that was never set up.
                    @test endswith(p, "&& ")
                    # A region without one, and a spawn that is not a region's, leave the line alone.
                    @test RE._region_prologue("") == ""
                    @test RE._region_prologue("no-such-region") == ""
                    RE.region_set!("noprol"; host = "login", scheduler = :slurm)
                    @test RE._region_prologue("noprol") == ""
                finally
                    try; RE.region_delete!("prol"); RE.region_delete!("noprol"); catch; end
                end
            end

            @testset "options and prologue survive a round trip" begin
                RE.region_set!("rt"; host = "login", scheduler = :slurm,
                               options = Dict("qos" => "high"), prologue = "module load x")
                try
                    r = RE.region_get("rt")
                    @test r.options == Dict("qos" => "high") && r.prologue == "module load x"
                    # Through the stored form, which is what a reopened hub reads.
                    back = RE._region_from_dict(RE._region_to_dict(r))
                    @test back.options == r.options && back.prologue == r.prologue
                    # A record written before these fields existed reads as having neither, rather
                    # than failing to parse.
                    old = RE._region_from_dict(Dict("name" => "old", "host" => "h"))
                    @test isempty(old.options) && old.prologue == ""
                    # A number in the stored JSON is one setting with the string it renders as, not
                    # a second spelling of it.
                    num = RE._region_from_dict(Dict("name" => "n", "host" => "h",
                                                    "options" => Dict("nodes" => 2)))
                    @test num.options == Dict("nodes" => "2")
                finally
                    try; RE.region_delete!("rt"); catch; end
                end
            end

            # ── a dead worker's series does not outlive it ────────────────────────────────────
            # Both registries are keyed by the gate connection name, and every respawn mints a new
            # one. Both shipped with a `forget` function that nothing called, so a hub that restarted
            # a worker all afternoon kept a clock mapping and a telemetry ring for every worker it
            # had ever had. Measured at 9 of each on a hub with one notebook and one region.
            @testset "per-connection state is swept when its worker goes" begin
                RE.ClockTrack.note_exchange!("slate-dead-1", 0, 10, 20, 40)
                RE.ClockTrack.note_exchange!("slate-dead-2", 0, 10, 20, 40)
                RE._record_telemetry!("slate-dead-1", "{\"cpu\":1}")
                try
                    @test "slate-dead-1" in RE.ClockTrack.tracked_conns()
                    @test "slate-dead-2" in RE.ClockTrack.tracked_conns()

                    # The sweep reads only the open notebooks and their kernels, so a stand-in
                    # with no notebooks says "nothing is attached" without standing a hub up. Every
                    # entry above is then unreachable by definition.
                    nohub = (lock = ReentrantLock(), notebooks = Dict{String,Any}())
                    NS._sweep_stale_conn_state!(nohub)
                    @test !("slate-dead-1" in RE.ClockTrack.tracked_conns())
                    @test !("slate-dead-2" in RE.ClockTrack.tracked_conns())
                    @test !("slate-dead-1" in RE.kernel_stats_conns())
                    # And the sweep is idempotent: nothing left to drop is not an error.
                    @test NS._sweep_stale_conn_state!(nohub) === nothing
                finally
                    RE.ClockTrack.forget_clock!("slate-dead-1")
                    RE.ClockTrack.forget_clock!("slate-dead-2")
                    RE.forget_kernel_stats("slate-dead-1")
                end
            end

            # ── the grant stamp is not the refresh stamp ──────────────────────────────────────
            # These were ONE field, and the two clocks that read it want opposite things. The
            # placement is re-asked of the scheduler every `_PLACE_TTL`; the idle timer reads the
            # same field as "how long have we held this node" and floors the idle clock with it. So
            # every refresh made a node that had been sitting for an hour look freshly granted, the
            # idle clock could never grow past the refresh interval, and an idle timeout longer than
            # that could never fire at all. Nothing failed; the release simply never came.
            @testset "a placement refresh does not reset the grant clock" begin
                held = (host = "c1", job = "77", ts = 1000.0, checked = 1000.0, until = 9e9)
                # Same node, same job: this is the SAME grant, however often we re-ask about it.
                @test RE._granted_ts(held, "c1", "77", 2000.0) == 1000.0
                # A different node, or the same node under a new job, is a new grant.
                @test RE._granted_ts(held, "c2", "77", 2000.0) == 2000.0
                @test RE._granted_ts(held, "c1", "88", 2000.0) == 2000.0
                # Nothing held before is a new grant.
                @test RE._granted_ts(nothing, "c1", "77", 2000.0) == 2000.0

                # And the idle clock keeps counting across a refresh. A region last USED ten minutes
                # ago, holding a node granted then, whose placement was re-checked a moment ago:
                # `checked` moves, `ts` does not, so the idle stretch is the real ten minutes rather
                # than being capped at the refresh interval. Under the old single field this read as
                # zero and the release never came.
                lock(NS._REGION_USE_LOCK) do; NS._REGION_LAST_USED["gpu"] = time() - 600; end
                lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["gpu"] = (host = "c1", job = "77", ts = time() - 600,
                                               checked = time(), until = time() + 600)
                end
                try
                    @test NS._region_idle_for("gpu") >= 590
                    # The refresh stamp must not be what the idle clock reads: moving `checked` to
                    # now again changes nothing, which is the whole fix.
                    lock(RE._REGION_PLACE_LOCK) do
                        p = RE._REGION_PLACE["gpu"]
                        RE._REGION_PLACE["gpu"] = (host = p.host, job = p.job, ts = p.ts,
                                                   checked = time(), until = p.until)
                    end
                    @test NS._region_idle_for("gpu") >= 590
                finally
                    lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "gpu"); end
                    lock(NS._REGION_USE_LOCK) do; delete!(NS._REGION_LAST_USED, "gpu"); end
                end
            end

            # Warm workers are for a host you keep them on. A scheduler region's node is an
            # allocation, so a worker kept between notebooks is on a machine that may already be
            # gone — and `warm > 0` is what stops the reconciler releasing an idle node, which turns
            # a forgotten region into an allocation held indefinitely.
            @test RE.region_set!("warmish"; host = "workstation", warm = 3).warm == 3
            @test RE.region_set!("warmsched"; host = "login", scheduler = :slurm, warm = 3).warm == 0
            # …including a record already on disk with a count, so an existing one stops holding.
            @test RE._region_from_dict(Dict("name" => "old", "host" => "login",
                                            "scheduler" => "pbs", "warm" => 4)).warm == 0
            @test RE._region_from_dict(Dict("name" => "old", "host" => "box", "warm" => 4)).warm == 4

            # A granted node is reached THROUGH its login node: a session to the node itself would
            # be a second authentication, which is the thing the whole transport exists to avoid.
            # Commands run inside the allocation; files go to the shared filesystem via the login
            # session; the data path is a forward the login node opens.
            @test RE.via("c1") === nothing                      # unrouted: reached on its own
            RE.route!("c1", "login", "4242")
            try
                v = RE.via("c1")
                @test v !== nothing && v.host == "login" && v.job == "4242"
                @test RE._host_for_files("c1") == "login"        # shared filesystem, login session
                @test RE._host_for_files("elsewhere") == "elsewhere"
                # SLURM joins the running job rather than logging in again, on a node that refused an
                # ssh a moment ago.
                lock(() -> (RE._NODE_SSH["c1"] = (false, time())), RE._VIA_LOCK)
                @test occursin("srun --jobid=4242 --overlap", RE._in_allocation(v, "c1", "hostname"))
                # A step that cannot start says so within a bound instead of holding the session.
                @test occursin("--immediate=$(RE._STEP_START_S)", RE._in_allocation(v, "c1", "hostname"))
                # A node that takes an ssh from its login node is reached that way, with no step, and
                # the command still sees the job it is in.
                lock(() -> (RE._NODE_SSH["c1"] = (true, time())), RE._VIA_LOCK)
                cmd = RE._in_allocation(v, "c1", "hostname")
                @test startswith(cmd, "ssh ") && !occursin("srun", cmd) && occursin("SLURM_JOB_ID=", cmd) && occursin("4242", cmd)
                # The same job routed again keeps it; another job asks again, as does a refusal that
                # has had time to change.
                RE.route!("c1", "login", "4242"); @test RE._node_by_ssh("c1")
                RE.route!("c1", "login", "4243"); @test !haskey(RE._NODE_SSH, "c1")
                lock(() -> (RE._NODE_SSH["c1"] = (false, time() - RE._NODE_SSH_RETRY_S - 1)), RE._VIA_LOCK)
                @test !RE._node_by_ssh("c1")            # asked again: "login" is no host, so refused again
                @test last(RE._NODE_SSH["c1"]) > time() - 30
            finally
                RE.route!("c1", "")
            end
            @test RE.via("c1") === nothing                      # released with the allocation

            # PBS has no `srun --overlap` — `pbsdsh` only runs from INSIDE the job — so it reaches
            # the node the way every PBS site already does, an ssh from the login node. The hub still
            # authenticates once: that ssh is issued ON the login node's session.
            RE.route!("c2", "login", "88.pbsserver", :pbs)
            try
                v = RE.via("c2")
                @test v.kind === :pbs
                cmd = RE._in_allocation(v, "c2", "hostname")
                @test startswith(cmd, "ssh ") && occursin("'c2'", cmd) && !occursin("srun", cmd)
                @test occursin("BatchMode=yes", cmd)             # never hang on a prompt
                # The node sees the job it is in, as a `srun` step sees SLURM_JOB_ID.
                @test occursin("PBS_JOBID=", cmd) && occursin("88.pbsserver", cmd)
                # A worker joins the job, so the job ending ends it; a node without the command still runs it.
                a = RE._pbs_attached("julia w.jl")
                @test occursin("pbs_attach", a) && occursin("pbs_track", a)       # PBS Pro/OpenPBS, and Torque
                @test occursin("-j \"\$PBS_JOBID\" julia w.jl", a)
                @test occursin("else exec julia w.jl", a)
                @test RE._host_for_files("c2") == "login"        # the filesystem is still shared
            finally
                RE.route!("c2", "")
            end

            # An allocation bills for the time it is HELD, so a region may ask to have its node taken
            # back once nothing has used it. Opt-in: absent (every region written before the field
            # existed) and 0 both mean never, because regaining a node costs a queue wait.
            @test RE._region_from_dict(Dict("name" => "r", "host" => "h")).idle_release == 0
            @test RE._region_from_dict(Dict("name" => "r", "host" => "h",
                                            "idle_release" => 15)).idle_release == 15
            @test RE._region_from_dict(Dict("name" => "r", "host" => "h",
                                            "idle_release" => -5)).idle_release == 0
            # It has to survive a write/read round trip, or the form silently forgets it.
            let r = RE._region_from_dict(Dict("name" => "r", "host" => "h", "idle_release" => 20))
                @test RE._region_from_dict(RE._region_to_dict(r)).idle_release == 20
            end

            # Once the allocation ends the route goes with it, and what is left is a bare hostname.
            # Reaching it must not fall back to dialling the node directly: that fails with advice to
            # sign in to a compute node, which is not a thing anyone does, and it hides the real
            # reason. A host that was NEVER routed is untouched — that is an ordinary ssh host.
            @test RE.via("c1") === nothing
            ok, out = RE._run_on("c1", "hostname")
            @test !ok
            @test occursin("not held any more", out) && occursin("allocation", out)
            @test !occursin("padlock", out)
        end
    end

    # An allocation is held for a bounded time. A placement that outlives it points every cell at a
    # machine the hub no longer holds — and because the read-only view must not ask the scheduler
    # anything, the expiry has to be a clock, not a round trip.
    # Learning whether a site allows an extension costs the job a minute, so it is learned once per
    # site. A cached answer comes back without the scheduler being asked, so nothing is added.
    @testset "whether a site extends allocations is asked once" begin
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            r = RE.region_set!("extsite"; host = "login-unreachable.invalid", scheduler = :pbs)
            key = (:pbs, "login-unreachable.invalid")
            lock(NS._EXTENDABLE_LOCK) do
                NS._EXTENDABLE[key] = (; ok = false, reason = :refused, said = "not permitted", added_s = 0)
            end
            try
                ext = NS._site_extendable!(r)
                @test ext.reason === :refused && ext.said == "not permitted"
            finally
                lock(NS._EXTENDABLE_LOCK) do; delete!(NS._EXTENDABLE, key); end
            end
        end
    end

    @testset "a placement expires with its allocation" begin
        # SLURM's own time spellings (`squeue %L`), which is where the lease comes from.
        s = RE._sched_seconds
        @test [s("00:00:30"), s("00:05:00"), s("01:00:00"), s("2-00:00:00"), s("30"), s("2:30")] ==
              [30.0, 300.0, 3600.0, 172800.0, 1800.0, 150.0]
        @test s("UNLIMITED") == Inf
        @test s("") == 3600.0 && s("garbage") == 3600.0        # unparseable → an hour, not zero

        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            r = RE.region_set!("leased"; host = "login", scheduler = :slurm, walltime = "00:30:00")
            try
                RE.route!("c9", "login", "77")
                lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["leased"] =
                        (host = "c9", job = "77", ts = time(), checked = time(), until = time() + 60)
                end
                @test RE.region_host(r) == "c9"                # inside the lease: the node we hold
                @test RE._region_holds_node(r)
                # A routed node is never dialled directly, so its unreachable message must never
                # send anyone to ~/.ssh/config or tell them to use a key — on a cluster that refuses
                # keys that is advice for a machine they cannot ssh to. With no session to the login
                # node, THAT is the thing that has gone.
                msg = RE._unreachable("c9")
                @test occursin("through login", msg) && occursin("padlock", msg)
                @test !occursin("ssh/config", msg) && !occursin("key-based", msg)

                # A source copy kept for a worker on the node, and one for a host of the same name
                # outside the job (a single-node cluster's login).
                jobkey = RE._sync_base(RE.RemoteTarget("c9"; project = "proj", job = "77"))
                @test jobkey == "c9#77:proj"
                srcdir = mktempdir()
                lock(RE._SYNC_LOCK) do
                    s = RE.SyncSource(srcdir)
                    nosent = Dict{String,Tuple{Int,Float64}}()
                    s.dests["c9:proj"] = RE.SyncDest("c9", "proj", String[], "", nosent, Dict{String,Any}(jobkey => nothing), false)
                    s.dests["c9:other"] = RE.SyncDest("c9", "other", String[], "", copy(nosent),
                                                      Dict{String,Any}("c9:other" => nothing), false)
                    RE._SYNC_SOURCES[srcdir] = s
                end
                lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["leased"] =
                        (host = "c9", job = "77", ts = time(), checked = time(), until = time() - 1)
                end
                @test RE.region_host(r) == "login"             # past it: nothing placed, ask again
                @test !RE._region_holds_node(r)
                @test RE.via("c9") === nothing                 # the route goes with the allocation
                @test !haskey(RE._SYNC_SOURCES[srcdir].dests, "c9:proj")   # …and so does the job's copy
                @test haskey(RE._SYNC_SOURCES[srcdir].dests, "c9:other")   # …and only the job's
                lock(RE._SYNC_LOCK) do; delete!(RE._SYNC_SOURCES, srcdir); end
                @test !haskey(RE._REGION_PLACE, "leased")
                # An unrouted host keeps the plain advice — that one really is an ssh/config problem.
                @test occursin("~/.ssh/config", RE._unreachable("workstation"))
            finally
                RE.route!("c9", "")
                lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "leased"); end
            end
        end
    end

    @testset "what preparing a region keeps, and how a start uses it" begin
        # The probe's output, as a site prints it: one fact per line, a missing tool an empty value.
        f = RE._parse_probe("arch=x86_64\ncpu=AMD EPYC 7763 64-Core Processor\nmodules=gcc-native/14 cudatoolkit/13.2 \n" *
                            "cudalibs=/opt/nvidia/hpc_sdk/math_libs/13.2/lib64 \ngpus=4\nnoise line\n")
        @test f["cpu"] == "AMD EPYC 7763 64-Core Processor" && f["gpus"] == "4" && !haskey(f, "noise")
        # A module that puts a CUDA toolkit on the library path is unloaded, unless the region does.
        @test RE._site_prologue(f) == "module unload cudatoolkit"
        @test RE._site_prologue(f, "module unload cudatoolkit") == ""
        @test RE._site_prologue(merge(f, Dict("cudalibs" => ""))) == ""      # nothing shadowed
        # Patience from what loading took, never below the hub's default.
        @test RE._grace_for(1) == 45 && RE._grace_for(40) == 110
        # Module order is the site's, not a change.
        @test RE._stamps_of(Dict("modules" => "b a", "julia" => "j")) == RE._stamps_of(Dict("modules" => "a b", "julia" => "j"))

        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
            r = RE.region_set!("prep"; host = "login", scheduler = :slurm, prologue = "module load x")
            @test isempty(r.readiness) && r.liveness_grace == 0
            @test RE.readiness_text(r) == "not prepared"
            rec = Dict{String,Any}("prepared_at" => time(), "ok" => true, "prologue" => "module unload cudatoolkit",
                                   "liveness_grace_s" => 120, "steps" => Any[Dict("step" => "Read the site", "status" => "ok",
                                                                                    "detail" => "", "secs" => 1.0)],
                                   "stale" => "")
            RE.region_set!("prep"; readiness = rec)
            r = RE.region_get("prep")                   # through the file, as a restarted hub reads it
            @test occursin("✓ Read the site", RE.readiness_text(r))
            # The site's fix belongs to the machine and runs first; the region's own prologue after it.
            RE.host_facts_merge!("login", Dict{String,Any}("site_prologue" => "module unload cudatoolkit"))
            @test endswith(RE.machine_setup(RE.region_machine(r)), "{ module unload cudatoolkit ; } && ")
            @test RE._region_prologue("prep") == "{ module load x ; } && "
            @test occursin("site prologue: module unload cudatoolkit", RE.readiness_text(r))
            # Editing another field keeps the record.
            RE.region_set!("prep"; walltime = "00:10:00")
            @test RE.region_get("prep").readiness["liveness_grace_s"] == 120
            # The liveness grace: the region's own setting, else what was measured, else the default.
            k = (; target = RE.RemoteTarget("c9"; region = "prep"))
            @test NS._dead_wire_grace(k) == 120.0
            RE.region_set!("prep"; liveness_grace = 300)
            @test NS._dead_wire_grace(k) == 300.0
            RE.region_set!("prep"; liveness_grace = 0, readiness = merge(rec, Dict{String,Any}("liveness_grace_s" => 10)))
            @test NS._dead_wire_grace(k) == NS._DEAD_WIRE_GRACE
            @test NS._dead_wire_grace((; target = nothing)) == NS._DEAD_WIRE_GRACE
        end
    end

    @testset "a prepare for a notebook loads the packages in that notebook's worker" begin
        steps = Tuple{String,String}[]
        step(f, title) = (st = try; first(f()); catch; "fail"; end; push!(steps, (title, st)); st)
        ran = String[]
        worker = (start = (_ = false) -> nothing,
                  run = code -> (push!(ran, code); "load=12.5\ncuda=true devices=4\nsyscuda=\n"))
        measured = Dict{String,Any}()
        RE._prepare_in_worker!(step, measured, "proj", worker)
        @test steps == [("Start the notebook's worker", "ok"), ("Load proj in it", "ok")]
        @test measured["env_load_s"] == 12.5 && measured["cuda"]["functional"] == "true devices=4"
        @test measured["runtime_load_s"] == measured["worker_start_s"]   # its start is the runtime's load
        sent = only(ran)
        # A worker that does not come up is not asked to load anything.
        empty!(steps); empty!(ran)
        RE._prepare_in_worker!(step, Dict{String,Any}(), "proj", (start = (_ = false) -> error("no"), run = worker.run))
        @test steps == [("Start the notebook's worker", "fail")] && isempty(ran)
        # A worker that was already up is still checked, but times neither a start nor a load: its
        # packages were loaded long before, and the times from its start stand.
        empty!(steps); empty!(ran)
        up = Dict{String,Any}()
        RE._prepare_in_worker!(step, up, "proj", (start = (_ = false) -> false, run = worker.run))
        @test steps == [("Start the notebook's worker", "ok"), ("Load proj in it", "ok")] && length(ran) == 1
        @test !haskey(up, "runtime_load_s") && !haskey(up, "env_load_s") && up["cuda"]["functional"] == "true devices=4"
        # A worker is started fresh when this prepare built its image or its environment anew, since a
        # running one keeps the packages it loaded.
        fresh = Bool[]
        w2 = (start = f -> push!(fresh, f), run = worker.run)
        for m in (Dict{String,Any}(), Dict{String,Any}("env_action" => :held),
                  Dict{String,Any}("env_action" => :build), Dict{String,Any}("sysimage" => Dict("result" => "built")))
            RE._prepare_in_worker!(step, m, "proj", w2)
        end
        @test fresh == [false, false, true, true]
        # The code it sends runs in a module of its own (its imports are top-level there) and reports.
        mktempdir() do d
            write(joinpath(d, "Project.toml"), "")
            out = read(`$(Base.julia_cmd()) --startup-file=no --project=$d -e $sent`, String)
            @test occursin(r"^load=\d", out)
        end
    end

    @testset "every prepare leaves a report, and none is rewritten" begin
        withenv("KAIMONSLATE_DATA_HOME" => mktempdir()) do
            mk(id, running, steps) = RE._write_report!("rep", Dict{String,Any}("id" => id, "region" => "rep",
                "running" => running, "started" => 1.0, "project" => "/p", "steps" => steps))
            mk("20261001T010101", false, Any[Dict("step" => "a", "status" => "ok")])
            mk("20261001T020202", false, Any[Dict("step" => "a", "status" => "warn")])
            # Cut off mid-way (a hub restart): still on disk, still running, and nobody is on it.
            mk("20261001T030303", true, Any[Dict("step" => "Install", "status" => "running")])
            reps = RE.prepare_reports("rep")
            @test [x["id"] for x in reps] == ["20261001T030303", "20261001T020202", "20261001T010101"]
            @test [x["outcome"] for x in reps] == ["interrupted", "warnings", "failed"]   # no record ⇒ not ok
            @test reps[2]["warnings"] == 1
            full = RE.prepare_report("rep", "20261001T030303")
            @test full["outcome"] == "interrupted" && full["steps"][1]["step"] == "Install"
            @test RE.prepare_report("rep", "../../etc/passwd") === nothing     # an id is never a path
            @test RE.prepare_report("rep", "20991231T000000") === nothing
        end
    end

    @testset "a prepare runs end to end and leaves its report" begin
        # A host nothing can reach: the run stops at signing in, without prompting anyone, and still
        # writes a record and a report. This is the path a crash in the runner itself would take.
        withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir(), "KAIMONSLATE_DATA_HOME" => mktempdir()) do
            RE.region_set!("unreach"; host = "slate-test-unreachable.invalid", scheduler = :slurm)
            rec = RE.prepare_region!("unreach")
            @test rec["ok"] == false
            @test rec["steps"][1]["status"] == "fail" && occursin("Sign in", rec["steps"][1]["step"])
            # Nothing was read, so the machine has nothing recorded to compare a start with.
            @test isempty(RE.host_facts("slate-test-unreachable.invalid"))
            r = RE.region_get("unreach")
            @test r.readiness["report"] == rec["report"]
            reps = RE.prepare_reports("unreach")
            @test length(reps) == 1 && reps[1]["outcome"] == "failed"
            @test RE.preparing("unreach")["running"] == false
            # A start-up failure is shown as one, not lost in the log.
            RE.prepare_failed_to_start!("nostart", ErrorException("boom"))
            st = RE.preparing("nostart")
            @test st["running"] == false && occursin("boom", st["steps"][1]["detail"])
        end
    end

    @testset "an unchanged environment is not rebuilt" begin
        # A provision skips the resolve when the host recorded this fingerprint last time, so it must
        # hold still for an untouched environment and move for anything that changes what is installed.
        mktempdir() do d
            dep = mkpath(joinpath(d, "Dep"))
            write(joinpath(dep, "Project.toml"), "name = \"Dep\"\n")
            env = mkpath(joinpath(d, "env"))
            write(joinpath(env, "Project.toml"), "[deps]\nDep = \"0\"\n")
            write(joinpath(env, "Manifest.toml"), "[[deps.Dep]]\npath = \"../Dep\"\n")
            fp = RE._env_fingerprint(env, "[infra]")
            @test RE._env_fingerprint(env, "[infra]") == fp
            @test RE._env_fingerprint(env, "[other]") != fp              # the worker packages added
            write(joinpath(dep, "Project.toml"), "name = \"Dep\"\n[deps]\nX = \"1\"\n")
            fp2 = RE._env_fingerprint(env, "[infra]")
            @test fp2 != fp                                               # a dev'd dependency's Project
            write(joinpath(env, "Manifest.toml"), "[[deps.Dep]]\npath = \"../Dep\"\nversion = \"2\"\n")
            fp3 = RE._env_fingerprint(env, "[infra]")
            @test fp3 != fp2                                              # the Manifest
            write(joinpath(env, "notebook.jl"), "1\n")
            @test RE._env_fingerprint(env, "[infra]") == fp3              # sources are not the environment
            # The same files somewhere else: the developed package's copy on a host moves, and the
            # Manifest there must be rewritten to name it.
            moved = mktempdir(); cp(env, joinpath(moved, basename(env))); cp(dep, joinpath(moved, basename(dep)))
            @test RE._env_fingerprint(joinpath(moved, basename(env)), "[infra]") != fp3

            # What the host records adds its own Julia, and whether the build precompiled.
            s(j, pc) = RE._env_stamp(fp3, j, pc)
            @test s("julia version 1.12.7", true) != s("julia version 1.12.6", true)
            @test RE._env_stamp_serves(s("julia version 1.12.7", true), s("julia version 1.12.7", false))
            @test !RE._env_stamp_serves(s("julia version 1.12.7", false), s("julia version 1.12.7", true))
            @test !RE._env_stamp_serves("", s("julia version 1.12.7", false))
        end
    end

    @testset "a prepare tests the environment a start would install" begin
        mktempdir() do d
            nbp = joinpath(d, "loose.jl"); write(nbp, "1\n")
            # Outside any project and with no environment of its own: the runtime is what there is.
            Base.current_project(d) === nothing && @test RE._reference_env(nbp) == ("", "")
            envdir = RE.notebook_env_dir(nbp)
            mkpath(envdir); write(joinpath(envdir, "Project.toml"), "")
            @test first(RE._reference_env(nbp)) == envdir      # its own environment, no project above
            write(joinpath(d, "Project.toml"), "name = \"P\"\n")
            @test RE._reference_env(nbp) == (envdir, d)
            rm(envdir; recursive = true)
            @test RE._reference_env(nbp) == (d, d)
        end
    end

    @testset "a start reads the host's state in one command" begin
        # The script runs in the remote login shell; here it runs in a local one against a fake home.
        mktempdir() do home
            rel = ".cache/kaimonslate/remote/nb-1"
            # No julia on PATH: a launcher started under a fresh HOME sets itself up first, which is slow.
            sh(script) = read(setenv(`sh -c $script`, merge(ENV, Dict("HOME" => home, "PATH" => "/usr/bin:/bin")); dir = home), String)
            fresh = RE._parse_probe(sh(RE._host_state_script(rel)))
            @test all(k -> get(fresh, k, "?") == "", ("runtime", "kgate", "env", "rg"))

            put(p, s) = (mkpath(dirname(joinpath(home, p))); write(joinpath(home, p), s))
            put(RE._runtime_dir() * "/" * RE._RUNTIME_READY, "k")
            put(RE._REMOTE_KGATE_ENV * "/.ready", "")
            put(rel * "/" * RE._ENV_STAMP, "fp0")
            put(RE._RG_PATH_FILE, "/bin/sh")
            st = RE._parse_probe(sh(RE._host_state_script(rel)))
            @test st["runtime"] == "1" && st["kgate"] == "1"
            @test st["rg"] == "1"
            @test st["env"] == ""                         # a stamp without a Manifest is no environment
            put(rel * "/Manifest.toml", "")
            @test RE._parse_probe(sh(RE._host_state_script(rel)))["env"] == "fp0"
            put(RE._RG_PATH_FILE, joinpath(home, "gone", "rg"))
            @test RE._parse_probe(sh(RE._host_state_script(rel)))["rg"] == ""   # a path that went away

            # Without a project the env lines are left out; the runtime ones remain.
            bare = RE._parse_probe(sh(RE._host_state_script()))
            @test !haskey(bare, "env") && !haskey(bare, "rg") && bare["runtime"] == "1"
            @test haskey(bare, "julia") && haskey(bare, "modules")
        end
        @test occursin("'/abs/env/Manifest.toml'", RE._host_state_script("/abs/env"))   # not under \$HOME
    end

    @testset "what does not change is not asked again" begin
        # A worker environment's Manifest, read once per (host, environment) and forgotten when a
        # provision changes that environment, on every host that names it.
        RE._ENV_DEPS[("login", "~/env-a")] = Dict("A" => Any[]); RE._ENV_DEPS[("node1", "~/env-a")] = Dict("A" => Any[])
        RE._ENV_DEPS[("login", "~/env-b")] = Dict("B" => Any[])
        @test RE._worker_env_deps("login", "~/env-a") === RE._ENV_DEPS[("login", "~/env-a")]   # no ssh: unknown host
        RE._forget_env_deps!("~/env-a")
        @test !haskey(RE._ENV_DEPS, ("login", "~/env-a")) && !haskey(RE._ENV_DEPS, ("node1", "~/env-a"))
        @test haskey(RE._ENV_DEPS, ("login", "~/env-b"))
        RE._forget_env_deps!("~/env-b")

        # The scheduler `:auto` found on a host, asked once.
        r = RE.region_set!("autosched"; host = "auto-host-unreached", scheduler = :auto)
        try
            RE._AUTO_SCHEDULER["auto-host-unreached"] = :slurm
            @test RE.region_scheduler(r) === :slurm
        finally
            delete!(RE._AUTO_SCHEDULER, "auto-host-unreached"); RE.region_delete!("autosched")
        end

        # Several files in one transfer, from their contents.
        mktempdir() do dest
            @test RE._put_texts("", dest, ["a.json" => "{}", "a.state" => "idle 1"])
            @test read(joinpath(dest, "a.json"), String) == "{}" && read(joinpath(dest, "a.state"), String) == "idle 1"
        end
    end

    @testset "a task environment built again for new sources reuses what is installed" begin
        mktempdir() do home
            root = "slate-root"                         # relative, as ssh runs it: from the home dir
            sh(script) = read(setenv(`sh -c $script`, merge(ENV, Dict("HOME" => home, "PATH" => "/usr/bin:/bin")); dir = home), String)
            env = joinpath(home, root, "env")
            for (k, fp) in (("v1", "fpA"), ("v2", "fpB"))
                mkpath(joinpath(env, k)); write(joinpath(env, k, ".slate-envfp"), fp)
            end
            @test endswith(strip(sh(RE.Sweep._env_twin_sh(root, "fpB"))), "/env/v2/.slate-envfp")
            @test isempty(strip(sh(RE.Sweep._env_twin_sh(root, "fpC"))))
            # Built for new sources with the same packages: compiles, instantiating only if that fails.
            @test !occursin("instantiate()\nPkg.precompile", RE.Sweep._env_build_code(true, true))
            @test occursin("catch", RE.Sweep._env_build_code(true, true)) && RE.Sweep._env_build_code(true, false) == ""
            @test startswith(RE.Sweep._env_build_code(false, true), "Pkg.instantiate()")

            # Pruned gently: the newest eight stay, and anything used in the last 14 days, and `keep`.
            rm(env; recursive = true)
            old = [mkpath(joinpath(env, "o$i")) for i = 1:12]
            for (i, d) in enumerate(old)
                run(`touch -t $(string(202501010000 + i)) $d`)          # o12 is the newest
            end
            run(`touch $(old[1])`)                                       # used just now
            sh(RE.Sweep._env_prune_sh(root, "o2"))
            @test sort(readdir(env)) == sort(["o1", "o2", ["o$i" for i = 6:12]...])   # o3–o5 go
        end
    end

    @testset "a remote program's colours reach the activity only" begin
        @test RE._strip_ansi("\e[32m  ✓ \e[39mJSON \e[90m[682c06a0]\e[39m") == "  ✓ JSON [682c06a0]"
        @test RE._strip_ansi("no colour here") == "no colour here"
        # Slate's own lines are coloured for the activity, and read the same once the colour is gone.
        for l in ("prepare[pm]: Precompile x — ok: compiled already", "prepare[pm]: Get a node — fail: refused",
                  "provision [3/3] environment unchanged", "FAILED: sending x", "a line of no kind",
                  "provision START host=perlmutter transport=tunnel project=~/.cache/x parent=/Users/me/p",
                  "env: dev dep 'Pkg' → perlmutter:.cache/kaimonslate/devsrc/-Users-me-Pkg.jl")
            @test RE._strip_ansi(RE._activity_line(l)) == l
        end
        @test occursin("\e[32mok", RE._activity_line("prepare[pm]: Precompile x — ok: compiled already"))
        @test occursin("\e[31mfail", RE._activity_line("prepare[pm]: Get a node — fail: refused"))
        @test RE._activity_line("a line of no kind") == "a line of no kind"
        @test occursin("\e[36mperlmutter", RE._activity_line("provision START host=perlmutter transport=tunnel"))
        @test occursin("\e[36mpm_gpu1", RE._activity_line("prepare[pm_gpu1]: Precompile x — ok: done"))
        @test occursin("\e[1;34m[2/3]", RE._activity_line("provision [2/3] KaimonGate env already built"))
        @test RE._activity_line("\e[32m✓\e[39m JSON") == "\e[32m✓\e[39m JSON"     # its own colours kept
    end

    @testset "a developed package's sources are in what a compile is for" begin
        mktempdir() do d
            dep = mkpath(joinpath(d, "Dep", "src")); write(joinpath(dep, "Dep.jl"), "module Dep end")
            write(joinpath(d, "Dep", "Project.toml"), "name = \"Dep\"\nuuid = \"00000000-0000-0000-0000-0000000000dd\"\n")
            env = mkpath(joinpath(d, "env")); write(joinpath(env, "Project.toml"), "[deps]\nDep = \"00000000-0000-0000-0000-0000000000dd\"\n")
            write(joinpath(env, "Manifest.toml"), "manifest_format = \"2.0\"\n[[deps.Dep]]\npath = \"../Dep\"\nuuid = \"00000000-0000-0000-0000-0000000000dd\"\n")
            a = RE._dev_sources_digest(env)
            @test !isempty(a) && RE._dev_sources_digest(env) == a
            write(joinpath(dep, "Dep.jl"), "module Dep f() = 1 end")
            @test RE._dev_sources_digest(env) != a
        end
    end

    @testset "a module is loaded where the cells that use it run" begin
        r = RE.parse_report("#%% code id=a region=far\nusing OnlyFarPkgX\n" *
                            "#%% code id=b\nusing HerePkgX\n" *
                            "#%% code id=c region=far\nusing HerePkgX, SharedPkgX\n" *
                            "#%% code id=d\nusing SharedPkgX\n")
        RE.build_dependencies!(r)
        by = RE.unresolved_using_paths_by_side(r, c -> NS._cell_region(c))
        @test sort(get(by, "", String[])) == ["HerePkgX", "SharedPkgX"]
        @test get(by, "far", String[]) == ["OnlyFarPkgX"]          # a module only the region uses
    end

    @testset "a directory walk is complete and the same every time" begin
        # `walkdir` cannot be pruned: editing the list it hands out races its traversal and can drop a
        # sibling of the pruned directory. These walks prune `.git` and must still see `src`.
        mktempdir() do d
            mkpath(joinpath(d, ".git", "objects")); write(joinpath(d, ".git", "objects", "x"), "x")
            mkpath(joinpath(d, "src", "sub")); write(joinpath(d, "src", "A.jl"), "a"); write(joinpath(d, "src", "sub", "B.jl"), "b")
            write(joinpath(d, "Project.toml"), "")
            want = ["Project.toml", "src/A.jl", "src/sub/B.jl"]
            @test all(_ -> RE._files_under(d; descend = r -> basename(r) != ".git") == want, 1:50)
            @test RE._files_under(d; descend = r -> r != "src/sub") == [".git/objects/x", "Project.toml", "src/A.jl"]
            digests = Set(RE._tree_digest(d, [".git"]) for _ = 1:50)
            @test length(digests) == 1
        end
    end

    @testset "the sync and the provision send nothing the other already sent" begin
        src, dest, cache = mktempdir(), mktempdir(), mktempdir()
        withenv("KAIMONSLATE_CACHE_HOME" => cache) do
            mkpath(joinpath(src, "src")); write(joinpath(src, "src", "A.jl"), "a"); write(joinpath(src, "notes.txt"), "n")
            to = joinpath(dest, "copy"); ex = RE._DEVSRC_SEND_EXCLUDES; key = RE._sent_key("", to)
            @test RE._send_tree!("", src, to; excludes = ex)                   # a provision
            s = RE.SyncSource(src)
            d = RE.SyncDest("", to, ex, "", RE._sync_seed(src, ex, key), Dict{String,Any}(), false)
            @test d.sent == RE._sync_files(src, ex)                            # the watch starts from it
            write(joinpath(src, "src", "A.jl"), "a2")
            @test RE._sync_dest!(s, d, RE._sync_files(src, ex))               # the sync sends the edit
            @test isfile(joinpath(to, "notes.txt"))                            # and leaves what it does not watch
            rm(joinpath(to, "notes.txt"))                                      # would come back if sent again
            @test RE._send_tree!("", src, to; excludes = ex) && !isfile(joinpath(to, "notes.txt"))
            write(joinpath(src, "notes.txt"), "n2")                            # outside the watch: the provision's
            @test RE._send_tree!("", src, to; excludes = ex) && read(joinpath(to, "notes.txt"), String) == "n2"
        end
    end

    @testset "an unchanged source directory is not sent again" begin
        src, dest, cache = mktempdir(), mktempdir(), mktempdir()
        withenv("KAIMONSLATE_CACHE_HOME" => cache) do
            mkpath(joinpath(src, "src")); write(joinpath(src, "src", "A.jl"), "a")
            to = joinpath(dest, "copy")
            @test RE._send_tree!("", src, to; excludes = [".git"]) && isfile(joinpath(to, "src", "A.jl"))
            rm(to; recursive = true)                                   # would come back if sent again
            @test RE._send_tree!("", src, to; excludes = [".git"]) && !isdir(to)
            write(joinpath(src, "src", "A.jl"), "a2")
            @test RE._send_tree!("", src, to; excludes = [".git"]) && read(joinpath(to, "src", "A.jl"), String) == "a2"
            rm(to; recursive = true)
            @test RE._send_tree!("", src, to; excludes = [".git"], force = true) && isfile(joinpath(to, "src", "A.jl"))
        end
    end

    @testset "a prepare compiles again only for a new environment, node type or image" begin
        mktempdir() do home
            t = RE.RemoteTarget("h"; project = "~/.cache/kaimonslate/remote/nb-1")
            stamp = RE._env_stamp_path(t); mark = stamp * ".pc"
            mkpath(joinpath(home, dirname(stamp)))
            # What the step's shell does: the check, then (when it did not stop) a compile that writes
            # the mark as the Julia snippet would.
            run_step(jopt = "", sources = "") = read(setenv(`sh -c $("JOPT='$jopt'; " * RE._precompiled_check_sh(t, mark; sources) *
                                                       "echo compiled; printf '%s' \"\$SLATE_PC\" > \"\$HOME/$mark\"")`,
                                              merge(ENV, Dict("HOME" => home, "PATH" => "/usr/bin:/bin"))), String)
            compiled(jopt = "", sources = "") = occursin("compiled", run_step(jopt, sources))
            @test compiled()                                           # no environment recorded
            write(joinpath(home, stamp), "fp1")
            @test compiled()                                           # first compile for it
            @test !compiled()                                          # the same again: stops
            write(joinpath(home, stamp), "fp1+pc")
            @test !compiled()                                          # the suffix a compile adds
            write(joinpath(home, stamp), "fp1")
            @test !compiled() && read(joinpath(home, stamp), String) == "fp1+pc"   # current: marked compiled
            @test compiled("--sysimage=/x/cpu.so")                     # booted from an image now
            write(joinpath(home, stamp), "fp2")
            @test compiled("--sysimage=/x/cpu.so")                     # another environment
            @test compiled("--sysimage=/x/cpu.so", "srcA")             # a developed package's sources
            @test !compiled("--sysimage=/x/cpu.so", "srcA")
            @test compiled("--sysimage=/x/cpu.so", "srcB")             # ... edited
            f = joinpath(home, "m.pc")
            withenv("SLATE_PC" => "fp2|cpu|") do
                Core.eval(Module(), Meta.parseall(RE._precompiled_mark_snippet(f)))
            end
            @test read(f, String) == "fp2|cpu|"
        end
    end

    @testset "a worker whose environment was built again is replaced" begin
        # Asked on every reattach (record, probe, park, adoption): it holds the packages it loaded at boot.
        @eval struct EnvInfoK; info::Dict{String,Any}; running::Vector{String}; port::Int; label::String; end
        @eval RE._tool(k::EnvInfoK, name::String, args::Dict; timeout::Float64 = 0.0) =
            name == "__slate_env_info" ? k.info : Dict{String,Any}("running" => k.running)
        info(rebuilt) = Dict{String,Any}("payload_sha" => RE._payload_sha(), "job" => "", "env_rebuilt" => rebuilt)
        @test RE._worker_current(EnvInfoK(info(false), String[], 1, "nb"))
        @test !RE._worker_current(EnvInfoK(info(true), String[], 1, "nb"))
        @test RE._worker_current(EnvInfoK(info(true), ["cell1"], 1, "nb"))          # its running cell is kept
        @test RE._worker_current(EnvInfoK(delete!(info(true), "env_rebuilt"), String[], 1, "nb"))   # an older worker
    end

    @testset "compiled code is keyed by CPU architecture, not the chip's model" begin
        # Perlmutter's login (EPYC 7713) and GPU nodes (EPYC 7763) are one microarchitecture: code
        # compiled on either runs alike on both. A flag Julia does not compile for (`cpb`) does not split
        # them; a different microarchitecture with AVX-512 does.
        key(info) = mktempdir() do d
            f = joinpath(d, "cpuinfo"); write(f, info)
            readchomp(setenv(`sh -c $(RE._SYSIMAGE_CPU_SH * "; printf '%s' \"\$CPU\"")`, "SLATE_CPUINFO" => f, "PATH" => ENV["PATH"]))
        end
        amd(name, family, model, flags) = "vendor_id\t: AuthenticAMD\ncpu family\t: $family\nmodel\t\t: $model\n" *
                                          "model name\t: $name\nflags\t\t: $flags\n"
        milan = "fpu sse sse2 ssse3 sse4_1 sse4_2 avx avx2 fma bmi1 bmi2 aes vaes sha_ni"
        login = key(amd("AMD EPYC 7713 64-Core Processor", 25, 1, milan))
        node = key(amd("AMD EPYC 7763 64-Core Processor", 25, 1, milan * " cpb"))
        genoa = key(amd("AMD EPYC 9654 96-Core Processor", 25, 17, milan * " avx512f avx512bw"))
        @test login == node && startswith(login, "AuthenticAMD-25-1-")
        @test genoa != login
        arm = key("CPU implementer\t: 0x41\nCPU architecture: 8\nCPU part\t: 0xd0c\nFeatures\t: fp asimd sve\n")
        @test startswith(arm, "0x41-8-0xd0c-")
    end

    @testset "a worker being reaped is not attached to again" begin
        RE._mark_reaped!("reapnode", 9311)
        now = time()
        @test RE._reaped("reapnode", 9311; now)
        @test !RE._reaped("reapnode", 9312; now) && !RE._reaped("othernode", 9311; now)
        @test !RE._reaped("reapnode", 9311; now = now + RE._REAPED_TTL + 1)
        RE._unmark_reaped!("reapnode", 9311)            # a fresh worker started on the port
        @test !RE._reaped("reapnode", 9311; now)
    end

    @testset "a worker that does not start says what it is waiting on" begin
        # The shape of the worker that hung on a scratch file system: blocked in the Lustre client
        # reading a compiled cache, beside a compile child waiting on it.
        out = """
        P|4100|D|cl_sync_io_wait| 0.3 342
        F|4100|/pscratch/d/compiled/v1.12/KaimonGate/OYbhc.ji
        P|4101|S|pipe_read| 0.0 340
        F|4101|/home/u/.cache/kaimonslate/worker/worker-9111.log
        """
        procs = RE._parse_start_probe(out)
        @test [p.pid for p in procs] == [4100, 4101] && procs[1].age == 342 &&
              procs[1].files == ["/pscratch/d/compiled/v1.12/KaimonGate/OYbhc.ji"]
        d = RE._classify_start(procs)
        @test d.kind === :fs && d.file == procs[1].files[1] && occursin("uninterruptible, cl_sync_io_wait", d.summary)
        kind(s) = RE._classify_start(RE._parse_start_probe(s)).kind
        @test kind("P|7|S|fifo_open| 0.0 30\n") === :fs                  # a file that will not open
        @test kind("P|7|R|futex_wait_queue| 297.5 600\n") === :spin      # Julia-side, not the file system
        @test kind("P|7|S|do_epoll_wait| 1.0 30\n") === :waiting
        @test kind("") === :gone
        @test success(`sh -n -c $(RE._start_probe_sh(9111))`)

        # Two blocked starts in a row hold the next; the hold runs out, and a start that connects clears it.
        h = "hold-test-host"
        RE._clear_start_hold!(h)
        RE._note_start!(h, :fs, "x"; now = 1000.0)
        once = RE._start_held(h; now = 1001.0)
        RE._note_start!(h, :fs, "blocked reading f"; now = 1010.0)
        @test once === nothing && occursin("blocked reading f", something(RE._start_held(h; now = 1020.0), ""))
        @test RE._start_held(h; now = 1010.0 + RE._start_hold_s() + 1) === nothing
        RE._note_start!(h, :started)
        @test RE._start_held(h; now = 1020.0) === nothing
    end

    @testset "old versions of the worker code are removed gently" begin
        mktempdir() do home
            pay = joinpath(home, RE._REMOTE_WORKER, "payload")
            old = [mkpath(joinpath(pay, "v$i")) for i = 1:8]
            for (i, d) in enumerate(old); run(`touch -t $(string(202501010000 + i)) $d`); end
            run(`touch $(old[1])`)                                          # in use just now
            read(setenv(`sh -c $(RE._runtime_prune_sh("v2"))`, merge(ENV, Dict("HOME" => home, "PATH" => "/usr/bin:/bin")); dir = home), String)
            # The newest five stay (v1 touched now, v8–v5), and `keep`; v3 and v4 go.
            @test sort(readdir(pay)) == sort(["v1", "v2", "v5", "v6", "v7", "v8"])
        end
    end

    @testset "an environment's developed packages are found before it has a Manifest" begin
        # A project resolved nowhere yet names its local packages only in `[sources]`, and those name
        # theirs the same way: all of them travel, and each copy's own paths are pointed at the others.
        mktempdir() do root
            mk(name, body) = (d = mkpath(joinpath(root, name)); write(joinpath(d, "Project.toml"), "name = \"$name\"\n" * body); d)
            b = mk("B", "")
            a = mk("A", "[sources]\nB = {path = \"../B\"}\n")
            seb = mk("SlateExtensionsBase", "")
            env = mk("env", "[sources]\nA = {path = \"../A\"}\nSlateExtensionsBase = {path = \"../SlateExtensionsBase\"}\nenv = {path = \".\"}\n")
            @test RE.Sweep.local_dev_deps(env) == ["A" => a, "B" => b, "SlateExtensionsBase" => seb]
        end
        s = RE._env_instantiate_script("x", [("A", "devsrc/A"), ("SlateExtensionsBase", RE._remote_seb())])
        @test occursin("raw\"devsrc/A\", \"Project.toml\"", s)                       # A's own [sources] rewritten
        @test !occursin("raw\"" * RE._remote_seb() * "\", \"Project.toml\"", s)          # the worker's SDK left alone
    end

    @testset "Slate's packages join a notebook's environment without a resolve" begin
        entry(v; deps = String[], weak = String[]) =
            Dict{String,Any}("uuid" => string(Base.UUID(UInt128(hash(v)))), "version" => v, "deps" => deps,
                             (isempty(weak) ? () : ("weakdeps" => weak,))...)
        man(jv, deps) = Dict{String,Any}("julia_version" => jv, "manifest_format" => "2.0",
                                         "deps" => Dict{String,Any}(n => [e] for (n, e) in deps))
        nbp = Dict{String,Any}("deps" => Dict{String,Any}("A" => "a"), "compat" => Dict{String,Any}("A" => "1"))
        refp = Dict{String,Any}("deps" => Dict{String,Any}("G" => "g"))
        nbm = man("1.12.7", ["A" => entry("1.0.0"; deps = ["C"]), "C" => entry("2.0.0")])
        refm = man("1.12.7", ["G" => entry("3.0.0"; deps = ["C"]), "C" => entry("2.0.0")])
        p, m = RE._merge_manifests(nbp, nbm, refp, refm)
        @test p["deps"] == Dict("A" => "a", "G" => "g") && p["compat"] == nbp["compat"]
        @test sort(collect(keys(m["deps"]))) == ["A", "C", "G"] && m["deps"]["G"] == refm["deps"]["G"]
        @test !haskey(nbm["deps"], "G")                                   # the inputs are left alone
        # Anything a resolve would have had to decide is left to one.
        @test occursin("C is 2.1.0 in the notebook, 2.0.0",
                       RE._merge_manifests(nbp, man("1.12.7", ["A" => entry("1.0.0"), "C" => entry("2.1.0")]), refp, refm))
        @test occursin("Julia 1.12.6", RE._merge_manifests(nbp, merge(nbm, Dict("julia_version" => "1.12.6")), refp, refm))
        # Format 2.1 is 2.0 with the registries the packages came from, kept from the notebook's side.
        reg = Dict{String,Any}("General" => Dict{String,Any}("uuid" => "23338594-aafe-5451-b93e-139f81909106"))
        p21, m21 = RE._merge_manifests(nbp, merge(nbm, Dict("manifest_format" => "2.1", "registries" => reg)), refp, refm)
        @test m21["manifest_format"] == "2.1" && m21["registries"] == reg && haskey(m21["deps"], "G")
        @test occursin("another format", RE._merge_manifests(nbp, merge(nbm, Dict("manifest_format" => "1.0")), refp, refm))
        @test occursin("weak dependency on G",
                       RE._merge_manifests(nbp, man("1.12.7", ["A" => entry("1.0.0"; weak = ["G"])]), refp, refm))
        @test occursin("G as a weak dependency",
                       RE._merge_manifests(merge(nbp, Dict("weakdeps" => Dict("G" => "g"))), nbm, refp, refm))
        # The host adds nothing to a combined environment, and points the worker code at this version's copy.
        valid(s) = !any(x -> x isa Expr && x.head === :error, Meta.parseall(s).args)
        s = RE._env_instantiate_script("x", Tuple{String,String}[]; merged = true)
        @test valid(s) && !occursin("Pkg.add", s) && !occursin("Pkg.develop", s)
        @test occursin(RE._remote_worker_pkg(), s) && occursin(RE._remote_seb(), s) && occursin("project_hash", s)
        r = RE._infra_ref_script(RE._infra_ref_root())
        @test valid(r) && occursin("Pkg.add", r) && occursin(RE._remote_seb(), r)

        # For real: two environments resolved apart, combined, are current to Pkg and load.
        mktempdir() do root
            function mkpkg(name, deps)
                d = mkpath(joinpath(root, name, "src"))
                uuid = string(Base.UUID(UInt128(hash(name))))
                write(joinpath(root, name, "Project.toml"),
                      "name = \"$name\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n[deps]\n" *
                      join(("$x = \"$(Base.UUID(UInt128(hash(x))))\"\n" for x in deps)))
                write(joinpath(d, "$name.jl"), "module $name\n" * join(("using $x\n" for x in deps)) * "end\n")
                return joinpath(root, name)
            end
            c, a, g = mkpkg("Cdep", String[]), mkpkg("Anb", ["Cdep"]), mkpkg("Ginfra", ["Cdep"])
            nb, ref, out = (mkpath(joinpath(root, x)) for x in ("nb", "ref", "out"))
            jl(code) = success(pipeline(setenv(`$(Base.julia_cmd()) --startup-file=no -e $code`,
                                               merge(ENV, Dict("JULIA_PKG_OFFLINE" => "true", "JULIA_PKG_PRECOMPILE_AUTO" => "0"))),
                                        stdout = devnull, stderr = devnull))
            @test jl("import Pkg; Pkg.activate($(repr(nb))); Pkg.develop([Pkg.PackageSpec(path=$(repr(c))), Pkg.PackageSpec(path=$(repr(a)))]);" *
                     "Pkg.activate($(repr(ref))); Pkg.develop([Pkg.PackageSpec(path=$(repr(c))), Pkg.PackageSpec(path=$(repr(g)))])")
            T = RE.Sweep.TOML
            p, m = RE._merge_manifests((T.parsefile(joinpath(d, f)) for d in (nb, ref) for f in ("Project.toml", "Manifest.toml"))...)
            for (f, x) in (("Project.toml", p), ("Manifest.toml", m)); open(io -> T.print(io, x), joinpath(out, f), "w"); end
            @test jl("import Pkg; Pkg.activate($(repr(out)))\n" * RE._PROJECT_HASH_SNIPPET *
                     "Pkg.is_manifest_current($(repr(out))) === true || exit(3); Pkg.instantiate(); using Anb, Ginfra")
        end
    end

    @testset "a prepare keeps an environment whose depot still holds it" begin
        mktempdir() do home
            rel = ".cache/kaimonslate/remote/nb-1"
            sh(script) = read(setenv(`sh -c $script`, merge(ENV, Dict("HOME" => home, "PATH" => "/usr/bin:/bin")); dir = home), String)
            held = rel * "/" * RE._ENV_STAMP * ".held"
            probe() = RE._parse_probe(sh(RE._host_state_script(rel; held)))
            a, b = mkpath(joinpath(home, "depot", "A")), mkpath(joinpath(home, "depot", "B"))
            @test get(probe(), "held", "?") == ""                          # nothing recorded
            mkpath(joinpath(home, rel)); write(joinpath(home, held), "fp0\n$a\n$b\n")
            st = probe()
            @test (st["heldfor"], st["held"]) == ("fp0", "1")
            rm(b)
            @test probe()["held"] == ""                                     # the depot lost one
            @test !haskey(RE._parse_probe(sh(RE._host_state_script(rel))), "held")   # a start does not ask

            # The decision: a start keeps a matching environment; a prepare keeps it only when the
            # depot holds what was recorded for that same stamp, and otherwise fetches what is missing.
            s = "fp1"
            act(env; rebuild, h = "", hf = "") = RE._env_action(Dict("env" => env, "held" => h, "heldfor" => hf), s; rebuild)
            @test act(""; rebuild = false) === :build && act("other"; rebuild = true, h = "1", hf = "other") === :build
            @test act(s; rebuild = false) === :keep
            @test act(s; rebuild = true, h = "1", hf = s) === :held
            @test act(s; rebuild = true) === :repair
            @test act(s; rebuild = true, h = "1", hf = "fp0") === :repair      # a list from an earlier build
            @test act(s * "+pc"; rebuild = true, h = "1", hf = s * "+pc") === :held
            @test act(s * "+pc"; rebuild = true, h = "1", hf = s) === :held       # compiled after the list

            # The list a build writes: its stamp, then directories that exist.
            f = joinpath(home, "list.held")
            Core.eval(Module(), Meta.parseall("import Pkg\n" * RE._held_record_snippet(f, "fp9")))
            lines = readlines(f)
            @test first(lines) == "fp9" && length(lines) > 1 && all(ispath, lines[2:end])
        end
        # Fetching what a depot lost adds nothing to the environment, so nothing resolves.
        r = RE._env_repair_script("x"; precompile = false, held_file = "x.held", stamp = "fp")
        @test occursin("Pkg.instantiate()", r) && !occursin("Pkg.add", r) && !occursin("develop", r)
        # Nothing compiles there, so no count of what would (a check per package on a cluster filesystem).
        @test !occursin("SLATE_PREP total", r) &&
              !occursin("SLATE_PREP total", RE._env_instantiate_script("x", Tuple{String,String}[]; precompile = false))
        @test occursin("SLATE_PREP total", RE._env_instantiate_script("x", Tuple{String,String}[]))
        @test occursin("x.held", RE._env_instantiate_script("x", Tuple{String,String}[]; held_file = "x.held"))
        @test RE._seb_sha() == RE._seb_sha() && length(RE._seb_sha()) == 16
    end

    # Signing in interactively REPLACES the session (a half-open one is cleared first), and every
    # forward on it dies. Nothing a layer up can detect that — a dead forward looks healthy until a
    # transfer sits on it for the whole receive timeout — so the drop has to be announced and the
    # cached data forwards discarded, or the next boundary transfer fails with a ZMQ timeout that
    # reads as a broken region rather than as "you signed in again".
    @testset "a dropped session takes its forwards with it" begin
        ST = RE.Sweep.SshTransport
        saw = String[]
        prev = ST._ON_DROP[]
        try
            ST.on_drop!((h, died) -> push!(saw, "$h:$died"))
            ST._announce_drop("login"); ST._announce_drop("login", true)
            @test saw == ["login:false", "login:true"]
            # A listener that throws must not break disconnecting — that would strand the session.
            ST.on_drop!((_, _) -> error("boom"))
            @test ST._announce_drop("login") === nothing
        finally
            ST._ON_DROP[] = prev
        end

        # The eviction reaches the NODES routed through the dropped host, not just the host itself:
        # a compute node's forward is opened on its login node's session, so the key names the node
        # while the session names the way in.
        # No forwards, so closing one touches no session — the cache bookkeeping is what's under test.
        tun(h) = (RE.Tunnel(h, Tuple{Int,Int}[], nothing, true, nothing, "127.0.0.1"), 0)
        RE.route!("c8", "login2", "5")
        try
            lock(RE._DATA_TUNNEL_LOCK) do
                RE._DATA_TUNNELS[("login2", 7001)] = tun("login2")
                RE._DATA_TUNNELS[("c8", 7002)] = tun("login2")
                RE._DATA_TUNNELS[("unrelated", 7003)] = tun("unrelated")
            end
            RE._session_dropped!("login2")
            left = lock(RE._DATA_TUNNEL_LOCK) do; sort(collect(keys(RE._DATA_TUNNELS))); end
            @test left == [("unrelated", 7003)]
        finally
            RE.route!("c8", "")
            lock(RE._DATA_TUNNEL_LOCK) do; delete!(RE._DATA_TUNNELS, ("unrelated", 7003)); end
        end
    end

    # Signing out is a DECISION, so what it implies is known at once. A `:tunnel` worker's wire is a
    # forward on its host's session and cannot outlive it; a `:direct` worker dials the node itself
    # and can — which is the whole reason to choose it, so it must not be dropped alongside.
    @testset "a signed-out session severs only the wires it carried" begin
        kern(t) = (; target = t)
        tun  = kern(RE.RemoteTarget("login"; transport = :tunnel))
        node = kern(RE.RemoteTarget("c7"; transport = :tunnel))
        dir  = kern(RE.RemoteTarget("c7"; transport = :direct))
        RE.route!("c7", "login", "9")
        try
            @test RE.rides_session(tun, ["login"]) && RE.rides_session(node, ["c7"])
            @test !RE.rides_session(dir, ["c7"])            # dials the node — outlives the session
            @test !RE.rides_session(tun, ["other"])
            @test !RE.rides_session(kern(nothing), ["login"])   # local/in-process: no wire to sever

            # The host to NAME when saying why: the session that carries the wire, which for a
            # compute node is its login node, not the node itself.
            @test RE.session_host(node) == "login"
            @test RE.session_host(tun) == "login"
            @test RE.session_host(dir) == ""                # nothing rides a session here
            @test RE.session_host(kern(nothing)) == ""
        finally
            RE.route!("c7", "")
        end
        @test RE.session_host(node) == "c7"                 # unrouted: its own host holds the session
    end

    # The worker popup mixes two kinds of chip in one row: fixed-width METRIC chips, which must not
    # wrap (a number that reflows on every tick makes the row jitter), and one NOTE chip carrying a
    # whole sentence, which must. They are two single-class rules in one sheet, so which wins is
    # decided by the cascade — and `.wchip` is declared after `.wchip-warn`, so the note silently
    # inherited `nowrap` and a full sentence was clipped at the popup's edge with no ellipsis.
    @testset "the worker note chip out-ranks the metric chip's nowrap" begin
        css = read(joinpath(@__DIR__, "..", "src", "assets", "notebook.css"), String)
        base = findfirst(r"(?<![\w.-])\.wchip\s*\{[^}]*white-space\s*:\s*nowrap"s, css)
        warn = findfirst(r"\.wchip[\w.-]*\.wchip-warn[^}]*white-space\s*:\s*normal"s, css)
        @test base !== nothing && warn !== nothing     # both rules still exist and still disagree
        # Specificity (two classes) settles it whatever the order; bare `.wchip-warn` would need to
        # come after `.wchip`, and does not.
        @test occursin(".wchip.wchip-warn", css)
        @test occursin(r"\.wchip\.wchip-warn[^}]*overflow-wrap\s*:\s*anywhere"s, css)
    end

    # The home page and a notebook carry different stylesheets, so a class used by a component on
    # both has to live in the one sheet they share. Pure JS, asserted from node; skips without it.
    @testset "shared styles reach both pages (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping the shared-style assertions"
            @test true
        else
            io = IOBuffer()
            ok = success(pipeline(`$node $(joinpath(@__DIR__, "js", "shared_styles.mjs"))`;
                                  stdout = io, stderr = io))
            ok || print(String(take!(io)))
            @test ok
        end
    end

    @testset "both worker paths provision the worker package" begin
        # What the worker may import is SlateWorker's `[deps]` (test_shared_includes.jl holds them to
        # its imports). Each path has to provision the package itself: `src/worker_infra` for a local
        # worker, `_worker_develop()` for a remote one. Provisioned in only one, every worker on the
        # other path dies at boot.
        src = dirname(pathof(KaimonSlate))
        infra = read(joinpath(src, "worker_infra", "Project.toml"), String)
        @test occursin("SlateWorker", infra) && occursin("SlateExtensionsBase", infra)
        @test occursin(RE._remote_worker_pkg(), RE._worker_develop()) && occursin(RE._remote_seb(), RE._worker_develop())
        # `ripgrep_jll` is resolved softly at load (`BatchLauncher._resolve_rg`), so a host that cannot
        # see it loses log search rather than the batch fabric. It is still provisioned both ways.
        @test occursin("ripgrep_jll", infra) && occursin("ripgrep_jll", RE._infra_spec())
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

# Pruning has to reach the FAR SIDE, not just the wire.
#
# A send merges, so ceasing to send something leaves whatever earlier provisions already put there.
# The transfer shrank and the remote directory did not, which reads as the rules having done
# nothing at all — the number someone checks after pruning is what is sitting on the host.
@testset "the remote loses what the rules now hold" begin
    mktempdir() do src
        mktempdir() do dst
            for d in ("src", "assets", "keepme"); mkpath(joinpath(src, d)); end
            write(joinpath(src, "Project.toml"), "name=\"T\"\n")
            write(joinpath(src, "src", "main.jl"), "x = 1\n")
            write(joinpath(src, "assets", "big.bin"), rand(UInt8, 50_000))
            write(joinpath(src, "keepme", "k.txt"), "keep\n")
            ex = ["Manifest.toml", ".git"]
            landed() = sort([replace(relpath(joinpath(r, f), dst), '\\' => '/')
                             for (r, _, fs) in walkdir(dst) for f in fs])

            # An empty host means "this machine", which exercises the whole send + prune path
            # without needing ssh.
            RE._send_dir!("", src, dst; excludes = ex, region = "r", filter = true)
            @test "assets/big.bin" in landed()

            write(joinpath(src, ".slateignore"), "[region:r]\nassets/\n")
            RE._send_dir!("", src, dst; excludes = ex, region = "r", filter = true)
            after = landed()
            @test !any(startswith(p, "assets") for p in after)     # gone from the far side
            # …and nothing else was taken with it. A blanket replace would also remove what the
            # host generated for itself, which is why only HELD entries are touched.
            @test "keepme/k.txt" in after && "src/main.jl" in after
        end
    end
end
