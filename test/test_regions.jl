# Region data-root wiring: the spec grammar that carries a region's pinned data root
# (src/server.jl `_parse_region_spec`) and the two things that stamp it onto a worker —
# the `RemoteTarget.datadir` field and the cold-spawn boot script that exports it as
# `KAIMONSLATE_DATADIR` (src/remote.jl). Pure/local — no ssh, no workers. The receiving
# half (`datadir()` / `__slate_materialize_datadir` resolving the same env) lives in the
# worker process, exercised by the manual remote round-trip, not here.
using ReTest
using KaimonSlate

const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

@testset "region data-root wiring" begin

    @testset "_parse_region_spec: positional parts + named root= token" begin
        # backward-compatible positional forms (host[,transport[,port[,stream]]])
        @test NS._parse_region_spec("gpubox") ==
              (host = "gpubox", transport = "", port = "", stream = "", root = "")
        @test NS._parse_region_spec("gpubox,direct") ==
              (host = "gpubox", transport = "direct", port = "", stream = "", root = "")
        @test NS._parse_region_spec("gpubox,direct,9100,9101") ==
              (host = "gpubox", transport = "direct", port = "9100", stream = "9101", root = "")
        # root= is pulled out by name — trailing, mid-spec, and whitespace-tolerant
        @test NS._parse_region_spec("gpubox,direct,root=/scratch/flights") ==
              (host = "gpubox", transport = "direct", port = "", stream = "", root = "/scratch/flights")
        @test NS._parse_region_spec("gpubox,root=/mnt/x,tunnel") ==
              (host = "gpubox", transport = "tunnel", port = "", stream = "", root = "/mnt/x")
        @test NS._parse_region_spec(" gpubox , tunnel , root=/mnt/x ") ==
              (host = "gpubox", transport = "tunnel", port = "", stream = "", root = "/mnt/x")
        @test NS._parse_region_spec("gpubox,direct,9100,9101,root=/d") ==
              (host = "gpubox", transport = "direct", port = "9100", stream = "9101", root = "/d")
        # a named token does NOT reserve a positional slot — with root pulled, bare parts collapse in
        # order, so ports need an explicit transport ahead of them (this is the documented convention).
        @test NS._parse_region_spec("gpubox,root=/d,9100,9101") ==
              (host = "gpubox", transport = "9100", port = "9101", stream = "", root = "/d")
        # unknown key=value tokens are ignored (forward-compatible with a later `shared=` etc.)
        @test NS._parse_region_spec("gpubox,shared=1,root=/d").root == "/d"
        @test NS._parse_region_spec("gpubox,shared=1,root=/d").transport == ""
        # empty spec → all empty (the caller guards this before parsing)
        @test NS._parse_region_spec("") ==
              (host = "", transport = "", port = "", stream = "", root = "")
    end

    @testset "RemoteTarget.datadir: field default + kwarg round-trip" begin
        @test RE.RemoteTarget("h").datadir == ""                       # backward-compatible default
        @test RE.RemoteTarget("h"; datadir = "/scratch/flights").datadir == "/scratch/flights"
    end

    @testset "_remote_worker_script: exports KAIMONSLATE_DATADIR iff a root is pinned" begin
        t0 = RE.RemoteTarget("h"; transport = :tunnel)
        t1 = RE.RemoteTarget("h"; transport = :tunnel, datadir = "/scratch/flights")
        s0 = RE._remote_worker_script(t0, 9100, 9101, "/home/me/proj", "PUB")
        s1 = RE._remote_worker_script(t1, 9100, 9101, "/home/me/proj", "PUB")
        @test !occursin("KAIMONSLATE_DATADIR", s0)                     # no root → no env line at all
        @test occursin("ENV[\"KAIMONSLATE_DATADIR\"] = raw\"/scratch/flights\"", s1)
        @test startswith(strip(s1), "ENV[\"KAIMONSLATE_DATADIR\"]")    # set BEFORE the worker boots
        @test Meta.parseall(s1) isa Expr                               # the generated script is valid Julia
    end

end
