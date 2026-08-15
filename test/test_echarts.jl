# ECharts DSL tests: the option dict each form/kind builds, and — the whole point of the DSL being
# discoverable — that Express-mode top-level component kwargs (axes/grid/zoom) land on the OPTION, not
# the series. `echart(...)` is pure (returns an `EChart` whose `.option` is a Dict), so we assert on it.
using ReTest

include(joinpath(@__DIR__, "..", "src", "engine.jl")); using .ReportEngine
const RE = ReportEngine

@testset "ECharts DSL" begin

    @testset "Express: one series, axes inferred" begin
        o = RE.echart(:line, ["Mon", "Tue", "Wed"], [1, 2, 3]; title = "T", smooth = true).option
        @test o["series"][1]["type"] == "line"
        @test o["series"][1]["smooth"] == true              # a plain kwarg styles the series
        @test o["xAxis"]["type"] == "category"              # string x ⇒ category axis
        @test o["xAxis"]["data"] == ["Mon", "Tue", "Wed"]
        @test o["title"]["text"] == "T"
        # numeric x ⇒ value axis + [x,y] point data
        o2 = RE.echart(:scatter, [1.0, 2.0], [3.0, 4.0]).option
        @test o2["xAxis"]["type"] == "value"
        @test o2["series"][1]["data"] == [[1.0, 3.0], [2.0, 4.0]]
    end

    @testset "Express: top-level component kwargs go on the OPTION, not the series" begin
        # The documented log-axis pattern — regression for the trap where `yAxis` was spliced into the
        # series and silently did nothing.
        o = RE.echart(:line, [1, 2, 3], [10, 100, 1000]; yAxis = (type = :log,)).option
        @test o["yAxis"]["type"] == "log"                   # lands on the option
        @test !haskey(o["series"][1], "yAxis")              # NOT on the series
        # a spread of top-level components all lift out; a real styling kwarg stays on the series
        o2 = RE.echart(:line, [1, 2, 3], [1, 2, 3];
                       grid = (left = 70,), dataZoom = [(type = :slider,)],
                       visualMap = (min = 0, max = 1), symbolSize = 6).option
        @test o2["grid"]["left"] == 70
        @test o2["dataZoom"][1]["type"] == "slider"
        @test o2["visualMap"]["min"] == 0
        @test o2["series"][1]["symbolSize"] == 6            # styling kwarg → series
        @test !haskey(o2["series"][1], "grid")
    end

    @testset "consistent typography: text inherits the document font unless overridden" begin
        # Default: all chart text uses one family (inherit), so a superscript in a title can't fall
        # back to a different font than the rest of the chart.
        o = RE.echart(:line, [1, 2], [3, 4]).option
        @test o["textStyle"]["fontFamily"] == "inherit"
        # A caller textStyle wins (and rides the OPTION in Express mode, not the series).
        o2 = RE.echart(:line, [1, 2], [3, 4]; textStyle = (fontFamily = "serif",)).option
        @test o2["textStyle"]["fontFamily"] == "serif"
        @test !haskey(o2["series"][1], "textStyle")
    end

    @testset "Composable: many series + option-level axes (dual Y)" begin
        o = RE.echart(RE.series(:line, [1, 2], [1, 2]; name = "L"),
                      RE.series(:bar, [1, 2], [3, 4]; name = "R", yAxisIndex = 1);
                      legend = true, yAxis = [(name = "L",), (name = "R", type = :log)]).option
        @test length(o["series"]) == 2
        @test o["series"][2]["yAxisIndex"] == 1
        @test o["yAxis"] isa AbstractVector && o["yAxis"][2]["type"] == "log"
        @test haskey(o, "legend")
    end

    @testset "Ergonomic kinds bring their implied components" begin
        heat = RE.echart(:heatmap, ["a", "b"], ["x", "y"], [1 2; 3 4]).option
        @test heat["xAxis"]["type"] == "category" && heat["yAxis"]["type"] == "category"
        @test haskey(heat, "visualMap")                     # heatmap implies a visualMap
        pie = RE.echart(:pie, ["A", "B"], [10, 20]).option
        @test !haskey(pie, "xAxis")                         # pie carries no cartesian axes
        @test pie["series"][1]["data"][1]["name"] == "A"
    end

    @testset "Relational / hierarchical / geo / calendar kinds" begin
        # sankey: nodes auto-derived from link endpoints; pair sugar `src => tgt => val`
        sk = RE.echart(:sankey, [("a", "b", 5), ("b" => ("c" => 3))]).option
        @test sk["series"][1]["type"] == "sankey"
        @test Set(n["name"] for n in sk["series"][1]["data"]) == Set(["a", "b", "c"])
        @test sk["series"][1]["links"][1]["value"] == 5
        @test !haskey(sk, "xAxis")                          # brings its own coordinate system
        # explicit nodes list
        @test length(RE.echart(:sankey, ["x", "y"], [("x", "y", 1)]).option["series"][1]["data"]) == 2

        # graph: force layout by default, edges from tuples or pairs
        g = RE.echart(:graph, ["a", "b", "c"], [("a", "b"), "b" => "c"]).option
        @test g["series"][1]["type"] == "graph" && g["series"][1]["layout"] == "force"
        @test length(g["series"][1]["links"]) == 2 && !haskey(g, "yAxis")

        # treemap/sunburst hierarchy: pair sugar (leaf/branch) + NamedTuple passthrough
        tm = RE.echart(:treemap, ["A" => 10, "B" => ["b1" => 3, "b2" => 4]]).option
        @test tm["series"][1]["data"][2]["children"][1]["value"] == 3 && !haskey(tm, "xAxis")
        sb = RE.echart(:sunburst, [(name = "root", children = [(name = "c", value = 5)])]).option
        @test sb["series"][1]["data"][1]["children"][1]["value"] == 5

        # geo lines: bound to the geo coordinate system, no cartesian axes, progressive=0 (roam-safe)
        ln = RE.echart(:lines, [(0.0, 0.0)], [(10.0, 20.0)]; geo = (map = "world",)).option
        @test ln["series"][1]["type"] == "lines" && ln["series"][1]["coordinateSystem"] == "geo"
        @test ln["series"][1]["data"][1]["coords"] == [[0.0, 0.0], [10.0, 20.0]]
        @test ln["series"][1]["progressive"] == 0 && !haskey(ln, "xAxis") && ln["geo"]["map"] == "world"

        # calendar heatmap: a heatmap series on the calendar coord + implied calendar/visualMap
        cal = RE.echart(:calendar, ["2024-01-01", "2024-12-31"], [1, 9]).option
        @test cal["series"][1]["type"] == "heatmap" && cal["series"][1]["coordinateSystem"] == "calendar"
        @test cal["calendar"]["range"] == "2024" && cal["visualMap"]["max"] == 9 && !haskey(cal, "xAxis")
        @test RE.echart(:calendar, ["2023-11-01", "2024-02-01"], [2, 7]).option["calendar"]["range"] == ["2023", "2024"]
    end

    @testset "Raw form is the full option surface, Symbol/NamedTuple-friendly" begin
        o = RE.echart(; xAxis = (type = :category, data = ["a"]),
                      series = [(type = :bar, data = [1])]).option
        @test o["xAxis"]["type"] == "category"
        @test o["series"][1]["type"] == "bar"
    end

    # `zoom` — ECharts declares no zoom by default, and the bare `inside` component is invisible
    # and irreversible. `zoom=true` is the one-word form that also supplies the affordances.
    @testset "zoom: expands to dataZoom (+ toolbox), never clobbering an explicit one" begin
        o = RE.echart(:line, [1, 2], [3, 4]; zoom = true).option
        @test o["dataZoom"][1]["type"] == "inside"
        @test o["dataZoom"][1]["xAxisIndex"] == [0]
        # The full range is stated explicitly so `restore` has a defined target — without it the
        # toolbox reset jumps to whatever window ECharts first saw, which on a reactively
        # re-rendered chart need not contain the data now plotted.
        @test o["dataZoom"][1]["start"] == 0 && o["dataZoom"][1]["end"] == 100
        @test haskey(o["toolbox"]["feature"], "dataZoom") && haskey(o["toolbox"]["feature"], "restore")
        @test !haskey(o, "zoom")                                   # the Slate kwarg never survives
        # Gesture only — no toolbox.
        ins = RE.echart(:line, [1, 2], [3, 4]; zoom = :inside).option
        @test ins["dataZoom"][1]["type"] == "inside" && !haskey(ins, "toolbox")
        # Slider, and both.
        sl = RE.echart(:line, [1, 2], [3, 4]; zoom = :slider).option
        @test only(sl["dataZoom"])["type"] == "slider"
        @test Set(d["type"] for d in RE.echart(:line, [1, 2], [3, 4]; zoom = :both).option["dataZoom"]) ==
              Set(["inside", "slider"])
        # Multi-panel: EVERY x axis, so stacked panels zoom together rather than drifting apart.
        multi = RE.echart(:line, [1, 2], [3, 4]; zoom = true,
                          xAxis = [(type = :value,), (type = :value, gridIndex = 1)]).option
        @test multi["dataZoom"][1]["xAxisIndex"] == [0, 1]
        # An explicit component wins — the raw escape hatch stays clean.
        exp1 = RE.echart(:line, [1, 2], [3, 4]; zoom = true,
                         dataZoom = [(type = :slider,)]).option
        @test only(exp1["dataZoom"])["type"] == "slider"
        # zoom=false is a no-op, not an empty component.
        @test !haskey(RE.echart(:line, [1, 2], [3, 4]; zoom = false).option, "dataZoom")
        # Raw form too, and a bad mode fails loudly.
        @test RE.echart(; series = [(type = "line", data = [1])], zoom = :slider).option["dataZoom"][1]["type"] == "slider"
        @test_throws ArgumentError RE.echart(:line, [1, 2], [3, 4]; zoom = :sideways)
    end

    # `select` — the chart's x-range as an INPUT for a `@bind`. Julia names the variable; the
    # front-end resolves it to its defining cell and does the two-way link (core.js
    # `_wireEchartSelect`). What's asserted here is the wire contract and that the brush component
    # is set up so the reader can just drag.
    @testset "select: chart drag drives a @bind range" begin
        o = RE.echart(:line, [1, 2], [3, 4]; select = :span).option
        @test o["__select"]["name"] == "span"
        @test !haskey(o, "select")                            # the Slate kwarg never survives
        @test o["brush"]["brushType"] == "lineX" && o["brush"]["brushMode"] == "single"
        @test o["brush"]["throttleType"] == "debounce"        # commit on settle, not per pixel
        @test o["toolbox"]["show"] === false                  # permanently armed; no tool to pick
        # A String names the same thing as a Symbol.
        @test RE.echart(:line, [1, 2], [3, 4]; select = "span").option["__select"]["name"] == "span"
        # An explicit brush wins — styling/mode stays overridable without losing the link.
        ov = RE.echart(:line, [1, 2], [3, 4]; select = :span,
                       brush = (brushType = :rect,)).option
        @test ov["brush"]["brushType"] == "rect" && ov["__select"]["name"] == "span"
        # No marker at all when unused.
        @test !haskey(RE.echart(:line, [1, 2], [3, 4]).option, "__select")
    end

    # `valuefmt` — tooltip number formatting. A JS function can't cross a JSON option (no reviver),
    # so the spec travels as DATA under `__valuefmt` and the front-end (`_valueFormatter`, core.js)
    # turns it into a `tooltip.valueFormatter`. What matters here: the spec is normalised through
    # the SAME `_parse_col_format` the tables use (so the two vocabularies can't drift), the raw
    # kwarg never survives onto the option (ECharts would carry an unknown key into its model), and
    # it works in all four call forms.
    @testset "valuefmt: tooltip number formatting, shared with the table format DSL" begin
        wire(o) = get(o, "__valuefmt", nothing)
        # Preset (arrives as a String — `_ec` stringifies Symbols before normalisation) + overrides.
        pre = RE.echart(:line, [1.0, 2.0], [0.001, 0.002]; valuefmt = :scientific).option
        @test wire(pre)["kind"] == "scientific" && wire(pre)["digits"] == 3
        ovr = RE.echart(:line, [1.0, 2.0], [0.001, 0.002];
                        valuefmt = (kind = :fixed, digits = 5)).option
        @test wire(ovr)["kind"] == "fixed" && wire(ovr)["digits"] == 5
        # The Slate-only kwarg must NOT reach the option as itself.
        @test !haskey(ovr, "valuefmt")
        # Per series — for a chart whose series carry different units.
        ser = RE.echart(RE.series(:line, [1.0, 2.0], [0.1, 0.2]; name = "a", valuefmt = :percent),
                        RE.series(:line, [1.0, 2.0], [3.0, 4.0]; name = "b")).option
        @test wire(ser["series"][1])["kind"] == "percent"
        @test wire(ser["series"][2]) === nothing           # untouched
        @test !haskey(ser["series"][1], "valuefmt")
        @test wire(ser) === nothing                        # not lifted to the option
        # Raw form gets it too (every echart form funnels through `_slate_normalize!`).
        raw = RE.echart(; series = [(type = "bar", data = [[1, 2]])], valuefmt = :integer).option
        @test wire(raw)["kind"] == "integer" && wire(raw)["sep"] === true
        # A chart with no valuefmt carries no marker at all.
        @test wire(RE.echart(:line, [1, 2], [3, 4]).option) === nothing
        # Unknown presets fail loudly rather than silently formatting as :fixed.
        @test_throws ArgumentError RE.echart(:line, [1, 2], [3, 4]; valuefmt = :nonsense)
    end
    # (The reference-is-surfaced-to-agents assertions live in test_agentops.jl, where NotebookServer's
    #  `slate_api_reference` is already in scope.)

end
