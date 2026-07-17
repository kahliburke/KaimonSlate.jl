# Interactive-table capture tests (slate_table + DataFrame/Tables.jl auto-render).
# Tables.jl is NOT a test dependency, so the soft-detection path is exercised only
# by its absence here (a bare NamedTuple-vector must NOT auto-render); the
# no-dependency shapes carry the rest.
using ReTest

const HERE = @__DIR__
include(joinpath(HERE, "..", "src", "engine.jl")); using .ReportEngine
import JSON

_names(t) = String[c.name for c in t.columns]              # ColumnDef → names, for terse assertions

@testset "SlateTable / slate_table" begin

    @testset "no-dependency shapes" begin
        # Vector of NamedTuples → columns from keys, rows in order.
        t = slate_table([(name = "a", x = 1), (name = "b", x = 2)])
        @test t isa SlateTable
        @test _names(t) == ["name", "x"]
        @test [c.type for c in t.columns] == [:string, :int]   # inferred physical types
        @test t.rows == [Any["a", 1], Any["b", 2]]
        @test t.opts["nrows"] == 2 && t.opts["ncols"] == 2

        # NamedTuple of column vectors.
        tc = slate_table((x = [1, 2, 3], y = [4, 5, 6]))
        @test _names(tc) == ["x", "y"]
        @test length(tc.rows) == 3 && tc.rows[3] == Any[3, 6]

        # Dict of column vectors (key order is unspecified — compare as sets).
        td = slate_table(Dict("a" => [1, 2], "b" => [3, 4]))
        @test Set(_names(td)) == Set(["a", "b"])
        @test length(td.rows) == 2

        # Explicit columns + rows, and a matrix.
        te = slate_table(["p", "q"], [[1, 2], [3, 4]])
        @test _names(te) == ["p", "q"] && te.rows == [Any[1, 2], Any[3, 4]]
        tm = slate_table(["p", "q"], [1 2; 3 4])
        @test tm.rows == [Any[1, 2], Any[3, 4]]

        # Idempotent + a clear error for unsupported input.
        @test slate_table(te) === te
        @test_throws ArgumentError slate_table(42)

        # Empty vector → an empty (but valid) table, not an error.
        @test isempty(slate_table(Vector{NamedTuple}()).columns)
    end

    @testset "column type inference + default alignment" begin
        t = slate_table((i = [1, 2], f = [1.5, 2.5], b = [true, false], s = ["a", "b"]))
        @test [c.type for c in t.columns] == [:int, :float, :bool, :string]
        @test [c.align for c in t.columns] == [:right, :right, :center, :left]
        # a column with a missing/nothing mixed in still infers from the present values
        tm = slate_table((x = [1, missing, 3],))
        @test tm.columns[1].type == :int
        # all-missing / empty ⇒ :string
        @test slate_table((x = [missing, nothing],)).columns[1].type == :string
    end

    @testset "format / align DSL" begin
        t = slate_table((Revenue = [45999.5, 12050.0], Margin = [0.324, 0.281], Product = ["A", "B"]);
                        format = (Revenue = :currency, Margin = (kind = :percent, digits = 1)),
                        align  = (Product = :center,))
        cols = Dict(c.name => c for c in t.columns)
        @test cols["Revenue"].format.kind == :currency && cols["Revenue"].format.digits == 2
        @test cols["Margin"].format.kind == :percent && cols["Margin"].format.digits == 1
        @test cols["Product"].align == :center
        @test cols["Revenue"].align == :right                 # inferred default preserved
        # coltype override + unknown-column typo → hard error
        @test slate_table(["x"], [[1]]; coltype = (x = :string,)).columns[1].type == :string
        @test_throws ArgumentError slate_table(["x"], [[1]]; format = (nope = :currency,))
        # the trailing-comma trap: `viz = (x = :heat)` is an assignment, not a NamedTuple — the
        # bare Symbol must produce a FRIENDLY ArgumentError naming the fix, not a keys(::Symbol)
        # MethodError
        err = try; slate_table(["x"], [[1]]; viz = :heat); nothing; catch e; e; end
        @test err isa ArgumentError && occursin("trailing comma", err.msg)
    end

    @testset "default_format: blanket numeric format, per-column override wins" begin
        t = slate_table((Revenue = [45999.5, 12050.0], Margin = [0.324, 0.281], Product = ["A", "B"]);
                        default_format = :integer, format = (Margin = :percent,))
        cols = Dict(c.name => c for c in t.columns)
        @test cols["Revenue"].format.kind == :integer          # blanket applied (numeric, no override)
        @test cols["Margin"].format.kind == :percent           # explicit `format` wins over the blanket
        @test cols["Product"].format === nothing                # non-numeric columns untouched
    end

    @testset "viz (bar/heat) + domain + export_rows" begin
        t = slate_table((a = [1, 2, 3, 4], b = ["w", "x", "y", "z"]); viz = (a = :bar,), export_rows = 2)
        ca, cb = t.columns
        @test ca.viz == :bar
        @test ca.domain == (1.0, 4.0)                 # numeric domain inferred at capture (for scaling)
        @test cb.viz == :none && cb.domain === nothing
        @test t.opts["export_rows"] == 2
        # wire carries viz + domain only for the viz column
        wa = ReportEngine._col_wire(ca)
        @test wa["viz"] == "bar" && wa["domain"] == Any[1.0, 4.0]
        @test !haskey(ReportEngine._col_wire(cb), "viz")
    end

    @testset "cells are reduced to JSON-safe scalars" begin
        cv = ReportEngine._cellval
        @test cv(nothing) === nothing
        @test cv(missing) === nothing
        @test cv(true) === true
        @test cv(7) === Int64(7)
        @test cv(1.5) === 1.5
        @test cv(NaN) == "NaN"          # JSON has no NaN/Inf → stringified
        @test cv(Inf) == "Inf"
        @test cv(Symbol("s")) == "s"
        @test cv(1 // 2) === 0.5         # Rational → finite Float64
        @test cv(big(10)^40) isa String # out of Int64 range → string (JS precision)
    end

    @testset "row cap is applied and flagged" begin
        t = slate_table(["i"], [[i] for i in 1:(ReportEngine._MAX_TABLE_ROWS + 500)])
        @test length(t.rows) == ReportEngine._MAX_TABLE_ROWS
        @test t.opts["truncated"] == true
        @test t.opts["nrows"] == ReportEngine._MAX_TABLE_ROWS + 500
    end

    @testset "capture: slate_table return → wire `tables`, value suppressed" begin
        r = parse_report("#%% code id=t\nslate_table([(a=1,b=2),(a=3,b=4)])")
        eval_report!(r)
        out = r.cells[1].output
        @test out.exception === nothing
        @test length(out.tables) == 1
        @test [c["name"] for c in out.tables[1]["columns"]] == ["a", "b"]
        @test out.tables[1]["columns"][1]["type"] == "int"      # object-form columns carry type/align/format
        @test out.tables[1]["columns"][1]["align"] == "right"
        @test out.tables[1]["columns"][1]["format"] === nothing
        @test out.tables[1]["rows"] == [Any[1, 2], Any[3, 4]]
        @test out.value_repr == ""               # richer output suppresses the text repr
        @test isempty(out.display)               # not captured as a MIME chunk

        # The wire form (gate contract) carries the same raw spec.
        w = run_capture(report_module(r), "slate_table([(a=1,),(a=2,)])")
        @test length(w.tables) == 1 && [c["name"] for c in w.tables[1]["columns"]] == ["a"]
    end

    @testset "no auto-render without Tables.jl" begin
        # A bare NamedTuple-vector is a Tables.jl table, but with Tables.jl absent
        # it must fall through to the text repr — never silently become a table.
        r = parse_report("#%% code id=t\n[(a=1,b=2),(a=3,b=4)]")
        eval_report!(r)
        out = r.cells[1].output
        @test isempty(out.tables)
        @test !isempty(out.value_repr)
    end

    @testset "paged: InMemoryPagedProvider fetch_page" begin
        P = ReportEngine
        prov = P._inmemory_provider((a = [3, 1, 2, 5, 4], b = ["c", "a", "b", "e", "d"]))
        @test prov isa P.InMemoryPagedProvider
        cols = P.page_columns(prov)
        @test [c.name for c in cols] == ["a", "b"]
        @test cols[1].type == :int && cols[2].type == :string

        @test P.fetch_page(prov, P.PageRequest(1, 2, 0, false, "")).total == 5
        @test length(P.fetch_page(prov, P.PageRequest(1, 2, 0, false, "")).rows) == 2
        @test [r[1] for r in P.fetch_page(prov, P.PageRequest(1, 10, 1, false, "")).rows] == [1, 2, 3, 4, 5]
        @test [r[1] for r in P.fetch_page(prov, P.PageRequest(1, 10, 1, true, "")).rows] == [5, 4, 3, 2, 1]
        @test [r[1] for r in P.fetch_page(prov, P.PageRequest(2, 2, 1, false, "")).rows] == [3, 4]  # sorted page 2
        @test P.fetch_page(prov, P.PageRequest(1, 10, 0, false, "a")).total == 1  # search across cols
    end

    @testset "paged: capture wire + table_page round-trip" begin
        r = parse_report("#%% code id=t\nslate_table((a=collect(1:100), b=collect(101:200)); paged=true)")
        eval_report!(r)
        out = r.cells[1].output
        @test out.exception === nothing
        @test length(out.tables) == 1
        spec = out.tables[1]
        @test spec["paged"] == true
        @test haskey(spec, "tableId")
        @test [c["name"] for c in spec["columns"]] == ["a", "b"]
        @test spec["opts"]["nrows"] == 100
        @test length(spec["rows"]) == 50              # page 1, default page_size 50
        @test spec["rows"][1] == Any[1, 101]

        # Fetch later pages / sorts via the kernel seam, using the registered id.
        res = ReportEngine.table_page(InProcessKernel(), r, spec["tableId"],
            Dict("page" => 2, "page_size" => 50, "sort_col" => 0, "sort_desc" => false, "search" => ""))
        @test res.total == 100 && length(res.rows) == 50 && res.rows[1] == Any[51, 151]
        res2 = ReportEngine.table_page(InProcessKernel(), r, spec["tableId"],
            Dict("page" => 1, "page_size" => 3, "sort_col" => 1, "sort_desc" => true))
        @test [row[1] for row in res2.rows] == [100, 99, 98]
        # Unknown id → graceful empty page (e.g. evicted / stale after recompute).
        res3 = ReportEngine.table_page(InProcessKernel(), r, "nope", Dict("page" => 1))
        @test res3.total == 0 && isempty(res3.rows)
    end

    @testset "paged: SQL provider plumbing (no DB needed)" begin
        P = ReportEngine
        @test P._like_arg("A'b%c") == "%a''b\\%c%"     # lowercased, quote-doubled, %/_ escaped
        prov = P.SqlPagedProvider(nothing, "SELECT * FROM t",
            [P.ColumnDef("x", :int, :right, nothing, true, true), P.ColumnDef("y", :string, :left, nothing, true, true)])
        w = P._sql_where(prov, P.PageRequest(1, 10, 0, false, "foo"))
        @test occursin("LOWER(CAST(\"x\" AS VARCHAR)) LIKE", w) && occursin(" OR ", w)
        @test P._sql_where(prov, P.PageRequest(1, 10, 0, false, "")) == ""
        # Without DBInterface/Tables loaded, slate_query errors clearly (not a MethodError).
        @test_throws ArgumentError slate_query(nothing, "SELECT 1")
    end

    @testset "formatter parity fixture (_format_cell)" begin
        # The SAME golden fixture is asserted from JS (fmtCell) — see test/js/format_parity.mjs.
        cases = JSON.parsefile(joinpath(HERE, "fixtures", "format_cases.json"))
        fails = String[]
        for c in cases
            got = ReportEngine._format_cell(c["value"], c["format"])
            got == c["expected"] ||
                push!(fails, "$(c["value"]) $(c["format"]) → $(repr(got)) (expected $(repr(c["expected"])))")
        end
        @test isempty(fails)   # aggregate: one assertion, all divergences listed on failure
        isempty(fails) || foreach(println, fails)

        # The conservative default (no format) cleans numbers without a DSL opt-in.
        @test ReportEngine._format_cell(210000.0, nothing) == "210000"
        @test ReportEngine._format_cell(1.25e6, nothing) == "1250000"
        @test ReportEngine._format_cell(0.4153, nothing) == "0.4153"
        @test ReportEngine._format_cell(42, nothing) == "42"
        @test ReportEngine._format_cell(nothing, nothing) == ""
    end

    @testset "formatter parity: JS fmtCell (node, if available)" begin
        node = Sys.which("node")
        if node === nothing
            @info "node not found — skipping JS↔Julia formatter parity (Julia fixture asserted above)"
            @test true
        else
            io = IOBuffer()
            ok = success(pipeline(`$node $(joinpath(HERE, "js", "format_parity.mjs"))`; stdout = io, stderr = io))
            ok || print(String(take!(io)))         # surface the diverging cases on failure
            @test ok
        end
    end
end
