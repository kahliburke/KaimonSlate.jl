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

        @testset "delete several cells in one call" begin
            n0 = length(nb.report.cells)
            a = match(r"id=(\w+)", NS.agent_add_cell!(nb, "111"))[1]
            b = match(r"id=(\w+)", NS.agent_add_cell!(nb, "222"))[1]
            c = match(r"id=(\w+)", NS.agent_add_cell!(nb, "333"))[1]
            @test length(nb.report.cells) == n0 + 3
            # a list of ids → one atomic delete; missing ids are reported, the rest still go
            r = NS.agent_delete_cells!(nb, [a, b, "nope_zzz"])
            @test occursin("deleted 2 cells", r) && occursin("not found: nope_zzz", r)
            @test length(nb.report.cells) == n0 + 1                        # only c remains of the three
            @test NS._cell_exists(nb, c) && !NS._cell_exists(nb, a) && !NS._cell_exists(nb, b)
            NS.agent_delete_cells!(nb, [c])                                # single-element list also works
            @test length(nb.report.cells) == n0
            @test occursin("no cell", NS.agent_delete_cells!(nb, String[]))   # empty → guarded message
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
            @test occursin("@asset", full) && occursin("readfile", full) &&
                  occursin("@use", full) && occursin("WebPage", full)       # front-end asset system present
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
            # @asset + the front-end asset system: documented in full AND teaching the non-obvious
            # bit — a LITERAL path is statically TRACKED (memo-invalidation + a file-watcher re-run),
            # while a computed path needs `readfile` (untracked). Agents get this from the reference.
            as = NS.slate_api_reference("@asset")
            @test occursin("bytes", as) && occursin("readfile", as)          # both forms + the escape hatch
            @test occursin("track", lowercase(as)) && occursin("watch", lowercase(as))   # reactivity explained
            @test occursin("WebPage", as)                                    # cross-ref to the primary consumer
            @test occursin("readfile", NS.slate_api_reference("computed path")) ||    # searchable by concept
                  occursin("@asset", NS.slate_api_reference("read a file"))
            recs = NS.slate_api_records()
            @test !isempty(recs) && all(r -> r["module"] == "Slate", recs)
            @test any(r -> r["name"] == "@bind", recs) && any(r -> r["name"] == "animate", recs)
            # These records ARE what feeds `slate.search_docs` (module "Slate"), so every asset helper
            # must ride along — that's how they surface in search, not just the `slate.api` tool.
            @test all(nm -> any(r -> r["name"] == nm, recs), ["@asset", "readfile", "@use", "WebPage"])
            @test any(r -> r["name"] == "@asset" && occursin("track", lowercase(r["doc"])), recs)
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

        @testset "`needs=` tags survive sanitization and wire a manual edge" begin
            # The sanitizer folds punctuation to underscores — but a `key=value` tag's `=` and
            # value-commas are GRAMMAR: `needs=a,b` mangled to `needs_a_b` silently severs every
            # manual edge on the first tag round-trip (live regression).
            @test Symbol("needs=up,db") in NS._parse_tag_symbols(["needs=up,db"])
            @test Symbol("needs=up") in NS._parse_tag_symbols("needs=up cache")     # string form: whitespace-split
            @test :cache in NS._parse_tag_symbols("needs=up cache")
            @test Symbol("needs=a_b") in NS._parse_tag_symbols(["needs=a-b"])       # values still sanitized
            @test isempty(NS._parse_tag_symbols(["needs="]))                        # empty value → dropped
            # End-to-end: tag a downstream cell via the UI path; the edge lands in deps, the cell
            # restales, and the tag survives the persist round-trip verbatim.
            up = match(r"id=(\w+)", NS.agent_add_cell!(nb, "sideeffect = 1"))[1]
            dn = match(r"id=(\w+)", NS.agent_add_cell!(nb, "observed = 2"))[1]
            NS.set_cell_tags!(nb, dn, ["needs=$up"])
            dncell = nb.report.cells[NS._index_of(nb.report.cells, dn)]
            @test up in dncell.deps
            @test dncell.state == KaimonSlate.ReportEngine.STALE
            @test occursin("needs=$up", read(nb.path, String))
        end

        @testset "scratch eval — diagnostics without a cell" begin
            n0 = length(nb.report.cells)
            @test occursin("7", NS.agent_scratch_eval!(nb, "3 + 4"))
            @test length(nb.report.cells) == n0                              # no cell created
            # a bare assignment LEAKS into the kernel namespace (diagnostic state across calls)
            NS.agent_scratch_eval!(nb, "scratch_probe = 123")
            @test occursin("123", NS.agent_scratch_eval!(nb, "scratch_probe"))
            # ephemeral wraps in a `let` child scope → the binding is discarded
            NS.agent_scratch_eval!(nb, "ephemeral_probe = 999"; ephemeral = true)
            @test occursin("UndefVarError", NS.agent_scratch_eval!(nb, "ephemeral_probe"))
            # errors are CAPTURED, not thrown; still no cells added
            @test occursin("ERROR", NS.agent_scratch_eval!(nb, "sqrt(-1.0)"))
            @test length(nb.report.cells) == n0
        end

        @testset "surface @bind controls onto a cell" begin
            NS.agent_add_cell!(nb, "@bind sfreq Slider(1:100)\n@bind samp Slider(0:0.1:1)"; id = "sctl")
            NS.agent_add_cell!(nb, "sfreq * samp"; id = "splot")
            _ctrls(id) = nb.report.cells[NS._index_of(nb.report.cells, id)].controls
            # a row of two single-control columns
            @test occursin("surfaced 2", NS.agent_surface_controls!(nb, "splot", "sfreq,samp"))
            @test _ctrls("splot") == [["sfreq"], ["samp"]]
            # columns grammar: one stacked column
            NS.agent_surface_controls!(nb, "splot", "[sfreq,samp]")
            @test _ctrls("splot") == [["sfreq", "samp"]]
            # a typo is rejected (names listed), layout untouched
            r = NS.agent_surface_controls!(nb, "splot", "nope")
            @test occursin("unknown", r) && occursin("sfreq", r)
            @test _ctrls("splot") == [["sfreq", "samp"]]
            # empty clears the strip; a missing cell is reported
            NS.agent_surface_controls!(nb, "splot", "")
            @test isempty(_ctrls("splot"))
            @test occursin("no cell", NS.agent_surface_controls!(nb, "ghostcell", "sfreq"))
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

@testset "open with autorun=false: cells land STALE, untouched" begin
    hub = NS.start_hub(; port = 8860)
    try
        nbp = tempname() * ".jl"
        write(nbp, "#%% code id=a\nbase = 10\n#%% code id=b\nderived = base * 2\n")
        nb = hub.notebooks[NS.open_notebook!(hub, nbp; autorun = false)]
        sleep(0.3)   # generous: long enough for an errant auto-run to have started/finished
        @test all(c -> c.state == KaimonSlate.ReportEngine.STALE, nb.report.cells)
        @test get(nb.report.meta, "hydrating", false) !== true
        @test nb.report.cells[1].output === nothing    # never ran — no output at all

        # A manual run still works normally once triggered.
        NS._eval!(nb; wait_all = true)
        @test all(c -> c.state == KaimonSlate.ReportEngine.FRESH, nb.report.cells)
        @test nb.report.cells[2].output.value_repr == "20"

        # Re-opening the ALREADY-open notebook (autorun defaults true) doesn't touch it — `autorun`
        # only applies on a fresh open, mirroring `runon`.
        NS.open_notebook!(hub, nbp)
        @test all(c -> c.state == KaimonSlate.ReportEngine.FRESH, nb.report.cells)
    finally
        NS.stop_hub(hub)
    end
end

@testset "locked cell self-heals on a fresh autorun=false open (a cold reopen has nothing in memory)" begin
    hub = NS.start_hub(; port = 8861)
    try
        # `b` is deliberately SELF-CONTAINED (doesn't read `a`'s `base`): InProcessKernel (this test
        # has no gate worker) has no durable memo store, so its `eval_capture` ignores `memo` and just
        # re-evaluates — self-heal exercises the SAME trigger path a real GateKernel restore would, but
        # without a real memo store the "restore" is actually a recompute, which would UndefVarError if
        # `b` depended on `a` (never run in this fresh process, per autorun=false).
        nbp = tempname() * ".jl"
        write(nbp, "#%% code id=a\nbase = 10\n#%% code id=b\nderived = 5 * 2\n")
        id = NS.open_notebook!(hub, nbp)
        nb = hub.notebooks[id]
        NS._eval!(nb; wait_all = true)
        @test findfirst(c -> c.id == "b", nb.report.cells) !== nothing
        NS.set_cell_tags!(nb, "b", ["locked"])
        NS._eval!(nb; wait_all = true)   # locking a FRESH cell only QUEUES its capture force-run
        bcell() = nb.report.cells[findfirst(c -> c.id == "b", nb.report.cells)]
        @test :locked in bcell().flags
        @test any(f -> startswith(String(f), "lockedkey="), bcell().flags)

        NS.close_notebook!(hub, id)
        nb2 = hub.notebooks[NS.open_notebook!(hub, nbp; autorun = false)]
        # Self-heal runs in a background @async task — POLL for it to finish instead of a fixed sleep,
        # which can expire before the restore completes on a loaded / coverage-instrumented CI run
        # (leaving `output === nothing` → a spurious failure).
        bfind() = nb2.report.cells[findfirst(c -> c.id == "b", nb2.report.cells)]
        timedwait(10.0; pollint = 0.05) do
            bc = bfind(); bc.state == KaimonSlate.ReportEngine.FRESH && bc.output !== nothing
        end
        acell2 = nb2.report.cells[findfirst(c -> c.id == "a", nb2.report.cells)]
        bcell2 = bfind()
        @test acell2.state == KaimonSlate.ReportEngine.STALE     # unlocked: untouched, per autorun=false
        @test bcell2.state == KaimonSlate.ReportEngine.FRESH     # locked: self-healed despite autorun=false
        @test bcell2.output !== nothing && bcell2.output.value_repr == "10"
    finally
        Core.println(Core.stderr, "RKDIAG: self-heal testset before stop_hub(8861)")
        NS.stop_hub(hub)
        Core.println(Core.stderr, "RKDIAG: self-heal testset after stop_hub(8861)")
    end
end
Core.println(Core.stderr, "RKDIAG: self-heal testset fully exited")

@testset "restart_kernel!: a locked cell restores ahead of a slow preceding cell, not queued behind it" begin
    # TEMPORARY CI DIAGNOSTIC: this testset crashes the process on CI (exit 1, no output) while passing
    # locally; the stderr-capture mux swallows the real error. Emit step markers + any caught exception to
    # Core.stderr (the raw fd that bypasses the mux) so CI shows what actually dies. Revert once diagnosed.
    _diag(msg) = (Core.println(Core.stderr, "RKDIAG: " * msg))
    _diag("enter")
    try
        hub = NS.start_hub(; port = 8862)
        _diag("hub started")
        try
            nbp = tempname() * ".jl"
            write(nbp, "#%% code id=slow\nsleep(1.0); slowval = 1\n#%% code id=fast\nfastval = 5 * 2\n")
            nb = hub.notebooks[NS.open_notebook!(hub, nbp)]
            _diag("opened")
            NS._eval!(nb; wait_all = true)
            _diag("eval1 done")
            NS.set_cell_tags!(nb, "fast", ["locked"])
            NS._eval!(nb; wait_all = true)   # runs the surgical force-run queued by locking a FRESH cell
            _diag("eval2 (lock force-run) done")
            fastcell() = nb.report.cells[findfirst(c -> c.id == "fast", nb.report.cells)]
            @test any(f -> startswith(String(f), "lockedkey="), fastcell().flags)

            _diag("before restart_kernel!")
            NS.restart_kernel!(nb)
            _diag("after restart_kernel!")
            sleep(0.3)   # self-heal runs before the slow cell's 1s sleep finishes
            _diag("after sleep(0.3)")
            @test fastcell().state == KaimonSlate.ReportEngine.FRESH   # restored already — did NOT wait on `slow`
            slowcell() = nb.report.cells[findfirst(c -> c.id == "slow", nb.report.cells)]
            @test slowcell().state in (KaimonSlate.ReportEngine.STALE, KaimonSlate.ReportEngine.RUNNING)   # still queued/running
            _diag("asserts done")
            # Let the slow cell's re-run FINISH before teardown — otherwise `stop_hub` tears down while a
            # `Threads.@spawn` eval is mid-`sleep(1.0)`, and that orphaned eval crashes ~1s later against
            # the torn-down notebook (an async failure the stderr-capture mux swallows → silent exit 1).
            timedwait(5.0; pollint = 0.05) do; slowcell().state == KaimonSlate.ReportEngine.FRESH; end
            _diag("slow cell settled: state=$(slowcell().state)")
        finally
            _diag("before stop_hub")
            NS.stop_hub(hub)
            _diag("after stop_hub")
        end
    catch e
        Core.println(Core.stderr, "RKDIAG: CAUGHT EXCEPTION:")
        Core.println(Core.stderr, sprint(showerror, e))
        Core.println(Core.stderr, sprint(Base.show_backtrace, catch_backtrace()))
        rethrow()
    end
    _diag("exit")
end

@testset "▶ force-run on an upstream cell does not restale a locked FRESH dependent" begin
    hub = NS.start_hub(; port = 8863)
    try
        nbp = tempname() * ".jl"
        write(nbp, "#%% code id=a\nbase = 10\n#%% code id=b\nderived = base * 2\n")
        nb = hub.notebooks[NS.open_notebook!(hub, nbp)]
        NS._eval!(nb; wait_all = true)
        NS.set_cell_tags!(nb, "b", ["locked"])
        NS._eval!(nb; wait_all = true)   # surgical force-run queued by locking a FRESH cell
        bcell() = nb.report.cells[findfirst(c -> c.id == "b", nb.report.cells)]
        acell() = nb.report.cells[findfirst(c -> c.id == "a", nb.report.cells)]
        @test bcell().state == KaimonSlate.ReportEngine.FRESH
        lockedkey_before = KaimonSlate.ReportEngine._locked_key(bcell())
        @test !isempty(lockedkey_before)

        # Pressing ▶ on `a` (edit_cell! with force=true, same source) — the play button's own path.
        NS.edit_cell!(nb, "a", acell().source; force = true)
        NS._eval!(nb; wait_all = true)

        @test acell().state == KaimonSlate.ReportEngine.FRESH        # the played cell itself re-ran
        @test bcell().state == KaimonSlate.ReportEngine.FRESH        # `b` stayed frozen — never went STALE
        @test KaimonSlate.ReportEngine._locked_key(bcell()) == lockedkey_before
    finally
        NS.stop_hub(hub)
    end
end
