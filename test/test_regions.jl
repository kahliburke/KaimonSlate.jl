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
                # SLURM joins the running job rather than logging in again.
                @test occursin("srun --jobid=4242 --overlap", RE._in_allocation(v, "c1", "hostname"))
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

                lock(RE._REGION_PLACE_LOCK) do
                    RE._REGION_PLACE["leased"] =
                        (host = "c9", job = "77", ts = time(), checked = time(), until = time() - 1)
                end
                @test RE.region_host(r) == "login"             # past it: nothing placed, ask again
                @test !RE._region_holds_node(r)
                @test RE.via("c9") === nothing                 # the route goes with the allocation
                @test !haskey(RE._REGION_PLACE, "leased")
                # An unrouted host keeps the plain advice — that one really is an ssh/config problem.
                @test occursin("~/.ssh/config", RE._unreachable("workstation"))
            finally
                RE.route!("c9", "")
                lock(RE._REGION_PLACE_LOCK) do; delete!(RE._REGION_PLACE, "leased"); end
            end
        end
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
            ST.on_drop!(h -> push!(saw, h))
            ST._announce_drop("login")
            @test saw == ["login"]
            # A listener that throws must not break disconnecting — that would strand the session.
            ST.on_drop!(_ -> error("boom"))
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

    @testset "the worker payload imports only stdlibs" begin
        # A worker loads these files in the NOTEBOOK's project, where the only packages guaranteed
        # present are stdlibs. An `import` of a KaimonSlate dependency here takes EVERY worker down
        # at boot — and the rest of this suite cannot see it, because tests run in KaimonSlate's own
        # project, where that package resolves perfectly well. So check it by reading the source.
        src = dirname(pathof(KaimonSlate))
        # Stdlibs, plus the two packages the boot script provisions into the worker's own
        # `worker_infra` env — those are Slate's to guarantee, unlike a dependency of the hub.
        allowed = Set(readdir(Sys.STDLIB)) ∪ Set(["Base", "Core", "Main",
                                                  "KaimonGate", "SlateExtensionsBase"])
        # PARSE rather than grep: `using CairoMakie` in a docstring and `using MyPkg` in a `@sweep`
        # example are not imports, and an import inside a `try` is guarded on purpose.
        function toplevel_imports(ex, out = String[])
            ex isa Expr || return out
            if ex.head in (:import, :using)
                for a in ex.args
                    a isa Expr || continue
                    # `import A`, `using A: x`, `import ..A` — the first symbol is the package.
                    parts = a.head === :(:) ? a.args[1].args : a.args
                    isempty(parts) && continue
                    parts[1] isa Symbol && push!(out, String(parts[1]))
                end
            elseif ex.head in (:toplevel, :block, :module)
                for a in ex.args; toplevel_imports(a, out); end
            end
            return out
        end
        seen, queue, offenders = Set{String}(), ["worker.jl"], String[]
        while !isempty(queue)
            f = popfirst!(queue)
            (f in seen || !isfile(joinpath(src, f))) && continue
            push!(seen, f)
            text = read(joinpath(src, f), String)
            for m in eachmatch(r"include\(\s*(?:@__MODULE__\s*,\s*)?joinpath\(@__DIR__,\s*\"([^\"]+\.jl)\"", text)
                push!(queue, String(m.captures[1]))
            end
            parsed = try; Meta.parseall(text); catch; nothing; end
            parsed === nothing && continue
            for pkg in toplevel_imports(parsed)
                pkg in allowed && continue
                push!(offenders, "$f imports $pkg")
            end
        end
        @test length(seen) > 10                          # the walk actually found the payload
        @test "remotestore.jl" in seen                   # …including the transport layer
        isempty(offenders) || @info "worker payload non-stdlib imports" offenders
        @test isempty(offenders)
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
