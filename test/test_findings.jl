# Findings: where they live, and how they travel.
#
# `test_specialist.jl` covers the protocol — who may record one, what the checker is given, what the
# orchestrator does with it. This covers the part that outlives the session: a conclusion is only
# worth recording if it is still there next time, and the whole point of the "already established"
# briefing is that a later investigation does not start from nothing.
#
# Both halves have failed in exactly the way a test catches and a live session does not. Findings
# were in memory only, so every hub restart silently threw away the notebook's accumulated
# knowledge while the recall code kept running and finding nothing.

using ReTest
include(joinpath(@__DIR__, "freeport.jl"))
using Sockets
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine


# A hub, a notebook, and a clean slate of module-level caches. Each block gets its own history root
# so one test's store can never be read by another's.
function _with_notebook(f, source::AbstractString; path::AbstractString = "")
    NS.SlateHistory._ROOT[] = mktempdir()
    p = isempty(path) ? tempname() * ".jl" : path
    isfile(p) || write(p, source)
    hub = NS.start_hub(; port = freeport())
    try
        # `autorun=false`: none of this needs the cells to have RUN. The dependency graph these
        # tests lean on is derived when the file is parsed, and booting a worker per block is most
        # of the suite's runtime for nothing.
        nb = hub.notebooks[NS.open_notebook!(hub, p; autorun = false)]
        return f(nb, p)
    finally
        try; NS.stop_hub(hub); catch; end
    end
end

# What a process restart does, without the process.
function _forget_everything!()
    empty!(NS._FINDINGS); empty!(NS._FINDINGS_LOADED); NS._FINDING_SEQ[] = 0
end

const _CELLS = """
              #%% code id=source
              raw = [1.0, 2.0, -999.0, 4.0]

              #%% code id=sink
              total = sum(raw)
              """

@testset "findings" begin

    @testset "survive a restart" begin
        # The reason this exists: they used to live in a module-level Dict and nowhere else, so the
        # notebook's knowledge lasted exactly as long as the hub did.
        root = mktempdir()
        p = tempname() * ".jl"; write(p, _CELLS)
        NS.SlateHistory._ROOT[] = root
        hub = NS.start_hub(; port = freeport())
        id = ""
        try
            nb = hub.notebooks[NS.open_notebook!(hub, p; autorun = false)]
            f = NS.record_finding!(nb, "debugger", "agent:x"; cell = "sink",
                                   claim = "the sum is wrong", evidence = "total == -992")
            NS.set_verdict!(nb, f.id, "confirmed", "read it myself")
            NS.set_decision!(nb, f.id, "go — and rename it")
            id = f.id
        finally
            try; NS.stop_hub(hub); catch; end
        end

        _forget_everything!()
        NS.SlateHistory._ROOT[] = root          # same machine, same store
        hub2 = NS.start_hub(; port = freeport())
        try
            nb = hub2.notebooks[NS.open_notebook!(hub2, p; autorun = false)]
            fs = NS.findings_json(nb)
            @test length(fs) == 1
            g = only(fs)
            @test g["id"] == id
            @test g["cell"] == "sink"
            @test g["verdict"] == "confirmed"
            @test g["decision"] == "go — and rename it"     # the person's own words, kept

            # Ids come from a counter. Reloading has to move it past what is already on disk, or the
            # next finding overwrites one of these wherever they are keyed by id.
            f2 = NS.record_finding!(nb, "debugger", "agent:y"; cell = "sink", claim = "another look")
            @test f2.id != id
            @test length(NS.findings_json(nb)) == 2
        finally
            try; NS.stop_hub(hub2); catch; end
        end
    end

    @testset "stay out of the file unless asked" begin
        _forget_everything!()
        _with_notebook(_CELLS) do nb, _
            NS.record_finding!(nb, "debugger", "agent:x"; cell = "sink", claim = "wrong",
                               evidence = "first line\nsecond line")
            @test !occursin("Slate.findings", RE.serialize_report(nb.report))

            NS.set_notebook_config!(nb, "sharefindings", true)
            NS.stage_findings!(nb)
            txt = RE.serialize_report(nb.report)
            @test occursin("Slate.findings", txt)
            # The footer is comments, so the document still runs as plain Julia — which is the whole
            # constraint on the notebook format.
            @test (Meta.parseall(txt); true)
            # One record per line: JSON escapes its own newlines, so an evidence paragraph cannot
            # break out of its comment and turn the rest of the block into code.
            @test !occursin("first line\nsecond line", txt)

            # Turning it off takes them back out rather than freezing the last set written.
            NS.set_notebook_config!(nb, "sharefindings", false)
            NS.stage_findings!(nb)
            @test !occursin("Slate.findings", RE.serialize_report(nb.report))
        end
    end

    @testset "travel with the document" begin
        # Someone else's machine: their own store, the file arriving under a different path.
        _forget_everything!()
        sent = _with_notebook(_CELLS) do nb, _
            f = NS.record_finding!(nb, "debugger", "agent:x"; cell = "sink",
                                   claim = "the sum is wrong",
                                   evidence = "line one\nline two")
            NS.set_verdict!(nb, f.id, "confirmed", "checked against the cell")
            NS.set_decision!(nb, f.id, "go")
            NS.set_notebook_config!(nb, "sharefindings", true)
            NS.stage_findings!(nb)
            RE.serialize_report(nb.report)
        end
        @test occursin("Slate.findings", sent)

        _forget_everything!()
        far = tempname() * ".jl"; write(far, sent)
        _with_notebook(""; path = far) do nb, _
            fs = NS.findings_json(nb)
            @test length(fs) == 1
            g = only(fs)
            @test g["cell"] == "sink"
            @test g["verdict"] == "confirmed"
            @test g["decision"] == "go"
            @test occursin("line two", g["evidence"])      # the paragraph came through whole
            # And it reaches the next investigation, which is the only reason to carry it.
            @test occursin("ALREADY ESTABLISHED", NS.debug_briefing(nb, "sink", ""))
        end
    end

    @testset "an incoming copy never overwrites a local decision" begin
        # The same document, investigated on both machines. What arrives is what THEY established;
        # a record already here carries this machine's decision and is the newer word on it.
        _forget_everything!()
        _with_notebook(_CELLS) do nb, _
            f = NS.record_finding!(nb, "debugger", "agent:mine"; cell = "sink", claim = "mine")
            NS.set_decision!(nb, f.id, "no — deliberately left alone")

            nb.report.meta["findings_incoming"] = Any[
                Dict{String,Any}("id" => f.id, "cell" => "sink", "claim" => "theirs",
                                 "decision" => "go"),                      # same id: must be ignored
                Dict{String,Any}("id" => "find99", "cell" => "source", "claim" => "a new one"),
            ]
            @test NS.adopt_findings!(nb) == 1                              # only the unseen one
            @test !haskey(nb.report.meta, "findings_incoming")             # consumed, not left behind

            fs = NS.findings_json(nb)
            @test length(fs) == 2
            mine = only(x for x in fs if x["id"] == f.id)
            @test mine["claim"] == "mine"
            @test mine["decision"] == "no — deliberately left alone"
            @test any(x -> x["cell"] == "source", fs)
        end
    end

    @testset "the briefing shows only what bears on the cell" begin
        _forget_everything!()
        _with_notebook(_CELLS) do nb, _
            NS.record_finding!(nb, "debugger", "agent:x"; cell = "source", claim = "about an input")
            # `sink` reads `raw` from `source`, so a finding there is part of its story.
            @test occursin("about an input", NS.debug_briefing(nb, "sink", ""))
            # `source` has no inputs, so nothing downstream of it is its business.
            NS.record_finding!(nb, "debugger", "agent:x"; cell = "sink", claim = "about the output")
            @test !occursin("about the output", NS.debug_briefing(nb, "source", ""))
        end
    end
end
