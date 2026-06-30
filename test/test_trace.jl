# Unit tests for `@trace` value tracing (src/trace.jl). The macro is injected per-notebook as
# `esc(_trace_transform(blk))` (widgets.jl) and records rows onto an injected `__slate_trace_sink`
# while the block RETURNS the cell's real last value. Here we reproduce both: a module-level sink
# plus the `@tr` macro. We assert on the returned value AND the recorded rows. Covers plain/typed/
# augmented/destructuring/local/global assignment, loop & branch recursion (per-iteration capture),
# opaque defs, value snapshotting (a later mutation must NOT rewrite an earlier row), and the wire.
using ReTest

const HERE = @__DIR__
include(joinpath(HERE, "..", "src", "trace.jl"))

# Mirror the namespace injection: the per-notebook sink + `@tr` == the notebook's `@trace`.
__slate_trace_sink = Ref{Any}(nothing)
macro tr(blk)
    esc(_trace_transform(blk))
end

# Rows recorded by the most recent `@tr` block, as (name, value-repr) pairs.
rows() = __slate_trace_sink[] === nothing ? Tuple{Int,String,String}[] : __slate_trace_sink[]
nv() = [(n, v) for (_, n, v) in rows()]

@testset "@trace" begin
    @testset "returns the real value; records assignments + result" begin
        v = @tr begin
            a = 3
            b = a + 2
            b
        end
        @test v == 5                                       # the cell's NORMAL value, not a trace object
        @test nv() == [("a", "3"), ("b", "5"), ("result", "5")]
    end

    @testset "loop: per-iteration capture" begin
        v = @tr begin
            s = 0
            for i in 1:3
                c = i^2
                s += c
            end
            s
        end
        @test v == 14
        @test nv() == [("s", "0"),
            ("c", "1"), ("s", "1"),
            ("c", "4"), ("s", "5"),
            ("c", "9"), ("s", "14"),
            ("result", "14")]
    end

    @testset "while loop" begin
        v = @tr begin
            n = 3
            while n > 0
                n -= 1
            end
            n
        end
        @test v == 0
        @test nv() == [("n", "3"), ("n", "2"), ("n", "1"), ("n", "0"), ("result", "0")]
    end

    @testset "if/elseif/else branches" begin
        f(x) = @tr begin
            if x > 0
                sign = 1
            elseif x < 0
                sign = -1
            else
                sign = 0
            end
            sign
        end
        @test f(5) == 1 && nv() == [("sign", "1"), ("result", "1")]
        @test f(-5) == -1 && nv() == [("sign", "-1"), ("result", "-1")]
        @test f(0) == 0 && nv() == [("sign", "0"), ("result", "0")]
    end

    @testset "typed + tuple-destructuring assignment" begin
        v = @tr begin
            x::Int = 7
            (p, q) = (10, 20)
            p + q
        end
        @test v == 30
        @test nv() == [("x", "7"), ("p", "10"), ("q", "20"), ("result", "30")]
    end

    @testset "local / global assignment recorded; returns value" begin
        v = @tr begin
            local a = 1
            a + 1
        end
        @test v == 2
        @test nv() == [("a", "1"), ("result", "2")]
    end

    @testset "final assignment returns the assigned value" begin
        v = @tr begin
            x = 4
            y = x * 5
        end
        @test v == 20                                      # cell ending in an assignment returns its value
        @test nv() == [("x", "4"), ("y", "20")]
    end

    @testset "let block recursion (bindings stay local, body traced)" begin
        v = @tr begin
            base = 100
            let y = base + 1
                z = y * 2
            end
            base
        end
        @test v == 100
        @test nv() == [("base", "100"), ("z", "202"), ("result", "100")]
    end

    @testset "try/catch recursion" begin
        v = @tr begin
            ok = 0
            try
                ok = 1
                error("boom")
            catch err
                ok = 2
            end
            ok
        end
        @test v == 2
        @test nv() == [("ok", "0"), ("ok", "1"), ("ok", "2"), ("result", "2")]
    end

    @testset "opaque defs are not recorded" begin
        v = @tr begin
            g(x) = x + 1
            w = g(4)
            w
        end
        @test v == 5
        @test nv() == [("w", "5"), ("result", "5")]        # no row for `g`
    end

    @testset "indexed assignment leaves no name row; loop returns nothing" begin
        v = @tr begin
            arr = [0, 0, 0]
            arr[2] = 9
            for k in 1:2
                arr[k] = k
            end
        end
        @test v === nothing                                # a cell ending in a for-loop returns nothing
        @test nv() == [("arr", "[0, 0, 0]")]               # arr[i]= records nothing
    end

    @testset "value snapshot: later mutation does not rewrite earlier rows" begin
        v = @tr begin
            vec = [1, 2]
            push!(vec, 3)
            vec
        end
        @test v == [1, 2, 3]
        @test (rows()[1][2], rows()[1][3]) == ("vec", "[1, 2]")   # snapshot at that line, not the mutated value
        @test nv()[end] == ("result", "[1, 2, 3]")
    end

    @testset "single (non-block) expression" begin
        v = @tr 6 * 7
        @test v == 42
        @test nv() == [("result", "42")]
    end

    @testset "cell ending in a value-returning let/if returns that value (the try_gram bug)" begin
        # A cell that is just `let … expr end` must return the let's value, not nothing.
        v = @tr begin
            let a = 3
                a * 2
            end
        end
        @test v == 6
        # ending in an `if` returns the taken branch's value.
        g(x) = @tr begin
            if x > 0
                x * 10
            else
                -1
            end
        end
        @test g(4) == 40
        @test g(-2) == -1
    end

    @testset "let/begin with only a bare expression records the result (the kinetic_1d case)" begin
        # A cell that is just `let … <expr> end` with no assignments used to trace NOTHING; now its
        # value is captured as the result row.
        v = @tr begin
            let
                3 + 4
            end
        end
        @test v == 7
        @test nv() == [("result", "7")]
        # a final `begin … end` likewise yields a result row
        v2 = @tr begin
            begin
                2 * 5
            end
        end
        @test v2 == 10
        @test nv() == [("result", "10")]
    end

    @testset "wire form" begin
        @tr begin
            n = 2
            n * 3
        end
        w = _trace_wire(rows())
        @test w isa Vector
        @test w[1]["name"] == "n" && w[1]["value"] == "2" && w[1]["line"] isa Int
        @test any(d -> d["name"] == "result" && d["value"] == "6", w)
    end
end
