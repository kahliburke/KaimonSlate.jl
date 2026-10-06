# The notebook worker as a package, so each worker process loads a precompiled image instead of
# compiling its code at boot. The code lives beside the hub's in src/, where the files it shares with
# the engine are; worker.jl is the module body.
module SlateWorker
include(joinpath(@__DIR__, "..", "..", "worker.jl"))
end
