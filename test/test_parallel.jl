# Parallel (inter-cell) batch execution — the server-side classifier that decides which cells are
# safe to run concurrently. `_cell_defines` must flag ANY cell that defines a method/type/macro: such
# a cell mutates the worker's method & type tables and so runs as a serial barrier. A false NEGATIVE
# (a def cell mistaken for pure compute) would let it run concurrently — unsafe — so this is the
# safety-critical predicate and is tested directly.
using Test
using KaimonSlate
const NS = KaimonSlate.NotebookServer
const RE = KaimonSlate.ReportEngine

cell(src) = RE.Cell("c", RE.CODE, src)

@testset "parallel" begin
    @testset "_cell_defines flags definitions (serial barrier)" begin
        @test NS._cell_defines(cell("function f(x)\n  x + 1\nend"))     # long-form function
        @test NS._cell_defines(cell("f(x) = x + 1"))                    # short-form method
        @test NS._cell_defines(cell("g(x) where {T} = x"))             # parametric short-form
        @test NS._cell_defines(cell("struct Pt\n  x\n  y\nend"))        # type def
        @test NS._cell_defines(cell("abstract type Animal end"))        # abstract type
        @test NS._cell_defines(cell("macro m()\n  :(1)\nend"))          # macro def
        @test NS._cell_defines(cell("x = 1\nh(y) = y^2"))              # mixed: a def anywhere counts
        @test NS._cell_defines(cell("x = ("))                          # unparseable → conservative barrier
    end

    @testset "_cell_defines passes pure compute (parallelisable)" begin
        @test !NS._cell_defines(cell("x = 6 * 7"))                     # plain binding
        @test !NS._cell_defines(cell("y = sum(rand(100))"))           # call, not a def
        @test !NS._cell_defines(cell("const K = 3"))                  # const binding is not a method/type def
        @test !NS._cell_defines(cell("z = [i^2 for i in 1:10]"))      # comprehension
        @test !NS._cell_defines(cell("a = 1\nb = a + 2\nc = b * 3"))  # several bindings, no defs
    end

    @testset "parallel default + per-notebook override" begin
        r = RE.Report("nb", "nb")
        nb = NS.LiveNotebook("nb", "", r, RE.InProcessKernel(), 0, String[], String[],
                             ReentrantLock(), Channel{String}[], ReentrantLock(), "", false,
                             Dict{String,String}())
        old = NS.PARALLEL_DEFAULT[]
        try
            NS.PARALLEL_DEFAULT[] = true
            @test NS._parallel_enabled(nb) == true                     # no meta → follows the default
            nb.report.meta["parallel"] = false
            @test NS._parallel_enabled(nb) == false                    # per-notebook override wins
            NS.PARALLEL_DEFAULT[] = false
            delete!(nb.report.meta, "parallel")
            @test NS._parallel_enabled(nb) == false                    # follows default-off
            nb.report.meta["parallel"] = true
            @test NS._parallel_enabled(nb) == true                     # override on
        finally
            NS.PARALLEL_DEFAULT[] = old
        end
    end
end
