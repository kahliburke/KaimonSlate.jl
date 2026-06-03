# Interactive-table capture tests (slate_table + DataFrame/Tables.jl auto-render).
# Tables.jl is NOT a test dependency, so the soft-detection path is exercised only
# by its absence here (a bare NamedTuple-vector must NOT auto-render); the
# no-dependency shapes carry the rest.
using Test

const HERE = @__DIR__
include(joinpath(HERE, "..", "src", "engine.jl")); using .ReportEngine

@testset "SlateTable / slate_table" begin

    @testset "no-dependency shapes" begin
        # Vector of NamedTuples → columns from keys, rows in order.
        t = slate_table([(name = "a", x = 1), (name = "b", x = 2)])
        @test t isa SlateTable
        @test t.columns == ["name", "x"]
        @test t.rows == [Any["a", 1], Any["b", 2]]
        @test t.opts["nrows"] == 2 && t.opts["ncols"] == 2

        # NamedTuple of column vectors.
        tc = slate_table((x = [1, 2, 3], y = [4, 5, 6]))
        @test tc.columns == ["x", "y"]
        @test length(tc.rows) == 3 && tc.rows[3] == Any[3, 6]

        # Dict of column vectors (key order is unspecified — compare as sets).
        td = slate_table(Dict("a" => [1, 2], "b" => [3, 4]))
        @test Set(td.columns) == Set(["a", "b"])
        @test length(td.rows) == 2

        # Explicit columns + rows, and a matrix.
        te = slate_table(["p", "q"], [[1, 2], [3, 4]])
        @test te.columns == ["p", "q"] && te.rows == [Any[1, 2], Any[3, 4]]
        tm = slate_table(["p", "q"], [1 2; 3 4])
        @test tm.rows == [Any[1, 2], Any[3, 4]]

        # Idempotent + a clear error for unsupported input.
        @test slate_table(te) === te
        @test_throws ArgumentError slate_table(42)

        # Empty vector → an empty (but valid) table, not an error.
        @test slate_table(Vector{NamedTuple}()).columns == String[]
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
        @test out.tables[1]["columns"] == ["a", "b"]
        @test out.tables[1]["rows"] == [Any[1, 2], Any[3, 4]]
        @test out.value_repr == ""               # richer output suppresses the text repr
        @test isempty(out.display)               # not captured as a MIME chunk

        # The wire form (gate contract) carries the same raw spec.
        w = run_capture(report_module(r), "slate_table([(a=1,),(a=2,)])")
        @test length(w.tables) == 1 && w.tables[1]["columns"] == ["a"]
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
end
