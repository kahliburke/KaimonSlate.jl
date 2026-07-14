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

end
