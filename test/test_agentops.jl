# Agent cell operations — the incremental-build tool surface. Runs against a live
# hub (so the file-watcher is active) to guard the watcher-vs-rapid-write race that
# was deleting just-added cells.
using ReTest
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

        @testset "slate API reference + search records (SSOT)" begin
            full = NS.slate_api_reference()
            @test occursin("echart", full) && occursin("@bind", full) && occursin("animate", full)
            @test occursin("playhead", full) && occursin("nocache", full)   # newest helpers present
            one = NS.slate_api_reference("animate")
            @test occursin("animate", one) && !occursin("## Charts", one)     # filtered detail, not full ref
            @test occursin("No Slate API entry", NS.slate_api_reference("zzzznope"))
            # The echart DSL must be documented in full AND teach the non-obvious bits — the three forms,
            # the top-level-component routing (log axis, dataZoom, visualMap), and per-kind data shapes —
            # so `slate.api`/`search_docs` surface them to agents instead of leaving them to grep source.
            ec = NS.slate_api_reference("echart")
            @test occursin("Express", ec) && occursin("Composable", ec) && occursin("Raw", ec)
            @test occursin("type=:log", ec) || occursin("type = :log", ec)   # the log-axis pattern
            @test occursin("dataZoom", ec) && occursin("visualMap", ec)      # components documented
            @test occursin("candlestick", ec) && occursin("boxplot", ec)     # per-kind data shapes
            @test occursin("type=:log", NS.slate_api_reference("log axis")) ||    # searchable by concept
                  occursin("echart", NS.slate_api_reference("log axis"))
            recs = NS.slate_api_records()
            @test !isempty(recs) && all(r -> r["module"] == "Slate", recs)
            @test any(r -> r["name"] == "@bind", recs) && any(r -> r["name"] == "animate", recs)
            @test !isempty(NS.slate_api_version())
            # Drill-down / "Related" resolution: a Slate helper resolves from the registry (real doc),
            # NOT a live binding (which for a DSL constructor/macro yields "No documentation found").
            @test NS.slate_api_entry("Checkbox") !== nothing && NS.slate_api_entry("nope_zzz") === nothing
            @test NS.slate_api_entry("bind") === NS.slate_api_entry("@bind")   # tolerant of a leading @
            h = NS.help_lookup(nb, "Checkbox")
            @test h["module"] == "Slate" && h["kind"] == "slate"
            @test !isempty(h["docHtml"]) && occursin("checkbox", lowercase(h["doc"]))
            hb = NS.help_lookup(nb, "@bind")
            @test hb["module"] == "Slate" && occursin("Slider", hb["doc"])
            # Curated ECharts option docs: indexed under module "ECharts" and resolvable by path, so a
            # chart question surfaces the option AND the Slate DSL form that reaches it.
            erecs = NS.echarts_doc_records()
            @test !isempty(erecs) && all(r -> r["module"] == "ECharts", erecs)
            @test any(r -> r["name"] == "yAxis.type", erecs)
            @test "ECharts" in NS._UNIVERSAL_MODULES        # in scope so scoped search surfaces it
            he = NS.help_lookup(nb, "yAxis.type")
            @test he["module"] == "ECharts" && he["kind"] == "echarts"
            @test occursin("log", lowercase(he["doc"])) && occursin("echart(", he["doc"])   # carries the DSL mapping
            @test !isempty(NS.echarts_docs_version()) && NS.echarts_doc_entry("nope.zzz") === nothing
        end

        @testset "outline shows a cell's tags" begin
            cid = match(r"id=(\w+)", NS.agent_add_cell!(nb, "1 + 1"))[1]
            NS.set_cell_tags!(nb, cid, ["nocache", "wip"])
            out = NS.notebook_digest(nb)
            @test occursin("{nocache wip}", out) || occursin("{wip nocache}", out)
        end

        @testset "table cells render as text for agents" begin
            r = NS.agent_add_cell!(nb, "slate_table([(sym=\"AAPL\", px=42.0), (sym=\"MSFT\", px=13.5)])")
            @test occursin("sym", r) && occursin("px", r)         # header
            @test occursin("AAPL", r) && occursin("42.0", r)      # data cells, not just "[rendered: table]"
            @test !occursin("[rendered: table]", r)
        end

        @testset "add_cell / edit_cell manage tags" begin
            _flags(id) = nb.report.cells[NS._index_of(nb.report.cells, id)].flags
            # add_cell applies tags (comma/space-separated) to the fresh cell
            cid = match(r"id=(\w+)", NS.agent_add_cell!(nb, "2 + 2"; tags = "hidecode, wip"))[1]
            @test :hidecode in _flags(cid) && :wip in _flags(cid)
            # edit_cell with tags REPLACES them
            NS.agent_edit_cell!(nb, cid, "2 + 3"; tags = "reviewed")
            @test :reviewed in _flags(cid) && !(:wip in _flags(cid)) && !(:hidecode in _flags(cid))
            # edit_cell WITHOUT tags leaves the existing tags untouched (no silent wipe)
            NS.agent_edit_cell!(nb, cid, "2 + 4")
            @test :reviewed in _flags(cid)
        end

        @testset "external tool calls surface in the chat panel" begin
            # Pure envelope shape — exactly what the browser's `agentEvent` consumes.
            use, res = NS._external_tool_envelopes("ext-1", "edit_cell",
                Dict{String,Any}("cell" => "intro", "source" => "x = 1"), "edited id=intro"; ok = true)
            ue = NS.JSON.parse(use); re = NS.JSON.parse(res)
            @test ue["kind"] == "tool_use" && ue["external"] === true
            @test ue["data"]["call"]["toolCallId"] == "ext-1"
            @test ue["data"]["call"]["title"] == "slate_edit_cell"          # → _prettyTool → "✏️ edit cell"
            @test ue["data"]["call"]["rawInput"]["source"] == "x = 1"       # → code preview + navigate chip
            @test re["kind"] == "tool_result" && re["external"] === true
            @test re["data"]["update"]["toolCallId"] == "ext-1"             # pairs with the tool_use
            @test re["data"]["update"]["status"] == "completed"
            @test re["data"]["update"]["content"][1]["content"]["text"] == "edited id=intro"
            # ok=false → a failed (error) row
            _, rf = NS._external_tool_envelopes("ext-2", "run", Dict{String,Any}("cell" => "x"), "⛔ nope"; ok = false)
            @test NS.JSON.parse(rf)["data"]["update"]["status"] == "failed"

            loglen() = lock(NS._AGENT_LOCK) do; length(get(NS._AGENT_LOG, nb.id, String[])); end

            # An external MCP client (agent_id "") → surfaced as a tool_use + tool_result pair.
            empty!(nb.agents)
            n0 = loglen()
            NS.note_external_tool!(nb, "", "add_cell", Dict{String,Any}("source" => "1+1"), "added id=z1")
            @test loglen() == n0 + 2
            # A crew agent (its id is in nb.agents) → NOT surfaced (already relayed over the agent bus).
            nb.agents["default"] = "slate-crew-1"
            n1 = loglen()
            NS.note_external_tool!(nb, "slate-crew-1", "add_cell", Dict{String,Any}("source" => "2"), "added id=z2")
            @test loglen() == n1
            # A foreign Kaimon agent (spawned for another notebook; not our crew) → surfaced.
            NS.note_external_tool!(nb, "slate-other-nb", "add_cell", Dict{String,Any}("source" => "3"), "added id=z3")
            @test loglen() == n1 + 2
            empty!(nb.agents)
        end
    finally
        NS.stop_hub(hub)
    end
end
