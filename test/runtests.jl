# Package test entry point. Each file is included into its OWN module so the per-file
# `include("../src/…")` namespaces stay isolated (what `@safetestset` gave us before), and every file
# uses ReTest's LAZY `@testset` — so a subset can be run by pattern:
#   run_tests(pattern="parsched")                       # via Kaimon
#   julia --project -e 'using Pkg; Pkg.test(test_args=["parsched"])'
using ReTest

module Defname;   include("test_defname.jl");   end
module Prepare;   include("test_prepare.jl");   end
module Demux;     include("test_demux.jl");     end
module Parsched;  include("test_parsched.jl");  end
module Memostore; include("test_memostore.jl"); end
module Effectstore; include("test_effectstore.jl"); end
module Blobchannel; include("test_blobchannel.jl"); end
module RemotePool; include("test_remote_pool.jl"); end
module Regions;   include("test_regions.jl");   end
module Parallel;  include("test_parallel.jl");  end
module Animation; include("test_animation.jl"); end
module Echarts;   include("test_echarts.jl");   end
module SlateLook; include("test_slate_look.jl"); end
module Engine;    include("test_engine.jl");    end
module Eval;      include("test_eval.jl");      end
module Deps;      include("test_deps.jl");      end
module Web;       include("test_web.jl");       end
module Bind;      include("test_bind.jl");      end
module Render;    include("test_render.jl");    end
module Tables;    include("test_tables.jl");    end
module Trace;     include("test_trace.jl");     end
module Complete;  include("test_complete.jl");  end
module History;   include("test_history.jl");   end
module Agentops;  include("test_agentops.jl");  end
module Repro;     include("test_repro.jl");     end
module Slides;    include("test_slides.jl");    end
module Frontmatter; include("test_frontmatter.jl"); end
module Export;    include("test_export.jl");    end
module Publishing; include("test_publishing.jl"); end
module App;       include("test_app.jl");       end

const _TESTMODS = (Defname, Prepare, Demux, Parsched, Memostore, Effectstore, Blobchannel, RemotePool, Regions, Parallel, Animation, Echarts, SlateLook, Engine, Eval, Deps,
                   Web, Bind, Render, Tables, Trace, Complete, History, Agentops, Repro, Slides,
                   Frontmatter, Export, Publishing, App)

# ARGS carries the optional ReTest pattern (forwarded by run_tests / Pkg.test); empty → run all.
# ReTest matches a plain String LITERALLY (regex metacharacters escaped), so "deps|eval" would match
# nothing — promote each arg to a case-insensitive Regex so alternation/anchors work.
retest(_TESTMODS..., (Regex(a, "i") for a in ARGS)...)
