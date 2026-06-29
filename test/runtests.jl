# Package test entry point. Each file is run in its own module (SafeTestsets) so
# the per-file `include("../src/engine.jl")` namespaces stay isolated. Each file
# is also runnable standalone: `julia --project test/test_<name>.jl`.
using SafeTestsets

@safetestset "defname" begin include("test_defname.jl") end
@safetestset "animation" begin include("test_animation.jl") end
@safetestset "engine" begin include("test_engine.jl") end
@safetestset "eval"   begin include("test_eval.jl") end
@safetestset "deps"   begin include("test_deps.jl") end
@safetestset "bind"   begin include("test_bind.jl") end
@safetestset "render" begin include("test_render.jl") end
@safetestset "tables" begin include("test_tables.jl") end
@safetestset "trace"  begin include("test_trace.jl") end
@safetestset "complete" begin include("test_complete.jl") end
@safetestset "history" begin include("test_history.jl") end
@safetestset "agentops" begin include("test_agentops.jl") end
@safetestset "repro" begin include("test_repro.jl") end
