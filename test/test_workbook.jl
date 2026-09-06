# Workbook mode: an app whose `workbook`-tagged cells the reader may rewrite (a course notebook
# whose exercises a student fills in). What's pinned here is what fails SILENTLY — a route that
# quietly becomes reachable for every cell instead of the tagged ones, a posture that a document
# could grant itself, a Reset button that can't find the original, a "restart to apply" hint that
# lies in either direction. The visible half (the boxed editor, the Run/Reset bar, the scratchpad
# panel) is CSS/JS and is eyeballed.
using ReTest
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

mkwb(src; id = "wb", path = "/tmp/wb.jl") = NS.LiveNotebook(id, path,
    RE.parse_report(src; title = id), RE.InProcessKernel(), 1, String[], String[],
    ReentrantLock(), Channel{String}[], ReentrantLock(), "", false, Dict{String,String}())

# One exercise the reader owns, one ordinary cell they don't, one markdown cell wearing the tag.
const _WB_SRC = """
#%% code id=ex1 workbook
function inner(u, v)
    missing
end

#%% code id=plain
const K = 3

#%% md id=md1 workbook
text

#%% code id=try1 workbook trace
inner([1.0], [2.0])
"""

@testset "workbook route allowlist" begin
    wb(m, t) = NS._app_route_allowed(m, t; workbook = true)
    app(m, t) = NS._app_route_allowed(m, t)
    split2(r) = (split(r)[1], split(r)[2])

    @testset "the added routes, and only in a workbook" begin
        # Everything a reader needs that a plain app withholds: rewrite a cell, run what that made
        # stale, complete and look up docs while typing, the scratchpad, and the Reset source.
        added = ["POST /api/demo/cell/ex1", "POST /api/demo/run", "POST /api/demo/complete",
                 "POST /api/demo/scratch-eval", "POST /api/demo/scratch/clear",
                 "GET /api/demo/workbook-stub/ex1",
                 "GET /api/demo/help", "GET /api/demo/docsearch"]
        # Aggregated: a @test per row in a loop reports a count and names nothing when one fails.
        @test isempty([r for r in added if !wb(split2(r)...)])
        # The same routes on a hub that is merely an app must stay refused — the capability comes
        # from how the process was started, never from the document.
        @test isempty([r for r in added if app(split2(r)...)])
    end

    @testset "a workbook widens nothing else" begin
        # The rest of the authoring API is the reason app mode exists. A workbook opens a handful of
        # named routes; if any of these ever join them, that opening has become a doorway.
        refused = ["POST /api/demo/publish", "POST /api/demo/cell-add",
                   "POST /api/demo/cell-delete/x", "POST /api/demo/cells-paste",
                   "POST /api/demo/tags/x", "POST /api/demo/file-op", "POST /api/demo/restart",
                   "POST /api/demo/chat", "POST /api/demo/export-app", "POST /api/demo/packages",
                   "GET /api/notebooks", "GET /api/demo/history", "GET /api/demo/files"]
        @test isempty([r for r in refused if wb(split2(r)...)])
    end

    @testset "the shape of a path can't be talked around" begin
        # Matched on the path alone, so a query string can't smuggle an allowed suffix in.
        @test !wb("POST", "/api/demo/publish?next=/run")
        # `/cell/{cid}` is ONE segment: a nested path is a different route and stays refused.
        @test !wb("POST", "/api/demo/cell/a/b")
        # Methods outside GET/HEAD/POST are refused outright, workbook or not.
        @test !wb("DELETE", "/api/demo/cell/ex1")
        @test !wb("PUT", "/api/demo/run")
    end
end

@testset "authority is per cell, not per route" begin
    nb = mkwb(_WB_SRC)
    # Reaching `/api/{id}/cell/{cid}` is necessary and never sufficient: the handler asks this.
    @test NS._workbook_cell_allowed(nb, "ex1")
    @test NS._workbook_cell_allowed(nb, "try1")                 # a second tag (`trace`) changes nothing
    bad = ["plain",   # a code cell the author did not mark
           "md1",     # markdown wearing the tag: there is no code to run
           "nope",    # an id that isn't in the document at all
           ""]        # and the empty id, which a hand-built request can send
    @test isempty([c for c in bad if NS._workbook_cell_allowed(nb, c)])
end

@testset "a document cannot grant itself the posture" begin
    # `workbook` without `app` would mean the authoring API is open AND the flag claims a lockdown.
    # Refused at construction rather than quietly downgraded, so a misconfigured launcher is loud.
    @test_throws ArgumentError NS.start_hub(; port = 0, workbook = true)
end

@testset "the original a Reset restores" begin
    original = replace(_WB_SRC, "    missing\n" => "    sum(u .* v)\n")   # stands in for the author's stub
    mktempdir() do d
        nbfile = joinpath(d, "wb.jl")
        write(nbfile, _WB_SRC)
        sibling = joinpath(d, ".wb.jl.original")
        write(sibling, original)
        nb = mkwb(_WB_SRC; path = nbfile)

        # Beside the notebook is the fallback, for a workbook served straight out of a folder.
        @test NS._workbook_stub_path(nb) == sibling
        want = RE.parse_report(original).cells[findfirst(c -> c.id == "ex1",
                                                         RE.parse_report(original).cells)].source
        @test NS._workbook_stub_source(nb, "ex1") == want
        @test NS._workbook_stub_source(nb, "nope") === nothing      # unknown id → no guess

        # An exported bundle EXPANDS: the copy ships beside the launcher and the notebook ends up
        # inside `.app/`, so the two are never siblings and the launcher names the file outright.
        elsewhere = joinpath(d, "shipped.original")
        write(elsewhere, original)
        withenv("SLATE_WORKBOOK_ORIGINAL" => elsewhere) do
            @test NS._workbook_stub_path(nb) == elsewhere
            @test NS._workbook_stub_source(nb, "ex1") == want
        end

        # No copy anywhere → Reset says so rather than restoring something invented.
        rm(sibling)
        @test NS._workbook_stub_source(nb, "ex1") === nothing
    end
end

@testset "the exported launcher carries the posture" begin
    # The generated `run.jl` is the only place the exported app's posture is written down, and it is
    # plain text at export time — so this is what makes the checkbox mean anything.
    on = NS._run_script(""; bundle_name = "wb.jl", app = true, workbook = true)
    off = NS._run_script(""; bundle_name = "wb.jl", app = true, workbook = false)
    @test occursin("workbook = true", on)
    @test occursin("SLATE_WORKBOOK_ORIGINAL", on)     # …and points Reset at the shipped copy
    @test !occursin("workbook = true", off)
    @test !occursin("SLATE_WORKBOOK_ORIGINAL", off)
end

@testset "revise status tells the truth in both directions" begin
    # The health panel demotes "restart to apply" to an informational row when Revise has caught up.
    # Both mistakes are bad: claiming coverage strands the reader on stale code, and never claiming
    # it puts the old nag back on every edit. Saved and restored so the suite leaves no residue.
    saved = (NS._REVISE_MOD[], NS._REVISE_LAST[], NS._REVISE_ERR[], NS._REVISE_PENDING[])
    try
        NS._REVISE_MOD[] = nothing
        NS._REVISE_ERR[] = ""; NS._REVISE_PENDING[] = false; NS._REVISE_LAST[] = time()
        @test !NS.revise_covers_source()                 # no Revise → never covered

        NS._REVISE_MOD[] = Base                          # any non-nothing stands for "loaded"
        NS._REVISE_LAST[] = time() + 60                  # a pass newer than every source file
        @test NS.revise_covers_source()

        NS._REVISE_LAST[] = 1.0                          # a pass older than the source
        @test !NS.revise_covers_source()

        NS._REVISE_LAST[] = time() + 60
        NS._REVISE_PENDING[] = true                      # changes seen but not yet applied
        @test !NS.revise_covers_source()

        NS._REVISE_PENDING[] = false
        NS._REVISE_ERR[] = "boom"                        # a failed pass is not coverage
        @test !NS.revise_covers_source()

        NS._REVISE_ERR[] = ""
        st = NS.revise_status()
        @test sort(collect(keys(st))) == ["active", "covers", "error", "errorAt", "last"]
    finally
        NS._REVISE_MOD[], NS._REVISE_LAST[], NS._REVISE_ERR[], NS._REVISE_PENDING[] = saved
    end
end

@testset "the tag round-trips through the .jl" begin
    # The posture reads `workbook` off the parsed cell, so a tag that didn't survive a save would
    # silently un-assign every exercise in the document.
    nb = mkwb(_WB_SRC)
    out = RE.serialize_report(nb.report)
    @test occursin("id=ex1 workbook", out) || occursin("id=ex1 workbook", replace(out, "  " => " "))
    reparsed = RE.parse_report(out)
    tagged = [c.id for c in reparsed.cells if :workbook in c.flags]
    @test sort(tagged) == ["ex1", "md1", "try1"]
    # …and `trace` is still there beside it: setting one tag must not drop another.
    t1 = reparsed.cells[findfirst(c -> c.id == "try1", reparsed.cells)]
    @test :trace in t1.flags
end
