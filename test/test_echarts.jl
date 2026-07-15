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
    # (The reference-is-surfaced-to-agents assertions live in test_agentops.jl, where NotebookServer's
    #  `slate_api_reference` is already in scope.)

end
