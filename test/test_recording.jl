# Presentation recording: the deck streams a capture to the hub, which owns every path. Pinned here:
# chunks land in order in a file beside the notebook, the chapters and timings are written next to
# it, an id is only good for the notebook that opened it, and app mode never serves these routes.
using ReTest
using KaimonSlate
import JSON
const NS = KaimonSlate.NotebookServer

@testset "recording: start, chunks, finish" begin
    dir = mktempdir()
    nbpath = joinpath(dir, "talk notes.jl")
    write(nbpath, "#%% md id=a\n# Talk\n")
    s = NS.recording_start!("nbA", nbpath; mime = "video/mp4;codecs=avc1")
    @test occursin(r"^[0-9a-f]{32}$", s["id"])
    @test s["ext"] == "mp4" && startswith(s["file"], joinpath("recordings", "talk_notes-"))
    media = joinpath(dir, s["file"])
    @test isfile(media) && filesize(media) == 0

    @test NS.recording_chunk!("nbA", s["id"], UInt8[1, 2, 3])
    @test NS.recording_chunk!("nbA", s["id"], UInt8[4, 5])
    @test read(media) == UInt8[1, 2, 3, 4, 5]

    vtt = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:02.000\n1. Talk\n\n"
    out = NS.recording_finish!("nbA", s["id"]; vtt, timings = Dict("duration_ms" => 2000, "marks" => []))
    stem = splitext(media)[1]
    @test out["bytes"] == 5 && !haskey(out, "converting")      # mp4: nothing to convert
    @test read(stem * ".vtt", String) == vtt
    @test JSON.parse(read(stem * ".json", String))["timings"]["duration_ms"] == 2000
    # Finished means gone: no more appends, no second finish.
    @test !NS.recording_chunk!("nbA", s["id"], UInt8[9])
    @test NS.recording_finish!("nbA", s["id"]) === nothing

    # A second recording in the same second gets its own file.
    a = NS.recording_start!("nbA", nbpath; mime = "video/webm")
    b = NS.recording_start!("nbA", nbpath; mime = "video/webm")
    @test a["ext"] == "webm" && a["file"] != b["file"]
end

@testset "recording: ids are checked" begin
    dir = mktempdir()
    nbpath = joinpath(dir, "nb.jl"); write(nbpath, "")
    s = NS.recording_start!("nbA", nbpath)
    @test !NS.recording_chunk!("nbB", s["id"], UInt8[1])       # another notebook's page
    @test !NS.recording_chunk!("nbA", "../../etc/passwd", UInt8[1])
    @test !NS.recording_chunk!("nbA", uppercase(s["id"]), UInt8[1])
    @test !NS.recording_chunk!("nbA", "0"^32, UInt8[1])         # well-formed, never issued
    @test NS.recording_finish!("nbB", s["id"]) === nothing
    @test filesize(joinpath(dir, s["file"])) == 0
end

@testset "recording: not served in app mode" begin
    for p in ("/api/x/recording/start", "/api/x/recording/" * "a"^32 * "/chunk",
              "/api/x/recording/" * "a"^32 * "/finish")
        @test !NS._app_route_allowed("POST", p)
        @test !NS._app_route_allowed("POST", p; workbook = true)
    end
end
