# Parallel (inter-cell) batch execution — the server-side classifier that decides which cells are
# safe to run concurrently. `_cell_defines` must flag ANY cell that defines a method/type/macro: such
# a cell mutates the worker's method & type tables and so runs as a serial barrier. A false NEGATIVE
# (a def cell mistaken for pure compute) would let it run concurrently — unsafe — so this is the
# safety-critical predicate and is tested directly.
using ReTest
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

    @testset "provenance graphics detection (aliased plot verbs the regex misses)" begin
        # A helper alias like `const fancyplot! = lines!` defeats the lexical regex — the
        # crash-on-miss class. Once CairoMakie's exports resolve, provenance catches it.
        lock(RE._USING_LOCK) do
            RE._USING_EXPORTS["CairoMakie"] = [:fancyplot!, :lines!]
        end
        try
            g = RE._graphics_export_names()
            @test :fancyplot! in g
            mk(id, src) = (c = RE.Cell(id, RE.CODE, src); RE.infer_bindings!(c); c)
            c1 = mk("gp1", "fancyplot!(data)")
            @test !RE._uses_shared_graphics(c1.source)      # regex misses the alias…
            @test RE._is_graphics_cell(c1, g)               # …provenance doesn't
            @test !RE._is_graphics_cell(mk("gp2", "y = sum(rand(10))"), g)   # pure compute stays pure
            # end-to-end: the batch specs serialize the aliased cell against another graphics cell
            specs = NS._batch_specs([mk("ga", "fancyplot!(data)"), mk("gb", "fig = Figure()")])
            bl = NS.par_blockers(specs)
            @test !NS.co_runnable(["ga", "gb"], bl)
        finally
            lock(RE._USING_LOCK) do; delete!(RE._USING_EXPORTS, "CairoMakie"); end
        end
    end

    @testset "_preempt_victims: only running pure-compute cells are interruptible" begin
        running(src) = (c = cell(src); c.state = RE.RUNNING; c)
        # a running compute cell is a victim; the guards must hold everything else back
        @test NS._preempt_victims((running("x = sum(rand(10^8))"),)) == ["c"]
        @test isempty(NS._preempt_victims((cell("x = 1"),)))                       # not running
        @test isempty(NS._preempt_victims((running("f(x) = x + 1"),)))             # method def — never
        @test isempty(NS._preempt_victims((running("struct S; a; end"),)))         # type def — never
        @test isempty(NS._preempt_victims((running("fig = Figure(); lines!(ax, x, y)"),)))  # graphics — never
        # in-process kernel: cancel_cells is a no-op (nothing to preempt)
        @test RE.cancel_cells(RE.InProcessKernel(), RE.Report("nb", "nb"), ["c"]) == 0
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
