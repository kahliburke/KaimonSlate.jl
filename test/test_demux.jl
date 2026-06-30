# Unit tests for the task-demultiplexing capture primitive (src/demux.jl) — the foundation for the
# in-process parallel evaluator pool. Verifies that concurrent tasks each capture their OWN output.
using ReTest

include(joinpath(@__DIR__, "..", "src", "demux.jl"))

@testset "demux" begin
    @testset "DemuxIO routes per task; fallback when unset" begin
        fb = IOBuffer()
        d = DemuxIO(:k, fb)
        print(d, "to-fallback")                      # no task-local key → fallback
        @test String(take!(fb)) == "to-fallback"

        bufs = [IOBuffer() for _ in 1:6]
        @sync for i in 1:6
            Threads.@spawn begin
                task_local_storage(:k, bufs[i])      # this task's sink
                for _ in 1:200; print(d, "t$i ") end  # hammer it concurrently
            end
        end
        for i in 1:6
            toks = split(strip(String(take!(bufs[i]))))
            @test length(toks) == 200
            @test all(==("t$i"), toks)               # ONLY this task's writes landed here
        end
        @test position(fb) == 0                       # nothing leaked to the fallback
    end

    @testset "with_captured_output isolates concurrent evaluators (global stdout = DemuxIO)" begin
        prev = install_demux!()                          # rebind Base.stdout/stderr to the demux
        try
            res = Vector{Any}(undef, 5)
            @sync for i in 1:5
                Threads.@spawn begin
                    res[i] = with_captured_output() do
                        for _ in 1:80; print("o$i ") end
                        println(stderr, "e$i")
                        i * 100
                    end
                end
            end
            for i in 1:5
                @test res[i].value == i * 100
                otoks = split(strip(res[i].stdout))
                @test length(otoks) == 80 && all(==("o$i"), otoks)   # stdout isolated
                @test strip(res[i].stderr) == "e$i"                  # stderr isolated
            end
        finally
            restore_streams!(prev)
        end
    end
end
