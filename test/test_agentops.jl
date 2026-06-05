# Agent cell operations — the incremental-build tool surface. Runs against a live
# hub (so the file-watcher is active) to guard the watcher-vs-rapid-write race that
# was deleting just-added cells.
using Test
using KaimonSlate
const NS = KaimonSlate.NotebookServer

@testset "agent cell ops" begin
    NS.SlateHistory._ROOT[] = mktempdir()
    hub = NS.start_hub(; port = 8859)
    try
        nbp = tempname() * ".jl"
        write(nbp, "#%% md id=intro\n# T\n")
        nb = hub.notebooks[NS.open_notebook!(hub, nbp)]   # WITH file watcher

        @testset "add + run returns results" begin
            @test occursin("42", NS.agent_add_cell!(nb, "x = 6 * 7"))
            @test occursin("142", NS.agent_add_cell!(nb, "x + 100"))      # reads x reactively
            r = NS.agent_add_cell!(nb, "sqrt(-1.0)")
            @test occursin("ERROR", r) && occursin("DomainError", r)      # errors surface
            @test occursin("20", NS.agent_add_cell!(nb, "sum([5,5,10])"))
        end

        @testset "no cells lost to the watcher race" begin
            @test length(nb.report.cells) == 5                            # intro + 4
        end

        @testset "edit + reactive recompute" begin
            cid_x = match(r"id=(\w+)", NS.agent_add_cell!(nb, "y = 2"))[1]
            cid_d = match(r"id=(\w+)", NS.agent_add_cell!(nb, "y * 10"))[1]
            @test occursin("20", NS._result_of(nb, cid_d))
            NS.agent_edit_cell!(nb, cid_x, "y = 5")                        # downstream restales
            sleep(0.2)
            @test occursin("50", NS.agent_run!(nb, cid_d))                 # y*10 → 50
        end

        @testset "read digest + delete" begin
            dig = NS.notebook_digest(nb)
            @test occursin("id=intro", dig) && occursin("[code,", dig)
            n0 = length(nb.report.cells)
            cid = match(r"id=(\w+)", NS.agent_add_cell!(nb, "99"))[1]
            @test length(nb.report.cells) == n0 + 1
            NS.agent_delete_cell!(nb, cid)
            @test length(nb.report.cells) == n0
        end

        @testset "find_live by id and path" begin
            @test NS.find_live(hub, nb.id) === nb
            @test NS.find_live(hub, nbp) === nb
            @test NS.find_live(hub, "nope") === nothing
        end
    finally
        NS.stop_hub(hub)
    end
end
