# Unit tests for `_def_name` — the top-level-definition name extractor behind hot-reload change
# detection (src/defname.jl). Covers the Expr shapes Julia parsing AND Revise produce. The
# regression that motivated this: Revise stores bare one-liner defs as `begin <LNN> def end`
# (a :block), which used to be dropped, so cells using those functions never went stale.
using Test

const HERE = @__DIR__
include(joinpath(HERE, "..", "src", "defname.jl"))

p(s) = Meta.parse(s)                                   # the single top-level Expr for a snippet
blk(args...) = Expr(:block, args...)                   # Revise's `begin <LNN> def end` wrapper
docm(def) = Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), LineNumberNode(1, :t), "the docs", def)  # docstring form
LNN = LineNumberNode(7, Symbol("SlateTest.jl"))

@testset "_def_name" begin
    @testset "function definitions" begin
        @test _def_name(p("f(x) = x")) == "f"                       # short-form
        @test _def_name(p("function g(x)\n  x\nend")) == "g"        # full form
        @test _def_name(p("h(x::T) where {T} = x")) == "h"          # where
        @test _def_name(p("j(x::Int)::Float64 = x")) == "j"         # return-typed
        @test _def_name(p("k(x; y = 1) = x + y")) == "k"            # kwargs
        @test _def_name(p("Base.foo(x) = x")) == "foo"              # qualified → last component
    end

    @testset "Revise :block-wrapped one-liners (the regression)" begin
        @test _def_name(blk(LNN, p("offset(n) = n * 1"))) == "offset"
        @test _def_name(blk(LNN, p("offset2(n) = n + 1"))) == "offset2"
        @test _def_name(blk(LNN, p("function q(x)\n x\nend"))) == "q"
        @test _def_name(blk(LineNumberNode(1), LineNumberNode(2), p("r(x) = x"))) == "r"
        @test _def_name(blk(LNN, p("struct W; a; end"))) == "W"     # block-wrapped type
    end

    @testset "docstrings + macro-wrapped" begin
        @test _def_name(docm(p("f2(x) = x"))) == "f2"               # @doc macrocall
        @test _def_name(docm(p("struct DS; a; end"))) == "DS"
        @test _def_name(p("@inline f4(x) = x")) == "f4"             # macro-wrapped def
    end

    @testset "types" begin
        @test _def_name(p("struct Foo\n a::Int\nend")) == "Foo"
        @test _def_name(p("mutable struct Bar\n x\nend")) == "Bar"
        @test _def_name(p("struct Baz{T}\n x::T\nend")) == "Baz"    # parametric
        @test _def_name(p("struct Sub <: Super end")) == "Sub"     # subtype
        @test _def_name(p("struct Par{T} <: Sup{T}\n x::T\nend")) == "Par"
        @test _def_name(p("abstract type A end")) == "A"
        @test _def_name(p("abstract type B <: A end")) == "B"
        @test _def_name(p("primitive type P 8 end")) == "P"
    end

    @testset "const + bare assignment" begin
        @test _def_name(p("const K = 5")) == "K"
        @test _def_name(p("const L = M = 5")) == "L"
        @test _def_name(p("y = 5")) == "y"                          # global assignment
    end

    @testset "macros" begin
        @test _def_name(p("macro m(x)\n x\nend")) == "@m"
    end

    @testset "non-definitions → nothing" begin
        @test _def_name(p("x + 1")) === nothing
        @test _def_name(p("using Foo")) === nothing
        @test _def_name(p("import Foo: bar")) === nothing
        @test _def_name(p("export a, b")) === nothing
        @test _def_name(p("foo(3)")) === nothing                    # a call, not a def
        @test _def_name(p("(c::Counter)(x) = x")) === nothing       # callable-object method: no plain binding
        @test _def_name(LineNumberNode(1)) === nothing
        @test _def_name(:x) === nothing
        @test _def_name(42) === nothing
        @test _def_name(blk(LineNumberNode(1), p("x + 1"))) === nothing   # block with no def
    end

    @testset "findfirst_def" begin
        @test findfirst_def([LineNumberNode(1), p("a + b"), p("z(x) = x")]) == "z"
        @test findfirst_def([LineNumberNode(1), p("a + b")]) === nothing
        @test findfirst_def(Any[]) === nothing
    end
end
