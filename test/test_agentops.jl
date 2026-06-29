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

        @testset "add_cell with an explicit id; rename_cell" begin
            r = NS.agent_add_cell!(nb, "1 + 1"; id = "my_sum")
            @test occursin("id=my_sum", r)
            @test NS._cell_exists(nb, "my_sum")
            # a taken id errors (no cell added)
            n0 = length(nb.report.cells)
            r2 = NS.agent_add_cell!(nb, "2"; id = "my_sum")
            @test occursin("already in use", r2) && length(nb.report.cells) == n0
            # non-id characters fold to underscore
            r3 = NS.agent_add_cell!(nb, "3"; id = "a b!c")
            @test occursin("id=a_b_c", r3) && NS._cell_exists(nb, "a_b_c")
            # rename: success, collision, missing
            @test occursin("renamed my_sum → total", NS.agent_rename_cell!(nb, "my_sum", "total"))
            @test NS._cell_exists(nb, "total") && !NS._cell_exists(nb, "my_sum")
            @test occursin("already in use", NS.agent_rename_cell!(nb, "total", "a_b_c"))
            @test occursin("no cell", NS.agent_rename_cell!(nb, "ghost", "x"))
        end

        @testset "read modes: outline / cells / delta_since" begin
            NS.agent_add_cell!(nb, "# " * repeat("Q", 4000) * "\n21 * 2"; id = "bigcell")  # large SOURCE, small result
            out = NS.notebook_digest(nb)                       # default → compact OUTLINE
            tok = match(r"state=(\w+)", out)[1]
            @test occursin("OUTLINE", out) && occursin("defines:", out)
            @test occursin("id=bigcell", out)
            @test !occursin("QQQQQ", out)                      # the big SOURCE is NOT dumped in the outline
            # cells="…" → FULL content of just those cells
            full = NS.notebook_digest(nb; cells = "bigcell")
            @test occursin("QQQQQ", full) && occursin("### id=bigcell", full)
            # delta_since: no change → "(no changes)", then an add shows only it
            @test occursin("no changes", NS.notebook_digest(nb; delta_since = tok))
            NS.agent_add_cell!(nb, "7 + 7"; id = "delta_probe")
            d = NS.notebook_digest(nb; delta_since = tok)
            @test occursin("[ADDED]", d) && occursin("id=delta_probe", d) && occursin("14", d)
            @test !occursin("id=bigcell", d)                   # unchanged cell omitted from the delta
            # an unknown token falls back to the outline
            @test occursin("full outline", NS.notebook_digest(nb; delta_since = "deadbeef"))
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
