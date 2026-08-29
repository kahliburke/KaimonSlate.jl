# Unit tests for `_def_name` — the top-level-definition name extractor behind hot-reload change
# detection (src/defname.jl). Covers the Expr shapes Julia parsing AND Revise produce. The
# regression that motivated this: Revise stores bare one-liner defs as `begin <LNN> def end`
# (a :block), which used to be dropped, so cells using those functions never went stale.
using ReTest

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

# `_collect_defs!` — the file → (def-name → body-hash) walk behind change-granular hot-reload.
# Crucially it recurses into submodules (so `Sub.greet` is captured under leaf `greet`), and the
# body-hash is LineNumberNode-insensitive (a line shift is not a change) but body-sensitive.
defs(src) = _collect_defs!(Dict{String,UInt64}(), Meta.parseall(src))

@testset "_collect_defs!" begin
    @testset "top-level + nested submodule defs (leaf names)" begin
        d = defs("""
        module M
        using X
        f(x) = x
        struct Pt; a; b; end
        module Sub
        greet() = "hi"
        end
        const K = 5
        end
        """)
        @test sort(collect(keys(d))) == ["K", "Pt", "f", "greet"]   # incl. submodule's `greet`
    end

    @testset "line shifts don't change the hash; body edits do" begin
        @test defs("g(x) = x")["g"]   == defs("\n\n\ng(x) = x")["g"]      # LNN-insensitive
        @test defs("g(x) = x")["g"]   != defs("g(x) = x + 1")["g"]        # body-sensitive
        @test defs("greet() = \"v1\"")["greet"] != defs("greet() = \"v2\"")["greet"]
    end

    @testset "diff isolates the changed def" begin
        a = defs("f(x)=x\ng(x)=2x\nmodule S; h()=1; end")
        b = defs("f(x)=x\ng(x)=3x\nmodule S; h()=1; end")            # only g changed
        changed = [k for (k, v) in b if get(a, k, nothing) != v]
        @test changed == ["g"]
    end

    @testset "a DOCUMENTED module is not opaque" begin
        # `"""doc""" module M … end` parses as a `@doc` macrocall, so the plain `:module` branch
        # never sees it. Most packages document their top module, and the result was that this
        # returned NOTHING for their main file — the memo layer and the batch fabric's
        # re-provisioning both watch this, so an edit to any function in it changed nothing.
        d = defs("\"\"\"\n    M\n\nA documented module.\n\"\"\"\nmodule M\nf(x) = x\ng() = 1\nend")
        @test sort(collect(keys(d))) == ["f", "g"]
        # …and the bodies are still what changes, so an edit inside one is visible.
        e = defs("\"\"\"\n    M\n\nA documented module.\n\"\"\"\nmodule M\nf(x) = x + 1\ng() = 1\nend")
        @test d["g"] == e["g"] && d["f"] != e["f"]
        # A documented FUNCTION already worked (`_def_name` unwraps it) — keep it that way.
        @test haskey(defs("\"doc\"\nf(x) = x"), "f")
    end

    @testset "src_tree_digest: definitions, not bytes" begin
        mktempdir() do dir
            src = joinpath(dir, "src"); mkpath(src)
            body = "\"\"\"\n    P\n\"\"\"\nmodule P\nf(x) = x\nend\n"
            write(joinpath(src, "P.jl"), body)
            base = src_tree_digest([src])
            @test base != SRC_DIGEST_EMPTY                       # a documented module is not empty

            write(joinpath(src, "P.jl"), body * "\n# just a comment\n")
            @test src_tree_digest([src]) == base                 # comments/formatting are not code

            write(joinpath(src, "P.jl"), replace(body, "f(x) = x" => "f(x) = x + 1"))
            @test src_tree_digest([src]) != base                 # an edited body is

            write(joinpath(src, "P.jl"), body)
            @test src_tree_digest([src]) == base                 # and it is reversible
            write(joinpath(src, "Q.jl"), "g() = 2\n")
            @test src_tree_digest([src]) != base                 # a new file counts too
            @test src_tree_digest([joinpath(dir, "nope")]) == SRC_DIGEST_EMPTY
        end
    end
end
