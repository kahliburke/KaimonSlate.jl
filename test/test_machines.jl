# The machine layer (src/machines.jl): what a `clusters.json` entry says about a host, what preparing
# found there, and the shell every Julia on it starts in. Local only: no ssh.
using ReTest
using KaimonSlate

const RE = KaimonSlate.ReportEngine

@testset "machines" begin
    withenv("KAIMONSLATE_CONFIG_HOME" => mktempdir()) do
        @testset "an entry describes the machine" begin
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter", "kind" => "slurm",
                                 "account" => "m1", "depot" => "\$HOME/d", "prologue" => "module load x"))
            m = RE.machine_get("pm")
            @test m.host == "perlmutter" && m.kind === :slurm && m.account == "m1"
            @test m.depot == "~/d"                                  # one spelling for the shell to expand
            @test RE.machine_get("nope") === nothing
            @test RE.machine_from(Dict("name" => "w", "host" => "box", "kind" => "exec")).kind === :exec
        end

        @testset "a region takes its host and scheduler from its machine" begin
            r = RE.region_set!("gpu"; machine = "pm", partition = "gpu", gpus = "4")
            @test r.host == "perlmutter" && r.scheduler === :slurm && r.account == "m1"
            @test RE.region_machine(r).name == "pm"
            # An edit to the machine reaches the region on the next read.
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter2", "kind" => "pbs"))
            r = RE.region_get("gpu")
            @test r.host == "perlmutter2" && r.scheduler === :pbs && r.account == ""
            # The region's own account wins over the machine's.
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter", "kind" => "slurm", "account" => "m1"))
            @test RE.region_set!("gpu"; account = "m2").account == "m2"
            # Editing a region, or another one, does not copy the machine's values into it.
            RE.region_set!("cpu"; machine = "pm")
            RE.region_set!("cpu"; walltime = "01:00:00")
            RE.region_set!("gpu"; walltime = "00:30:00")
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter", "kind" => "slurm", "account" => "m3"))
            @test RE.region_get("cpu").account == "m3" && RE.region_get("cpu").walltime == "01:00:00"
            @test RE.region_get("gpu").account == "m2"
            # How the node is asked for comes from the machine too, and a region can say otherwise.
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter", "kind" => "slurm", "account" => "m3",
                                 "submit" => "salloc"))
            @test RE.region_get("cpu").submit == "salloc"
            @test RE.region_set!("cpu"; submit = "sbatch").submit == "sbatch"
            @test RE.region_set!("cpu"; submit = "qsub").submit == "salloc"           # not a way: the machine's
            RE.cluster_set!(Dict("name" => "pm", "host" => "perlmutter", "kind" => "slurm", "account" => "m3"))
            # A region that names a host directly runs on an implicit machine there.
            w = RE.region_set!("ws"; host = "box")
            m = RE.region_machine(w)
            @test m.name == "" && m.host == "box" && m.kind === :exec && m.depot == ""
        end

        @testset "a machine is a region, and a region varies its machine" begin
            RE.cluster_set!(Dict("name" => "mx", "host" => "mxhost", "kind" => "slurm", "account" => "acc",
                                 "partition" => "gpu", "walltime" => "00:30:00", "gpus" => "4",
                                 "directives" => "#SBATCH --constraint=gpu\n--licenses=scratch", "qos" => "debug",
                                 "root_remote" => "/s"))
            # Its shape, as one map, whatever form the entry wrote it in.
            @test RE.machine_options(RE.cluster_get("mx")) ==
                  Dict("constraint" => "gpu", "licenses" => "scratch", "qos" => "debug")
            # The machine is a region of its own name, asking for what it declares.
            r = RE.region_get("mx")
            @test r !== nothing && r.machine == "mx" && r.host == "mxhost" && r.scheduler === :slurm
            @test r.partition == "gpu" && r.walltime == "00:30:00" && r.gpus == "4" && r.account == "acc"
            @test r.options["constraint"] == "gpu" && r.options["qos"] == "debug"
            # A variant stores what differs; the rest comes from the machine, options key by key.
            v = RE.region_set!("mx_cpu"; machine = "mx", options = Dict("constraint" => "cpu"), gpus = "", account = "acc2")
            @test v.partition == "gpu" && v.walltime == "00:30:00" && v.account == "acc2"
            @test v.options["constraint"] == "cpu" && v.options["qos"] == "debug"
            # Editing the machine's own region keeps it bound to the machine.
            e = RE.region_set!("mx"; walltime = "01:00:00")
            @test e.machine == "mx" && e.walltime == "01:00:00" && e.partition == "gpu"
            RE.region_delete!("mx")
            @test RE.region_get("mx").walltime == "00:30:00"               # back to the machine's own
            # A region is a sweep target too: the machine's entry with the region's shape.
            d = only(filter(c -> c["name"] == "mx_cpu", RE.clusters_resolved()))
            t = RE.Sweep.cluster(Dict(String(k) => string(x) for (k, x) in d))
            @test (get(t.resources, :constraint, ""), t.qos, t.account) == ("cpu", "debug", "acc2")
            @test t.root_remote == "/s" && occursin("--licenses=scratch", t.directives)
            RE.region_delete!("mx_cpu"); RE.cluster_delete!("mx")
            @test RE.region_get("mx") === nothing
        end

        @testset "what preparing found is kept per host" begin
            @test isempty(RE.host_facts("perlmutter"))
            RE.host_facts_merge!("perlmutter", Dict("scratch" => "/pscratch/sd/k/me"))
            RE.host_facts_merge!("perlmutter", Dict("depot" => "/pscratch/sd/k/me/.julia-slate"))
            @test RE.host_facts("perlmutter")["scratch"] == "/pscratch/sd/k/me"
            @test RE.host_facts("perlmutter")["depot"] == "/pscratch/sd/k/me/.julia-slate"
            RE.host_facts_set!("perlmutter", Dict{String,Any}())
            @test isempty(RE.host_facts("perlmutter"))
        end

        @testset "the depot: the machine's setting, else what automatic resolved to" begin
            mk(depot) = RE.Machine("pm", "perlmutter", :slurm, "", "", depot, "")
            @test RE.machine_depot(mk("/data/jl")) == "/data/jl"
            @test RE.machine_depot(mk("~/.julia")) == "" && RE.machine_depot(mk("\$HOME/.julia/")) == ""
            @test RE.machine_depot(mk("")) == ""                    # automatic, before any prepare
            RE.host_facts_merge!("perlmutter", Dict("depot" => "/scratch/me/.julia-slate"))
            @test RE.machine_depot(mk("")) == "/scratch/me/.julia-slate"
            @test RE._auto_depot("/scratch/me/") == "/scratch/me/.julia-slate" && RE._auto_depot("") == ""
            RE.host_facts_set!("perlmutter", Dict{String,Any}())
        end

        @testset "every Julia on a machine starts in one shell" begin
            m = RE.Machine("pm", "perlmutter", :slurm, "", "", "/scratch/me/jd", "module load x")
            RE.host_facts_merge!("perlmutter", Dict("site_prologue" => "module unload cudatoolkit"))
            s = RE.machine_setup(m)
            @test occursin("\$HOME/.juliaup/bin", s)
            # The trailing `:` keeps the bundled stdlib depot; juliaup is kept looking at home.
            @test occursin("JULIA_DEPOT_PATH='/scratch/me/jd':", s) && occursin("JULIAUP_DEPOT_PATH=", s)
            # The site's fix first, then the user's prologue, and the command only if they succeed.
            @test endswith(s, "{ module unload cudatoolkit ; module load x ; } && ")
            # A machine that names its own julia puts that directory first instead of juliaup's.
            j = RE.machine_setup(RE.Machine("pm", "perlmutter", :slurm, "", "/opt/julia/bin/julia", "", ""))
            @test occursin("'/opt/julia/bin':", j) && !occursin("juliaup", j)
            RE.host_facts_set!("perlmutter", Dict{String,Any}())
            @test RE.machine_setup(RE.Machine("", "box", :exec, "", "", "", "")) ==
                  "export PATH=\"\$HOME/.juliaup/bin:\$PATH\"; "
            # It runs: a POSIX shell takes the whole prefix.
            mktempdir() do d
                out = read(`sh -c $(RE.machine_setup(RE.Machine("", "box", :exec, "", "", d, "true")) * "echo \$JULIA_DEPOT_PATH")`, String)
                @test strip(out) == d * ":"
            end
        end

        @testset "where a host records the environment it built" begin
            t0 = RE.RemoteTarget("h"; project = "~/.cache/kaimonslate/remote/nb-1")
            @test RE._env_stamp_path(t0) == ".cache/kaimonslate/remote/nb-1/.slate-env"
            t1 = RE.RemoteTarget("h"; project = "~/.cache/kaimonslate/remote/nb-1", depot = "/scratch/jd")
            @test RE._env_stamp_path(t1) == "/scratch/jd/slate/envs/nb-1"
            # A depot is part of the environment: a different one holds none of it.
            mktempdir() do env
                write(joinpath(env, "Project.toml"), "")
                @test RE._env_fingerprint(env, "i"; depot = "/a") != RE._env_fingerprint(env, "i"; depot = "/b")
                @test RE._env_fingerprint(env, "i") == RE._env_fingerprint(env, "i"; depot = "")
            end
        end

        @testset "batch tasks start in their machine's shell" begin
            S = RE.Sweep
            RE.cluster_set!(Dict("name" => "pmb", "host" => "perlmutter", "kind" => "slurm",
                                 "root_remote" => "/scratch/store", "depot" => "/scratch/jd"))
            d = only(filter(c -> c["name"] == "pmb", RE.clusters_resolved()))
            @test d["_depot"] == "/scratch/jd" && occursin("JULIA_DEPOT_PATH='/scratch/jd':", d["_setup"])
            @test RE.cluster_get_resolved("pmb")["_setup"] == d["_setup"]
            # The entry a cell receives is flat strings; the target it builds carries the shell.
            t = S.cluster(Dict(String(k) => string(v) for (k, v) in d))
            @test t.setup == d["_setup"] && t.depot == "/scratch/jd"
            # Copies keep it.
            t4 = S.with_chunk(t, 4)
            @test t4.chunk == 4 && t4.setup == t.setup && t4.depot == t.depot
            # Every task process runs it before julia, as a complete line.
            line = S._as_line(S._prefix(t))
            js = RE.BatchLauncher.JobSpec("n", ["c1"]; root = "/r", project = "/p", payload = "/x", prologue = line)
            cmd = RE.BatchLauncher.task_command(js, ["c1"])
            @test first(findfirst("JULIA_DEPOT_PATH", cmd)) < first(findfirst("julia --project=/p", cmd))
            @test S._as_line("a; { b ; } && ") == "a; { b ; } && true" && S._as_line("a; ") == "a"
            # A target built by hand, with no hub to resolve a machine, keeps its own prologue.
            h = S.ClusterTarget("h"; root_remote = "/s", prologue = "module load julia")
            @test S._prefix(h) == "{ module load julia ; } && "
        end

        @testset "a later wave builds from the project the run was written from" begin
            S = RE.Sweep
            proj = mktempdir()
            t = S.ClusterTarget("perlmutter"; root_remote = "/scratch/store", parent = "/hub/own/project")
            root = S.store_root(t); mkpath(root)
            run = repeat("ab", 32)
            S.BatchSweep.write_sweep!(root, run, String[]; parent = proj,
                                      resources = Dict("gpus" => "4", "walltime" => "00:30:00"))
            @test S._as_run(t, run).parent == proj
            # …asking for the nodes its cell asked for.
            @test S._as_run(t, run).resources.gpus == "4" && S._as_run(t, run).resources.walltime == "00:30:00"
            # A run that recorded nothing, or a project that is gone, leaves the target as it was.
            other = repeat("cd", 32)
            S.BatchSweep.write_sweep!(root, other, String[])
            @test S._as_run(t, other).parent == "/hub/own/project"
        end

        @testset "a sweep waits for its environment to pass a test task" begin
            S = RE.Sweep
            t = S.ClusterTarget("perlmutter"; root_remote = "/scratch/store", parent = mktempdir(),
                                setup = "export PATH=x; ", depot = "/scratch/jd", machine = "pmb")
            k = S.env_test_key(t)
            @test k == S.proj_key(t.parent) * "|/"
            @test S._untested(t)
            @test !S._untested(S._with(t; tested = "other@x," * k))
            # A target the hub did not resolve has nothing to compare against, and runs as it is.
            @test !S._untested(S._with(t; setup = ""))
            # What passed reaches a cell through the machine's entry; what failed does not, and nothing
            # does while the machine's site has changed since it was prepared.
            depot = RE.machine_depot(RE.machine_from(RE.cluster_get("pmb")))
            write(joinpath(t.parent, "Project.toml"), "")
            RE.record_env_test!("perlmutter", t.parent, "/"; by = "test task", status = "ok", depot)
            bad = mktempdir(); write(joinpath(bad, "Project.toml"), "")
            RE.record_env_test!("perlmutter", bad, "/"; by = "test task", status = "fail", depot)
            d = RE.cluster_get_resolved("pmb")
            @test d["_tested"] == k
            @test S.cluster(Dict(String(a) => string(b) for (a, b) in d)).tested == k
            @test RE.env_readiness("perlmutter", bad, "/"; depot) == "The last prepare of these packages failed."
            RE.host_facts_merge!("perlmutter", Dict{String,Any}("stale" => "changed since prepared: modules"))
            @test RE.cluster_get_resolved("pmb")["_tested"] == ""
            @test RE.env_readiness("perlmutter", t.parent, "/"; depot) ==
                  "On perlmutter, the loaded modules changed since the last prepare, so the packages need building again."
            RE.host_facts_set!("perlmutter", Dict{String,Any}())
        end

        @testset "a region's prepare tests the sweeps of the same project and node type" begin
            S = RE.Sweep
            proj = mktempdir(); write(joinpath(proj, "Project.toml"), "")
            RE.cluster_set!(Dict("name" => "tm", "host" => "tmhost", "kind" => "slurm", "root_remote" => "/s",
                                 "partition" => "gpu"))
            r = RE.region_get("tm")
            RE.record_env_test!(r.host, proj, RE.region_node_type(r); by = "tm", status = "ok", depot = RE.region_depot(r))
            # The region's own view of it, and the verdict its cells are held by.
            @test only(values(RE.readiness_view(r)["envs"]))["by"] == "tm"
            @test RE.env_readiness(r.host, proj, RE.region_node_type(r); depot = RE.region_depot(r)) == ""
            @test RE.env_readiness(r.host, proj, "cpu/") == "These packages were prepared on GPU nodes, and CPU nodes need their own build."
            t = S._with(S.cluster(Dict(String(k) => string(v) for (k, v) in RE.cluster_get_resolved("tm"))); parent = proj)
            @test !S._untested(t)                                       # same project, same nodes
            @test S._untested(S.with_resources(t, (; partition = "cpu")))   # other nodes: test again
            write(joinpath(proj, "Project.toml"), "[deps]\nX = \"1\"\n")
            t2 = S._with(S.cluster(Dict(String(k) => string(v) for (k, v) in RE.cluster_get_resolved("tm"))); parent = proj)
            @test S._untested(t2)                                       # its environment changed since
            @test RE.env_readiness(r.host, proj, RE.region_node_type(r); depot = RE.region_depot(r)) ==
                  "Since the last prepare, X was added."
            RE.host_facts_set!("tmhost", Dict{String,Any}())
            RE.region_delete!("tm"); RE.cluster_delete!("tm")
        end

        @testset "an environment with the same contents as a tested one is ready" begin
            tested, copy, other = mktempdir(), mktempdir(), mktempdir()
            for d in (tested, copy); write(joinpath(d, "Project.toml"), "[deps]\nX = \"1\"\n"); end
            write(joinpath(other, "Project.toml"), "[deps]\nY = \"1\"\n")
            RE.record_env_test!("twinhost", tested, "gpu/"; by = "prep", status = "ok", depot = "/d")
            @test RE.env_readiness("twinhost", copy, "gpu/"; depot = "/d") == ""
            new = "This notebook's packages haven't been installed on twinhost yet."
            @test RE.env_readiness("twinhost", other, "gpu/"; depot = "/d") == new
            @test RE.env_readiness("twinhost", copy, "cpu/"; depot = "/d") == new
            @test RE.env_readiness("twinhost", copy, "gpu/"; depot = "/other") == new
            # A project new to the machine, against what the same region last prepared there.
            @test RE.env_readiness("twinhost", other, "gpu/"; depot = "/d", by = "prep") ==
                  "Since the last prepare, Y was added, X was removed."
            # A record without its packages: that project's packages as they are now, none included.
            bare = mktempdir(); write(joinpath(bare, "Project.toml"), "")
            RE.record_env_test!("twinhost", bare, "cpu/"; by = "old", status = "ok", depot = "/d")
            fx = RE.host_facts("twinhost"); delete!(fx["envs"][RE.Sweep.env_key(bare, "cpu/")], "packages")
            RE.host_facts_merge!("twinhost", Dict{String,Any}("envs" => fx["envs"]))
            @test RE.env_readiness("twinhost", other, "cpu/"; depot = "/d", by = "old") == "Since the last prepare, Y was added."
            @test RE.package_change(Dict("A" => "1.0", "B" => "2.0"), Dict("A" => "1.1", "B" => "2.0", "C" => "", "D" => "")) ==
                  "C and D were added, A was updated"
            RE.host_facts_set!("twinhost", Dict{String,Any}())
        end

        @testset "an environment the host already built from the same contents is copied" begin
            home = mktempdir()
            run_script(t, fp) = read(addenv(`bash -c $(RE._twin_env_script(t, fp))`, "HOME" => home), String)
            a = joinpath(home, "envs", "a"); mkpath(a)
            write(joinpath(a, "Project.toml"), "P"); write(joinpath(a, "Manifest.toml"), "M")
            write(joinpath(a, RE._ENV_STAMP), "fp1")
            @test occursin("twin=", run_script(RE.RemoteTarget("h"; project = "~/envs/b"), "fp1"))
            @test read(joinpath(home, "envs", "b", "Manifest.toml"), String) == "M"
            @test !occursin("twin=", run_script(RE.RemoteTarget("h"; project = "~/envs/c"), "fp9"))
            @test !isdir(joinpath(home, "envs", "c"))
            # With a depot the stamp sits in it, named for the environment.
            dep = joinpath(home, "depot"); mkpath(joinpath(dep, "slate", "envs"))
            write(joinpath(dep, "slate", "envs", "a"), "fp2")
            @test occursin("twin=", run_script(RE.RemoteTarget("h"; project = "~/envs/d", depot = dep), "fp2"))
            @test isfile(joinpath(home, "envs", "d", "Project.toml"))
        end

        @testset "records from before one per machine are carried over" begin
            proj = mktempdir(); write(joinpath(proj, "Project.toml"), "")
            RE.cluster_set!(Dict("name" => "mg", "host" => "mghost", "kind" => "slurm", "root_remote" => "/s",
                                 "partition" => "gpu"))
            fp = RE._env_fingerprint(proj, RE._infra_spec(); depot = "")
            RE.region_set!("mg"; readiness = Dict{String,Any}("prepared_at" => time(), "envs" => Dict{String,Any}(
                RE._proj_key(proj) => Dict{String,Any}("project" => proj, "fingerprint" => fp, "status" => "ok"))))
            RE.host_facts_merge!("mghost", Dict{String,Any}("batch" => Dict{String,Any}(
                RE.Sweep.env_key(proj, "cpu/") => Dict{String,Any}("project" => proj, "status" => "ok"))))
            envs = RE.tested_envs("mghost")
            @test sort!(collect(keys(envs))) == sort!([RE.Sweep.env_key(proj, "gpu/"), RE.Sweep.env_key(proj, "cpu/")])
            @test envs[RE.Sweep.env_key(proj, "gpu/")]["by"] == "mg"
            @test !haskey(RE.host_facts("mghost"), "batch") && !haskey(RE.region_get("mg").readiness, "envs")
            @test RE.env_readiness("mghost", proj, "cpu/") == ""
            RE.host_facts_set!("mghost", Dict{String,Any}())
            RE.region_delete!("mg"); RE.cluster_delete!("mg")
        end

        @testset "the card says where each job stands" begin
            S = RE.Sweep
            # One squeue line per running element and per pending array range.
            @test RE.BatchLauncher._array_count("591_[1-8]") == 8 && RE.BatchLauncher._array_count("591_[1-3,7]") == 4
            @test RE.BatchLauncher._array_count("591_4") == 1
            h = S._queue_html(Dict("slate-x" => Dict{String,Any}("id" => "591", "pending" => 6, "running" => 2,
                "reason" => "Priority", "start" => "2026-10-02 01:12:00", "nodes" => "nid001", "elapsed" => "3:01", "left" => "26:59")))
            @test occursin("2 running on nid001", h) && occursin("6 queued — behind higher-priority jobs", h)
            @test occursin("est. start 2026-10-02 01:12:00", h) && occursin("job 591", h)
            @test S._queue_html(Dict{String,Dict{String,Any}}()) == ""
            @test S._state_label(:held) != "not started"
            @test S._prepare_key(S.ClusterTarget("h"; root_remote = "/s", machine = "pm")) == "batch_pm"
        end

        @testset "a test job runs its own command in the tasks' shell" begin
            js = RE.BatchLauncher.JobSpec("slate-test-x", ["test"]; root = "/r", project = "/e", payload = "",
                                          prologue = "export A=1", command = "julia --project=/e -e 1")
            cmd = RE.BatchLauncher.task_command(js, "\$CHUNK")
            @test endswith(cmd, "export A=1\njulia --project=/e -e 1")
            @test !occursin("SlateTask", cmd) && !occursin("PRECOMPILE_AUTO", cmd)   # it precompiles on purpose
        end

        @testset "a batch prepare that cannot sign in still leaves its report" begin
            withenv("KAIMONSLATE_DATA_HOME" => mktempdir()) do
                RE.cluster_set!(Dict("name" => "gone", "host" => "slate-test-unreachable.invalid",
                                     "kind" => "slurm", "root_remote" => "/s"))
                proj = mktempdir(); write(joinpath(proj, "Project.toml"), "")
                rec = RE.prepare_batch!("gone"; project = proj)
                @test rec["ok"] == false && !haskey(rec, "tested")
                @test occursin("Sign in", rec["steps"][1]["step"]) && rec["steps"][1]["status"] == "fail"
                reps = RE.prepare_reports(RE._batch_key("gone"))
                @test length(reps) == 1 && reps[1]["outcome"] == "failed"
                @test isempty(RE.tested_envs("slate-test-unreachable.invalid"))
            end
        end

        @testset "a shipped package's own [sources] point at the shipped copies" begin
            mktempdir() do d
                pkg = mkpath(joinpath(d, "devsrc", "Trade"))
                write(joinpath(pkg, "Project.toml"),
                      "name = \"Trade\"\n[sources]\nSEB = {path = \"../KaimonSlate.jl/lib/SEB\"}\nX = {url = \"https://x\"}\n")
                seb = joinpath(d, "devsrc", "SEB")
                code = RE.Sweep.devsources_script([pkg], [("Trade", pkg), ("SEB", seb)])
                include_string(Module(), code)
                t = RE.Sweep.TOML.parsefile(joinpath(pkg, "Project.toml"))
                @test t["sources"]["SEB"]["path"] == seb            # absolute paths stay as given
                @test t["sources"]["X"]["url"] == "https://x"         # a git source is left alone
            end
        end

        @testset "a start marks the machine stale when its host changed" begin
            RE.region_set!("gpu"; machine = "pm")
            RE.host_facts_merge!("perlmutter", Dict("stamps" => Dict("julia" => "julia version 1.12.7", "modules" => "a b")))
            t = RE.RemoteTarget("nid1"; region = "gpu")
            RE.readiness_check!(t; seen = Dict("julia" => "julia version 1.12.7", "modules" => "b a"))
            @test get(RE.host_facts("perlmutter"), "stale", "") == ""          # module order is not a change
            RE.readiness_check!(t; seen = Dict("julia" => "julia version 1.12.8", "modules" => "a b"))
            @test occursin("julia", RE.host_facts("perlmutter")["stale"])
            RE.host_facts_set!("perlmutter", Dict{String,Any}())
        end

        @testset "a sysimage build reports what it did" begin
            # The build script decides before it builds anything; run it against a fake home, with no
            # packages to resolve.
            r = RE.region_set!("simg"; host = "simghost"); r2 = RE.region_set!("simg2"; host = "simghost")
            mktempdir() do home
                proj = mkpath(joinpath(home, "env")); write(joinpath(proj, "Project.toml"), "")
                mkpath(joinpath(home, RE._REMOTE_WORKER)); write(joinpath(home, RE._REMOTE_WORKER, "worker.jl"), "")
                store = joinpath(home, ".julia", "slate-sysimg")
                @test RE.sysimage_store(r) == "~/.julia/slate-sysimg"                 # in the depot, shared
                run_script(rg = r; minfree = 0.0, force = false) = begin
                    f = joinpath(home, "build.jl")
                    write(f, RE._sysimage_build_script(rg, "env", Dict{String,String}[]; minfree_gb = minfree, force, infra = ()))
                    read(setenv(`$(Base.julia_cmd()) --startup-file=no $f`, merge(ENV, Dict("HOME" => home))), String)
                end
                # Too little memory: put off, with the reason. The image is named by what it holds.
                out = run_script(; minfree = 1e9)
                st, why, m = RE._sysimage_outcome(out, true, 3)
                @test st == "warn" && occursin("free", why)
                key, cpu = m["key"], m["cpu"]
                dir = joinpath(store, key)
                @test isfile(joinpath(dir, "env", "Project.toml")) && isempty(readdir(joinpath(store, ".resolve")))
                # A build of the same image already running elsewhere holds it; the lock names its region.
                write(joinpath(dir, ".building-" * cpu), "simg otherhost 1")
                st, why, _ = RE._sysimage_outcome(run_script(r2), true, 3)
                @test st == "warn" && occursin("built for simg", why) && occursin("otherhost", why)
                rm(joinpath(dir, ".building-" * cpu))
                # Built for this CPU: current for any region whose packages resolve the same.
                write(joinpath(dir, cpu * ".so"), "x")
                st, why, m = RE._sysimage_outcome(run_script(), true, 3)
                @test st == "ok" && occursin("already built", why) && m["result"] == "current" && m["key"] == key
                st, _, m2 = RE._sysimage_outcome(run_script(r2), true, 3)
                @test st == "ok" && m2["key"] == key && m2["image"] == m["image"]
            end
            RE.region_delete!("simg2")
            RE.region_delete!("simg")
            # What a finished build and a failed one read as, and the packages it holds.
            out = "[sysimg] key=abc cpu=x\n[sysimg] pkg u1 CUDA 5.1.0 t1\n[sysimg] result=built image=/h/k.so bytes=314572800 env=/h/env\n"
            st, why, m = RE._sysimage_outcome(out, true, 600)
            @test st == "ok" && occursin("300 MB", why) && m["image"] == "/h/k.so" && m["packages"]["u1"]["version"] == "5.1.0"
            @test RE._sysimage_outcome("[sysimg] result=failed reason=link error\n", true, 5)[1:2] == ("fail", "link error")
            @test RE._sysimage_outcome("ERROR: boom", false, 5)[1] == "fail"
        end

        @testset "a region's request for a node reads the same everywhere" begin
            r = RE.region_set!("plc"; host = "login", scheduler = :slurm, cpus = 32, mem = "0")
            A(st; id = "7", node = "", kw...) = RE.Sweep.Allocation("n", id, st, node, ""; kw...)
            p = RE.placement_note(r, A(:pending; start = "07:40", reason = "Priority"); waited = 240)
            @test p.state === :queued && p.text == "queued as job 7 for 4m · estimated start 07:40 · waiting on Priority"
            p = RE.placement_note(r, A(:none; id = "", said = "the queue requires 32 cores per GPU"))
            @test p.state === :refused && p.text == "SLURM refused the request: the queue requires 32 cores per GPU"
            @test RE.placement_note(r, A(:none; id = "")).text == "SLURM holds no job for the request"
            @test RE.placement_note(r, A(:unreachable)).state === :unreachable
            @test RE.placement_note(r, A(:running; node = "c1")).state === :granted
            @test RE.placement_note(r, A(:running)).state === :queued              # granted, node not named yet
            # More CPUs held than asked for: said, with the memory request that caused it.
            p = RE.placement_note(r, A(:pending; cpus = 128))
            @test p.grown && occursin("SLURM holds 128 CPUs, not the 32 asked for, for mem=0", p.text)
            @test RE.placement_note(r, A(:running; node = "c1", cpus = 128)).grown
            @test !RE.placement_note(r, A(:pending; cpus = 32)).grown
            # A queue that takes no batch jobs: the refusal points at salloc, unless that is the way already.
            batch = A(:none; id = "", said = "Cannot submit batch jobs to gpu_shared_interactive")
            @test endswith(RE.placement_note(r, batch).text, "· set the region to request with salloc")
            r = RE.region_set!("plc"; submit = "salloc")
            @test r.submit == "salloc" && !occursin("set the region", RE.placement_note(r, batch).text)
            RE.region_delete!("plc")
        end

        @testset "a worker boots from the region's image only when the versions agree" begin
            env = mktempdir()
            write(joinpath(env, "Project.toml"), "[deps]\nCUDA = \"u1\"\nMine = \"u2\"\n")
            write(joinpath(env, "Manifest.toml"), """
                [[deps.CUDA]]
                uuid = "u1"
                version = "5.1.0"
                git-tree-sha1 = "t51"
                [[deps.Mine]]
                uuid = "u2"
                path = "../Mine"
                version = "0.1.0"
                """)
            # What an image can hold: the registered packages, not the one from a path.
            @test [e["name"] for e in RE.sysimage_candidates(env)] == ["CUDA"]
            img(v, t) = Dict{String,Any}("packages" => Dict("u1" => Dict("name" => "CUDA", "version" => v, "tree" => t)))
            @test isempty(RE.sysimage_conflicts(img("5.1.0", "t51"), env))
            @test RE.sysimage_conflicts(img("5.0.0", "t50"), env) == ["CUDA (image 5.0.0, notebook 5.1.0)"]
            # An image of other packages entirely conflicts with nothing.
            @test isempty(RE.sysimage_conflicts(Dict{String,Any}("packages" => Dict("u9" => Dict("name" => "X"))), env))
            @test RE.sysimage_spec_key(Dict{String,String}[]) == ""
            # What the package dialog reads: nothing before a build; then the list the image was built
            # from (kept with it, or the region's own when only its hash was), and this notebook's clashes.
            list = [Dict{String,String}("name" => "CUDA", "uuid" => "u1", "version" => "", "path" => "")]
            r = RE.region_set!("stat"; host = "h", sysimage_pkgs = list)
            @test RE.sysimage_status(r, "") === nothing
            rec = merge(img("5.0.0", "t50"), Dict{String,Any}("bytes" => 2^30, "built_at" => 1.0,
                                                              "spec" => RE.sysimage_spec_key(r.sysimage_pkgs)))
            r = RE.region_set!("stat"; readiness = Dict{String,Any}("sysimage" => rec))
            st = RE.sysimage_status(r, "")            # no environment on the machine yet: no versions to compare
            @test st["listed"] == r.sysimage_pkgs && st["packages"] == 1 && isempty(st["conflicts"])
            rec["spec"] = "other"; r = RE.region_set!("stat"; readiness = Dict{String,Any}("sysimage" => rec))
            @test RE.sysimage_status(r, "")["listed"] === nothing
            # The versions compared are the machine's environment's, given as its Manifest's deps.
            there = Dict{String,Any}("CUDA" => [Dict{String,Any}("uuid" => "u1", "version" => "5.0.0", "git-tree-sha1" => "t50")])
            @test isempty(RE.sysimage_conflicts(rec, there)) && !isempty(RE.sysimage_conflicts(rec, env))
            RE.region_delete!("stat")
        end
    end
end
